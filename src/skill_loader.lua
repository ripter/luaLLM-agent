--- src/skill_loader.lua
--- Load skill files, parse metadata headers, resolve dependencies.
--- Rocks: luafilesystem (lfs), penlight

local lfs  = require("lfs")
local util = require("util")

local M = {}

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

--- Read a file line by line into a table.
local function read_lines(path)
  local lines = {}
  local f, err = io.open(path, "r")
  if not f then return nil, err end
  for line in f:lines() do
    lines[#lines + 1] = line
  end
  f:close()
  return lines
end

--- Check whether a path has a .lua extension (case-sensitive).
local function is_lua_file(name)
  return type(name) == "string" and name:sub(-4) == ".lua"
end

--- Check whether a filename is a test file (*_test.lua).
local function is_test_file(name)
  return type(name) == "string" and name:match("_test%.lua$") ~= nil
end

-- ---------------------------------------------------------------------------
-- Metadata parsing
-- ---------------------------------------------------------------------------

local function extract_metadata_text(lines)
  local in_block = false
  local parts    = {}

  for _, line in ipairs(lines) do
    if not in_block then
      local stripped = line:match("^%-%-%-%s*(.*)$")
      if stripped and stripped:match("^@skill") then
        in_block = true
        local after = stripped:match("^@skill%s*(.*)$")
        if after and after ~= "" then
          parts[#parts + 1] = after
        end
      end
    else
      local stripped = line:match("^%-%-%-%s?(.*)$")
      if stripped then
        parts[#parts + 1] = stripped
      else
        break
      end
    end
  end

  if #parts == 0 then
    return nil, "no @skill metadata block found"
  end

  return table.concat(parts, "\n")
end

local function parse_metadata_text(text)
  local safe_env = {
    math     = math,
    string   = string,
    table    = table,
    pairs    = pairs,
    ipairs   = ipairs,
    type     = type,
    tostring = tostring,
    tonumber = tonumber,
    true_    = true,
    false_   = false,
  }

  local chunk, load_err
  local source = "return " .. text
  if setfenv then
    chunk, load_err = loadstring(source, "=skill_metadata")
    if chunk then setfenv(chunk, safe_env) end
  else
    chunk, load_err = load(source, "=skill_metadata", "t", safe_env)
  end

  if not chunk then
    return nil, "failed to compile metadata: " .. tostring(load_err)
  end

  local ok, result = pcall(chunk)
  if not ok then
    return nil, "failed to evaluate metadata: " .. tostring(result)
  end

  if type(result) ~= "table" then
    return nil, "metadata must evaluate to a table"
  end

  return result
end

local function validate_metadata(meta)
  if type(meta.name) ~= "string" or meta.name == "" then
    return nil, "metadata: 'name' must be a non-empty string"
  end

  if type(meta.version) ~= "string" or meta.version == "" then
    return nil, "metadata: 'version' must be a non-empty string"
  end

  if type(meta.public_functions) ~= "table" or #meta.public_functions == 0 then
    return nil, "metadata: 'public_functions' must be a non-empty array"
  end

  for i, fn in ipairs(meta.public_functions) do
    if type(fn) ~= "string" or fn == "" then
      return nil, "metadata: public_functions[" .. i .. "] must be a non-empty string"
    end
  end

  meta.description  = meta.description  or ""
  meta.dependencies = meta.dependencies or {}
  meta.paths        = meta.paths        or {}
  meta.urls         = meta.urls         or {}

  return true
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function M.parse_metadata(file_path)
  if type(file_path) ~= "string" or file_path == "" then
    return nil, "skill_loader.parse_metadata: file_path must be a non-empty string"
  end

  local lines, read_err = read_lines(file_path)
  if not lines then
    return nil, "skill_loader.parse_metadata: cannot read '" .. file_path .. "': " .. tostring(read_err)
  end

  local text, extract_err = extract_metadata_text(lines)
  if not text then
    return nil, "skill_loader.parse_metadata: " .. extract_err .. " in " .. file_path
  end

  local meta, parse_err = parse_metadata_text(text)
  if not meta then
    return nil, "skill_loader.parse_metadata: " .. parse_err .. " in " .. file_path
  end

  local ok, val_err = validate_metadata(meta)
  if not ok then
    return nil, "skill_loader.parse_metadata: " .. val_err .. " in " .. file_path
  end

  return meta
end

function M.load(skill_name, search_dirs)
  if type(skill_name) ~= "string" or skill_name == "" then
    return nil, "skill_loader.load: skill_name must be a non-empty string"
  end

  if type(search_dirs) ~= "table" or #search_dirs == 0 then
    return nil, "skill_loader.load: search_dirs must be a non-empty array"
  end

  local filename = skill_name .. ".lua"
  local tried    = {}

  for _, dir in ipairs(search_dirs) do
    local path = dir .. "/" .. filename
    local attr = lfs.attributes(path)

    if attr and attr.mode == "file" then
      local meta, meta_err = M.parse_metadata(path)
      if not meta then
        return nil, meta_err
      end

      local code, read_err = util.read_file(path)
      if not code then
        return nil, "skill_loader.load: cannot read '" .. path .. "': " .. tostring(read_err)
      end

      return {
        metadata = meta,
        code     = code,
        path     = path,
      }
    end

    tried[#tried + 1] = dir
  end

  return nil, "skill_loader.load: skill '" .. skill_name
    .. "' not found in: " .. table.concat(tried, ", ")
end

function M.resolve_dependencies(metadata, allowed_dir)
  if type(metadata) ~= "table" then
    return nil, "skill_loader.resolve_dependencies: metadata must be a table"
  end

  if type(allowed_dir) ~= "string" or allowed_dir == "" then
    return nil, "skill_loader.resolve_dependencies: allowed_dir must be a non-empty string"
  end

  local deps = metadata.dependencies or {}
  if #deps == 0 then
    return {}
  end

  local UNVISITED = 0
  local VISITING  = 1
  local VISITED   = 2

  local state      = {}
  local order      = {}
  local order_set  = {}

  local function visit(modname, chain)
    if state[modname] == VISITED then
      return true
    end

    if state[modname] == VISITING then
      return nil, "circular dependency detected: "
        .. table.concat(chain, " -> ") .. " -> " .. modname
    end

    local filepath = allowed_dir .. "/" .. modname .. ".lua"
    local attr = lfs.attributes(filepath)
    if not attr or attr.mode ~= "file" then
      return nil, "dependency '" .. modname .. "' not found: " .. filepath
    end

    state[modname] = VISITING
    chain[#chain + 1] = modname

    local meta, meta_err = M.parse_metadata(filepath)
    if meta and meta.dependencies then
      for _, sub_dep in ipairs(meta.dependencies) do
        local ok, err = visit(sub_dep, chain)
        if not ok then return nil, err end
      end
    end

    chain[#chain] = nil
    state[modname] = VISITED

    if not order_set[modname] then
      order[#order + 1] = modname
      order_set[modname] = true
    end

    return true
  end

  for _, dep in ipairs(deps) do
    state[dep] = state[dep] or UNVISITED
    local ok, err = visit(dep, {})
    if not ok then
      return nil, "skill_loader.resolve_dependencies: " .. err
    end
  end

  return order
end

function M.list(dir)
  if type(dir) ~= "string" or dir == "" then
    return {}
  end

  local attr = lfs.attributes(dir)
  if not attr or attr.mode ~= "directory" then
    return {}
  end

  local results = {}

  for entry in lfs.dir(dir) do
    if is_lua_file(entry) and not is_test_file(entry) then
      local path = dir .. "/" .. entry
      local file_attr = lfs.attributes(path)

      if file_attr and file_attr.mode == "file" then
        local meta = M.parse_metadata(path)

        if meta then
          results[#results + 1] = {
            name        = meta.name,
            version     = meta.version,
            description = meta.description or "",
            path        = path,
          }
        end
      end
    end
  end

  table.sort(results, function(a, b) return a.name < b.name end)

  return results
end

return M
