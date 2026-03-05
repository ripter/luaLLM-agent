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
  -- Inject a bogus status directly — all real statuses now have handlers.

  it("returns nil + error for an unknown status", function()
    local deps = ok_deps()
    local t    = mocks.make_task_obj()
    t.status   = "bogus_status"
    local result, err = agent.step(deps, t)
    assert.is_nil(result)
    assert.is_truthy(err:find("no handler", 1, true))
  end)

  it("error mentions the unknown status string", function()
    local deps = ok_deps()
    local t    = mocks.make_task_obj()
    t.status   = "bogus_status"
    local _, err = agent.step(deps, t)
    assert.is_truthy(err:find("bogus_status", 1, true))
  end)

end)

-- ---------------------------------------------------------------------------
-- agent.run — basic flow
-- ---------------------------------------------------------------------------

describe("agent.run", function()

  it("returns a task table", function()
    local deps = ok_deps()
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
    local deps = fail_deps("LLM down")
    local t    = agent.run(deps, "do something")
    assert.equals(task.FAILED, t.status)
  end)

  it("respects max_steps safety limit", function()
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

  it("returns nil + error when task_obj is nil and state has no saved task", function()
    local deps = ok_deps()
    -- ok_deps has no state.load, so passing nil task_obj → "no saved task" error.
    local result, err = agent.resume(deps, nil)
    assert.is_nil(result)
    assert.is_string(err)
    assert.is_truthy(err:find("no saved task", 1, true))
  end)

  it("returns the task (not nil) when status is not APPROVAL", function()
    -- New behaviour: non-APPROVAL is not an error; task is returned with a message.
    local deps   = ok_deps()
    local t      = mocks.make_task_obj()   -- PENDING status
    local result = agent.resume(deps, t)
    assert.equals(t, result)
  end)

  it("does not change status when task is not in APPROVAL", function()
    local deps = ok_deps()
    local t    = mocks.make_task_obj()   -- PENDING status
    agent.resume(deps, t)
    assert.equals(task.PENDING, t.status)
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

-- ===========================================================================
-- Step 3c — handle_testing tests
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- Helpers specific to 3c
-- ---------------------------------------------------------------------------

--- Build a task already at TESTING status with skill_files populated.
local function testing_task(skill_files, overrides)
  overrides   = overrides or {}
  local t = mocks.make_task_obj({ prompt = overrides.prompt or "do something" })
  task.transition(t, task.PLANNING)
  task.transition(t, task.EXECUTING)
  task.transition(t, task.TESTING)
  t.skill_files = skill_files or {}
  if overrides.attempts_test then
    t.attempts.test = overrides.attempts_test
  end
  return t
end

--- Shorthand: deps where all run_tests calls pass by default.
local function testing_ok_deps(overrides)
  return mocks.make_agent_deps(overrides or {})
end

--- Shorthand: deps where run_tests returns specific per-path results.
local function testing_deps_with_results(results_map)
  return mocks.make_agent_deps({
    skill_runner_overrides = { results = results_map },
  })
end

-- ---------------------------------------------------------------------------
-- handle_testing — all tests pass → APPROVAL
-- ---------------------------------------------------------------------------

describe("agent.step on TESTING task (all tests pass)", function()

  it("transitions to APPROVAL when all skill tests pass", function()
    local deps = testing_ok_deps()
    local t    = testing_task({ "src/skill_a.lua" })
    agent.step(deps, t)
    assert.equals(task.APPROVAL, t.status)
  end)

  it("transitions to APPROVAL with multiple passing skills", function()
    local deps = testing_ok_deps()
    local t    = testing_task({ "src/skill_a.lua", "src/skill_b.lua" })
    agent.step(deps, t)
    assert.equals(task.APPROVAL, t.status)
  end)

  it("calls skill_runner.run_tests for each skill file", function()
    local deps = testing_ok_deps()
    local t    = testing_task({ "src/skill_a.lua", "src/skill_b.lua" })
    agent.step(deps, t)
    assert.equals(2, #deps.skill_runner._calls)
  end)

  it("calls run_tests with the .test.lua path derived from each skill path", function()
    local deps = testing_ok_deps()
    local t    = testing_task({ "src/skill_a.lua" })
    agent.step(deps, t)
    assert.equals("src/skill_a.test.lua", deps.skill_runner._calls[1])
  end)

  it("populates t.test_results with one entry per skill", function()
    local deps = testing_ok_deps()
    local t    = testing_task({ "src/skill_a.lua", "src/skill_b.lua" })
    agent.step(deps, t)
    assert.equals(2, #t.test_results)
  end)

  it("each test_result entry records skill_path, test_path, and passed=true", function()
    local deps = testing_ok_deps()
    local t    = testing_task({ "src/skill_a.lua" })
    agent.step(deps, t)
    local r = t.test_results[1]
    assert.equals("src/skill_a.lua",      r.skill_path)
    assert.equals("src/skill_a.test.lua", r.test_path)
    assert.is_true(r.passed)
  end)

  it("transitions to APPROVAL with no skills (empty skill_files)", function()
    -- If TESTING is somehow entered with no skill_files, all-pass vacuously.
    local deps = testing_ok_deps()
    local t    = testing_task({})
    agent.step(deps, t)
    assert.equals(task.APPROVAL, t.status)
  end)

end)

-- ---------------------------------------------------------------------------
-- handle_testing — test failure, retries left → REPLANNING
-- ---------------------------------------------------------------------------

describe("agent.step on TESTING task (test fails, retries left)", function()

  it("transitions to REPLANNING when a test fails and retries remain", function()
    local deps = testing_deps_with_results({
      ["src/skill_a.test.lua"] = { passed = false, output = "FAILED: assertion #1" },
    })
    local t = testing_task({ "src/skill_a.lua" })
    -- attempts.test = 0, max = 2 → after bump = 1 < 2
    agent.step(deps, t)
    assert.equals(task.REPLANNING, t.status)
  end)

  it("sets t.error containing test output on failure", function()
    local deps = testing_deps_with_results({
      ["src/skill_a.test.lua"] = { passed = false, output = "FAILED: assertion #1" },
    })
    local t = testing_task({ "src/skill_a.lua" })
    agent.step(deps, t)
    assert.is_truthy(t.error:find("FAILED: assertion #1", 1, true))
  end)

  it("bumps attempts.test counter on failure", function()
    local deps = testing_deps_with_results({
      ["src/skill_a.test.lua"] = { passed = false, output = "FAILED" },
    })
    local t = testing_task({ "src/skill_a.lua" })
    agent.step(deps, t)
    assert.equals(1, t.attempts.test)
  end)

  it("t.test_results records passed=false for the failing skill", function()
    local deps = testing_deps_with_results({
      ["src/skill_a.test.lua"] = { passed = false, output = "FAILED" },
    })
    local t = testing_task({ "src/skill_a.lua" })
    agent.step(deps, t)
    assert.is_false(t.test_results[1].passed)
  end)

end)

-- ---------------------------------------------------------------------------
-- handle_testing — test failure, no retries → FAILED
-- ---------------------------------------------------------------------------

describe("agent.step on TESTING task (test fails, no retries)", function()

  it("transitions to FAILED when no retries remain", function()
    local deps = testing_deps_with_results({
      ["src/skill_a.test.lua"] = { passed = false, output = "FAILED" },
    })
    local t = testing_task({ "src/skill_a.lua" }, { attempts_test = 2 })
    -- attempts.test = 2 == max_attempts.test → can_retry = false after bump
    agent.step(deps, t)
    assert.equals(task.FAILED, t.status)
  end)

  it("sets t.error on failure with no retries", function()
    local deps = testing_deps_with_results({
      ["src/skill_a.test.lua"] = { passed = false, output = "nothing left" },
    })
    local t = testing_task({ "src/skill_a.lua" }, { attempts_test = 2 })
    agent.step(deps, t)
    assert.is_string(t.error)
    assert.is_truthy(t.error:find("nothing left", 1, true))
  end)

end)

-- ---------------------------------------------------------------------------
-- handle_testing — hard failure from run_tests (missing test file)
-- ---------------------------------------------------------------------------

describe("agent.step on TESTING task (run_tests hard failure)", function()

  it("treats a missing test file as a test failure (retries → REPLANNING)", function()
    -- skill_runner returns nil + error_string for the test path
    local deps = mocks.make_agent_deps({
      skill_runner_overrides = {
        results = {
          ["src/skill_a.test.lua"] = "file not found: src/skill_a.test.lua",
        },
      },
    })
    local t = testing_task({ "src/skill_a.lua" })
    agent.step(deps, t)
    -- Hard failure is folded into the normal failure path; retries remain → REPLANNING
    assert.equals(task.REPLANNING, t.status)
  end)

  it("records the hard-failure message in t.test_results output", function()
    local deps = mocks.make_agent_deps({
      skill_runner_overrides = {
        results = {
          ["src/skill_a.test.lua"] = "file not found: src/skill_a.test.lua",
        },
      },
    })
    local t = testing_task({ "src/skill_a.lua" })
    agent.step(deps, t)
    assert.is_truthy(t.test_results[1].output:find("file not found", 1, true))
  end)

end)

-- ---------------------------------------------------------------------------
-- handle_testing — multiple skills, mixed results
-- ---------------------------------------------------------------------------

describe("agent.step on TESTING task (multiple skills, mixed pass/fail)", function()

  it("transitions to REPLANNING when at least one skill fails", function()
    local deps = testing_deps_with_results({
      ["src/skill_a.test.lua"] = { passed = true,  output = "ok" },
      ["src/skill_b.test.lua"] = { passed = false, output = "FAILED" },
    })
    local t = testing_task({ "src/skill_a.lua", "src/skill_b.lua" })
    agent.step(deps, t)
    assert.equals(task.REPLANNING, t.status)
  end)

  it("t.test_results reflects individual pass/fail per skill", function()
    local deps = testing_deps_with_results({
      ["src/skill_a.test.lua"] = { passed = true,  output = "ok" },
      ["src/skill_b.test.lua"] = { passed = false, output = "FAILED" },
    })
    local t = testing_task({ "src/skill_a.lua", "src/skill_b.lua" })
    agent.step(deps, t)
    -- Find results by skill_path regardless of order.
    local by_skill = {}
    for _, r in ipairs(t.test_results) do by_skill[r.skill_path] = r end
    assert.is_true(by_skill["src/skill_a.lua"].passed)
    assert.is_false(by_skill["src/skill_b.lua"].passed)
  end)

  it("t.error only mentions the failing skill", function()
    local deps = testing_deps_with_results({
      ["src/skill_a.test.lua"] = { passed = true,  output = "ok" },
      ["src/skill_b.test.lua"] = { passed = false, output = "skill_b exploded" },
    })
    local t = testing_task({ "src/skill_a.lua", "src/skill_b.lua" })
    agent.step(deps, t)
    assert.is_truthy(t.error:find("skill_b", 1, true))
  end)

end)

-- ===========================================================================
-- Step 3d — handle_approval tests
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- Helpers specific to 3d
-- ---------------------------------------------------------------------------

--- Build a task already at APPROVAL status with skill_files and test_results set.
local function approval_task(skill_files, overrides)
  overrides   = overrides or {}
  local t = mocks.make_task_obj({ prompt = overrides.prompt or "do something" })
  task.transition(t, task.PLANNING)
  task.transition(t, task.EXECUTING)
  task.transition(t, task.TESTING)
  task.transition(t, task.APPROVAL)
  t.skill_files  = skill_files or {}
  t.test_results = overrides.test_results or {}
  return t
end

--- Shorthand: deps for approval tests with sensible defaults.
local function approval_deps(overrides)
  return mocks.make_agent_deps(overrides or {})
end

-- ---------------------------------------------------------------------------
-- handle_approval — approval.create called correctly
-- ---------------------------------------------------------------------------

describe("agent.step on APPROVAL task (approval.create)", function()

  it("calls approval.create once per skill file", function()
    local deps = approval_deps()
    local t    = approval_task({ "src/skill_a.lua", "src/skill_b.lua" })
    agent.step(deps, t)
    assert.equals(2, #deps.approval._create_calls)
  end)

  it("passes the skill name (basename without .lua) to approval.create", function()
    local deps = approval_deps()
    local t    = approval_task({ "src/my_skill.lua" })
    agent.step(deps, t)
    assert.equals("my_skill", deps.approval._create_calls[1].skill_name)
  end)

  it("passes the skill_path to approval.create", function()
    local deps = approval_deps()
    local t    = approval_task({ "src/my_skill.lua" })
    agent.step(deps, t)
    assert.equals("src/my_skill.lua", deps.approval._create_calls[1].skill_path)
  end)

  it("passes the .test.lua path to approval.create", function()
    local deps = approval_deps()
    local t    = approval_task({ "src/my_skill.lua" })
    agent.step(deps, t)
    assert.equals("src/my_skill.test.lua", deps.approval._create_calls[1].test_path)
  end)

  it("passes matching test_results to approval.create", function()
    local test_results = {
      { skill_path = "src/my_skill.lua", test_path = "src/my_skill.test.lua",
        passed = true, output = "ok" },
    }
    local deps = approval_deps()
    local t    = approval_task({ "src/my_skill.lua" }, { test_results = test_results })
    agent.step(deps, t)
    local passed_results = deps.approval._create_calls[1].test_results
    assert.equals(1, #passed_results)
    assert.equals("src/my_skill.lua", passed_results[1].skill_path)
  end)

  it("passes metadata from skill_loader.parse_metadata to approval.create", function()
    local deps = approval_deps({
      skill_loader_overrides = { skill_paths = { "src/my_skill.lua" } },
    })
    local t = approval_task({ "src/my_skill.lua" })
    agent.step(deps, t)
    -- metadata should be a table (not nil)
    assert.is_table(deps.approval._create_calls[1].metadata)
  end)

end)

-- ---------------------------------------------------------------------------
-- handle_approval — approval_id and task state
-- ---------------------------------------------------------------------------

describe("agent.step on APPROVAL task (task state)", function()

  it("sets t.approval_id from the record returned by approval.create", function()
    local deps = approval_deps({
      approval_overrides = { approval_id = "my-approval-uuid" },
    })
    local t = approval_task({ "src/skill_a.lua" })
    agent.step(deps, t)
    assert.equals("my-approval-uuid", t.approval_id)
  end)

  it("t.approval_id is set to the first skill's record id with multiple skills", function()
    local deps = approval_deps({
      approval_overrides = { approval_id = "first-uuid" },
    })
    local t = approval_task({ "src/skill_a.lua", "src/skill_b.lua" })
    agent.step(deps, t)
    assert.equals("first-uuid", t.approval_id)
  end)

  it("task remains in APPROVAL status (it is a pause point)", function()
    local deps = approval_deps()
    local t    = approval_task({ "src/skill_a.lua" })
    agent.step(deps, t)
    assert.equals(task.APPROVAL, t.status)
  end)

  it("calls state.save with the task", function()
    local deps = approval_deps()
    local t    = approval_task({ "src/skill_a.lua" })
    agent.step(deps, t)
    assert.equals(1, #deps.state._saved)
    assert.equals(t, deps.state._saved[1])
  end)

end)

-- ---------------------------------------------------------------------------
-- handle_approval — promotion commands are printed
-- ---------------------------------------------------------------------------

describe("agent.step on APPROVAL task (printed output)", function()

  it("calls approval.get_promotion_commands once per skill", function()
    local deps = approval_deps()
    local t    = approval_task({ "src/skill_a.lua", "src/skill_b.lua" })
    agent.step(deps, t)
    assert.equals(2, #deps.approval._promo_calls)
  end)

  it("passes the record returned by create to get_promotion_commands", function()
    local deps = approval_deps({
      approval_overrides = { approval_id = "check-id" },
    })
    local t = approval_task({ "src/skill_a.lua" })
    agent.step(deps, t)
    local promo_record = deps.approval._promo_calls[1].record
    assert.equals("check-id", promo_record.id)
  end)

  it("passes allowed_dir from config to get_promotion_commands", function()
    local deps = approval_deps({
      config_overrides = { store = { ["skills.allowed_dir"] = "/opt/skills" } },
    })
    local t = approval_task({ "src/skill_a.lua" })
    agent.step(deps, t)
    assert.equals("/opt/skills", deps.approval._promo_calls[1].allowed_dir)
  end)

  it("emits the promotion commands to deps.print", function()
    local printed = {}
    local deps    = approval_deps({
      approval_overrides = { promotion_cmds = { "cp skill.lua /skills/" } },
    })
    deps.print = function(s) printed[#printed + 1] = s end
    local t = approval_task({ "src/skill_a.lua" })
    agent.step(deps, t)
    local found = false
    for _, line in ipairs(printed) do
      if line:find("cp skill.lua /skills/", 1, true) then found = true; break end
    end
    assert.is_true(found, "promotion command should appear in printed output")
  end)

  it("emits resume instructions", function()
    local printed = {}
    local deps    = approval_deps()
    deps.print = function(s) printed[#printed + 1] = s end
    local t = approval_task({ "src/skill_a.lua" })
    agent.step(deps, t)
    local found = false
    for _, line in ipairs(printed) do
      if line:find("resume", 1, true) then found = true; break end
    end
    assert.is_true(found, "should print resume instructions")
  end)

end)

-- ---------------------------------------------------------------------------
-- handle_approval — approval.create failure → FAILED
-- ---------------------------------------------------------------------------

describe("agent.step on APPROVAL task (approval.create fails)", function()

  it("transitions to FAILED when approval.create returns an error", function()
    local deps = approval_deps({
      approval_overrides = { create_err = "disk full" },
    })
    local t = approval_task({ "src/skill_a.lua" })
    agent.step(deps, t)
    assert.equals(task.FAILED, t.status)
  end)

  it("failure detail mentions the skill path", function()
    local deps = approval_deps({
      approval_overrides = { create_err = "disk full" },
    })
    local t = approval_task({ "src/skill_a.lua" })
    agent.step(deps, t)
    local detail = t.history[#t.history].detail
    assert.is_truthy(detail:find("src/skill_a.lua", 1, true))
  end)

end)

-- ===========================================================================
-- Step 3e — handle_replanning tests
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- Helpers specific to 3e
-- ---------------------------------------------------------------------------

--- Build a task at REPLANNING status with error context populated.
local function replanning_task(overrides)
  overrides = overrides or {}
  local t = mocks.make_task_obj({ prompt = overrides.prompt or "do something" })
  task.transition(t, task.PLANNING)
  task.transition(t, task.EXECUTING)
  task.transition(t, task.REPLANNING)
  t.error        = overrides.error        or "something broke"
  t.plan_path    = overrides.plan_path    or "./old_plan.md"
  t.plan_text    = overrides.plan_text    or "## plan\noutput: old.lua\n\n## prompt\nOld.\n"
  t.test_results = overrides.test_results or {}
  if overrides.attempts_replan then
    t.attempts.replan = overrides.attempts_replan
  end
  return t
end

--- Shorthand: deps where replan succeeds, returning a specific path.
local function replan_ok_deps(new_path, extra_overrides)
  return mocks.make_agent_deps({
    planner_overrides = { replan_path = new_path or "./new_plan.md" },
  })
end

--- Shorthand: deps where replan fails.
local function replan_fail_deps(err_msg)
  return mocks.make_agent_deps({
    planner_overrides = { replan_err = err_msg or "LLM unavailable" },
  })
end

-- ---------------------------------------------------------------------------
-- handle_replanning — success path
-- ---------------------------------------------------------------------------

describe("agent.step on REPLANNING task (replan succeeds)", function()

  it("transitions to PLANNING on replan success", function()
    local deps = replan_ok_deps()
    local t    = replanning_task()
    agent.step(deps, t)
    assert.equals(task.PLANNING, t.status)
  end)

  it("sets t.plan_path to the new plan path", function()
    local deps = replan_ok_deps("./plans/revised.md")
    local t    = replanning_task()
    agent.step(deps, t)
    assert.equals("./plans/revised.md", t.plan_path)
  end)

  it("increments the replan attempt counter", function()
    local deps = replan_ok_deps()
    local t    = replanning_task()
    agent.step(deps, t)
    assert.equals(1, t.attempts.replan)
  end)

  it("calls planner.replan exactly once", function()
    local deps = replan_ok_deps()
    local t    = replanning_task()
    agent.step(deps, t)
    assert.equals(1, #deps.planner._replan_calls)
  end)

  it("passes the task to planner.replan", function()
    local deps = replan_ok_deps()
    local t    = replanning_task({ prompt = "build a parser" })
    agent.step(deps, t)
    assert.equals(t, deps.planner._replan_calls[1].task)
  end)

  it("clears the old plan_path before calling replan", function()
    -- Verify that if replan fails, plan_path is nil (not stale).
    local deps = replan_fail_deps("oops")
    local t    = replanning_task({ plan_path = "./stale.md" })
    agent.step(deps, t)
    -- On failure t goes to FAILED; the stale path should have been cleared.
    assert.is_nil(t.plan_path)
  end)

  it("after replan, handle_planning uses the new plan_path (no second LLM call)", function()
    -- Wire a full REPLANNING → PLANNING → EXECUTING sequence via two step() calls.
    local deps = replan_ok_deps("./new_plan.md")
    local t    = replanning_task()
    agent.step(deps, t)          -- REPLANNING → PLANNING (sets plan_path)
    assert.equals(task.PLANNING, t.status)
    agent.step(deps, t)          -- PLANNING → EXECUTING (short-circuit, no generate call)
    assert.equals(task.EXECUTING, t.status)
    -- planner.generate should NOT have been called (only replan was).
    assert.equals(0, #deps.planner._generate_calls)
  end)

end)

-- ---------------------------------------------------------------------------
-- handle_replanning — error_info passed to planner.replan
-- ---------------------------------------------------------------------------

describe("agent.step on REPLANNING task (error_info contents)", function()

  it("error_info.message contains t.error", function()
    local deps = replan_ok_deps()
    local t    = replanning_task({ error = "assertion #3 failed" })
    agent.step(deps, t)
    local ei = deps.planner._replan_calls[1].error_info
    assert.is_truthy(ei.message:find("assertion #3 failed", 1, true))
  end)

  it("error_info.plan_text contains the previous plan text", function()
    local deps = replan_ok_deps()
    local t    = replanning_task({ plan_text = "## plan\noutput: foo.lua\n\n## prompt\nOld.\n" })
    agent.step(deps, t)
    local ei = deps.planner._replan_calls[1].error_info
    assert.equals("## plan\noutput: foo.lua\n\n## prompt\nOld.\n", ei.plan_text)
  end)

  it("error_info.test_output includes output from failing test_results", function()
    local test_results = {
      { skill_path = "src/s.lua", test_path = "src/s.test.lua",
        passed = false, output = "FAILED: expected 1 got 2" },
    }
    local deps = replan_ok_deps()
    local t    = replanning_task({ test_results = test_results })
    agent.step(deps, t)
    local ei = deps.planner._replan_calls[1].error_info
    assert.is_truthy(ei.test_output:find("expected 1 got 2", 1, true))
  end)

  it("error_info.test_output is nil when all tests passed", function()
    local test_results = {
      { skill_path = "src/s.lua", test_path = "src/s.test.lua",
        passed = true, output = "ok" },
    }
    local deps = replan_ok_deps()
    local t    = replanning_task({ test_results = test_results })
    agent.step(deps, t)
    local ei = deps.planner._replan_calls[1].error_info
    assert.is_nil(ei.test_output)
  end)

  it("error_info.test_output is nil when test_results is empty", function()
    local deps = replan_ok_deps()
    local t    = replanning_task({ test_results = {} })
    agent.step(deps, t)
    local ei = deps.planner._replan_calls[1].error_info
    assert.is_nil(ei.test_output)
  end)

end)

-- ---------------------------------------------------------------------------
-- handle_replanning — failure path
-- ---------------------------------------------------------------------------

describe("agent.step on REPLANNING task (replan fails)", function()

  it("transitions to FAILED when planner.replan fails", function()
    local deps = replan_fail_deps("LLM unavailable")
    local t    = replanning_task()
    agent.step(deps, t)
    assert.equals(task.FAILED, t.status)
  end)

  it("sets t.error to the replan error message", function()
    local deps = replan_fail_deps("context window exceeded")
    local t    = replanning_task()
    agent.step(deps, t)
    assert.is_truthy(t.error:find("context window exceeded", 1, true))
  end)

  it("still increments the replan attempt counter on failure", function()
    local deps = replan_fail_deps("oops")
    local t    = replanning_task()
    agent.step(deps, t)
    assert.equals(1, t.attempts.replan)
  end)

end)

-- ---------------------------------------------------------------------------
-- handle_planning short-circuit (plan_path already set by replan)
-- ---------------------------------------------------------------------------

describe("agent.step on PLANNING task (plan_path pre-set by replan)", function()

  it("transitions directly to EXECUTING without calling planner.generate", function()
    local deps = mocks.make_agent_deps()
    local t    = mocks.make_task_obj()
    task.transition(t, task.PLANNING)
    t.plan_path = "./already_replanned.md"
    agent.step(deps, t)
    assert.equals(task.EXECUTING, t.status)
    assert.equals(0, #deps.planner._generate_calls)
  end)

  it("preserves the pre-set plan_path", function()
    local deps = mocks.make_agent_deps()
    local t    = mocks.make_task_obj()
    task.transition(t, task.PLANNING)
    t.plan_path = "./already_replanned.md"
    agent.step(deps, t)
    assert.equals("./already_replanned.md", t.plan_path)
  end)

  it("does not bump the plan attempt counter", function()
    local deps = mocks.make_agent_deps()
    local t    = mocks.make_task_obj()
    task.transition(t, task.PLANNING)
    t.plan_path = "./already_replanned.md"
    agent.step(deps, t)
    assert.equals(0, t.attempts.plan)
  end)

end)

-- ===========================================================================
-- Step 3f — agent.resume (promotion flow) tests
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- Helpers specific to 3f
-- ---------------------------------------------------------------------------

--- Build a task in APPROVAL status with skill_files and approval_id set.
local function approval_task_for_resume(skill_files, overrides)
  overrides = overrides or {}
  local t = mocks.make_task_obj({ prompt = overrides.prompt or "do something" })
  task.transition(t, task.PLANNING)
  task.transition(t, task.EXECUTING)
  task.transition(t, task.TESTING)
  task.transition(t, task.APPROVAL)
  t.skill_files  = skill_files or {}
  t.approval_id  = overrides.approval_id or "test-approval-id"
  t.test_results = overrides.test_results or {}
  return t
end

--- Build deps suitable for resume tests.
local function resume_deps(overrides)
  return mocks.make_agent_deps(overrides or {})
end

-- ---------------------------------------------------------------------------
-- agent.resume — no saved task
-- ---------------------------------------------------------------------------

describe("agent.resume with no saved task", function()

  it("returns nil + error when state.load returns nil", function()
    local deps  = resume_deps({ state_overrides = { load_err = "file not found" } })
    local result, err = agent.resume(deps)  -- no task_obj → load from state
    assert.is_nil(result)
    assert.is_truthy(err:find("no saved task", 1, true))
  end)

  it("error message includes the underlying load error", function()
    local deps  = resume_deps({ state_overrides = { load_err = "corrupt state file" } })
    local _, err = agent.resume(deps)
    assert.is_truthy(err:find("corrupt state file", 1, true))
  end)

  it("returns nil + error when state dep is absent entirely", function()
    local deps = resume_deps()
    deps.state = nil
    local result, err = agent.resume(deps)
    assert.is_nil(result)
    assert.is_truthy(err:find("no saved task", 1, true))
  end)

end)

-- ---------------------------------------------------------------------------
-- agent.resume — all skills already promoted → COMPLETE
-- ---------------------------------------------------------------------------

describe("agent.resume when all skills are already promoted", function()

  it("transitions the task to COMPLETE", function()
    local t = approval_task_for_resume({ "src/my_skill.lua" })
    local deps = resume_deps({
      approval_overrides = { promoted_skills = { "my_skill" } },
      state_overrides    = { task_to_load = t },
    })
    agent.resume(deps)
    assert.equals(task.COMPLETE, t.status)
  end)

  it("calls check_promotion for each skill", function()
    local t = approval_task_for_resume({ "src/skill_a.lua", "src/skill_b.lua" })
    local deps = resume_deps({
      approval_overrides = { promoted_skills = { "skill_a", "skill_b" } },
      state_overrides    = { task_to_load = t },
    })
    agent.resume(deps)
    assert.is_true(#deps.approval._check_calls >= 2)
  end)

  it("calls check_promotion with the derived skill name and allowed_dir", function()
    local t = approval_task_for_resume({ "src/my_skill.lua" })
    local deps = resume_deps({
      approval_overrides = { promoted_skills = { "my_skill" } },
      config_overrides   = { store = { ["skills.allowed_dir"] = "/opt/skills" } },
      state_overrides    = { task_to_load = t },
    })
    agent.resume(deps)
    local call = deps.approval._check_calls[1]
    assert.equals("my_skill",   call.skill_name)
    assert.equals("/opt/skills", call.allowed_dir)
  end)

  it("saves state after transitioning to COMPLETE", function()
    local t = approval_task_for_resume({ "src/my_skill.lua" })
    local deps = resume_deps({
      approval_overrides = { promoted_skills = { "my_skill" } },
      state_overrides    = { task_to_load = t },
    })
    agent.resume(deps)
    assert.equals(1, #deps.state._saved)
  end)

  it("works when task_obj is passed directly (bypasses state.load)", function()
    local t = approval_task_for_resume({ "src/my_skill.lua" })
    local deps = resume_deps({
      approval_overrides = { promoted_skills = { "my_skill" } },
    })
    agent.resume(deps, t)   -- task_obj supplied directly
    assert.equals(task.COMPLETE, t.status)
  end)

  it("loads task from state.load when no task_obj is given", function()
    local t = approval_task_for_resume({ "src/my_skill.lua" })
    local deps = resume_deps({
      approval_overrides = { promoted_skills = { "my_skill" } },
      state_overrides    = { task_to_load = t },
    })
    local returned = agent.resume(deps)   -- no task_obj arg
    assert.equals(task.COMPLETE, returned.status)
  end)

end)

-- ---------------------------------------------------------------------------
-- agent.resume — skills not promoted → prompt_human called
-- ---------------------------------------------------------------------------

describe("agent.resume when skills are not yet promoted", function()

  it("calls prompt_human for each un-promoted skill", function()
    local t = approval_task_for_resume({ "src/my_skill.lua" })
    local deps = resume_deps({
      approval_overrides = {
        promoted_skills = {},     -- nothing promoted
        prompt_response = "reject",
      },
      state_overrides = { task_to_load = t },
    })
    agent.resume(deps, t)
    assert.equals(1, #deps.approval._prompt_calls)
  end)

  it("does not call prompt_human for already-promoted skills", function()
    local t = approval_task_for_resume({ "src/skill_a.lua", "src/skill_b.lua" })
    local deps = resume_deps({
      approval_overrides = {
        promoted_skills = { "skill_a" },  -- only a is promoted
        prompt_response = "reject",
      },
    })
    agent.resume(deps, t)
    -- Only skill_b needs prompting
    assert.equals(1, #deps.approval._prompt_calls)
  end)

  it("fetches the approval record via approval.get before prompt_human", function()
    local t = approval_task_for_resume({ "src/my_skill.lua" },
      { approval_id = "abc-123" })
    local deps = resume_deps({
      approval_overrides = {
        promoted_skills = {},
        prompt_response = "reject",
      },
    })
    agent.resume(deps, t)
    assert.equals(1, #deps.approval._get_calls)
    assert.equals("abc-123", deps.approval._get_calls[1].approval_id)
  end)

end)

-- ---------------------------------------------------------------------------
-- agent.resume — human says approve (Y)
-- ---------------------------------------------------------------------------

describe("agent.resume when human approves (prints commands, stays APPROVAL)", function()

  it("task remains in APPROVAL after human approves (must re-run resume)", function()
    local t = approval_task_for_resume({ "src/my_skill.lua" })
    local deps = resume_deps({
      approval_overrides = {
        promoted_skills = {},
        prompt_response = "approve",
        promotion_cmds  = { "cp my_skill.lua /skills/" },
      },
    })
    agent.resume(deps, t)
    assert.equals(task.APPROVAL, t.status)
  end)

  it("prints promotion commands after human approves", function()
    local printed = {}
    local t = approval_task_for_resume({ "src/my_skill.lua" })
    local deps = resume_deps({
      approval_overrides = {
        promoted_skills = {},
        prompt_response = "approve",
        promotion_cmds  = { "cp my_skill.lua /skills/" },
      },
    })
    deps.print = function(s) printed[#printed + 1] = s end
    agent.resume(deps, t)
    local found = false
    for _, line in ipairs(printed) do
      if line:find("cp my_skill.lua /skills/", 1, true) then found = true; break end
    end
    assert.is_true(found, "promotion command should be printed after approve")
  end)

  it("prints instructions to re-run resume", function()
    local printed = {}
    local t = approval_task_for_resume({ "src/my_skill.lua" })
    local deps = resume_deps({
      approval_overrides = { promoted_skills = {}, prompt_response = "approve" },
    })
    deps.print = function(s) printed[#printed + 1] = s end
    agent.resume(deps, t)
    local found = false
    for _, line in ipairs(printed) do
      if line:find("resume", 1, true) then found = true; break end
    end
    assert.is_true(found, "should instruct human to re-run resume")
  end)

end)

-- ---------------------------------------------------------------------------
-- agent.resume — human rejects (N) → FAILED
-- ---------------------------------------------------------------------------

describe("agent.resume when human rejects", function()

  it("transitions to FAILED when human rejects", function()
    local t = approval_task_for_resume({ "src/my_skill.lua" })
    local deps = resume_deps({
      approval_overrides = { promoted_skills = {}, prompt_response = "reject" },
    })
    agent.resume(deps, t)
    assert.equals(task.FAILED, t.status)
  end)

  it("failure detail mentions the rejected skill name", function()
    local t = approval_task_for_resume({ "src/my_skill.lua" })
    local deps = resume_deps({
      approval_overrides = { promoted_skills = {}, prompt_response = "reject" },
    })
    agent.resume(deps, t)
    local detail = t.history[#t.history].detail
    assert.is_truthy(detail:find("my_skill", 1, true))
  end)

  it("saves state after transitioning to FAILED", function()
    local t = approval_task_for_resume({ "src/my_skill.lua" })
    local deps = resume_deps({
      approval_overrides = { promoted_skills = {}, prompt_response = "reject" },
    })
    agent.resume(deps, t)
    assert.equals(1, #deps.state._saved)
  end)

end)

-- ---------------------------------------------------------------------------
-- agent.resume — task not in APPROVAL status
-- ---------------------------------------------------------------------------

describe("agent.resume when task is not in APPROVAL status", function()

  it("returns the task without error when status is not APPROVAL", function()
    local t = mocks.make_task_obj()    -- PENDING
    local deps = resume_deps()
    local returned = agent.resume(deps, t)
    assert.equals(t, returned)
  end)

  it("does not transition the task when status is not APPROVAL", function()
    local t = mocks.make_task_obj()    -- PENDING
    local deps = resume_deps()
    agent.resume(deps, t)
    assert.equals(task.PENDING, t.status)
  end)

  it("prints an informational message about the current status", function()
    local printed = {}
    local t = mocks.make_task_obj()
    local deps = resume_deps()
    deps.print = function(s) printed[#printed + 1] = s end
    agent.resume(deps, t)
    assert.is_true(#printed >= 1, "should print something")
    local found = false
    for _, line in ipairs(printed) do
      if line:find(task.PENDING, 1, true) then found = true; break end
    end
    assert.is_true(found, "should mention current status in output")
  end)

end)

-- ===========================================================================
-- Step 3g — agent.run() end-to-end integration tests
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- Helpers specific to 3g
-- ---------------------------------------------------------------------------

--- Build deps where the full pipeline succeeds with no skill outputs.
--- PENDING → PLANNING → EXECUTING → COMPLETE
local function e2e_no_skill_deps()
  return mocks.make_agent_deps({
    -- planner succeeds (default)
    -- cmd_plan succeeds (default), plan has no outputs → no skill scan
    -- skill_loader returns no skills (default)
  })
end

--- Build deps where execution produces one skill output.
--- PENDING → PLANNING → EXECUTING → TESTING → APPROVAL
local function e2e_skill_deps(skill_path)
  skill_path = skill_path or "src/my_skill.lua"
  return mocks.make_agent_deps({
    plan_overrides         = { outputs = { skill_path } },
    skill_loader_overrides = { skill_paths = { skill_path } },
    -- skill_runner passes by default
  })
end

--- Build deps where cmd_plan fails once then succeeds.
--- PENDING → PLANNING → EXECUTING → REPLANNING → PLANNING → EXECUTING → COMPLETE
local function e2e_fail_then_succeed_deps()
  local call_count = 0
  local cmd_plan = {
    run = function(args, _deps)
      call_count = call_count + 1
      if call_count == 1 then
        return nil, "transient error"
      end
      return true, nil
    end,
    _call_count = function() return call_count end,
  }
  return mocks.make_agent_deps({ cmd_plan = cmd_plan })
end

-- ---------------------------------------------------------------------------
-- Happy path: no skills → COMPLETE
-- ---------------------------------------------------------------------------

describe("agent.run end-to-end: no skills (PENDING → COMPLETE)", function()

  it("returns a task in COMPLETE status", function()
    local deps = e2e_no_skill_deps()
    local t    = agent.run(deps, "generate a readme")
    assert.equals(task.COMPLETE, t.status)
  end)

  it("task history includes planning, executing, and complete entries", function()
    local deps = e2e_no_skill_deps()
    local t    = agent.run(deps, "generate a readme")
    local statuses = {}
    for _, h in ipairs(t.history) do statuses[#statuses + 1] = h.status end
    assert.is_truthy(table.concat(statuses, ","):find("planning", 1, true))
    assert.is_truthy(table.concat(statuses, ","):find("executing", 1, true))
    assert.is_truthy(table.concat(statuses, ","):find("complete", 1, true))
  end)

  it("calls state.save at least once", function()
    local deps = e2e_no_skill_deps()
    agent.run(deps, "generate a readme")
    assert.is_true(#deps.state._saved >= 1)
  end)

  it("state.save is called after every step (saved count >= step count)", function()
    local deps = e2e_no_skill_deps()
    local t    = agent.run(deps, "generate a readme")
    -- Steps: PENDING, PLANNING, EXECUTING — at minimum 3 saves.
    assert.is_true(#deps.state._saved >= 3)
  end)

  it("final saved task has COMPLETE status", function()
    local deps = e2e_no_skill_deps()
    local t    = agent.run(deps, "generate a readme")
    local last_saved = deps.state._saved[#deps.state._saved]
    assert.equals(task.COMPLETE, last_saved.status)
  end)

end)

-- ---------------------------------------------------------------------------
-- Happy path with skills → APPROVAL (paused)
-- ---------------------------------------------------------------------------

describe("agent.run end-to-end: skill output (PENDING → APPROVAL, paused)", function()

  it("returns a task in APPROVAL status", function()
    local deps = e2e_skill_deps("src/my_skill.lua")
    local t    = agent.run(deps, "create a skill")
    assert.equals(task.APPROVAL, t.status)
  end)

  it("task history passes through testing", function()
    local deps = e2e_skill_deps("src/my_skill.lua")
    local t    = agent.run(deps, "create a skill")
    local statuses = {}
    for _, h in ipairs(t.history) do statuses[#statuses + 1] = h.status end
    assert.is_truthy(table.concat(statuses, ","):find("testing", 1, true))
  end)

  it("t.skill_files is populated", function()
    local deps = e2e_skill_deps("src/my_skill.lua")
    local t    = agent.run(deps, "create a skill")
    assert.equals(1, #t.skill_files)
    assert.equals("src/my_skill.lua", t.skill_files[1])
  end)

  it("t.approval_id is set", function()
    local deps = e2e_skill_deps("src/my_skill.lua")
    local t    = agent.run(deps, "create a skill")
    assert.is_string(t.approval_id)
  end)

  it("state.save called after reaching APPROVAL", function()
    local deps = e2e_skill_deps("src/my_skill.lua")
    local t    = agent.run(deps, "create a skill")
    -- The last save should have the paused APPROVAL task.
    local last_saved = deps.state._saved[#deps.state._saved]
    assert.equals(task.APPROVAL, last_saved.status)
  end)

end)

-- ---------------------------------------------------------------------------
-- Failure + replan: EXECUTING fails once, replan succeeds → COMPLETE
-- ---------------------------------------------------------------------------

describe("agent.run end-to-end: execution failure + replan → COMPLETE", function()

  it("returns COMPLETE after recovering from an execution failure", function()
    local deps = e2e_fail_then_succeed_deps()
    local t    = agent.run(deps, "do something")
    assert.equals(task.COMPLETE, t.status)
  end)

  it("task history includes a replanning entry", function()
    local deps = e2e_fail_then_succeed_deps()
    local t    = agent.run(deps, "do something")
    local statuses = {}
    for _, h in ipairs(t.history) do statuses[#statuses + 1] = h.status end
    assert.is_truthy(table.concat(statuses, ","):find("replanning", 1, true))
  end)

  it("planner.replan was called once", function()
    local deps = e2e_fail_then_succeed_deps()
    agent.run(deps, "do something")
    assert.equals(1, #deps.planner._replan_calls)
  end)

  it("state.save called throughout (saves > 3)", function()
    local deps = e2e_fail_then_succeed_deps()
    agent.run(deps, "do something")
    -- Sequence is at least: PENDING, PLANNING, EXECUTING, REPLANNING, PLANNING, EXECUTING, COMPLETE
    assert.is_true(#deps.state._saved >= 5)
  end)

end)

-- ---------------------------------------------------------------------------
-- Max steps exceeded → FAILED
-- ---------------------------------------------------------------------------

describe("agent.run end-to-end: max_steps exceeded → FAILED", function()

  it("returns a task in FAILED status when max_steps is hit", function()
    -- Use a planner that always succeeds but cmd_plan that always fails,
    -- so the loop cycles without terminating.
    local deps = mocks.make_agent_deps({
      cmd_plan_overrides = { run_err = "always fails" },
    })
    local t = agent.run(deps, "do something", { max_steps = 4 })
    assert.equals(task.FAILED, t.status)
  end)

  it("t.error mentions max steps", function()
    local deps = mocks.make_agent_deps({
      cmd_plan_overrides = { run_err = "always fails" },
    })
    local t = agent.run(deps, "do something", { max_steps = 4 })
    assert.is_truthy(t.error:find("max steps", 1, true))
  end)

  it("state.save called after max-steps FAILED transition", function()
    local deps = mocks.make_agent_deps({
      cmd_plan_overrides = { run_err = "always fails" },
    })
    agent.run(deps, "do something", { max_steps = 4 })
    local last_saved = deps.state._saved[#deps.state._saved]
    assert.equals(task.FAILED, last_saved.status)
  end)

end)

-- ---------------------------------------------------------------------------
-- state.save called after every step
-- ---------------------------------------------------------------------------

describe("agent.run state.save discipline", function()

  it("saves after each individual step, not just at terminal state", function()
    -- Intercept saves and record the status at each save point.
    local saved_statuses = {}
    local deps = e2e_no_skill_deps()
    deps.state = {
      save   = function(t) saved_statuses[#saved_statuses + 1] = t.status end,
      _saved = saved_statuses,
    }
    agent.run(deps, "do something")
    -- We should see intermediate statuses, not just the final one.
    -- At minimum: planning, executing, complete are all present.
    local seen = {}
    for _, s in ipairs(saved_statuses) do seen[s] = true end
    assert.is_true(seen[task.PLANNING]  ~= nil, "planning step should be saved")
    assert.is_true(seen[task.EXECUTING] ~= nil, "executing step should be saved")
    assert.is_true(seen[task.COMPLETE]  ~= nil, "complete step should be saved")
  end)

end)
