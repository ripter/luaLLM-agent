--- src/sandbox.lua
--- Execute untrusted Lua code in a restricted environment.
--- Rocks: luafilesystem (lfs)

local lfs     = require("lfs")
local safe_fs = require("safe_fs")

local M = {}

-- ---------------------------------------------------------------------------
-- Internal constants
-- ---------------------------------------------------------------------------

local MAX_OPEN_HANDLES     = 10
local DEFAULT_TIMEOUT_SEC  = 30
local INSTRUCTIONS_PER_SEC = 1000000

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

--- Resolve a path to an absolute, normalised form.
--- Unlike util.normalize, this does NOT expand ~ (sandboxed code must not
--- know about $HOME). It only resolves relative paths and collapses . and ..
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

-- ---------------------------------------------------------------------------
-- sandbox.make_io
-- ---------------------------------------------------------------------------

function M.make_io(declared_paths, allowed_paths, log_fn, skill_name)
  local open_handles = 0

  --- Validate that a resolved path is permitted by both lists.
  --- Uses safe_fs.prefix_match — the shared path matching implementation.
  local function check_path(path, mode)
    local resolved, err = resolve_path(path)
    if not resolved then
      return nil, "sandbox.io: invalid path: " .. tostring(err)
    end

    if not safe_fs.prefix_match(resolved, declared_paths) then
      return nil, "sandbox.io: path not in skill's declared paths: " .. resolved
    end

    if not safe_fs.prefix_match(resolved, allowed_paths) then
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

  function sio.close(handle)
    if handle then
      handle:close()
      if open_handles > 0 then
        open_handles = open_handles - 1
      end
    end
  end

  function sio.open_count()
    return open_handles
  end

  return sio
end

-- ---------------------------------------------------------------------------
-- sandbox.make_require
-- ---------------------------------------------------------------------------

function M.make_require(declared_deps, allowed_dir)
  local dep_set = {}
  for _, name in ipairs(declared_deps or {}) do
    dep_set[name] = true
  end

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

    local dep_env = M.make_env({
      paths         = {},
      allowed_paths = {},
      dependencies  = {},
      allowed_dir   = allowed_dir,
      log_fn        = nil,
      skill_name    = modname,
    })

    if setfenv then
      setfenv(chunk, dep_env)
    else
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

    -- Captured print
    print = function(...)
      local parts = {}
      for i = 1, select("#", ...) do
        parts[#parts + 1] = tostring(select(i, ...))
      end
      captured_output[#captured_output + 1] = table.concat(parts, "\t")
    end,

    log = opts.log_fn,
    _captured_output = captured_output,
  }

  return env
end

-- ---------------------------------------------------------------------------
-- sandbox.execute
-- ---------------------------------------------------------------------------

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

  local chunk, load_err
  if setfenv then
    chunk, load_err = loadstring(code_string, "=sandbox")
    if chunk then
      setfenv(chunk, env)
    end
  else
    chunk, load_err = load(code_string, "=sandbox", "t", env)
  end

  if not chunk then
    return nil, "sandbox.execute: compilation failed: " .. tostring(load_err)
  end

  local instruction_count = 0
  local timed_out = false

  local function hook()
    instruction_count = instruction_count + 1
    if instruction_count > max_instructions then
      timed_out = true
      error("sandbox.execute: instruction limit exceeded (timeout " .. timeout_seconds .. "s)")
    end
  end

  debug.sethook(hook, "", 1000)

  local ok, result = pcall(chunk)

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
