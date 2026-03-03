--- src/task.lua
--- Task table schema and status machine.
--- Pure data module: no I/O, no filesystem access, no external deps beyond
--- os.time() and an optional uuid_fn injected via task.new().

local M = {}

-- ---------------------------------------------------------------------------
-- Status constants
-- ---------------------------------------------------------------------------

M.PENDING    = "pending"
M.PLANNING   = "planning"
M.EXECUTING  = "executing"
M.TESTING    = "testing"
M.APPROVAL   = "approval"
M.REPLANNING = "replanning"
M.COMPLETE   = "complete"
M.FAILED     = "failed"

-- ---------------------------------------------------------------------------
-- Legal transition table
-- ---------------------------------------------------------------------------

local TRANSITIONS = {
  [M.PENDING]    = { [M.PLANNING]   = true },
  [M.PLANNING]   = { [M.EXECUTING]  = true, [M.FAILED]     = true },
  [M.EXECUTING]  = { [M.TESTING]    = true, [M.COMPLETE]   = true,
                     [M.REPLANNING] = true, [M.FAILED]     = true },
  [M.TESTING]    = { [M.APPROVAL]   = true, [M.REPLANNING] = true,
                     [M.FAILED]     = true },
  [M.APPROVAL]   = { [M.COMPLETE]   = true, [M.FAILED]     = true },
  [M.REPLANNING] = { [M.PLANNING]   = true, [M.FAILED]     = true },
  [M.COMPLETE]   = {},
  [M.FAILED]     = {},
}

-- ---------------------------------------------------------------------------
-- ISO-8601 timestamp helper (second precision)
-- ---------------------------------------------------------------------------

local function iso8601(t)
  t = t or os.time()
  return os.date("!%Y-%m-%dT%H:%M:%SZ", t)
end

-- ---------------------------------------------------------------------------
-- Default UUID generator (lazy-loads the uuid rock)
-- ---------------------------------------------------------------------------

local function default_uuid_fn()
  local ok, uuid = pcall(require, "uuid")
  if not ok then
    -- Fallback: pseudo-uuid from os.time + math.random (not cryptographic,
    -- but sufficient for local task IDs when the rock isn't installed).
    math.randomseed(os.time() + math.floor(os.clock() * 1e6))
    return string.format(
      "%08x-%04x-4%03x-%04x-%012x",
      math.random(0, 0xffffffff),
      math.random(0, 0xffff),
      math.random(0, 0xfff),
      math.random(0x8000, 0xbfff),
      math.random(0, 0xffffffffffff)
    )
  end
  -- Seed the uuid rock's RNG the same way approval.lua does.
  uuid.set_rng(function(n)
    math.randomseed(os.time() + math.floor(os.clock() * 1e6))
    local bytes = {}
    for i = 1, n do bytes[i] = string.char(math.random(0, 255)) end
    return table.concat(bytes)
  end)
  return uuid()
end

-- ---------------------------------------------------------------------------
-- Public API: new
-- ---------------------------------------------------------------------------

--- Create a new task table.
---
--- @param prompt    string   The user's original prompt for this task.
--- @param uuid_fn   function Optional. Called with no args, returns a UUID string.
---                           Defaults to using the `uuid` luarock.
--- @return table
function M.new(prompt, uuid_fn)
  uuid_fn = uuid_fn or default_uuid_fn
  local now = iso8601()
  return {
    id           = uuid_fn(),
    prompt       = prompt or "",
    status       = M.PENDING,
    plan_path    = nil,
    plan_text    = nil,
    outputs      = {},
    skill_files  = {},
    test_results = nil,
    approval_id  = nil,
    error        = nil,
    attempts     = { plan = 0, replan = 0, test = 0 },
    max_attempts = { plan = 3, replan = 2, test = 2 },
    history      = {},
    created_at   = now,
    updated_at   = now,
  }
end

-- ---------------------------------------------------------------------------
-- Public API: transition
-- ---------------------------------------------------------------------------

--- Transition a task to a new status.
--- Validates that the transition is legal, appends to history, and updates
--- updated_at.  Mutates t in-place.
---
--- @param t          table   The task table (from task.new).
--- @param new_status string  One of the M.* status constants.
--- @param detail     string  Optional human-readable note logged in history.
--- @return table|nil, string  Returns t on success, or nil + error string.
function M.transition(t, new_status, detail)
  local allowed = TRANSITIONS[t.status]
  if not allowed then
    return nil, "illegal transition: unknown source status '" .. tostring(t.status) .. "'"
  end
  if not allowed[new_status] then
    return nil, "illegal transition: " .. t.status .. " → " .. tostring(new_status)
  end

  local now = iso8601()
  t.history[#t.history + 1] = {
    status = new_status,
    ts     = now,
    detail = detail or "",
  }
  t.status     = new_status
  t.updated_at = now
  return t
end

-- ---------------------------------------------------------------------------
-- Public API: query helpers
-- ---------------------------------------------------------------------------

--- Return true if the task is in a terminal status (COMPLETE or FAILED).
function M.is_terminal(t)
  return t.status == M.COMPLETE or t.status == M.FAILED
end

--- Return true if the task is paused waiting for human input (APPROVAL).
function M.is_paused(t)
  return t.status == M.APPROVAL
end

--- Return true if the attempt counter for key is below the max.
--- @param key string  One of "plan", "replan", "test".
function M.can_retry(t, key)
  local attempts = t.attempts[key]
  local max      = t.max_attempts[key]
  if attempts == nil or max == nil then return false end
  return attempts < max
end

--- Increment the attempt counter for key and return the new count.
--- @param key string  One of "plan", "replan", "test".
function M.bump_attempt(t, key)
  t.attempts[key] = (t.attempts[key] or 0) + 1
  return t.attempts[key]
end

return M
