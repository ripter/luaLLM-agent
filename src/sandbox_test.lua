--- src/sandbox_test.lua
--- Busted tests for src/sandbox.lua

local lfs = require("lfs")

local _src = debug.getinfo(1, "S").source:match("^@(.*/)") or "./"
package.path = _src .. "?.lua;" .. package.path

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local cwd      = lfs.currentdir()
local TEST_DIR = cwd .. "/sandbox_test_" .. tostring(os.time())

--- Set up a temp directory tree for tests.
local function setup_dir()
  lfs.mkdir(TEST_DIR)
  lfs.mkdir(TEST_DIR .. "/allowed")
  lfs.mkdir(TEST_DIR .. "/forbidden")
  lfs.mkdir(TEST_DIR .. "/deps")
end

--- Write content to a file.
local function write_file(path, content)
  local f = assert(io.open(path, "w"))
  f:write(content)
  f:close()
end

--- Read entire file to string.
local function read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local c = f:read("*a")
  f:close()
  return c
end

--- Cleanup everything.
local function cleanup()
  os.execute("rm -rf " .. TEST_DIR)
end

--- Fresh sandbox module (reset cached state between tests).
local function fresh_sandbox()
  package.loaded["sandbox"] = nil
  return require("sandbox")
end

-- ---------------------------------------------------------------------------
-- Top-level setup / teardown
-- ---------------------------------------------------------------------------

setup(function()
  setup_dir()
  -- Create test fixtures
  write_file(TEST_DIR .. "/allowed/hello.txt", "hello world\n")
  write_file(TEST_DIR .. "/allowed/data.csv",  "a,b,c\n1,2,3\n")
  write_file(TEST_DIR .. "/forbidden/secret.txt", "top secret\n")
  -- Dependency modules
  write_file(TEST_DIR .. "/deps/greeter.lua", [[
local G = {}
function G.greet(name) return "hello " .. name end
return G
]])
  write_file(TEST_DIR .. "/deps/bad_syntax.lua", "this is not valid lua {{{{")
end)

teardown(cleanup)

-- ---------------------------------------------------------------------------
-- sandbox.make_io
-- ---------------------------------------------------------------------------

describe("sandbox.make_io", function()

  it("opens a file that is in both declared and allowed paths", function()
    local sandbox = fresh_sandbox()
    local sio = sandbox.make_io(
      { TEST_DIR .. "/allowed" },
      { TEST_DIR .. "/allowed" },
      nil, "test-skill"
    )

    local fh, err = sio.open(TEST_DIR .. "/allowed/hello.txt", "r")
    assert.is_truthy(fh, tostring(err))
    local content = fh:read("*a")
    sio.close(fh)
    assert.equals("hello world\n", content)
  end)

  it("rejects a path not in declared paths", function()
    local sandbox = fresh_sandbox()
    local sio = sandbox.make_io(
      { TEST_DIR .. "/allowed" },
      { TEST_DIR .. "/allowed", TEST_DIR .. "/forbidden" },
      nil, "test-skill"
    )

    local fh, err = sio.open(TEST_DIR .. "/forbidden/secret.txt", "r")
    assert.is_nil(fh)
    assert.is_truthy(err:find("declared paths"))
  end)

  it("rejects a path not in allowed paths", function()
    local sandbox = fresh_sandbox()
    local sio = sandbox.make_io(
      { TEST_DIR .. "/allowed", TEST_DIR .. "/forbidden" },
      { TEST_DIR .. "/allowed" },
      nil, "test-skill"
    )

    local fh, err = sio.open(TEST_DIR .. "/forbidden/secret.txt", "r")
    assert.is_nil(fh)
    assert.is_truthy(err:find("allowed_paths"))
  end)

  it("enforces the open handle limit", function()
    local sandbox = fresh_sandbox()
    local sio = sandbox.make_io(
      { TEST_DIR .. "/allowed" },
      { TEST_DIR .. "/allowed" },
      nil, "test-skill"
    )

    local handles = {}
    -- Open MAX handles
    for i = 1, 10 do
      local fh, err = sio.open(TEST_DIR .. "/allowed/hello.txt", "r")
      assert.is_truthy(fh, "handle " .. i .. " should open: " .. tostring(err))
      handles[#handles + 1] = fh
    end

    -- 11th should fail
    local fh, err = sio.open(TEST_DIR .. "/allowed/hello.txt", "r")
    assert.is_nil(fh)
    assert.is_truthy(err:find("too many open handles"))

    -- Close one and try again
    sio.close(handles[1])
    fh, err = sio.open(TEST_DIR .. "/allowed/hello.txt", "r")
    assert.is_truthy(fh, tostring(err))
    sio.close(fh)

    -- Cleanup remaining
    for i = 2, #handles do sio.close(handles[i]) end
  end)

  it("lines() returns an iterator over file lines", function()
    local sandbox = fresh_sandbox()
    local sio = sandbox.make_io(
      { TEST_DIR .. "/allowed" },
      { TEST_DIR .. "/allowed" },
      nil, "test-skill"
    )

    local iter, err = sio.lines(TEST_DIR .. "/allowed/data.csv")
    assert.is_truthy(iter, tostring(err))

    local lines = {}
    for line in iter do
      lines[#lines + 1] = line
    end

    assert.equals(2, #lines)
    assert.equals("a,b,c", lines[1])
    assert.equals("1,2,3", lines[2])
  end)

  it("lines() rejects paths not in declared paths", function()
    local sandbox = fresh_sandbox()
    local sio = sandbox.make_io(
      { TEST_DIR .. "/allowed" },
      { TEST_DIR .. "/allowed" },
      nil, "test-skill"
    )

    local iter, err = sio.lines(TEST_DIR .. "/forbidden/secret.txt")
    assert.is_nil(iter)
    assert.is_truthy(err:find("declared paths"))
  end)

  it("calls log_fn on file access", function()
    local sandbox = fresh_sandbox()
    local log_calls = {}
    local function mock_log(event, data)
      log_calls[#log_calls + 1] = { event = event, data = data }
    end

    local sio = sandbox.make_io(
      { TEST_DIR .. "/allowed" },
      { TEST_DIR .. "/allowed" },
      mock_log, "my-skill"
    )

    local fh = sio.open(TEST_DIR .. "/allowed/hello.txt", "r")
    sio.close(fh)

    assert.equals(1, #log_calls)
    assert.equals("sandbox.io.access", log_calls[1].event)
    assert.equals("my-skill",          log_calls[1].data.skill)
    assert.equals("r",                 log_calls[1].data.mode)
  end)

  it("rejects an empty path", function()
    local sandbox = fresh_sandbox()
    local sio = sandbox.make_io({ "/" }, { "/" }, nil, "test")
    local fh, err = sio.open("", "r")
    assert.is_nil(fh)
    assert.is_truthy(err:find("invalid path"))
  end)

end)

-- ---------------------------------------------------------------------------
-- sandbox.make_require
-- ---------------------------------------------------------------------------

describe("sandbox.make_require", function()

  it("loads a declared dependency from allowed_dir", function()
    local sandbox = fresh_sandbox()
    local req = sandbox.make_require({ "greeter" }, TEST_DIR .. "/deps")

    local greeter = req("greeter")
    assert.is_truthy(greeter)
    assert.equals("hello Alice", greeter.greet("Alice"))
  end)

  it("caches modules on repeated require", function()
    local sandbox = fresh_sandbox()
    local req = sandbox.make_require({ "greeter" }, TEST_DIR .. "/deps")

    local a = req("greeter")
    local b = req("greeter")
    assert.equals(a, b)
  end)

  it("rejects a module not in declared dependencies", function()
    local sandbox = fresh_sandbox()
    local req = sandbox.make_require({ "greeter" }, TEST_DIR .. "/deps")

    local ok, err = pcall(req, "os")
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("not in declared dependencies"))
  end)

  it("errors when module file does not exist", function()
    local sandbox = fresh_sandbox()
    local req = sandbox.make_require({ "nonexistent" }, TEST_DIR .. "/deps")

    local ok, err = pcall(req, "nonexistent")
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("not found"))
  end)

  it("errors on module with syntax error", function()
    local sandbox = fresh_sandbox()
    local req = sandbox.make_require({ "bad_syntax" }, TEST_DIR .. "/deps")

    assert.has_error(function()
      req("bad_syntax")
    end)
  end)

  it("rejects empty module name", function()
    local sandbox = fresh_sandbox()
    local req = sandbox.make_require({ "greeter" }, TEST_DIR .. "/deps")

    local ok, err = pcall(req, "")
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("non-empty string", 1, true))
  end)

end)

-- ---------------------------------------------------------------------------
-- sandbox.make_env
-- ---------------------------------------------------------------------------

describe("sandbox.make_env", function()

  it("includes all whitelisted globals", function()
    local sandbox = fresh_sandbox()
    local env = sandbox.make_env()

    local expected = {
      "math", "string", "table", "pairs", "ipairs", "next",
      "select", "type", "tostring", "tonumber", "pcall", "xpcall",
      "error", "assert", "unpack",
    }
    for _, name in ipairs(expected) do
      assert.is_truthy(env[name], name .. " must be in env")
    end
  end)

  it("does NOT include blocked globals", function()
    local sandbox = fresh_sandbox()
    local env = sandbox.make_env()

    local blocked = {
      "os", "debug", "load", "loadstring", "loadfile", "dofile",
      "rawget", "rawset", "rawequal", "collectgarbage", "setfenv", "getfenv",
    }
    for _, name in ipairs(blocked) do
      assert.is_nil(env[name], name .. " must NOT be in env")
    end
  end)

  it("provides a restricted io table (not raw io)", function()
    local sandbox = fresh_sandbox()
    local env = sandbox.make_env()

    assert.is_truthy(env.io)
    assert.is_truthy(env.io.open)
    assert.is_truthy(env.io.lines)
    assert.is_truthy(env.io.close)
    -- Must not be the raw global io
    assert.not_equals(io, env.io)
  end)

  it("provides a restricted require function", function()
    local sandbox = fresh_sandbox()
    local env = sandbox.make_env()

    assert.is_truthy(env.require)
    assert.not_equals(require, env.require)
  end)

  it("print captures output", function()
    local sandbox = fresh_sandbox()
    local env = sandbox.make_env()

    env.print("hello", "world")
    env.print("line 2")

    assert.equals(2, #env._captured_output)
    assert.equals("hello\tworld", env._captured_output[1])
    assert.equals("line 2",      env._captured_output[2])
  end)

  it("includes log_fn as log when provided", function()
    local sandbox = fresh_sandbox()
    local called = false
    local env = sandbox.make_env({
      log_fn = function() called = true end,
    })

    assert.is_truthy(env.log)
    env.log("test", {})
    assert.is_true(called)
  end)

  it("log is nil when no log_fn provided", function()
    local sandbox = fresh_sandbox()
    local env = sandbox.make_env()
    assert.is_nil(env.log)
  end)

end)

-- ---------------------------------------------------------------------------
-- sandbox.execute
-- ---------------------------------------------------------------------------

describe("sandbox.execute", function()

  it("executes simple code and returns result", function()
    local sandbox = fresh_sandbox()
    local env = sandbox.make_env()

    local ok, result = sandbox.execute("return 1 + 2", env)
    assert.is_true(ok)
    assert.equals(3, result)
  end)

  it("code can use whitelisted globals", function()
    local sandbox = fresh_sandbox()
    local env = sandbox.make_env()

    local ok, result = sandbox.execute([[
      local t = {3, 1, 2}
      table.sort(t)
      return t[1] .. t[2] .. t[3]
    ]], env)
    assert.is_true(ok)
    assert.equals("123", result)
  end)

  it("code cannot access os", function()
    local sandbox = fresh_sandbox()
    local env = sandbox.make_env()

    local ok, err = sandbox.execute("return os.time()", env)
    assert.is_nil(ok)
    assert.is_truthy(err:find("runtime error"))
  end)

  it("code cannot access debug", function()
    local sandbox = fresh_sandbox()
    local env = sandbox.make_env()

    local ok, err = sandbox.execute("return debug.getinfo(1)", env)
    assert.is_nil(ok)
    assert.is_truthy(err:find("runtime error"))
  end)

  it("code cannot call rawget/rawset", function()
    local sandbox = fresh_sandbox()
    local env = sandbox.make_env()

    local ok, err = sandbox.execute("return rawget({}, 'x')", env)
    assert.is_nil(ok)
    assert.is_truthy(err:find("runtime error"))
  end)

  it("returns error for syntax errors", function()
    local sandbox = fresh_sandbox()
    local env = sandbox.make_env()

    local ok, err = sandbox.execute("this is not valid lua {{{", env)
    assert.is_nil(ok)
    assert.is_truthy(err:find("compilation failed"))
  end)

  it("returns error for runtime errors", function()
    local sandbox = fresh_sandbox()
    local env = sandbox.make_env()

    local ok, err = sandbox.execute("error('boom')", env)
    assert.is_nil(ok)
    assert.is_truthy(err:find("runtime error"))
    assert.is_truthy(err:find("boom"))
  end)

  it("times out on infinite loops", function()
    local sandbox = fresh_sandbox()
    local env = sandbox.make_env()

    -- Use a very short timeout
    local ok, err = sandbox.execute("while true do end", env, 0.05)
    assert.is_nil(ok)
    assert.is_truthy(err:find("timed out"))
  end)

  it("code can use print and output is captured", function()
    local sandbox = fresh_sandbox()
    local env = sandbox.make_env()

    local ok = sandbox.execute([[
      print("line 1")
      print("line 2")
    ]], env)
    assert.is_true(ok)
    assert.equals(2, #env._captured_output)
    assert.equals("line 1", env._captured_output[1])
    assert.equals("line 2", env._captured_output[2])
  end)

  it("code can use the restricted io to read allowed files", function()
    local sandbox = fresh_sandbox()
    local env = sandbox.make_env({
      paths         = { TEST_DIR .. "/allowed" },
      allowed_paths = { TEST_DIR .. "/allowed" },
      skill_name    = "test-skill",
    })

    local ok, result = sandbox.execute([[
      local f = io.open("]] .. TEST_DIR .. [[/allowed/hello.txt", "r")
      local content = f:read("*a")
      io.close(f)
      return content
    ]], env)
    assert.is_true(ok, tostring(result))
    assert.equals("hello world\n", result)
  end)

  it("code cannot read forbidden files via restricted io", function()
    local sandbox = fresh_sandbox()
    local env = sandbox.make_env({
      paths         = { TEST_DIR .. "/allowed" },
      allowed_paths = { TEST_DIR .. "/allowed" },
      skill_name    = "test-skill",
    })

    local ok, err = sandbox.execute([[
      local f, e = io.open("]] .. TEST_DIR .. [[/forbidden/secret.txt", "r")
      if not f then error(e) end
      return f:read("*a")
    ]], env)
    assert.is_nil(ok)
    assert.is_truthy(err:find("declared paths"))
  end)

  it("code can use restricted require for declared deps", function()
    local sandbox = fresh_sandbox()
    local env = sandbox.make_env({
      dependencies = { "greeter" },
      allowed_dir  = TEST_DIR .. "/deps",
      skill_name   = "test-skill",
    })

    local ok, result = sandbox.execute([[
      local g = require("greeter")
      return g.greet("Bob")
    ]], env)
    assert.is_true(ok, tostring(result))
    assert.equals("hello Bob", result)
  end)

  it("code cannot require undeclared modules", function()
    local sandbox = fresh_sandbox()
    local env = sandbox.make_env({
      dependencies = {},
      allowed_dir  = TEST_DIR .. "/deps",
      skill_name   = "test-skill",
    })

    local ok, err = sandbox.execute([[
      local g = require("greeter")
    ]], env)
    assert.is_nil(ok)
    assert.is_truthy(err:find("not in declared dependencies"))
  end)

  it("returns error for non-string code", function()
    local sandbox = fresh_sandbox()
    local ok, err = sandbox.execute(42, {})
    assert.is_nil(ok)
    assert.is_truthy(err:find("code_string must be a string"))
  end)

  it("returns error for non-table env", function()
    local sandbox = fresh_sandbox()
    local ok, err = sandbox.execute("return 1", "not a table")
    assert.is_nil(ok)
    assert.is_truthy(err:find("env must be a table"))
  end)

  it("returns error for invalid timeout", function()
    local sandbox = fresh_sandbox()
    local ok, err = sandbox.execute("return 1", {}, -1)
    assert.is_nil(ok)
    assert.is_truthy(err:find("timeout_seconds must be a positive number"))
  end)

  it("result is nil when code returns nothing", function()
    local sandbox = fresh_sandbox()
    local env = sandbox.make_env()

    local ok, result = sandbox.execute("local x = 1", env)
    assert.is_true(ok)
    assert.is_nil(result)
  end)

  it("code can return tables", function()
    local sandbox = fresh_sandbox()
    local env = sandbox.make_env()

    local ok, result = sandbox.execute("return { a = 1, b = 2 }", env)
    assert.is_true(ok)
    assert.equals(1, result.a)
    assert.equals(2, result.b)
  end)

  it("debug.sethook is cleaned up after execution", function()
    local sandbox = fresh_sandbox()
    local env = sandbox.make_env()

    sandbox.execute("return 1", env, 1)

    -- After execute, no hook should remain
    local hook = debug.gethook()
    assert.is_nil(hook)
  end)

  it("debug.sethook is cleaned up even after timeout", function()
    local sandbox = fresh_sandbox()
    local env = sandbox.make_env()

    sandbox.execute("while true do end", env, 0.05)

    local hook = debug.gethook()
    assert.is_nil(hook)
  end)

end)
