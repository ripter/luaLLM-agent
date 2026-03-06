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
  local state  = require("state")
  local config = require("config")
  config.load()           -- requires load() before get()
  state.init(config.default_dir() .. "/state")   -- absolute path must match allowed_paths
  return {
    task         = require("task"),
    planner      = require("planner"),
    cmd_plan     = require("cmd_plan"),
    cmd_generate         = require("cmd_generate"),
    cmd_generate_context = require("cmd_generate_context"),
    plan         = require("plan"),
    skill_loader = require("skill_loader"),
    skill_runner = require("skill_runner"),
    approval     = require("approval"),
    state        = state,
    config       = config,
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
-- Task output directory
-- ---------------------------------------------------------------------------

--- Derive and create the per-task output directory: <agent.output_dir>/<task_id>/
--- Stores the result on t.output_dir. Returns (dir, nil) or (nil, err).
local function ensure_task_output_dir(deps, t)
  if t.output_dir then
    return t.output_dir, nil
  end
  local util = require("util")
  local base = deps.config.get("agent.output_dir") or "~/agent_wrote"
  base = util.expand_tilde(base)
  local dir = base .. "/" .. (t.id or "task")
  local ok, err = util.mkdir_p(dir)
  if not ok then
    return nil, "could not create task output dir '" .. dir .. "': " .. tostring(err)
  end
  t.output_dir = dir
  return dir, nil
end

-- ---------------------------------------------------------------------------
-- Handler: PENDING → PLANNING
-- ---------------------------------------------------------------------------

local function handle_pending(deps, t)
  local _, err = ensure_task_output_dir(deps, t)
  if err then
    deps.task.transition(t, deps.task.FAILED, err)
    return t
  end
  deps.task.transition(t, deps.task.PLANNING, "starting")
  return t
end

-- ---------------------------------------------------------------------------
-- Rewrite relative output paths in a plan file to be absolute under task_dir
-- ---------------------------------------------------------------------------

--- Read plan.md, rewrite any relative `output:` lines to absolute paths
--- under task_dir, and write it back. Returns (true, nil) or (nil, err).
local function rewrite_output_paths(plan_path, task_dir)
  local util = require("util")
  local raw, err = util.read_file(plan_path)
  if not raw then
    return nil, "rewrite_output_paths: cannot read " .. plan_path .. ": " .. tostring(err)
  end

  local rewritten = raw:gsub("(output:%s*)([^\n]+)", function(prefix, path)
    path = path:match("^%s*(.-)%s*$")
    -- Leave absolute paths alone
    if path:sub(1, 1) == "/" or path:sub(1, 1) == "~" then
      return prefix .. path
    end
    return prefix .. task_dir .. "/" .. path
  end)

  local ok, werr = util.write_file_atomic(plan_path, rewritten)
  if not ok then
    return nil, "rewrite_output_paths: cannot write " .. plan_path .. ": " .. tostring(werr)
  end
  return true, nil
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
    output_dir    = t.output_dir or (deps.config.default_dir() .. "/state"),
  })

  if plan_path then
    -- Rewrite relative output: paths to be absolute under the task output dir.
    if t.output_dir then
      local _, rw_err = rewrite_output_paths(plan_path, t.output_dir)
      if rw_err then
        deps.task.transition(t, deps.task.FAILED, rw_err)
        return t
      end
    end
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
  local lfs = require("lfs")
  return {
    plan                    = deps.plan,
    globber                 = deps.plan.default_globber,
    cmd_generate_context    = deps.cmd_generate_context,
    cmd_generate            = deps.cmd_generate,
    luallm                  = deps.luallm,
    safe_fs                 = deps.safe_fs,
    config                  = deps.config,
    suppress_test_runner_note = true,
    fs                      = deps.fs or {
      exists = function(path)
        local attr = lfs.attributes(path)
        return attr ~= nil and attr.mode == "file"
      end
    },
    print                = deps.print or function(_) end,
  }
end

local function handle_executing(deps, t)
  local plan_deps = make_cmd_plan_deps(deps)

  -- If we have a fix_context from a previous logic failure, run a targeted
  -- fix pass: load the plan to get output paths, then re-generate each output
  -- with the current file content + fix instruction as context.
  if t.fix_context then
    local fix = t.fix_context
    t.fix_context = nil   -- consume it

    local plan_table
    if deps.plan and t.plan_path then
      local pt, _ = deps.plan.load_file(t.plan_path)
      plan_table = pt
    end

    local output_paths = (plan_table and plan_table.outputs) or t.outputs or {}
    local emit = deps.print or function(_) end
    local util = require("util")

    for _, output_path in ipairs(output_paths) do
      emit("  fixing → " .. output_path .. " …")

      -- Build context: current file contents + fix instruction
      local current = util.read_file(output_path)
      local fix_prompt = fix.prompt
      if current then
        fix_prompt = "Current file contents:\n\n" .. current .. "\n\n" .. fix.prompt
      end

      local gen_deps = {
        luallm       = deps.luallm,
        safe_fs      = deps.safe_fs,
        config       = deps.config,
        cmd_generate = deps.cmd_generate,
      }

      local ok, info = deps.cmd_generate.run(gen_deps, {
        output_path = output_path,
        prompt      = fix_prompt,
      })

      if not ok then
        local err = tostring(info)
        t.error = err
        if deps.task.can_retry(t, "plan") then
          deps.task.transition(t, deps.task.REPLANNING,
            "fix pass failed (will replan): " .. err)
        else
          deps.task.transition(t, deps.task.FAILED,
            "fix pass failed (no retries left): " .. err)
        end
        return t
      end

      emit("  ✓ " .. output_path .. "  (" .. (info.model or "?") .. ", " .. (info.tokens or "?") .. " tokens)")
    end

    -- Fall through to test_runner check below with the same plan_table
    t.outputs = output_paths

    -- Run test_runner on the fixed code (reuse plan_table loaded above)
    if plan_table and plan_table.test_runner and plan_table.test_runner ~= "" then
      local run_dir = t.output_dir or "."
      local runner  = plan_table.test_runner
      local cmd     = string.format("cd '%s' && %s 2>&1", run_dir:gsub("'", "'\\''"), runner)
      emit("  running test_runner: " .. runner)
      local handle   = io.popen(cmd, "r")
      local output   = handle and handle:read("*a") or ""
      local pok, _, exit_code = handle and handle:close()
      exit_code = (type(pok) == "number") and pok or (exit_code or (pok and 0 or 1))
      if exit_code ~= 0 then
        emit("  ✗ test_runner failed after fix (exit " .. tostring(exit_code) .. "):")
        emit("    " .. output:gsub("\n", "\n    "):match("^(.-)%s*$"))
        local err_msg = "test_runner failed after fix:\n" .. output
        t.error = err_msg
        -- Store another fix_context for next attempt
        t.fix_context = {
          error  = output,
          prompt = "The previous fix attempt still has this failure:\n" .. output
                .. "\n\nFix only the specific problem. Keep all working parts unchanged. "
                .. "Output the complete corrected file.",
        }
        if deps.task.can_retry(t, "plan") then
          deps.task.bump_attempt(t, "plan")
          deps.task.transition(t, deps.task.EXECUTING, "fix attempt failed, trying again")
        else
          deps.task.transition(t, deps.task.FAILED, "fix attempts exhausted")
        end
        return t
      end
      emit("  ✓ test_runner passed")
      t.error = nil
    end

    deps.task.transition(t, deps.task.COMPLETE, "fixed and verified")
    return t
  end

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

  -- Run the test_runner command if declared, for plain codegen tasks.
  -- For skill tasks this happens in handle_testing via skill_runner.run_tests.
  if plan_table and plan_table.test_runner and plan_table.test_runner ~= "" then
    local emit = deps.print or function(_) end
    local runner = plan_table.test_runner

    -- Run from the task output directory so relative paths work.
    local run_dir = t.output_dir or "."
    local safe_runner = runner:gsub("'", "'\\''")
    local cmd = string.format("cd '%s' && %s 2>&1", run_dir, safe_runner)

    emit("  running test_runner: " .. runner)
    local handle = io.popen(cmd, "r")
    local output = handle and handle:read("*a") or ""
    local pok, _, exit_code = handle and handle:close()
    exit_code = (type(pok) == "number") and pok or (exit_code or (pok and 0 or 1))

    if exit_code ~= 0 then
      local err_msg = "test_runner '" .. runner .. "' failed (exit " .. tostring(exit_code) .. "):\n" .. output

      -- Detect errors that require human action rather than LLM retry.
      local human_action = nil
      local lower_output = output:lower()

      -- Extract explicit luarocks hint first
      local explicit_rock = output:match("luarocks install ([%w%-_%.]+)")

      -- Extract missing module name from Lua's "module 'x' not found" message
      local missing_module = output:match("module '([^']+)' not found")

      -- Map known module names to their luarocks package names
      local MODULE_TO_ROCK = {
        ["luasql.sqlite3"]  = "luasql-sqlite3",
        ["luasql.mysql"]    = "luasql-mysql",
        ["luasql.postgres"] = "luasql-postgres",
        ["cjson"]           = "lua-cjson",
        ["cjson.safe"]      = "lua-cjson",
        ["lfs"]             = "luafilesystem",
        ["socket"]          = "luasocket",
        ["socket.http"]     = "luasocket",
        ["ltn12"]           = "luasocket",
        ["ssl"]             = "luasec",
        ["inspect"]         = "inspect",
        ["argparse"]        = "argparse",
        ["penlight"]        = "penlight",
        ["pl.path"]         = "penlight",
        ["uuid"]            = "uuid",
        ["lsqlite3"]        = "lsqlite3",
      }

      if explicit_rock or missing_module then
        local rock = explicit_rock
                  or (missing_module and MODULE_TO_ROCK[missing_module])
                  or (missing_module and missing_module:gsub("%.", "-"):gsub("/", "-"))
        human_action = "Missing Lua dependency: " .. (missing_module or rock) .. "\n"
                    .. "Install it with:\n"
                    .. "     luarocks install " .. rock
      elseif lower_output:match("permission denied") then
        human_action = "Permission denied. Check file/directory permissions."
      elseif lower_output:match("command not found") or lower_output:match("no such file or directory") then
        local missing = output:match("([^:'\n]+): command not found")
                     or output:match("([^:'\n]+): [Nn]o such file")
        human_action = "Required command not found: " .. (missing or "unknown") .. "\nInstall it and then run: ./agent agent resume"
      end

      if human_action then
        t.error = err_msg
        t.human_action = human_action
        emit("")
        emit("  ⚠  Action required before the agent can continue:")
        emit("     " .. human_action:gsub("\n", "\n     "))
        emit("")
        emit("  Once done, run:  ./agent agent resume")
        deps.task.transition(t, deps.task.AWAITING_HUMAN,
          "human action required: " .. human_action)
        return t
      end

      -- Classify the failure:
      -- SYNTAX errors (can't parse at all) → full replan, new code from scratch
      -- LOGIC errors (runs but output wrong) → re-execute with current code as context + fix instruction
      local is_syntax_error = output:match("unexpected symbol") or
                              output:match("'<eof>'") or
                              output:match("'<name>'") or
                              output:match("near '[^']+'")

      t.error = err_msg
      emit("  ✗ test_runner failed (exit " .. tostring(exit_code) .. "):")
      emit("    " .. output:gsub("\n", "\n    "):match("^(.-)%s*$"))

      if not is_syntax_error and deps.task.can_retry(t, "plan") then
        -- Logic failure: keep the existing plan but inject error context so
        -- the generator patches the code rather than rewriting from scratch.
        -- Store error for the next execute pass to use as additional context.
        t.fix_context = {
          error  = output,
          prompt = "The previous version had this test failure:\n" .. output
                .. "\n\nFix only the specific problem described above. "
                .. "Keep all working parts of the code unchanged. "
                .. "Output the complete corrected file.",
        }
        deps.task.bump_attempt(t, "plan")
        deps.task.transition(t, deps.task.EXECUTING,
          "logic failure, re-executing with fix context")
      elseif deps.task.can_retry(t, "plan") then
        deps.task.transition(t, deps.task.REPLANNING,
          "syntax failure, replanning: " .. err_msg)
      else
        deps.task.transition(t, deps.task.FAILED,
          "test_runner failed (no retries left): " .. err_msg)
      end
      return t
    end

    emit("  ✓ test_runner passed")
    t.error = nil
  end

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

local LIBRARY_API_HINTS = {
  lsqlite3 = [[
lsqlite3 correct API (NOT luasql):
  local sqlite3 = require("lsqlite3")
  local db = sqlite3.open("file.db")          -- returns db object (NOT env:open)
  db:exec("CREATE TABLE ...")                  -- for DDL with no results
  local stmt = db:prepare("SELECT ...")        -- returns stmt
  stmt:step()                                  -- advance; returns sqlite3.ROW or sqlite3.DONE
  stmt:get_value(0)                            -- get column 0 of current row
  stmt:reset()                                 -- reset for re-use
  stmt:finalize()                              -- close statement
  db:close()
  -- For INSERT with bound params:
  local stmt = db:prepare("INSERT INTO t VALUES (?)")
  stmt:bind(1, value)
  stmt:step()
  stmt:finalize()
  -- Do NOT use :get(), :get_integer(), :fetch(), :Prepare(), :Execute(), :Close()
  -- Those are luasql methods. lsqlite3 is a completely different library.]],
}

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

  -- If the error mentions a known library, inject a correct API reference so
  -- the LLM stops hallucinating methods from a different library.
  local err_text = (t.error or "") .. (error_info.test_output or "")
  for lib, hint in pairs(LIBRARY_API_HINTS) do
    if err_text:find(lib, 1, true) then
      error_info.message = error_info.message .. "\n\nAPI reference for " .. lib .. ":\n" .. hint
      break
    end
  end

  -- Include the actual generated file contents so the LLM can see what it wrote.
  if t.output_dir and type(t.outputs) == "table" then
    local util = require("util")
    local file_parts = {}
    for _, path in ipairs(t.outputs) do
      local content, _ = util.read_file(path)
      if content then
        file_parts[#file_parts + 1] = "--- " .. path .. " ---\n" .. content
      end
    end
    if #file_parts > 0 then
      error_info.skill_code = table.concat(file_parts, "\n\n")
    end
  end

  -- Clear the old plan_path so handle_planning does not short-circuit on the
  -- stale path; replan will set a new one below.
  t.plan_path = nil
  t.plan_text = nil

  local plan_path, result = deps.planner.replan(deps, t, error_info, {
    output_dir = t.output_dir or (deps.config.default_dir() .. "/state"),
  })

  if plan_path then
    if t.output_dir then
      local _, rw_err = rewrite_output_paths(plan_path, t.output_dir)
      if rw_err then
        deps.task.transition(t, deps.task.FAILED, rw_err)
        return t
      end
    end
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
-- Handler: AWAITING_HUMAN (paused — human must act then resume)
-- ---------------------------------------------------------------------------

-- This is a no-op handler: the task is paused and is_paused() returns true,
-- so the run() loop will exit before calling step() again. It's registered
-- so that step() doesn't error if called directly (e.g. in tests).
local function handle_awaiting_human(_deps, t)
  return t
end

-- ---------------------------------------------------------------------------
-- Dispatch table
-- ---------------------------------------------------------------------------

local HANDLERS = {
  [("pending")]        = handle_pending,
  [("planning")]       = handle_planning,
  [("executing")]      = handle_executing,
  [("testing")]        = handle_testing,
  [("approval")]       = handle_approval,
  [("awaiting_human")] = handle_awaiting_human,
  [("replanning")]     = handle_replanning,
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

  -- Allow human-directed retry from FAILED.
  if task_obj.status == deps.task.FAILED then
    emit("  Task failed previously. Checking what can be salvaged...")
    task_obj.attempts = { plan = 0, replan = 0, test = 0 }
    task_obj.error    = nil

    -- If output files already exist on disk, go straight to fix mode
    -- rather than replanning from scratch.
    local lfs = require("lfs")
    local outputs_exist = false
    if type(task_obj.outputs) == "table" and #task_obj.outputs > 0 then
      outputs_exist = true
      for _, path in ipairs(task_obj.outputs) do
        local attr = lfs.attributes(path)
        if not attr or attr.mode ~= "file" then
          outputs_exist = false
          break
        end
      end
    end

    if outputs_exist and task_obj.plan_path then
      emit("  Output files exist — will attempt targeted fix rather than full replan.")
      -- Reload plan_text so replan has context
      task_obj.plan_text = read_plan_text(task_obj.plan_path) or task_obj.plan_text
      -- Set fix_context so handle_executing does a patch pass
      task_obj.fix_context = {
        error  = "Previous run hit step limit. Tests were still failing.",
        prompt = "The previous attempt ran out of retries. "
              .. "Review the code and fix any remaining issues so all tests pass. "
              .. "Output the complete corrected file.",
      }
      deps.task.transition(task_obj, deps.task.EXECUTING, "human-directed retry with fix context")
    else
      emit("  No output files found — will replan from scratch.")
      task_obj.plan_path = nil
      task_obj.plan_text = nil
      deps.task.transition(task_obj, deps.task.REPLANNING, "human-directed retry, replanning")
    end

    if deps.state and type(deps.state.save) == "function" then
      deps.state.save(task_obj)
    end
  end

  -- If the task is in a non-terminal, non-paused status (e.g. crashed mid-flight
  -- while executing or planning), re-drive it through the state machine.
  if task_obj.status ~= deps.task.APPROVAL then
    if deps.task.is_terminal(task_obj) then
      emit("  Task is already in terminal status '" .. tostring(task_obj.status)
           .. "' — nothing to resume.")
      return task_obj
    end

    -- AWAITING_HUMAN: the human has completed the required action.
    -- Remind them what was needed, then transition back to EXECUTING.
    if task_obj.status == deps.task.AWAITING_HUMAN then
      if task_obj.human_action then
        emit("  Resuming after human action:")
        emit("     " .. task_obj.human_action:gsub("\n", "\n     "))
      end
      task_obj.human_action = nil
      task_obj.error        = nil
      deps.task.transition(task_obj, deps.task.EXECUTING, "resuming after human action")
      if deps.state and type(deps.state.save) == "function" then
        deps.state.save(task_obj)
      end
    end

    emit("  Task status is '" .. tostring(task_obj.status)
         .. "' — re-entering state machine.")

    -- On human-directed retry, reload plan_text from disk if plan_path exists
    -- so handle_replanning has context to give the LLM.
    if task_obj.plan_path and (not task_obj.plan_text or task_obj.plan_text == "") then
      task_obj.plan_text = read_plan_text(task_obj.plan_path)
    end

    local max_steps = (opts and opts.max_steps) or 20
    for _ = 1, max_steps do
      if deps.task.is_terminal(task_obj) then break end
      if deps.task.is_paused(task_obj)   then break end
      local ok, step_err = M.step(deps, task_obj)
      if not ok then
        task_obj.error = tostring(step_err)
        emit("  ✗ step error: " .. task_obj.error)
        deps.task.transition(task_obj, deps.task.FAILED, task_obj.error)
      end
      if deps.state and type(deps.state.save) == "function" then
        deps.state.save(task_obj)
      end
    end

    if not deps.task.is_terminal(task_obj) and not deps.task.is_paused(task_obj) then
      task_obj.error = "max steps exceeded on resume"
      deps.task.transition(task_obj, deps.task.FAILED, task_obj.error)
      if deps.state and type(deps.state.save) == "function" then
        deps.state.save(task_obj)
      end
    end

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
