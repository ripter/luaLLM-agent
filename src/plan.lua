--- src/plan.lua
--- Plan file parser, validator, and glob resolver.
--- A plan file is a Markdown document with ## sections containing key:value metadata.

local lfs = require("lfs")

local M = {}

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

--- Trim leading and trailing whitespace from a string.
local function trim(s)
  return s:match("^%s*(.-)%s*$")
end

--- Split a string on the first ":" and return (key, value), both trimmed.
--- Returns (nil, nil) if no colon found.
local function split_kv(line)
  local colon = line:find(":", 1, true)
  if not colon then return nil, nil end
  local k = trim(line:sub(1, colon - 1)):lower()
  local v = trim(line:sub(colon + 1))
  return k, v
end

-- ---------------------------------------------------------------------------
-- Section extraction
-- ---------------------------------------------------------------------------

--- Split raw markdown text into sections keyed by lowercase section name.
--- Only `##` (exactly two hashes + space) starts a new section.
--- `###` and deeper do NOT start a new section — they're part of the content.
--- Returns:
---   { title = "..." or nil,
---     sections = { ["plan"] = "...", ["prompt"] = "...", ... } }
local function extract_sections(text)
  local title    = nil
  local sections = {}
  local current_name    = nil   -- current section key
  local current_lines   = {}

  local function flush()
    if current_name then
      sections[current_name] = table.concat(current_lines, "\n")
    end
  end

  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    -- Detect top-level title: exactly one # followed by space
    if not title and line:match("^#%s+(.+)$") and not line:match("^##") then
      title = trim(line:match("^#%s+(.+)$"))

    -- Detect exactly ## headers (## followed by space and name, not ###)
    elseif line:match("^##%s+") and not line:match("^###") then
      flush()
      current_lines = {}
      current_name  = trim(line:match("^##%s+(.+)$")):lower()

    else
      if current_name then
        current_lines[#current_lines + 1] = line
      end
    end
  end

  flush()

  return { title = title, sections = sections }
end

-- ---------------------------------------------------------------------------
-- plan section parser
-- ---------------------------------------------------------------------------

--- Parse the key:value lines of the ## plan section.
--- Returns a table with parsed fields.
local function parse_plan_section(text)
  local result = {
    model           = nil,
    sanitize_fences = nil,   -- nil means "not set"; defaults to true in validate
    test_runner     = nil,
    context         = {},
    outputs         = {},
    test_goals      = {},
  }

  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    line = trim(line)
    if line ~= "" then
      local k, v = split_kv(line)
      if k then
        if k == "model" then
          result.model = v
        elseif k == "sanitize_fences" then
          result.sanitize_fences = (v == "true")
        elseif k == "test_runner" then
          result.test_runner = v
        elseif k == "context" then
          result.context[#result.context + 1] = v
        elseif k == "output" then
          result.outputs[#result.outputs + 1] = v
        elseif k == "test_goal" then
          result.test_goals[#result.test_goals + 1] = v
        end
        -- Unknown keys are silently ignored for forward-compatibility.
      end
    end
  end

  return result
end

-- ---------------------------------------------------------------------------
-- Public API: parse
-- ---------------------------------------------------------------------------

--- Parse a plan from a markdown string.
--- Returns (plan_table, nil) on success or (nil, error_string) on failure.
function M.parse(text)
  if type(text) ~= "string" then
    return nil, "plan.parse: expected string, got " .. type(text)
  end

  local extracted = extract_sections(text)
  local sections  = extracted.sections

  -- Validate required sections and detect duplicates.
  -- (Duplicate detection: extract_sections takes last-wins for identical names,
  --  so we count occurrences ourselves.)
  local section_counts = {}
  -- Re-scan headers to count occurrences
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    if line:match("^##%s+") and not line:match("^###") then
      local name = trim(line:match("^##%s+(.+)$")):lower()
      section_counts[name] = (section_counts[name] or 0) + 1
    end
  end

  for _, required in ipairs({ "plan", "prompt" }) do
    local count = section_counts[required] or 0
    if count == 0 then
      return nil, "plan file is missing required section: ## " .. required
    end
    if count > 1 then
      return nil, "plan file has duplicate section: ## " .. required
                  .. " (found " .. count .. " times)"
    end
  end

  if (section_counts["system prompt"] or 0) > 1 then
    return nil, "plan file has duplicate section: ## system prompt"
  end

  -- Parse the plan section fields
  local plan_fields = parse_plan_section(sections["plan"] or "")

  -- Apply sanitize_fences default
  if plan_fields.sanitize_fences == nil then
    plan_fields.sanitize_fences = true
  end

  -- Trim the prompt (preserve internal newlines, strip leading/trailing blank lines)
  local prompt_raw  = sections["prompt"] or ""
  local prompt_text = prompt_raw:match("^%s*(.-)%s*$")

  local system_prompt = nil
  if sections["system prompt"] then
    local sp = sections["system prompt"]:match("^%s*(.-)%s*$")
    if sp ~= "" then system_prompt = sp end
  end

  return {
    title           = extracted.title,
    model           = plan_fields.model,
    system_prompt   = system_prompt,
    sanitize_fences = plan_fields.sanitize_fences,
    context         = plan_fields.context,
    outputs         = plan_fields.outputs,
    test_runner     = plan_fields.test_runner,
    test_goals      = plan_fields.test_goals,
    prompt          = prompt_text,
  }, nil
end

-- ---------------------------------------------------------------------------
-- Public API: load_file
-- ---------------------------------------------------------------------------

--- Load a plan file from disk and parse it.
--- Returns (plan_table, nil) or (nil, error_string).
function M.load_file(path)
  if type(path) ~= "string" or path == "" then
    return nil, "plan.load_file: path must be a non-empty string"
  end

  local f, err = io.open(path, "r")
  if not f then
    return nil, "plan.load_file: cannot open '" .. path .. "': " .. tostring(err)
  end
  local text = f:read("*a")
  f:close()

  if not text or text == "" then
    return nil, "plan.load_file: file is empty: " .. path
  end

  local plan, parse_err = M.parse(text)
  if not plan then
    return nil, "plan.load_file: " .. tostring(parse_err) .. " (in " .. path .. ")"
  end

  return plan, nil
end

-- ---------------------------------------------------------------------------
-- Public API: validate
-- ---------------------------------------------------------------------------

--- Validate a parsed plan table.
--- Returns (true, nil) or (nil, error_string).
function M.validate(plan)
  if type(plan) ~= "table" then
    return nil, "plan.validate: expected table"
  end

  if type(plan.prompt) ~= "string" or trim(plan.prompt) == "" then
    return nil, "plan.validate: prompt is empty"
  end

  if type(plan.context) ~= "table" then
    return nil, "plan.validate: context must be an array"
  end

  -- context entries are optional; an empty list is valid (plain generate, no context)

  if type(plan.outputs) ~= "table" then
    return nil, "plan.validate: outputs must be an array"
  end

  if type(plan.sanitize_fences) ~= "boolean" then
    return nil, "plan.validate: sanitize_fences must be a boolean"
  end

  return true, nil
end

-- ---------------------------------------------------------------------------
-- Public API: resolve_context_globs
-- ---------------------------------------------------------------------------

--- Expand a list of glob patterns into a sorted, unique list of file paths.
---
--- @param patterns  table     List of glob pattern strings.
--- @param globber   function  globber(pattern) -> {filepath, ...}
---                            Dependency-injected; use M.default_globber in production.
---
--- Returns (sorted_unique_files, nil) or (nil, error_string).
function M.resolve_context_globs(patterns, globber)
  if type(patterns) ~= "table" then
    return nil, "resolve_context_globs: patterns must be a table"
  end
  if type(globber) ~= "function" then
    return nil, "resolve_context_globs: globber must be a function"
  end

  local seen  = {}
  local files = {}

  for _, pattern in ipairs(patterns) do
    local matched, err = globber(pattern)
    if not matched then
      return nil, "glob error for pattern '" .. pattern .. "': " .. tostring(err)
    end
    for _, path in ipairs(matched) do
      if not seen[path] then
        seen[path]        = true
        files[#files + 1] = path
      end
    end
  end

  table.sort(files)
  return files, nil
end

-- ---------------------------------------------------------------------------
-- Default globber (lfs-based, injected by cmd_plan in production)
-- ---------------------------------------------------------------------------

--- Recursively collect files under a directory, optionally filtered by a
--- glob pattern.  This is the production globber dependency.
---
--- Supports:
---   exact path        → [path]  (if it's a file)
---   dir/              → all files recursively under dir
---   dir/**/*.ext      → all .ext files recursively
---   dir/*.ext         → .ext files directly in dir (non-recursive)
---
--- Returns {filepaths} or (nil, error).
function M.default_globber(pattern)
  -- Normalise: convert ** to a recursive marker
  -- Strategy: convert the glob pattern to a Lua pattern for matching,
  -- then walk the filesystem and collect matches.

  -- If pattern contains no wildcards and refers to an existing file, return it.
  if not pattern:match("[*?]") then
    local attr = lfs.attributes(pattern)
    if attr and attr.mode == "file" then
      return { pattern }
    elseif attr and attr.mode == "directory" then
      -- Bare directory: return all files recursively
      return M.default_globber(pattern:gsub("/*$", "") .. "/**/*")
    else
      -- No wildcards, not found — return empty (not an error; file may be optional)
      return {}
    end
  end

  -- Find the non-wildcard root directory to start walking.
  local root = pattern:match("^([^*?]*/)")
                or (pattern:match("^([^*?]*)") .. "/")
  root = root:gsub("/*$", "")  -- strip trailing slash
  if root == "" then root = "." end

  -- Build a Lua pattern from the glob.
  -- ** matches any number of path segments (including none).
  -- *  matches within a single segment.
  -- ?  matches one character.
  local lua_pat = "^" .. pattern
    :gsub("([%.%+%-%^%$%(%)%[%]%%])", "%%%1")  -- escape regex specials
    :gsub("%*%*", "\0STAR\0")                   -- protect ** temporarily
    :gsub("%*",   "[^/]*")                       -- * -> non-slash sequence
    :gsub("%?",   "[^/]")                        -- ? -> single non-slash char
    :gsub("\0STAR\0", ".*")                      -- ** -> anything including /
    .. "$"

  -- Walk root recursively and collect matching files.
  local results = {}
  local function walk(dir)
    local attr = lfs.attributes(dir)
    if not attr or attr.mode ~= "directory" then return end
    for entry in lfs.dir(dir) do
      if entry ~= "." and entry ~= ".." then
        local path = (dir == "." and entry or dir .. "/" .. entry)
        local ea   = lfs.attributes(path)
        if ea then
          if ea.mode == "directory" then
            walk(path)
          elseif ea.mode == "file" then
            -- Normalise path separators for matching
            if path:match(lua_pat) then
              results[#results + 1] = path
            end
          end
        end
      end
    end
  end

  walk(root)
  table.sort(results)
  return results
end

return M
