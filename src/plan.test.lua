--- src/plan.test.lua
--- Unit tests for src/plan.lua — no filesystem I/O required.

local _src = debug.getinfo(1, "S").source:match("^@(.*/)") or "./"
package.path = _src .. "?.lua;" .. package.path

local plan = require("plan")

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local MINIMAL_PLAN = [[
## plan
context: src/foo.lua
output: src/out.lua

## prompt
Write a module.
]]

local FULL_PLAN = [[
# Add safe fs

## plan
model: Qwen3-Coder-Q8_0
sanitize_fences: true
context: src/config.lua
context: src/safe_fs.lua
context: src/**/*.test.lua
output: src/safe_fs.lua
output: src/safe_fs.test.lua
test_runner: busted
test_goal: blocked overrides allowed
test_goal: temp dirs cleaned up

## system prompt
You are a Lua code generator. Output ONLY valid Lua code. No markdown fences.

## prompt
Implement safe_fs glob allow/block policy and tests.
]]

-- ---------------------------------------------------------------------------
-- parse: basic success
-- ---------------------------------------------------------------------------

describe("plan.parse", function()

  it("parses a minimal valid plan", function()
    local p, err = plan.parse(MINIMAL_PLAN)
    assert.is_not_nil(p, tostring(err))
    assert.equals("Write a module.", p.prompt)
    assert.same({ "src/foo.lua" }, p.context)
    assert.same({ "src/out.lua" }, p.outputs)
    assert.is_true(p.sanitize_fences)  -- default
  end)

  it("parses a full plan with all fields", function()
    local p, err = plan.parse(FULL_PLAN)
    assert.is_not_nil(p, tostring(err))
    assert.equals("Add safe fs", p.title)
    assert.equals("Qwen3-Coder-Q8_0", p.model)
    assert.is_true(p.sanitize_fences)
    assert.equals(3, #p.context)
    assert.equals("src/config.lua",        p.context[1])
    assert.equals("src/safe_fs.lua",       p.context[2])
    assert.equals("src/**/*.test.lua",     p.context[3])
    assert.equals(2, #p.outputs)
    assert.equals("busted", p.test_runner)
    assert.equals(2, #p.test_goals)
    assert.equals("blocked overrides allowed", p.test_goals[1])
    assert.equals("temp dirs cleaned up",      p.test_goals[2])
    assert.equals("You are a Lua code generator. Output ONLY valid Lua code. No markdown fences.",
                  p.system_prompt)
    assert.is_truthy(p.prompt:find("safe_fs", 1, true))
  end)

  it("derives title from first # header", function()
    local p = assert(plan.parse("# My Plan\n\n## plan\ncontext: a.lua\n\n## prompt\nDo it.\n"))
    assert.equals("My Plan", p.title)
  end)

  it("parses title with special characters (emoji, backticks, spaces)", function()
    local p = assert(plan.parse("# 🧠 `luallm-agent` Plan v3\n\n## plan\ncontext: a.lua\n\n## prompt\nDo it.\n"))
    assert.equals("🧠 `luallm-agent` Plan v3", p.title)
  end)

  it("title is nil when no # header present", function()
    local p = assert(plan.parse(MINIMAL_PLAN))
    assert.is_nil(p.title)
  end)

  it("title is nil when file starts directly with ## plan (no title line)", function()
    local text = "## plan\ncontext: a.lua\n\n## prompt\nDo it.\n"
    local p = assert(plan.parse(text))
    assert.is_nil(p.title)
  end)

  it("# title line is not confused with ## section headers", function()
    local p = assert(plan.parse("# Real Title\n\n## plan\ncontext: a.lua\n\n## prompt\nDo it.\n"))
    assert.equals("Real Title", p.title)
    -- The title must not bleed into the plan section
    assert.equals(0, #p.outputs)
  end)

  -- sanitize_fences -----------------------------------------------------------

  it("sanitize_fences defaults to true when not specified", function()
    local p = assert(plan.parse(MINIMAL_PLAN))
    assert.is_true(p.sanitize_fences)
  end)

  it("respects sanitize_fences: false", function()
    local text = "## plan\ncontext: a.lua\nsanitize_fences: false\n\n## prompt\nDo it.\n"
    local p = assert(plan.parse(text))
    assert.is_false(p.sanitize_fences)
  end)

  -- repeated keys preserve order ----------------------------------------------

  it("preserves insertion order for context entries", function()
    local text = "## plan\ncontext: c.lua\ncontext: a.lua\ncontext: b.lua\n\n## prompt\nDo it.\n"
    local p = assert(plan.parse(text))
    assert.same({ "c.lua", "a.lua", "b.lua" }, p.context)
  end)

  it("preserves insertion order for output entries", function()
    local text = "## plan\ncontext: x.lua\noutput: z.lua\noutput: a.lua\n\n## prompt\nDo it.\n"
    local p = assert(plan.parse(text))
    assert.same({ "z.lua", "a.lua" }, p.outputs)
  end)

  it("preserves insertion order for test_goal entries", function()
    local text = "## plan\ncontext: x.lua\ntest_goal: first\ntest_goal: second\n\n## prompt\nDo it.\n"
    local p = assert(plan.parse(text))
    assert.same({ "first", "second" }, p.test_goals)
  end)

  -- section names are case-insensitive ----------------------------------------

  it("accepts section names in any case", function()
    local text = "## PLAN\ncontext: a.lua\n\n## PROMPT\nDo it.\n"
    local p, err = plan.parse(text)
    assert.is_not_nil(p, tostring(err))
    assert.equals("Do it.", p.prompt)
  end)

  it("accepts mixed-case section names", function()
    local text = "## Plan\ncontext: a.lua\n\n## System Prompt\nBe helpful.\n\n## Prompt\nDo it.\n"
    local p = assert(plan.parse(text))
    assert.equals("Be helpful.", p.system_prompt)
  end)

  -- ### does NOT start a new section ------------------------------------------

  it("treats ### headers inside prompt as prompt content, not a new section", function()
    local text = [[
## plan
context: a.lua

## prompt
Do it.

### Sub-heading inside prompt

More prompt content.
]]
    local p = assert(plan.parse(text))
    assert.is_truthy(p.prompt:find("Sub-heading inside prompt", 1, true),
      "### sub-heading should remain part of prompt")
    assert.is_truthy(p.prompt:find("More prompt content", 1, true))
  end)

  it("treats #### inside plan section as a plain line (not a new section)", function()
    local text = "## plan\ncontext: a.lua\n#### not a section\noutput: b.lua\n\n## prompt\nDo it.\n"
    local p = assert(plan.parse(text))
    -- The #### line should not have caused a parse error; outputs should still be found
    assert.same({ "b.lua" }, p.outputs)
  end)

  -- optional system prompt ----------------------------------------------------

  it("system_prompt is nil when section absent", function()
    local p = assert(plan.parse(MINIMAL_PLAN))
    assert.is_nil(p.system_prompt)
  end)

  it("parses system prompt section", function()
    local text = "## plan\ncontext: a.lua\n\n## system prompt\nBe terse.\n\n## prompt\nDo it.\n"
    local p = assert(plan.parse(text))
    assert.equals("Be terse.", p.system_prompt)
  end)

  -- error cases ---------------------------------------------------------------

  it("errors when ## plan section is missing", function()
    local text = "## prompt\nDo it.\n"
    local p, err = plan.parse(text)
    assert.is_nil(p)
    assert.is_truthy(err:find("missing required section", 1, true))
    assert.is_truthy(err:find("plan", 1, true))
  end)

  it("errors when ## prompt section is missing", function()
    local text = "## plan\ncontext: a.lua\n"
    local p, err = plan.parse(text)
    assert.is_nil(p)
    assert.is_truthy(err:find("missing required section", 1, true))
    assert.is_truthy(err:find("prompt", 1, true))
  end)

  it("errors on duplicate ## plan section", function()
    local text = "## plan\ncontext: a.lua\n\n## plan\ncontext: b.lua\n\n## prompt\nDo it.\n"
    local p, err = plan.parse(text)
    assert.is_nil(p)
    assert.is_truthy(err:find("duplicate", 1, true))
    assert.is_truthy(err:find("plan", 1, true))
  end)

  it("errors on duplicate ## prompt section", function()
    local text = "## plan\ncontext: a.lua\n\n## prompt\nFirst.\n\n## prompt\nSecond.\n"
    local p, err = plan.parse(text)
    assert.is_nil(p)
    assert.is_truthy(err:find("duplicate", 1, true))
    assert.is_truthy(err:find("prompt", 1, true))
  end)

end)

-- ---------------------------------------------------------------------------
-- validate
-- ---------------------------------------------------------------------------

describe("plan.validate", function()

  local function make_plan(overrides)
    local base = {
      prompt          = "Do it.",
      context         = { "src/a.lua" },
      outputs         = {},
      sanitize_fences = true,
      test_goals      = {},
    }
    if overrides then
      for k, v in pairs(overrides) do base[k] = v end
    end
    return base
  end

  it("accepts a valid plan", function()
    local ok, err = plan.validate(make_plan())
    assert.is_true(ok, tostring(err))
  end)

  it("accepts a plan with no context entries", function()
    local ok, err = plan.validate(make_plan({ context = {} }))
    assert.is_true(ok, tostring(err))
  end)

  it("rejects empty prompt", function()
    local ok, err = plan.validate(make_plan({ prompt = "   " }))
    assert.is_nil(ok)
    assert.is_truthy(err:find("prompt", 1, true))
  end)

  it("rejects non-boolean sanitize_fences", function()
    local ok, err = plan.validate(make_plan({ sanitize_fences = "true" }))
    assert.is_nil(ok)
    assert.is_truthy(err:find("sanitize_fences", 1, true))
  end)

  it("accepts sanitize_fences = false", function()
    local ok, err = plan.validate(make_plan({ sanitize_fences = false }))
    assert.is_true(ok, tostring(err))
  end)

end)

-- ---------------------------------------------------------------------------
-- resolve_context_globs
-- ---------------------------------------------------------------------------

describe("plan.resolve_context_globs", function()

  it("calls globber for each pattern and returns sorted unique results", function()
    local called = {}
    local function fake_globber(pattern)
      called[#called + 1] = pattern
      if pattern == "src/*.lua" then
        return { "src/b.lua", "src/a.lua" }
      elseif pattern == "src/x.lua" then
        return { "src/x.lua" }
      end
      return {}
    end

    local files, err = plan.resolve_context_globs(
      { "src/*.lua", "src/x.lua" }, fake_globber)

    assert.is_not_nil(files, tostring(err))
    assert.same({ "src/a.lua", "src/b.lua", "src/x.lua" }, files)
    assert.equals(2, #called)
  end)

  it("deduplicates files that appear in multiple patterns", function()
    local function dup_globber(pattern)
      return { "src/a.lua", "src/b.lua" }
    end

    local files = assert(plan.resolve_context_globs(
      { "src/*.lua", "src/**/*.lua" }, dup_globber))
    -- Each file should appear exactly once
    assert.equals(2, #files)
  end)

  it("returns empty list when all globs match nothing", function()
    local files = assert(plan.resolve_context_globs(
      { "nonexistent/**" }, function(_) return {} end))
    assert.equals(0, #files)
  end)

  it("propagates globber errors", function()
    local function erroring_globber(pattern)
      return nil, "disk error"
    end

    local files, err = plan.resolve_context_globs({ "x" }, erroring_globber)
    assert.is_nil(files)
    assert.is_truthy(err:find("disk error", 1, true))
  end)

end)
