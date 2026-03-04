--- src/planner.test.lua
--- Unit tests for src/planner.lua — no real LLM calls, no filesystem I/O.

local planner = require("planner")
local mocks   = require("test.mocks")

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local VALID_PLAN_MD = [[
## plan
context: src/foo.lua
output: src/out.lua

## prompt
Write a module.
]]

--- Build a planner-specific deps table using mocks.
--- Accepted overrides:
---   llm_content        — string the fake LLM returns (default: VALID_PLAN_MD)
---   luallm_overrides   — forwarded to make_luallm inside mocks.make_deps
---   safe_fs_overrides  — forwarded to make_safe_fs
---   plan_mod_overrides — forwarded to mocks.make_plan_mod
---   config_overrides   — forwarded to make_config
---   plan_mod           — inject a fully custom plan mod
local function make_planner_deps(overrides)
  overrides = overrides or {}

  local llm_content = overrides.llm_content
  if llm_content == nil then llm_content = VALID_PLAN_MD end

  local luallm_overrides = overrides.luallm_overrides or {}
  -- Only set complete_resp when the caller hasn't supplied complete or complete_err.
  if not luallm_overrides.complete and not luallm_overrides.complete_err then
    luallm_overrides.complete_resp = mocks.fake_response(llm_content, { total_tokens = 10 })
  end

  -- Build the base deps (config, luallm, safe_fs) via the shared factory.
  local base_deps, written = mocks.make_deps({
    luallm_overrides  = luallm_overrides,
    safe_fs_overrides = overrides.safe_fs_overrides,
    config_overrides  = overrides.config_overrides,
  })

  -- Wrap luallm.complete to record raw call arguments for inspection.
  local llm_calls   = {}
  local inner_complete = base_deps.luallm.complete
  base_deps.luallm.complete = function(req, opts)
    llm_calls[#llm_calls + 1] = { req = req, opts = opts or {} }
    return inner_complete(req, opts)
  end

  -- Build / attach the plan mod (mocks.make_plan_mod exposes parse + validate).
  local plan_tbl = mocks.make_plan(overrides.plan_overrides)
  base_deps.plan = overrides.plan_mod
               or mocks.make_plan_mod(plan_tbl, overrides.plan_mod_overrides)

  -- Expose inspection handles.
  base_deps._llm_calls = llm_calls
  base_deps._written   = written   -- array of {path, content, ...} from safe_fs

  return base_deps
end

-- ---------------------------------------------------------------------------
-- planner.system_prompt
-- ---------------------------------------------------------------------------

describe("planner.system_prompt", function()

  it("returns a non-empty string", function()
    local sp = planner.system_prompt()
    assert.is_string(sp)
    assert.is_true(#sp > 0)
  end)

  it("documents the ## plan section", function()
    assert.is_truthy(planner.system_prompt():find("## plan", 1, true))
  end)

  it("documents the ## prompt section", function()
    assert.is_truthy(planner.system_prompt():find("## prompt", 1, true))
  end)

  it("documents the ## system prompt section", function()
    assert.is_truthy(planner.system_prompt():find("system prompt", 1, true))
  end)

  it("mentions context: key", function()
    assert.is_truthy(planner.system_prompt():find("context:", 1, true))
  end)

  it("mentions output: key", function()
    assert.is_truthy(planner.system_prompt():find("output:", 1, true))
  end)

  it("mentions sanitize_fences", function()
    assert.is_truthy(planner.system_prompt():find("sanitize_fences", 1, true))
  end)

  it("contains a concrete example plan", function()
    -- Must include at least one example with both required sections.
    local sp = planner.system_prompt()
    assert.is_truthy(sp:find("## plan",   1, true))
    assert.is_truthy(sp:find("## prompt", 1, true))
  end)

end)

-- ---------------------------------------------------------------------------
-- planner.generate — success path
-- ---------------------------------------------------------------------------

describe("planner.generate (success)", function()

  it("returns a plan_path string and plan_table on success", function()
    local deps = make_planner_deps()
    local path, result = planner.generate(deps, "Write a parser.")
    assert.is_string(path)
    assert.is_table(result)
  end)

  it("plan_path ends with plan.md by default", function()
    local deps = make_planner_deps()
    local path = planner.generate(deps, "Write a parser.")
    assert.is_truthy(path:match("plan%.md$"))
  end)

  it("uses opts.output_dir in the returned path", function()
    local deps = make_planner_deps()
    local path = planner.generate(deps, "Write a parser.", { output_dir = "/tmp/tasks/42" })
    assert.is_truthy(path:match("^/tmp/tasks/42/"))
  end)

  it("uses opts.plan_name as the filename", function()
    local deps = make_planner_deps()
    local path = planner.generate(deps, "Write a parser.", { plan_name = "my_plan.md" })
    assert.is_truthy(path:match("my_plan%.md$"))
  end)

  it("calls luallm.complete exactly once", function()
    local deps = make_planner_deps()
    planner.generate(deps, "Write a parser.")
    assert.equals(1, #deps._llm_calls)
  end)

  it("passes a non-empty system prompt to luallm.complete", function()
    local deps = make_planner_deps()
    planner.generate(deps, "Write a parser.")
    local req = deps._llm_calls[1].req
    assert.is_string(req.system)
    assert.is_true(#req.system > 0)
  end)

  it("includes the user prompt in the messages", function()
    local deps = make_planner_deps()
    planner.generate(deps, "Write a JSON parser.")
    local content = deps._llm_calls[1].req.messages[1].content
    assert.is_truthy(content:find("Write a JSON parser.", 1, true))
  end)

  it("includes context_files in the LLM message when provided", function()
    local deps = make_planner_deps()
    planner.generate(deps, "Write a module.", { context_files = { "src/a.lua", "src/b.lua" } })
    local content = deps._llm_calls[1].req.messages[1].content
    assert.is_truthy(content:find("src/a.lua", 1, true))
    assert.is_truthy(content:find("src/b.lua", 1, true))
  end)

  it("does not add context noise when context_files is empty", function()
    local deps = make_planner_deps()
    planner.generate(deps, "Write a module.", { context_files = {} })
    local content = deps._llm_calls[1].req.messages[1].content
    assert.is_falsy(content:find("Relevant existing files", 1, true))
  end)

  it("writes the LLM content via safe_fs.write_file", function()
    local deps = make_planner_deps()
    planner.generate(deps, "Write a parser.")
    assert.is_true(#deps._written >= 1)
  end)

  it("passes model override to luallm.complete", function()
    local deps = make_planner_deps()
    planner.generate(deps, "Write a parser.", { model = "my-model" })
    assert.equals("my-model", deps._llm_calls[1].opts.model)
  end)

  it("uses model from config when no opts.model given", function()
    local deps = make_planner_deps({ config_overrides = { store = { model = "config-model" } } })
    planner.generate(deps, "Write a parser.")
    assert.equals("config-model", deps._llm_calls[1].opts.model)
  end)

  it("opts.model takes precedence over config model", function()
    local deps = make_planner_deps({ config_overrides = { store = { model = "config-model" } } })
    planner.generate(deps, "Write a parser.", { model = "override-model" })
    assert.equals("override-model", deps._llm_calls[1].opts.model)
  end)

  it("returned plan_table fields come from plan.parse result", function()
    local deps = make_planner_deps()
    local _, result = planner.generate(deps, "Write a parser.")
    -- mocks.make_plan sets prompt = "Write a module."
    assert.equals("Write a module.", result.prompt)
  end)

end)

-- ---------------------------------------------------------------------------
-- planner.generate — failure paths
-- ---------------------------------------------------------------------------

describe("planner.generate (failures)", function()

  it("returns nil + error when prompt is empty string", function()
    local deps = make_planner_deps()
    local path, err = planner.generate(deps, "")
    assert.is_nil(path)
    assert.is_truthy(err:find("prompt", 1, true))
  end)

  it("returns nil + error when prompt is nil", function()
    local deps = make_planner_deps()
    local path, err = planner.generate(deps, nil)
    assert.is_nil(path)
    assert.is_string(err)
  end)

  it("returns nil + error when LLM call fails", function()
    local deps = make_planner_deps({ luallm_overrides = { complete_err = "connection refused" } })
    local path, err = planner.generate(deps, "Write a parser.")
    assert.is_nil(path)
    assert.is_truthy(err:find("connection refused", 1, true))
  end)

  it("returns nil + error when LLM returns empty content", function()
    local deps = make_planner_deps({ llm_content = "" })
    local path, err = planner.generate(deps, "Write a parser.")
    assert.is_nil(path)
    assert.is_truthy(err:find("empty", 1, true))
  end)

  it("returns nil + error when LLM returns garbage (parse fails)", function()
    local deps = make_planner_deps({ llm_content = "Sorry, I cannot do that." })
    -- Swap in a plan_mod whose parse rejects anything without the right sections.
    local plan_tbl = mocks.make_plan()
    local plan_mod = mocks.make_plan_mod(plan_tbl, {})
    plan_mod.parse = function(_text)
      return nil, "missing required section: ## plan"
    end
    deps.plan = plan_mod
    local path, err = planner.generate(deps, "Write a parser.")
    assert.is_nil(path)
    assert.is_truthy(err:find("missing", 1, true))
  end)

  it("returns nil + error when plan fails validate()", function()
    local deps = make_planner_deps({
      plan_mod_overrides = { validate_err = "prompt is empty" },
    })
    local path, err = planner.generate(deps, "Write a parser.")
    assert.is_nil(path)
    assert.is_truthy(err:find("prompt is empty", 1, true))
  end)

  it("returns nil + error when safe_fs.write_file fails", function()
    local deps = make_planner_deps({ safe_fs_overrides = { write_err = "disk full" } })
    local path, err = planner.generate(deps, "Write a parser.")
    assert.is_nil(path)
    assert.is_truthy(err:find("disk full", 1, true))
  end)

  it("returns nil + error when LLM response has no choices", function()
    local deps = make_planner_deps()
    local real_complete = deps.luallm.complete
    deps.luallm.complete = function(req, opts)
      deps._llm_calls[#deps._llm_calls + 1] = { req = req, opts = opts or {} }
      return { choices = {} }, nil
    end
    local path, err = planner.generate(deps, "Write a parser.")
    assert.is_nil(path)
    assert.is_truthy(err:find("choices", 1, true) or err:find("no choices", 1, true))
  end)

end)

-- ---------------------------------------------------------------------------
-- planner.replan — success path
-- ---------------------------------------------------------------------------

describe("planner.replan (success)", function()

  local function make_task(prompt)
    return { prompt = prompt or "Write a parser." }
  end

  it("returns plan_path and plan_table on success", function()
    local deps = make_planner_deps()
    local path, result = planner.replan(deps, make_task(), {
      phase = "testing", message = "assertion failed",
    })
    assert.is_string(path)
    assert.is_table(result)
  end)

  it("calls luallm.complete exactly once", function()
    local deps = make_planner_deps()
    planner.replan(deps, make_task(), { phase = "testing", message = "err" })
    assert.equals(1, #deps._llm_calls)
  end)

  it("passes a non-empty system prompt to luallm.complete", function()
    local deps = make_planner_deps()
    planner.replan(deps, make_task(), { phase = "testing", message = "err" })
    local req = deps._llm_calls[1].req
    assert.is_string(req.system)
    assert.is_true(#req.system > 0)
  end)

  it("includes the original task prompt in the LLM message", function()
    local deps = make_planner_deps()
    planner.replan(deps, make_task("Build a JSON parser."), { phase = "testing", message = "err" })
    local content = deps._llm_calls[1].req.messages[1].content
    assert.is_truthy(content:find("Build a JSON parser.", 1, true))
  end)

  it("includes error phase in the LLM message", function()
    local deps = make_planner_deps()
    planner.replan(deps, make_task(), { phase = "executing", message = "syntax error" })
    local content = deps._llm_calls[1].req.messages[1].content
    assert.is_truthy(content:find("executing", 1, true))
  end)

  it("includes error message in the LLM message", function()
    local deps = make_planner_deps()
    planner.replan(deps, make_task(), { phase = "testing", message = "test #3 failed" })
    local content = deps._llm_calls[1].req.messages[1].content
    assert.is_truthy(content:find("test #3 failed", 1, true))
  end)

  it("includes plan_text in the LLM message when provided", function()
    local deps = make_planner_deps()
    planner.replan(deps, make_task(), {
      phase     = "testing",
      message   = "err",
      plan_text = "output: wrong.lua",
    })
    local content = deps._llm_calls[1].req.messages[1].content
    assert.is_truthy(content:find("wrong.lua", 1, true))
  end)

  it("includes test_output in the LLM message when provided", function()
    local deps = make_planner_deps()
    planner.replan(deps, make_task(), {
      phase       = "testing",
      message     = "tests failed",
      test_output = "FAILED: expected 1 got 2",
    })
    local content = deps._llm_calls[1].req.messages[1].content
    assert.is_truthy(content:find("expected 1 got 2", 1, true))
  end)

  it("includes skill_code in the LLM message when provided", function()
    local deps = make_planner_deps()
    planner.replan(deps, make_task(), {
      phase      = "testing",
      message    = "err",
      skill_code = "local function bad() return nil end",
    })
    local content = deps._llm_calls[1].req.messages[1].content
    assert.is_truthy(content:find("local function bad", 1, true))
  end)

  it("omits plan_text section when not provided", function()
    local deps = make_planner_deps()
    planner.replan(deps, make_task(), { phase = "testing", message = "err" })
    local content = deps._llm_calls[1].req.messages[1].content
    assert.is_falsy(content:find("Previous plan", 1, true))
  end)

  it("omits test_output section when not provided", function()
    local deps = make_planner_deps()
    planner.replan(deps, make_task(), { phase = "testing", message = "err" })
    local content = deps._llm_calls[1].req.messages[1].content
    assert.is_falsy(content:find("Test runner output", 1, true))
  end)

  it("writes the plan file via safe_fs.write_file", function()
    local deps = make_planner_deps()
    planner.replan(deps, make_task(), { phase = "testing", message = "err" })
    assert.is_true(#deps._written >= 1)
  end)

end)

-- ---------------------------------------------------------------------------
-- planner.replan — failure paths
-- ---------------------------------------------------------------------------

describe("planner.replan (failures)", function()

  it("returns nil + error when task.prompt is empty", function()
    local deps = make_planner_deps()
    local path, err = planner.replan(deps, { prompt = "" }, { phase = "testing", message = "err" })
    assert.is_nil(path)
    assert.is_truthy(err:find("prompt", 1, true))
  end)

  it("returns nil + error when task is nil", function()
    local deps = make_planner_deps()
    local path, err = planner.replan(deps, nil, { phase = "testing", message = "err" })
    assert.is_nil(path)
    assert.is_string(err)
  end)

  it("returns nil + error when LLM call fails", function()
    local deps = make_planner_deps({ luallm_overrides = { complete_err = "timeout" } })
    local path, err = planner.replan(deps, { prompt = "p" }, { phase = "testing", message = "err" })
    assert.is_nil(path)
    assert.is_truthy(err:find("timeout", 1, true))
  end)

  it("returns nil + error when plan fails validation", function()
    local deps = make_planner_deps({
      plan_mod_overrides = { validate_err = "outputs required" },
    })
    local path, err = planner.replan(deps, { prompt = "p" }, { phase = "testing", message = "err" })
    assert.is_nil(path)
    assert.is_truthy(err:find("outputs required", 1, true))
  end)

  it("returns nil + error when write fails", function()
    local deps = make_planner_deps({ safe_fs_overrides = { write_err = "no space" } })
    local path, err = planner.replan(deps, { prompt = "p" }, { phase = "testing", message = "err" })
    assert.is_nil(path)
    assert.is_truthy(err:find("no space", 1, true))
  end)

end)
