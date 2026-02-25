--- src/cmd_generate_context.lua
--- Logic for the `generate-with-context` command.
--- Reads context files, enforces a size cap, then delegates to cmd_generate.

local _src = debug.getinfo(1, "S").source:match("^@(.*/)") or "./"
package.path = _src .. "?.lua;" .. package.path

local M = {}

-- Default cap for total context file bytes to avoid blowing model context windows.
-- Override via generate.max_context_bytes in config.json.
local DEFAULT_MAX_CONTEXT_BYTES = 64 * 1024  -- 64 KB

-- ---------------------------------------------------------------------------
-- File reading
-- ---------------------------------------------------------------------------

--- Read a single file and return its contents as a string.
--- Returns (content_string, nil) or (nil, error_string).
local function read_file(path)
  local f, err = io.open(path, "r")
  if not f then
    return nil, "cannot open context file '" .. path .. "': " .. tostring(err)
  end
  local content = f:read("*a")
  f:close()
  if content == nil then
    return nil, "failed to read context file: " .. path
  end
  return content, nil
end

--- Read all context files, enforce size cap.
--- Returns (list_of_{path,content}, nil) or (nil, error_string).
--- deps.config is used to read generate.max_context_bytes.
local function read_context_files(paths, config)
  local max_bytes
  local mb_ok, mb_val = pcall(config.get, "generate.max_context_bytes")
  if mb_ok and type(mb_val) == "number" and mb_val > 0 then
    max_bytes = math.floor(mb_val)
  else
    max_bytes = DEFAULT_MAX_CONTEXT_BYTES
  end

  local records    = {}
  local total_bytes = 0

  for _, path in ipairs(paths) do
    local content, err = read_file(path)
    if not content then
      return nil, err
    end

    total_bytes = total_bytes + #content
    if total_bytes > max_bytes then
      return nil, string.format(
        "context files exceed maximum allowed size (%d bytes). "
        .. "Reduce context files or raise generate.max_context_bytes in config. "
        .. "Failed when adding '%s' (total would be %d bytes).",
        max_bytes, path, total_bytes)
    end

    records[#records + 1] = { path = path, content = content }
  end

  return records, nil
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Run the generate-with-context command.
---
--- deps = {
---   luallm       — module with .state() and .complete()
---   safe_fs      — module with .validate_policy(), .is_allowed(), .write_file()
---   config       — module with .load(), .get()
---   cmd_generate — the cmd_generate module (for run_with_context)
--- }
--- args = {
---   output_path   — string: file to write
---   context_paths — list of strings: files to read for context
---   prompt        — string: the user's generation request
--- }
---
--- Returns (true, info_table) on success or (nil, error_string) on failure.
function M.run(deps, args)
  local config       = deps.config
  local cmd_generate = deps.cmd_generate

  pcall(config.load)

  if not args.context_paths or #args.context_paths == 0 then
    return nil, "generate-with-context requires at least one context file"
  end

  -- Read all context files (respects size cap).
  local records, read_err = read_context_files(args.context_paths, config)
  if not records then
    return nil, read_err
  end

  -- Delegate to cmd_generate with the assembled context.
  return cmd_generate.run_with_context(
    { luallm  = deps.luallm,
      safe_fs = deps.safe_fs,
      config  = deps.config },
    { output_path   = args.output_path,
      context_files = records,
      prompt        = args.prompt }
  )
end

return M
