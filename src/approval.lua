--- src/approval.lua
--- Approval Manager with strict Human Required promotion workflow.
---
--- SECURITY INVARIANT: This module never moves, copies, or chmods skill files.
--- It may only *print* commands a human should run. Promotion is always manual.
---
--- Rocks: cjson (cjson.safe), luafilesystem (lfs), uuid, penlight

local cjson = require("cjson.safe")
local lfs   = require("lfs")
local uuid  = require("uuid")
local util  = require("util")

-- Initialise the RNG once at module load time.
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
-- Lazy-load optional / not-yet-written modules
-- ---------------------------------------------------------------------------

local config = util.try_require("config")
local audit  = util.try_require("audit")

local M = {}

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

--- Generate a UUID v4 string using the uuid luarock.
local function new_uuid()
  return uuid()
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

--- Try to log via audit module; silently skip if audit is unavailable.
local function try_audit(event, data)
  if audit and type(audit.log) == "function" then
    audit.log(event, data)
  end
end

--- Locate the state/pending_approvals directory.
local function default_approvals_dir()
  local state = util.try_require("state")
  if state and type(state.dir) == "function" then
    local d = state.dir()
    if d then return d .. "/pending_approvals" end
  end
  return "./state/pending_approvals"
end

--- Load and decode a JSON file. Returns (table) or (nil, err).
local function load_json_file(path)
  local raw, err = util.read_file(path)
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
  return util.write_file_atomic(path, encoded)
end

--- Find the file path for an approval record by ID within approvals_dir.
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

function M.create(skill_name, skill_path, test_path, test_results, metadata, approvals_dir)
  if type(skill_name) ~= "string" or skill_name == "" then
    return nil, "approval.create: skill_name must be a non-empty string"
  end

  approvals_dir = approvals_dir or default_approvals_dir()

  local ok, err = util.mkdir_p(approvals_dir)
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
    created_at   = util.iso8601(),
    skill_path   = skill_path   or "",
    test_path    = test_path    or "",
    test_results = test_results or {},
    metadata     = metadata     or {},
    approved     = cjson.null,
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

  return load_json_file(path)
end

function M.list_pending(approvals_dir)
  approvals_dir = approvals_dir or default_approvals_dir()

  local attr = lfs.attributes(approvals_dir)
  if not attr or attr.mode ~= "directory" then
    return {}
  end

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

  record.approved    = approved
  record.resolved_at = util.iso8601()
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

function M.check_promotion(skill_name, allowed_dir, record)
  if type(skill_name) ~= "string" or skill_name == "" then return false end
  if type(allowed_dir) ~= "string" or allowed_dir == "" then return false end

  local target = allowed_dir .. "/" .. skill_name .. ".lua"
  local attr   = lfs.attributes(target)
  return attr ~= nil and attr.mode == "file"
end

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
  record.promoted_at = util.iso8601()

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
    "mkdir -p " .. util.shell_quote(allowed_dir),
    "cp "       .. util.shell_quote(src) .. " " .. util.shell_quote(dst),
    "chmod 444 " .. util.shell_quote(dst),
    "# Verify the promotion was recorded:",
    "lua main.lua doctor",
  }

  return cmds
end

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

function M.promote(...)
  return nil,
    "HumanRequired: promotion must be performed manually. " ..
    "Use approval.get_promotion_commands() to obtain the required shell commands."
end

return M
