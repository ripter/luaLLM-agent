--- src/skill_runner.lua
--- Execute skills inside the sandbox, run test suites, validate skills.
--- Depends on: sandbox, skill_loader, audit, config

local sandbox      = require("sandbox")
local skill_loader = require("skill_loader")
local audit        = require("audit")
local config       = require("config")
local lfs          = require("lfs")

local M = {}

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

--- Return current time as an ISO 8601 string (UTC, second precision).
local function iso8601()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

--- Build a log function that delegates to audit.log with a skill prefix.
--- Returns nil (not a function) if audit has not been initialised, so the
--- sandbox treats logging as optional.
local function make_log_fn(skill_name)
  return function(event, data)
    audit.log("skill." .. skill_name .. "." .. event, data)
  end
end

--- Read an entire file to a string, or return nil + error.
local function read_file(path)
  local f, err = io.open(path, "r")
  if not f then return nil, err end
  local content = f:read("*a")
  f:close()
  return content
end

--- Determine the directory containing a given file path.
local function dir_of(filepath)
  return filepath:match("^(.+)/[^/]+$") or "."
end

-- ---------------------------------------------------------------------------
-- skill_runner.execute
-- ---------------------------------------------------------------------------

--- Load a skill by name and execute its run(args) function inside a sandbox.
---
--- Flow:
---   1. Load skill via skill_loader.load
---   2. Resolve dependencies
---   3. Build sandbox env from skill metadata + config
---   4. Execute the skill code in the sandbox
---   5. Call the module's run(args) function
---   6. Log all steps via audit
---
--- @param skill_name  string   bare name (no .lua extension)
--- @param args        any      argument passed to the skill's run() function
--- @param search_dirs table    ordered list of directories to search
--- @return any           result from run(), or nil + error string
function M.execute(skill_name, args, search_dirs)
  if type(skill_name) ~= "string" or skill_name == "" then
    return nil, "skill_runner.execute: skill_name must be a non-empty string"
  end

  if type(search_dirs) ~= "table" or #search_dirs == 0 then
    return nil, "skill_runner.execute: search_dirs must be a non-empty array"
  end

  local log_fn = make_log_fn(skill_name)

  -- 1. Load skill
  audit.log("skill.load", { skill = skill_name })
  local skill, load_err = skill_loader.load(skill_name, search_dirs)
  if not skill then
    audit.log("skill.load.error", { skill = skill_name, error = load_err })
    return nil, load_err
  end

  local meta = skill.metadata

  -- 2. Resolve dependencies
  local skill_dir = dir_of(skill.path)
  local dep_order, dep_err = skill_loader.resolve_dependencies(meta, skill_dir)
  if not dep_order then
    audit.log("skill.deps.error", { skill = skill_name, error = dep_err })
    return nil, dep_err
  end

  -- 3. Build sandbox environment
  local allowed_paths = config.get("allowed_paths") or {}
  local timeout = config.get("limits.skill_exec_timeout_seconds") or 30

  local env = sandbox.make_env({
    paths         = meta.paths        or {},
    allowed_paths = allowed_paths,
    dependencies  = meta.dependencies or {},
    allowed_dir   = skill_dir,
    log_fn        = log_fn,
    skill_name    = skill_name,
  })

  -- 4. Execute the skill code to get the module table
  audit.log("skill.execute.start", { skill = skill_name })
  local exec_ok, module_or_err = sandbox.execute(skill.code, env, timeout)
  if not exec_ok then
    audit.log("skill.execute.error", { skill = skill_name, error = module_or_err })
    return nil, "skill_runner.execute: sandbox execution failed: " .. tostring(module_or_err)
  end

  if type(module_or_err) ~= "table" then
    local msg = "skill_runner.execute: skill '" .. skill_name
      .. "' did not return a module table"
    audit.log("skill.execute.error", { skill = skill_name, error = msg })
    return nil, msg
  end

  local skill_module = module_or_err

  -- 5. Call run(args)
  if type(skill_module.run) ~= "function" then
    local msg = "skill_runner.execute: skill '" .. skill_name
      .. "' has no run() function"
    audit.log("skill.execute.error", { skill = skill_name, error = msg })
    return nil, msg
  end

  audit.log("skill.run.start", { skill = skill_name })
  local run_ok, result = pcall(skill_module.run, args)
  if not run_ok then
    audit.log("skill.run.error", { skill = skill_name, error = tostring(result) })
    return nil, "skill_runner.execute: run() error: " .. tostring(result)
  end

  audit.log("skill.run.complete", { skill = skill_name })
  return result
end

-- ---------------------------------------------------------------------------
-- skill_runner.run_tests
-- ---------------------------------------------------------------------------

--- Execute a test file as a subprocess and capture the results.
---
--- Runs: timeout <seconds> lua <test_file_path> -o json 2>&1
--- Parses stdout as plain text (one line per test status).
---
--- @param test_file_path   string  path to the *_test.lua file
--- @param timeout_seconds  number  maximum wall-clock seconds (default 60)
--- @return table|nil   { exit_code, output, passed }
--- @return string|nil  error message
function M.run_tests(test_file_path, timeout_seconds)
  if type(test_file_path) ~= "string" or test_file_path == "" then
    return nil, "skill_runner.run_tests: test_file_path must be a non-empty string"
  end

  local attr = lfs.attributes(test_file_path)
  if not attr or attr.mode ~= "file" then
    return nil, "skill_runner.run_tests: file not found: " .. test_file_path
  end

  timeout_seconds = timeout_seconds or 60
  if type(timeout_seconds) ~= "number" or timeout_seconds <= 0 then
    return nil, "skill_runner.run_tests: timeout_seconds must be a positive number"
  end

  -- Build the command. Use timeout(1) for wall-clock enforcement.
  -- Redirect stderr to stdout so we capture everything.
  local cmd = string.format(
    "timeout %d lua %s 2>&1",
    math.ceil(timeout_seconds),
    test_file_path
  )

  local handle = io.popen(cmd, "r")
  if not handle then
    return nil, "skill_runner.run_tests: failed to start subprocess"
  end

  local output = handle:read("*a")
  local ok, exit_type, exit_code = handle:close()

  -- io.popen:close returns (true/nil, "exit"/"signal", code) in Lua 5.2+
  -- In Lua 5.1 it returns just the exit status number.
  if type(ok) == "number" then
    exit_code = ok
    ok = (exit_code == 0)
  else
    exit_code = exit_code or (ok and 0 or 1)
  end

  -- timeout(1) returns exit code 124 when the process is killed.
  local timed_out = (exit_code == 124)

  return {
    exit_code = exit_code,
    output    = output or "",
    passed    = (exit_code == 0),
    timed_out = timed_out,
  }
end

-- ---------------------------------------------------------------------------
-- skill_runner.validate_skill
-- ---------------------------------------------------------------------------

--- Validate a skill file: parse metadata, verify public_functions exist in the
--- returned module table, verify declared paths are within the allowed paths.
---
--- The cfg parameter is a plain table with at least:
---   { allowed_paths = { ... }, blocked_paths = { ... } }
--- This avoids requiring config to be loaded globally in test contexts.
---
--- @param skill_path string  path to the .lua skill file
--- @param cfg        table   config table with allowed_paths and blocked_paths
--- @return true|false
--- @return table|nil   list of error strings (when false)
function M.validate_skill(skill_path, cfg)
  local errors = {}

  local function err(msg)
    errors[#errors + 1] = msg
  end

  if type(skill_path) ~= "string" or skill_path == "" then
    return false, { "skill_path must be a non-empty string" }
  end

  if type(cfg) ~= "table" then
    return false, { "cfg must be a table" }
  end

  -- 1. Parse metadata
  local meta, meta_err = skill_loader.parse_metadata(skill_path)
  if not meta then
    return false, { meta_err }
  end

  -- 2. Load and execute the skill code in a permissive sandbox to get module
  local code, read_err = read_file(skill_path)
  if not code then
    return false, { "cannot read skill file: " .. tostring(read_err) }
  end

  local skill_dir = dir_of(skill_path)
  local env = sandbox.make_env({
    paths         = meta.paths        or {},
    allowed_paths = cfg.allowed_paths or {},
    dependencies  = meta.dependencies or {},
    allowed_dir   = skill_dir,
    log_fn        = nil,
    skill_name    = meta.name,
  })

  local exec_ok, module_or_err = sandbox.execute(code, env, 10)
  if not exec_ok then
    err("skill code failed to execute: " .. tostring(module_or_err))
  end

  -- 3. Verify public_functions exist in module table
  if exec_ok and type(module_or_err) == "table" then
    for _, fn_name in ipairs(meta.public_functions) do
      if type(module_or_err[fn_name]) ~= "function" then
        err("public_functions: '" .. fn_name .. "' is not a function in the module")
      end
    end
  elseif exec_ok then
    err("skill did not return a module table")
  end

  -- 4. Verify declared paths are within config allowed_paths
  local allowed  = cfg.allowed_paths or {}
  local blocked  = cfg.blocked_paths or {}

  for _, path_pattern in ipairs(meta.paths or {}) do
    -- Strip trailing glob for matching
    local prefix = path_pattern:gsub("/%*$", "")

    -- Check against blocked_paths (prefix match)
    local is_blocked = false
    for _, bp in ipairs(blocked) do
      if prefix == bp or prefix:sub(1, #bp + 1) == bp .. "/" then
        err("declared path '" .. path_pattern .. "' is blocked by: " .. bp)
        is_blocked = true
        break
      end
    end

    -- Check against allowed_paths (must be within at least one)
    if not is_blocked then
      local is_allowed = false
      for _, ap in ipairs(allowed) do
        local ap_prefix = ap:gsub("/%*$", "")
        if prefix == ap_prefix
           or prefix:sub(1, #ap_prefix + 1) == ap_prefix .. "/" then
          is_allowed = true
          break
        end
      end

      if not is_allowed then
        err("declared path '" .. path_pattern .. "' is not within any allowed_paths")
      end
    end
  end

  if #errors > 0 then
    return false, errors
  end

  return true
end

return M
