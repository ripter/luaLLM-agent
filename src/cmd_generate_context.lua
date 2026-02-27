--- src/cmd_generate_context.lua
--- Logic for the `generate-with-context` command.
--- Reads context files, enforces a size cap, then delegates to cmd_generate.

local _src = debug.getinfo(1, "S").source:match("^@(.*/)" ) or "./"
package.path = _src .. "?.lua;" .. package.path

local util = require("util")

local M = {}

local DEFAULT_MAX_CONTEXT_BYTES = 64 * 1024  -- 64 KB

-- ---------------------------------------------------------------------------
-- File reading
-- ---------------------------------------------------------------------------

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
    local content, err = util.read_file(path)
    if not content then
      return nil, "cannot open context file '" .. path .. "': " .. tostring(err)
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

function M.run(deps, args)
  local config       = deps.config
  local cmd_generate = deps.cmd_generate

  pcall(config.load)

  if not args.context_paths or #args.context_paths == 0 then
    return nil, "generate-with-context requires at least one context file"
  end

  local records, read_err = read_context_files(args.context_paths, config)
  if not records then
    return nil, read_err
  end

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
