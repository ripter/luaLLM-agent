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

return M

