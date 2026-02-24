# 🏗️ `luallm-agent` Self-Build Plan (Revised)
*Updated to reflect current progress*

---

## Current State

Phase 0 is effectively **complete**. The project has:

```
src/
├── main.lua          # CLI entry: help, test, doctor, quick-prompt
├── config.lua        # Load, validate, merge, path checking
├── doctor.lua        # Validates config + luallm binary
└── luallm.lua        # luallm CLI wrapper (state, completions)
```

Working capabilities:
- ✅ `main.lua help` — prints usage
- ✅ `main.lua test` — runs test suites
- ✅ `main.lua doctor` — validates config + luallm
- ✅ `main.lua quick-prompt "..."` — sends prompt to running model, prints response

This means the agent can already call an LLM and get structured output. The bootstrap threshold is crossed.

---

## Strategy (Updated)

Since `quick-prompt` works, the fastest path to self-build is:

1. **Phase 1A — Structured Generation**: Extend `quick-prompt` into a `generate` command that writes LLM output to files. This is the bridge between "agent can talk to an LLM" and "agent can build its own modules."
2. **Phase 1B — Agent-Built Modules**: Use `generate` to have the LLM produce each remaining module, with human review.
3. **Phase 2 — Full Agent Loop**: Wire the modules into the orchestrator. The agent can now plan, draft skills, test them, and request approval.
4. **Phase 3 — Self-Harden**: Use the full agent to generate sample skills, its own test suite, and documentation.

---

## Phase 1A — Structured Generation

Goal: A `generate` command that sends a system prompt + user prompt to the LLM and writes the response to a file. This is the tool the agent uses to build itself.

### ✅ Step 1A.1 — `generate` command (done)

Add to `main.lua`:

```
lua main.lua generate <output_path> "prompt"
```

Behavior:
1. Read the target output path from args
2. Send to LLM with a system prompt: `"You are a Lua code generator. Output ONLY valid Lua code. No markdown fences, no explanations, no commentary. Start with the first line of code."`
3. Write the response content to `<output_path>`
4. Print: file path, model used, token count


### ✅ Step 1A.2 — `generate-with-context` command (Done)

```
lua main.lua generate-with-context <output_path> <context_file1> [context_file2 ...] "prompt"
```

Same as `generate`, but reads the context files and prepends them to the prompt:

```
Here are existing source files for reference:

--- src/config.lua ---
<contents>

--- src/luallm.lua ---
<contents>

Now, using these as reference for style, conventions, and available APIs:
<user prompt>
```

This is critical because every Phase 1B module needs to call into existing modules. The LLM needs to see the real interfaces, not hallucinate them.

**Estimated effort**: ~50 lines total for both commands. Human-written — this is still bootstrapping infrastructure.

---

## ✅ Phase 1B — Agent-Built Modules (working)

Each step uses `generate-with-context` to produce a module. The human reviews and installs.

Workflow per step:

```bash
# 1. Generate the module
lua main.lua generate-with-context src/<target>.lua src/config.lua src/luallm.lua "prompt..."

# 2. Review the output
cat src/<target>.lua

# 3. Generate tests
lua main.lua generate-with-context src/<target>_test.lua src/<target>.lua "Write tests for..."

# 4. Run tests
lua main.lua test

# 5. Fix issues (manual or re-generate with feedback)
```

### Step 1B.1 — Audit logger (`src/audit.lua`)

**Context files**: `src/config.lua`

**Prompt**:
```
Write a Lua module audit.lua that implements an append-only JSONL logger.

Requirements:
- Uses cjson (require "cjson.safe") for encoding
- audit.init(path) — set log file path, create file if missing
- audit.log(event, data) — append one JSON line: {"ts": ISO8601, "event": event, "task_id": current_task_id, "data": data}
- audit.set_task_id(id) — set current task context
- audit.rotate(max_size_mb, max_files) — rotate if file exceeds size. Rename current to .1, shift .1→.2, etc. Delete oldest beyond max_files.
- All writes flush immediately (f:flush() after every line)
- Never reads the log file during normal operation
- Use lfs (require "lfs") for file size checks

Follow the same module style as the context files: local M = {} at top, return M at bottom.
```

### Step 1B.2 — UUID utility (`src/uuid.lua`)

**Context files**: none (or skip entirely if using luarocks `uuid`)

If the luarocks `uuid` module works for your needs, skip this step and just `require("uuid")` where needed. If it has quirks or you want a simpler wrapper:

**Prompt**:
```
Write a tiny Lua module uuid.lua that wraps the luarocks uuid library.

- local uuid_lib = require("uuid")
- M.generate() — returns a new UUID v4 string
- That's it. Keep it minimal.
```

### Step 1B.3 — State manager (`src/state.lua`)

**Context files**: `src/config.lua`

**Prompt**:
```
Write a Lua module state.lua for persisting agent task state.

Requirements:
- Uses cjson.safe for encoding/decoding
- Uses lfs for file operations
- state.init(dir) — set state directory path (e.g. from config), ensure it exists
- state.save(task) — write task table as JSON to current_task.json. Use atomic writes: write to .tmp file first, then os.rename() over the real file.
- state.load() — read and parse current_task.json. Return the task table or nil if no file exists. If file exists but is invalid JSON, return nil, "corrupt".
- state.clear() — remove current_task.json (and .tmp if present)
- state.exists() — return true if current_task.json exists

Follow the same module style as the context files.
```

### Step 1B.4 — Test framework (`src/test_framework.lua`)

**Context files**: `src/config_test.lua` (as an example of the inline harness being used now)

**Prompt**:
```
Write a Lua test framework module test_framework.lua that replaces the inline test harness currently copy-pasted into test files.

Requirements:
- local T = require("test_framework")
- T.case(name, fn) — register a test case
- T.eq(got, expected, label?) — assert equality. On failure, show both values.
- T.neq(got, unexpected, label?) — assert inequality
- T.truthy(val, label?) — assert val is truthy
- T.falsy(val, label?) — assert val is falsy
- T.errors(fn, label?) — assert fn() throws an error. Optionally match error message pattern.
- T.matches(str, pattern, label?) — assert string matches Lua pattern
- T.run_all() — run all registered cases, print results, output JSON summary to stdout, exit with code 0 (all pass) / 1 (any fail) / 2 (framework error)
- Each test runs in pcall so one failure doesn't stop others
- Print ✅ / ❌ per test with name and error message
- Reset registered cases after run_all() so module can be reused in a single process
- JSON output format: {"total": N, "passed": N, "failed": N, "results": [{"name": "...", "status": "pass"|"fail", "error": "...", "duration_ms": N}]}
- Use os.clock() for duration_ms

Follow the same module style as context files. Use cjson.safe for JSON output.
```

After this step, refactor existing test files to use `require("test_framework")` instead of the inline harness.

### Step 1B.5 — Task graph engine (`src/graph.lua`)

**Context files**: `src/config.lua`, `src/state.lua`

**Prompt**:
```
Write a Lua module graph.lua — a task graph (DAG) engine for planning multi-step tasks.

A task graph is a table with this shape:
{
  nodes = {
    { id = "1", action = "skill", skill_name = "read_csv", skill_args = {path="..."}, depends_on = {}, status = "pending", retries = 0, max_retries = 3, result = nil },
    { id = "2", action = "llm_call", prompt_template = "Summarize: {1}", depends_on = {"1"}, status = "pending", retries = 0, max_retries = 3, result = nil },
    { id = "3", action = "decision", condition = "length > 1000", if_true = "4", if_false = "5", depends_on = {"2"}, status = "pending", retries = 0, max_retries = 3, result = nil },
  },
  metadata = { prompt = "...", created_at = "...", model = "..." }
}

Requirements:
- graph.validate(g) — check: all node IDs unique, all depends_on reference valid IDs, no cycles. Return true or false + list of error strings.
- graph.topological_sort(g) — return ordered list of node IDs, or nil + "cycle detected"
- graph.get_ready_nodes(g) — return nodes where status=="pending" and all depends_on nodes have status=="complete"
- graph.is_complete(g) — true if every node is "complete" or "skipped"
- graph.mark_downstream_skipped(g, failed_node_id) — find all nodes that transitively depend on failed_node_id, set their status to "skipped"
- graph.from_json(json_string) — parse JSON, validate, return graph table or nil + errors
- All functions are pure: no I/O, no side effects, no requires beyond cjson.safe

Use cjson.safe for JSON parsing. Follow the same module style as context files.
```

### Step 1B.6 — Sandbox (`src/sandbox.lua`)

**Context files**: `src/config.lua`, `src/audit.lua`

**Prompt**:
```
Write a Lua module sandbox.lua that executes untrusted Lua code in a restricted environment.

Requirements:
- sandbox.make_env(opts) — build a restricted _ENV table. opts contains:
  - paths: list of allowed file path patterns
  - allowed_paths: global allowed paths from config
  - dependencies: table of allowed module names
  - allowed_dir: directory to load dependencies from
  - log_fn: function(event, data) for audit logging
  - skill_name: string for log context

  Whitelisted globals: math, string, table, pairs, ipairs, next, select, type, tostring, tonumber, pcall, xpcall, error, assert, unpack (or table.unpack)
  Also include: a wrapped io table (see below), a wrapped require, a captured print, and the log_fn as "log"

  Blocked (must NOT be in env): os, io (raw), debug, load, loadstring, loadfile, dofile, rawget, rawset, rawequal, collectgarbage, require (raw), setfenv, getfenv

- sandbox.make_io(declared_paths, allowed_paths, log_fn, skill_name) — return a table with:
  - open(path, mode) — resolve to absolute, check path is in both declared_paths AND allowed_paths, log the access, return io.open handle. Error if path not allowed. Track open handles, error if >10 simultaneous.
  - lines(path) — same checks, return io.lines
  - close(handle) — close and decrement handle count

- sandbox.make_require(declared_deps, allowed_dir) — return a function that:
  - Errors if modname not in declared_deps
  - Loads from allowed_dir/modname.lua only
  - Runs the loaded chunk in its own restricted env (recursive sandbox)

- sandbox.execute(code_string, env, timeout_seconds) — load code string with env as its environment, run it with a debug.sethook instruction-count limit for CPU timeout (calibrate ~1M instructions/sec), return result or nil + error

Use lfs for path resolution. Follow the same module style as context files.
```

### Step 1B.7 — Skill loader (`src/skill_loader.lua`)

**Context files**: `src/config.lua`, `src/sandbox.lua`

**Prompt**:
```
Write a Lua module skill_loader.lua that loads skill files and parses their metadata headers.

Skill files have a metadata block at the top:
---@skill {
---  name = "read_csv",
---  version = "1.0",
---  description = "Parse a CSV file into a table of rows",
---  dependencies = {},
---  paths = { "~/data/*" },
---  urls = {},
---  public_functions = { "run", "parse_args" },
---}

Requirements:
- skill_loader.parse_metadata(file_path) — read file, extract the @skill block (lines starting with ---), strip the --- prefix, concatenate, parse as a Lua table (use load("return " .. text) in a safe env). Return metadata table or nil + error. Required fields: name, version, public_functions.
- skill_loader.load(skill_name, search_dirs) — search for skill_name.lua in each dir in order, parse metadata, read full file contents. Return { metadata = ..., code = ..., path = ... } or nil + error.
- skill_loader.resolve_dependencies(metadata, allowed_dir) — verify all entries in metadata.dependencies exist as .lua files in allowed_dir, detect circular deps via DFS. Return ordered load list or nil + error.
- skill_loader.list(dir) — scan dir for .lua files (excluding *_test.lua), parse metadata from each, return list of { name, version, description, path }.

Use lfs for directory scanning. Use cjson.safe only if needed. Follow same module style as context files.
```

### Step 1B.8 — Skill runner (`src/skill_runner.lua`)

**Context files**: `src/sandbox.lua`, `src/skill_loader.lua`, `src/audit.lua`, `src/config.lua`

**Prompt**:
```
Write a Lua module skill_runner.lua that executes skills inside the sandbox and runs test suites.

Requirements:
- skill_runner.execute(skill_name, args, search_dirs) — load skill via skill_loader, build sandbox env via sandbox.make_env using the skill's metadata, load the skill code in the sandbox, call its run(args) function, return the result or nil + error. Log execution via audit.log.
- skill_runner.run_tests(test_file_path, timeout_seconds) — execute a test file as a subprocess: os.execute("lua " .. test_file_path). Capture stdout (the JSON test results). Parse and return the structured results. Timeout via the provided seconds value.
- skill_runner.validate_skill(skill_path, config) — load the skill, parse metadata, verify all public_functions exist in the returned module table, verify all declared paths are within config.allowed_paths. Return true or false + list of error strings.

Follow same module style as context files.
```

### Step 1B.9 — Approval manager (`src/approval.lua`)

**Context files**: `src/config.lua`, `src/audit.lua`, `src/state.lua`

**Prompt**:
```
Write a Lua module approval.lua that manages the skill approval workflow.

Requirements:
- Uses cjson.safe, lfs, and uuid (require "uuid" from luarocks)
- approval.create(skill_name, skill_path, test_path, test_results, metadata) — create a pending approval JSON file at state/pending_approvals/skill_<n>_<uuid>.json. Return the approval record table.
- approval.list_pending(approvals_dir) — scan directory, parse each JSON file, return list of approval records
- approval.get(approvals_dir, approval_id) — load a specific approval by ID
- approval.resolve(approvals_dir, approval_id, approved) — set approved=true/false, write back, log via audit
- approval.check_promotion(skill_name, allowed_dir, approval_record) — check if skill_name.lua now exists in allowed_dir, return true if found
- approval.prompt_human(record) — print formatted approval display:
  - Show skill name + version
  - Show file paths
  - Show test results (✅/❌ per test)
  - Show declared paths and dependencies
  - Show options: [V]iew code  [R]erun tests  [E]dit  [Y]es (promote)  [N]o (reject)
  - Read single character input, return the action string
- approval.get_promotion_commands(record, allowed_dir) — return list of strings: the exact cp + chmod commands the human should run
- approval.check_tier(tier_name) — delegate to config.approval_tier(tier_name)

Follow same module style as context files.
```

### Step 1B.10 — Full orchestrator (`src/agent.lua`)

**Context files**: ALL `src/*.lua` modules (pass them all as context)

**Prompt**:
```
Write a Lua module agent.lua — the full state machine orchestrator for luallm-agent.

Available modules (already implemented):
- config — config.load(), config.get(), config.is_path_allowed(), config.model_policy(), config.approval_tier()
- luallm — luallm.state(), luallm.complete(), luallm.start(), luallm.stop(), luallm.notes(), luallm.help(), luallm.wait_for_ready()
- state — state.save(task), state.load(), state.clear(), state.exists()
- audit — audit.init(), audit.log(), audit.set_task_id(), audit.rotate()
- graph — graph.validate(), graph.get_ready_nodes(), graph.is_complete(), graph.from_json(), graph.mark_downstream_skipped()
- sandbox — sandbox.make_env(), sandbox.execute()
- skill_loader — skill_loader.load(), skill_loader.list(), skill_loader.parse_metadata()
- skill_runner — skill_runner.execute(), skill_runner.run_tests(), skill_runner.validate_skill()
- approval — approval.create(), approval.prompt_human(), approval.check_promotion(), approval.get_promotion_commands()
- llm_client logic is in luallm.lua (use luallm.complete for LLM calls)
- uuid from luarocks (require "uuid")

Task statuses:
PENDING → PLANNING → GRAPH_EXEC → COMPLETE/FAILED
With sub-loops: SKILL_DRAFT → SKILL_TEST → APPROVAL → REWORK (back to SKILL_DRAFT)
And: MODEL_WAIT (when a model needs starting)

Requirements:
- agent.run(prompt) — main loop:
  1. Create task table with id, prompt, status="pending", step_count=0
  2. Loop while not complete/failed:
     a. Increment step_count, check against config.limits.max_task_steps
     b. Dispatch based on status to the appropriate handler
     c. Save state after every transition
     d. Audit log every transition
  3. Return task

- agent.plan(task) — set status to "planning", build the LLM system prompt including:
  - List of available skills (from skill_loader.list on the allowed dir)
  - Running models (from luallm.state())
  - The graph schema definition
  - A few-shot example of a valid graph

- agent.generate_graph(task) — call LLM with the planning prompt, parse response as JSON graph, validate with graph.validate(). On success set status="graph_exec". On failure retry up to config.limits.max_plan_retries.

- agent.execute_graph(task) — get next ready node, execute it:
  - action "skill" → skill_runner.execute()
  - action "llm_call" → luallm.complete(), interpolating {node_id} references in prompt_template
  - action "decision" → evaluate condition against prior results
  If skill not found → set status="skill_draft"
  If all nodes complete → set status="complete"

- agent.draft_skill(task) — use LLM to generate skill .lua + _test.lua, write to skills/agent/

- agent.test_skill(task) — run tests via skill_runner.run_tests(). If pass → status="approval". If fail → status="rework" (up to max_skill_retries).

- agent.rework_skill(task) — send failing test output to LLM for revision, re-draft, re-test.

- agent.pause_for_approval(task) — create approval record, set task.paused=true, return (caller exits).

- agent.pause_for_model(task) — print which model to start and how, set task.paused=true, return.

- agent.resume(task) — called by --resume. Check status:
  - APPROVAL → check if skill was promoted, run approval.prompt_human if still pending
  - MODEL_WAIT → check luallm.state(), resume if model running

Follow same module style as context files.
```

### Step 1B.11 — CLI update (`src/main.lua`)

**Context files**: `src/main.lua` (current), `src/agent.lua`

**Prompt**:
```
Extend the existing main.lua to add these commands alongside the existing help, test, doctor, and quick-prompt:

- lua main.lua run "prompt" — call agent.run(prompt), print task status on completion
- lua main.lua run "prompt" --yes — same but set a flag that auto-approves task confirmation tier
- lua main.lua resume — call state.load(), then agent.resume(task). Print status.
- lua main.lua reset — call state.clear(), print confirmation
- lua main.lua log --tail N — read the last N lines of the audit log JSONL file, pretty-print each
- lua main.lua log --task TASK_ID — filter audit log lines by task_id field
- lua main.lua skills list — call skill_loader.list() on the allowed skills dir, print table
- lua main.lua skills test NAME — call skill_runner.run_tests() on the named skill's test file

Keep existing commands working. Keep the arg parsing simple (no external deps).

Here is the current main.lua for reference: <current code will be provided as context file>
```

---

## Phase 2 — Full Agent Loop

At this point `lua main.lua run "..."` works end-to-end. The agent can plan tasks, draft skills, test them, and request approval.

### Step 2.1 — Sample skills

Run each through the full agent flow:

```bash
lua main.lua run "Create a skill called read_file that reads a text file and returns its contents as a string. Args: {path=string}."

lua main.lua run "Create a skill called write_file that writes a string to a file path. Args: {path=string, content=string, overwrite=boolean}. Refuse to overwrite unless overwrite=true."

lua main.lua run "Create a skill called read_csv that parses a CSV file into a list of row tables with headers as keys. Args: {path=string, has_header=boolean}."

lua main.lua run "Create a skill called write_markdown that takes {title=string, sections={{heading=string, body=string},...}, output_path=string} and writes a formatted markdown file."

lua main.lua run "Create a skill called shell_safe that runs a shell command from a whitelist: ls, wc, head, tail, grep, find, cat, sort, uniq. Args: {command=string, args={string,...}}. Reject any command not in the whitelist."
```

Each one will go through: plan → graph → skill_draft → test → approval → human promotes → resume.

### Step 2.2 — Self-test suite

```bash
lua main.lua run "Look at every .lua file in src/. For each module that doesn't have a corresponding _test.lua file, generate tests using the test_framework module. Write each test file to src/."
```

### Step 2.3 — Documentation

```bash
lua main.lua run "Read all .lua files in src/. Generate a REFERENCE.md with: module-by-module API docs, function signatures with parameter descriptions, return values, and a dependency graph."
```

---

## Phase 3 — Self-Harden

The agent uses itself to improve itself:

### Step 3.1 — Error recovery improvements
```bash
lua main.lua run "Review src/agent.lua. Add better error messages for every failure path. When a step fails, the error message should tell the human exactly what happened, what the agent tried, and what the human can do to fix it."
```

### Step 3.2 — Prompt templates
```bash
lua main.lua run "Create a src/prompts.lua module that centralizes all LLM prompt templates used by agent.lua: the planning system prompt, skill generation prompt, graph schema definition, rework prompt. Each should be a function that takes context and returns the formatted prompt string."
```

### Step 3.3 — Performance tracking
```bash
lua main.lua run "Add timing instrumentation to agent.lua. Log the wall-clock duration of every LLM call, skill execution, and test run in the audit log. Add a 'lua main.lua stats' command that reads the audit log and prints: average LLM latency per model, total tokens used, skill generation success rate, average retries per skill."
```

---

## Dependency Order (Phase 1B)

```
1B.1  Audit logger         ─── (needs config)
1B.2  UUID wrapper          ─── (no deps, or skip if using luarocks uuid directly)
1B.3  State manager         ─── (needs config)
1B.4  Test framework        ─── (no deps)
            │
            ▼
1B.5  Task graph engine     ─── (pure logic, no deps beyond cjson)
1B.6  Sandbox               ─── (needs config, audit)
1B.7  Skill loader          ─── (needs config)
            │
            ▼
1B.8  Skill runner          ─── (needs sandbox, skill_loader, audit, config)
1B.9  Approval manager      ─── (needs config, audit, state)
            │
            ▼
1B.10 Full orchestrator     ─── (needs ALL above)
1B.11 CLI update            ─── (needs orchestrator)
```

Parallelizable:
- **Group A** (no cross-deps): 1B.1, 1B.2, 1B.3, 1B.4, 1B.5
- **Group B** (needs Group A): 1B.6, 1B.7
- **Group C** (needs Group B): 1B.8, 1B.9
- **Group D** (needs all): 1B.10, 1B.11

---

## Critical Path

```
NOW (Phase 0 done)                PHASE 1A (~1hr)              PHASE 1B (~4-8hr)           PHASE 2-3
──────────────────               ───────────────              ──────────────────          ──────────
✅ config.lua                    1A.1 generate cmd            1B.1-5  (Group A)           Sample skills
✅ doctor.lua                    1A.2 generate-with-context   1B.6-7  (Group B)           Self-test
✅ luallm.lua                                                 1B.8-9  (Group C)           Docs + harden
✅ main.lua (help/test/                                       1B.10-11 (Group D)
   doctor/quick-prompt)                                              │
         │                              │                            ▼
         └──────────────────────────────┘                     "full agent loop works"
                         │
                  "agent can generate
                   its own source files"
```

## Next Immediate Steps

1. **Build `generate` and `generate-with-context` commands** (~50 lines, human-written)
2. **Generate `audit.lua` and `test_framework.lua`** (Group A, no cross-deps)
3. **Generate `state.lua` and `graph.lua`** (Group A, no cross-deps)
4. **Refactor existing tests to use `test_framework.lua`**
5. Continue down the dependency chain

The bottleneck remains human review. Budget ~20-30 minutes per module including generation, review, test, and integration.
