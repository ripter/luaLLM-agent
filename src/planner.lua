--- src/planner.lua
--- LLM-powered plan.md generator.
--- Converts a user prompt into a validated plan.md file, and can revise a
--- failed plan given error context.  Pure orchestration: no filesystem access
--- except via the injected safe_fs dep.

local M = {}

-- ---------------------------------------------------------------------------
-- Internal constants
-- ---------------------------------------------------------------------------

local DEFAULT_OUTPUT_DIR  = "."
local DEFAULT_PLAN_NAME   = "plan.md"

-- ---------------------------------------------------------------------------
-- system_prompt
-- ---------------------------------------------------------------------------

--- Return the system prompt that teaches the LLM the plan.md format.
--- Exposed for testing; not normally called directly.
function M.system_prompt()
  return [[
You are a planning assistant that produces plan.md files for an automated Lua code-generation pipeline.

## Output format

Respond with ONLY a valid plan.md document — no preamble, no explanation, no markdown fences around the whole document.

A plan.md has three sections, in this order:

1.  An optional title line:
        # <short descriptive title>

2.  A required `## plan` section containing key:value metadata lines:
        ## plan
        model: <model-name>           (optional)
        sanitize_fences: true         (optional; default true — strips ``` fences from LLM output)
        context: <path-or-glob>       (zero or more; existing source files the generator should read)
        output: <filepath>            (one or more; files the generator will write)
        test_runner: <command>        (optional; e.g. "busted" or "pytest")
        test_goal: <description>      (zero or more; what the tests must prove)

3.  An optional `## system prompt` section containing the system prompt to
    pass to the code-generation LLM.

4.  A required `## prompt` section containing the natural-language coding
    instruction for the code-generation LLM.

## Rules

- The `## plan` and `## prompt` sections are REQUIRED.
- Keys in `## plan` are lowercase.  Unknown keys are ignored.
- `context:` lines reference EXISTING files.  Do not list files that do not exist.
- `output:` lines are the files the pipeline will generate (create or overwrite).
- `sanitize_fences: true` (the default) strips leading/trailing ``` fences from
  the LLM's response before writing the output file.  Set to false only when the
  output itself is a markdown file.
- The `## prompt` section is the full coding instruction.  Be specific.
- Do NOT wrap the plan.md in a ```markdown fence.
- Do NOT add any text before the optional `#` title or after the `## prompt` content.

## Example

# Add input validation to config loader

## plan
model: Qwen3-Coder-Q8_0
sanitize_fences: true
context: src/config.lua
context: src/config_test.lua
output: src/config.lua
output: src/config_test.lua
test_runner: busted
test_goal: rejects non-string keys
test_goal: returns nil for missing keys

## system prompt
You are a Lua code generator. Output ONLY valid Lua source code. No markdown fences.

## prompt
Add input validation to `src/config.lua`:
- `config.get(key)` must return `nil, "key must be a string"` when key is not a string.
- `config.set(key, value)` must return `nil, "key must be a string"` when key is not a string.
Update the busted tests in `src/config_test.lua` to cover both error paths.
]]
end

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

--- Extract the text content from a luallm completion response.
--- Returns (text, nil) or (nil, error_string).
local function extract_content(response)
  if type(response) ~= "table" then
    return nil, "planner: LLM returned nil or non-table response"
  end
  local choices = response.choices
  if type(choices) ~= "table" or #choices == 0 then
    return nil, "planner: LLM response has no choices"
  end
  local msg = choices[1].message
  if type(msg) ~= "table" then
    return nil, "planner: LLM choice has no message"
  end
  local content = msg.content
  if type(content) ~= "string" or content == "" then
    return nil, "planner: LLM returned empty content"
  end
  return content, nil
end

--- Resolve the model to use: prefer opts.model, then config default, then nil.
local function resolve_model(deps, opts)
  if opts and opts.model then return opts.model end
  if deps.config then
    local m = deps.config.get("model")
    if m and m ~= "" then return m end
  end
  return nil
end

--- Write text to path via safe_fs.  Returns (true, nil) or (nil, error).
local function write_plan(deps, path, text)
  local ok, err = deps.safe_fs.write_file(path, text)
  if not ok then
    return nil, "planner: failed to write plan file '" .. path .. "': " .. tostring(err)
  end
  return true, nil
end

--- Parse and validate LLM output as a plan.  Returns (plan_table, nil) or (nil, err).
local function parse_and_validate(deps, text)
  local plan_table, parse_err = deps.plan.parse(text)
  if not plan_table then
    return nil, "planner: LLM output is not a valid plan.md: " .. tostring(parse_err)
  end
  local ok, val_err = deps.plan.validate(plan_table)
  if not ok then
    return nil, "planner: LLM plan failed validation: " .. tostring(val_err)
  end
  return plan_table, nil
end

--- Build the output path for the plan file.
local function plan_path(output_dir, plan_name)
  output_dir = output_dir or DEFAULT_OUTPUT_DIR
  plan_name  = plan_name  or DEFAULT_PLAN_NAME
  -- Normalise trailing slash
  if output_dir:sub(-1) == "/" then
    return output_dir .. plan_name
  end
  return output_dir .. "/" .. plan_name
end

-- ---------------------------------------------------------------------------
-- Public API: generate
-- ---------------------------------------------------------------------------

--- Generate a fresh plan.md from a user prompt.
---
--- @param deps   table   { luallm, config, plan, safe_fs }
--- @param prompt string  The user's natural-language task description.
--- @param opts   table   Optional:
---                         context_files = {}     extra source files for the LLM
---                         output_dir    = "."    where to write plan.md
---                         plan_name     = nil    filename override
---                         model         = nil    model override
---
--- @return string|nil, string|table
---   On success: plan_path (string), plan_table (table)
---   On failure: nil, error_string
function M.generate(deps, prompt, opts)
  opts = opts or {}

  if type(prompt) ~= "string" or prompt == "" then
    return nil, "planner.generate: prompt must be a non-empty string"
  end

  -- Build the user message.
  local parts = {}
  parts[#parts + 1] = "User request:\n" .. prompt

  if opts.context_files and #opts.context_files > 0 then
    parts[#parts + 1] = "\nRelevant existing files (for context reference):"
    for _, f in ipairs(opts.context_files) do
      parts[#parts + 1] = "  - " .. tostring(f)
    end
  end

  parts[#parts + 1] = "\nProduce a plan.md for this request."

  local user_msg = table.concat(parts, "\n")

  -- Call the LLM.
  local model   = resolve_model(deps, opts)
  local call_opts = {}
  if model then call_opts.model = model end

  local response, llm_err = deps.luallm.complete({
    system   = M.system_prompt(),
    messages = { { role = "user", content = user_msg } },
  }, call_opts)

  if not response then
    return nil, "planner.generate: LLM call failed: " .. tostring(llm_err)
  end

  local content, extract_err = extract_content(response)
  if not content then
    return nil, extract_err
  end

  -- Parse and validate.
  local plan_table, pv_err = parse_and_validate(deps, content)
  if not plan_table then
    return nil, pv_err
  end

  -- Write to disk.
  local out_path = plan_path(opts.output_dir, opts.plan_name)
  local _, write_err = write_plan(deps, out_path, content)
  if write_err then
    return nil, write_err
  end

  return out_path, plan_table
end

-- ---------------------------------------------------------------------------
-- Public API: replan
-- ---------------------------------------------------------------------------

--- Generate a revised plan.md given a previous failure.
---
--- @param deps       table  { luallm, config, plan, safe_fs }
--- @param task       table  The task table (from task.new); used for prompt + opts.
--- @param error_info table  {
---                            phase       = "testing"|"executing"|"planning",
---                            message     = "...",
---                            test_output = "..." (optional),
---                            plan_text   = "..." (optional),
---                            skill_code  = "..." (optional),
---                          }
--- @param opts       table  Optional: same shape as generate() opts.
---
--- @return string|nil, string|table
function M.replan(deps, task_obj, error_info, opts)
  opts       = opts       or {}
  error_info = error_info or {}

  local original_prompt = (task_obj and task_obj.prompt) or ""
  if original_prompt == "" then
    return nil, "planner.replan: task.prompt must be a non-empty string"
  end

  -- Build the user message.
  local parts = {}

  parts[#parts + 1] = "## Original user request\n\n" .. original_prompt

  if error_info.plan_text and error_info.plan_text ~= "" then
    parts[#parts + 1] = "## Previous plan.md that was attempted\n\n"
                       .. error_info.plan_text
  end

  if error_info.skill_code and error_info.skill_code ~= "" then
    parts[#parts + 1] = "## Generated code that was produced\n\n"
                       .. error_info.skill_code
  end

  local phase = error_info.phase or "unknown"
  local msg   = error_info.message or "(no error message provided)"
  parts[#parts + 1] = "## What went wrong\n\nPhase: " .. phase .. "\nError: " .. msg

  if error_info.test_output and error_info.test_output ~= "" then
    parts[#parts + 1] = "## Test runner output\n\n" .. error_info.test_output
  end

  parts[#parts + 1] = [[
## Your task

Produce a revised plan.md that avoids the same failure.
- If the generated code failed tests, adjust the `## prompt` to fix the logic.
- If the plan referenced wrong file paths, correct the `context:` or `output:` lines.
- If the test_runner or test_goals are wrong, update them.
- Output ONLY the revised plan.md document.]]

  local user_msg = table.concat(parts, "\n\n")

  -- Call the LLM.
  local model     = resolve_model(deps, opts)
  local call_opts = {}
  if model then call_opts.model = model end

  local response, llm_err = deps.luallm.complete({
    system   = M.system_prompt(),
    messages = { { role = "user", content = user_msg } },
  }, call_opts)

  if not response then
    return nil, "planner.replan: LLM call failed: " .. tostring(llm_err)
  end

  local content, extract_err = extract_content(response)
  if not content then
    return nil, extract_err
  end

  -- Parse and validate.
  local plan_table, pv_err = parse_and_validate(deps, content)
  if not plan_table then
    return nil, pv_err
  end

  -- Write to disk.
  local out_path = plan_path(opts.output_dir, opts.plan_name)
  local _, write_err = write_plan(deps, out_path, content)
  if write_err then
    return nil, write_err
  end

  return out_path, plan_table
end

return M
