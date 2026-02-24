--- src/luallm.test.lua
--- Busted tests for src/luallm.lua
--- All tests are offline: io.popen, socket.http.request are stubbed.

local cjson = require("cjson.safe")

-- Make sure busted can find src/ modules regardless of invocation directory.
local src_dir = debug.getinfo(1, "S").source:match("^@(.*/)") or "./"
package.path = src_dir .. "?.lua;" .. package.path

-- Load the modules under test.
local luallm = require("luallm")
local http   = require("socket.http")
local ltn12  = require("ltn12")

-- ---------------------------------------------------------------------------
-- Stub helpers
-- ---------------------------------------------------------------------------

--- Replace a field on a table, returning a function that restores the original.
local function stub(tbl, key, replacement)
  local original = tbl[key]
  tbl[key] = replacement
  return function() tbl[key] = original end
end

--- Build a fake io.popen that returns `output` as stdout.
--- Also captures the command string into `captured.cmd`.
local function make_popen_stub(output, captured)
  return function(cmd)
    if captured then captured.cmd = cmd end
    return {
      read  = function(_, _) return output end,
      close = function(_) return true end,
    }
  end
end

--- Build a fake http.request that:
---   - stores the request options into `captured`
---   - returns (1, status, {}, status_line) with `resp_body` fed into the sink
local function make_http_stub(resp_body, status, captured)
  status = status or 200
  return function(opts)
    if captured then
      -- Drain the source so we can inspect the body that was sent.
      local chunks = {}
      if opts.source then
        local chunk, err = opts.source()
        while chunk do
          chunks[#chunks + 1] = chunk
          chunk, err = opts.source()
        end
      end
      captured.url     = opts.url
      captured.method  = opts.method
      captured.headers = opts.headers
      captured.body    = table.concat(chunks)
    end
    -- Feed response body into the caller's ltn12 sink.
    if opts.sink and resp_body then
      opts.sink(resp_body)
    end
    return 1, status, {}, "HTTP/1.1 " .. status .. " OK"
  end
end

-- ---------------------------------------------------------------------------
-- Tests: luallm.exec
-- ---------------------------------------------------------------------------

describe("luallm.exec", function()

  local restore_popen

  after_each(function()
    if restore_popen then restore_popen(); restore_popen = nil end
  end)

  it("appends --json when not already present", function()
    local cap = {}
    restore_popen = stub(_G, "io", setmetatable({}, {
      __index = function(_, k)
        if k == "popen" then return make_popen_stub('{"ok":true}', cap) end
        return io[k]  -- fall through to real io for other keys
      end
    }))
    -- Override just io.popen directly for simplicity.
    restore_popen()  -- undo the table trick
    local orig = io.popen
    io.popen = make_popen_stub('{"ok":true}', cap)
    restore_popen = function() io.popen = orig end

    local result, err = luallm.exec("status")
    assert.is_nil(err)
    assert.is_truthy(result)
    assert.is_truthy(cap.cmd:find("%-%-json"), "command should contain --json")
  end)

  it("does not duplicate --json if already present", function()
    local cap = {}
    local orig = io.popen
    io.popen = make_popen_stub('{"ok":true}', cap)
    restore_popen = function() io.popen = orig end

    luallm.exec("status", "--json")
    local _, count = cap.cmd:gsub("%-%-json", "")
    assert.equals(1, count, "should only have one --json flag")
  end)

  it("returns a decoded Lua table on valid JSON output", function()
    local orig = io.popen
    io.popen = make_popen_stub('{"status":"running","count":3}')
    restore_popen = function() io.popen = orig end

    local result, err = luallm.exec("status")
    assert.is_nil(err)
    assert.are.same({ status = "running", count = 3 }, result)
  end)

  it("returns (nil, err) on invalid JSON output", function()
    local orig = io.popen
    io.popen = make_popen_stub("not valid json {{{{")
    restore_popen = function() io.popen = orig end

    local result, err = luallm.exec("status")
    assert.is_nil(result)
    assert.is_truthy(err)
    assert.is_truthy(err:find("JSON parse error"), "error should mention JSON parse")
  end)

  it("returns (nil, err) on empty output", function()
    local orig = io.popen
    io.popen = make_popen_stub("")
    restore_popen = function() io.popen = orig end

    local result, err = luallm.exec("status")
    assert.is_nil(result)
    assert.is_truthy(err)
  end)

  it("builds the command from multiple args", function()
    local cap = {}
    local orig = io.popen
    io.popen = make_popen_stub('{"ok":true}', cap)
    restore_popen = function() io.popen = orig end

    luallm.exec("run", "mymodel", "--preset", "cold-start")
    assert.is_truthy(cap.cmd:find("run"),         "cmd should include 'run'")
    assert.is_truthy(cap.cmd:find("mymodel"),     "cmd should include 'mymodel'")
    assert.is_truthy(cap.cmd:find("cold%-start"), "cmd should include 'cold-start'")
    assert.is_truthy(cap.cmd:find("%-%-json"),    "cmd should include '--json'")
  end)

end)

-- ---------------------------------------------------------------------------
-- Tests: luallm.state
-- ---------------------------------------------------------------------------

describe("luallm.state", function()

  local restore_exec

  after_each(function()
    if restore_exec then restore_exec(); restore_exec = nil end
  end)

  it("returns the table from exec untouched", function()
    local fake_state = { models = { { name = "llama3", port = 8080 } } }
    restore_exec = stub(luallm, "exec", function(...)
      return fake_state, nil
    end)

    local result, err = luallm.state()
    assert.is_nil(err)
    assert.are.same(fake_state, result)
  end)

  it("propagates exec errors", function()
    restore_exec = stub(luallm, "exec", function(...)
      return nil, "binary not found"
    end)

    local result, err = luallm.state()
    assert.is_nil(result)
    assert.is_truthy(err:find("binary not found"))
  end)

  it("calls exec with 'state' as the first argument", function()
    local called_with = {}
    restore_exec = stub(luallm, "exec", function(...)
      called_with = { ... }
      return {}, nil
    end)

    luallm.state()
    assert.equals("status", called_with[1])
  end)

end)

-- ---------------------------------------------------------------------------
-- Tests: luallm.complete
-- ---------------------------------------------------------------------------

describe("luallm.complete", function()

  local restore_state
  local restore_http

  local function stub_state(model_list_or_table)
    restore_state = stub(luallm, "state", function()
      return model_list_or_table, nil
    end)
  end

  after_each(function()
    if restore_state then restore_state(); restore_state = nil end
    if restore_http  then restore_http();  restore_http  = nil end
  end)

  -- Happy path -----------------------------------------------------------------

  it("calls the correct URL for the named model", function()
    stub_state({ models = { { name = "foo", port = 1234 } } })
    local cap = {}
    local resp = cjson.encode({ choices = { { message = { content = "hi" } } } })
    restore_http = stub(http, "request", make_http_stub(resp, 200, cap))

    local result, err = luallm.complete("foo", { { role = "user", content = "hello" } })
    assert.is_nil(err)
    assert.equals("http://127.0.0.1:1234/v1/chat/completions", cap.url)
  end)

  it("uses POST method", function()
    stub_state({ models = { { name = "foo", port = 1234 } } })
    local cap = {}
    local resp = cjson.encode({ choices = {} })
    restore_http = stub(http, "request", make_http_stub(resp, 200, cap))

    luallm.complete("foo", {})
    assert.equals("POST", cap.method)
  end)

  it("sends JSON body containing model and messages", function()
    stub_state({ models = { { name = "foo", port = 1234 } } })
    local cap = {}
    local resp = cjson.encode({ choices = {} })
    restore_http = stub(http, "request", make_http_stub(resp, 200, cap))

    local messages = { { role = "user", content = "ping" } }
    luallm.complete("foo", messages)

    local body, decode_err = cjson.decode(cap.body)
    assert.is_nil(decode_err)
    assert.equals("foo", body.model)
    assert.equals("user", body.messages[1].role)
    assert.equals("ping", body.messages[1].content)
  end)

  it("merges options fields into the request body", function()
    stub_state({ models = { { name = "foo", port = 1234 } } })
    local cap = {}
    local resp = cjson.encode({ choices = {} })
    restore_http = stub(http, "request", make_http_stub(resp, 200, cap))

    luallm.complete("foo", {}, { temperature = 0.7, max_tokens = 100 })

    local body = cjson.decode(cap.body)
    assert.equals(0.7, body.temperature)
    assert.equals(100, body.max_tokens)
  end)

  it("parses the JSON response into a Lua table", function()
    stub_state({ models = { { name = "foo", port = 1234 } } })
    local expected = { choices = { { message = { role = "assistant", content = "pong" } } } }
    local resp = cjson.encode(expected)
    restore_http = stub(http, "request", make_http_stub(resp, 200))

    local result, err = luallm.complete("foo", {})
    assert.is_nil(err)
    assert.equals("pong", result.choices[1].message.content)
  end)

  it("sets Content-Type and Accept headers", function()
    stub_state({ models = { { name = "foo", port = 1234 } } })
    local cap = {}
    local resp = cjson.encode({ choices = {} })
    restore_http = stub(http, "request", make_http_stub(resp, 200, cap))

    luallm.complete("foo", {})
    assert.equals("application/json", cap.headers["Content-Type"])
    assert.equals("application/json", cap.headers["Accept"])
  end)

  -- State shape variants -------------------------------------------------------

  it("finds model in state.running_models", function()
    stub_state({ running_models = { { name = "bar", port = 5678 } } })
    local cap = {}
    local resp = cjson.encode({ choices = {} })
    restore_http = stub(http, "request", make_http_stub(resp, 200, cap))

    local _, err = luallm.complete("bar", {})
    assert.is_nil(err)
    assert.is_truthy(cap.url:find("5678"))
  end)

  it("finds model when state is a bare array", function()
    stub_state({ { name = "baz", port = 9999 } })
    local cap = {}
    local resp = cjson.encode({ choices = {} })
    restore_http = stub(http, "request", make_http_stub(resp, 200, cap))

    local _, err = luallm.complete("baz", {})
    assert.is_nil(err)
    assert.is_truthy(cap.url:find("9999"))
  end)

  -- Error paths ----------------------------------------------------------------

  it("returns (nil, err) when model is not in state", function()
    stub_state({ models = { { name = "other", port = 1234 } } })

    local result, err = luallm.complete("nonexistent", {})
    assert.is_nil(result)
    assert.is_truthy(err)
    assert.is_truthy(err:find("not found") or err:find("nonexistent"),
      "error should name the missing model")
  end)

  it("returns (nil, err) when state() fails", function()
    restore_state = stub(luallm, "state", function()
      return nil, "daemon not running"
    end)

    local result, err = luallm.complete("foo", {})
    assert.is_nil(result)
    assert.is_truthy(err:find("daemon not running"))
  end)

  it("returns (nil, err) on non-2xx HTTP status", function()
    stub_state({ models = { { name = "foo", port = 1234 } } })
    restore_http = stub(http, "request", make_http_stub('{"error":"overloaded"}', 503))

    local result, err = luallm.complete("foo", {})
    assert.is_nil(result)
    assert.is_truthy(err)
    assert.is_truthy(err:find("503"), "error should mention HTTP status")
  end)

  it("returns (nil, err) on HTTP connection failure", function()
    stub_state({ models = { { name = "foo", port = 1234 } } })
    restore_http = stub(http, "request", function(_)
      return nil, "connection refused"
    end)

    local result, err = luallm.complete("foo", {})
    assert.is_nil(result)
    assert.is_truthy(err:find("connection refused"))
  end)

  it("returns (nil, err) when response body is not valid JSON", function()
    stub_state({ models = { { name = "foo", port = 1234 } } })
    restore_http = stub(http, "request", make_http_stub("not json", 200))

    local result, err = luallm.complete("foo", {})
    assert.is_nil(result)
    assert.is_truthy(err:find("JSON decode failed"))
  end)

end)
