--- src/cmd_plan.test.lua
--- Busted tests for src/cmd_plan.lua — dependency-injected via src/test/mocks.lua.

local mocks    = require("test.mocks")
local cmd_plan = require("cmd_plan")

-- Shorthand
local NIL = mocks.NIL

-- ---------------------------------------------------------------------------
-- Tests: check
-- ---------------------------------------------------------------------------

describe("cmd_plan.run (check)", function()

  it("prints summary for a valid plan", function()
    local deps, _, lines = mocks.make_plan_deps({
      plan_overrides = {
        title   = "My Plan",
        model   = "llama3",
        context = { "src/a.lua", "src/b.lua" },
        outputs = { "src/out1.lua", "src/out2.lua" },
      },
      globber = function(pat) return { pat } end,
    })

    local ok, err = cmd_plan.run({ subcommand = "check", plan_path = "plan.md" }, deps)

    assert.is_true(ok, tostring(err))
    local joined = table.concat(lines, "\n")
    assert.is_truthy(joined:find("My Plan",          1, true), "should print title")
    assert.is_truthy(joined:find("llama3",            1, true), "should print model")
    assert.is_truthy(joined:find("Outputs declared",  1, true), "should show outputs label")
  end)

  it("prints (not set) when model is nil", function()
    local deps, _, lines = mocks.make_plan_deps({
      plan_overrides = { model = NIL },
    })

    cmd_plan.run({ subcommand = "check", plan_path = "plan.md" }, deps)

    assert.is_truthy(table.concat(lines, "\n"):find("not set", 1, true))
  end)

  it("prints (none) when title is nil", function()
    local deps, _, lines = mocks.make_plan_deps({
      plan_overrides = { title = NIL },
    })

    cmd_plan.run({ subcommand = "check", plan_path = "plan.md" }, deps)

    assert.is_truthy(table.concat(lines, "\n"):find("none", 1, true))
  end)

  it("context files count reflects what globber returns", function()
    local deps, _, lines = mocks.make_plan_deps({
      plan_overrides = { context = { "src/*.lua" } },
      globber = function(_) return { "src/a.lua", "src/b.lua", "src/c.lua" } end,
    })

    cmd_plan.run({ subcommand = "check", plan_path = "plan.md" }, deps)

    local joined = table.concat(lines, "\n")
    assert.is_truthy(joined:find("Context files", 1, true))
    assert.is_truthy(joined:find("3", 1, true))
  end)

  it("returns nil + error when plan load fails", function()
    local deps, _, _ = mocks.make_plan_deps({
      plan_mod_overrides = { load_err = "file not found" },
    })

    local ok, err = cmd_plan.run({ subcommand = "check", plan_path = "missing.md" }, deps)

    assert.is_nil(ok)
    assert.is_truthy(err:find("file not found", 1, true))
  end)

  it("returns nil + error when validation fails", function()
    local deps, _, _ = mocks.make_plan_deps({
      plan_mod_overrides = { validate_err = "prompt is empty" },
    })

    local ok, err = cmd_plan.run({ subcommand = "check", plan_path = "bad.md" }, deps)

    assert.is_nil(ok)
    assert.is_truthy(err:find("prompt is empty", 1, true))
  end)

  it("does not call cmd_generate_context", function()
    local deps, gen_ctx, _ = mocks.make_plan_deps({})

    cmd_plan.run({ subcommand = "check", plan_path = "plan.md" }, deps)

    assert.equals(0, #gen_ctx._calls, "check must not call generate")
  end)

end)

-- ---------------------------------------------------------------------------
-- Tests: run
-- ---------------------------------------------------------------------------

describe("cmd_plan.run (run)", function()

  it("calls cmd_generate_context.run once per declared output", function()
    local deps, gen_ctx, _ = mocks.make_plan_deps({
      plan_overrides   = { outputs = { "src/out1.lua", "src/out2.lua" } },
      existing_outputs = { "src/out1.lua", "src/out2.lua" },
    })

    local ok, err = cmd_plan.run({ subcommand = "run", plan_path = "plan.md" }, deps)

    assert.is_true(ok, tostring(err))
    assert.equals(2, #gen_ctx._calls)
    assert.equals("src/out1.lua", gen_ctx._calls[1].args.output_path)
    assert.equals("src/out2.lua", gen_ctx._calls[2].args.output_path)
  end)

  it("passes the plan prompt to generate", function()
    local deps, gen_ctx, _ = mocks.make_plan_deps({
      plan_overrides = { prompt = "Build a widget.", outputs = { "src/widget.lua" } },
    })

    cmd_plan.run({ subcommand = "run", plan_path = "plan.md" }, deps)

    assert.equals("Build a widget.", gen_ctx._calls[1].args.prompt)
  end)

  it("passes resolved context files to generate", function()
    local deps, gen_ctx, _ = mocks.make_plan_deps({
      plan_overrides = { context = { "src/*.lua" }, outputs = { "src/out.lua" } },
      globber = function(_) return { "src/a.lua", "src/b.lua" } end,
    })

    cmd_plan.run({ subcommand = "run", plan_path = "plan.md" }, deps)

    local ctx = gen_ctx._calls[1].args.context_paths
    assert.is_truthy(ctx)
    local names = {}
    for _, f in ipairs(ctx) do names[f] = true end
    assert.is_true(names["src/a.lua"], "context should contain src/a.lua")
    assert.is_true(names["src/b.lua"], "context should contain src/b.lua")
  end)

  it("injects system_prompt override via wrapped config", function()
    local captured_config
    local gen_ctx_spy = {
      run = function(gen_deps, gen_args)
        captured_config = gen_deps.config
        return true, { model = "m", tokens = "1", output_path = gen_args.output_path }
      end,
      _calls = {},
    }

    local deps, _, _ = mocks.make_plan_deps({
      plan_overrides = { system_prompt = "Be terse.", outputs = { "src/out.lua" } },
      gen_ctx        = gen_ctx_spy,
    })

    cmd_plan.run({ subcommand = "run", plan_path = "plan.md" }, deps)

    assert.is_not_nil(captured_config)
    assert.equals("Be terse.", captured_config.get("generate.system_prompt"))
  end)

  it("injects sanitize_fences=false override via wrapped config", function()
    local captured_config
    local gen_ctx_spy = {
      run = function(gen_deps, gen_args)
        captured_config = gen_deps.config
        return true, { model = "m", tokens = "1", output_path = gen_args.output_path }
      end,
      _calls = {},
    }

    local deps, _, _ = mocks.make_plan_deps({
      plan_overrides = { sanitize_fences = false, outputs = { "src/out.lua" } },
      gen_ctx        = gen_ctx_spy,
    })

    cmd_plan.run({ subcommand = "run", plan_path = "plan.md" }, deps)

    assert.is_false(captured_config.get("generate.sanitize_fences"))
  end)

  it("returns nil + error when generate fails", function()
    local deps, _, _ = mocks.make_plan_deps({
      gen_ctx_overrides = { run_err = "connection refused" },
    })

    local ok, err = cmd_plan.run({ subcommand = "run", plan_path = "plan.md" }, deps)

    assert.is_nil(ok)
    assert.is_truthy(err:find("connection refused", 1, true))
  end)

  it("returns nil + error when a declared output is missing after run", function()
    local gen_ctx_no_write = {
      run = function(_, gen_args)
        return true, { model = "m", tokens = "1", output_path = gen_args.output_path }
      end,
      _calls = {},
    }
    local deps, _, _ = mocks.make_plan_deps({
      plan_overrides = { outputs = { "src/out.lua" } },
      gen_ctx        = gen_ctx_no_write,
      fs             = { exists = function(_) return false end },
    })

    local ok, err = cmd_plan.run({ subcommand = "run", plan_path = "plan.md" }, deps)

    assert.is_nil(ok)
    assert.is_truthy(err:find("missing", 1, true))
    assert.is_truthy(err:find("src/out.lua", 1, true))
  end)

  it("falls back to plain generate when context patterns resolve to zero files", function()
    local cmd_generate_calls = {}
    local cmd_generate_stub = {
      run = function(_, gen_args)
        cmd_generate_calls[#cmd_generate_calls + 1] = gen_args
        return true, { model = "m", tokens = "1", output_path = gen_args.output_path }
      end,
    }
    local gen_ctx_spy = {
      run    = function() error("cmd_generate_context must not be called with no context") end,
      _calls = {},
    }
    local deps, _, _ = mocks.make_plan_deps({
      plan_overrides = {
        context = {},
        outputs = { "src/out.lua" },
        prompt  = "Write a module.",
      },
      globber      = function(_) return {} end,
      gen_ctx      = gen_ctx_spy,
      cmd_generate = cmd_generate_stub,
      fs           = { exists = function(_) return true end },
    })

    local ok, err = cmd_plan.run({ subcommand = "run", plan_path = "plan.md" }, deps)

    assert.is_true(ok, tostring(err))
    assert.equals(1, #cmd_generate_calls)
    assert.equals("src/out.lua", cmd_generate_calls[1].output_path)
  end)

  it("succeeds with no declared outputs (runs generate once)", function()
    local deps, gen_ctx, _ = mocks.make_plan_deps({
      plan_overrides = { outputs = {}, context = { "src/a.lua" } },
    })

    local ok, err = cmd_plan.run({ subcommand = "run", plan_path = "plan.md" }, deps)

    assert.is_true(ok, tostring(err))
    assert.equals(1, #gen_ctx._calls)
  end)

  it("prints test_runner note when test_runner is set", function()
    local deps, _, lines = mocks.make_plan_deps({
      plan_overrides = { test_runner = "busted", outputs = { "src/out.lua" } },
    })

    cmd_plan.run({ subcommand = "run", plan_path = "plan.md" }, deps)

    local joined = table.concat(lines, "\n")
    assert.is_truthy(joined:find("busted",       1, true))
    assert.is_truthy(joined:find("not executed", 1, true))
  end)

end)

-- ---------------------------------------------------------------------------
-- Tests: resume
-- ---------------------------------------------------------------------------

describe("cmd_plan.run (resume)", function()

  it("prints 'nothing to do' and does not generate when all outputs exist", function()
    local deps, gen_ctx, lines = mocks.make_plan_deps({
      plan_overrides   = { outputs = { "src/out.lua" } },
      existing_outputs = { "src/out.lua" },
    })

    local ok, err = cmd_plan.run({ subcommand = "resume", plan_path = "plan.md" }, deps)

    assert.is_true(ok, tostring(err))
    assert.equals(0, #gen_ctx._calls)
    assert.is_truthy(table.concat(lines, "\n"):find("nothing to do", 1, true))
  end)

  it("generates only missing outputs, skips existing ones", function()
    local deps, gen_ctx, _ = mocks.make_plan_deps({
      plan_overrides   = { outputs = { "src/a.lua", "src/b.lua" } },
      existing_outputs = { "src/a.lua" },  -- only a.lua pre-exists
    })

    local ok, err = cmd_plan.run({ subcommand = "resume", plan_path = "plan.md" }, deps)

    assert.is_true(ok, tostring(err))
    assert.equals(1, #gen_ctx._calls)
    assert.equals("src/b.lua", gen_ctx._calls[1].args.output_path)
  end)

  it("returns nil + error when plan has no declared outputs", function()
    local deps, _, _ = mocks.make_plan_deps({
      plan_overrides = { outputs = {} },
    })

    local ok, err = cmd_plan.run({ subcommand = "resume", plan_path = "plan.md" }, deps)

    assert.is_nil(ok)
    assert.is_truthy(err:find("outputs", 1, true))
  end)

  it("returns nil + error when output still missing after generate", function()
    local gen_ctx_no_write = {
      run = function(_, gen_args)
        return true, { model = "m", tokens = "1", output_path = gen_args.output_path }
      end,
      _calls = {},
    }
    local deps, _, _ = mocks.make_plan_deps({
      plan_overrides = { outputs = { "src/out.lua" } },
      gen_ctx        = gen_ctx_no_write,
      fs             = { exists = function(_) return false end },
    })

    local ok, err = cmd_plan.run({ subcommand = "resume", plan_path = "plan.md" }, deps)

    assert.is_nil(ok)
    assert.is_truthy(err:find("still missing", 1, true))
  end)

  it("returns nil + error when generate fails during resume", function()
    local deps, _, _ = mocks.make_plan_deps({
      plan_overrides    = { outputs = { "src/out.lua" } },
      gen_ctx_overrides = { run_err = "LLM timeout" },
    })

    local ok, err = cmd_plan.run({ subcommand = "resume", plan_path = "plan.md" }, deps)

    assert.is_nil(ok)
    assert.is_truthy(err:find("LLM timeout", 1, true))
  end)

  it("prints list of missing outputs before generating", function()
    local deps, _, lines = mocks.make_plan_deps({
      plan_overrides = { outputs = { "src/a.lua", "src/b.lua" } },
      -- no existing_outputs => both are missing
    })

    cmd_plan.run({ subcommand = "resume", plan_path = "plan.md" }, deps)

    local joined = table.concat(lines, "\n")
    assert.is_truthy(joined:find("src/a.lua", 1, true))
    assert.is_truthy(joined:find("src/b.lua", 1, true))
  end)

end)

-- ---------------------------------------------------------------------------
-- Tests: new
-- ---------------------------------------------------------------------------

describe("cmd_plan.run (new)", function()

  local tmp_path = "/tmp/test_plan_new_" .. tostring(os.time()) .. ".md"

  after_each(function()
    os.remove(tmp_path)
  end)

  it("creates a file at the given path", function()
    local deps, _, _ = mocks.make_plan_deps({})

    local ok, err = cmd_plan.run({ subcommand = "new", plan_path = tmp_path }, deps)

    assert.is_true(ok, tostring(err))
    local f = io.open(tmp_path, "r")
    assert.is_not_nil(f, "file should exist")
    if f then f:close() end
  end)

  it("written file contains required section headers", function()
    local deps, _, _ = mocks.make_plan_deps({})

    cmd_plan.run({ subcommand = "new", plan_path = tmp_path }, deps)

    local f = io.open(tmp_path, "r")
    assert.is_not_nil(f)
    local content = f:read("*a")
    f:close()

    assert.is_truthy(content:find("## plan",   1, true))
    assert.is_truthy(content:find("## prompt", 1, true))
  end)

  it("written file does not contain a # <title> placeholder", function()
    local deps, _, _ = mocks.make_plan_deps({})

    cmd_plan.run({ subcommand = "new", plan_path = tmp_path }, deps)

    local f = io.open(tmp_path, "r")
    local content = f:read("*a")
    f:close()

    assert.is_falsy(content:find("# <title>", 1, true))
  end)

  it("written file contains default key stubs", function()
    local deps, _, _ = mocks.make_plan_deps({})

    cmd_plan.run({ subcommand = "new", plan_path = tmp_path }, deps)

    local f = io.open(tmp_path, "r")
    local content = f:read("*a")
    f:close()

    assert.is_truthy(content:find("sanitize_fences:", 1, true))
    assert.is_truthy(content:find("context:",         1, true))
    assert.is_truthy(content:find("output:",          1, true))
  end)

  it("returns nil + error when file cannot be written", function()
    local deps, _, _ = mocks.make_plan_deps({})

    local ok, err = cmd_plan.run({
      subcommand = "new",
      plan_path  = "/no/such/dir/plan.md",
    }, deps)

    assert.is_nil(ok)
    assert.is_truthy(err ~= nil)
  end)

end)

-- ---------------------------------------------------------------------------
-- Tests: error cases
-- ---------------------------------------------------------------------------

describe("cmd_plan.run (errors)", function()

  it("returns nil + error for unknown subcommand", function()
    local deps, _, _ = mocks.make_plan_deps({})

    local ok, err = cmd_plan.run({ subcommand = "explode", plan_path = "plan.md" }, deps)

    assert.is_nil(ok)
    assert.is_truthy(err:find("unknown subcommand", 1, true))
    assert.is_truthy(err:find("explode",            1, true))
  end)

  it("returns nil + error when plan_path is empty", function()
    local deps, _, _ = mocks.make_plan_deps({})

    local ok, err = cmd_plan.run({ subcommand = "run", plan_path = "" }, deps)

    assert.is_nil(ok)
    assert.is_truthy(err:find("plan_path", 1, true))
  end)

end)
