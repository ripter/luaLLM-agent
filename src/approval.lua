--- src/approval.lua
--- Approval Manager with strict Human Required promotion workflow.
---
--- SECURITY INVARIANT: This module never moves, copies, or chmods skill files.
--- It may only *print* commands a human should run. Promotion is always manual.
---
--- Rocks: cjson (cjson.safe), luafilesystem (lfs), uuid

local cjson = require("cjson.safe")
local lfs   = require("lfs")
local uuid  = require("uuid")

-- Initialise the RNG once at module load time.
-- uuid.set_rng() expects a function(n) that returns a binary string of n
-- random bytes.  We build one from math.random, seeded with a mix of
-- os.time() and os.clock() for sub-second resolution.
do
  math.randomseed(math.floor(os.time() + os.clock() * 10000))
  uuid.set_rng(function(n)
    local bytes = {}
    for i = 1, n do
      bytes[i] = string.char(math.random(0, 255))
    end
    return table.concat(bytes)
  end)
end

-- ---------------------------------------------------------------------------
-- Lazy-load optional / not-yet-written modules so this file requires cleanly
-- regardless of whether they exist yet.
-- ---------------------------------------------------------------------------

local function try_require(name)
  local ok, mod = pcall(require, name)
  return ok and mod or nil
end

local config = try_require("config")
local audit  = try_require("audit")

local M = {}

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

--- Return current time as an ISO 8601 UTC string.
local function iso8601()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

--- Generate a UUID v4 string using the uuid luarock.
local function new_uuid()
  return uuid()
end

--- Ensure a directory and all parents exist (mirrors config.lua's mkdir_p).
--- Handles both absolute paths (starting with /) and relative paths.
local function mkdir_p(path)
  -- Determine if path is absolute so we can reconstruct it correctly.
  local is_absolute = path:sub(1, 1) == "/"
  local acc = is_absolute and "" or "."

  for seg in path:gmatch("[^/]+") do
    -- Skip "." segments that come from relative paths like "./foo"
    if seg ~= "." then
      acc = acc .. "/" .. seg
      local attr = lfs.attributes(acc)
      if not attr then
        local ok, err = lfs.mkdir(acc)
        if not ok and not lfs.attributes(acc) then
          return nil, "mkdir " .. acc .. ": " .. (err or "")
        end
      elseif attr.mode ~= "directory" then
        return nil, acc .. " exists but is not a directory"
      end
    end
  end
  return true
end

--- Read entire file to string, return (content) or (nil, err).
local function read_file(path)
  local f, err = io.open(path, "r")
  if not f then return nil, err end
  local content = f:read("*a")
  f:close()
  return content
end

--- Write string atomically: write to .tmp then rename.
local function write_file_atomic(path, content)
  local tmp = path .. ".tmp"
  local f, err = io.open(tmp, "w")
  if not f then
    return nil, "cannot write " .. tmp .. ": " .. tostring(err)
  end
  f:write(content)
  f:close()
  local ok, ren_err = os.rename(tmp, path)
  if not ok then
    os.remove(tmp)
    return nil, "rename failed: " .. tostring(ren_err)
  end
  return true
end

--- Escape a path for safe embedding in a double-quoted shell argument.
--- Doubles any embedded double-quote characters.
local function shell_quote(path)
  return '"' .. path:gsub('"', '\\"') .. '"'
end

--- Count files in a directory matching a pattern (for stable naming).
local function count_files_in_dir(dir)
  local n = 0
  if not lfs.attributes(dir) then return 0 end
  for _ in lfs.dir(dir) do
    n = n + 1
  end
  return math.max(0, n - 2)  -- subtract . and ..
end

--- Try to log via audit module; silently skip if audit is unavailable or uninitialised.
local function try_audit(event, data)
  if audit and type(audit.log) == "function" then
    audit.log(event, data)
  end
end

--- Locate the state/pending_approvals directory.
--- Uses state.dir() if the state module is initialised; otherwise falls back
--- to ./state/pending_approvals.  Callers may also pass approvals_dir explicitly.
local function default_approvals_dir()
  local state = try_require("state")
  if state and type(state.dir) == "function" then
    local d = state.dir()
    if d then return d .. "/pending_approvals" end
  end
  return "./state/pending_approvals"
end

--- Load and decode a JSON file. Returns (table) or (nil, err).
local function load_json_file(path)
  local raw, err = read_file(path)
  if not raw then return nil, err end
  local parsed, parse_err = cjson.decode(raw)
  if not parsed then
    return nil, "JSON parse error in " .. path .. ": " .. tostring(parse_err)
  end
  return parsed
end

--- Save a record table as JSON to path. Returns (true) or (nil, err).
local function save_record(path, record)
  local encoded, err = cjson.encode(record)
  if not encoded then
    return nil, "JSON encode failed: " .. tostring(err)
  end
  return write_file_atomic(path, encoded)
end

--- Find the file path for an approval record by ID within approvals_dir.
--- Returns (filepath, record) or (nil, err).
local function find_record(approvals_dir, approval_id)
  local attr = lfs.attributes(approvals_dir)
  if not attr or attr.mode ~= "directory" then
    return nil, "approvals_dir does not exist or is not a directory: " .. tostring(approvals_dir)
  end

  for filename in lfs.dir(approvals_dir) do
    if filename:match("%.json$") then
      local filepath = approvals_dir .. "/" .. filename
      local record, err = load_json_file(filepath)
      if record and record.id == approval_id then
        return filepath, record
      end
    end
  end

  return nil, "approval not found: " .. tostring(approval_id)
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Create a pending approval record and persist it to approvals_dir.
---
--- approvals_dir defaults to ./state/pending_approvals (or from state module).
--- Filename: skill_<n>_<uuid>.json
---
--- Returns (record_table) or (nil, error_string).
function M.create(skill_name, skill_path, test_path, test_results, metadata, approvals_dir)
  if type(skill_name) ~= "string" or skill_name == "" then
    return nil, "approval.create: skill_name must be a non-empty string"
  end

  approvals_dir = approvals_dir or default_approvals_dir()

  local ok, err = mkdir_p(approvals_dir)
  if not ok then
    return nil, "approval.create: cannot create approvals dir: " .. tostring(err)
  end

  local n    = count_files_in_dir(approvals_dir) + 1
  local id   = new_uuid()
  local name = string.format("skill_%04d_%s.json", n, id)
  local path = approvals_dir .. "/" .. name

  local record = {
    id           = id,
    skill_name   = skill_name,
    created_at   = iso8601(),
    skill_path   = skill_path   or "",
    test_path    = test_path    or "",
    test_results = test_results or {},
    metadata     = metadata     or {},
    approved     = cjson.null,   -- nil/unresolved; JSON null
    resolved_at  = cjson.null,
    promoted     = false,
    promoted_at  = cjson.null,
  }

  local save_ok, save_err = save_record(path, record)
  if not save_ok then
    return nil, "approval.create: failed to save record: " .. tostring(save_err)
  end

  try_audit("approval.created", {
    id         = id,
    skill_name = skill_name,
    path       = path,
  })

  -- Decode what we wrote so booleans / nulls are consistent
  return load_json_file(path)
end

--- Return all approval records in approvals_dir, sorted by filename.
--- Returns (list_of_records) — empty list on missing/empty dir.
function M.list_pending(approvals_dir)
  approvals_dir = approvals_dir or default_approvals_dir()

  local attr = lfs.attributes(approvals_dir)
  if not attr or attr.mode ~= "directory" then
    return {}
  end

  -- Collect filenames first for stable sort
  local filenames = {}
  for filename in lfs.dir(approvals_dir) do
    if filename:match("%.json$") then
      filenames[#filenames + 1] = filename
    end
  end
  table.sort(filenames)

  local records = {}
  for _, filename in ipairs(filenames) do
    local filepath = approvals_dir .. "/" .. filename
    local record, _ = load_json_file(filepath)
    if record then
      records[#records + 1] = record
    end
  end

  return records
end

--- Load a single approval record by ID.
--- Returns (record_table) or (nil, error_string).
function M.get(approvals_dir, approval_id)
  if type(approval_id) ~= "string" or approval_id == "" then
    return nil, "approval.get: approval_id must be a non-empty string"
  end

  approvals_dir = approvals_dir or default_approvals_dir()
  local filepath, record = find_record(approvals_dir, approval_id)
  if not filepath then
    return nil, "approval.get: " .. tostring(record)
  end
  return record
end

--- Resolve an approval: set approved=true/false and resolved_at.
---
--- SECURITY: This function MUST NOT promote, copy, or chmod any files.
--- If opts contains {promote=true} or similar, return an error immediately.
---
--- Returns (updated_record) or (nil, error_string).
function M.resolve(approvals_dir, approval_id, approved, opts)
  -- Hard guard: reject any attempt to sneak promotion through resolve.
  if type(opts) == "table" then
    if opts.promote or opts.copy or opts.chmod or opts.exec then
      return nil, "approval.resolve: promotion options are not permitted here. " ..
                  "Promotion must be performed manually. " ..
                  "Use approval.get_promotion_commands() to obtain the required shell commands."
    end
  end

  if type(approval_id) ~= "string" or approval_id == "" then
    return nil, "approval.resolve: approval_id must be a non-empty string"
  end

  if type(approved) ~= "boolean" then
    return nil, "approval.resolve: approved must be a boolean"
  end

  approvals_dir = approvals_dir or default_approvals_dir()

  local filepath, record = find_record(approvals_dir, approval_id)
  if not filepath then
    return nil, "approval.resolve: " .. tostring(record)
  end

  -- Update only status fields — never touch promoted/promoted_at.
  record.approved    = approved
  record.resolved_at = iso8601()
  -- Explicitly ensure promoted stays false if unset.
  if record.promoted == nil then
    record.promoted = false
  end

  local ok, err = save_record(filepath, record)
  if not ok then
    return nil, "approval.resolve: failed to save: " .. tostring(err)
  end

  try_audit("approval.resolved", {
    id         = approval_id,
    skill_name = record.skill_name,
    approved   = approved,
  })

  return load_json_file(filepath)
end

--- Check whether skill_name.lua exists in allowed_dir.
--- Returns true if it exists, false otherwise.
--- Does NOT modify the record or trigger any action.
function M.check_promotion(skill_name, allowed_dir, record)
  if type(skill_name) ~= "string" or skill_name == "" then return false end
  if type(allowed_dir) ~= "string" or allowed_dir == "" then return false end

  local target = allowed_dir .. "/" .. skill_name .. ".lua"
  local attr   = lfs.attributes(target)
  return attr ~= nil and attr.mode == "file"
end

--- Mark a record as promoted IFF the skill file already exists in allowed_dir.
---
--- This ONLY updates the record on disk; it does not create or move any files.
--- If the file does not exist, returns (nil, "NotPromoted: file not found in allowed_dir").
---
--- Returns (updated_record) or (nil, error_string).
function M.mark_promoted(approvals_dir, approval_id, allowed_dir)
  if type(approval_id) ~= "string" or approval_id == "" then
    return nil, "approval.mark_promoted: approval_id must be a non-empty string"
  end
  if type(allowed_dir) ~= "string" or allowed_dir == "" then
    return nil, "approval.mark_promoted: allowed_dir must be a non-empty string"
  end

  approvals_dir = approvals_dir or default_approvals_dir()

  local filepath, record = find_record(approvals_dir, approval_id)
  if not filepath then
    return nil, "approval.mark_promoted: " .. tostring(record)
  end

  local target = allowed_dir .. "/" .. record.skill_name .. ".lua"
  if not lfs.attributes(target) then
    return nil, "NotPromoted: file not found in allowed_dir: " .. target
  end

  record.promoted    = true
  record.promoted_at = iso8601()

  local ok, err = save_record(filepath, record)
  if not ok then
    return nil, "approval.mark_promoted: failed to save: " .. tostring(err)
  end

  try_audit("approval.marked_promoted", {
    id         = approval_id,
    skill_name = record.skill_name,
    allowed_dir = allowed_dir,
  })

  return load_json_file(filepath)
end

--- Display a formatted approval prompt and read a single keypress from stdin.
---
--- Returns one of: "view", "rerun", "edit", "approve", "reject",
---                 "print_promote", "mark_promoted"
function M.prompt_human(record)
  if type(record) ~= "table" then
    return nil, "approval.prompt_human: record must be a table"
  end

  local skill_name = record.skill_name or "unknown"
  local version    = record.metadata and record.metadata.version
  local title      = version and (skill_name .. " v" .. version) or skill_name

  io.write("\n")
  io.write("┌─────────────────────────────────────────────────────┐\n")
  io.write("│  Skill Approval: " .. title .. "\n")
  io.write("├─────────────────────────────────────────────────────┤\n")
  io.write("│  skill_path : " .. tostring(record.skill_path or "—") .. "\n")
  io.write("│  test_path  : " .. tostring(record.test_path  or "—") .. "\n")
  io.write("│  created_at : " .. tostring(record.created_at or "—") .. "\n")

  -- Test results
  local results = record.test_results or {}
  if type(results) == "table" and #results > 0 then
    io.write("├─────────────────────────────────────────────────────┤\n")
    io.write("│  Test results:\n")
    for _, item in ipairs(results) do
      local icon = (item.passed or item.ok) and "✅" or "❌"
      local name = item.name or item.test or tostring(item)
      io.write("│    " .. icon .. "  " .. name .. "\n")
    end
  end

  -- Metadata extras
  local meta = record.metadata or {}
  if type(meta.dependencies) == "table" and #meta.dependencies > 0 then
    io.write("├─────────────────────────────────────────────────────┤\n")
    io.write("│  Dependencies: " .. table.concat(meta.dependencies, ", ") .. "\n")
  end
  if type(meta.declared_paths) == "table" and #meta.declared_paths > 0 then
    io.write("│  Declared paths:\n")
    for _, p in ipairs(meta.declared_paths) do
      io.write("│    " .. tostring(p) .. "\n")
    end
  end

  io.write("├─────────────────────────────────────────────────────┤\n")
  io.write("│  [V]iew code  [R]erun tests  [E]dit\n")
  io.write("│  [Y]es (approve)  [N]o (reject)\n")
  io.write("│  [P]rint promote commands  [M]ark promoted\n")
  io.write("└─────────────────────────────────────────────────────┘\n")
  io.write("Choice: ")
  io.flush()

  local input = io.read(1)
  if not input then return "reject" end
  input = input:lower()

  local key_map = {
    v = "view",
    r = "rerun",
    e = "edit",
    y = "approve",
    n = "reject",
    p = "print_promote",
    m = "mark_promoted",
  }
  return key_map[input] or "reject"
end

--- Return a list of exact shell commands a human must run to promote a skill.
---
--- Commands include mkdir -p, cp, and chmod. Paths are double-quoted with
--- embedded quotes escaped. No commands are executed.
---
--- Returns a list of strings.
function M.get_promotion_commands(record, allowed_dir)
  if type(record) ~= "table" then
    return nil, "approval.get_promotion_commands: record must be a table"
  end
  if type(allowed_dir) ~= "string" or allowed_dir == "" then
    return nil, "approval.get_promotion_commands: allowed_dir must be a non-empty string"
  end

  local skill_name = record.skill_name or "unknown"
  local src        = record.skill_path or ""
  local dst        = allowed_dir .. "/" .. skill_name .. ".lua"

  local cmds = {
    "# Promote skill '" .. skill_name .. "' to " .. allowed_dir,
    "mkdir -p " .. shell_quote(allowed_dir),
    "cp "       .. shell_quote(src) .. " " .. shell_quote(dst),
    "chmod 444 " .. shell_quote(dst),
    "# Verify the promotion was recorded:",
    "lua main.lua doctor",
  }

  return cmds
end

--- Delegate to config.approval_tier(tier_name).
--- Returns the tier value ("auto", "prompt", or "manual").
--- Returns nil + error if config is unavailable.
function M.check_tier(tier_name)
  if not config or type(config.approval_tier) ~= "function" then
    return nil, "approval.check_tier: config module unavailable"
  end
  local ok, result = pcall(config.approval_tier, tier_name)
  if not ok then
    return nil, "approval.check_tier: " .. tostring(result)
  end
  return result
end

--- TRAP: Intentionally always fails.
---
--- Promotion must be performed by a human using the shell commands returned by
--- approval.get_promotion_commands(). If this function is ever called by
--- automated code, it will fail loudly here rather than silently doing
--- something dangerous.
---
--- Always returns: (nil, "HumanRequired: ...")
function M.promote(...)  -- luacheck: ignore (varargs intentional)
  return nil,
    "HumanRequired: promotion must be performed manually. " ..
    "Use approval.get_promotion_commands() to obtain the required shell commands."
end

return M
