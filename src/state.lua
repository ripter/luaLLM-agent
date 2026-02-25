local cjson = require("cjson.safe")
local lfs   = require("lfs")

local M = {}

-- ---------------------------------------------------------------------------
-- Internal state
-- ---------------------------------------------------------------------------

local state_dir = nil

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function path_join(a, b)
  if a:sub(-1) == "/" then
    return a .. b
  end
  return a .. "/" .. b
end

local function read_file(path)
  local f, err = io.open(path, "r")
  if not f then return nil, err end
  local content = f:read("*a")
  f:close()
  return content
end

local function write_file_atomic(path, content)
  local tmp = path .. ".tmp"
  local f, err = io.open(tmp, "w")
  if not f then return nil, "cannot write " .. tmp .. ": " .. (err or "") end
  f:write(content)
  f:close()
  local ok, rerr = os.rename(tmp, path)
  if not ok then
    os.remove(tmp)
    return nil, "rename failed: " .. (rerr or "")
  end
  return true
end

local function ensure_dir(path)
  local attr = lfs.attributes(path)
  if not attr then
    local ok, err = lfs.mkdir(path)
    if not ok then
      return nil, "cannot create directory " .. path .. ": " .. (err or "")
    end
  elseif attr.mode ~= "directory" then
    return nil, path .. " exists but is not a directory"
  end
  return true
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function M.dir()
  return state_dir
end

function M.init(dir)
  if not dir then
    error("state.init() requires a directory path")
  end

  local ok, err = ensure_dir(dir)
  if not ok then
    return nil, err
  end

  state_dir = dir
  return true
end

function M.save(task)
  if not state_dir then
    error("state not initialized: call state.init() first")
  end

  if type(task) ~= "table" then
    return nil, "task must be a table"
  end

  local path = path_join(state_dir, "current_task.json")
  local content = cjson.encode(task)

  return write_file_atomic(path, content)
end

function M.load()
  if not state_dir then
    error("state not initialized: call state.init() first")
  end

  local path = path_join(state_dir, "current_task.json")
  local raw, err = read_file(path)

  if not raw then
    if err:match("No such file") or err:match("cannot open") then
      return nil -- file does not exist is not an error
    end
    return nil, "cannot read state file: " .. err
  end

  local ok, parsed = pcall(cjson.decode, raw)
  if not ok then
    return nil, "corrupt"
  end

  return parsed
end

function M.clear()
  if not state_dir then
    error("state not initialized: call state.init() first")
  end

  local path = path_join(state_dir, "current_task.json")
  local tmp  = path .. ".tmp"

  local attr = lfs.attributes(path)
  if attr then
    os.remove(path)
  end

  attr = lfs.attributes(tmp)
  if attr then
    os.remove(tmp)
  end

  return true
end

function M.exists()
  if not state_dir then
    error("state not initialized: call state.init() first")
  end

  local path = path_join(state_dir, "current_task.json")
  local attr = lfs.attributes(path)
  return attr ~= nil and attr.mode == "file"
end

return M