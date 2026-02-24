--- src/cmd_quick.test.lua
--- Busted tests for src/cmd_quick.lua

local _src = debug.getinfo(1, "S").source:match("^@(.*/)") or "./"
package.path = _src .. "?.lua;" .. package.path

local cmd_quick = require("cmd_quick")

-- ---------------------------------------------------------------------------
-- Stub helpers
-- ---------------------------------------------------------------------------

local function fake_response(content)
  return {
    choices = { { message = { role = "assistant", content = content } } },
  }
end

local function make_deps(overrides)
  overrides = overrides or {}

  local config_store = overrides.config_store or {}
  local config = {
    load = function() return true end,
    get  = function(key)
      if config_store[key] ~= nil then return config_store[key] end
      error("key not found: " .. key)
    end,
  }

  local state_resp = overrides.state_resp or {
    servers   = { { model = "auto-model", port = 8080, state = "running" } },
    last_used = "auto-model",
  }

  local complete_resp = overrides.complete_resp or fake_response("Hello!")
  local complete_err  = overrides.complete_err

  local luallm = {
    state = function()
      if overrides.state_err then return nil, overrides.state_err end
      return state_resp, nil
    end,
    complete = function(model, messages, options, port)
      if complete_err then return nil, complete_err end
      return complete_resp, nil
    end,
  }

  return { luallm = luallm, config = config }
end

-- ---------------------------------------------------------------------------
-- Tests
-- ---------------------------------------------------------------------------

describe("cmd_quick.run", function()

  it("returns completion content on success", function()
    local deps = make_deps({ complete_resp = fake_response("The answer is 42.") })

    local content, info = cmd_quick.run(deps, { prompt = "what is the answer?" })

    assert.equals("The answer is 42.", content)
    assert.is_truthy(info)
    assert.is_truthy(info.model)
  end)

  it("selects model from config luallm.model when present", function()
    local captured_model
    local deps = make_deps({
      config_store = { ["luallm.model"] = "pinned-model" },
      state_resp   = {
        servers   = { { model = "other-model", port = 8080, state = "running" } },
        last_used = "other-model",
      },
    })
    local orig = deps.luallm.complete
    deps.luallm.complete = function(model, messages, options, port)
      captured_model = model
      return orig(model, messages, options, port)
    end

    cmd_quick.run(deps, { prompt = "hi" })

    assert.equals("pinned-model", captured_model)
  end)

  it("falls back to first running server when no config model", function()
    local captured_model
    local deps = make_deps({
      state_resp = {
        servers = {
          { model = "stopped-model", port = 8080, state = "stopped"  },
          { model = "live-model",    port = 8081, state = "running"  },
        },
      },
    })
    local orig = deps.luallm.complete
    deps.luallm.complete = function(model, messages, options, port)
      captured_model = model
      return orig(model, messages, options, port)
    end

    cmd_quick.run(deps, { prompt = "hi" })

    assert.equals("live-model", captured_model)
  end)

  it("falls back to state.last_used when no running server and no config model", function()
    local captured_model
    local deps = make_deps({
      state_resp = {
        servers   = { { model = "last-model", port = 8080, state = "stopped" } },
        last_used = "last-model",
      },
    })
    local orig = deps.luallm.complete
    deps.luallm.complete = function(model, messages, options, port)
      captured_model = model
      return orig(model, messages, options, port)
    end

    cmd_quick.run(deps, { prompt = "hi" })

    assert.equals("last-model", captured_model)
  end)

  it("returns nil + error when state() fails", function()
    local deps = make_deps({ state_err = "daemon not running" })

    local content, err = cmd_quick.run(deps, { prompt = "hi" })

    assert.is_nil(content)
    assert.is_truthy(err:find("daemon not running"))
  end)

  it("returns nil + error when no model can be found", function()
    local deps = make_deps({
      state_resp = { servers = {}, last_used = nil },
    })

    local content, err = cmd_quick.run(deps, { prompt = "hi" })

    assert.is_nil(content)
    assert.is_truthy(err:find("no running model"))
  end)

  it("returns nil + error when complete() fails", function()
    local deps = make_deps({ complete_err = "connection refused" })

    local content, err = cmd_quick.run(deps, { prompt = "hi" })

    assert.is_nil(content)
    assert.is_truthy(err:find("connection refused"))
  end)

  it("returns nil + error on unexpected response shape", function()
    local deps = make_deps({ complete_resp = { something = "weird" } })

    local content, err = cmd_quick.run(deps, { prompt = "hi" })

    assert.is_nil(content)
    assert.is_truthy(err:find("unexpected response shape"))
  end)

end)
