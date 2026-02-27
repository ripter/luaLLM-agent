--- src/skill_runner.lua
--- Execute skills inside the sandbox, run test suites, validate skills.
--- Depends on: sandbox, skill_loader, audit, config, safe_fs, util

local sandbox      = require("sandbox")
local skill_loader = require("skill_loader")
local audit        = require("audit")
local config       = require("config")
local safe_fs      = require("safe_fs")
local lfs          = require("lfs")
local util         = require("util")

local M = {}

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

--- Build a log function that delegates to audit.log with a skill prefix.
local function make_log_fn(skill_name)
  return function(event, data)
    audit.log("skill." .. skill_name .. "." .. event, data)
  end
end

-- ---------------------------------------------------------------------------
-- skill_runner.execute
-- ---------------------------------------------------------------------------

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
  local skill_dir = util.dir_of(skill.path)
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
-- Lua interpreter detection (cached at module load)
-- ---------------------------------------------------------------------------

local LUA_BIN = (function()
  if type(arg) == "table" and type(arg[-1]) == "string" and arg[-1] ~= "" then
    local candidate = arg[-1]
    if not candidate:find("[%s%(%)%;]") then
      return candidate
    end
  end

  local candidates = { "lua", "lua5.4", "lua5.3", "lua5.2", "lua5.1", "luajit" }
  for _, name in ipairs(candidates) do
    local ok = os.execute(name .. " -e 'os.exit(0)' >/dev/null 2>&1")
    if ok == true or ok == 0 then
      return name
    end
  end

  return nil
end)()

local TIMEOUT_BIN = (function()
  for _, name in ipairs({ "timeout", "gtimeout" }) do
    local ok = os.execute(name .. " 0 true >/dev/null 2>&1")
    if ok == true or ok == 0 then
      return name
    end
  end
  return nil
end)()

-- ---------------------------------------------------------------------------
-- skill_runner.run_tests
-- ---------------------------------------------------------------------------

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

  if not LUA_BIN then
    return nil, "skill_runner.run_tests: no Lua interpreter found on PATH"
  end

  local safe_path = "'" .. test_file_path:gsub("'", "'\\''") .. "'"

  local cmd
  if TIMEOUT_BIN then
    cmd = string.format(
      "%s %d %s %s 2>&1",
      TIMEOUT_BIN,
      math.ceil(timeout_seconds),
      LUA_BIN,
      safe_path
    )
  else
    cmd = string.format("%s %s 2>&1", LUA_BIN, safe_path)
  end

  local handle = io.popen(cmd, "r")
  if not handle then
    return nil, "skill_runner.run_tests: failed to start subprocess"
  end

  local output = handle:read("*a")
  local ok, exit_type, exit_code = handle:close()

  if type(ok) == "number" then
    exit_code = ok
    ok = (exit_code == 0)
  else
    exit_code = exit_code or (ok and 0 or 1)
  end

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
--- Now delegates ALL path matching to safe_fs (single source of truth).
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
  local code, read_err = util.read_file(skill_path)
  if not code then
    return false, { "cannot read skill file: " .. tostring(read_err) }
  end

  local skill_dir = util.dir_of(skill_path)
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

  -- 4. Verify declared paths against policy using safe_fs (single authority)
  local allowed = cfg.allowed_paths or {}
  local blocked = cfg.blocked_paths or {}

  for _, path_pattern in ipairs(meta.paths or {}) do
    -- Normalise the declared path for checking, preserving any trailing wildcard
    local has_glob = path_pattern:find("/%*$")
    local abs_path = util.normalize(path_pattern:gsub("/%*$", ""))
    local check_path = has_glob and (abs_path .. "/*") or abs_path

    -- Check blocked
    local is_blocked = false
    for _, bp in ipairs(blocked) do
      if safe_fs.glob_match(check_path, bp) then
        err("declared path '" .. path_pattern .. "' is blocked by: " .. bp)
        is_blocked = true
        break
      end
    end

    -- Check allowed
    if not is_blocked then
      local is_allowed = false
      for _, ap in ipairs(allowed) do
        if safe_fs.glob_match(check_path, ap) then
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
