--- src/cmd_generate.lua
--- Logic for the `generate` command.
--- Pure functions that accept explicit deps — easy to test without a server.

local M = {}

M.DEFAULT_SYSTEM_PROMPT =
  "You are a Lua code generator. Output ONLY valid Lua code. " ..
  "No markdown fences, no explanations, no commentary. " ..
  "Start with the first line of code."

-- ---------------------------------------------------------------------------
-- Sanitizer: strip Markdown code fences if present
-- ---------------------------------------------------------------------------

function M.strip_fences(text)
  local first_nl = text:find("\n")
  if not first_nl then
    return text
  end

  local first_line = text:sub(1, first_nl - 1)
  if not first_line:match("^```[^`]*$") then
    return text
  end

  local rest       = text:sub(first_nl + 1)
  local inner_end  = nil
  local search_pos = 1

  while true do
    local nl_pos = rest:find("\n```", search_pos, true)
    if not nl_pos then break end
    local after_fence = rest:sub(nl_pos + 4)
    if after_fence:match("^%s*$") then
      inner_end = nl_pos - 1
    end
    search_pos = nl_pos + 1
  end

  if inner_end then
    local inner = rest:sub(1, inner_end)
    return inner .. "\n"
  end

  return text
end

-- ---------------------------------------------------------------------------
-- Context prompt builder (shared with generate-with-context command)
-- ---------------------------------------------------------------------------

function M.build_context_prompt(file_records, user_prompt)
  local parts = { "Here are existing source files for reference:" }
  for _, rec in ipairs(file_records) do
    parts[#parts + 1] = "--- " .. rec.path .. " ---"
    parts[#parts + 1] = rec.content
  end
  parts[#parts + 1] = "Now, using these as reference for style, conventions, and available APIs:"
  parts[#parts + 1] = user_prompt
  return table.concat(parts, "\n")
end

--- Resolve the final prompt string from a raw argument.
function M.resolve_prompt(raw)
  if raw == "-" then
    local content = io.read("*a")
    if not content or content == "" then
      return nil, "prompt from stdin was empty"
    end
    return content, nil
  end

  if raw:sub(1, 1) == "@" then
    local path = raw:sub(2)
    if path == "" then
      return nil, "@ prefix requires a file path, e.g. @prompts/my_prompt.md"
    end
    local f, err = io.open(path, "r")
    if not f then
      return nil, "cannot open prompt file '" .. path .. "': " .. tostring(err)
    end
    local content = f:read("*a")
    f:close()
    if not content or content == "" then
      return nil, "prompt file is empty: " .. path
    end
    return content, nil
  end

  if raw == "" then
    return nil, "prompt cannot be an empty string"
  end

  return raw, nil
end

-- ---------------------------------------------------------------------------
-- Shared inner runner
-- ---------------------------------------------------------------------------

local function run_inner(deps, args)
  local luallm   = deps.luallm
  local safe_fs  = deps.safe_fs
  local config   = deps.config

  local output_path = args.output_path
  local prompt      = args.prompt

  pcall(config.load)

  local allowed_ok, allowed_val = pcall(config.get, "allowed_paths")
  local blocked_ok, blocked_val = pcall(config.get, "blocked_paths")
  local allowed = (allowed_ok and type(allowed_val) == "table") and allowed_val or {}
  local blocked = (blocked_ok and type(blocked_val) == "table") and blocked_val or {}

  local pol_ok, pol_err = safe_fs.validate_policy(allowed, blocked)
  if not pol_ok then
    return nil, "path policy is invalid: " .. pol_err
  end

  local perm_ok, perm_err = safe_fs.is_allowed(output_path, allowed, blocked)
  if not perm_ok then
    return nil, "write not permitted: " .. perm_err
  end

  local sys_prompt
  local sp_ok, sp_val = pcall(config.get, "generate.system_prompt")
  if sp_ok and type(sp_val) == "string" and sp_val ~= "" then
    sys_prompt = sp_val
  else
    sys_prompt = M.DEFAULT_SYSTEM_PROMPT
  end

  local sanitize = true
  local san_ok, san_val = pcall(config.get, "generate.sanitize_fences")
  if san_ok and san_val == false then
    sanitize = false
  end

  local gen_timeout = nil
  local gt_ok, gt_val = pcall(config.get, "generate.timeout_seconds")
  if gt_ok and type(gt_val) == "number" and gt_val > 0 then
    gen_timeout = gt_val
  end

  local state, state_err = luallm.state()
  if not state then
    return nil, "could not reach luallm: " .. tostring(state_err)
  end

  -- Use the shared resolve_model from luallm module
  local model, port = luallm.resolve_model(state)
  if not model then
    return nil, "no running model found in luallm status"
  end

  local response, req_err = luallm.complete(model, {
    { role = "system", content = sys_prompt },
    { role = "user",   content = prompt     },
  }, gen_timeout and { _timeout = gen_timeout } or nil, port)

  if not response then
    return nil, "LLM request failed: " .. tostring(req_err)
  end

  local content_text = response.choices
                   and response.choices[1]
                   and response.choices[1].message
                   and response.choices[1].message.content

  if not content_text then
    return nil, "unexpected response shape (no choices[1].message.content)"
  end

  if sanitize then
    content_text = M.strip_fences(content_text)
  end

  local write_ok, write_err = safe_fs.write_file(output_path, content_text, allowed, blocked)
  if not write_ok then
    return nil, write_err
  end

  local tokens = "0"
  if response.usage and response.usage.total_tokens then
    tokens = tostring(math.floor(response.usage.total_tokens))
  elseif response.usage and response.usage.completion_tokens then
    tokens = tostring(math.floor(response.usage.completion_tokens)) .. " (completion)"
  end

  return true, { output_path = output_path, model = model, tokens = tokens }
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function M.run(deps, args)
  return run_inner(deps, args)
end

function M.run_with_context(deps, args)
  local file_records  = args.context_files or {}
  local user_prompt   = args.prompt
  local final_prompt  = M.build_context_prompt(file_records, user_prompt)
  return run_inner(deps, {
    output_path = args.output_path,
    prompt      = final_prompt,
  })
end

return M
