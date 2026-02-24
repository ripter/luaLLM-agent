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

--- Strip a single wrapping code fence block from `text` if present.
--- Handles:
---   ```lua\n...\n```   (language tag, single or multiline content)
---   ```\n...\n```      (no language tag)
--- Returns the inner content with exactly one trailing newline, or the
--- original text unchanged if no fence wrapper is detected.
---
--- Implementation note: Lua's `.` does not match `\n` in patterns, so we
--- avoid patterns for the multi-line inner content and use plain string
--- operations instead.
function M.strip_fences(text)
  -- Must have at least one newline to contain a fence block.
  local first_nl = text:find("\n")
  if not first_nl then
    return text
  end

  -- Opening fence line: ``` followed by optional language tag, nothing else.
  local first_line = text:sub(1, first_nl - 1)
  if not first_line:match("^```[^`]*$") then
    return text
  end

  -- Find the LAST occurrence of "\n```" (with optional trailing whitespace)
  -- at or near the very end of the string.  We iterate forward to find all
  -- candidates and keep the last one that is followed only by optional
  -- whitespace until end-of-string.
  local rest       = text:sub(first_nl + 1)  -- everything after the opening fence line
  local inner_end  = nil  -- byte offset in `rest` just before the closing fence newline
  local search_pos = 1

  while true do
    local nl_pos = rest:find("\n```", search_pos, true)
    if not nl_pos then break end
    -- Check that after the ``` there's only optional whitespace until EOS.
    local after_fence = rest:sub(nl_pos + 4)  -- skip \n and ```
    if after_fence:match("^%s*$") then
      inner_end = nl_pos - 1  -- last char before the \n that leads into ```
    end
    search_pos = nl_pos + 1
  end

  if inner_end then
    -- inner is everything in rest up to (but not including) the closing \n```.
    local inner = rest:sub(1, inner_end)
    return inner .. "\n"
  end

  return text
end

-- ---------------------------------------------------------------------------
-- Model resolution
-- ---------------------------------------------------------------------------

--- Pick the best model+port from a status response.
--- Prefers config override, then first running server.
--- Returns (model_name, port_or_nil).
local function resolve_model(state, config)
  -- Config override takes precedence.
  local cfg_ok, cfg_model = pcall(config.get, "luallm.model")
  if cfg_ok and type(cfg_model) == "string" and cfg_model ~= "" then
    return cfg_model, nil  -- port unknown; complete() will look it up
  end

  -- First running server from status response.
  for _, entry in ipairs(state.servers or {}) do
    if entry.state == "running" and (entry.model or entry.name) and entry.port then
      return entry.model or entry.name, math.floor(entry.port)
    end
  end

  return nil, nil
end


-- ---------------------------------------------------------------------------
-- Context prompt builder (shared with generate-with-context command)
-- ---------------------------------------------------------------------------

--- Format a list of { path, content } file records into a context block.
--- Returns a single string ready to prepend to the user prompt.
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
--- Three forms are supported:
---   "-"          → read from stdin
---   "@<path>"    → read from the file at <path>
---   anything else → use as a literal prompt string
---
--- Returns (prompt_string, nil) on success, or (nil, error_string) on failure.
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

--- Core generation logic shared by `run` and `run_with_context`.
--- args.prompt is the fully-assembled final prompt (context already merged in).
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

  -- Per-generate timeout: generate.timeout_seconds overrides the global limit.
  -- Large context payloads need significantly more time than quick prompts.
  local gen_timeout = nil
  local gt_ok, gt_val = pcall(config.get, "generate.timeout_seconds")
  if gt_ok and type(gt_val) == "number" and gt_val > 0 then
    gen_timeout = gt_val
  end

  local state, state_err = luallm.state()
  if not state then
    return nil, "could not reach luallm: " .. tostring(state_err)
  end

  local model, port = resolve_model(state, config)
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

--- Run the generate command.
--- args = { output_path, prompt }
function M.run(deps, args)
  return run_inner(deps, args)
end

--- Run the generate-with-context command.
--- args = { output_path, context_files, prompt }
--- context_files is a list of { path, content } tables already read by the caller.
--- The caller (cmd_generate_context) is responsible for reading files; this
--- function only assembles the prompt and delegates to run_inner.
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
