--- src/cmd_generate.test.lua
--- Busted tests for src/cmd_generate.lua (no real server needed)

local _src = debug.getinfo(1, "S").source:match("^@(.*/)") or "./"
package.path = _src .. "?.lua;" .. package.path

local cmd_generate = require("cmd_generate")

-- ---------------------------------------------------------------------------
-- Stub helpers
-- ---------------------------------------------------------------------------

local function fake_response(content, usage)
  return {
    choices = { { message = { role = "assistant", content = content } } },
    usage   = usage,
  }
end

--- Build a minimal deps table with controllable stubs.
local function make_deps(overrides)
  overrides = overrides or {}

  local written = {}  -- captures write_file calls

  local config_store = overrides.config_store or {}
  local config = {
    load = function() return true end,
    get  = function(key)
      if config_store[key] ~= nil then return config_store[key] end
      error("config key not found: " .. key)
    end,
  }

  local state_resp = overrides.state_resp or {
    servers = { { model = "test-model", port = 8080, state = "running" } }
  }

  local complete_resp = overrides.complete_resp or fake_response("print('hi')\n")
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
    resolve_model = overrides.resolve_model or function()
      return overrides.model or "test-model", overrides.port
    end,
  }

  local validate_ok  = overrides.validate_ok
  local validate_err = overrides.validate_err
  if validate_ok == nil then validate_ok = true end

  local is_allowed_ok  = overrides.is_allowed_ok
  local is_allowed_err = overrides.is_allowed_err
  if is_allowed_ok == nil then is_allowed_ok = true end

  local write_ok  = overrides.write_ok
  local write_err = overrides.write_err
  if write_ok == nil then write_ok = true end

  local safe_fs = {
    validate_policy = function(allowed, blocked)
      if not validate_ok then return nil, validate_err or "policy invalid" end
      return true, nil
    end,
    is_allowed = function(path, allowed, blocked)
      if not is_allowed_ok then return false, is_allowed_err or "denied" end
      return true, nil
    end,
    write_file = function(path, content, allowed, blocked)
      written[#written + 1] = { path = path, content = content }
      if not write_ok then return nil, write_err or "write failed" end
      return true, nil
    end,
  }

  return { luallm = luallm, safe_fs = safe_fs, config = config }, written
end

-- ---------------------------------------------------------------------------
-- strip_fences tests
-- ---------------------------------------------------------------------------

describe("cmd_generate.strip_fences", function()

  -- Spec-required cases:
  -- input "```lua\nprint('hi')\n```"  => "print('hi')\n"
  -- input "```\nprint('hi')\n```"     => "print('hi')\n"

  it("strips ```lua fence (spec case)", function()
    local result = cmd_generate.strip_fences("```lua\nprint('hi')\n```")
    assert.equals("print('hi')\n", result)
  end)

  it("strips bare ``` fence (spec case)", function()
    local result = cmd_generate.strip_fences("```\nprint('hi')\n```")
    assert.equals("print('hi')\n", result)
  end)

  it("does not change plain code (no fences)", function()
    local input = "print('hello')\nreturn 42\n"
    assert.equals(input, cmd_generate.strip_fences(input))
  end)

  it("does not strip when only opening fence is present", function()
    local input = "```lua\nprint('hi')\n"
    assert.equals(input, cmd_generate.strip_fences(input))
  end)

  it("preserves multiline code inside fences", function()
    local inner = "local x = 1\nlocal y = 2\nreturn x + y"
    local input = "```lua\n" .. inner .. "\n```"
    -- inner has no trailing newline; strip_fences should add exactly one
    assert.equals(inner .. "\n", cmd_generate.strip_fences(input))
  end)

  it("handles other language tags (e.g. ```javascript)", function()
    local result = cmd_generate.strip_fences("```javascript\nconsole.log(1)\n```")
    assert.equals("console.log(1)\n", result)
  end)

  it("strips fences with trailing whitespace after closing ```", function()
    local result = cmd_generate.strip_fences("```lua\nx=1\n```   ")
    assert.equals("x=1\n", result)
  end)

  it("returns unchanged when first line is not a fence", function()
    local input = "-- a comment\nprint('hi')\n```"
    assert.equals(input, cmd_generate.strip_fences(input))
  end)

  it("does not modify single-line string (no newline at all)", function()
    local input = "print('hi')"
    assert.equals(input, cmd_generate.strip_fences(input))
  end)

end)

-- ---------------------------------------------------------------------------
-- cmd_generate.run tests
-- ---------------------------------------------------------------------------

describe("cmd_generate.run", function()

  it("uses default system prompt when config has no override", function()
    local captured_messages
    local deps, _ = make_deps({
      config_store = { allowed_paths = { "/tmp/*" }, blocked_paths = {} },
    })
    -- Wrap complete to capture messages
    local orig_complete = deps.luallm.complete
    deps.luallm.complete = function(model, messages, options, port)
      captured_messages = messages
      return orig_complete(model, messages, options, port)
    end

    cmd_generate.run(deps, { output_path = "/tmp/out.lua", prompt = "hello world" })

    assert.is_truthy(captured_messages)
    assert.equals("system", captured_messages[1].role)
    assert.equals(cmd_generate.DEFAULT_SYSTEM_PROMPT, captured_messages[1].content)
  end)

  it("uses overridden system prompt from config", function()
    local captured_messages
    local deps, _ = make_deps({
      config_store = {
        allowed_paths             = { "/tmp/*" },
        blocked_paths             = {},
        ["generate.system_prompt"] = "Custom prompt.",
      },
    })
    deps.luallm.complete = function(model, messages, options, port)
      captured_messages = messages
      return fake_response("x=1\n"), nil
    end

    cmd_generate.run(deps, { output_path = "/tmp/out.lua", prompt = "p" })

    assert.equals("Custom prompt.", captured_messages[1].content)
  end)

  it("sanitizer strips fences by default", function()
    local deps, written = make_deps({
      config_store  = { allowed_paths = { "/tmp/*" }, blocked_paths = {} },
      complete_resp = fake_response("```lua\nprint('hi')\n```"),
    })

    cmd_generate.run(deps, { output_path = "/tmp/out.lua", prompt = "p" })

    assert.equals("print('hi')\n", written[1].content)
  end)

  it("sanitizer strips bare ``` fences", function()
    local deps, written = make_deps({
      config_store  = { allowed_paths = { "/tmp/*" }, blocked_paths = {} },
      complete_resp = fake_response("```\nprint('hi')\n```"),
    })

    cmd_generate.run(deps, { output_path = "/tmp/out.lua", prompt = "p" })

    assert.equals("print('hi')\n", written[1].content)
  end)

  it("sanitizer disabled via generate.sanitize_fences = false", function()
    local fenced = "```lua\nprint('hi')\n```"
    local deps, written = make_deps({
      config_store  = {
        allowed_paths                 = { "/tmp/*" },
        blocked_paths                 = {},
        ["generate.sanitize_fences"]  = false,
      },
      complete_resp = fake_response(fenced),
    })

    cmd_generate.run(deps, { output_path = "/tmp/out.lua", prompt = "p" })

    assert.equals(fenced, written[1].content)
  end)

  it("returns error when validate_policy fails, never calls write_file", function()
    local deps, written = make_deps({
      validate_ok  = false,
      validate_err = "overlap detected",
    })

    local ok, err = cmd_generate.run(deps, { output_path = "/tmp/out.lua", prompt = "p" })

    assert.is_nil(ok)
    assert.is_truthy(err:find("overlap detected"))
    assert.equals(0, #written, "write_file must not be called when policy invalid")
  end)

  it("returns error when is_allowed fails, never calls write_file", function()
    local deps, written = make_deps({
      config_store    = { allowed_paths = { "/tmp/*" }, blocked_paths = {} },
      is_allowed_ok   = false,
      is_allowed_err  = "path not in allowed list",
    })

    local ok, err = cmd_generate.run(deps, { output_path = "/var/out.lua", prompt = "p" })

    assert.is_nil(ok)
    assert.is_truthy(err:find("path not in allowed list"))
    assert.equals(0, #written)
  end)

  it("returns error when write_file fails", function()
    local deps, _ = make_deps({
      config_store = { allowed_paths = { "/tmp/*" }, blocked_paths = {} },
      write_ok     = false,
      write_err    = "disk full",
    })

    local ok, err = cmd_generate.run(deps, { output_path = "/tmp/out.lua", prompt = "p" })

    assert.is_nil(ok)
    assert.is_truthy(err:find("disk full"))
  end)

  it("returns ok with output_path, model, and tokens on success", function()
    local deps, _ = make_deps({
      config_store  = { allowed_paths = { "/tmp/*" }, blocked_paths = {} },
      complete_resp = fake_response("x=1\n", { total_tokens = 42 }),
    })

    local ok, info = cmd_generate.run(deps, { output_path = "/tmp/out.lua", prompt = "p" })

    assert.is_true(ok)
    assert.equals("/tmp/out.lua", info.output_path)
    assert.equals("test-model",  info.model)
    assert.equals("42",          info.tokens)
  end)

end)
-- ---------------------------------------------------------------------------
-- resolve_prompt
-- ---------------------------------------------------------------------------

describe("cmd_generate.resolve_prompt", function()

  it("returns a plain string unchanged", function()
    local result, err = cmd_generate.resolve_prompt("write a thing")
    assert.is_nil(err)
    assert.equals("write a thing", result)
  end)

  it("returns error for empty string", function()
    local result, err = cmd_generate.resolve_prompt("")
    assert.is_nil(result)
    assert.is_truthy(err:find("empty"))
  end)

  it("reads prompt from a real file via @ prefix", function()
    local lfs  = require("lfs")
    local path = lfs.currentdir() .. "/tmp_prompt_test.md"
    local f    = assert(io.open(path, "w"))
    f:write("Generate a cache module.\n")
    f:close()

    local result, err = cmd_generate.resolve_prompt("@" .. path)
    os.remove(path)

    assert.is_nil(err)
    assert.equals("Generate a cache module.\n", result)
  end)

  it("returns error when @ file does not exist", function()
    local result, err = cmd_generate.resolve_prompt("@/nonexistent/no_such_file.md")
    assert.is_nil(result)
    assert.is_truthy(err:find("cannot open prompt file"))
  end)

  it("returns error for bare @ with no path", function()
    local result, err = cmd_generate.resolve_prompt("@")
    assert.is_nil(result)
    assert.is_truthy(err:find("requires a file path"))
  end)

  it("treats a string starting with @ as a file path, not literal", function()
    -- Confirm a valid @file is NOT returned as the literal string "@file"
    local lfs  = require("lfs")
    local path = lfs.currentdir() .. "/tmp_at_test.md"
    local f    = assert(io.open(path, "w"))
    f:write("hello\n")
    f:close()

    local result, err = cmd_generate.resolve_prompt("@" .. path)
    os.remove(path)

    assert.is_nil(err)
    assert.equals("hello\n", result)
    -- Explicitly confirm the raw "@path" string was not returned
    assert.is_falsy(result == ("@" .. path))
  end)

  -- Note: stdin ("-") is not tested here because redirecting io.read in busted
  -- is not portable. The logic is a single io.read("*a") branch and is verified
  -- by manual testing.

end)
