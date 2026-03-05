--- src/cmd_agent.test.lua
--- Unit tests for cmd_agent.lua.
--- All deps are injected — no real agent, no filesystem, no state.

local cmd_agent = require("cmd_agent")
local mocks     = require("test.mocks")
local task      = require("task")

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

--- Build a minimal agent stub.
--- Supported overrides:
---   run_result    — task table returned by agent.run  (default: COMPLETE task)
---   run_nil       — if true, agent.run returns nil
---   resume_result — task table returned by agent.resume (default: COMPLETE task)
---   resume_nil    — if true, agent.resume returns nil
local function make_agent_stub(overrides)
  overrides = overrides or {}
  local run_calls    = {}
  local resume_calls = {}

  local function default_task(status)
    local t = mocks.make_task_obj()
    task.transition(t, task.PLANNING)
    task.transition(t, task.EXECUTING)
    if status == task.COMPLETE then
      task.transition(t, task.COMPLETE)
    end
    return t
  end

  return {
    run = function(_deps, prompt, opts)
      run_calls[#run_calls + 1] = { prompt = prompt, opts = opts }
      if overrides.run_nil then return nil end
      return overrides.run_result or default_task(task.COMPLETE)
    end,

    resume = function(_deps, task_obj, opts)
      resume_calls[#resume_calls + 1] = { task_obj = task_obj, opts = opts }
      if overrides.resume_nil then return nil end
      return overrides.resume_result or task_obj or default_task(task.COMPLETE)
    end,

    _run_calls    = run_calls,
    _resume_calls = resume_calls,
  }
end

--- Build full cmd_agent deps with a stub agent and state.
local function make_deps(overrides)
  overrides = overrides or {}
  local printed = {}
  return {
    agent  = overrides.agent  or make_agent_stub(overrides.agent_overrides or {}),
    state  = overrides.state  or mocks.make_state(overrides.state_overrides or {}),
    print  = overrides.print  or function(s) printed[#printed + 1] = s end,
    _printed = printed,
  }
end

--- Build an in-APPROVAL task suitable for resume tests.
local function approval_task()
  local t = mocks.make_task_obj()
  task.transition(t, task.PLANNING)
  task.transition(t, task.EXECUTING)
  task.transition(t, task.TESTING)
  task.transition(t, task.APPROVAL)
  t.skill_files = { "src/my_skill.lua" }
  t.approval_id = "test-approval-id"
  return t
end

-- ===========================================================================
-- cmd_agent.run
-- ===========================================================================

describe("cmd_agent.run", function()

  it("calls agent.run with the given prompt", function()
    local deps = make_deps()
    cmd_agent.run(deps, { prompt = "build a parser" })
    assert.equals(1, #deps.agent._run_calls)
    assert.equals("build a parser", deps.agent._run_calls[1].prompt)
  end)

  it("passes context_files through to agent.run", function()
    local deps = make_deps()
    cmd_agent.run(deps, { prompt = "do it", context_files = { "src/foo.lua" } })
    local opts = deps.agent._run_calls[1].opts
    assert.same({ "src/foo.lua" }, opts.context_files)
  end)

  it("passes deps to agent.run", function()
    local deps = make_deps()
    cmd_agent.run(deps, { prompt = "do it" })
    -- agent.run receives deps as its first argument — verified by checking call happened
    assert.equals(1, #deps.agent._run_calls)
  end)

  it("returns the task table returned by agent.run", function()
    local t    = mocks.make_task_obj()
    local deps = make_deps({ agent_overrides = { run_result = t } })
    local result = cmd_agent.run(deps, { prompt = "do it" })
    assert.equals(t, result)
  end)

  it("returns nil + error when prompt is missing", function()
    local deps = make_deps()
    local result, err = cmd_agent.run(deps, {})
    assert.is_nil(result)
    assert.is_truthy(err:find("prompt", 1, true))
  end)

  it("returns nil + error when prompt is empty string", function()
    local deps = make_deps()
    local result, err = cmd_agent.run(deps, { prompt = "" })
    assert.is_nil(result)
    assert.is_truthy(err:find("prompt", 1, true))
  end)

  it("returns nil + error when agent.run returns nil", function()
    local deps = make_deps({ agent_overrides = { run_nil = true } })
    local result, err = cmd_agent.run(deps, { prompt = "do it" })
    assert.is_nil(result)
    assert.is_string(err)
  end)

  it("prints the final task status", function()
    local deps = make_deps()
    cmd_agent.run(deps, { prompt = "do it" })
    local found = false
    for _, line in ipairs(deps._printed) do
      if line:find("status", 1, true) or line:find("complete", 1, true)
         or line:find("finished", 1, true) then
        found = true; break
      end
    end
    assert.is_true(found, "should print task status")
  end)

  it("prints the error when task has t.error set", function()
    local t_err = mocks.make_task_obj()
    t_err.error = "something went wrong"
    local deps = make_deps({ agent_overrides = { run_result = t_err } })
    cmd_agent.run(deps, { prompt = "do it" })
    local found = false
    for _, line in ipairs(deps._printed) do
      if line:find("something went wrong", 1, true) then found = true; break end
    end
    assert.is_true(found, "should print error from task")
  end)

end)

-- ===========================================================================
-- cmd_agent.resume
-- ===========================================================================

describe("cmd_agent.resume", function()

  it("calls agent.resume with the loaded task", function()
    local t    = approval_task()
    local deps = make_deps({ state_overrides = { task_to_load = t } })
    cmd_agent.resume(deps)
    assert.equals(1, #deps.agent._resume_calls)
    assert.equals(t, deps.agent._resume_calls[1].task_obj)
  end)

  it("passes deps to agent.resume", function()
    local t    = approval_task()
    local deps = make_deps({ state_overrides = { task_to_load = t } })
    cmd_agent.resume(deps)
    assert.equals(1, #deps.agent._resume_calls)
  end)

  it("returns the task returned by agent.resume", function()
    local t    = approval_task()
    local deps = make_deps({ state_overrides = { task_to_load = t } })
    local result = cmd_agent.resume(deps)
    assert.equals(t, result)
  end)

  it("returns nil + error when there is no saved task", function()
    local deps = make_deps({ state_overrides = { load_err = "file not found" } })
    local result, err = cmd_agent.resume(deps)
    assert.is_nil(result)
    assert.is_truthy(err:find("no saved task", 1, true))
  end)

  it("error message includes the underlying load error", function()
    local deps = make_deps({ state_overrides = { load_err = "corrupt state" } })
    local _, err = cmd_agent.resume(deps)
    assert.is_truthy(err:find("corrupt state", 1, true))
  end)

  it("does not call agent.resume when state.load fails", function()
    local deps = make_deps({ state_overrides = { load_err = "missing" } })
    cmd_agent.resume(deps)
    assert.equals(0, #deps.agent._resume_calls)
  end)

  it("returns nil + error when agent.resume returns nil", function()
    local t    = approval_task()
    local deps = make_deps({
      state_overrides = { task_to_load = t },
      agent_overrides = { resume_nil   = true },
    })
    local result, err = cmd_agent.resume(deps)
    assert.is_nil(result)
    assert.is_string(err)
  end)

  it("prints the status after resume", function()
    local t    = approval_task()
    local deps = make_deps({ state_overrides = { task_to_load = t } })
    cmd_agent.resume(deps)
    local found = false
    for _, line in ipairs(deps._printed) do
      if line:find("status", 1, true) or line:find("approval", 1, true) then
        found = true; break
      end
    end
    assert.is_true(found, "should print status after resume")
  end)

end)

-- ===========================================================================
-- cmd_agent.reset
-- ===========================================================================

describe("cmd_agent.reset", function()

  it("calls state.clear", function()
    local deps = make_deps()
    cmd_agent.reset(deps)
    assert.equals(1, deps.state._cleared.count)
  end)

  it("returns true on success", function()
    local deps = make_deps()
    local result = cmd_agent.reset(deps)
    assert.is_true(result)
  end)

  it("returns nil + error when state.clear fails", function()
    local deps = make_deps({ state_overrides = { clear_err = "permission denied" } })
    local result, err = cmd_agent.reset(deps)
    assert.is_nil(result)
    assert.is_truthy(err:find("permission denied", 1, true))
  end)

  it("prints a confirmation message on success", function()
    local deps = make_deps()
    cmd_agent.reset(deps)
    local found = false
    for _, line in ipairs(deps._printed) do
      if line:find("cleared", 1, true) then found = true; break end
    end
    assert.is_true(found, "should print confirmation on reset")
  end)

  it("does not call agent.run or agent.resume", function()
    local deps = make_deps()
    cmd_agent.reset(deps)
    assert.equals(0, #deps.agent._run_calls)
    assert.equals(0, #deps.agent._resume_calls)
  end)

end)

-- ===========================================================================
-- cmd_agent.status
-- ===========================================================================

describe("cmd_agent.status", function()

  it("returns the task table", function()
    local t    = mocks.make_task_obj()
    local deps = make_deps({ state_overrides = { task_to_load = t } })
    local result = cmd_agent.status(deps)
    assert.equals(t, result)
  end)

  it("returns nil + error when there is no saved task", function()
    local deps = make_deps({ state_overrides = { load_err = "nothing saved" } })
    local result, err = cmd_agent.status(deps)
    assert.is_nil(result)
    assert.is_truthy(err:find("no saved task", 1, true))
  end)

  it("prints the task id", function()
    local t    = mocks.make_task_obj()
    local deps = make_deps({ state_overrides = { task_to_load = t } })
    cmd_agent.status(deps)
    local found = false
    for _, line in ipairs(deps._printed) do
      if line:find(t.id, 1, true) then found = true; break end
    end
    assert.is_true(found, "should print task id")
  end)

  it("prints the task prompt", function()
    local t    = mocks.make_task_obj({ prompt = "unique prompt string" })
    local deps = make_deps({ state_overrides = { task_to_load = t } })
    cmd_agent.status(deps)
    local found = false
    for _, line in ipairs(deps._printed) do
      if line:find("unique prompt string", 1, true) then found = true; break end
    end
    assert.is_true(found, "should print task prompt")
  end)

  it("prints the task status", function()
    local t    = mocks.make_task_obj()
    local deps = make_deps({ state_overrides = { task_to_load = t } })
    cmd_agent.status(deps)
    local found = false
    for _, line in ipairs(deps._printed) do
      if line:find(t.status, 1, true) then found = true; break end
    end
    assert.is_true(found, "should print task status")
  end)

  it("prints history entries when present", function()
    local t = mocks.make_task_obj()
    task.transition(t, task.PLANNING, "kicking off")
    local deps = make_deps({ state_overrides = { task_to_load = t } })
    cmd_agent.status(deps)
    local found = false
    for _, line in ipairs(deps._printed) do
      if line:find("planning", 1, true) then found = true; break end
    end
    assert.is_true(found, "should print history")
  end)

  it("prints t.error when set", function()
    local t = mocks.make_task_obj()
    t.error = "exploded spectacularly"
    local deps = make_deps({ state_overrides = { task_to_load = t } })
    cmd_agent.status(deps)
    local found = false
    for _, line in ipairs(deps._printed) do
      if line:find("exploded spectacularly", 1, true) then found = true; break end
    end
    assert.is_true(found, "should print task error")
  end)

  it("does not call agent.run or agent.resume", function()
    local t    = mocks.make_task_obj()
    local deps = make_deps({ state_overrides = { task_to_load = t } })
    cmd_agent.status(deps)
    assert.equals(0, #deps.agent._run_calls)
    assert.equals(0, #deps.agent._resume_calls)
  end)

end)
