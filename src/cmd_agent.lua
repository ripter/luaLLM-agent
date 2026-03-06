--- src/cmd_agent.lua
--- CLI wrapper for the agent: run, resume, reset, status.
--- Same thin-wrapper pattern as cmd_plan.lua / cmd_quick.lua.
---
--- deps (all optional, injected for tests):
---   agent   — agent module (.run, .resume)
---   state   — state module (.load, .save, .clear)
---   print   — print function (default _G.print)
---
--- All four public functions accept (deps, args) and return (result, err).

local _src = debug.getinfo(1, "S").source:match("^@(.*/)") or "./"
package.path = _src .. "?.lua;" .. package.path

local M = {}

-- ---------------------------------------------------------------------------
-- Default dependencies
-- ---------------------------------------------------------------------------

local function default_deps()
  local state  = require("state")
  local config = require("config")
  config.load()
  state.init(config.default_dir() .. "/state")
  return {
    agent = require("agent"),
    state = state,
    print = _G.print,
  }
end

local function resolve(deps)
  if type(deps) == "table" then return deps end
  return default_deps()
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function emit(deps, msg)
  local fn = deps.print or _G.print
  fn(msg)
end

local function fmt_history(history)
  local lines = {}
  for _, h in ipairs(history or {}) do
    local line = "  [" .. (h.ts or "?") .. "] " .. (h.status or "?")
    if h.detail and h.detail ~= "" then
      line = line .. " — " .. h.detail
    end
    lines[#lines + 1] = line
  end
  return lines
end

-- ---------------------------------------------------------------------------
-- cmd_agent.run — start a new task
-- ---------------------------------------------------------------------------

--- Start a new agent task from a prompt.
--- args = { prompt = "...", context_files = {...} }
function M.run(deps, args)
  deps = resolve(deps)
  args = args or {}

  local prompt = args.prompt
  if type(prompt) ~= "string" or prompt == "" then
    emit(deps, "cmd_agent.run: prompt is required")
    return nil, "cmd_agent.run: prompt is required"
  end

  emit(deps, "  Starting agent task: " .. prompt)

  local t = deps.agent.run(nil, prompt, {
    context_files = args.context_files or {},
  })

  if not t then
    emit(deps, "  Error: agent.run returned nil")
    return nil, "agent.run returned nil"
  end

  emit(deps, "  Task " .. (t.id or "?") .. " finished with status: " .. (t.status or "?"))

  if t.status == "awaiting_human" then
    -- The action-required message was already printed by the agent during execution.
    -- Just show a brief status line and the next step.
    emit(deps, "")
    emit(deps, "  ⚠  Task paused — action required.")
    if t.human_action then
      emit(deps, "     " .. t.human_action:gsub("\n", "\n     "))
    end
    emit(deps, "")
    emit(deps, "  Once done, run:  ./agent agent resume")
  elseif t.error then
    local err = t.error
    if t.status == "failed" and err:find("model not found in luallm state", 1, true) then
      emit(deps, "")
      emit(deps, "  ⚠  luallm is running but no model is loaded.")
      emit(deps, "     Open the luallm UI and load a model, then retry.")
      emit(deps, "  Raw error: " .. err)
    elseif t.status == "failed" and err:find("LLM call failed", 1, true) then
      emit(deps, "")
      emit(deps, "  ⚠  Could not reach luallm. Is the server running?")
      emit(deps, "     Run:  ./agent doctor   — to check your environment.")
      emit(deps, "  Raw error: " .. err)
    else
      emit(deps, "  Error: " .. err)
    end
  end

  return t
end

-- ---------------------------------------------------------------------------
-- cmd_agent.resume — resume a paused task
-- ---------------------------------------------------------------------------

--- Resume a paused (APPROVAL) task loaded from saved state.
function M.resume(deps, _args)
  deps = resolve(deps)

  -- Load task from state so we can print context before resuming.
  local t, load_err = deps.state.load()
  if not t then
    local msg = "cmd_agent.resume: no saved task — " .. tostring(load_err)
    emit(deps, "  " .. msg)
    return nil, msg
  end

  emit(deps, "  Resuming task " .. (t.id or "?")
       .. " (status: " .. (t.status or "?") .. ")")

  local result = deps.agent.resume(nil, t)

  if not result then
    emit(deps, "  Error: agent.resume returned nil")
    return nil, "agent.resume returned nil"
  end

  emit(deps, "  Task status after resume: " .. (result.status or "?"))
  return result
end

-- ---------------------------------------------------------------------------
-- cmd_agent.reset — clear saved task state
-- ---------------------------------------------------------------------------

--- Clear any saved task state.
function M.reset(deps, _args)
  deps = resolve(deps)

  local ok, err = deps.state.clear()
  if not ok then
    local msg = "cmd_agent.reset: state.clear failed — " .. tostring(err)
    emit(deps, "  " .. msg)
    return nil, msg
  end

  emit(deps, "  Agent state cleared.")
  return true
end

-- ---------------------------------------------------------------------------
-- cmd_agent.status — print current task status
-- ---------------------------------------------------------------------------

--- Load and print the current task status and history.
function M.status(deps, _args)
  deps = resolve(deps)

  local t, load_err = deps.state.load()
  if not t then
    local msg = "cmd_agent.status: no saved task — " .. tostring(load_err)
    emit(deps, "  " .. msg)
    return nil, msg
  end

  emit(deps, "  Task:    " .. (t.id     or "?"))
  emit(deps, "  Prompt:  " .. (t.prompt or "?"))
  emit(deps, "  Status:  " .. (t.status or "?"))
  if t.status == "awaiting_human" and t.human_action then
    emit(deps, "")
    emit(deps, "  ⚠  Waiting for you to:")
    emit(deps, "     " .. t.human_action:gsub("\n", "\n     "))
    emit(deps, "")
    emit(deps, "  Then run:  ./agent agent resume")
    emit(deps, "")
  end
  if t.error and t.status ~= "awaiting_human" then
    emit(deps, "  Error:   " .. t.error)
  end

  local history_lines = fmt_history(t.history)
  if #history_lines > 0 then
    emit(deps, "  History:")
    for _, line in ipairs(history_lines) do
      emit(deps, line)
    end
  end

  return t
end

return M
