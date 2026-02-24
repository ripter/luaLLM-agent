# 🏗️ `luallm-agent` Self-Build Plan
*Minimum viable bootstrap → agent builds itself*

---

## Strategy

The fastest path to a self-building agent has three phases:

1. **Phase 0 — Human Bootstrap**: Hand-build the absolute minimum the agent needs to call an LLM and write files. No sandbox, no approval flow, no graph engine. Just: read config, talk to `luallm`, persist state, write output.
2. **Phase 1 — Agent Self-Build**: The running (minimal) agent generates its own remaining modules as skills, with human review at each step.
3. **Phase 2 — Agent Self-Harden**: The agent uses itself to build the safety and quality layers (sandbox, approvals, audit) that constrain it going forward.

The dividing line is clear: **the agent cannot build itself until it can call an LLM and write a file.** Everything before that line is human work. Everything after it is agent work with human approval.

---

## Phase 0 — Human Bootstrap

Goal: A working `luallm-agent run "..."` that can generate a single Lua file from a prompt and save it to disk. No tests, no sandbox, no approvals, no graph. Just the skeleton.

### Step 0.1 — Project scaffolding

Create the directory layout and empty files. ~5 minutes.

```
luallm-agent/
├── bin/
│   └── luallm-agent           # entry point (shell shim → lua cli/main.lua)
├── lib/
│   ├── json.lua               # vendor dkjson or equivalent
│   └── uuid.lua               # /dev/urandom UUID v4
├── agent/
│   ├── config.lua             # load + validate config.json
│   ├── luallm.lua             # luallm CLI wrapper
│   ├── state.lua              # atomic save/load current_task.json
│   ├── llm_client.lua         # model selection + completion
│   └── agent.lua              # minimal orchestrator
├── cli/
│   └── main.lua               # arg parsing, dispatch
└── test/
    └── ...                    # tests for each module
```

### Step 0.2 — `lib/json.lua`

Vendor `dkjson` (single file, MIT licensed, pure Lua). Copy it in. No code to write.

**Verify**: `lua -e "local j = require('lib.json'); print(j.encode({ok=true}))"` → `{"ok":true}`

### Step 0.3 — `lib/uuid.lua`

~30 lines. Read 16 bytes from `/dev/urandom`, format as UUID v4.

**Verify**: `lua -e "local u = require('lib.uuid'); print(u.generate())"` → prints a UUID

### ✅ Step 0.4 — `agent/config.lua` (Done)

Loads `~/.config/luallmagent/config.json`, expands `~` in paths, provides typed accessors. Hardcode a minimal default config if file is missing (for bootstrapping).

For now, only needs to supply:
- `config.luallm.binary` (default `"luallm"`)
- `config.model_selection` (default: `{ default = { prefer = {}, fallback = {} } }`)
- `config.limits.llm_timeout_seconds` (default `120`)

**Verify**: `lua -e "local c = require('agent.config'); c.load(); print(c.get('luallm.binary'))"` → `luallm`


### ✅ Step 0.5 — `agent/luallm.lua` (Done)

~80 lines. The `luallm` CLI wrapper. Only implement three functions for now:

1. `luallm.exec(...)` — runs `luallm <args> --json`, returns parsed JSON or error
2. `luallm.state()` — calls `luallm state --json`, returns model list
3. `luallm.complete(model_name, messages, options)` — finds port from state, sends HTTP POST to `127.0.0.1:<port>/v1/chat/completions`

HTTP: use `luasocket` if available, fall back to shelling out to `curl`.

**Verify**: With a model running, `lua -e "local l = require('agent.luallm'); print(require('lib.json').encode(l.state()))"` → shows running models.

### Step 0.6 — `agent/state.lua`

~40 lines. Atomic save/load of `current_task.json`.

- `state.save(task)` — write to `.tmp`, rename
- `state.load()` — read + parse, or nil if no file
- `state.clear()` — remove state file

**Verify**: Save a table, load it back, confirm round-trip.

### Step 0.7 — `agent/llm_client.lua`

~50 lines. Thin layer over `luallm.lua`.

- `llm_client.select_model(task_type)` — iterate config preference list, check `luallm.state()` for running models, return first running match
- `llm_client.complete(task_type, messages)` — select model, call `luallm.complete`, return response content

No retry, no backoff, no fallback yet. Just the happy path.

**Verify**: `lua -e "local l = require('agent.llm_client'); print(l.complete('default', {{role='user', content='say hello'}}))"` → prints model response.

### Step 0.8 — `agent/agent.lua` (minimal)

~70 lines. The simplest possible orchestrator:

```lua
function agent.run(prompt)
  local task = {
    id = uuid.generate(),
    prompt = prompt,
    status = "running",
    created_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
  }
  state.save(task)

  local messages = {
    { role = "system", content = "You are a Lua code generator. Output ONLY valid Lua code. No markdown fences." },
    { role = "user", content = prompt },
  }

  local response = llm_client.complete("default", messages)
  task.result = response
  task.status = "complete"
  state.save(task)
  return task
end
```

No state machine, no graph, no skills. Just: prompt → LLM → result.

### Step 0.9 — `cli/main.lua`

~40 lines. Arg parsing:

- `luallm-agent run "prompt"` → calls `agent.run(prompt)`, prints result
- `luallm-agent --reset` → calls `state.clear()`

### Step 0.10 — Smoke test

```bash
luallm start llama3-8b-q4
luallm-agent run "Write a Lua function that reverses a string"
```

If this prints working Lua code, **Phase 0 is complete**. The agent can talk to an LLM and produce output.

**Estimated total Phase 0 effort**: ~400 lines of Lua, 2-4 hours for a human.

---

## Phase 1 — Agent Self-Build

From here forward, the agent builds itself. Each step is an `luallm-agent run "..."` invocation that produces a module. The human reviews and installs each output before proceeding.

The workflow for every step is:

```bash
# 1. Agent generates the module
luallm-agent run "<prompt from step below>"

# 2. Human reviews the output
# 3. Human copies to correct location
cp output.lua agent/<target>.lua

# 4. Human writes or asks agent to generate a test
luallm-agent run "Write tests for agent/<target>.lua using this test format: ..."

# 5. Human runs tests
lua test/<target>_test.lua

# 6. Human integrates (updates require paths, wires into agent.lua)
```

> **Important**: During Phase 1, the agent is running WITHOUT a sandbox, approvals, or audit log. The human IS the sandbox. Review every output carefully before installing.

### Step 1.1 — Audit logger (`agent/audit.lua`)

**Prompt**:
```
Write a Lua module `audit.lua` that implements an append-only JSONL logger.

Requirements:
- audit.init(path) — set log file path
- audit.log(event, data) — append one JSON line: {"ts": ISO8601, "event": event, "task_id": current_task_id, "data": data}
- audit.set_task_id(id) — set current task context
- audit.rotate(max_size_mb, max_files) — rotate if file exceeds max_size_mb
- Uses lib/json.lua for encoding (require path: "lib.json")
- Never reads the log file, only appends
- All writes are flushed immediately (f:flush() after every line)
```

**After install**: Wire `audit.log()` calls into `agent.lua` and `llm_client.lua`.

### Step 1.2 — `luallm` wrapper enhancements (`agent/luallm.lua`)

**Prompt**:
```
Extend the existing agent/luallm.lua module with these additional functions.
Here is the current code: <paste current luallm.lua>

Add:
- luallm.help() — call `luallm help --json`, cache result in-memory for process lifetime
- luallm.notes(model_name?) — call `luallm notes --json` or `luallm notes <name> --json`
- luallm.start(model_name) — call `luallm start <name> --json`, return parsed result
- luallm.stop(model_name) — call `luallm stop <name> --json`, return parsed result
- luallm.wait_for_ready(model_name, timeout_seconds) — poll luallm.state() every 2s until model is running or timeout
- All functions use --json flag and return parsed JSON
- All functions return { ok=true, data=... } or { ok=false, error=..., exit_code=... }
```

### Step 1.3 — Enhanced LLM client with retry + fallback (`agent/llm_client.lua`)

**Prompt**:
```
Rewrite agent/llm_client.lua with retry logic and model fallback.
Here is the current code: <paste current llm_client.lua>
Here is agent/luallm.lua for reference: <paste luallm.lua>
Here is agent/audit.lua for reference: <paste audit.lua>

Requirements:
- llm_client.complete_with_retry(model_name, messages, options) — retry up to max_retries with exponential backoff (base 1s, max 60s). Check luallm.state() before each retry to detect model crash.
- llm_client.select_model(task_type) — read config.model_selection, cross-reference with luallm.state(), return first running preferred model, then fallbacks. Skip models if luallm.notes() flags them.
- llm_client.ensure_model_running(model_name) — if auto_start is true in config, call luallm.start() and wait_for_ready(). If false, return nil with "model_not_running" error.
- Audit log every LLM call, retry, model selection, and OOM event.
- On OOM detection, print a suggestion to the human about adding a luallm note.
```

### Step 1.4 — Test framework (`lib/luallm_test.lua`)

**Prompt**:
```
Write a minimal Lua test framework module lib/luallm_test.lua.

Requirements:
- test.case(name, fn) — register a test case
- test.eq(got, expected) — assert equality, error with diff on failure
- test.neq(got, expected) — assert inequality
- test.truthy(val) — assert val is truthy
- test.errors(fn) — assert fn() throws an error
- test.run_all() — run all registered cases, output structured JSON to stdout:
  { "total": N, "passed": N, "failed": N, "results": [{ "name": "...", "status": "pass"|"fail", "error": "...", "duration_ms": N }] }
- Exit code 0 if all pass, 1 if any fail, 2 if framework error
- Each test case runs in a pcall so one failure doesn't stop others
- Reset registered cases after run_all() so the module can be reused
```

### Step 1.5 — Config validator (`agent/config.lua` rewrite)

**Prompt**:
```
Rewrite agent/config.lua with full schema validation.
Here is the current minimal version: <paste config.lua>
Here is the full config schema from the plan: <paste §15 from plan>

Requirements:
- config.load(path?) — load config.json from path or default location, validate against schema
- config.validate(tbl) — return ok, errors where errors is a list of human-readable strings
- Validate: all required keys present, types correct, allowed_paths/blocked_paths are lists of strings,
  approvals.skill_promotion is always "manual" (override if not), limits are positive numbers,
  model_selection has at least a "default" entry
- config.get(dotted_path) — e.g. config.get("luallm.binary") traverses nested keys
- Expand ~ to $HOME in all path values
- If config file missing, generate a default and print its path
```

### Step 1.6 — Task graph engine (`agent/graph.lua`)

**Prompt**:
```
Write agent/graph.lua — a task graph (DAG) engine.

The graph schema (in Lua table form):
<paste §5.1 schema from plan>

Requirements:
- graph.validate(graph_table) — validate all node IDs are unique, depends_on references are valid, no cycles (topological sort), return ok, errors
- graph.get_ready_nodes(graph_table) — return nodes where status=="pending" and all depends_on nodes are status=="complete"
- graph.is_complete(graph_table) — true if all nodes are "complete" or "skipped"
- graph.mark_downstream_skipped(graph_table, failed_node_id) — mark all transitive dependents as "skipped"
- graph.topological_sort(graph_table) — return ordered list of node IDs or nil, "cycle detected"
- graph.from_json(json_string) — parse and validate, return graph or nil, errors
- All functions are pure (no side effects, no I/O)
```

### Step 1.7 — Sandbox (`agent/sandbox.lua`)

**Prompt**:
```
Write agent/sandbox.lua — a Lua sandbox for executing untrusted skill code.

Requirements:
- sandbox.make_env(skill_metadata) — return a restricted _ENV table per the spec below
- sandbox.execute(code_string, env, timeout_seconds) — load code with the restricted env, run it with a debug.sethook CPU limit, return result or error
- sandbox.make_io(declared_paths, allowed_paths) — return a table with .open(path, mode) and .lines(path) that enforce both declared_paths (from skill metadata) and allowed_paths (from config). Error on any path not in both lists. Log reads/writes via a provided log function.
- sandbox.make_require(declared_deps, allowed_dir) — return a require function that only loads from allowed_dir, only for modules listed in declared_deps, each in its own sandbox

Whitelisted globals: math, string, table, pairs, ipairs, next, select, type, tostring, tonumber, pcall, xpcall, error, assert, unpack/table.unpack, print (captured), log (provided)

Blocked (must NOT be in env): os, io (raw), debug, load, loadstring, loadfile, dofile, rawget, rawset, rawequal, collectgarbage, require (raw), setfenv, getfenv, setmetatable (except on tables created within the sandbox)

Resource limits via debug.sethook:
- CPU: instruction count limit derived from timeout_seconds (calibrate ~1M instructions/sec as baseline)
- Memory: poll collectgarbage("count") in the hook, kill if over limit
- Track open file handles, error if >10 simultaneous
```

### Step 1.8 — Skill loader (`agent/skill_loader.lua`)

**Prompt**:
```
Write agent/skill_loader.lua — loads skill files, parses metadata headers, resolves dependencies.

Skill metadata format (in a comment block at top of .lua files):
---@skill {
---  name = "read_csv",
---  version = "1.0",
---  description = "...",
---  dependencies = {},
---  paths = { "~/data/*" },
---  urls = {},
---  public_functions = { "run", "parse_args" },
---}

Requirements:
- skill_loader.parse_metadata(file_path) — read the file, extract and parse the @skill block, return metadata table or nil, error
- skill_loader.load(skill_name, search_dirs) — find skill_name.lua in search_dirs (ordered), parse metadata, return { metadata=..., code=file_contents, path=absolute_path }
- skill_loader.resolve_dependencies(skill_metadata, allowed_dir) — check all dependencies exist in allowed_dir, detect circular deps, return ordered load list or nil, error
- skill_loader.list(dir) — return list of {name, version, description, path} for all skills in a directory
- Metadata parsing should be strict: missing required fields (name, version, public_functions) → error
```

### Step 1.9 — Skill runner (`agent/skill_runner.lua`)

**Prompt**:
```
Write agent/skill_runner.lua — executes skills in the sandbox and runs test suites.

Dependencies: agent/sandbox.lua, agent/skill_loader.lua, agent/audit.lua, agent/config.lua

Requirements:
- skill_runner.execute(skill_name, args, search_dirs) — load skill via skill_loader, build sandbox env via sandbox.make_env using skill metadata, execute the skill's `run` function with args, return result or error. Audit log the execution.
- skill_runner.run_tests(test_file_path) — execute the test file, capture stdout (expecting JSON test results from luallm_test framework), return parsed test results. Timeout after config.limits.skill_exec_timeout_seconds.
- skill_runner.validate_skill(skill_path) — load metadata, check all public_functions exist in the returned module table, check paths are within config.allowed_paths, return ok, errors
```

### Step 1.10 — Approval manager (`agent/approval.lua`)

**Prompt**:
```
Write agent/approval.lua — manages the skill approval workflow.

Dependencies: lib/json.lua, lib/uuid.lua, agent/config.lua, agent/audit.lua

Requirements:
- approval.create(skill_name, skill_path, test_path, test_results) — create a pending approval JSON file in state/pending_approvals/, return approval record
- approval.list_pending() — return list of pending approval records
- approval.get(approval_id) — load a specific approval
- approval.resolve(approval_id, approved) — mark as approved/rejected, audit log
- approval.check_promotion(skill_name) — check if skill now exists in skills/allowed/, return true if found and version matches the approval record
- approval.prompt_human(approval_record) — print the formatted approval prompt (the CLI display from §7.4 of the plan), read user input, return chosen action: "view", "rerun", "edit", "fix", "yes", "no"
- approval.get_promotion_commands(approval_record) — return the exact cp/chmod commands as a list of strings

Tier enforcement: approval.check_tier(tier_name) reads config.approvals[tier_name] and returns "auto", "prompt", or "manual". skill_promotion always returns "manual" regardless of config.
```

### Step 1.11 — Full orchestrator (`agent/agent.lua` rewrite)

**Prompt**:
```
Rewrite agent/agent.lua as the full state machine orchestrator.

Here are all available modules (paste interfaces only, not full code):
<paste function signatures from: config, luallm, state, llm_client, audit, graph, sandbox, skill_loader, skill_runner, approval>

Here is the state machine from the plan:
<paste §6 from plan>

Requirements:
- Implement the full Task.Status state machine: PENDING → PLANNING → GRAPH_EXEC → (SKILL_DRAFT → SKILL_TEST → APPROVAL → REWORK as needed) → COMPLETE/FAILED, plus MODEL_WAIT
- agent.run(prompt) — the main loop per §6
- agent.plan(task) — build the LLM prompt including available skills list and model info
- agent.generate_graph(task) — call LLM, parse response as task graph, validate with graph.validate()
- agent.execute_graph(task) — get next ready node, execute it (skill → skill_runner, llm_call → llm_client, decision → evaluate condition)
- agent.draft_skill(task) — use LLM to generate skill code + test code, write to skills/agent/
- agent.test_skill(task) — run tests via skill_runner.run_tests, transition to APPROVAL if pass, REWORK if fail
- agent.rework_skill(task) — send failing test output back to LLM for revision, up to max_skill_retries
- agent.pause_for_approval(task) — create approval, print prompt, exit
- agent.pause_for_model(task) — print model start instructions, exit
- Global step budget enforcement
- save_state after every transition
- audit.log at every transition
```

### Step 1.12 — CLI completion (`cli/main.lua` rewrite)

**Prompt**:
```
Rewrite cli/main.lua as the full CLI dispatcher.

Commands to support:
- luallm-agent init — create ~/.config/luallmagent/ skeleton, generate default config.json, set permissions
- luallm-agent doctor — run all checks (see below)
- luallm-agent run "prompt" — start a new task
- luallm-agent run "prompt" --yes — auto-approve task confirmation tier
- luallm-agent --resume — resume paused task (check MODEL_WAIT and APPROVAL states)
- luallm-agent --reset — clear state
- luallm-agent log --tail N — show last N audit log entries (default 20)
- luallm-agent log --task TASK_ID — filter audit log by task
- luallm-agent skills list — list skills in allowed/ with version info
- luallm-agent skills test NAME — rerun tests for a skill

Use a simple arg parser (no external deps). Print usage on invalid args.
```

### Step 1.13 — Doctor module (`cli/doctor.lua`)

**Prompt**:
```
Write cli/doctor.lua — environment health checker.

Dependencies: agent/config.lua, agent/luallm.lua, agent/audit.lua

Checks to implement (each prints ✅, ⚠️, or ❌ with details):
1. Config file exists and is valid JSON
2. Config file is not writable by current user (or warn)
3. luallm binary found at config.luallm.binary
4. luallm help --json is parseable
5. Lua version is 5.2+ (or 5.1 with setfenv)
6. skills/allowed/ exists and is not writable (or warn)
7. skills/agent/ exists and is writable
8. state/ directory exists and is writable
9. /dev/urandom is readable (UUID source)
10. Audit log is writable
11. luallm state --json returns valid data, report each model status
12. luallm notes --json returns valid data, flag models without notes
13. Cross-reference config.model_selection against running models
14. No pending approvals (or list them)
15. No running tasks (or show current task status)

Exit codes: 0 = all critical pass, 1 = any fatal, 2 = warnings only
```

---

## Phase 2 — Agent Self-Harden

The agent is now feature-complete. These steps use the full agent (with graph execution, skills, sandbox, approvals) to build hardening and convenience features.

### Step 2.1 — Sample skills

Use the agent's full `run` flow to generate, test, and approve these starter skills:

```bash
luallm-agent run "Create a skill called read_file that reads a text file and returns its contents as a string. It should take {path=...} as args."
# → agent drafts skill + test, runs tests, requests approval
# → human reviews, promotes

luallm-agent run "Create a skill called write_file that writes a string to a file. Args: {path=..., content=...}. Must check path is in allowed list. Must refuse to overwrite unless args.overwrite=true."

luallm-agent run "Create a skill called read_csv that parses a CSV file into a list of row tables. Args: {path=..., has_header=true}."

luallm-agent run "Create a skill called write_markdown_report that takes {title=..., sections={{heading=..., body=...}, ...}, output_path=...} and writes a formatted markdown file."

luallm-agent run "Create a skill called exec_safe that runs a shell command from a whitelist of allowed commands (ls, wc, head, tail, grep, find). Args: {command=..., args={...}}. Must reject any command not in the whitelist."
```

### Step 2.2 — Self-test suite

```bash
luallm-agent run "Read every module in the agent/ directory. For each module that doesn't have a corresponding test file in test/, generate one. Use the lib/luallm_test.lua framework. Each test file should cover: normal operation, edge cases, error conditions."
```

### Step 2.3 — Documentation

```bash
luallm-agent run "Read all .lua files in lib/, agent/, and cli/. Generate a single REFERENCE.md with: module-by-module API docs, function signatures, parameter descriptions, return values, and a dependency graph in mermaid format."
```

---

## Critical Path Summary

```
PHASE 0 (Human, ~4 hours)          PHASE 1 (Agent + Human review)         PHASE 2 (Agent, full flow)
─────────────────────────          ────────────────────────────────        ──────────────────────────
0.1  Scaffolding                   1.1  Audit logger                      2.1  Sample skills
0.2  json.lua (vendor)             1.2  luallm wrapper enhancements       2.2  Self-test suite
0.3  uuid.lua                      1.3  LLM client retry + fallback       2.3  Documentation
0.4  config.lua (minimal)          1.4  Test framework
0.5  luallm.lua (minimal)          1.5  Config validator
0.6  state.lua                     1.6  Task graph engine
0.7  llm_client.lua (minimal)      1.7  Sandbox
0.8  agent.lua (minimal)           1.8  Skill loader
0.9  cli/main.lua (minimal)        1.9  Skill runner
0.10 Smoke test                    1.10 Approval manager
         │                         1.11 Full orchestrator
         │                         1.12 CLI completion
         ▼                         1.13 Doctor module
   "agent can call LLM                     │
    and write a file"                      ▼
         │                          "agent is feature-complete"
         │                                 │
         └──────────────────────────────────┘
```

## Dependency Order (Phase 1)

Steps within Phase 1 have dependencies. Here's the safe ordering:

```
1.4  Test framework         ─── (no deps, enables testing everything after)
1.1  Audit logger           ─── (no agent deps)
1.2  luallm wrapper         ─── (uses audit)
1.3  LLM client             ─── (uses luallm wrapper, audit)
1.5  Config validator        ─── (no agent deps)
1.6  Task graph engine       ─── (pure logic, no agent deps)
1.7  Sandbox                 ─── (uses config)
1.8  Skill loader            ─── (uses config)
1.9  Skill runner            ─── (uses sandbox, skill loader, audit, config)
1.10 Approval manager        ─── (uses config, audit)
1.11 Full orchestrator       ─── (uses ALL above)
1.12 CLI completion          ─── (uses orchestrator)
1.13 Doctor module           ─── (uses config, luallm wrapper, audit)
```

Parallelizable groups (order within group doesn't matter):
- **Group A** (no deps): 1.4, 1.1, 1.5, 1.6
- **Group B** (needs Group A): 1.2, 1.7, 1.8
- **Group C** (needs Group B): 1.3, 1.9, 1.10, 1.13
- **Group D** (needs all): 1.11, 1.12

---

## Human Review Checklist Per Step

For each Phase 1 step, before installing the agent's output:

```
□ Code reads correctly (no hallucinated requires, no phantom APIs)
□ All require() paths match actual file locations
□ No use of blocked globals (os.execute, io.popen, debug, load, etc.)
□ Error handling present (pcall where needed, nil checks)
□ Tests exist and pass (run manually: lua test/<module>_test.lua)
□ Module integrates with existing code (function signatures match callers)
□ No hardcoded paths or credentials
□ File written to correct location
```

---

## Estimated Timeline

| Phase | Steps | Estimated Time | Who |
|-------|-------|----------------|-----|
| Phase 0 | 0.1–0.10 | 2–4 hours | Human |
| Phase 1 | 1.1–1.13 | 4–8 hours (mostly review) | Agent + Human |
| Phase 2 | 2.1–2.3 | 1–2 hours (mostly autonomous) | Agent + Human spot-check |
| **Total** | | **7–14 hours** | |

The bottleneck is human review in Phase 1. Each step produces a module the human must read, test, and install. With a fast model and focused review, each Phase 1 step takes ~20–40 minutes including review.
