local cjson = require("cjson.safe")
local lfs   = require("lfs")
local util  = require("util")

local M = {}

-- ---------------------------------------------------------------------------
-- Internal state
-- ---------------------------------------------------------------------------

local state_dir = nil

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

  local ok, err = util.mkdir_p(dir)
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

  local path = util.path_join(state_dir, "current_task.json")
  local content = cjson.encode(task)

  return util.write_file_atomic(path, content)
end

function M.load()
  if not state_dir then
    error("state not initialized: call state.init() first")
  end

  local path = util.path_join(state_dir, "current_task.json")
  local raw, err = util.read_file(path)

  if not raw then
    if err and (err:match("No such file") or err:match("cannot open")) then
      return nil -- file does not exist is not an error
    end
    return nil, "cannot read state file: " .. tostring(err)
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

  local path = util.path_join(state_dir, "current_task.json")
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

  local path = util.path_join(state_dir, "current_task.json")
  local attr = lfs.attributes(path)
  return attr ~= nil and attr.mode == "file"
end

return M
