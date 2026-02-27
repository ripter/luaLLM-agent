--- src/cmd_quick.test.lua
--- Busted tests for src/cmd_quick.lua
local mocks = require("test.mocks")
local cmd_quick = require("cmd_quick")


describe("cmd_quick.run", function()
  before_each(function()
    mocks.reset_loaded()
  end)

  it("returns completion content on success", function()
    local deps = mocks.make_deps({ 
      luallm_overrides = {
        complete_resp = mocks.fake_response("The answer is 42.")
      }
    })

    local content, info = cmd_quick.run(deps, { prompt = "what is the answer?" })

    assert.equals("The answer is 42.", content)
    assert.is_truthy(info)
    assert.is_truthy(info.model)
  end)

  it("returns nil + error when state() fails", function()
    local deps = mocks.make_deps({
      luallm_overrides = { state_err = "daemon not running" }
    })

    local content, err = cmd_quick.run(deps, { prompt = "hi" })

    assert.is_nil(content)
    assert.is_truthy(err:find("daemon not running"))
  end)

  it("returns nil + error when complete() fails", function()
    local deps = mocks.make_deps({
      luallm_overrides = { complete_err = "connection refused" }
    })

    local content, err = cmd_quick.run(deps, { prompt = "hi" })

    assert.is_nil(content)
    assert.is_truthy(err:find("connection refused"))
  end)

  it("returns nil + error on unexpected response shape", function()
    local deps = mocks.make_deps({
      luallm_overrides = { complete_resp = { something = "weird" } }
    })

    local content, err = cmd_quick.run(deps, { prompt = "hi" })

    assert.is_nil(content)
    assert.is_truthy(err:find("unexpected response shape"))
  end)

end)
