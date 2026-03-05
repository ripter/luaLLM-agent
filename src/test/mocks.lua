-- spec/support/mocks.lua
local M = {}

-- Reset require cache for modules under test, so each test starts clean.
function M.reset_loaded(prefixes)
  prefixes = prefixes or { "src%.", "src/" }
  for k, _ in pairs(package.loaded) do
    for _, pat in ipairs(prefixes) do
      if k:match(pat) then
        package.loaded[k] = nil
        break
      end
    end
  end
end

-- Helper for mocking a response
function M.fake_response(content, usage)
  return {
    choices = { { message = { role = "assistant", content = content } } },
    usage   = usage,
  }
end



-- Minimal fake config store that tests can mutate.
local function make_config(overrides)
  overrides = overrides or {}
  local store = overrides.store or {}

  local config = {
    load = function() return true end,
    get = function(key)
      return store[key]
    end,
    _store = store,
  }

  return config
end

-- Minimal fake luallm. Keep resolve_model dumb on purpose.
local function make_luallm(overrides)
  overrides = overrides or {}
  local state_resp = overrides.state_resp or { last_used = "test-model", servers = {} }
  local complete_resp = overrides.complete_resp or {
    choices = { { message = { content = "ok" } } },
    usage = { total_tokens = 1 },
  }

  return {
    state = overrides.state or function()
      if overrides.state_err then return nil, overrides.state_err end
      return state_resp, nil
    end,

    resolve_model = overrides.resolve_model or function()
      return overrides.model or "test-model", overrides.port
    end,

    complete = overrides.complete or function()
      if overrides.complete_err then return nil, overrides.complete_err end
      return complete_resp, nil
    end,
  }
end

local function make_safe_fs(overrides)
  overrides = overrides or {}
  local calls = { write_file = {} }

  local safe_fs = {
    validate_policy = overrides.validate_policy or function()
      if overrides.policy_err then return nil, overrides.policy_err end
      return true, nil
    end,

    is_allowed = overrides.is_allowed or function(path, allowed, blocked)
      if overrides.is_allowed_err then return false, overrides.is_allowed_err end
      return true, nil
    end,

    write_file = overrides.write_file or function(path, content, allowed, blocked)
      table.insert(calls.write_file, {
        path          = path,
        content       = content,
        allowed_paths = allowed,
        blocked_paths = blocked,
      })
      if overrides.write_err then return nil, overrides.write_err end
      return true, nil
    end,

    _calls = calls,
  }

  return safe_fs
end

-- Capture prints without needing luassert output capture tricks.
local function capture_prints()
  local out = {}
  local old_print = _G.print
  _G.print = function(...)
    local t = {}
    for i = 1, select("#", ...) do
      t[#t+1] = tostring(select(i, ...))
    end
    out[#out+1] = table.concat(t, "\t")
  end
  return out, function() _G.print = old_print end
end

function M.make_deps(overrides)
  overrides = overrides or {}

  local config  = overrides.config  or make_config(overrides.config_overrides)
  local luallm  = overrides.luallm  or make_luallm(overrides.luallm_overrides)
  local safe_fs = overrides.safe_fs or make_safe_fs(overrides.safe_fs_overrides)

  -- Expose the write_file call log as a flat array for tests that do:
  --   local deps, written = mocks.make_deps(...)
  --   assert.equals(1, #written)
  local written = safe_fs._calls and safe_fs._calls.write_file or {}

  local cmd_generate = overrides.cmd_generate or require("cmd_generate")

  return {
    config         = config,
    luallm         = luallm,
    safe_fs        = safe_fs,
    cmd_generate   = cmd_generate,
    capture_prints = capture_prints,
  }, written
end

-- ---------------------------------------------------------------------------
-- Plan-specific mock factories
-- ---------------------------------------------------------------------------

--- Build a baseline plan table for cmd_plan tests.
--- Pass `overrides` to set specific fields.  To explicitly set a field to nil,
--- use the sentinel value `mocks.NIL` — make_plan will clear that key.
M.NIL = {}  -- sentinel: means "set this key to nil in make_plan"

function M.make_plan(overrides)
  local base = {
    title           = "Test Plan",
    model           = nil,
    system_prompt   = nil,
    sanitize_fences = true,
    context         = { "src/a.lua" },
    outputs         = { "src/out.lua" },
    test_runner     = nil,
    test_goals      = {},
    prompt          = "Write a module.",
  }
  if overrides then
    for k, v in pairs(overrides) do
      if v == M.NIL then
        base[k] = nil
      else
        base[k] = v
      end
    end
  end
  return base
end

--- Build a stub plan module.
--- `plan_table` is the table that load_file will return (nil to simulate error).
--- Supported overrides: load_err, validate_err, glob_err.
function M.make_plan_mod(plan_table, overrides)
  overrides = overrides or {}
  return {
    parse = function(_text)
      if overrides.parse_err then return nil, overrides.parse_err end
      return plan_table, nil
    end,
    load_file = function(_path)
      if overrides.load_err then return nil, overrides.load_err end
      return plan_table, nil
    end,
    validate = function(_p)
      if overrides.validate_err then return nil, overrides.validate_err end
      return true, nil
    end,
    resolve_context_globs = function(patterns, globber)
      if overrides.glob_err then return nil, overrides.glob_err end
      local files = {}
      local seen  = {}
      for _, pat in ipairs(patterns) do
        local matched = globber(pat) or {}
        for _, f in ipairs(matched) do
          if not seen[f] then seen[f] = true; files[#files + 1] = f end
        end
      end
      table.sort(files)
      return files, nil
    end,
  }
end

--- Build a stub cmd_generate_context module.
--- Tracks calls in ._calls.  Supports overrides: run_err.
--- `written_set` is a table that the stub will add output_path keys to,
--- so that a paired fake_fs can report them as existing after generate.
function M.make_gen_ctx(overrides, written_set)
  overrides   = overrides   or {}
  written_set = written_set or {}
  local calls = {}
  return {
    run = function(_gen_deps, gen_args)
      calls[#calls + 1] = { args = gen_args }
      if overrides.run_err then return nil, overrides.run_err end
      -- Mark the output as "written" so fake_fs sees it.
      if gen_args.output_path then
        written_set[gen_args.output_path] = true
      end
      return true, {
        model       = "test-model",
        tokens      = "42",
        output_path = gen_args.output_path,
      }
    end,
    _calls = calls,
  }
end

--- Build a fake filesystem dep for cmd_plan.
--- `existing`   list of paths that exist from the start.
--- `written_set` shared table that make_gen_ctx updates after each generate call;
---              paths added there will also be reported as existing.
function M.make_fs(existing, written_set)
  existing    = existing    or {}
  written_set = written_set or {}
  local exist_set = {}
  for _, p in ipairs(existing) do exist_set[p] = true end
  return {
    exists = function(path)
      return exist_set[path] or written_set[path] or false
    end,
  }
end

--- Build a complete deps table for cmd_plan.run tests.
---
--- overrides:
---   plan_table         — result of M.make_plan(...)
---   plan_mod_overrides — forwarded to M.make_plan_mod
---   gen_ctx_overrides  — forwarded to M.make_gen_ctx
---   existing_outputs   — list of output paths that exist before run
---   globber            — function(pat) -> {paths}
---   config / luallm / safe_fs — pass-through
---
--- Returns (deps, gen_ctx, printed_lines).
function M.make_plan_deps(overrides)
  overrides = overrides or {}

  local plan_tbl  = overrides.plan_table or M.make_plan(overrides.plan_overrides)

  -- Shared written_set: gen_ctx writes here, fs.exists reads from it.
  local written_set = {}

  local gen_ctx = overrides.gen_ctx
              or M.make_gen_ctx(overrides.gen_ctx_overrides, written_set)

  -- Plain cmd_generate stub (used for no-context fallback path).
  -- Also writes to written_set so fs.exists sees the output after generate.
  local cmd_generate = overrides.cmd_generate or {
    run = function(_, gen_args)
      if gen_args.output_path then written_set[gen_args.output_path] = true end
      return true, { model = "test-model", tokens = "1", output_path = gen_args.output_path }
    end,
    run_with_context = function(_, gen_args)
      if gen_args.output_path then written_set[gen_args.output_path] = true end
      return true, { model = "test-model", tokens = "1", output_path = gen_args.output_path }
    end,
  }

  local fs = overrides.fs
          or M.make_fs(overrides.existing_outputs, written_set)

  local plan_mod = overrides.plan_mod
               or M.make_plan_mod(plan_tbl, overrides.plan_mod_overrides)

  local lines  = {}
  local emit   = function(s) lines[#lines + 1] = s end

  local config  = overrides.config  or make_config(overrides.config_overrides  or {})
  local luallm  = overrides.luallm  or make_luallm(overrides.luallm_overrides  or {})
  local safe_fs = overrides.safe_fs or make_safe_fs(overrides.safe_fs_overrides or {})

  local deps = {
    plan                 = plan_mod,
    globber              = overrides.globber or function(pat) return { pat } end,
    cmd_generate_context = gen_ctx,
    cmd_generate         = cmd_generate,
    luallm               = luallm,
    safe_fs              = safe_fs,
    config               = config,
    fs                   = fs,
    print                = emit,
  }

  return deps, gen_ctx, lines
end

-- ---------------------------------------------------------------------------
-- cmd_plan mock factory
-- ---------------------------------------------------------------------------

--- Build a stub cmd_plan module for agent tests.
--- Supported overrides:
---   run_err  — error string; causes run() to return nil + err
--- Tracks all calls in ._calls.
function M.make_cmd_plan(overrides)
  overrides = overrides or {}
  local calls = {}
  return {
    run = function(args, deps)
      calls[#calls + 1] = { args = args, deps = deps }
      if overrides.run_err then return nil, overrides.run_err end
      return true, nil
    end,
    _calls = calls,
  }
end

-- ---------------------------------------------------------------------------
-- skill_loader mock factory
-- ---------------------------------------------------------------------------

--- Build a stub skill_loader module for agent tests.
--- `skill_paths` is a list of output paths that should be recognised as skills.
--- Any path in the list returns a minimal metadata table; others return nil.
--- Supported overrides:
---   skill_paths — list of paths that parse successfully as skills (default: {})
--- Tracks all parse_metadata calls in ._calls.
function M.make_skill_loader(overrides)
  overrides   = overrides or {}
  local skill_set = {}
  for _, p in ipairs(overrides.skill_paths or {}) do
    skill_set[p] = true
  end
  local calls = {}
  return {
    parse_metadata = function(path)
      calls[#calls + 1] = path
      if skill_set[path] then
        return { name = path, paths = {}, dependencies = {}, public_functions = {} }, nil
      end
      return nil, "not a skill: " .. tostring(path)
    end,
    _calls = calls,
  }
end

-- ---------------------------------------------------------------------------
-- skill_runner mock factory
-- ---------------------------------------------------------------------------

--- Build a stub skill_runner module for agent tests.
--- `results` maps test_path → result table (or error string for hard failure).
--- A result table shape: { passed=bool, output=string, exit_code=int, timed_out=bool }
--- If a path is not in the map, run_tests returns a passing result by default.
--- Supported overrides:
---   results  — map of test_path -> { passed, output } or error_string
---   default_passed — boolean, controls default when path not in results (default: true)
--- Tracks all run_tests calls in ._calls.
function M.make_skill_runner(overrides)
  overrides = overrides or {}
  local result_map    = overrides.results       or {}
  local default_pass  = overrides.default_passed
  if default_pass == nil then default_pass = true end
  local calls = {}

  return {
    run_tests = function(test_path, _timeout)
      calls[#calls + 1] = test_path
      local r = result_map[test_path]
      if r == nil then
        -- Default: passing result.
        return {
          passed    = default_pass,
          output    = default_pass and "ok" or "FAILED",
          exit_code = default_pass and 0 or 1,
          timed_out = false,
        }, nil
      end
      if type(r) == "string" then
        -- Hard failure (e.g. file not found).
        return nil, r
      end
      -- Explicit result table.
      return {
        passed    = r.passed,
        output    = r.output    or "",
        exit_code = r.exit_code or (r.passed and 0 or 1),
        timed_out = r.timed_out or false,
      }, nil
    end,
    _calls = calls,
  }
end

-- ---------------------------------------------------------------------------
-- approval mock factory
-- ---------------------------------------------------------------------------

--- Build a stub approval module for agent tests.
--- Supported overrides:
---   create_err      — error string; causes create() to return nil + err
---   approval_id     — id placed in every returned record (default: "test-approval-id")
---   promotion_cmds  — list returned by get_promotion_commands (default: {"# cmd1"})
---   promotion_err   — error string; causes get_promotion_commands() to return nil + err
--- Tracks calls in ._create_calls, ._promo_calls, ._get_calls, ._prompt_calls,
--- and ._check_calls.
---
--- Supported overrides:
---   approval_id       — id in every create record (default: "test-approval-id")
---   create_err        — error string for create()
---   promotion_cmds    — list returned by get_promotion_commands
---   promotion_err     — error string for get_promotion_commands
---   promoted_skills   — set of skill_names that check_promotion returns true for
---   get_record        — table returned by get() (default: minimal record)
---   get_err           — error string for get()
---   prompt_response   — string returned by prompt_human (default: "reject")
function M.make_approval(overrides)
  overrides = overrides or {}
  local create_calls  = {}
  local promo_calls   = {}
  local get_calls     = {}
  local prompt_calls  = {}
  local check_calls   = {}
  local approval_id   = overrides.approval_id or "test-approval-id"

  -- Build promoted set from list.
  local promoted_set = {}
  for _, name in ipairs(overrides.promoted_skills or {}) do
    promoted_set[name] = true
  end

  return {
    create = function(skill_name, skill_path, test_path, test_results, metadata, approvals_dir)
      create_calls[#create_calls + 1] = {
        skill_name    = skill_name,
        skill_path    = skill_path,
        test_path     = test_path,
        test_results  = test_results,
        metadata      = metadata,
        approvals_dir = approvals_dir,
      }
      if overrides.create_err then return nil, overrides.create_err end
      return {
        id         = approval_id,
        skill_name = skill_name,
        skill_path = skill_path or "",
        test_path  = test_path  or "",
      }, nil
    end,

    get = function(_approvals_dir, _approval_id)
      get_calls[#get_calls + 1] = { approvals_dir = _approvals_dir, approval_id = _approval_id }
      if overrides.get_err then return nil, overrides.get_err end
      return overrides.get_record or {
        id         = _approval_id or approval_id,
        skill_name = "stub_skill",
        skill_path = "src/stub_skill.lua",
        test_path  = "src/stub_skill.test.lua",
      }, nil
    end,

    check_promotion = function(skill_name, _allowed_dir)
      check_calls[#check_calls + 1] = { skill_name = skill_name, allowed_dir = _allowed_dir }
      return promoted_set[skill_name] == true
    end,

    prompt_human = function(record)
      prompt_calls[#prompt_calls + 1] = record
      return overrides.prompt_response or "reject"
    end,

    get_promotion_commands = function(record, allowed_dir)
      promo_calls[#promo_calls + 1] = { record = record, allowed_dir = allowed_dir }
      if overrides.promotion_err then return nil, overrides.promotion_err end
      return overrides.promotion_cmds or { "# promote " .. (record.skill_name or "?") }, nil
    end,

    _create_calls = create_calls,
    _promo_calls  = promo_calls,
    _get_calls    = get_calls,
    _prompt_calls = prompt_calls,
    _check_calls  = check_calls,
  }
end

-- ---------------------------------------------------------------------------
-- state mock factory
-- ---------------------------------------------------------------------------

--- Build a stub state module for agent tests.
--- Tracks save() calls in ._saved.
--- Supported overrides:
---   save_err — error string; causes save() to return nil + err
--- Supported overrides:
---   task_to_load — task table returned by load() (default: nil → triggers load_err)
---   load_err     — error string returned when task_to_load is nil (default: "no saved task")
---   save_err     — error string for save()
function M.make_state(overrides)
  overrides = overrides or {}
  local saved   = {}
  local cleared = { count = 0 }
  return {
    load = function()
      if overrides.task_to_load then return overrides.task_to_load, nil end
      return nil, overrides.load_err or "no saved task"
    end,

    save = function(task_obj)
      saved[#saved + 1] = task_obj
      if overrides.save_err then return nil, overrides.save_err end
      return true, nil
    end,

    clear = function()
      cleared.count = cleared.count + 1
      if overrides.clear_err then return nil, overrides.clear_err end
      return true, nil
    end,

    _saved   = saved,
    _cleared = cleared,
  }
end

-- ---------------------------------------------------------------------------
-- Planner-specific mock factory
-- ---------------------------------------------------------------------------

--- Build a stub planner module for agent tests.
--- Supported overrides:
---   generate_err   — error string; causes generate() to return nil + err
---   generate_path  — plan_path returned on success (default: "./plan.md")
---   replan_err     — error string; causes replan() to return nil + err
---   replan_path    — plan_path returned on success (default: "./plan.md")
--- Also tracks calls in ._generate_calls and ._replan_calls.
function M.make_planner(overrides)
  overrides = overrides or {}
  local generate_calls = {}
  local replan_calls   = {}

  return {
    generate = function(_deps, prompt, opts)
      generate_calls[#generate_calls + 1] = { prompt = prompt, opts = opts }
      if overrides.generate_err then return nil, overrides.generate_err end
      local path = overrides.generate_path or "./plan.md"
      return path, M.make_plan({ prompt = prompt })
    end,

    replan = function(_deps, task_obj, error_info, opts)
      replan_calls[#replan_calls + 1] = { task = task_obj, error_info = error_info, opts = opts }
      if overrides.replan_err then return nil, overrides.replan_err end
      local path = overrides.replan_path or "./plan.md"
      return path, M.make_plan({ prompt = task_obj and task_obj.prompt or "" })
    end,

    system_prompt = function() return "stub system prompt" end,

    _generate_calls = generate_calls,
    _replan_calls   = replan_calls,
  }
end

-- ---------------------------------------------------------------------------
-- Agent deps factory
-- ---------------------------------------------------------------------------

--- Build a task table for agent tests using the real task module.
--- Uses a fixed uuid so tests are deterministic.
function M.make_task_obj(overrides)
  overrides = overrides or {}
  local task_mod = require("task")
  local t = task_mod.new(
    overrides.prompt or "do something",
    function() return overrides.id or "test-task-id" end
  )
  for k, v in pairs(overrides) do
    if k ~= "prompt" and k ~= "id" then
      t[k] = v
    end
  end
  return t
end

--- Build a full deps table for agent tests.
--- Supported overrides:
---   planner_overrides      — forwarded to make_planner
---   plan_mod_overrides     — forwarded to make_plan_mod
---   cmd_plan_overrides      — forwarded to make_cmd_plan
---   skill_loader_overrides  — forwarded to make_skill_loader
---   skill_runner_overrides  — forwarded to make_skill_runner
---   approval_overrides     — forwarded to make_approval
---   state_overrides        — forwarded to make_state
---   config_overrides / luallm_overrides / safe_fs_overrides — pass-through
function M.make_agent_deps(overrides)
  overrides = overrides or {}

  local base_deps, written = M.make_deps({
    luallm_overrides  = overrides.luallm_overrides,
    safe_fs_overrides = overrides.safe_fs_overrides,
    config_overrides  = overrides.config_overrides,
  })

  local plan_tbl = M.make_plan(overrides.plan_overrides)
  local task_mod = require("task")

  local deps = {
    task         = task_mod,
    planner      = overrides.planner      or M.make_planner(overrides.planner_overrides or {}),
    plan         = overrides.plan         or M.make_plan_mod(plan_tbl, overrides.plan_mod_overrides or {}),
    cmd_plan     = overrides.cmd_plan     or M.make_cmd_plan(overrides.cmd_plan_overrides or {}),
    skill_loader = overrides.skill_loader or M.make_skill_loader(overrides.skill_loader_overrides or {}),
    skill_runner = overrides.skill_runner or M.make_skill_runner(overrides.skill_runner_overrides or {}),
    state        = overrides.state        or M.make_state(overrides.state_overrides or {}),
    approval     = overrides.approval     or M.make_approval(overrides.approval_overrides or {}),
    config       = base_deps.config,
    luallm       = base_deps.luallm,
    safe_fs      = base_deps.safe_fs,
    print        = overrides.print or function(_) end,
  }

  return deps, written
end

return M

