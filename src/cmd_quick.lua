--- src/cmd_quick.lua
--- Logic for the `quick-prompt` command.

local M = {}

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Run the quick-prompt command.
---
--- deps = { luallm, config }
--- args = { prompt }
---
--- Returns (content_string, info_table) on success or (nil, error_string) on failure.
--- info_table = { model, started } where started=true if we auto-started luallm.
function M.run(deps, args)
  local luallm = deps.luallm
  local config = deps.config

  pcall(config.load)

  -- Read auto_start preference before doing anything network-related.
  local auto_start = false
  local ok_cfg, cfg_val = pcall(config.get, "luallm.auto_start")
  if ok_cfg and cfg_val == true then
    auto_start = true
  end

  local state, state_err = luallm.state()

  -- If the daemon isn't reachable and auto_start is enabled, try to start it.
  local server_started = false
  if not state and auto_start then
    local started, start_err = luallm.start()
    if not started then
      return nil, "luallm is not running and auto-start failed: " .. tostring(start_err)
                  .. "\n  Start it manually with: luallm start"
    end
    server_started = true
    -- Re-fetch state now that the server is up.
    state, state_err = luallm.state()
    if not state then
      return nil, "luallm started but status still unavailable: " .. tostring(state_err)
    end
  elseif not state then
    -- Server not running, auto_start disabled — give a clear, actionable message
    -- that also surfaces the underlying error so the user knows what went wrong.
    return nil, "luallm is not running: " .. tostring(state_err) .. "\n"
                .. "  Start it with:  luallm start\n"
                .. "  Or enable auto-start in config.json:  \"luallm\": { \"auto_start\": true }"
  end

  local model, port = luallm.resolve_model(state)
  if not model then
    return nil, "no running model found in luallm status\n"
                .. "  Start a model with: luallm start <model-name>"
  end

  local response, req_err = luallm.complete(model, {
    { role = "user", content = args.prompt },
  }, nil, port)

  if not response then
    return nil, "request failed: " .. tostring(req_err)
  end

  local content_text = response.choices
                   and response.choices[1]
                   and response.choices[1].message
                   and response.choices[1].message.content

  if not content_text then
    return nil, "unexpected response shape (no choices[1].message.content)"
  end

  return content_text, { model = model, started = server_started }
end

return M
