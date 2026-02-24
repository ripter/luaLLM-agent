--- src/cmd_quick.lua
--- Logic for the `quick-prompt` command.

local M = {}

-- ---------------------------------------------------------------------------
-- Model resolution
-- ---------------------------------------------------------------------------

--- Pick the best model+port from a status response.
--- Priority: config luallm.model > first running server > state.last_used.
--- Returns (model_name, port_or_nil).
local function resolve_model(state, config)
  -- 1. Config explicit model.
  local cfg_ok, cfg_model = pcall(config.get, "luallm.model")
  if cfg_ok and type(cfg_model) == "string" and cfg_model ~= "" then
    return cfg_model, nil
  end

  -- 2. First running server.
  for _, entry in ipairs(state.servers or {}) do
    if entry.state == "running" and (entry.model or entry.name) and entry.port then
      return entry.model or entry.name, math.floor(entry.port)
    end
  end

  -- 3. last_used fallback — look up its port in the servers list.
  if type(state.last_used) == "string" and state.last_used ~= "" then
    for _, entry in ipairs(state.servers or {}) do
      if (entry.model or entry.name) == state.last_used and entry.port then
        return state.last_used, math.floor(entry.port)
      end
    end
    -- last_used known but no port — return name and let complete() find port.
    return state.last_used, nil
  end

  return nil, nil
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Run the quick-prompt command.
---
--- deps = { luallm, config }
--- args = { prompt }
---
--- Returns (content_string, info_table) on success or (nil, error_string) on failure.
--- info_table = { model }
function M.run(deps, args)
  local luallm = deps.luallm
  local config = deps.config

  pcall(config.load)

  local state, state_err = luallm.state()
  if not state then
    return nil, "could not reach luallm: " .. tostring(state_err)
  end

  local model, port = resolve_model(state, config)
  if not model then
    return nil, "no running model found in luallm status"
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

  return content_text, { model = model }
end

return M
