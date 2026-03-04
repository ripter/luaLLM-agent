--- src/agent.lua
--- Core orchestration loop.
--- Drives a task table through the status machine one step at a time,
--- delegating to planner, cmd_plan, skill_runner, and approval.
---
--- Build order: handlers are added one step at a time (3a, 3b, …).
--- Only handle_pending and handle_planning are implemented here (Step 3a).

local _src = debug.getinfo(1, "S").source:match("^@(.*/)") or "./"
package.path = _src .. "?.lua;" .. package.path

local M = {}

-- ---------------------------------------------------------------------------
-- Default dependencies
-- ---------------------------------------------------------------------------

local function default_deps()
  return {
    task         = require("task"),
    planner      = require("planner"),
    cmd_plan     = require("cmd_plan"),
    plan         = require("plan"),
    skill_runner = require("skill_runner"),
    approval     = require("approval"),
    config       = require("config"),
    luallm       = require("luallm"),
    safe_fs      = require("safe_fs"),
    print        = _G.print,
  }
end

-- ---------------------------------------------------------------------------
-- Internal: read plan text from disk (best-effort; nil on failure)
-- ---------------------------------------------------------------------------

local function read_plan_text(plan_path)
  if type(plan_path) ~= "string" or plan_path == "" then return nil end
  local f = io.open(plan_path, "r")
  if not f then return nil end
  local text = f:read("*a")
  f:close()
  return (text ~= "") and text or nil
end

-- ---------------------------------------------------------------------------
-- Handler: PENDING → PLANNING
-- ---------------------------------------------------------------------------

local function handle_pending(deps, t)
  deps.task.transition(t, deps.task.PLANNING, "starting")
  return t
end

-- ---------------------------------------------------------------------------
-- Handler: PLANNING → EXECUTING | REPLANNING | FAILED
-- ---------------------------------------------------------------------------

local function handle_planning(deps, t)
  deps.task.bump_attempt(t, "plan")

  local plan_path, result = deps.planner.generate(deps, t.prompt, {
    context_files = t.context_files,
  })

  if plan_path then
    -- Success: record plan location and content, advance to EXECUTING.
    t.plan_path = plan_path
    t.plan_text = read_plan_text(plan_path) or (type(result) == "string" and result or nil)
    deps.task.transition(t, deps.task.EXECUTING, "plan generated: " .. plan_path)
    return t
  end

  -- Failure path: result is an error string.
  local err = tostring(result)
  t.error = err

  -- PLANNING can only transition to EXECUTING or FAILED (see task.lua TRANSITIONS).
  -- When the planner fails we always go to FAILED here.  The retry logic lives
  -- in handle_replanning (Step 3b): REPLANNING → PLANNING re-enters this handler
  -- if attempts.plan < max_attempts.plan.
  local detail = deps.task.can_retry(t, "plan")
    and ("planning failed (attempt " .. t.attempts.plan .. ", will retry): " .. err)
    or  ("planning failed (no retries left): " .. err)
  deps.task.transition(t, deps.task.FAILED, detail)

  return t
end

-- ---------------------------------------------------------------------------
-- Dispatch table
-- ---------------------------------------------------------------------------

local HANDLERS = {
  [("pending")]    = handle_pending,
  [("planning")]   = handle_planning,
  -- Remaining handlers (executing, testing, approval, replanning) added in 3b+.
}

-- ---------------------------------------------------------------------------
-- Public API: step
-- ---------------------------------------------------------------------------

--- Execute one step of the state machine for task t.
--- Dispatches t.status to the appropriate handler.
--- Returns t (mutated) on success, or nil + error_string on hard failure.
---
--- Note: a "hard failure" is when the dispatch table has no handler for the
--- current status (i.e. a programming error or an unimplemented state).
--- Handler-level failures (planner errors, etc.) are expressed as status
--- transitions (→ REPLANNING or → FAILED) rather than nil returns.
function M.step(deps, t)
  local handler = HANDLERS[t.status]
  if not handler then
    return nil, "agent.step: no handler for status '" .. tostring(t.status) .. "'"
  end
  return handler(deps, t)
end

-- ---------------------------------------------------------------------------
-- Public API: run
-- ---------------------------------------------------------------------------

--- Create a task from prompt and drive it through the state machine until it
--- reaches a terminal or paused state (or max_steps is exceeded).
---
--- @param deps   table   Dependency table (see module doc).
--- @param prompt string  The user's task description.
--- @param opts   table   Optional:
---                         max_steps     = 20
---                         context_files = {}
---
--- @return table|nil, string  Completed task table, or nil + error_string.
function M.run(deps, prompt, opts)
  if type(deps) ~= "table" then
    deps = default_deps()
  end
  opts = opts or {}

  if type(prompt) ~= "string" or prompt == "" then
    return nil, "agent.run: prompt must be a non-empty string"
  end

  local max_steps = opts.max_steps or 20

  local t = deps.task.new(prompt)
  t.context_files = opts.context_files or {}

  local steps = 0
  while not deps.task.is_terminal(t) and not deps.task.is_paused(t) do
    steps = steps + 1
    if steps > max_steps then
      deps.task.transition(t, deps.task.FAILED,
        "agent.run: exceeded max_steps (" .. max_steps .. ")")
      break
    end

    local result, err = M.step(deps, t)
    if not result then
      -- Hard failure from step (unhandled status); fail the task.
      deps.task.transition(t, deps.task.FAILED, tostring(err))
      break
    end
  end

  return t
end

-- ---------------------------------------------------------------------------
-- Public API: resume
-- ---------------------------------------------------------------------------

--- Resume a paused (APPROVAL) task.
--- Placeholder — full implementation in Step 3c when approval handler is added.
---
--- @param deps  table
--- @param task_obj table  A task table in APPROVAL status.
--- @param opts  table     Optional.
---
--- @return table|nil, string
function M.resume(deps, task_obj, opts)
  if type(deps) ~= "table" then
    deps = default_deps()
  end

  if type(task_obj) ~= "table" then
    return nil, "agent.resume: task_obj must be a table"
  end

  if task_obj.status ~= deps.task.APPROVAL then
    return nil, "agent.resume: task is not paused (status: " .. tostring(task_obj.status) .. ")"
  end

  -- Drive the loop from the current (APPROVAL) state.
  opts = opts or {}
  local max_steps = opts.max_steps or 20
  local steps     = 0

  while not deps.task.is_terminal(task_obj) and not deps.task.is_paused(task_obj) do
    steps = steps + 1
    if steps > max_steps then
      deps.task.transition(task_obj, deps.task.FAILED,
        "agent.resume: exceeded max_steps (" .. max_steps .. ")")
      break
    end

    local result, err = M.step(deps, task_obj)
    if not result then
      deps.task.transition(task_obj, deps.task.FAILED, tostring(err))
      break
    end
  end

  return task_obj
end

return M
