--- src/sandbox.lua
--- Execute untrusted Lua code in a restricted environment.
--- Rocks: luafilesystem (lfs)

local lfs = require("lfs")

local M = {}

-- ---------------------------------------------------------------------------
-- Internal constants
-- ---------------------------------------------------------------------------

local MAX_OPEN_HANDLES     = 10
local DEFAULT_TIMEOUT_SEC  = 30
local INSTRUCTIONS_PER_SEC = 1000000   -- calibration: ~1 M instructions/sec

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

--- Resolve a path to an absolute, normalised form.
--- Collapses /./, /../, and resolves relative paths against lfs.currentdir().
local function resolve_path(path)
  if type(path) ~= "string" or path == "" then
    return nil, "path must be a non-empty string"
  end

  -- Make absolute
  if path:sub(1, 1) ~= "/" then
    path = lfs.currentdir() .. "/" .. path
  end

  -- Normalise: split on /, collapse . and ..
  local parts = {}
  for seg in path:gmatch("[^/]+") do
    if seg == "." then
      -- skip
    elseif seg == ".." then
      if #parts > 0 then
        parts[#parts] = nil
      end
    else
      parts[#parts + 1] = seg
    end
  end

  return "/" .. table.concat(parts, "/")
end

--- Check whether resolved_path matches any entry in a list of path patterns.
--- Supports exact match, prefix match, and trailing-glob (/*) match.
local function path_matches(resolved_path, patterns)
  for _, pattern in ipairs(patterns or {}) do
    local prefix = pattern:gsub("/%*$", "")
    if resolved_path == prefix
       or resolved_path:sub(1, #prefix + 1) == prefix .. "/" then
      return true, pattern
    end
  end
  return false
end

-- ---------------------------------------------------------------------------
-- sandbox.make_io
-- ---------------------------------------------------------------------------

--- Build a restricted io table whose open/lines/close respect declared and
--- allowed path lists. Tracks open handles and enforces a maximum count.
---
--- @param declared_paths  list of path patterns the skill declared
--- @param allowed_paths   list of globally allowed path patterns (from config)
--- @param log_fn          function(event, data) for audit logging
--- @param skill_name      string used as context in log entries
--- @return table  restricted io-like table
function M.make_io(declared_paths, allowed_paths, log_fn, skill_name)
  local open_handles = 0

  --- Validate that a resolved path is permitted by both lists.
  local function check_path(path, mode)
    local resolved, err = resolve_path(path)
    if not resolved then
      return nil, "sandbox.io: invalid path: " .. tostring(err)
    end

    if not path_matches(resolved, declared_paths) then
      return nil, "sandbox.io: path not in skill's declared paths: " .. resolved
    end

    if not path_matches(resolved, allowed_paths) then
      return nil, "sandbox.io: path not in global allowed_paths: " .. resolved
    end

    if log_fn then
      log_fn("sandbox.io.access", {
        skill  = skill_name,
        path   = resolved,
        mode   = mode or "r",
      })
    end

    return resolved
  end

  local sio = {}

  --- Open a file after path checks. Honours the handle limit.
  --- @param path string
  --- @param mode string|nil  (defaults to "r")
  --- @return file handle or nil + error
  function sio.open(path, mode)
    mode = mode or "r"

    local resolved, err = check_path(path, mode)
    if not resolved then return nil, err end

    if open_handles >= MAX_OPEN_HANDLES then
      return nil, "sandbox.io: too many open handles (limit " .. MAX_OPEN_HANDLES .. ")"
    end

    local fh, open_err = io.open(resolved, mode)
    if not fh then
      return nil, "sandbox.io: cannot open '" .. resolved .. "': " .. tostring(open_err)
    end

    open_handles = open_handles + 1
    return fh
  end

  --- Return an iterator over lines of a file after path checks.
  --- @param path string
  --- @return iterator or nil + error
  function sio.lines(path)
    local resolved, err = check_path(path, "r")
    if not resolved then return nil, err end

    if open_handles >= MAX_OPEN_HANDLES then
      return nil, "sandbox.io: too many open handles (limit " .. MAX_OPEN_HANDLES .. ")"
    end

    local ok, iter = pcall(io.lines, resolved)
    if not ok then
      return nil, "sandbox.io: cannot open '" .. resolved .. "' for lines: " .. tostring(iter)
    end

    open_handles = open_handles + 1
    -- io.lines auto-closes, so we wrap to track the decrement.
    local finished = false
    return function()
      local line = iter()
      if line == nil and not finished then
        finished = true
        open_handles = open_handles - 1
      end
      return line
    end
  end

  --- Close a file handle and decrement the open count.
  --- @param handle file handle
  function sio.close(handle)
    if handle then
      handle:close()
      if open_handles > 0 then
        open_handles = open_handles - 1
      end
    end
  end

  --- Return the current number of open handles (for testing).
  function sio.open_count()
    return open_handles
  end

  return sio
end

-- ---------------------------------------------------------------------------
-- sandbox.make_require
-- ---------------------------------------------------------------------------

--- Build a restricted require function that only loads modules explicitly
--- listed in declared_deps, and only from allowed_dir.
---
--- @param declared_deps  list of module name strings the skill may require
--- @param allowed_dir    directory from which to load <modname>.lua files
--- @return function  restricted require replacement
function M.make_require(declared_deps, allowed_dir)
  -- Build a set for O(1) lookup.
  local dep_set = {}
  for _, name in ipairs(declared_deps or {}) do
    dep_set[name] = true
  end

  -- Cache loaded modules to avoid re-executing.
  local module_cache = {}

  local function sandboxed_require(modname)
    if type(modname) ~= "string" or modname == "" then
      error("sandbox.require: module name must be a non-empty string", 2)
    end

    if not dep_set[modname] then
      error("sandbox.require: module '" .. modname .. "' is not in declared dependencies", 2)
    end

    if module_cache[modname] then
      return module_cache[modname]
    end

    local filepath = allowed_dir .. "/" .. modname .. ".lua"
    local attr = lfs.attributes(filepath)
    if not attr then
      error("sandbox.require: module file not found: " .. filepath, 2)
    end

    local chunk, load_err = loadfile(filepath)
    if not chunk then
      error("sandbox.require: failed to load '" .. filepath .. "': " .. tostring(load_err), 2)
    end

    -- Run the loaded chunk in a minimal restricted env (recursive sandbox).
    local dep_env = M.make_env({
      paths         = {},
      allowed_paths = {},
      dependencies  = {},
      allowed_dir   = allowed_dir,
      log_fn        = nil,
      skill_name    = modname,
    })

    if setfenv then                -- Lua 5.1
      setfenv(chunk, dep_env)
    else                           -- Lua 5.2+
      -- loadfile doesn't accept env in all builds; use debug.setupvalue
      debug.setupvalue(chunk, 1, dep_env)
    end

    local ok, result = pcall(chunk)
    if not ok then
      error("sandbox.require: error executing '" .. modname .. "': " .. tostring(result), 2)
    end

    module_cache[modname] = result or true
    return module_cache[modname]
  end

  return sandboxed_require
end

-- ---------------------------------------------------------------------------
-- sandbox.make_env
-- ---------------------------------------------------------------------------

--- Build a restricted _ENV / environment table for untrusted code.
---
--- opts fields:
---   paths         – list of path patterns the skill may access
---   allowed_paths – global allowed paths from config
---   dependencies  – list of module names the skill may require
---   allowed_dir   – directory to load dependency modules from
---   log_fn        – function(event, data) for audit logging (may be nil)
---   skill_name    – string identifying the skill (for logs)
---
--- @param opts table
--- @return table  restricted environment
function M.make_env(opts)
  opts = opts or {}

  local captured_output = {}

  local env = {
    -- Safe globals
    math        = math,
    string      = string,
    table       = table,
    pairs       = pairs,
    ipairs      = ipairs,
    next        = next,
    select      = select,
    type        = type,
    tostring    = tostring,
    tonumber    = tonumber,
    pcall       = pcall,
    xpcall      = xpcall,
    error       = error,
    assert      = assert,
    unpack      = unpack or table.unpack,

    -- Restricted io
    io = M.make_io(
      opts.paths         or {},
      opts.allowed_paths or {},
      opts.log_fn,
      opts.skill_name    or "unknown"
    ),

    -- Restricted require
    require = M.make_require(
      opts.dependencies or {},
      opts.allowed_dir  or "."
    ),

    -- Captured print — collects output for inspection.
    print = function(...)
      local parts = {}
      for i = 1, select("#", ...) do
        parts[#parts + 1] = tostring(select(i, ...))
      end
      captured_output[#captured_output + 1] = table.concat(parts, "\t")
    end,

    -- Audit log function available to skill code.
    log = opts.log_fn,

    -- Give code access to its captured output table.
    _captured_output = captured_output,
  }

  -- Explicitly NOT in env: os, debug, load, loadstring, loadfile, dofile,
  -- rawget, rawset, rawequal, collectgarbage, setfenv, getfenv, io (raw).

  return env
end

-- ---------------------------------------------------------------------------
-- sandbox.execute
-- ---------------------------------------------------------------------------

--- Load and execute a code string inside the given environment with a
--- CPU-time limit enforced via debug.sethook instruction counting.
---
--- @param code_string      string   Lua source to execute
--- @param env              table    environment table (from make_env)
--- @param timeout_seconds  number|nil  CPU budget in seconds (default 30)
--- @return true, result on success; nil, error_string on failure
function M.execute(code_string, env, timeout_seconds)
  if type(code_string) ~= "string" then
    return nil, "sandbox.execute: code_string must be a string"
  end
  if type(env) ~= "table" then
    return nil, "sandbox.execute: env must be a table"
  end

  timeout_seconds = timeout_seconds or DEFAULT_TIMEOUT_SEC
  if type(timeout_seconds) ~= "number" or timeout_seconds <= 0 then
    return nil, "sandbox.execute: timeout_seconds must be a positive number"
  end

  local max_instructions = math.floor(timeout_seconds * INSTRUCTIONS_PER_SEC)

  -- Load the code chunk.
  local chunk, load_err
  if setfenv then
    -- Lua 5.1: loadstring + setfenv
    chunk, load_err = loadstring(code_string, "=sandbox")
    if chunk then
      setfenv(chunk, env)
    end
  else
    -- Lua 5.2+: load accepts env directly
    chunk, load_err = load(code_string, "=sandbox", "t", env)
  end

  if not chunk then
    return nil, "sandbox.execute: compilation failed: " .. tostring(load_err)
  end

  -- Instruction-count hook to enforce CPU timeout.
  local instruction_count = 0
  local timed_out = false

  local function hook()
    instruction_count = instruction_count + 1
    if instruction_count > max_instructions then
      timed_out = true
      error("sandbox.execute: instruction limit exceeded (timeout " .. timeout_seconds .. "s)")
    end
  end

  -- Install hook: fire every 1000 instructions for reasonable granularity.
  debug.sethook(hook, "", 1000)

  local ok, result = pcall(chunk)

  -- Always remove the hook.
  debug.sethook()

  if not ok then
    if timed_out then
      return nil, "sandbox.execute: execution timed out (" .. timeout_seconds .. "s limit)"
    end
    return nil, "sandbox.execute: runtime error: " .. tostring(result)
  end

  return true, result
end

return M
