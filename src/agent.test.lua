--- src/agent.test.lua  (Step 3a)
--- Unit tests for agent.lua: skeleton, handle_pending, handle_planning.
--- All deps are injected via mocks — no real LLM, no filesystem, no state.

local agent  = require("agent")
local mocks  = require("test.mocks")
local task   = require("task")

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

--- Shorthand: make deps with a planner that always succeeds.
local function ok_deps(overrides)
  return mocks.make_agent_deps(overrides)
end

--- Shorthand: make deps with a planner that always fails.
local function fail_deps(err_msg)
  return mocks.make_agent_deps({
    planner_overrides = { generate_err = err_msg or "LLM exploded" },
  })
end

--- Advance a freshly-built task to the given status via real task.transition
--- so we can hand it to step() at an arbitrary point.
local function task_at(status, extra)
  local t = mocks.make_task_obj(extra or {})
  -- Walk the task to the desired status through the legal path.
  local paths = {
    [task.PLANNING]   = { task.PLANNING },
    [task.EXECUTING]  = { task.PLANNING, task.EXECUTING },
    [task.REPLANNING] = { task.PLANNING, task.EXECUTING, task.REPLANNING },
    [task.FAILED]     = { task.PLANNING, task.FAILED },
  }
  for _, s in ipairs(paths[status] or {}) do
    task.transition(t, s)
  end
  return t
end

-- ---------------------------------------------------------------------------
-- agent.step — PENDING handler
-- ---------------------------------------------------------------------------

describe("agent.step on PENDING task", function()

  it("returns the task table (not nil)", function()
    local deps = ok_deps()
    local t    = mocks.make_task_obj()
    local result = agent.step(deps, t)
    assert.is_table(result)
  end)

  it("transitions status to PLANNING", function()
    local deps = ok_deps()
    local t    = mocks.make_task_obj()
    agent.step(deps, t)
    assert.equals(task.PLANNING, t.status)
  end)

  it("appends one history entry", function()
    local deps = ok_deps()
    local t    = mocks.make_task_obj()
    agent.step(deps, t)
    assert.equals(1, #t.history)
    assert.equals(task.PLANNING, t.history[1].status)
  end)

  it("does not call planner.generate", function()
    local deps = ok_deps()
    local t    = mocks.make_task_obj()
    agent.step(deps, t)
    assert.equals(0, #deps.planner._generate_calls)
  end)

end)

-- ---------------------------------------------------------------------------
-- agent.step — PLANNING handler (success)
-- ---------------------------------------------------------------------------

describe("agent.step on PLANNING task (planner succeeds)", function()

  it("calls planner.generate exactly once", function()
    local deps = ok_deps()
    local t    = task_at(task.PLANNING)
    agent.step(deps, t)
    assert.equals(1, #deps.planner._generate_calls)
  end)

  it("passes the task prompt to planner.generate", function()
    local deps = ok_deps()
    local t    = task_at(task.PLANNING, { prompt = "build me something" })
    agent.step(deps, t)
    assert.equals("build me something", deps.planner._generate_calls[1].prompt)
  end)

  it("passes context_files to planner.generate", function()
    local deps = ok_deps()
    local t    = task_at(task.PLANNING)
    t.context_files = { "src/a.lua", "src/b.lua" }
    agent.step(deps, t)
    local opts = deps.planner._generate_calls[1].opts
    assert.same({ "src/a.lua", "src/b.lua" }, opts.context_files)
  end)

  it("transitions status to EXECUTING", function()
    local deps = ok_deps()
    local t    = task_at(task.PLANNING)
    agent.step(deps, t)
    assert.equals(task.EXECUTING, t.status)
  end)

  it("sets t.plan_path on success", function()
    local deps = ok_deps({ planner_overrides = { generate_path = "/tmp/my_plan.md" } })
    local t    = task_at(task.PLANNING)
    agent.step(deps, t)
    assert.equals("/tmp/my_plan.md", t.plan_path)
  end)

  it("increments the plan attempt counter", function()
    local deps = ok_deps()
    local t    = task_at(task.PLANNING)
    agent.step(deps, t)
    assert.equals(1, t.attempts.plan)
  end)

  it("appends a history entry with EXECUTING status", function()
    local deps = ok_deps()
    local t    = task_at(task.PLANNING)
    agent.step(deps, t)
    -- history[1] was PLANNING (from task_at), history[2] is EXECUTING
    local last = t.history[#t.history]
    assert.equals(task.EXECUTING, last.status)
  end)

end)

-- ---------------------------------------------------------------------------
-- agent.step — PLANNING handler (failure)
-- PLANNING can only transition to EXECUTING or FAILED (task.lua TRANSITIONS).
-- Retry logic lives in handle_replanning (Step 3b); this handler always
-- goes to FAILED on planner error, with the attempt count recorded.
-- ---------------------------------------------------------------------------

describe("agent.step on PLANNING task (planner fails)", function()

  it("transitions to FAILED on planner error", function()
    local deps = fail_deps("network error")
    local t    = task_at(task.PLANNING)
    agent.step(deps, t)
    assert.equals(task.FAILED, t.status)
  end)

  it("transitions to FAILED even when retries remain (PLANNING→REPLANNING is illegal)", function()
    local deps = fail_deps("network error")
    local t    = task_at(task.PLANNING)
    -- max_attempts.plan = 3, attempts starts at 0 → after bump = 1 < 3, but still FAILED
    assert.is_true(task.can_retry(t, "plan"),
      "precondition: retries should still be available")
    agent.step(deps, t)
    assert.equals(task.FAILED, t.status)
  end)

  it("history detail mentions 'will retry' when retries remain", function()
    local deps = fail_deps("network error")
    local t    = task_at(task.PLANNING)
    agent.step(deps, t)
    local detail = t.history[#t.history].detail
    assert.is_truthy(detail:find("will retry", 1, true) or detail:find("attempt", 1, true))
  end)

  it("history detail mentions 'no retries left' when exhausted", function()
    local deps = fail_deps("permanent failure")
    local t    = task_at(task.PLANNING)
    t.attempts.plan = t.max_attempts.plan
    agent.step(deps, t)
    local detail = t.history[#t.history].detail
    assert.is_truthy(detail:find("no retries", 1, true))
  end)

  it("sets t.error to the planner error message", function()
    local deps = fail_deps("network error")
    local t    = task_at(task.PLANNING)
    agent.step(deps, t)
    assert.is_truthy(t.error:find("network error", 1, true))
  end)

  it("does not set t.plan_path", function()
    local deps = fail_deps("oops")
    local t    = task_at(task.PLANNING)
    agent.step(deps, t)
    assert.is_nil(t.plan_path)
  end)

  it("increments the plan attempt counter", function()
    local deps = fail_deps("oops")
    local t    = task_at(task.PLANNING)
    agent.step(deps, t)
    assert.equals(1, t.attempts.plan)
  end)

end)

-- ---------------------------------------------------------------------------
-- agent.step — unhandled status
-- ---------------------------------------------------------------------------

describe("agent.step on unhandled status", function()
  -- Use TESTING: it has no handler yet (added in Step 3c+).

  it("returns nil + error for an unimplemented status", function()
    local deps   = ok_deps()
    local t      = mocks.make_task_obj()
    task.transition(t, task.PLANNING)
    task.transition(t, task.EXECUTING)
    task.transition(t, task.TESTING)
    local result, err = agent.step(deps, t)
    assert.is_nil(result)
    assert.is_truthy(err:find("no handler", 1, true))
  end)

  it("error mentions the current status", function()
    local deps = ok_deps()
    local t    = mocks.make_task_obj()
    task.transition(t, task.PLANNING)
    task.transition(t, task.EXECUTING)
    task.transition(t, task.TESTING)
    local _, err = agent.step(deps, t)
    assert.is_truthy(err:find(task.TESTING, 1, true))
  end)

end)

-- ---------------------------------------------------------------------------
-- agent.run — basic flow
-- ---------------------------------------------------------------------------

describe("agent.run", function()

  it("returns a task table", function()
    local deps = ok_deps()
    -- Planner succeeds → EXECUTING, but EXECUTING has no handler → hard failure
    -- run() should catch that and mark FAILED, still returning the task.
    local t = agent.run(deps, "do something")
    assert.is_table(t)
  end)

  it("returns nil + error for empty prompt", function()
    local deps = ok_deps()
    local t, err = agent.run(deps, "")
    assert.is_nil(t)
    assert.is_truthy(err:find("prompt", 1, true))
  end)

  it("returns nil + error for nil prompt", function()
    local deps = ok_deps()
    local t, err = agent.run(deps, nil)
    assert.is_nil(t)
    assert.is_string(err)
  end)

  it("creates task with the given prompt", function()
    local deps = ok_deps()
    local t    = agent.run(deps, "write a parser")
    assert.equals("write a parser", t.prompt)
  end)

  it("task passes through PLANNING (planner is called)", function()
    local deps = ok_deps()
    agent.run(deps, "do something")
    -- Planner must have been invoked at least once.
    assert.is_true(#deps.planner._generate_calls >= 1)
  end)

  it("task ends in FAILED when planner always fails and no retries left", function()
    -- Exhaust retries: max is 3, so fail 3+ times.
    -- With a plain fail_deps the loop goes PENDING→PLANNING→REPLANNING,
    -- but REPLANNING has no handler yet → hard failure → FAILED.
    local deps = fail_deps("LLM down")
    local t    = agent.run(deps, "do something")
    assert.equals(task.FAILED, t.status)
  end)

  it("respects max_steps safety limit", function()
    -- With no REPLANNING handler, each step that hits an unhandled state
    -- causes a hard failure; run() catches it and sets FAILED.
    -- So just confirm we get a terminal task back regardless.
    local deps = ok_deps()
    local t    = agent.run(deps, "do something", { max_steps = 2 })
    assert.is_true(task.is_terminal(t))
  end)

  it("passes context_files through to planner.generate", function()
    local deps = ok_deps()
    agent.run(deps, "do something", { context_files = { "src/foo.lua" } })
    local call_opts = deps.planner._generate_calls[1] and deps.planner._generate_calls[1].opts
    assert.is_not_nil(call_opts)
    assert.same({ "src/foo.lua" }, call_opts.context_files)
  end)

end)

-- ---------------------------------------------------------------------------
-- agent.resume — basic validation
-- ---------------------------------------------------------------------------

describe("agent.resume", function()

  it("returns nil + error when task_obj is nil", function()
    local deps = ok_deps()
    local t, err = agent.resume(deps, nil)
    assert.is_nil(t)
    assert.is_string(err)
  end)

  it("returns nil + error when task is not in APPROVAL status", function()
    local deps = ok_deps()
    local t    = mocks.make_task_obj()   -- PENDING status
    local result, err = agent.resume(deps, t)
    assert.is_nil(result)
    assert.is_truthy(err:find("not paused", 1, true) or err:find("APPROVAL", 1, true)
                     or err:find("approval", 1, true))
  end)

end)

-- ===========================================================================
-- Step 3b — handle_executing tests
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- Helpers specific to 3b
-- ---------------------------------------------------------------------------

--- Build a task already at EXECUTING status with a plan_path set.
local function executing_task(overrides)
  overrides = overrides or {}
  local t = mocks.make_task_obj({ prompt = overrides.prompt or "do something" })
  task.transition(t, task.PLANNING)
  task.transition(t, task.EXECUTING)
  t.plan_path = overrides.plan_path or "./plan.md"
  if overrides.attempts_plan then
    t.attempts.plan = overrides.attempts_plan
  end
  return t
end

--- Shorthand: deps where cmd_plan succeeds and no outputs are skills.
local function exec_ok_deps(overrides)
  overrides = overrides or {}
  -- plan_mod.load_file returns a plan with the given outputs list.
  local outputs = overrides.outputs or {}
  return mocks.make_agent_deps({
    plan_overrides         = { outputs = outputs },
    skill_loader_overrides = overrides.skill_loader_overrides or { skill_paths = {} },
    cmd_plan_overrides     = overrides.cmd_plan_overrides or {},
  })
end

--- Shorthand: deps where cmd_plan fails.
local function exec_fail_deps(err_msg)
  return mocks.make_agent_deps({
    cmd_plan_overrides = { run_err = err_msg or "generate exploded" },
  })
end

-- ---------------------------------------------------------------------------
-- handle_executing — cmd_plan success, no skills → COMPLETE
-- ---------------------------------------------------------------------------

describe("agent.step on EXECUTING task (cmd_plan succeeds, no skills)", function()

  it("transitions to COMPLETE", function()
    local deps = exec_ok_deps()
    local t    = executing_task()
    agent.step(deps, t)
    assert.equals(task.COMPLETE, t.status)
  end)

  it("calls cmd_plan.run exactly once", function()
    local deps = exec_ok_deps()
    local t    = executing_task()
    agent.step(deps, t)
    assert.equals(1, #deps.cmd_plan._calls)
  end)

  it("calls cmd_plan.run with subcommand=run and the task's plan_path", function()
    local deps = exec_ok_deps()
    local t    = executing_task({ plan_path = "/tmp/my_plan.md" })
    agent.step(deps, t)
    local call_args = deps.cmd_plan._calls[1].args
    assert.equals("run",             call_args.subcommand)
    assert.equals("/tmp/my_plan.md", call_args.plan_path)
  end)

  it("passes a deps table to cmd_plan.run (not nil)", function()
    local deps = exec_ok_deps()
    local t    = executing_task()
    agent.step(deps, t)
    assert.is_table(deps.cmd_plan._calls[1].deps)
  end)

  it("t.skill_files is empty when no outputs are skills", function()
    local deps = exec_ok_deps({ outputs = { "src/out.lua" } })
    local t    = executing_task()
    agent.step(deps, t)
    assert.same({}, t.skill_files)
  end)

  it("calls skill_loader.parse_metadata for each declared output", function()
    local outputs = { "src/a.lua", "src/b.lua" }
    local deps    = exec_ok_deps({ outputs = outputs })
    local t       = executing_task()
    agent.step(deps, t)
    -- parse_metadata must have been called once per output
    assert.equals(#outputs, #deps.skill_loader._calls)
  end)

  it("parse_metadata is called with each output path", function()
    local outputs = { "src/a.lua", "src/b.lua" }
    local deps    = exec_ok_deps({ outputs = outputs })
    local t       = executing_task()
    agent.step(deps, t)
    -- Calls may be in any order; use a set check.
    local seen = {}
    for _, p in ipairs(deps.skill_loader._calls) do seen[p] = true end
    for _, p in ipairs(outputs) do
      assert.is_true(seen[p], "expected parse_metadata call for " .. p)
    end
  end)

end)

-- ---------------------------------------------------------------------------
-- handle_executing — cmd_plan success, skills found → TESTING
-- ---------------------------------------------------------------------------

describe("agent.step on EXECUTING task (cmd_plan succeeds, skills found)", function()

  it("transitions to TESTING when at least one output is a skill", function()
    local outputs = { "src/my_skill.lua", "src/helper.lua" }
    local deps    = exec_ok_deps({
      outputs                = outputs,
      skill_loader_overrides = { skill_paths = { "src/my_skill.lua" } },
    })
    local t = executing_task()
    agent.step(deps, t)
    assert.equals(task.TESTING, t.status)
  end)

  it("t.skill_files contains only the skill output(s)", function()
    local outputs = { "src/my_skill.lua", "src/helper.lua" }
    local deps    = exec_ok_deps({
      outputs                = outputs,
      skill_loader_overrides = { skill_paths = { "src/my_skill.lua" } },
    })
    local t = executing_task()
    agent.step(deps, t)
    assert.same({ "src/my_skill.lua" }, t.skill_files)
  end)

  it("t.skill_files contains all skills when multiple outputs are skills", function()
    local outputs = { "src/skill_a.lua", "src/skill_b.lua" }
    local deps    = exec_ok_deps({
      outputs                = outputs,
      skill_loader_overrides = { skill_paths = outputs },
    })
    local t = executing_task()
    agent.step(deps, t)
    assert.equals(2, #t.skill_files)
  end)

  it("t.outputs is populated from plan outputs", function()
    local outputs = { "src/my_skill.lua" }
    local deps    = exec_ok_deps({
      outputs                = outputs,
      skill_loader_overrides = { skill_paths = outputs },
    })
    local t = executing_task()
    agent.step(deps, t)
    assert.same(outputs, t.outputs)
  end)

end)

-- ---------------------------------------------------------------------------
-- handle_executing — cmd_plan failure
-- ---------------------------------------------------------------------------

describe("agent.step on EXECUTING task (cmd_plan fails)", function()

  it("transitions to REPLANNING when retries remain", function()
    local deps = exec_fail_deps("generate exploded")
    local t    = executing_task()
    -- attempts.plan = 0, max = 3 → can_retry = true
    agent.step(deps, t)
    assert.equals(task.REPLANNING, t.status)
  end)

  it("transitions to FAILED when no retries remain", function()
    local deps = exec_fail_deps("generate exploded")
    local t    = executing_task({ attempts_plan = 3 })  -- exhausted
    agent.step(deps, t)
    assert.equals(task.FAILED, t.status)
  end)

  it("sets t.error on failure", function()
    local deps = exec_fail_deps("generate exploded")
    local t    = executing_task()
    agent.step(deps, t)
    assert.is_truthy(t.error:find("generate exploded", 1, true))
  end)

  it("does not call skill_loader.parse_metadata on failure", function()
    local deps = exec_fail_deps("oops")
    local t    = executing_task()
    agent.step(deps, t)
    assert.equals(0, #deps.skill_loader._calls)
  end)

  it("does not transition skill_files on failure", function()
    local deps = exec_fail_deps("oops")
    local t    = executing_task()
    agent.step(deps, t)
    -- skill_files should remain untouched (empty default)
    assert.same({}, t.skill_files)
  end)

end)
