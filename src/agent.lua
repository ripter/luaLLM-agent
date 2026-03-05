--- src/agent.lua
--- Core orchestration loop.
--- Drives a task table through the status machine one step at a time,
--- delegating to planner, cmd_plan, skill_runner, and approval.
---
--- Build order: handlers are added one step at a time (3a, 3b, …).
--- Step 3a: handle_pending, handle_planning.
--- Step 3b: handle_executing.
--- Step 3c: handle_testing.
--- Step 3d: handle_approval.

local _src = debug.getinfo(1, "S").source:match("^@(.*/)") or "./"
package.path = _src .. "?.lua;" .. package.path

local M = {}

-- ---------------------------------------------------------------------------
-- Default dependencies
-- ---------------------------------------------------------------------------

local function default_deps()
  return {
    task         = require("task"),
    planner      = require("planner"),
    cmd_plan     = require("cmd_plan"),
    plan         = require("plan"),
    skill_loader = require("skill_loader"),
    skill_runner = require("skill_runner"),
    approval     = require("approval"),
    state        = require("state"),
    config       = require("config"),
    luallm       = require("luallm"),
    safe_fs      = require("safe_fs"),
    print        = _G.print,
  }
end

-- ---------------------------------------------------------------------------
-- Internal: read plan text from disk (best-effort; nil on failure)
-- ---------------------------------------------------------------------------

local function read_plan_text(plan_path)
  if type(plan_path) ~= "string" or plan_path == "" then return nil end
  local f = io.open(plan_path, "r")
  if not f then return nil end
  local text = f:read("*a")
  f:close()
  return (text ~= "") and text or nil
end

-- ---------------------------------------------------------------------------
-- Handler: PENDING → PLANNING
-- ---------------------------------------------------------------------------

local function handle_pending(deps, t)
  deps.task.transition(t, deps.task.PLANNING, "starting")
  return t
end

-- ---------------------------------------------------------------------------
-- Handler: PLANNING → EXECUTING | REPLANNING | FAILED
-- ---------------------------------------------------------------------------

local function handle_planning(deps, t)
  deps.task.bump_attempt(t, "plan")

  local plan_path, result = deps.planner.generate(deps, t.prompt, {
    context_files = t.context_files,
  })

  if plan_path then
    -- Success: record plan location and content, advance to EXECUTING.
    t.plan_path = plan_path
    t.plan_text = read_plan_text(plan_path) or (type(result) == "string" and result or nil)
    deps.task.transition(t, deps.task.EXECUTING, "plan generated: " .. plan_path)
    return t
  end

  -- Failure path: result is an error string.
  local err = tostring(result)
  t.error = err

  -- PLANNING can only transition to EXECUTING or FAILED (see task.lua TRANSITIONS).
  -- When the planner fails we always go to FAILED here.  The retry logic lives
  -- in handle_replanning (Step 3b): REPLANNING → PLANNING re-enters this handler
  -- if attempts.plan < max_attempts.plan.
  local detail = deps.task.can_retry(t, "plan")
    and ("planning failed (attempt " .. t.attempts.plan .. ", will retry): " .. err)
    or  ("planning failed (no retries left): " .. err)
  deps.task.transition(t, deps.task.FAILED, detail)

  return t
end

-- ---------------------------------------------------------------------------
-- Handler: EXECUTING → TESTING | COMPLETE | REPLANNING | FAILED
-- ---------------------------------------------------------------------------

--- Build the deps table that cmd_plan.run() expects, bridging from agent deps.
local function make_cmd_plan_deps(deps)
  return {
    plan                 = deps.plan,
    globber              = deps.plan.default_globber,
    cmd_generate_context = deps.cmd_generate_context,
    cmd_generate         = deps.cmd_generate,
    luallm               = deps.luallm,
    safe_fs              = deps.safe_fs,
    config               = deps.config,
    fs                   = deps.fs or { exists = function(_) return false end },
    print                = deps.print or function(_) end,
  }
end

local function handle_executing(deps, t)
  local plan_deps = make_cmd_plan_deps(deps)

  local ok, err = deps.cmd_plan.run(
    { subcommand = "run", plan_path = t.plan_path },
    plan_deps
  )

  if not ok then
    err = tostring(err)
    t.error = err

    if deps.task.can_retry(t, "plan") then
      deps.task.transition(t, deps.task.REPLANNING,
        "execution failed (will retry): " .. err)
    else
      deps.task.transition(t, deps.task.FAILED,
        "execution failed (no retries left): " .. err)
    end

    return t
  end

  -- Execution succeeded.  Collect declared outputs from the plan.
  -- We re-load the plan to get the outputs list; fall back to t.outputs if set.
  local plan_table
  if deps.plan and t.plan_path then
    local pt, _ = deps.plan.load_file(t.plan_path)
    plan_table = pt
  end

  local output_paths = (plan_table and plan_table.outputs) or t.outputs or {}
  t.outputs = output_paths

  -- Scan each output for @skill metadata.  Any file that parses successfully
  -- as a skill is added to t.skill_files.
  local skill_files = {}
  for _, path in ipairs(output_paths) do
    local meta, _ = deps.skill_loader.parse_metadata(path)
    if meta then
      skill_files[#skill_files + 1] = path
    end
  end

  t.skill_files = skill_files

  if #skill_files > 0 then
    deps.task.transition(t, deps.task.TESTING,
      "execution complete, skills found: " .. #skill_files)
  else
    deps.task.transition(t, deps.task.COMPLETE,
      "execution complete, no skills (pure codegen)")
  end

  return t
end

-- ---------------------------------------------------------------------------
-- Handler: TESTING → APPROVAL | REPLANNING | FAILED
-- ---------------------------------------------------------------------------

--- Derive the test file path from a skill file path.
--- Convention: "path/to/foo.lua"  →  "path/to/foo.test.lua"
local function test_path_for(skill_path)
  return (skill_path:gsub("%.lua$", ".test.lua"))
end

local function handle_testing(deps, t)
  local results  = {}
  local failed   = {}

  for _, skill_path in ipairs(t.skill_files or {}) do
    local test_path = test_path_for(skill_path)

    local result, run_err = deps.skill_runner.run_tests(test_path)

    if not result then
      -- Hard failure from run_tests (file not found, no Lua interpreter, etc.).
      -- Treat as a test failure so the retry/fail logic applies uniformly.
      results[#results + 1] = {
        skill_path = skill_path,
        test_path  = test_path,
        passed     = false,
        output     = tostring(run_err),
        error      = run_err,
      }
      failed[#failed + 1] = {
        skill_path = skill_path,
        output     = tostring(run_err),
      }
    else
      results[#results + 1] = {
        skill_path = skill_path,
        test_path  = test_path,
        passed     = result.passed,
        output     = result.output,
        exit_code  = result.exit_code,
        timed_out  = result.timed_out,
      }
      if not result.passed then
        failed[#failed + 1] = {
          skill_path = skill_path,
          output     = result.output,
        }
      end
    end
  end

  t.test_results = results

  if #failed == 0 then
    deps.task.transition(t, deps.task.APPROVAL, "all tests passed")
    return t
  end

  -- Build a summary of failures for the error context (used by handle_replanning).
  local parts = {}
  for _, f in ipairs(failed) do
    parts[#parts + 1] = f.skill_path .. ":\n" .. f.output
  end
  local err_summary = "test failures (" .. #failed .. "/" .. #results .. "):\n"
                    .. table.concat(parts, "\n---\n")

  t.error = err_summary

  deps.task.bump_attempt(t, "test")

  if deps.task.can_retry(t, "test") then
    deps.task.transition(t, deps.task.REPLANNING,
      "testing failed (will retry): " .. #failed .. " skill(s) failed")
  else
    deps.task.transition(t, deps.task.FAILED,
      "testing failed (no retries left): " .. #failed .. " skill(s) failed")
  end

  return t
end

-- ---------------------------------------------------------------------------
-- Handler: APPROVAL (paused — creates approval records, prints commands)
-- ---------------------------------------------------------------------------

--- Extract the skill name from a skill file path.
--- Convention: "path/to/my_skill.lua" -> "my_skill"
local function skill_name_for(skill_path)
  local base = skill_path:match("([^/]+)$") or skill_path
  return (base:gsub("%.lua$", ""))
end

--- Find the test_results entry for a given skill_path (nil if absent).
local function results_for(test_results, skill_path)
  if type(test_results) ~= "table" then return nil end
  for _, r in ipairs(test_results) do
    if r.skill_path == skill_path then return r end
  end
  return nil
end

local function handle_approval(deps, t)
  local emit        = deps.print or function(_) end
  local allowed_dir = deps.config.get("skills.allowed_dir") or "./skills"

  -- Create an approval record for each skill file.
  local approval_ids = {}

  for _, skill_path in ipairs(t.skill_files or {}) do
    local skill_name = skill_name_for(skill_path)
    local test_path  = test_path_for(skill_path)

    -- Gather test results for this skill (may be nil).
    local skill_results = results_for(t.test_results, skill_path)
    local test_results_arg = skill_results and { skill_results } or {}

    -- Re-fetch metadata so the record has the full declared paths/deps.
    local metadata = nil
    if deps.skill_loader then
      local meta, _ = deps.skill_loader.parse_metadata(skill_path)
      metadata = meta
    end

    local record, err = deps.approval.create(
      skill_name,
      skill_path,
      test_path,
      test_results_arg,
      metadata or {}
    )

    if not record then
      -- Approval creation failure is a hard error; fail the task.
      deps.task.transition(t, deps.task.FAILED,
        "approval.create failed for '" .. skill_path .. "': " .. tostring(err))
      return t
    end

    approval_ids[#approval_ids + 1] = record.id

    -- Print promotion commands for this skill.
    local cmds, cmds_err = deps.approval.get_promotion_commands(record, allowed_dir)
    if cmds then
      emit("")
      emit("  Promote '" .. skill_name .. "':")
      for _, cmd in ipairs(cmds) do
        emit("    " .. cmd)
      end
    else
      emit("  (could not generate promotion commands: " .. tostring(cmds_err) .. ")")
    end
  end

  -- Store the first approval_id on the task (primary handle for resume).
  t.approval_id = approval_ids[1]

  -- Persist task state so it survives process exit.
  if deps.state and type(deps.state.save) == "function" then
    deps.state.save(t)
  end

  emit("")
  emit("  Task paused for human approval.")
  emit("  Run the promotion commands above, then:")
  emit("    ./agent resume")

  -- The task stays in APPROVAL — this is a pause point, not a transition.
  -- run() will exit the loop because task.is_paused(t) returns true.
  return t
end

-- ---------------------------------------------------------------------------
-- Dispatch table
-- ---------------------------------------------------------------------------

local HANDLERS = {
  [("pending")]    = handle_pending,
  [("planning")]   = handle_planning,
  [("executing")]  = handle_executing,
  [("testing")]    = handle_testing,
  [("approval")]   = handle_approval,
  -- Remaining handlers (replanning) added in 3e+.
}

-- ---------------------------------------------------------------------------
-- Public API: step
-- ---------------------------------------------------------------------------

--- Execute one step of the state machine for task t.
--- Dispatches t.status to the appropriate handler.
--- Returns t (mutated) on success, or nil + error_string on hard failure.
---
--- Note: a "hard failure" is when the dispatch table has no handler for the
--- current status (i.e. a programming error or an unimplemented state).
--- Handler-level failures (planner errors, etc.) are expressed as status
--- transitions (→ REPLANNING or → FAILED) rather than nil returns.
function M.step(deps, t)
  local handler = HANDLERS[t.status]
  if not handler then
    return nil, "agent.step: no handler for status '" .. tostring(t.status) .. "'"
  end
  return handler(deps, t)
end

-- ---------------------------------------------------------------------------
-- Public API: run
-- ---------------------------------------------------------------------------

--- Create a task from prompt and drive it through the state machine until it
--- reaches a terminal or paused state (or max_steps is exceeded).
---
--- @param deps   table   Dependency table (see module doc).
--- @param prompt string  The user's task description.
--- @param opts   table   Optional:
---                         max_steps     = 20
---                         context_files = {}
---
--- @return table|nil, string  Completed task table, or nil + error_string.
function M.run(deps, prompt, opts)
  if type(deps) ~= "table" then
    deps = default_deps()
  end
  opts = opts or {}

  if type(prompt) ~= "string" or prompt == "" then
    return nil, "agent.run: prompt must be a non-empty string"
  end

  local max_steps = opts.max_steps or 20

  local t = deps.task.new(prompt)
  t.context_files = opts.context_files or {}

  local steps = 0
  while not deps.task.is_terminal(t) and not deps.task.is_paused(t) do
    steps = steps + 1
    if steps > max_steps then
      deps.task.transition(t, deps.task.FAILED,
        "agent.run: exceeded max_steps (" .. max_steps .. ")")
      break
    end

    local result, err = M.step(deps, t)
    if not result then
      -- Hard failure from step (unhandled status); fail the task.
      deps.task.transition(t, deps.task.FAILED, tostring(err))
      break
    end
  end

  return t
end

-- ---------------------------------------------------------------------------
-- Public API: resume
-- ---------------------------------------------------------------------------

--- Resume a paused (APPROVAL) task.
--- Placeholder — full implementation in Step 3c when approval handler is added.
---
--- @param deps  table
--- @param task_obj table  A task table in APPROVAL status.
--- @param opts  table     Optional.
---
--- @return table|nil, string
function M.resume(deps, task_obj, opts)
  if type(deps) ~= "table" then
    deps = default_deps()
  end

  if type(task_obj) ~= "table" then
    return nil, "agent.resume: task_obj must be a table"
  end

  if task_obj.status ~= deps.task.APPROVAL then
    return nil, "agent.resume: task is not paused (status: " .. tostring(task_obj.status) .. ")"
  end

  -- Drive the loop from the current (APPROVAL) state.
  opts = opts or {}
  local max_steps = opts.max_steps or 20
  local steps     = 0

  while not deps.task.is_terminal(task_obj) and not deps.task.is_paused(task_obj) do
    steps = steps + 1
    if steps > max_steps then
      deps.task.transition(task_obj, deps.task.FAILED,
        "agent.resume: exceeded max_steps (" .. max_steps .. ")")
      break
    end

    local result, err = M.step(deps, task_obj)
    if not result then
      deps.task.transition(task_obj, deps.task.FAILED, tostring(err))
      break
    end
  end

  return task_obj
end

return M
