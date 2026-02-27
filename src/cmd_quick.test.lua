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
    resolve_model = function(state)
      -- Mirror the real resolve_model priority logic for the stub.
      local cfg_ok, cfg_model = pcall(config.get, "luallm.model")
      if cfg_ok and type(cfg_model) == "string" and cfg_model ~= "" then
        return cfg_model, nil
      end
      for _, entry in ipairs(state.servers or {}) do
        if entry.state == "running" and (entry.model or entry.name) and entry.port then
          return entry.model or entry.name, entry.port
        end
      end
      if type(state.last_used) == "string" and state.last_used ~= "" then
        for _, entry in ipairs(state.servers or {}) do
          if (entry.model or entry.name) == state.last_used and entry.port then
            return state.last_used, entry.port
          end
        end
        return state.last_used, nil
      end
      return nil, nil
    end,
    start = function()
      if overrides.start_err then return nil, overrides.start_err end
      return true
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

  it("falls back to state.last_used when it is running and no config model", function()
    local captured_model
    local deps = make_deps({
      state_resp = {
        servers   = { { model = "last-model", port = 8080, state = "running" } },
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

  it("returns nil + actionable error when server not running and auto_start disabled", function()
    local deps = make_deps({ state_err = "connection refused" })

    local content, err = cmd_quick.run(deps, { prompt = "hi" })

    assert.is_nil(content)
    assert.is_truthy(err:find("not running", 1, true))
    assert.is_truthy(err:find("luallm start", 1, true))
    assert.is_truthy(err:find("auto_start",   1, true))
  end)

  it("auto-starts luallm when state() fails and auto_start=true", function()
    local start_called = false
    local deps = make_deps({
      config_store = { ["luallm.auto_start"] = true },
      state_err    = "daemon not running",
    })
    deps.luallm.start = function()
      start_called = true
      -- After start, state() should succeed — swap the implementation.
      deps.luallm.state = function()
        return {
          servers   = { { model = "auto-model", port = 8080, state = "running" } },
          last_used = "auto-model",
        }, nil
      end
      return true
    end

    local content, info = cmd_quick.run(deps, { prompt = "hi" })

    assert.is_true(start_called, "start() should have been called")
    assert.is_not_nil(content, "should succeed after auto-start")
    assert.is_true(info.started, "info.started should be true")
  end)

  it("returns error when auto_start=true but start() fails", function()
    local deps = make_deps({
      config_store = { ["luallm.auto_start"] = true },
      state_err    = "daemon not running",
      start_err    = "no models configured",
    })

    local content, err = cmd_quick.run(deps, { prompt = "hi" })

    assert.is_nil(content)
    assert.is_truthy(err:find("auto-start failed", 1, true))
    assert.is_truthy(err:find("no models configured", 1, true))
  end)

  it("info.started is false on a normal run without auto-start", function()
    local deps = make_deps({ complete_resp = fake_response("ok") })

    local content, info = cmd_quick.run(deps, { prompt = "hi" })

    assert.is_not_nil(content)
    assert.is_false(info.started)
  end)

end)
