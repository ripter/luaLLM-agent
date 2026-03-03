--- src/task.test.lua
--- Unit tests for src/task.lua — pure logic, no filesystem, no LLM.

local _src = debug.getinfo(1, "S").source:match("^@(.*/)") or "./"
package.path = _src .. "?.lua;" .. package.path

package.loaded["task"] = nil   -- ensure fresh load each run
local task = require("task")

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- A deterministic uuid_fn so tests don't depend on the uuid rock.
local function fixed_uuid(id)
  id = id or "test-uuid-1234"
  return function() return id end
end

-- Create a fresh task with a predictable ID.
local function new_task(prompt)
  return task.new(prompt or "do something", fixed_uuid())
end

-- ---------------------------------------------------------------------------
-- task.new
-- ---------------------------------------------------------------------------

describe("task.new", function()

  it("returns a table", function()
    assert.is_table(new_task())
  end)

  it("sets id from uuid_fn", function()
    local t = task.new("p", fixed_uuid("my-id"))
    assert.equals("my-id", t.id)
  end)

  it("sets prompt", function()
    local t = new_task("write a parser")
    assert.equals("write a parser", t.prompt)
  end)

  it("initial status is PENDING", function()
    assert.equals(task.PENDING, new_task().status)
  end)

  it("plan_path is nil", function()
    assert.is_nil(new_task().plan_path)
  end)

  it("plan_text is nil", function()
    assert.is_nil(new_task().plan_text)
  end)

  it("outputs is an empty table", function()
    assert.same({}, new_task().outputs)
  end)

  it("skill_files is an empty table", function()
    assert.same({}, new_task().skill_files)
  end)

  it("test_results is nil", function()
    assert.is_nil(new_task().test_results)
  end)

  it("approval_id is nil", function()
    assert.is_nil(new_task().approval_id)
  end)

  it("error is nil", function()
    assert.is_nil(new_task().error)
  end)

  it("attempts has expected keys zeroed", function()
    local a = new_task().attempts
    assert.equals(0, a.plan)
    assert.equals(0, a.replan)
    assert.equals(0, a.test)
  end)

  it("max_attempts has correct defaults", function()
    local m = new_task().max_attempts
    assert.equals(3, m.plan)
    assert.equals(2, m.replan)
    assert.equals(2, m.test)
  end)

  it("history is an empty table", function()
    assert.same({}, new_task().history)
  end)

  it("created_at is an ISO-8601 string", function()
    local ts = new_task().created_at
    assert.is_string(ts)
    -- Basic shape: YYYY-MM-DDTHH:MM:SSZ
    assert.is_truthy(ts:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$"))
  end)

  it("updated_at equals created_at on creation", function()
    local t = new_task()
    assert.equals(t.created_at, t.updated_at)
  end)

end)

-- ---------------------------------------------------------------------------
-- Status constants
-- ---------------------------------------------------------------------------

describe("task status constants", function()

  it("PENDING is 'pending'",       function() assert.equals("pending",    task.PENDING)    end)
  it("PLANNING is 'planning'",     function() assert.equals("planning",   task.PLANNING)   end)
  it("EXECUTING is 'executing'",   function() assert.equals("executing",  task.EXECUTING)  end)
  it("TESTING is 'testing'",       function() assert.equals("testing",    task.TESTING)    end)
  it("APPROVAL is 'approval'",     function() assert.equals("approval",   task.APPROVAL)   end)
  it("REPLANNING is 'replanning'", function() assert.equals("replanning", task.REPLANNING) end)
  it("COMPLETE is 'complete'",     function() assert.equals("complete",   task.COMPLETE)   end)
  it("FAILED is 'failed'",         function() assert.equals("failed",     task.FAILED)     end)

end)

-- ---------------------------------------------------------------------------
-- task.transition — legal transitions
-- ---------------------------------------------------------------------------

describe("task.transition (legal)", function()

  local function assert_legal(from_path, to)
    -- Build task and walk it to the desired from-status via legal transitions.
    local t = new_task()
    for _, s in ipairs(from_path) do
      local ok, err = task.transition(t, s)
      assert.is_not_nil(ok, "setup transition failed: " .. tostring(err))
    end
    local result, err = task.transition(t, to)
    assert.is_not_nil(result, "expected legal transition to " .. to .. " but got: " .. tostring(err))
    assert.equals(to, result.status)
    return result
  end

  it("PENDING → PLANNING", function()
    assert_legal({}, task.PLANNING)
  end)

  it("PLANNING → EXECUTING", function()
    assert_legal({ task.PLANNING }, task.EXECUTING)
  end)

  it("PLANNING → FAILED", function()
    assert_legal({ task.PLANNING }, task.FAILED)
  end)

  it("EXECUTING → TESTING", function()
    assert_legal({ task.PLANNING, task.EXECUTING }, task.TESTING)
  end)

  it("EXECUTING → COMPLETE", function()
    assert_legal({ task.PLANNING, task.EXECUTING }, task.COMPLETE)
  end)

  it("EXECUTING → REPLANNING", function()
    assert_legal({ task.PLANNING, task.EXECUTING }, task.REPLANNING)
  end)

  it("EXECUTING → FAILED", function()
    assert_legal({ task.PLANNING, task.EXECUTING }, task.FAILED)
  end)

  it("TESTING → APPROVAL", function()
    assert_legal({ task.PLANNING, task.EXECUTING, task.TESTING }, task.APPROVAL)
  end)

  it("TESTING → REPLANNING", function()
    assert_legal({ task.PLANNING, task.EXECUTING, task.TESTING }, task.REPLANNING)
  end)

  it("TESTING → FAILED", function()
    assert_legal({ task.PLANNING, task.EXECUTING, task.TESTING }, task.FAILED)
  end)

  it("APPROVAL → COMPLETE", function()
    assert_legal({ task.PLANNING, task.EXECUTING, task.TESTING, task.APPROVAL }, task.COMPLETE)
  end)

  it("APPROVAL → FAILED", function()
    assert_legal({ task.PLANNING, task.EXECUTING, task.TESTING, task.APPROVAL }, task.FAILED)
  end)

  it("REPLANNING → PLANNING", function()
    assert_legal({ task.PLANNING, task.EXECUTING, task.REPLANNING }, task.PLANNING)
  end)

  it("REPLANNING → FAILED", function()
    assert_legal({ task.PLANNING, task.EXECUTING, task.REPLANNING }, task.FAILED)
  end)

end)

-- ---------------------------------------------------------------------------
-- task.transition — illegal transitions
-- ---------------------------------------------------------------------------

describe("task.transition (illegal)", function()

  local function assert_illegal(from_path, to)
    local t = new_task()
    for _, s in ipairs(from_path) do
      task.transition(t, s)
    end
    local result, err = task.transition(t, to)
    assert.is_nil(result)
    assert.is_string(err)
    assert.is_truthy(err:find("illegal transition", 1, true))
    return err
  end

  it("PENDING → EXECUTING is illegal", function()
    assert_illegal({}, task.EXECUTING)
  end)

  it("PENDING → COMPLETE is illegal", function()
    assert_illegal({}, task.COMPLETE)
  end)

  it("PENDING → FAILED is illegal", function()
    assert_illegal({}, task.FAILED)
  end)

  it("PLANNING → TESTING is illegal", function()
    assert_illegal({ task.PLANNING }, task.TESTING)
  end)

  it("PLANNING → APPROVAL is illegal", function()
    assert_illegal({ task.PLANNING }, task.APPROVAL)
  end)

  it("PLANNING → COMPLETE is illegal", function()
    assert_illegal({ task.PLANNING }, task.COMPLETE)
  end)

  it("EXECUTING → PLANNING is illegal", function()
    assert_illegal({ task.PLANNING, task.EXECUTING }, task.PLANNING)
  end)

  it("EXECUTING → APPROVAL is illegal", function()
    assert_illegal({ task.PLANNING, task.EXECUTING }, task.APPROVAL)
  end)

  it("TESTING → EXECUTING is illegal", function()
    assert_illegal({ task.PLANNING, task.EXECUTING, task.TESTING }, task.EXECUTING)
  end)

  it("TESTING → COMPLETE is illegal", function()
    assert_illegal({ task.PLANNING, task.EXECUTING, task.TESTING }, task.COMPLETE)
  end)

  it("APPROVAL → PLANNING is illegal", function()
    assert_illegal(
      { task.PLANNING, task.EXECUTING, task.TESTING, task.APPROVAL },
      task.PLANNING)
  end)

  it("COMPLETE → anything is illegal", function()
    local t = new_task()
    task.transition(t, task.PLANNING)
    task.transition(t, task.EXECUTING)
    task.transition(t, task.COMPLETE)
    -- Attempt every possible status from COMPLETE
    for _, s in ipairs({
      task.PENDING, task.PLANNING, task.EXECUTING, task.TESTING,
      task.APPROVAL, task.REPLANNING, task.COMPLETE, task.FAILED,
    }) do
      local result, err = task.transition(t, s)
      assert.is_nil(result, "expected COMPLETE → " .. s .. " to be illegal")
      assert.is_truthy(err:find("illegal transition", 1, true))
    end
  end)

  it("FAILED → anything is illegal", function()
    local t = new_task()
    task.transition(t, task.PLANNING)
    task.transition(t, task.FAILED)
    for _, s in ipairs({
      task.PENDING, task.PLANNING, task.EXECUTING, task.TESTING,
      task.APPROVAL, task.REPLANNING, task.COMPLETE, task.FAILED,
    }) do
      local result, err = task.transition(t, s)
      assert.is_nil(result, "expected FAILED → " .. s .. " to be illegal")
      assert.is_truthy(err:find("illegal transition", 1, true))
    end
  end)

  it("error message names both statuses", function()
    local t = new_task()
    local _, err = task.transition(t, task.EXECUTING)
    assert.is_truthy(err:find(task.PENDING,   1, true), "should mention source: " .. err)
    assert.is_truthy(err:find(task.EXECUTING, 1, true), "should mention target: " .. err)
  end)

end)

-- ---------------------------------------------------------------------------
-- transition side-effects: history and updated_at
-- ---------------------------------------------------------------------------

describe("task.transition side-effects", function()

  it("appends one entry to history per transition", function()
    local t = new_task()
    assert.equals(0, #t.history)

    task.transition(t, task.PLANNING)
    assert.equals(1, #t.history)

    task.transition(t, task.EXECUTING)
    assert.equals(2, #t.history)

    task.transition(t, task.COMPLETE)
    assert.equals(3, #t.history)
  end)

  it("history entry has status, ts, and detail fields", function()
    local t = new_task()
    task.transition(t, task.PLANNING, "started planning")
    local entry = t.history[1]
    assert.equals(task.PLANNING,      entry.status)
    assert.equals("started planning", entry.detail)
    assert.is_string(entry.ts)
    assert.is_truthy(entry.ts:match("^%d%d%d%d%-%d%d%-%d%dT"))
  end)

  it("detail defaults to empty string when omitted", function()
    local t = new_task()
    task.transition(t, task.PLANNING)
    assert.equals("", t.history[1].detail)
  end)

  it("updates updated_at on each transition", function()
    local t = new_task()
    local before = t.updated_at
    -- Small sleep not possible here, but updated_at must at least be set
    task.transition(t, task.PLANNING)
    assert.is_string(t.updated_at)
    -- updated_at is >= created_at (string compare works for ISO-8601)
    assert.is_true(t.updated_at >= before)
  end)

  it("does not mutate task on illegal transition", function()
    local t = new_task()
    local original_status  = t.status
    local original_history = #t.history

    task.transition(t, task.EXECUTING)  -- illegal from PENDING

    assert.equals(original_status,  t.status)
    assert.equals(original_history, #t.history)
  end)

  it("returns the mutated task table on success", function()
    local t = new_task()
    local result = task.transition(t, task.PLANNING)
    assert.equals(t, result)  -- same table reference
  end)

end)

-- ---------------------------------------------------------------------------
-- task.is_terminal
-- ---------------------------------------------------------------------------

describe("task.is_terminal", function()

  local function task_at(status_path)
    local t = new_task()
    for _, s in ipairs(status_path) do task.transition(t, s) end
    return t
  end

  it("false for PENDING",    function() assert.is_false(task.is_terminal(new_task())) end)
  it("false for PLANNING",   function() assert.is_false(task.is_terminal(task_at({ task.PLANNING }))) end)
  it("false for EXECUTING",  function() assert.is_false(task.is_terminal(task_at({ task.PLANNING, task.EXECUTING }))) end)
  it("false for TESTING",    function() assert.is_false(task.is_terminal(task_at({ task.PLANNING, task.EXECUTING, task.TESTING }))) end)
  it("false for APPROVAL",   function() assert.is_false(task.is_terminal(task_at({ task.PLANNING, task.EXECUTING, task.TESTING, task.APPROVAL }))) end)
  it("false for REPLANNING", function() assert.is_false(task.is_terminal(task_at({ task.PLANNING, task.EXECUTING, task.REPLANNING }))) end)

  it("true for COMPLETE", function()
    assert.is_true(task.is_terminal(task_at({ task.PLANNING, task.EXECUTING, task.COMPLETE })))
  end)

  it("true for FAILED", function()
    assert.is_true(task.is_terminal(task_at({ task.PLANNING, task.FAILED })))
  end)

end)

-- ---------------------------------------------------------------------------
-- task.is_paused
-- ---------------------------------------------------------------------------

describe("task.is_paused", function()

  it("false for non-APPROVAL statuses", function()
    local t = new_task()
    assert.is_false(task.is_paused(t))
    task.transition(t, task.PLANNING)
    assert.is_false(task.is_paused(t))
    task.transition(t, task.EXECUTING)
    assert.is_false(task.is_paused(t))
    task.transition(t, task.TESTING)
    assert.is_false(task.is_paused(t))
  end)

  it("true only for APPROVAL", function()
    local t = new_task()
    task.transition(t, task.PLANNING)
    task.transition(t, task.EXECUTING)
    task.transition(t, task.TESTING)
    task.transition(t, task.APPROVAL)
    assert.is_true(task.is_paused(t))
  end)

end)

-- ---------------------------------------------------------------------------
-- task.can_retry
-- ---------------------------------------------------------------------------

describe("task.can_retry", function()

  it("true when attempts < max", function()
    local t = new_task()
    assert.is_true(task.can_retry(t, "plan"))   -- 0 < 3
    assert.is_true(task.can_retry(t, "replan")) -- 0 < 2
    assert.is_true(task.can_retry(t, "test"))   -- 0 < 2
  end)

  it("false when attempts == max", function()
    local t = new_task()
    t.attempts.plan = 3
    assert.is_false(task.can_retry(t, "plan"))
  end)

  it("false when attempts > max", function()
    local t = new_task()
    t.attempts.replan = 99
    assert.is_false(task.can_retry(t, "replan"))
  end)

  it("false for unknown key", function()
    local t = new_task()
    assert.is_false(task.can_retry(t, "nonexistent"))
  end)

  it("responds correctly after bump_attempt", function()
    local t = new_task()
    -- test: max is 2, start at 0
    assert.is_true(task.can_retry(t, "test"))
    task.bump_attempt(t, "test")  -- 1
    assert.is_true(task.can_retry(t, "test"))
    task.bump_attempt(t, "test")  -- 2 == max
    assert.is_false(task.can_retry(t, "test"))
  end)

end)

-- ---------------------------------------------------------------------------
-- task.bump_attempt
-- ---------------------------------------------------------------------------

describe("task.bump_attempt", function()

  it("increments from 0 to 1 and returns 1", function()
    local t = new_task()
    local count = task.bump_attempt(t, "plan")
    assert.equals(1, count)
    assert.equals(1, t.attempts.plan)
  end)

  it("increments again and returns updated count", function()
    local t = new_task()
    task.bump_attempt(t, "plan")
    local count = task.bump_attempt(t, "plan")
    assert.equals(2, count)
    assert.equals(2, t.attempts.plan)
  end)

  it("each key is independent", function()
    local t = new_task()
    task.bump_attempt(t, "plan")
    task.bump_attempt(t, "plan")
    task.bump_attempt(t, "replan")
    assert.equals(2, t.attempts.plan)
    assert.equals(1, t.attempts.replan)
    assert.equals(0, t.attempts.test)
  end)

  it("return value matches t.attempts[key]", function()
    local t = new_task()
    for _ = 1, 5 do
      local returned = task.bump_attempt(t, "test")
      assert.equals(t.attempts.test, returned)
    end
  end)

end)
