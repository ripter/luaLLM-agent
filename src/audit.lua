--- src/audit.lua
--- Append-only JSONL audit logger with rotation support.
--- Rocks: cjson (cjson.safe), luafilesystem (lfs)

local cjson = require("cjson.safe")
local lfs   = require("lfs")

local M = {}

-- ---------------------------------------------------------------------------
-- Internal state
-- ---------------------------------------------------------------------------

local log_path  = nil   -- absolute path to the active log file
local task_id   = nil   -- current task context (set by set_task_id)

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

--- Return current time as an ISO 8601 string (UTC, second precision).
--- os.date with "!" prefix uses UTC.
local function iso8601()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

--- Return the size of a file in bytes, or 0 if it does not exist.
local function file_size(path)
  local attr = lfs.attributes(path, "size")
  return attr or 0
end

--- Rename src to dst. Silently succeeds if src does not exist.
local function rename(src, dst)
  if lfs.attributes(src) then
    os.rename(src, dst)
  end
end

--- Delete a file. Silently succeeds if it does not exist.
local function delete(path)
  if lfs.attributes(path) then
    os.remove(path)
  end
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Set the log file path and create the file if it does not exist.
--- Must be called before log() or rotate().
--- Returns true on success or (nil, error_string) on failure.
function M.init(path)
  if type(path) ~= "string" or path == "" then
    return nil, "audit.init: path must be a non-empty string"
  end

  -- Create the file if missing (open in append mode and close immediately).
  local f, err = io.open(path, "a")
  if not f then
    return nil, "audit.init: cannot open log file '" .. path .. "': " .. tostring(err)
  end
  f:close()

  log_path = path
  return true
end

--- Set the current task ID embedded in every subsequent log line.
--- Pass nil to clear.
function M.set_task_id(id)
  task_id = id
end

--- Append one JSON line to the log:
---   {"ts":"<ISO8601>","event":"<event>","task_id":<id_or_null>,"data":<data>}
--- Returns true on success or (nil, error_string) on failure.
--- Never raises — errors are returned, not thrown.
function M.log(event, data)
  if not log_path then
    return nil, "audit.log: logger not initialised (call audit.init first)"
  end

  if type(event) ~= "string" or event == "" then
    return nil, "audit.log: event must be a non-empty string"
  end

  local entry = {
    ts      = iso8601(),
    event   = event,
    task_id = (task_id ~= nil) and task_id or cjson.null,
    data    = data,
  }

  local line, encode_err = cjson.encode(entry)
  if not line then
    return nil, "audit.log: JSON encode failed: " .. tostring(encode_err)
  end

  local f, open_err = io.open(log_path, "a")
  if not f then
    return nil, "audit.log: cannot open log file: " .. tostring(open_err)
  end

  f:write(line .. "\n")
  f:flush()
  f:close()

  return true
end

--- Rotate the log file if it exceeds max_size_mb megabytes.
---
--- Rotation scheme (same as logrotate's default):
---   current      → .1
---   .1           → .2
---   …
---   .(max_files-1) → .max_files   (then deleted if already at max_files)
---
--- The active log file is left empty and ready for new writes after rotation.
--- Returns true (even if no rotation was needed) or (nil, error_string).
function M.rotate(max_size_mb, max_files)
  if not log_path then
    return nil, "audit.rotate: logger not initialised (call audit.init first)"
  end

  if type(max_size_mb) ~= "number" or max_size_mb <= 0 then
    return nil, "audit.rotate: max_size_mb must be a positive number"
  end

  if type(max_files) ~= "number" or max_files < 1 then
    return nil, "audit.rotate: max_files must be a positive integer"
  end

  max_files = math.floor(max_files)

  local size_bytes = file_size(log_path)
  local limit_bytes = max_size_mb * 1024 * 1024

  if size_bytes <= limit_bytes then
    return true  -- nothing to do
  end

  -- Shift existing numbered backups up by one, dropping anything beyond max_files.
  -- Work from the highest number downward to avoid clobbering.
  for i = max_files - 1, 1, -1 do
    local src = log_path .. "." .. i
    local dst = log_path .. "." .. (i + 1)
    if i + 1 > max_files then
      delete(src)
    else
      rename(src, dst)
    end
  end

  -- Rename the current log to .1.
  local ok, ren_err = os.rename(log_path, log_path .. ".1")
  if not ok then
    return nil, "audit.rotate: failed to rename log file: " .. tostring(ren_err)
  end

  -- Create a fresh empty log file.
  local f, open_err = io.open(log_path, "w")
  if not f then
    return nil, "audit.rotate: failed to create new log file: " .. tostring(open_err)
  end
  f:close()

  return true
end

return M
