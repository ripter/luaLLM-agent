--- src/safe_fs.lua
--- Filesystem write safety: path normalisation, glob policy, symlink check.
--- THE single authority for path matching across the entire codebase.
--- Rocks: luafilesystem (lfs), penlight

local lfs  = require("lfs")
local util = require("util")

local M = {}

-- ---------------------------------------------------------------------------
-- Path normalisation (delegates to util.normalize)
-- ---------------------------------------------------------------------------

M.normalize = util.normalize

-- ---------------------------------------------------------------------------
-- Glob → Lua pattern conversion
-- ---------------------------------------------------------------------------

--- Convert a glob pattern string to a Lua pattern anchored at ^ and $.
--- Supports * (any sequence incl. /), ? (any single char), [...] passthrough.
local function glob_to_lua_pattern(glob)
  local result = { "^" }
  local i = 1
  local len = #glob

  while i <= len do
    local c = glob:sub(i, i)

    if c == "[" then
      local j = glob:find("]", i + 1, true)
      if j then
        result[#result + 1] = glob:sub(i, j)
        i = j + 1
      else
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
--- A pattern with no wildcard or trailing slash is treated as a directory prefix:
--- it implicitly covers all paths beneath it, without requiring the directory
--- to exist on disk at policy-evaluation time.
local function normalise_pattern(pat)
  local expanded = util.expand_tilde(pat)
  if not expanded:match("[*?]") and not expanded:match("/$") then
    return pat .. "/*"
  end
  return pat
end

--- Return true if the normalised absolute path matches the glob pattern.
--- This is the SINGLE source of truth for path matching in the project.
--- A pattern with no wildcard matches the path exactly OR as a directory prefix
--- (i.e. the path is the directory itself, or a file/directory inside it).
function M.glob_match(abs_path, glob)
  local normalised = util.normalize(util.expand_tilde(glob))
  if not normalised:match("[*?]") then
    -- Exact match
    local exact_pat = glob_to_lua_pattern(normalised)
    if abs_path:match(exact_pat) then return true end
    -- Prefix match: treat the pattern as a directory, match anything inside
    local prefix_pat = glob_to_lua_pattern(normalised .. "/*")
    return abs_path:match(prefix_pat) ~= nil
  end
  local pat = glob_to_lua_pattern(normalised)
  return abs_path:match(pat) ~= nil
end

--- Simpler prefix-based path matching for use by the sandbox.
--- Supports exact match, prefix match, and trailing-glob (/*) match.
--- Does NOT normalise or expand tilde (sandbox paths are already resolved).
function M.prefix_match(resolved_path, patterns)
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
-- Symlink check
-- ---------------------------------------------------------------------------

local function check_no_symlink_dirs(abs_path)
  local parts = {}
  for seg in abs_path:gmatch("[^/]+") do
    parts[#parts + 1] = seg
  end

  local acc = ""
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

function M.validate_policy(allowed_patterns, blocked_patterns)
  if type(allowed_patterns) ~= "table" or #allowed_patterns == 0 then
    return nil, "allowed_paths is empty or missing — all writes denied by default"
  end

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

function M.is_allowed(target_path, allowed_patterns, blocked_patterns)
  local ok, err = M.validate_policy(allowed_patterns, blocked_patterns)
  if not ok then
    return false, "policy invalid: " .. err
  end

  local abs = util.normalize(target_path)

  local sym_ok, sym_err = check_no_symlink_dirs(abs)
  if not sym_ok then
    return false, sym_err
  end

  if type(blocked_patterns) == "table" then
    for _, pat in ipairs(blocked_patterns) do
      if M.glob_match(abs, pat) then
        return false, "path matches blocked pattern: " .. pat
      end
    end
  end

  for _, pat in ipairs(allowed_patterns) do
    if M.glob_match(abs, pat) then
      return true, nil
    end
  end

  return false, "path does not match any allowed_paths pattern"
end

-- ---------------------------------------------------------------------------
-- Safe file write
-- ---------------------------------------------------------------------------

function M.write_file(target_path, content, allowed_patterns, blocked_patterns)
  local ok, err = M.is_allowed(target_path, allowed_patterns, blocked_patterns)
  if not ok then
    return nil, "write denied: " .. err
  end

  local abs = util.normalize(target_path)

  local target_attr = lfs.attributes(abs)
  if target_attr and target_attr.mode == "directory" then
    return nil, "output path is a directory, not a file: " .. abs
  end

  local parent = abs:match("^(.*)/[^/]*$") or "/"
  local attr   = lfs.attributes(parent)
  if not attr or attr.mode ~= "directory" then
    return nil, "parent directory does not exist: " .. parent
  end

  return util.write_file_atomic(abs, content)
end

return M
