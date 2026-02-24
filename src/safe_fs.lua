--- src/safe_fs.lua
--- Filesystem write safety: path normalisation, glob policy, symlink check.
--- Rocks: luafilesystem (lfs)

local lfs = require("lfs")

local M = {}

-- ---------------------------------------------------------------------------
-- Path normalisation
-- ---------------------------------------------------------------------------

--- Join two path segments cleanly.
local function path_join(a, b)
  if a:sub(-1) == "/" then
    return a .. b
  end
  return a .. "/" .. b
end

--- Resolve a path to an absolute path without consulting the filesystem
--- (does not require the path to exist).  Handles leading ~, . and .. segments.
local function normalize(path)
  -- Strip trailing slashes — a path ending in / is ambiguous and always means
  -- "a directory", which is never a valid write target.
  path = path:gsub("/+$", "")
  if path == "" then path = "/" end

  -- Expand leading ~
  if path:sub(1, 1) == "~" then
    local home = os.getenv("HOME") or os.getenv("USERPROFILE") or ""
    path = home .. path:sub(2)
  end

  -- Make absolute
  if path:sub(1, 1) ~= "/" then
    path = path_join(lfs.currentdir(), path)
  end

  -- Resolve . and .. by walking segments
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

M.normalize = normalize  -- exported for tests

-- ---------------------------------------------------------------------------
-- Glob → Lua pattern conversion
-- ---------------------------------------------------------------------------

--- Convert a glob pattern string to a Lua pattern anchored at ^ and $.
--- Supports * (any sequence incl. /), ? (any single char), [...] passthrough.
local function glob_to_lua_pattern(glob)
  -- We build the pattern character by character so we can handle [...] blocks.
  local result = { "^" }
  local i = 1
  local len = #glob

  while i <= len do
    local c = glob:sub(i, i)

    if c == "[" then
      -- Pass bracket class through verbatim until closing ]
      local j = glob:find("]", i + 1, true)
      if j then
        result[#result + 1] = glob:sub(i, j)
        i = j + 1
      else
        -- Unclosed bracket — treat [ as literal
        result[#result + 1] = "%["
        i = i + 1
      end

    elseif c == "*" then
      result[#result + 1] = ".*"
      i = i + 1

    elseif c == "?" then
      result[#result + 1] = "."
      i = i + 1

    else
      -- Escape Lua magic characters (everything except * ? [ which we handled)
      if c:match("[%^%$%(%)%%%.%+%-%]%{%}]") then
        result[#result + 1] = "%" .. c
      else
        result[#result + 1] = c
      end
      i = i + 1
    end
  end

  result[#result + 1] = "$"
  return table.concat(result)
end

M.glob_to_lua_pattern = glob_to_lua_pattern  -- exported for tests

--- Normalise a glob pattern so bare directory paths match files inside them.
--- If the pattern (after ~ expansion) refers to an existing directory and
--- doesn't end with * or /, append /* so users don't have to.
local function normalise_pattern(pat)
  -- Expand ~ first so we can check the filesystem
  local expanded = pat
  if expanded:sub(1, 1) == "~" then
    local home = os.getenv("HOME") or os.getenv("USERPROFILE") or ""
    expanded = home .. expanded:sub(2)
  end
  -- If it doesn't already have a glob wildcard at the end, check if it's a dir
  if not expanded:match("[*?]$") and not expanded:match("/$") then
    local attr = lfs.attributes(expanded)
    if attr and attr.mode == "directory" then
      return pat .. "/*"
    end
  end
  return pat
end

--- Return true if the normalised path matches the glob pattern.
local function glob_match(path, glob)
  local pat = glob_to_lua_pattern(normalize(normalise_pattern(glob)))
  return path:match(pat) ~= nil
end

-- ---------------------------------------------------------------------------
-- Symlink check
-- ---------------------------------------------------------------------------

--- Return (true, nil) if no path segment leading to `path` is a symlink,
--- or (false, reason) if a symlinked directory is detected.
--- We check every directory component of the absolute normalised path.
local function check_no_symlink_dirs(abs_path)
  -- Build each parent prefix and check it.
  local parts = {}
  for seg in abs_path:gmatch("[^/]+") do
    parts[#parts + 1] = seg
  end

  local acc = ""
  -- Check all segments except the final filename (symlinked files are OK to
  -- detect at write time; we care about traversal via symlinked directories).
  for i = 1, #parts - 1 do
    acc = acc .. "/" .. parts[i]
    local attr = lfs.symlinkattributes and lfs.symlinkattributes(acc)
    if attr and attr.mode == "link" then
      return false, "symlinked directory in path not allowed for safety: " .. acc
    end
  end
  return true
end

-- ---------------------------------------------------------------------------
-- Policy validation
-- ---------------------------------------------------------------------------

--- Validate the policy tables.
--- Returns (true, nil) on success, or (nil, error_string) on failure.
function M.validate_policy(allowed_patterns, blocked_patterns)
  -- allowed_paths must be non-empty
  if type(allowed_patterns) ~= "table" or #allowed_patterns == 0 then
    return nil, "allowed_paths is empty or missing — all writes denied by default"
  end

  -- Check for exact pattern string overlap
  if type(blocked_patterns) == "table" then
    local allowed_set = {}
    for _, p in ipairs(allowed_patterns) do
      allowed_set[p] = true
    end
    local overlaps = {}
    for _, p in ipairs(blocked_patterns) do
      if allowed_set[p] then
        overlaps[#overlaps + 1] = p
      end
    end
    if #overlaps > 0 then
      return nil, "policy conflict: pattern(s) appear in both allowed_paths and blocked_paths: "
               .. table.concat(overlaps, ", ")
    end
  end

  return true
end

-- ---------------------------------------------------------------------------
-- Path allow/deny check
-- ---------------------------------------------------------------------------

--- Check whether target_path is permitted by the policy.
--- Returns (true, nil) if allowed, or (false, reason) if denied.
function M.is_allowed(target_path, allowed_patterns, blocked_patterns)
  -- 1. Validate policy first
  local ok, err = M.validate_policy(allowed_patterns, blocked_patterns)
  if not ok then
    return false, "policy invalid: " .. err
  end

  -- 2. Normalise target
  local abs = normalize(target_path)

  -- 3. Symlink check on directory components
  local sym_ok, sym_err = check_no_symlink_dirs(abs)
  if not sym_ok then
    return false, sym_err
  end

  -- 4. Blocked overrides everything
  if type(blocked_patterns) == "table" then
    for _, pat in ipairs(blocked_patterns) do
      if glob_match(abs, pat) then
        return false, "path matches blocked pattern: " .. pat
      end
    end
  end

  -- 5. Must match at least one allowed pattern
  for _, pat in ipairs(allowed_patterns) do
    if glob_match(abs, pat) then
      return true, nil
    end
  end

  return false, "path does not match any allowed_paths pattern"
end

-- ---------------------------------------------------------------------------
-- Safe file write
-- ---------------------------------------------------------------------------

--- Write content to target_path only if the policy permits it.
--- The parent directory must already exist; we do not auto-create directories.
--- Returns (true, nil) on success, or (nil, error_string) on failure.
function M.write_file(target_path, content, allowed_patterns, blocked_patterns)
  -- Policy check
  local ok, err = M.is_allowed(target_path, allowed_patterns, blocked_patterns)
  if not ok then
    return nil, "write denied: " .. err
  end

  local abs = normalize(target_path)

  -- Refuse if the resolved path is an existing directory
  local target_attr = lfs.attributes(abs)
  if target_attr and target_attr.mode == "directory" then
    return nil, "output path is a directory, not a file: " .. abs
  end

  -- Parent directory must exist
  local parent = abs:match("^(.*)/[^/]*$") or "/"
  local attr   = lfs.attributes(parent)
  if not attr or attr.mode ~= "directory" then
    return nil, "parent directory does not exist: " .. parent
  end

  -- Atomic write: write to .tmp then rename
  local tmp = abs .. ".tmp"
  local f, open_err = io.open(tmp, "w")
  if not f then
    return nil, "cannot open for writing: " .. tostring(open_err)
  end

  local write_ok, write_err = f:write(content)
  f:close()

  if not write_ok then
    os.remove(tmp)
    return nil, "write failed: " .. tostring(write_err)
  end

  local rename_ok, rename_err = os.rename(tmp, abs)
  if not rename_ok then
    os.remove(tmp)
    return nil, "rename failed: " .. tostring(rename_err)
  end

  return true, nil
end

return M
