# 🎯 Orchestrator Build Plan — Discrete Steps

## Scope (v1)

Two capabilities:

1. **Skill draft → test → approval loop**: User gives a prompt → LLM generates a plan.md → plan runs and produces skill files → tests run → if pass, enter approval → human promotes → done.
2. **LLM-driven re-planning on failure**: If plan generation fails or tests fail, feed the error back to the LLM and ask for a revised plan. Bounded retries.

**Explicitly not in v1**: task graph DAG execution, audit logging of every transition. These can be added later as orthogonal concerns.

**Pattern**: Same deps injection as every other module. Every public function takes `(deps, ...)`.

---

## Architecture Overview

```
User prompt
    │
    ▼
┌─────────────┐
│  cmd_agent   │  CLI wrapper (run / resume / reset / status)
└──────┬──────┘
       │
       ▼
┌─────────────┐
│   agent      │  State machine loop
└──────┬──────┘
       │ uses
       ├──→ task.lua         (pure data: task table, status constants, transitions)
       ├──→ planner.lua      (LLM → plan.md generation + re-plan on error)
       ├──→ cmd_plan          (existing: runs plan.md → writes files)
       ├──→ skill_loader      (existing: detect @skill metadata)
       ├──→ skill_runner      (existing: run tests)
       ├──→ approval          (existing: create record, prompt human, check promotion)
       └──→ state             (existing: atomic save/load of current_task.json)
```

---

## Step 1 — `src/task.lua` (Pure data, zero deps)

**What it is**: The task table schema and status machine. No I/O, no requires beyond basic Lua. Every other orchestrator module imports this for the status constants and transition rules.

**Public API**:

```lua
local task = require("task")

-- Status constants
task.PENDING      -- "pending"
task.PLANNING     -- "planning"
task.EXECUTING    -- "executing"
task.TESTING      -- "testing"
task.APPROVAL     -- "approval"
task.REPLANNING   -- "replanning"
task.COMPLETE     -- "complete"
task.FAILED       -- "failed"

-- Create a new task table
task.new(prompt)
--> {
-->   id             = <uuid string>,
-->   prompt         = prompt,
-->   status         = "pending",
-->   plan_path      = nil,
-->   plan_text      = nil,
-->   outputs        = {},        -- files produced by cmd_plan.run
-->   skill_files    = {},        -- subset of outputs with @skill metadata
-->   test_results   = nil,       -- from skill_runner.run_tests
-->   approval_id    = nil,       -- from approval.create
-->   error          = nil,       -- last error message
-->   attempts       = { plan = 0, replan = 0, test = 0 },
-->   max_attempts   = { plan = 3, replan = 2, test = 2 },
-->   history        = {},        -- append-only log of {status, ts, detail}
-->   created_at     = <iso8601>,
-->   updated_at     = <iso8601>,
--> }

-- Transition to a new status (validates the transition is legal)
task.transition(t, new_status, detail)
--> returns t (mutated) or nil, "illegal transition: X → Y"
--> appends to t.history, updates t.updated_at

-- Query helpers
task.is_terminal(t)    --> true if COMPLETE or FAILED
task.is_paused(t)      --> true if APPROVAL (waiting for human)
task.can_retry(t, key) --> true if t.attempts[key] < t.max_attempts[key]
task.bump_attempt(t, key) --> increments t.attempts[key], returns new count
```

**Legal transitions** (enforce in `transition()`):

```
PENDING     → PLANNING
PLANNING    → EXECUTING, FAILED
EXECUTING   → TESTING, COMPLETE, REPLANNING, FAILED
TESTING     → APPROVAL, REPLANNING, FAILED
APPROVAL    → COMPLETE, FAILED
REPLANNING  → PLANNING, FAILED
```

**Deps**: None. Uses `os.time()` for timestamps. Accepts an optional `uuid_fn` in `task.new()` for testability (defaults to `require("uuid")`).

**Test file**: `src/task.test.lua`

**What to test**:
- `task.new()` returns a table with all expected fields
- Every legal transition succeeds and updates history
- Every illegal transition returns nil + error
- `is_terminal`, `is_paused`, `can_retry` return correct booleans
- `bump_attempt` increments and returns count
- History grows with each transition

**Estimated size**: ~120 lines module, ~200 lines tests.

---

## Step 2 — `src/planner.lua` (LLM → plan.md)

**What it is**: Asks the LLM to produce a plan.md file from a user prompt. Also handles re-planning when given error context. This is the "brain" that turns a vague request into something `cmd_plan` can execute.

**Public API**:

```lua
local planner = require("planner")

-- Generate a fresh plan.md from a user prompt.
-- Writes the plan to a temp file path, validates it via plan.parse + plan.validate.
-- Returns (plan_path, plan_table) or (nil, error_string).
planner.generate(deps, prompt, opts)
-- opts (all optional):
--   context_files = {}     -- extra source files to include for the LLM
--   output_dir   = "."    -- where to write the plan.md
--   plan_name    = nil    -- filename override (default: auto-generated)

-- Generate a revised plan.md given a previous failure.
-- Same return signature as generate().
planner.replan(deps, task, error_info)
-- error_info = {
--   phase       = "testing" | "executing" | "planning",
--   message     = "...",
--   test_output = "..." (optional, raw test runner output),
--   plan_text   = "..." (optional, the plan that failed),
--   skill_code  = "..." (optional, the generated code that failed tests),
-- }

-- Build the system prompt that teaches the LLM the plan.md format.
-- Exposed for testing; not normally called directly.
planner.system_prompt()
```

**Deps table**:

```lua
{
  luallm  = luallm,   -- .complete(), .resolve_model(), .state()
  config  = config,   -- .get(), .load()
  plan    = plan,     -- .parse(), .validate()
  safe_fs = safe_fs,  -- .write_file()
}
```

**Key design decisions**:

The system prompt must teach the LLM:
- The exact plan.md format (## plan, ## prompt, ## system prompt sections)
- That `context:` lines reference existing files the generated code should use
- That `output:` lines are the files to generate
- That `sanitize_fences: true` strips markdown fences from output
- A few-shot example of a valid plan.md

For `replan()`, the prompt includes:
- The original user request
- What was tried (the previous plan.md content)
- What went wrong (error message, test output, generated code)
- Instruction to produce a revised plan.md that avoids the same failure

**Test file**: `src/planner.test.lua`

**What to test**:
- `generate()` calls `luallm.complete()` with the right system prompt
- `generate()` writes a file and returns a valid plan_path
- `generate()` fails gracefully when LLM returns garbage (not a valid plan)
- `generate()` fails when LLM returns plan that fails `plan.validate()`
- `replan()` includes error context in the prompt
- `replan()` includes the failed plan text and test output
- `system_prompt()` contains the plan.md format documentation
- All tests use mock deps (no real LLM calls)

**Estimated size**: ~200 lines module, ~250 lines tests.

---

## Step 3 — `src/agent.lua` (State machine)

**What it is**: The core orchestration loop. Takes a prompt, drives it through the status machine using planner, cmd_plan, skill_runner, and approval.

This is the biggest module. Build it **one handler at a time**, testing each in isolation before wiring them together.

### Step 3a — Skeleton + `handle_pending` + `handle_planning`

**Functions**:

```lua
local agent = require("agent")

-- Main entry point. Creates task, runs the loop.
-- Returns the completed task table.
agent.run(deps, prompt, opts)
-- opts (optional):
--   max_steps = 20      -- safety: abort after N transitions
--   context_files = {}  -- passed through to planner

-- Resume a paused task (loaded from state).
agent.resume(deps, opts)

-- The main loop (internal, but testable).
-- Dispatches task.status to the appropriate handler.
agent.step(deps, t)
-- Returns t (mutated) or nil, error_string.
-- One call = one status transition.
```

**Handler: `handle_pending(deps, t)`**:
- Transitions to PLANNING
- That's it. This is just the entry point.

**Handler: `handle_planning(deps, t)`**:
- Calls `planner.generate(deps, t.prompt, { context_files = t.context_files })`
- On success: sets `t.plan_path` and `t.plan_text`, transitions to EXECUTING
- On failure + retries left: bumps attempt, transitions to REPLANNING
- On failure + no retries: transitions to FAILED with error

**What to test (3a)**:
- `step()` on a PENDING task transitions to PLANNING
- `step()` on a PLANNING task calls planner.generate
- On planner success: status becomes EXECUTING, plan_path is set
- On planner failure (retries left): status becomes REPLANNING
- On planner failure (no retries): status becomes FAILED
- `run()` with a planner that succeeds gets past PLANNING

**Deps table** (full, for all of agent.lua):

```lua
{
  task         = task,          -- task.lua (Step 1)
  planner      = planner,       -- planner.lua (Step 2)
  cmd_plan     = cmd_plan,      -- existing
  plan         = plan,          -- existing
  skill_loader = skill_loader,  -- existing
  skill_runner = skill_runner,  -- existing
  approval     = approval,      -- existing
  state        = state,         -- existing
  config       = config,        -- existing
  luallm       = luallm,        -- existing
  safe_fs      = safe_fs,       -- existing
  print        = print,         -- for status messages
}
```

### Step 3b — `handle_executing`

**Handler: `handle_executing(deps, t)`**:
- Builds the deps that `cmd_plan.run()` expects from the agent's deps
- Calls `cmd_plan.run({ subcommand = "run", plan_path = t.plan_path }, plan_deps)`
- On success: collects `t.outputs` from the plan's declared outputs
- Scans outputs for @skill metadata via `skill_loader.parse_metadata()`
  - If skills found: sets `t.skill_files`, transitions to TESTING
  - If no skills found: transitions to COMPLETE (just a code generation task)
- On cmd_plan failure + retries left: transitions to REPLANNING
- On cmd_plan failure + no retries: transitions to FAILED

**What to test (3b)**:
- Successful plan execution with no skills → COMPLETE
- Successful plan execution with skills → TESTING, skill_files populated
- Plan execution failure with retries → REPLANNING
- Plan execution failure without retries → FAILED
- skill_loader.parse_metadata called for each output file

### Step 3c — `handle_testing`

**Handler: `handle_testing(deps, t)`**:
- For each skill in `t.skill_files`:
  - Derive test file path (convention: `foo.lua` → `foo.test.lua`)
  - Call `skill_runner.run_tests(test_path, timeout)`
- Collect results into `t.test_results`
- If all pass: transitions to APPROVAL
- If any fail + retries left: transitions to REPLANNING (with test output as error context)
- If any fail + no retries: transitions to FAILED

**What to test (3c)**:
- All tests pass → APPROVAL
- Test failure with retries → REPLANNING, error includes test output
- Test failure without retries → FAILED
- Missing test file handled gracefully (either skip or fail)
- Multiple skills: one pass + one fail → REPLANNING

### Step 3d — `handle_approval`

**Handler: `handle_approval(deps, t)`**:
- For each skill in `t.skill_files`:
  - Call `approval.create(skill_name, skill_path, test_path, test_results, metadata, approvals_dir)`
  - Store `approval_id` on the task
- Save state (task is now paused)
- Print the promotion commands via `approval.get_promotion_commands()`
- Print instructions: "Run the commands above, then: `./agent resume`"
- Return the task (caller exits; task is persisted)

**What to test (3d)**:
- approval.create called with correct args for each skill
- Task gets approval_id set
- State is saved
- Promotion commands are printed

### Step 3e — `handle_replanning`

**Handler: `handle_replanning(deps, t)`**:
- Bumps replan attempt counter
- Builds error_info from `t.error`, `t.test_results`, `t.plan_text`
- Calls `planner.replan(deps, t, error_info)`
- On success: sets new `t.plan_path` and `t.plan_text`, transitions to PLANNING
  (yes, back to PLANNING — the loop will re-enter handle_planning which transitions to EXECUTING)

  Actually — replan produces a new plan.md. The next step should be EXECUTING that new plan, not PLANNING again. Let me correct:

- On success: sets new `t.plan_path` and `t.plan_text`, transitions to EXECUTING
- On failure: transitions to FAILED

Wait — looking at the transition table: REPLANNING → PLANNING. This is because after replanning, we might want to validate the new plan before executing. But planner.replan already validates it. Let me keep it simple:

- On success: transitions to PLANNING (which will immediately succeed and transition to EXECUTING since the plan is already generated and validated)

Actually that's wasteful. Let's adjust the transition table:

```
REPLANNING  → EXECUTING, FAILED
```

- On success: sets new plan_path, transitions to EXECUTING
- On failure: transitions to FAILED

**What to test (3e)**:
- replan success → EXECUTING with new plan_path
- replan failure → FAILED
- error_info correctly includes test output and previous plan text
- Attempt counter incremented

### Step 3f — `handle_resume` (for APPROVAL state)

**Handler logic in `agent.resume(deps)`**:
- Load task from state
- If status is APPROVAL:
  - For each approval_id, check `approval.check_promotion(skill_name, allowed_dir)`
  - If all promoted: transition to COMPLETE
  - If not all promoted: call `approval.prompt_human()` for each un-promoted record
    - If human says Y: print promotion commands again, re-check
    - If human says N: transition to FAILED
- If status is any other paused state: print current status and what to do

**What to test (3f)**:
- Resume with all skills promoted → COMPLETE
- Resume with skills not promoted → prompt_human called
- Resume with no saved task → error message

### Step 3g — `run()` main loop

Wire all handlers together:

```lua
function agent.run(deps, prompt, opts)
  opts = opts or {}
  local max_steps = opts.max_steps or 20
  local t = deps.task.new(prompt)
  t.context_files = opts.context_files

  for step = 1, max_steps do
    local ok, err = agent.step(deps, t)
    if not ok then
      t.error = err
      deps.task.transition(t, deps.task.FAILED, err)
    end

    deps.state.save(t)

    if deps.task.is_terminal(t) then
      return t
    end

    if deps.task.is_paused(t) then
      return t  -- caller should exit; resume later
    end
  end

  t.error = "max steps exceeded (" .. max_steps .. ")"
  deps.task.transition(t, deps.task.FAILED, t.error)
  deps.state.save(t)
  return t
end
```

**What to test (3g)**:
- Happy path: PENDING → PLANNING → EXECUTING → COMPLETE (no skills)
- Happy path with skills: → EXECUTING → TESTING → APPROVAL (paused)
- Failure + replan: → EXECUTING → REPLANNING → EXECUTING → COMPLETE
- Max steps exceeded → FAILED
- Each transition calls state.save

**Estimated size**: ~350-400 lines module, ~500 lines tests (across 3a-3g).

---

## Step 4 — `src/cmd_agent.lua` (CLI command)

**What it is**: Thin CLI wrapper, same pattern as `cmd_quick.lua` / `cmd_plan.lua`.

**Public API**:

```lua
local cmd_agent = require("cmd_agent")

-- Start a new task from a prompt.
cmd_agent.run(deps, args)
-- args = { prompt = "...", context = {...} }

-- Resume a paused task.
cmd_agent.resume(deps)

-- Clear saved task state.
cmd_agent.reset(deps)

-- Show current task status.
cmd_agent.status(deps)
```

**What it does**:
- `run`: Creates agent deps, calls `agent.run()`, prints result
- `resume`: Loads state, calls `agent.resume()`, prints result
- `reset`: Calls `state.clear()`, confirms
- `status`: Loads state, prints task status + history

**Test file**: `src/cmd_agent.test.lua`

**What to test**:
- `run` calls `agent.run` with correct deps
- `resume` calls `agent.resume`
- `reset` calls `state.clear`
- Error handling for missing state on resume

**Estimated size**: ~100 lines module, ~150 lines tests.

---

## Step 5 — Wire into `main.lua`

Add to the COMMANDS table:

```lua
{
  name  = "agent",
  usage = "<run|resume|reset|status> [prompt]",
  desc  = "Run the autonomous agent loop.",
  fn    = run_agent,
  setup = function(parser)
    parser:argument("subcommand", "Subcommand: run, resume, reset, status.")
    parser:argument("prompt", "What to do (for 'run')."):args("?")
    parser:option("--context", "Context files"):args("*")
  end,
}
```

No separate test file needed — this is just dispatch wiring.

---

## Build Order

```
Step 1: task.lua          ← no deps, build+test first
         │
Step 2: planner.lua       ← needs: luallm, config, plan, safe_fs (all existing)
         │
Step 3a: agent skeleton   ← needs: task, planner
Step 3b: handle_executing ← needs: + cmd_plan, skill_loader
Step 3c: handle_testing   ← needs: + skill_runner
Step 3d: handle_approval  ← needs: + approval, state
Step 3e: handle_replanning← needs: + planner (already have)
Step 3f: handle_resume    ← needs: + approval, state
Step 3g: run() loop       ← wires everything
         │
Step 4: cmd_agent.lua     ← needs: agent
Step 5: main.lua wiring   ← needs: cmd_agent
```

Each step has its own tests that pass before moving to the next. The agent.lua file grows across steps 3a–3g but each step adds one handler + its tests.

---

## Mock Strategy

Extend `src/test/mocks.lua` with:

```lua
-- Build a fake planner for agent tests.
function M.make_planner(overrides)
  overrides = overrides or {}
  return {
    generate = overrides.generate or function(deps, prompt, opts)
      return "/tmp/test_plan.md", M.make_plan()
    end,
    replan = overrides.replan or function(deps, task, error_info)
      return "/tmp/replan.md", M.make_plan()
    end,
    system_prompt = function() return "test system prompt" end,
  }
end

-- Build a fake skill_loader that reports whether files have @skill metadata.
function M.make_skill_loader(skill_files)
  skill_files = skill_files or {}
  local skill_set = {}
  for _, f in ipairs(skill_files) do skill_set[f] = true end
  return {
    parse_metadata = function(path)
      if skill_set[path] then
        return { name = path:match("([^/]+)%.lua$"), version = "1.0",
                 public_functions = { "run" } }
      end
      return nil, "no @skill metadata"
    end,
    list = function() return {} end,
    load = function() return nil, "not found" end,
  }
end

-- Build a fake skill_runner for agent tests.
function M.make_skill_runner(overrides)
  overrides = overrides or {}
  return {
    run_tests = overrides.run_tests or function(path, timeout)
      return { exit_code = 0, output = "", passed = true, timed_out = false }
    end,
    execute = function() return nil, "not implemented in test" end,
    validate_skill = function() return true end,
  }
end

-- Build a fake state module (in-memory, no disk).
function M.make_state()
  local saved = nil
  return {
    init    = function() return true end,
    save    = function(t) saved = t; return true end,
    load    = function() return saved end,
    clear   = function() saved = nil; return true end,
    exists  = function() return saved ~= nil end,
    dir     = function() return "/tmp/fake_state" end,
    _saved  = function() return saved end,  -- test introspection
  }
end
```

This lets every Step 3 sub-step mock exactly the deps it needs without touching the filesystem or calling an LLM.

---

## Plan File Generation

For Step 2 (planner.lua), the plan.md files the LLM generates will look like:

```markdown
## plan
model: GLM-4.5-Air-Q4_1
sanitize_fences: true
context: src/config.lua
context: src/sandbox.lua
output: src/skills/agent/read_csv.lua
output: src/skills/agent/read_csv.test.lua

## system prompt
You are a Lua code generator. Output ONLY valid Lua code.

## prompt
Create a skill called read_csv that parses a CSV file into a list of
row tables with headers as keys. Include a test file.
```

The planner's system prompt teaches the LLM this format. The agent never constructs plan.md manually — it always goes through the LLM.

---

## Revised Transition Table

```
PENDING     → PLANNING
PLANNING    → EXECUTING, REPLANNING, FAILED
EXECUTING   → TESTING, COMPLETE, REPLANNING, FAILED
TESTING     → APPROVAL, REPLANNING, FAILED
APPROVAL    → COMPLETE, FAILED
REPLANNING  → EXECUTING, FAILED
```

Note: PLANNING can go to REPLANNING if the LLM-generated plan fails validation. This avoids a separate "plan validation" state.

---

## Estimated Effort

| Step | Module | Est. Lines | Est. Test Lines | Notes |
|------|--------|-----------|----------------|-------|
| 1 | task.lua | 120 | 200 | Pure logic, fast |
| 2 | planner.lua | 200 | 250 | System prompt is the hard part |
| 3a-g | agent.lua | 350-400 | 500 | Build incrementally |
| 4 | cmd_agent.lua | 100 | 150 | Thin wrapper |
| 5 | main.lua | +30 | — | Wiring only |
| — | test/mocks.lua | +60 | — | Mock additions |
| **Total** | | **~900** | **~1100** | |

Budget ~30 min per sub-step for generate + review + test. Total: ~5-7 hours.

---

## Generating Each Step

Use the existing `plan` command to generate each module:

```bash
# Step 1
./agent plan new plans/task.md
# edit plans/task.md with the Step 1 spec above
./agent plan run plans/task.md

# Step 2
./agent plan new plans/planner.md
# edit with Step 2 spec, context: src/plan.lua, src/cmd_plan.lua, src/luallm.lua
./agent plan run plans/planner.md

# Step 3a
./agent plan new plans/agent_skeleton.md
# context: src/task.lua, src/planner.lua, src/state.lua
./agent plan run plans/agent_skeleton.md
# ... and so on for 3b-3g, adding context files as deps grow
```

Each plan.md should include in its context list every module the generated code needs to call. The LLM sees the real APIs and produces code that matches.
