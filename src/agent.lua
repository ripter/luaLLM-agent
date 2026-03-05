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
--- Step 3e: handle_replanning.
--- Step 3f: agent.resume (promotion flow).
--- Step 3g: agent.run() wired end-to-end.

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
  -- Fast-path: handle_replanning sets t.plan_path before transitioning back
  -- here, meaning a new plan.md is already on disk and validated.
  -- Skip the LLM call and go straight to EXECUTING.
  if t.plan_path then
    deps.task.transition(t, deps.task.EXECUTING,
      "using existing plan: " .. t.plan_path)
    return t
  end

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
  -- When the planner fails we always go to FAILED here.
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
-- Internal helpers: skill path conventions
-- ---------------------------------------------------------------------------

--- Derive the test file path from a skill file path.
--- Convention: "path/to/foo.lua"  →  "path/to/foo.test.lua"
local function test_path_for(skill_path)
  return (skill_path:gsub("%.lua$", ".test.lua"))
end

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

--- Create approval records for all skills in t.skill_files.
--- Sets t.approval_id (first record's id).
--- Prints promotion commands.
--- Returns true on success, or transitions t to FAILED and returns false.
local function create_approval_records(deps, t)
  local emit        = deps.print or function(_) end
  local allowed_dir = deps.config.get("skills.allowed_dir") or "./skills"
  local approval_ids = {}

  for _, skill_path in ipairs(t.skill_files or {}) do
    local skill_name = skill_name_for(skill_path)
    local test_path  = test_path_for(skill_path)

    local skill_results     = results_for(t.test_results, skill_path)
    local test_results_arg  = skill_results and { skill_results } or {}

    local metadata = nil
    if deps.skill_loader then
      local meta, _ = deps.skill_loader.parse_metadata(skill_path)
      metadata = meta
    end

    local record, err = deps.approval.create(
      skill_name, skill_path, test_path, test_results_arg, metadata or {}
    )

    if not record then
      deps.task.transition(t, deps.task.FAILED,
        "approval.create failed for '" .. skill_path .. "': " .. tostring(err))
      return false
    end

    approval_ids[#approval_ids + 1] = record.id

    local cmds, cmds_err = deps.approval.get_promotion_commands(record, allowed_dir)
    if cmds then
      emit("")
      emit("  Promote '" .. skill_name .. "':")
      for _, cmd in ipairs(cmds) do emit("    " .. cmd) end
    else
      emit("  (could not generate promotion commands: " .. tostring(cmds_err) .. ")")
    end
  end

  t.approval_id = approval_ids[1]

  if deps.state and type(deps.state.save) == "function" then
    deps.state.save(t)
  end

  emit("")
  emit("  Task paused for human approval.")
  emit("  Run the promotion commands above, then:")
  emit("    ./agent resume")

  return true
end

-- ---------------------------------------------------------------------------
-- Handler: TESTING → APPROVAL | REPLANNING | FAILED
-- ---------------------------------------------------------------------------

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
    -- All tests passed: create approval records before transitioning to APPROVAL
    -- so that approval_id is set on the task when run() pauses the loop.
    create_approval_records(deps, t)
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

-- handle_approval: called by step() when a task is already in APPROVAL status
-- (e.g. from direct step() calls in tests, or future re-entry after process restart).
-- In the normal run() flow, approval records are created by handle_testing via
-- create_approval_records() before the APPROVAL transition, so this handler is
-- a no-op that simply returns the paused task.
local function handle_approval(deps, t)
  -- If approval records haven't been created yet (direct step() call in tests),
  -- create them now.
  if not t.approval_id then
    create_approval_records(deps, t)
  end
  return t
end

-- ---------------------------------------------------------------------------
-- Handler: REPLANNING → PLANNING | FAILED
-- ---------------------------------------------------------------------------

local function handle_replanning(deps, t)
  deps.task.bump_attempt(t, "replan")

  -- Build error_info from what the task recorded during testing/executing.
  local error_info = {
    phase     = "testing",
    message   = t.error or "unknown error",
    plan_text = t.plan_text,
  }

  -- Attach test output if any tests were recorded.
  if type(t.test_results) == "table" and #t.test_results > 0 then
    local parts = {}
    for _, r in ipairs(t.test_results) do
      if not r.passed then
        parts[#parts + 1] = (r.skill_path or r.test_path or "?") .. ":\n" .. (r.output or "")
      end
    end
    if #parts > 0 then
      error_info.test_output = table.concat(parts, "\n---\n")
    end
  end

  -- Clear the old plan_path so handle_planning does not short-circuit on the
  -- stale path; replan will set a new one below.
  t.plan_path = nil
  t.plan_text = nil

  local plan_path, result = deps.planner.replan(deps, t, error_info)

  if plan_path then
    t.plan_path = plan_path
    t.plan_text = read_plan_text(plan_path) or nil
    deps.task.transition(t, deps.task.PLANNING,
      "replan succeeded: " .. plan_path)
    return t
  end

  local err = tostring(result)
  t.error = err
  deps.task.transition(t, deps.task.FAILED,
    "replan failed: " .. err)
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
  [("replanning")] = handle_replanning,
  -- All handlers registered.
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
--- state.save is called after every step so the task survives process exit.
---
--- @param deps   table   Dependency table (see module doc).
--- @param prompt string  The user's task description.
--- @param opts   table   Optional:
---                         max_steps     = 20  (default)
---                         context_files = {}
---
--- @return task_table  Always returns the task (never nil).
---         Returns nil, err_string only for invalid arguments.
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

  for _ = 1, max_steps do
    -- Exit before stepping if the task is already at a pause/terminal point.
    -- This prevents re-entering a handler after it has set a final status.
    if deps.task.is_terminal(t) then
      return t
    end
    if deps.task.is_paused(t) then
      return t   -- caller should exit; resume later via agent.resume()
    end

    local ok, err = M.step(deps, t)
    if not ok then
      -- Hard failure (unhandled status or internal error); fail the task.
      t.error = tostring(err)
      deps.task.transition(t, deps.task.FAILED, t.error)
    end

    if deps.state and type(deps.state.save) == "function" then
      deps.state.save(t)
    end
  end

  -- Exhausted max_steps without reaching a terminal/paused state.
  t.error = "max steps exceeded (" .. max_steps .. ")"
  deps.task.transition(t, deps.task.FAILED, t.error)
  if deps.state and type(deps.state.save) == "function" then
    deps.state.save(t)
  end
  return t
end

-- ---------------------------------------------------------------------------
-- Public API: resume
-- ---------------------------------------------------------------------------

--- Resume a paused task from saved state.
---
--- Flow:
---   1. Load the task from deps.state.load() (or accept task_obj directly for tests).
---   2. If status is APPROVAL: run the promotion-check / human-prompt loop.
---   3. All skills promoted → COMPLETE.  Human rejects → FAILED.
---
--- @param deps     table   Dependency table.
--- @param task_obj table   Optional: pre-loaded task (used by tests / internal callers).
---                          When nil, task is loaded from deps.state.load().
--- @param opts     table   Optional.
---
--- @return table|nil, string
function M.resume(deps, task_obj, opts)
  if type(deps) ~= "table" then
    deps = default_deps()
  end
  opts = opts or {}

  local emit        = deps.print or function(_) end
  local allowed_dir = deps.config.get("skills.allowed_dir") or "./skills"
  local approvals_dir = deps.config.get("approvals.dir") or nil  -- nil → approval default

  -- Load task from state if not supplied directly.
  if task_obj == nil then
    if not deps.state or type(deps.state.load) ~= "function" then
      return nil, "agent.resume: no saved task (state.load unavailable)"
    end
    local loaded, load_err = deps.state.load()
    if not loaded then
      return nil, "agent.resume: no saved task: " .. tostring(load_err)
    end
    task_obj = loaded
  end

  if type(task_obj) ~= "table" then
    return nil, "agent.resume: task_obj must be a table"
  end

  if task_obj.status ~= deps.task.APPROVAL then
    emit("  Task status is '" .. tostring(task_obj.status)
         .. "' — nothing to resume (not waiting for approval).")
    return task_obj
  end

  -- Build a list of (skill_path, skill_name, approval_id) triples from skill_files.
  -- We pair each skill_file with the stored approval_id; for multi-skill tasks the
  -- IDs are stored in t.approval_ids (set by handle_approval) or we fall back to
  -- t.approval_id for the single-skill common case.
  local skill_entries = {}
  local approval_ids  = task_obj.approval_ids
                     or (task_obj.approval_id and { task_obj.approval_id })
                     or {}

  for i, skill_path in ipairs(task_obj.skill_files or {}) do
    skill_entries[#skill_entries + 1] = {
      skill_path  = skill_path,
      skill_name  = skill_name_for(skill_path),
      approval_id = approval_ids[i],
    }
  end

  if #skill_entries == 0 then
    -- No skills to check; transition directly to COMPLETE.
    deps.task.transition(task_obj, deps.task.COMPLETE, "resume: no skills to promote")
    if deps.state and type(deps.state.save) == "function" then
      deps.state.save(task_obj)
    end
    return task_obj
  end

  -- Check promotion status for each skill.
  local function all_promoted()
    for _, entry in ipairs(skill_entries) do
      if not deps.approval.check_promotion(entry.skill_name, allowed_dir) then
        return false
      end
    end
    return true
  end

  if all_promoted() then
    deps.task.transition(task_obj, deps.task.COMPLETE, "all skills promoted")
    if deps.state and type(deps.state.save) == "function" then
      deps.state.save(task_obj)
    end
    emit("  All skills promoted. Task complete.")
    return task_obj
  end

  -- At least one skill is not yet promoted — prompt the human.
  for _, entry in ipairs(skill_entries) do
    if deps.approval.check_promotion(entry.skill_name, allowed_dir) then
      goto continue
    end

    -- Fetch the full approval record (needed by prompt_human).
    local record = nil
    if entry.approval_id then
      local r, get_err = deps.approval.get(approvals_dir, entry.approval_id)
      if r then
        record = r
      else
        emit("  Warning: could not load approval record for '"
             .. entry.skill_name .. "': " .. tostring(get_err))
      end
    end

    -- Fall back to a minimal record if get failed or no ID stored.
    if not record then
      record = {
        skill_name = entry.skill_name,
        skill_path = entry.skill_path,
        test_path  = test_path_for(entry.skill_path),
      }
    end

    local choice = deps.approval.prompt_human(record)

    if choice == "approve" or choice == "y" then
      -- Print promotion commands so the human can run them.
      local cmds, cmds_err = deps.approval.get_promotion_commands(record, allowed_dir)
      if cmds then
        emit("")
        emit("  Run these commands to promote '" .. entry.skill_name .. "':")
        for _, cmd in ipairs(cmds) do emit("    " .. cmd) end
        emit("")
        emit("  Then run:  ./agent resume")
      else
        emit("  (could not generate promotion commands: " .. tostring(cmds_err) .. ")")
      end
      -- Return the task still in APPROVAL — the human must re-run resume.
      return task_obj

    elseif choice == "reject" or choice == "n" then
      deps.task.transition(task_obj, deps.task.FAILED,
        "human rejected skill '" .. entry.skill_name .. "'")
      if deps.state and type(deps.state.save) == "function" then
        deps.state.save(task_obj)
      end
      return task_obj
    end
    -- Other choices (view, rerun, edit, print_promote, mark_promoted) fall
    -- through — the human must re-run resume to re-enter the loop.

    ::continue::
  end

  return task_obj
end

return M
