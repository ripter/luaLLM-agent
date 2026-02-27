--- src/util.lua
--- Shared utility functions for luallm-agent.
--- Centralises common operations that were previously copy-pasted across modules.
--- Rocks: penlight, luafilesystem (lfs)

local pl_path = require("pl.path")
local pl_file = require("pl.file")
local pl_dir  = require("pl.dir")
local lfs     = require("lfs")

local M = {}

-- ---------------------------------------------------------------------------
-- File I/O
-- ---------------------------------------------------------------------------

--- Read an entire file to a string, or return nil + error.
--- Wraps pl.file.read which returns (content) or (nil, err_msg).
function M.read_file(path)
  return pl_file.read(path)
end

--- Write a string to a file atomically (write to .tmp, then rename).
--- Returns (true) or (nil, error_string).
function M.write_file_atomic(path, content)
  local tmp = path .. ".tmp"
  local f, err = io.open(tmp, "w")
  if not f then
    return nil, "cannot write " .. tmp .. ": " .. (err or "")
  end
  f:write(content)
  f:close()
  local ok, rerr = os.rename(tmp, path)
  if not ok then
    os.remove(tmp)
    return nil, "rename failed: " .. (rerr or "")
  end
  return true
end

-- ---------------------------------------------------------------------------
-- Path operations
-- ---------------------------------------------------------------------------

--- Join two path segments cleanly.
--- Delegates to pl.path.join.
function M.path_join(a, b)
  return pl_path.join(a, b)
end

--- Return the directory portion of a file path.
--- Delegates to pl.path.dirname.
function M.dir_of(filepath)
  return pl_path.dirname(filepath)
end

--- Expand a leading ~ to $HOME in a string.
--- Delegates to pl.path.expanduser.
function M.expand_tilde(s)
  if type(s) ~= "string" then return s end
  return pl_path.expanduser(s)
end

--- Resolve a path to an absolute, normalised form.
--- Handles leading ~, relative paths, . and .. segments.
--- Strips trailing slashes (a trailing / is ambiguous).
function M.normalize(path)
  -- Strip trailing slashes
  path = path:gsub("/+$", "")
  if path == "" then path = "/" end

  -- Expand ~
  path = pl_path.expanduser(path)

  -- Make absolute
  if not pl_path.isabs(path) then
    path = pl_path.join(lfs.currentdir(), path)
  end

  -- Resolve . and .. by walking segments manually.
  -- pl.path.normpath does NOT collapse .. above root, so we do it ourselves.
  local parts = {}
  for seg in path:gmatch("[^/]+") do
    if seg == "." then
      -- skip
    elseif seg == ".." then
      if #parts > 0 then
        parts[#parts] = nil
      end
      -- at filesystem root, ignore extra ..
    else
      parts[#parts + 1] = seg
    end
  end

  return "/" .. table.concat(parts, "/")
end

--- Ensure a directory and all parents exist.
--- Delegates to pl.dir.makepath.
--- Returns (true) or (nil, error_string).
function M.mkdir_p(path)
  local ok, err = pl_dir.makepath(path)
  if not ok then
    return nil, "mkdir_p failed for " .. path .. ": " .. tostring(err)
  end
  return true
end

-- ---------------------------------------------------------------------------
-- Time
-- ---------------------------------------------------------------------------

--- Return current time as an ISO 8601 string (UTC, second precision).
function M.iso8601()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

-- ---------------------------------------------------------------------------
-- Shell
-- ---------------------------------------------------------------------------

--- Escape a path for safe embedding in a double-quoted shell argument.
--- Doubles any embedded double-quote characters.
function M.shell_quote(path)
  return '"' .. path:gsub('"', '\\"') .. '"'
end

-- ---------------------------------------------------------------------------
-- Module loading
-- ---------------------------------------------------------------------------

--- Attempt to require a module; return the module or nil on failure.
--- Useful for optional dependencies.
function M.try_require(name)
  local ok, mod = pcall(require, name)
  return ok and mod or nil
end

-- ---------------------------------------------------------------------------
-- Table utilities
-- ---------------------------------------------------------------------------

--- Return true if a table is an array (all keys are consecutive integers 1..n).
function M.is_array(t)
  if type(t) ~= "table" then return false end
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n == #t
end

--- Deep-merge src into dst.  src values win; tables are merged recursively.
--- Arrays (integer-keyed tables) are replaced wholesale, not merged element-wise.
function M.deep_merge(dst, src)
  local out = {}
  for k, v in pairs(dst) do out[k] = v end
  for k, v in pairs(src) do
    if type(v) == "table" and type(out[k]) == "table"
       and not M.is_array(v) and not M.is_array(out[k]) then
      out[k] = M.deep_merge(out[k], v)
    else
      out[k] = v
    end
  end
  return out
end

--- Deep-copy a table (or return non-table values unchanged).
function M.deep_copy(src)
  if type(src) ~= "table" then return src end
  local out = {}
  for k, v in pairs(src) do
    out[k] = M.deep_copy(v)
  end
  return out
end

--- Recursively expand ~ in all string values within a table.
function M.expand_paths(tbl)
  if type(tbl) ~= "table" then return tbl end
  local out = {}
  for k, v in pairs(tbl) do
    if type(v) == "string" then
      out[k] = M.expand_tilde(v)
    elseif type(v) == "table" then
      out[k] = M.expand_paths(v)
    else
      out[k] = v
    end
  end
  return out
end

return M
