--- src/cmd_quick.lua
--- Logic for the `quick-prompt` command.

local M = {}

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function M.run(deps, args)
  local luallm = deps.luallm
  local config = deps.config

  pcall(config.load)

  local state, state_err = luallm.state()
  if not state then
    return nil, "could not reach luallm: " .. tostring(state_err)
  end

  -- Use the shared resolve_model from luallm module
  local model, port = luallm.resolve_model(state)
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
