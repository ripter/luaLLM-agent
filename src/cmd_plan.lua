--- src/cmd_plan.lua
--- CLI entry for `plan run`, `plan check`, and `plan resume` sub-commands.
---
--- deps (all optional, injected for tests):
---   plan                    — plan module
---   globber                 — function(pattern) -> {paths}
---   cmd_generate_context    — module with .run(deps, args)
---   luallm                  — luallm module (for generate deps)
---   safe_fs                 — safe_fs module (for generate deps)
---   config                  — config module (for generate deps)
---   fs                      — table with .exists(path) -> boolean
---   print                   — print function (default _G.print)

local _src = debug.getinfo(1, "S").source:match("^@(.*/)") or "./"
package.path = _src .. "?.lua;" .. package.path

local M = {}

-- ---------------------------------------------------------------------------
-- Default dependencies
-- ---------------------------------------------------------------------------

local function default_deps()
  local lfs = require("lfs")
  return {
    plan                 = require("plan"),
    globber              = require("plan").default_globber,
    cmd_generate_context = require("cmd_generate_context"),
    cmd_generate         = require("cmd_generate"),
    luallm               = require("luallm"),
    safe_fs              = require("safe_fs"),
    config               = require("config"),
    fs = {
      exists = function(path)
        local attr = lfs.attributes(path)
        return attr ~= nil and attr.mode == "file"
      end,
    },
    print = _G.print,
  }
end

-- ---------------------------------------------------------------------------
-- Config wrapper: inject plan-level overrides
-- ---------------------------------------------------------------------------

--- Wrap a config dep so that plan.system_prompt and plan.sanitize_fences
--- override the corresponding config.get() keys used by cmd_generate.run_inner.
local function wrap_config(base_config, plan_table)
  return {
    load = function(...) return base_config.load(...) end,
    get  = function(key)
      if key == "generate.system_prompt" and plan_table.system_prompt then
        return plan_table.system_prompt
      end
      if key == "generate.sanitize_fences" then
        -- run_inner checks: if san_val == false then sanitize = false
        -- So we return the boolean value directly.
        return plan_table.sanitize_fences
      end
      -- TODO: if plan specifies a model, route luallm.model key too
      if key == "luallm.model" and plan_table.model then
        return plan_table.model
      end
      return base_config.get(key)
    end,
  }
end

-- ---------------------------------------------------------------------------
-- Shared: load + validate + resolve globs
-- ---------------------------------------------------------------------------

local function load_and_resolve(plan_path, deps)
  local plan_mod = deps.plan

  local plan_table, err = plan_mod.load_file(plan_path)
  if not plan_table then
    return nil, err
  end

  local ok, verr = plan_mod.validate(plan_table)
  if not ok then
    return nil, verr
  end

  local context_files, gerr = plan_mod.resolve_context_globs(
    plan_table.context, deps.globber)
  if not context_files then
    return nil, gerr
  end

  return plan_table, context_files
end

-- ---------------------------------------------------------------------------
-- Shared: print test_runner note
-- ---------------------------------------------------------------------------

local function note_test_runner(plan_table, emit)
  if plan_table.test_runner then
    emit("  Test runner requested: " .. plan_table.test_runner
         .. " (not executed by plan runner)")
  end
end

-- ---------------------------------------------------------------------------
-- Shared: run generate-with-context for one output
-- ---------------------------------------------------------------------------

local function run_generate_for_output(output_path, plan_table, context_files, deps)
  local wrapped_config = wrap_config(deps.config, plan_table)

  local gen_deps = {
    luallm       = deps.luallm,
    safe_fs      = deps.safe_fs,
    config       = wrapped_config,
    cmd_generate = deps.cmd_generate,
  }

  if #context_files == 0 then
    -- No context files: use plain generate rather than generate-with-context,
    -- which requires at least one file.
    return deps.cmd_generate.run(gen_deps, {
      output_path = output_path,
      prompt      = plan_table.prompt,
    })
  end

  return deps.cmd_generate_context.run(gen_deps, {
    output_path   = output_path,
    context_paths = context_files,
    prompt        = plan_table.prompt,
  })
end

-- ---------------------------------------------------------------------------
-- Sub-command: check
-- ---------------------------------------------------------------------------

local function run_check(plan_path, deps)
  local emit = deps.print

  local plan_table, context_files = load_and_resolve(plan_path, deps)
  if not plan_table then
    return nil, context_files  -- context_files holds error string here
  end

  emit("")
  emit("  Plan: " .. (plan_path or "?"))
  emit("  Title:            " .. (plan_table.title or "(none)"))
  emit("  Model:            " .. (plan_table.model  or "(not set)"))
  emit("  System prompt:    " .. (plan_table.system_prompt and "yes" or "(default)"))
  emit("  Sanitize fences:  " .. tostring(plan_table.sanitize_fences))
  emit("  Context patterns: " .. #plan_table.context)
  emit("  Context files:    " .. #context_files)
  emit("  Outputs declared: " .. #plan_table.outputs)
  if #plan_table.test_goals > 0 then
    emit("  Test goals:       " .. #plan_table.test_goals)
  end
  emit("")

  return true
end

-- ---------------------------------------------------------------------------
-- Sub-command: run
-- ---------------------------------------------------------------------------

local function run_run(plan_path, deps)
  local emit = deps.print

  local plan_table, context_files = load_and_resolve(plan_path, deps)
  if not plan_table then
    return nil, context_files
  end

  -- Run generate for each declared output. If no outputs are declared,
  -- run once with a nil output path (unusual but not an error for run).
  local outputs = plan_table.outputs
  if #outputs == 0 then
    -- No outputs declared: single generate call, no post-run verification.
    emit("  generating (no outputs declared) …")
    local ok, info = run_generate_for_output(nil, plan_table, context_files, deps)
    if not ok then
      return nil, "generate failed: " .. tostring(info)
    end
    emit("  ✓  (" .. (info.model or "?") .. ", " .. (info.tokens or "?") .. " tokens)")
    note_test_runner(plan_table, emit)
    emit("")
    return true
  end

  for _, output_path in ipairs(outputs) do
    emit("  generating → " .. output_path .. " …")
    local ok, info = run_generate_for_output(output_path, plan_table, context_files, deps)
    if not ok then
      return nil, "generate failed for '" .. output_path .. "': " .. tostring(info)
    end
    emit("  ✓ " .. output_path
         .. "  (" .. (info.model or "?") .. ", " .. (info.tokens or "?") .. " tokens)")
  end

  -- Verify all declared outputs now exist on disk.
  local missing = {}
  for _, output_path in ipairs(outputs) do
    if not deps.fs.exists(output_path) then
      missing[#missing + 1] = output_path
    end
  end

  if #missing > 0 then
    return nil, "outputs missing after run:\n  " .. table.concat(missing, "\n  ")
  end

  note_test_runner(plan_table, emit)
  emit("")

  return true
end

-- ---------------------------------------------------------------------------
-- Sub-command: resume
-- ---------------------------------------------------------------------------

local function run_resume(plan_path, deps)
  local emit = deps.print

  local plan_table, context_files = load_and_resolve(plan_path, deps)
  if not plan_table then
    return nil, context_files
  end

  if #plan_table.outputs == 0 then
    return nil, "resume requires declared outputs (none found in plan)"
  end

  -- Check which outputs are missing.
  local missing = {}
  for _, output_path in ipairs(plan_table.outputs) do
    if not deps.fs.exists(output_path) then
      missing[#missing + 1] = output_path
    end
  end

  if #missing == 0 then
    emit("  All outputs already exist; nothing to do.")
    return true
  end

  emit("  Missing outputs:")
  for _, p in ipairs(missing) do
    emit("    - " .. p)
  end
  emit("")

  -- Run generate for each missing output only.
  for _, output_path in ipairs(missing) do
    emit("  generating → " .. output_path .. " …")
    local ok, info = run_generate_for_output(output_path, plan_table, context_files, deps)
    if not ok then
      return nil, "generate failed for '" .. output_path .. "': " .. tostring(info)
    end
    emit("  ✓ " .. output_path
         .. "  (" .. (info.model or "?") .. ", " .. (info.tokens or "?") .. " tokens)")
  end

  -- Verify everything exists now.
  local still_missing = {}
  for _, output_path in ipairs(missing) do
    if not deps.fs.exists(output_path) then
      still_missing[#still_missing + 1] = output_path
    end
  end

  if #still_missing > 0 then
    return nil, "outputs still missing after resume:\n  " .. table.concat(still_missing, "\n  ")
  end

  note_test_runner(plan_table, emit)
  emit("")

  return true
end

-- ---------------------------------------------------------------------------
-- Sub-command: new
-- ---------------------------------------------------------------------------

local PLAN_TEMPLATE = [[## plan
model:
sanitize_fences: true
context: src/
output: src/
test_runner: busted

## system prompt
You are a Lua code generator. Output ONLY valid Lua code. No markdown fences.
No explanations, no commentary. Start with the first line of code.

## prompt
<describe what to generate here>
]]

local function run_new(plan_path, deps)
  local emit = deps.print

  local f, err = io.open(plan_path, "w")
  if not f then
    return nil, "plan new: cannot create '" .. plan_path .. "': " .. tostring(err)
  end

  f:write(PLAN_TEMPLATE)
  f:close()

  emit("  Created: " .. plan_path)
  emit("  Edit the file, then run:")
  emit("    ./agent plan check  " .. plan_path)
  emit("    ./agent plan run    " .. plan_path)

  return true
end

-- ---------------------------------------------------------------------------
-- Public API: run
-- ---------------------------------------------------------------------------

--- Entry point called from main.lua.
--- args = { subcommand = "run"|"check"|"resume", plan_path = "..." }
function M.run(args, deps)
  -- Merge defaults with any provided deps.
  local d = default_deps()
  if type(deps) == "table" then
    for k, v in pairs(deps) do
      d[k] = v
    end
  end

  local subcommand = args and args.subcommand
  local plan_path  = args and args.plan_path

  if not plan_path or plan_path == "" then
    return nil, "plan: plan_path is required"
  end

  if subcommand == "check" then
    return run_check(plan_path, d)
  elseif subcommand == "run" then
    return run_run(plan_path, d)
  elseif subcommand == "resume" then
    return run_resume(plan_path, d)
  elseif subcommand == "new" then
    return run_new(plan_path, d)
  else
    return nil, "plan: unknown subcommand '" .. tostring(subcommand)
                .. "' (expected: new, run, check, resume)"
  end
end

return M
