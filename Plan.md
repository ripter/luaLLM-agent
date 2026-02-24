# 🧠 `luallm-agent` Implementation Plan v3
*A Lua-native, human-supervised LLM agent for safe, multi-step task orchestration*

---

## 1. Core Principles

| Principle | Enforcement |
|-----------|-------------|
| **Human ownership of skills** | Agent writes *only* to `skills/agent/`. `skills/allowed/` is immutable to the agent (filesystem perms + config-level block). |
| **Test-first approval** | No skill enters `skills/allowed/` unless its test suite passes *and* a human verifies. |
| **Sandboxed execution** | Every skill runs in a restricted `_ENV`. Static analysis is a pre-check; the sandbox is the real enforcement layer. |
| **State-first architecture** | Every action persists to `current_task.json`; the agent never runs without recovery metadata. |
| **Auditable by default** | Every state transition, LLM call, file access, and test run appends to `state/audit_log.jsonl`. |
| **`luallm` as model layer** | The agent does not manage models directly. It discovers, starts, stops, queries, and annotates models through the `luallm` CLI and its `--json` interface. Notes, state, and lifecycle are `luallm`'s responsibility. |
| **Explicit approval tiers** | Skill promotion always requires human action. Other approvals are configurable. |
| **Bounded execution** | Every state has a retry limit and timeout. The agent cannot loop or burn tokens indefinitely. |
| **Fail-open, fail-safe** | Agent pauses on ambiguity; never auto-skips, auto-promotes, or auto-overwrites. |

---

## 2. File & State Structure

```
~/.config/luallmagent/
├── config.json                        # validated by `doctor`; immutable to agent
├── state/
│   ├── current_task.json              # persistent state; paused=true during human review
│   ├── audit_log.jsonl                # append-only structured log
│   └── pending_approvals/
│       └── skill_<n>_<uuid>.json
└── skills/
    ├── agent/                         # AGENT-WRITTEN (human can edit; agent may overwrite on rework)
    │   ├── read_csv.lua
    │   ├── read_csv_test.lua
    │   └── ...
    └── allowed/                       # HUMAN-MANAGED (agent reads only; write blocked)
        ├── .archive/                  # old versions moved here on update
        ├── read_csv.lua
        ├── read_csv_test.lua
        └── ...
```

> **No `models/` directory.** Model state, notes, and lifecycle are managed entirely by `luallm`. The agent queries `luallm` at runtime and does not cache or duplicate model metadata.

### Protection classes

| Resource | Agent can read? | Agent can write? | Mechanism |
|----------|:-:|:-:|-----------|
| `config.json` | Yes | **No** | `chmod 444` + config-level block |
| `skills/allowed/` | Yes | **No** | `chmod 444` + config-level block + `is_path_allowed()` |
| `skills/agent/` | Yes | Yes | Normal permissions |
| `state/` | Yes | Yes | Normal permissions |

> **Cross-platform note**: `chmod` is POSIX-only. The config-level path block (`blocked_paths`) is the *primary* enforcement layer. Filesystem permissions are defense-in-depth. On non-POSIX systems, the config block alone must be sufficient.

---

## 3. `luallm` Integration

The agent treats `luallm` as an external service it shells out to. All interaction uses the `--json` flag for machine-readable output. The agent never parses human-formatted `luallm` output.

### 3.1 Discovery: `luallm help --json`

On startup (and cached for the duration of a task), the agent calls:

```bash
luallm help --json
```

This returns the full command tree — available subcommands, flags, and their descriptions. The agent uses this to:

- Verify `luallm` is installed and responsive
- Discover which commands are available (future-proofing: if `luallm` adds new commands, the agent can adapt)
- Validate that required commands (`state`, `notes`, `start`, `stop`) exist

The agent stores the parsed help output in memory (not on disk) for the task's duration.

### 3.2 Model state: `luallm state --json`

```bash
luallm state --json
```

Returns which models are currently loaded, on which ports, their resource usage, and readiness. Example expected shape:

```json
{
  "models": [
    {
      "name": "llama3-8b-q4",
      "status": "running",
      "port": 8080,
      "pid": 12345,
      "vram_mb": 5500,
      "uptime_seconds": 3600
    },
    {
      "name": "llama3-70b-q4",
      "status": "stopped"
    }
  ]
}
```

The agent calls `luallm state --json` at these points:
- **Task start**: To know what's available for planning
- **Before each LLM call**: To confirm the target model is still running
- **After OOM/failure**: To detect if the model crashed

### 3.3 Model notes: `luallm notes --json`

```bash
luallm notes --json
luallm notes <model_name> --json
```

Notes are human- and agent-readable metadata about model capabilities, quirks, and history. The agent reads notes to inform model selection but **never writes notes automatically**. If the agent detects something noteworthy (e.g., a model consistently fails at JSON output), it surfaces this to the human via the audit log and CLI output, and suggests a note update:

```
ℹ️  llama3-8b-q4 failed JSON validation 3/3 times for graph generation.
   Consider adding a note: luallm notes llama3-8b-q4 "Unreliable for structured JSON output >500 tokens"
```

The agent parses notes to look for keywords/tags that inform selection policy (see §10).

### 3.4 Starting and stopping models

```bash
luallm start <model_name> --json
luallm stop <model_name> --json
```

The agent may start a model if:
- The selected model for a task is not currently running
- The `config.json` setting `luallm.auto_start` is `true` (default: `false`)
- If `auto_start` is `false`, the agent pauses and tells the human which model to start

The agent may stop a model if:
- The task is complete and `config.json` setting `luallm.auto_stop` is `true` (default: `false`)
- The agent never stops models mid-task

```lua
function luallm.ensure_model_running(model_name)
  local state = luallm.state()
  local model = find_model(state, model_name)

  if model and model.status == "running" then
    return model  -- ready
  end

  if config.luallm.auto_start then
    audit.log("model_start", { model = model_name, auto = true })
    local result = luallm.exec("start", model_name)
    if not result.ok then
      error("failed to start model: " .. result.error)
    end
    -- Poll state until running or timeout
    return luallm.wait_for_ready(model_name, config.limits.model_start_timeout_seconds)
  else
    -- Pause for human
    print("⏸  Model '" .. model_name .. "' is not running.")
    print("   Start it with: luallm start " .. model_name)
    print("   Then resume:   luallm-agent --resume")
    return nil, "model_not_running"
  end
end
```

### 3.5 Sending completions

The agent sends LLM requests to the running model's HTTP endpoint (discovered via `luallm state --json` port field). The completion format follows whatever API `luallm` exposes (likely OpenAI-compatible):

```lua
function luallm.complete(model_name, messages, options)
  local state = luallm.state()
  local model = find_model(state, model_name)
  if not model or model.status ~= "running" then
    error("model not running: " .. model_name)
  end

  local url = "http://127.0.0.1:" .. model.port .. "/v1/chat/completions"
  local body = json.encode({
    model = model_name,
    messages = messages,
    temperature = options.temperature or 0.2,
    max_tokens = options.max_tokens or 4096,
  })

  -- Uses luasocket or curl; timeout enforced externally
  local response, status = http.post(url, body, {
    ["Content-Type"] = "application/json",
  })

  if status ~= 200 then
    error("LLM completion failed (HTTP " .. status .. "): " .. (response or ""))
  end

  return json.decode(response)
end
```

### 3.6 `luallm` wrapper module

All `luallm` CLI interaction is centralized in a single module (`agent/luallm.lua`) that:

- Handles `--json` parsing for every command
- Detects non-zero exit codes and surfaces errors
- Caches `help --json` output for the task duration
- Does **not** cache `state --json` (always fresh)
- Provides typed Lua accessors: `luallm.state()`, `luallm.notes(model?)`, `luallm.start(model)`, `luallm.stop(model)`, `luallm.help()`

```lua
-- Core execution function
function luallm.exec(...)
  local args = { config.luallm.binary, ... , "--json" }
  local cmd = table.concat(args, " ")
  local handle = io.popen(cmd)
  local output = handle:read("*a")
  local ok, exit_type, code = handle:close()

  if not ok or code ~= 0 then
    return { ok = false, error = output, exit_code = code }
  end

  local parsed = json.decode(output)
  return { ok = true, data = parsed }
end
```

---

## 4. Sandbox Architecture

Static source analysis (scanning for `socket.http`, `io.open`, etc.) is trivially defeated by `load()`, `loadstring()`, string concatenation, or indirect calls. It remains useful as a fast pre-check and documentation aid, but cannot be the enforcement layer.

### 4.1 Restricted environment

Every skill executes inside a restricted `_ENV` constructed by the skill runner:

```lua
function sandbox.make_env(skill_metadata)
  local env = {
    -- Safe builtins (full)
    math    = math,
    string  = string,
    table   = table,
    pairs   = pairs,
    ipairs  = ipairs,
    next    = next,
    select  = select,
    type    = type,
    tostring = tostring,
    tonumber = tonumber,
    pcall   = pcall,
    xpcall  = xpcall,
    error   = error,
    assert  = assert,
    unpack  = unpack or table.unpack,

    -- Controlled I/O (path-checked wrappers)
    io = sandbox.make_io(skill_metadata.paths),

    -- Controlled require (resolves from allowed/ only)
    require = sandbox.make_require(skill_metadata.dependencies),

    -- Logging (write-only, appends to audit log)
    log = sandbox.make_logger(skill_metadata.name),

    -- Skill-declared print (captured, not sent to stdout)
    print = sandbox.make_print(skill_metadata.name),
  }
  env._G = env  -- self-referential, standard Lua pattern
  return env
end
```

### 4.2 Blocked globals

The following are **never** available inside a skill's `_ENV`:

| Blocked | Reason |
|---------|--------|
| `os.execute`, `os.remove`, `os.rename`, `os.exit` | Arbitrary shell/FS mutation |
| `io.popen` | Shell execution |
| `load`, `loadstring`, `loadfile`, `dofile` | Arbitrary code execution |
| `debug` (entire library) | Can inspect/mutate upvalues, break sandbox |
| `rawget`, `rawset`, `rawequal` | Can bypass metatables used for guards |
| `collectgarbage` | Can cause DoS |
| `require` (stdlib version) | Replaced with scoped loader |
| `setfenv`, `getfenv` (Lua 5.1) | Can escape sandbox |
| `setmetatable` on foreign tables | Restricted to tables the skill created |

### 4.3 Path-checked I/O wrappers

```lua
function sandbox.make_io(declared_paths)
  return {
    open = function(path, mode)
      local abs = resolve_absolute(path)
      if not agent.is_path_allowed(abs) then
        error("path not in allowed list: " .. path)
      end
      if not matches_any(abs, declared_paths) then
        error("path not declared in skill metadata: " .. path)
      end
      if mode and mode:match("[wa%+]") then
        audit.log("file_write", { path = abs, skill = skill_metadata.name })
      else
        audit.log("file_read", { path = abs, skill = skill_metadata.name })
      end
      return io.open(abs, mode)
    end,
    lines = function(path)
      -- same path checks, returns io.lines(abs)
    end,
    -- io.read, io.write, io.close operate on handles returned by open
  }
end
```

### 4.4 Scoped `require`

```lua
function sandbox.make_require(declared_deps)
  local allowed_dir = config.paths.skills_allowed
  return function(modname)
    if not declared_deps or not declared_deps[modname] then
      error("undeclared dependency: " .. modname)
    end
    local path = allowed_dir .. "/" .. modname .. ".lua"
    if not file_exists(path) then
      error("dependency not found in allowed/: " .. modname)
    end
    local chunk, err = loadfile(path)
    if not chunk then error(err) end
    -- Run the dependency in its own sandbox
    local dep_env = sandbox.make_env(load_skill_metadata(modname))
    setfenv(chunk, dep_env)  -- Lua 5.1
    -- or: load(chunk_source, name, "t", dep_env)  -- Lua 5.2+
    return chunk()
  end
end
```

### 4.5 Resource limits

| Resource | Limit | Enforcement |
|----------|-------|-------------|
| CPU time per skill execution | Configurable (default: 30s) | `debug.sethook` count-based interrupt, or external timeout via coroutine + `os.clock()` |
| Memory | Configurable (default: 50MB) | `collectgarbage("count")` polled by the hook; kills skill if exceeded |
| File handles | Max 10 open simultaneously | Tracked in the I/O wrapper |
| Output size | Max 10MB captured print/log | Tracked in the print wrapper |

> **Note on `debug.sethook`**: The host (skill runner) uses `debug.sethook` to enforce CPU limits. The `debug` library is *not* exposed to skills.

---

## 5. Task Graph

The task graph is the core data structure the LLM produces when planning. It is a directed acyclic graph (DAG) of executable nodes with explicit dependencies.

### 5.1 Schema

```lua
---@class TaskGraph
---@field nodes TaskNode[]
---@field metadata { prompt: string, created_at: string, model: string }

---@class TaskNode
---@field id string              -- unique within graph, e.g. "1", "2"
---@field action "skill"|"llm_call"|"decision"
---@field depends_on string[]    -- list of node IDs that must complete first
---@field status "pending"|"running"|"complete"|"failed"|"skipped"
---@field retries number         -- times this node has been retried
---@field max_retries number     -- default 3
---@field result any|nil         -- output of the node, nil until complete

-- For action == "skill":
---@field skill_name string
---@field skill_args table
---@field skill_source "allowed"|"draft"  -- whether skill exists or must be created

-- For action == "llm_call":
---@field prompt_template string  -- may reference {node_1_result}, {node_2_result}
---@field model string|nil        -- override model for this node

-- For action == "decision":
---@field condition string        -- human-readable condition
---@field if_true string          -- node ID to enable
---@field if_false string         -- node ID to enable
```

### 5.2 Graph generation strategy

The LLM generates the task graph in **one shot** from a structured prompt. The prompt includes:

1. The user's original request
2. An inventory of available skills (from `skills/allowed/`)
3. Currently running models and their capabilities (from `luallm state --json` + `luallm notes --json`)
4. The JSON schema above (as a strict contract)
5. A few-shot example of a well-formed graph

The agent validates the returned graph:
- All `depends_on` references resolve to real node IDs
- No cycles (topological sort must succeed)
- All referenced skills either exist in `allowed/` or are marked `skill_source = "draft"`
- No node references paths outside `config.allowed_paths`

If validation fails, the agent retries graph generation (up to `config.max_plan_retries`, default 2) with the validation errors appended to the prompt.

### 5.3 Graph execution

```lua
function agent.execute_graph(task)
  local ready = graph.get_ready_nodes(task.graph)  -- nodes with all deps complete
  if #ready == 0 and not graph.is_complete(task.graph) then
    task.status = Task.FAILED
    task.error = "deadlock: no ready nodes but graph incomplete"
    return task
  end

  -- Execute one node at a time (sequential for v1; parallel is a future option)
  local node = ready[1]
  node.status = "running"
  save_state(task)
  audit.log("node_start", { node_id = node.id, action = node.action })

  local ok, result = pcall(agent.execute_node, task, node)

  if ok then
    node.status = "complete"
    node.result = result
    audit.log("node_complete", { node_id = node.id })
  else
    node.retries = node.retries + 1
    if node.retries >= node.max_retries then
      node.status = "failed"
      task.status = Task.FAILED
      task.error = "node " .. node.id .. " failed after " .. node.retries .. " retries: " .. tostring(result)
      audit.log("node_failed_final", { node_id = node.id, error = tostring(result) })
    else
      node.status = "pending"  -- will be retried
      audit.log("node_retry", { node_id = node.id, attempt = node.retries, error = tostring(result) })
    end
  end

  save_state(task)
  return task
end
```

### 5.4 Node failure modes

| Failure | Behavior |
|---------|----------|
| Skill not in `allowed/` | Transition to `SKILL_DRAFT` → draft, test, request approval, then retry node |
| Skill execution error | Retry node (up to `max_retries`). On final failure, attempt re-plan: LLM generates alternative subgraph for the failed node. |
| LLM call error | Retry with exponential backoff (1s, 4s, 16s). On final failure, try fallback model per selection policy (§10). |
| LLM returns invalid output | Retry with validation error appended to prompt. |
| Model not running | Call `luallm.ensure_model_running()` (§3.4). If `auto_start` is off, pause for human. |
| Decision node | Evaluate condition against prior node results. If ambiguous, pause for human. |
| Upstream node failed | Downstream nodes marked `skipped`. |

---

## 6. Agent State Machine

```lua
Task.Status = {
  PENDING       = "pending",        -- initial
  PLANNING      = "planning",       -- LLM generating task graph
  GRAPH_EXEC    = "graph_exec",     -- executing graph nodes
  SKILL_DRAFT   = "skill_draft",    -- agent drafting a new skill
  SKILL_TEST    = "skill_test",     -- running skill tests
  APPROVAL      = "approval",       -- human review (paused=true)
  REWORK        = "rework",         -- re-drafting after failed test or rejected approval
  MODEL_WAIT    = "model_wait",     -- waiting for human to start a model
  COMPLETE      = "complete",
  FAILED        = "failed",
}
```

### Orchestrator (`agent.lua`)

```lua
function agent.run_task(prompt)
  local task = {
    id = uuid.generate(),
    prompt = prompt,
    status = Task.PENDING,
    created_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    step_count = 0,
    max_steps = config.max_task_steps or 50,  -- global budget
  }
  save_state(task)
  audit.log("task_start", { id = task.id, prompt = prompt })

  while task.status ~= Task.COMPLETE and task.status ~= Task.FAILED do
    -- Global step budget
    task.step_count = task.step_count + 1
    if task.step_count > task.max_steps then
      task.status = Task.FAILED
      task.error = "exceeded max step budget (" .. task.max_steps .. ")"
      audit.log("task_budget_exceeded", { id = task.id })
      break
    end

    if task.status == Task.PENDING then
      task = agent.plan(task)

    elseif task.status == Task.PLANNING then
      task = agent.generate_graph(task)

    elseif task.status == Task.GRAPH_EXEC then
      task = agent.execute_graph(task)

    elseif task.status == Task.SKILL_DRAFT then
      task = agent.draft_skill(task)

    elseif task.status == Task.SKILL_TEST then
      task = agent.test_skill(task)

    elseif task.status == Task.APPROVAL then
      agent.pause_for_approval(task)
      audit.log("task_paused", { id = task.id, reason = "approval" })
      return task  -- exits; resumed via --resume

    elseif task.status == Task.MODEL_WAIT then
      agent.pause_for_model(task)
      audit.log("task_paused", { id = task.id, reason = "model_not_running", model = task.waiting_for_model })
      return task  -- exits; resumed via --resume

    elseif task.status == Task.REWORK then
      task = agent.rework_skill(task)
    end

    save_state(task)
  end

  audit.log("task_end", { id = task.id, status = task.status })
  return task
end
```

On `--resume` when status is `MODEL_WAIT`, the agent calls `luallm state --json` to check if the required model is now running. If yes, transitions back to the previous state. If no, re-prints the start instructions and exits.

---

## 7. Skill Lifecycle

### 7.1 Skill metadata header

Every skill file begins with a structured metadata comment:

```lua
---@skill {
---  name = "read_csv",
---  version = "1.0",
---  description = "Parse a CSV file into a table of rows",
---  dependencies = {},
---  paths = { "~/data/*" },
---  urls = {},
---  public_functions = { "run", "parse_args" },
---}

local M = {}

function M.run(args)
  -- ...
end

function M.parse_args(raw)
  -- ...
end

return M
```

The skill runner parses this header at load time. Missing or malformed metadata is a hard error.

### 7.2 Test format

Tests output structured results (a minimal TAP-like JSON format), not just exit codes:

```lua
-- read_csv_test.lua
local test = require("luallm_test")  -- provided by the framework
local read_csv = require("read_csv")

test.case("parses simple CSV", function()
  local rows = read_csv.run({ path = "fixtures/simple.csv" })
  test.eq(#rows, 3)
  test.eq(rows[1].name, "Alice")
end)

test.case("handles empty file", function()
  local rows = read_csv.run({ path = "fixtures/empty.csv" })
  test.eq(#rows, 0)
end)

test.case("rejects path outside allowed list", function()
  test.errors(function()
    read_csv.run({ path = "/etc/passwd" })
  end)
end)

test.run_all()
-- Outputs JSON to stdout:
-- {
--   "skill": "read_csv",
--   "total": 3,
--   "passed": 3,
--   "failed": 0,
--   "results": [
--     { "name": "parses simple CSV", "status": "pass", "duration_ms": 12 },
--     { "name": "handles empty file", "status": "pass", "duration_ms": 3 },
--     { "name": "rejects path outside allowed list", "status": "pass", "duration_ms": 1 }
--   ]
-- }
```

Exit code: `0` if all pass, `1` if any fail, `2` if test framework error.

### 7.3 Draft phase (`skills/agent/`)

1. Agent generates `skill_name.lua` (with metadata header) + `skill_name_test.lua`
2. Tests run via: `lua skills/agent/skill_name_test.lua`
3. Structured test output is captured and stored in the approval request
4. If tests fail, agent enters `REWORK` (up to `config.max_skill_retries`, default 3):
   - LLM receives: original spec, current code, failing test output
   - LLM produces revised code
   - Tests re-run

### 7.4 Approval phase

Agent creates `state/pending_approvals/skill_<n>_<uuid>.json` and sets `task.status = Task.APPROVAL`.

CLI prompt on `--resume`:

```
┌─ Skill Approval: read_csv (v1.0)
│
│  Files:
│    skill: ~/.config/luallmagent/skills/agent/read_csv.lua
│    test:  ~/.config/luallmagent/skills/agent/read_csv_test.lua
│
│  Tests: 3/3 passed
│    ✅ parses simple CSV (12ms)
│    ✅ handles empty file (3ms)
│    ✅ rejects path outside allowed list (1ms)
│
│  Paths declared: ~/data/*
│  Dependencies: (none)
│
│  [V]iew code  [R]erun tests  [E]dit  [F]ix & retest  [Y]es (promote)  [N]o (reject)
└─
```

Selecting `[Y]es` prints the exact commands for the human to run:

```bash
cp ~/.config/luallmagent/skills/agent/read_csv.lua ~/.config/luallmagent/skills/allowed/
cp ~/.config/luallmagent/skills/agent/read_csv_test.lua ~/.config/luallmagent/skills/allowed/
chmod 444 ~/.config/luallmagent/skills/allowed/read_csv.lua
chmod 444 ~/.config/luallmagent/skills/allowed/read_csv_test.lua
luallm-agent --resume
```

The agent does **not** execute these commands. The human does.

### 7.5 Promotion phase (human-only)

On `--resume` after promotion, the agent:
1. Detects that the skill now exists in `allowed/`
2. Validates: metadata parses, tests pass from `allowed/`, version matches approval record
3. Marks the approval as `approved: true`
4. Returns to `GRAPH_EXEC` to continue the task

### 7.6 Skill updates

When a skill in `allowed/` needs revision:

1. Agent drafts a new version in `agent/` with an incremented `version` in the metadata header
2. Normal test + approval cycle
3. On human promotion:
   ```bash
   mv ~/.config/luallmagent/skills/allowed/read_csv.lua \
      ~/.config/luallmagent/skills/allowed/.archive/read_csv_v1.0.lua
   cp ~/.config/luallmagent/skills/agent/read_csv.lua \
      ~/.config/luallmagent/skills/allowed/
   ```
4. Agent validates new version on `--resume`

### 7.7 Skill dependencies

Skills may depend on other skills. Dependencies are declared in the metadata header and resolved at load time:

- Dependencies must exist in `skills/allowed/` (a draft skill cannot depend on another draft)
- Circular dependencies are detected and rejected
- Each dependency runs in its own sandbox (no shared mutable state between skills)
- The scoped `require` (§4.4) enforces this

---

## 8. Approval Tiers

| Tier | What | `--yes` skips? | Default |
|------|------|:-:|---------|
| **Task confirmation** | "I plan to do X, Y, Z — proceed?" | **Yes** | Prompt shown |
| **Path access (read)** | "Skill wants to read ~/data/foo.csv" | **Configurable** | Prompt shown |
| **Path access (write)** | "Skill wants to write ~/output/report.md" | **No** | Always prompt |
| **Skill promotion** | "Move skill to allowed/" | **Never** | Always human action |
| **Destructive overwrite** | "File ~/output/report.md already exists" | **Never** | Always prompt |
| **Network access** | "Skill wants to fetch https://..." | **No** | Always prompt |

Configuration in `config.json`:

```json
{
  "approvals": {
    "task_confirmation": "prompt",
    "path_read": "auto",
    "path_write": "prompt",
    "skill_promotion": "manual",
    "destructive_overwrite": "prompt",
    "network_access": "prompt"
  }
}
```

Values: `"auto"` (skip), `"prompt"` (CLI confirmation), `"manual"` (human action outside CLI).

> `skill_promotion` only accepts `"manual"`. The agent enforces this regardless of config content.

---

## 9. Audit Log

All agent actions append to `state/audit_log.jsonl` (newline-delimited JSON). The log is append-only; the agent never reads it during operation (it reads `current_task.json` for state).

### Entry format

```json
{
  "ts": "2024-06-02T14:30:01.123Z",
  "event": "node_start",
  "task_id": "abc-123",
  "data": {
    "node_id": "2",
    "action": "skill",
    "skill_name": "read_csv"
  }
}
```

### Event types

| Event | Logged when |
|-------|-------------|
| `task_start` | New task created |
| `task_end` | Task reaches COMPLETE or FAILED |
| `task_paused` | Task enters APPROVAL or MODEL_WAIT |
| `task_budget_exceeded` | Step count exceeds max |
| `graph_generated` | LLM produces task graph |
| `graph_validation_failed` | Task graph fails schema validation |
| `node_start` | Node begins execution |
| `node_complete` | Node succeeds |
| `node_retry` | Node fails, will retry |
| `node_failed_final` | Node exhausts retries |
| `llm_call` | LLM request sent (model, prompt hash, token count) |
| `llm_response` | LLM response received (response hash, token count, latency) |
| `luallm_exec` | Any `luallm` CLI call (command, args, exit code) |
| `model_start` | Agent started a model via `luallm start` |
| `model_not_running` | Agent needs a model that isn't running |
| `model_oom` | Model crashed or returned OOM |
| `model_fallback` | Agent selected fallback model |
| `skill_draft` | Skill code generated |
| `skill_test_run` | Test suite executed (full structured results) |
| `skill_rework` | Skill re-drafted after failure |
| `approval_requested` | Approval JSON created |
| `approval_resolved` | Human approved or rejected |
| `file_read` | File opened for reading |
| `file_write` | File opened for writing |
| `sandbox_violation` | Skill attempted blocked operation |

### Log rotation

When `audit_log.jsonl` exceeds `config.audit.max_size_mb` (default 50MB), the agent rotates:
`audit_log.jsonl` → `audit_log.1.jsonl` (up to `config.audit.max_files`, default 5).

---

## 10. Model Selection

The agent does not maintain its own model database. It builds a selection decision from two runtime sources:

1. **`luallm state --json`** — what's running right now, on which ports
2. **`luallm notes --json`** — human-authored capability notes per model

### 10.1 Selection policy (in `config.json`)

The agent's config defines which models to prefer for which task types, and the fallback order:

```json
{
  "model_selection": {
    "planning": {
      "prefer": ["llama3-70b-q4", "deepseek-33b-q4"],
      "fallback": ["llama3-8b-q4"]
    },
    "skill_generation": {
      "prefer": ["llama3-70b-q4"],
      "fallback": ["deepseek-33b-q4", "llama3-8b-q4"]
    },
    "simple_transform": {
      "prefer": ["llama3-8b-q4"],
      "fallback": []
    },
    "default": {
      "prefer": ["llama3-8b-q4"],
      "fallback": []
    }
  }
}
```

### 10.2 Selection logic

```lua
function agent.select_model(task_type)
  local policy = config.model_selection[task_type] or config.model_selection["default"]
  local state = luallm.state()
  local notes = luallm.notes()

  -- Try preferred models first, then fallbacks
  local candidates = {}
  for _, name in ipairs(policy.prefer) do table.insert(candidates, name) end
  for _, name in ipairs(policy.fallback) do table.insert(candidates, name) end

  for _, model_name in ipairs(candidates) do
    local model_state = find_model(state, model_name)
    local model_notes = notes[model_name]  -- may be nil

    -- Skip if notes indicate known problems for this task type
    if model_notes and is_flagged_unsuitable(model_notes, task_type) then
      audit.log("model_skip", { model = model_name, reason = "flagged in notes" })
      goto continue
    end

    if model_state and model_state.status == "running" then
      audit.log("model_selected", { model = model_name, task_type = task_type, running = true })
      return model_name, model_state.port
    end

    -- Model exists but not running — try to start or pause
    if model_state then
      local started_model, err = luallm.ensure_model_running(model_name)
      if started_model then
        audit.log("model_selected", { model = model_name, task_type = task_type, started = true })
        return model_name, started_model.port
      end
      -- If auto_start is off, this returns nil — we continue to try other candidates
    end

    ::continue::
  end

  -- No candidates available
  local names = table.concat(candidates, ", ")
  error("no viable model for task type '" .. task_type .. "'. Candidates: " .. names ..
        ". Check `luallm state` and start one.")
end
```

### 10.3 OOM handling

When a model crashes or returns an OOM error during a completion:

1. Agent detects the failure (HTTP error or `luallm state` shows model stopped)
2. Logs `model_oom` to audit log with the model name and context size
3. Suggests a note to the human:
   ```
   ⚠️  llama3-70b-q4 crashed (likely OOM) during graph generation (~4200 tokens).
      Consider: luallm notes llama3-70b-q4 "OOMs above ~4000 token context"
   ```
4. Selects next candidate in the fallback chain
5. If no fallbacks remain → `Task.FAILED` with actionable error message

The agent does **not** write to `luallm notes` directly. The human decides what to record. This keeps `luallm notes` as a curated, human-owned knowledge base rather than an auto-polluted log.

---

## 11. Retry Limits & Timeouts

Every retriable operation has explicit bounds. These are configurable in `config.json` under `limits`:

```json
{
  "limits": {
    "max_task_steps": 50,
    "max_plan_retries": 2,
    "max_node_retries": 3,
    "max_skill_retries": 3,
    "llm_timeout_seconds": 120,
    "llm_backoff_base_seconds": 1,
    "llm_backoff_max_seconds": 60,
    "skill_exec_timeout_seconds": 30,
    "skill_memory_limit_mb": 50,
    "max_open_file_handles": 10,
    "model_start_timeout_seconds": 120
  }
}
```

### LLM call retry with backoff

```lua
function agent.call_llm_with_retry(model_name, messages, options)
  local base = config.limits.llm_backoff_base_seconds
  local max_wait = config.limits.llm_backoff_max_seconds
  local timeout = config.limits.llm_timeout_seconds
  local max_retries = config.limits.max_node_retries

  for attempt = 1, max_retries do
    -- Verify model is still running before each attempt
    local state = luallm.state()
    local model = find_model(state, model_name)
    if not model or model.status ~= "running" then
      audit.log("model_oom", { model = model_name, attempt = attempt })
      return nil, "model_crashed"  -- caller handles fallback
    end

    local ok, result = pcall(luallm.complete, model_name, messages, options)
    if ok then
      audit.log("llm_response", {
        model = model_name,
        tokens_in = result.usage and result.usage.prompt_tokens,
        tokens_out = result.usage and result.usage.completion_tokens,
        latency_ms = result.latency_ms,
      })
      return result
    end

    local wait = math.min(base * (4 ^ (attempt - 1)), max_wait)
    audit.log("llm_retry", { model = model_name, attempt = attempt, wait = wait, error = tostring(result) })
    os.execute("sleep " .. wait)  -- host-level, not inside sandbox
  end

  return nil, "max_retries_exceeded"
end
```

---

## 12. UUID Generation

Lua has no built-in UUID. The agent uses the following strategy (checked by `doctor`):

1. **Preferred**: Read 16 bytes from `/dev/urandom`, format as UUID v4
2. **Fallback**: `luaossl` if installed (`openssl.rand.bytes(16)`)
3. **Last resort**: `os.time()` + `math.random()` seeded from `/dev/urandom` (weaker, flagged as warning by `doctor`)

```lua
function uuid.generate()
  local f = io.open("/dev/urandom", "rb")
  if f then
    local bytes = f:read(16)
    f:close()
    -- Set version (4) and variant (RFC 4122)
    local b7 = (bytes:byte(7) & 0x0F) | 0x40
    local b9 = (bytes:byte(9) & 0x3F) | 0x80
    return string.format(
      "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
      bytes:byte(1), bytes:byte(2), bytes:byte(3), bytes:byte(4),
      bytes:byte(5), bytes:byte(6),
      b7, bytes:byte(8),
      b9, bytes:byte(10),
      bytes:byte(11), bytes:byte(12), bytes:byte(13),
      bytes:byte(14), bytes:byte(15), bytes:byte(16)
    )
  end
  -- fallback strategies...
end
```

---

## 13. CLI Commands

| Command | Purpose |
|---------|---------|
| `luallm-agent init` | Generate `config.json`, create `~/.config/luallmagent/` skeleton, set permissions |
| `luallm-agent doctor` | Validate environment health (including `luallm` availability and model state) |
| `luallm-agent run "..."` | Start new task; generates task graph, begins execution |
| `luallm-agent --resume` | Resume paused task; checks pending approvals and model availability |
| `luallm-agent --reset` | Clear `state/current_task.json` and `pending_approvals/` |
| `luallm-agent log [--tail N]` | View audit log (last N entries, default 20) |
| `luallm-agent log --task TASK_ID` | View audit log filtered to a specific task |
| `luallm-agent skills list` | List all skills in `allowed/` with version and metadata |
| `luallm-agent skills test NAME` | Re-run tests for a skill in `allowed/` |

> **No `notes` command.** Use `luallm notes` directly. The agent reads notes but never writes them.

### `doctor` checks

```
✅ Config file: ~/.config/luallmagent/config.json (valid JSON, schema OK)
✅ Config file: NOT WRITABLE by agent user (🔒 safe)
✅ luallm binary: /usr/local/bin/luallm (v0.3.1)
✅ luallm help --json: parseable (14 commands found)
✅ Lua version: 5.4.6
✅ Cache dir: ~/.cache/luallmagent/ (writable)
✅ Allowed paths: 3/3 valid (~/data ✅, /tmp ✅, ~/output ✅)
✅ Blocked paths: 2/2 valid (~/.ssh ✅, /etc ✅)
✅ skills/allowed/: NOT WRITABLE by agent user (🔒 safe)
✅ skills/agent/: writable
✅ UUID source: /dev/urandom (available)
✅ Audit log: state/audit_log.jsonl (writable, 2.3MB)

Models (via luallm state --json):
  ✅ llama3-8b-q4: running on :8080 (5.5GB VRAM)
  ⏹  llama3-70b-q4: stopped
  ⚠️  deepseek-33b-q4: not found in luallm

Model notes (via luallm notes --json):
  ✅ llama3-8b-q4: has notes
  ⚠️  llama3-70b-q4: no notes (run `luallm notes llama3-70b-q4 "..."`)

Selection policy check:
  ✅ planning: at least 1 preferred model available (llama3-8b-q4 running)
  ⚠️  skill_generation: preferred model llama3-70b-q4 not running
  ✅ simple_transform: preferred model available

⚠️  Lua sandbox: setfenv not available (Lua 5.2+ uses _ENV; OK)
✅ No pending approvals
✅ No running tasks
```

Exit codes: `0` = all critical checks pass, `1` = fatal (cannot run), `2` = warnings only.

Key `doctor` additions over v2:
- Validates `luallm` binary exists and `help --json` is parseable
- Queries `luallm state --json` and reports running/stopped models
- Queries `luallm notes --json` and flags models without notes
- Cross-references `config.model_selection` against actual model availability
- Warns if preferred models for any task type are not running

---

## 14. Recovery & Resilience

| Scenario | Recovery |
|----------|----------|
| Task interrupted mid-step | `--resume` restores `current_task.json`; re-runs last node if status is `running` |
| Skill test fails | Agent enters `REWORK`; re-drafts with LLM context including failure output (up to `max_skill_retries`) |
| Skill test exhausts retries | Agent attempts alternative skill plan via LLM re-plan of the failing node |
| Model OOM / crash | Agent detects via `luallm state --json`, logs event, suggests note, falls back to next candidate |
| All models OOM | Task fails with clear error listing models tried; suggests `luallm notes` updates |
| Model not running | If `auto_start`: agent runs `luallm start`. Otherwise: `MODEL_WAIT` state, human starts model, `--resume` |
| `luallm` binary missing | `doctor` catches this as fatal. `run` refuses to start. |
| `luallm state --json` unparseable | Agent logs error, retries once, then fails with "luallm returned invalid output" |
| Human rejects skill | Agent re-plans the node that required the skill; may propose alternative approach |
| Human doesn't respond | Task stays paused indefinitely; `--resume` re-prompts |
| Audit log full | Rotated; no data loss, no interruption |
| `current_task.json` corrupted | Agent refuses to run; `--reset` clears state (human decision) |
| Power loss during `save_state` | Write to temp file + atomic rename to prevent partial writes |

### Atomic state writes

```lua
function save_state(task)
  local tmp = state_path .. ".tmp"
  local f = io.open(tmp, "w")
  f:write(json.encode(task))
  f:close()
  os.rename(tmp, state_path)  -- atomic on POSIX
end
```

---

## 15. `config.json` Schema

```json
{
  "$schema": "luallm-agent-config-v1",
  "allowed_paths": [
    "~/data",
    "~/output",
    "/tmp/luallm-*"
  ],
  "blocked_paths": [
    "~/.ssh",
    "~/.gnupg",
    "/etc",
    "/usr",
    "/var"
  ],
  "approvals": {
    "task_confirmation": "prompt",
    "path_read": "auto",
    "path_write": "prompt",
    "skill_promotion": "manual",
    "destructive_overwrite": "prompt",
    "network_access": "prompt"
  },
  "limits": {
    "max_task_steps": 50,
    "max_plan_retries": 2,
    "max_node_retries": 3,
    "max_skill_retries": 3,
    "llm_timeout_seconds": 120,
    "llm_backoff_base_seconds": 1,
    "llm_backoff_max_seconds": 60,
    "skill_exec_timeout_seconds": 30,
    "skill_memory_limit_mb": 50,
    "max_open_file_handles": 10,
    "model_start_timeout_seconds": 120
  },
  "audit": {
    "max_size_mb": 50,
    "max_files": 5
  },
  "luallm": {
    "binary": "luallm",
    "auto_start": false,
    "auto_stop": false
  },
  "model_selection": {
    "planning": {
      "prefer": ["llama3-70b-q4"],
      "fallback": ["llama3-8b-q4"]
    },
    "skill_generation": {
      "prefer": ["llama3-70b-q4"],
      "fallback": ["llama3-8b-q4"]
    },
    "simple_transform": {
      "prefer": ["llama3-8b-q4"],
      "fallback": []
    },
    "default": {
      "prefer": ["llama3-8b-q4"],
      "fallback": []
    }
  },
  "editor": "$EDITOR"
}
```

---

## 16. Deliverables & Build Order

Build order reflects dependency chains. Each module includes its tests.

| # | Module | File(s) | Depends on | Notes |
|---|--------|---------|------------|-------|
| 1 | **UUID** | `lib/uuid.lua` | — | Foundation; needed by everything |
| 2 | **JSON** | `lib/json.lua` (or vendor dkjson) | — | Foundation |
| 3 | **Audit logger** | `agent/audit.lua` | JSON, UUID | Append-only JSONL writer with rotation |
| 4 | **Config loader + validator** | `agent/config.lua` | JSON | Schema validation, path expansion |
| 5 | **`luallm` wrapper** | `agent/luallm.lua` | JSON, Config | CLI wrapper: `state()`, `notes()`, `start()`, `stop()`, `complete()`, `help()`. All `--json`. |
| 6 | **`init` command** | `cli/init.lua` | Config | Skeleton creation, permission setting |
| 7 | **`doctor` module** | `cli/doctor.lua` | Config, Audit, `luallm` wrapper | 15+ checks including model state and selection policy |
| 8 | **Sandbox** | `agent/sandbox.lua` | Config | `_ENV` builder, path-checked I/O, scoped require, resource limits |
| 9 | **Test framework** | `lib/luallm_test.lua` | JSON | Structured TAP-like output |
| 10 | **Skill loader** | `agent/skill_loader.lua` | Sandbox, Config | Metadata parser, dependency resolver |
| 11 | **Skill runner** | `agent/skill_runner.lua` | Sandbox, Skill loader, Test framework | Execute skill in sandbox, run tests, capture output |
| 12 | **Task graph** | `agent/graph.lua` | JSON | Schema validation, topological sort, execution engine |
| 13 | **LLM client** | `agent/llm_client.lua` | `luallm` wrapper, Config, Audit | Model selection, retry with backoff, OOM detection, fallback chain |
| 14 | **Approval manager** | `agent/approval.lua` | Config, Audit, JSON | CLI prompts, JSON state, tier enforcement |
| 15 | **State manager** | `agent/state.lua` | JSON, Audit | Atomic writes, recovery logic |
| 16 | **Orchestrator** | `agent/agent.lua` | All above | State machine, main loop |
| 17 | **CLI entry point** | `cli/main.lua` | Orchestrator | Arg parsing, command dispatch |
| 18 | **Sample skills** | `skills/agent/` | Test framework | `read_file`, `read_csv`, `write_file`, `exec_safe`, `write_markdown_report` |

---

## 17. Summary

This plan addresses:

- **`luallm` as the model layer**: The agent discovers models via `luallm state --json`, reads capabilities via `luallm notes --json`, starts/stops models via `luallm start/stop`, sends completions to running model ports, and uses `luallm help --json` for feature discovery. No model metadata is duplicated — `luallm` is the single source of truth.
- **Sandbox as real security**: Restricted `_ENV` with whitelisted globals, path-checked I/O, scoped require, and resource limits. Static analysis is a pre-check, not the enforcement layer.
- **Explicit task graph**: DAG with typed nodes, dependency tracking, per-node retry, and failure propagation. Generated by LLM in one shot with strict schema validation.
- **Bounded execution**: Retry limits, timeouts, backoff, and a global step budget prevent runaway loops or infinite token spend.
- **Full audit trail**: Append-only JSONL log covering every state transition, LLM call, `luallm` interaction, file access, and sandbox violation.
- **Skill versioning**: Metadata headers with version numbers, archive on update, version checked during approval.
- **Skill dependencies**: Declared in metadata, resolved from `allowed/` only, each dependency sandboxed independently.
- **Clear approval tiers**: Five tiers with explicit `--yes` behavior. Skill promotion is always manual, enforced regardless of config.
- **Config immutability**: `config.json` is in the same protection class as `skills/allowed/`.
- **Structured test output**: JSON results with per-test pass/fail, duration, and names — not just exit codes.
- **Model selection with fallback**: Config-driven preference and fallback chains, cross-referenced with live `luallm state` and human-authored `luallm notes`. OOM detection triggers fallback, not automatic note pollution.
- **Atomic state persistence**: Temp file + rename pattern prevents corruption on power loss.