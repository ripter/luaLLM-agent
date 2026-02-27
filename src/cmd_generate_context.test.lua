local mocks = require("test.mocks")
local lfs = require("lfs")

--local _src = debug.getinfo(1, "S").source:match("^@(.*/)") or "./"
--package.path = _src .. "?.lua;" .. package.path

local cmd_generate         = require("cmd_generate")
local cmd_generate_context = require("cmd_generate_context")

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local cwd = lfs.currentdir()



--- Build a minimal deps table for cmd_generate / cmd_generate_context.
local function make_deps(overrides)
  overrides = overrides or {}

  local written = {}

  local config_store = overrides.config_store or {}
  local config = {
    load = function() return true end,
    get  = function(key)
      if config_store[key] ~= nil then return config_store[key] end
      error("config key not found: " .. key)
    end,
  }

  local state_resp = overrides.state_resp or {
    servers = { { model = "ctx-model", port = 8080, state = "running" } }
  }
  local complete_resp = overrides.complete_resp or mocks.fake_response("-- generated\n")
  local complete_err  = overrides.complete_err

  local luallm = {
    state    = function()
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

  local safe_fs = {
    validate_policy = function() return true, nil end,
    is_allowed      = function(path) return true, nil end,
    write_file = function(path, content, allowed_paths, blocked_paths)
      written[#written + 1] = {
        path          = path,
        content       = content,
        allowed_paths = allowed_paths,
        blocked_paths = blocked_paths,
      }
      if overrides.write_err then return nil, overrides.write_err end
      return true, nil
    end,
  }

  return {
    luallm       = luallm,
    safe_fs      = safe_fs,
    config       = config,
    cmd_generate = cmd_generate,
  }, written
end

--- Write a temporary file and return its absolute path.
local function write_tmp(name, content)
  local path = cwd .. "/" .. name
  local f = assert(io.open(path, "w"))
  f:write(content)
  f:close()
  return path
end

local function rm(path) os.remove(path) end

-- ---------------------------------------------------------------------------
-- build_context_prompt (pure function, no deps)
-- ---------------------------------------------------------------------------

describe("cmd_generate.build_context_prompt", function()

  it("produces the expected structure with one file", function()
    local records = { { path = "src/config.lua", content = "-- config\n" } }
    local result  = cmd_generate.build_context_prompt(records, "Write a loader.")

    -- Header and footer presence
    assert.is_truthy(result:find("Here are existing source files for reference:", 1, true))
    assert.is_truthy(result:find("Now, using these as reference", 1, true))

    -- File inclusion
    assert.is_truthy(result:find("--- src/config.lua ---", 1, true))
    assert.is_truthy(result:find("-- config\n", 1, true))

    -- User prompt placement
    assert.is_truthy(result:find("Write a loader.", 1, true))
  end)

  it("includes multiple files in order", function()
    local records = {
      { path = "a.lua", content = "-- a\n" },
      { path = "b.lua", content = "-- b\n" },
    }
    local result = cmd_generate.build_context_prompt(records, "do something")

    local pos_a = result:find("--- a.lua ---", 1, true)
    local pos_b = result:find("--- b.lua ---", 1, true)
    assert.is_truthy(pos_a)
    assert.is_truthy(pos_b)
    assert.is_true(pos_a < pos_b, "a.lua must appear before b.lua")
  end)

  it("user prompt appears after the context section", function()
    local records = { { path = "x.lua", content = "x=1\n" } }
    local result  = cmd_generate.build_context_prompt(records, "MY_PROMPT")

    local pos_now    = result:find("Now, using these as reference", 1, true)
    local pos_prompt = result:find("MY_PROMPT",                     1, true)
    assert.is_true(pos_now < pos_prompt, "user prompt should appear after context section")
  end)

  it("works with zero context files", function()
    local result = cmd_generate.build_context_prompt({}, "prompt only")
    -- Header and footer should still be present; no file sections
    assert.is_truthy(result:find("Here are existing source files for reference:", 1, true))
    assert.is_truthy(result:find("prompt only", 1, true))
    assert.is_falsy(result:find("---"))  -- no file separators
  end)

  it("file content is preserved verbatim (including special chars)", function()
    local tricky = "local t = {[\"key\"] = 1}\nreturn t -- don't change this\n"
    local records = { { path = "tricky.lua", content = tricky } }
    local result  = cmd_generate.build_context_prompt(records, "p")
    assert.is_truthy(result:find(tricky, 1, true))
  end)

  it("handles large file content without truncation", function()
    local big = string.rep("x", 10000)
    local records = { { path = "big.lua", content = big } }
    local result  = cmd_generate.build_context_prompt(records, "p")
    assert.is_truthy(result:find(big, 1, true))
  end)

  it("handles paths with subdirectories", function()
    local records = { { path = "lib/utils/helpers.lua", content = "return {}" } }
    local result  = cmd_generate.build_context_prompt(records, "p")
    assert.is_truthy(result:find("--- lib/utils/helpers.lua ---", 1, true))
  end)

end)

-- ---------------------------------------------------------------------------
-- cmd_generate.run_with_context (deps injection, no filesystem)
-- ---------------------------------------------------------------------------

describe("cmd_generate.run_with_context", function()

  it("calls run_inner with the assembled context prompt", function()
    local captured_prompt
    local deps, _ = mocks.make_deps({
      config_overrides = {
        store = { allowed_paths = { "/tmp/*" }, blocked_paths = {} },
      }
    })
    local orig_complete = deps.luallm.complete
    deps.luallm.complete = function(model, messages, options, port)
      captured_prompt = messages[2].content  -- user message
      return orig_complete(model, messages, options, port)
    end

    cmd_generate.run_with_context(deps, {
      output_path   = "/tmp/out.lua",
      context_files = { { path = "src/cfg.lua", content = "-- cfg\n" } },
      prompt        = "Write a thing.",
    })

    assert.is_truthy(captured_prompt:find("Here are existing source files", 1, true))
    assert.is_truthy(captured_prompt:find("--- src/cfg.lua ---", 1, true))
    assert.is_truthy(captured_prompt:find("Write a thing.", 1, true))
  end)

  it("empty context_files sends prompt with header but no file blocks", function()
    local captured_prompt
    local deps, _ = mocks.make_deps({
      config_overrides = {
        store = { allowed_paths = { "/tmp/*" }, blocked_paths = {} },
      }
    })
    deps.luallm.complete = function(model, messages, options, port)
      captured_prompt = messages[2].content
      return mocks.fake_response("x=1\n"), nil
    end

    cmd_generate.run_with_context(deps, {
      output_path   = "/tmp/out.lua",
      context_files = {},
      prompt        = "Just a prompt.",
    })

    assert.is_truthy(captured_prompt:find("Just a prompt.", 1, true))
    assert.is_falsy(captured_prompt:find("---", 1, true))
  end)

  it("propagates write failure from run_inner", function()
    local deps, _ = mocks.make_deps({
      config_overrides = {
        store = { allowed_paths = { "/tmp/*" }, blocked_paths = {} },
      },
      safe_fs_overrides = {
        write_err = "disk full",
      },
    })

    local ok, err = cmd_generate.run_with_context(deps, {
      output_path   = "/tmp/out.lua",
      context_files = {},
      prompt        = "p",
    })

    assert.is_nil(ok)
    assert.is_truthy(err:find("disk full"))
  end)

  it("returns info table with model and tokens on success", function()
    local deps, _ = mocks.make_deps({
      config_overrides = {
        store = { allowed_paths = { "/tmp/*" }, blocked_paths = {} },
      },
      luallm_overrides = {
        model         = "ctx-model",
        complete_resp = mocks.fake_response("x=1\n", { total_tokens = 99 }),
      },
    })

    local ok, info = cmd_generate.run_with_context(deps, {
      output_path   = "/tmp/out.lua",
      context_files = { { path = "a.lua", content = "-- a\n" } },
      prompt        = "p",
    })

    assert.is_true(ok)
    assert.equals("ctx-model", info.model)
    assert.equals("99",        info.tokens)
  end)

  it("returns info even when usage field is missing", function()
    local deps, _ = mocks.make_deps({
      config_overrides = {
        store = { allowed_paths = { "/tmp/*" }, blocked_paths = {} },
      },
      luallm_overrides = {
        model         = "ctx-model",
        complete_resp = mocks.fake_response("x=1\n"),
      },
    })

    local ok, info = cmd_generate.run_with_context(deps, {
      output_path   = "/tmp/out.lua",
      context_files = {},
      prompt        = "p",
    })

    assert.is_true(ok)
    assert.equals("ctx-model", info.model)
    assert.equals("0",         info.tokens)
  end)

  it("delegates write_file to safe_fs with correct args", function()
    local captured_user_msg
    local deps, written = mocks.make_deps({
      config_overrides = {
        store = { allowed_paths = { "/allowed/*" }, blocked_paths = { "/denied/*" } },
      }
    })
    local orig_complete = deps.luallm.complete
    deps.luallm.complete = function(model, messages, options, port)
      captured_user_msg = messages[2].content
      return orig_complete(model, messages, options, port)
    end

    cmd_generate.run_with_context(deps, {
      output_path   = "/allowed/out.lua",
      context_files = { { path = "src/cfg.lua", content = "-- cfg\n" } },
      prompt        = "Write a thing.",
    })

    assert.equals(1, #written, "write_file must be called once")
    assert.equals("/allowed/out.lua", written[1].path)
    assert.is_truthy(captured_user_msg:find("Write a thing.", 1, true))
    assert.same({ "/allowed/*" }, written[1].allowed_paths)
    assert.same({ "/denied/*" },  written[1].blocked_paths)
  end)

  it("propagates safe_fs.write_file denial error", function()
    local deps, written = mocks.make_deps({
      config_overrides = {
        store = { allowed_paths = { "/allowed/*" }, blocked_paths = {} },
      }
    })
    deps.safe_fs.write_file = function(path, content, allowed_paths, blocked_paths)
      -- Still record for assertion B
      written[#written + 1] = {
        path          = path,
        content       = content,
        allowed_paths = allowed_paths,
        blocked_paths = blocked_paths,
      }
      -- Always deny
      return nil, "write denied by policy"
    end

    local ok, err = cmd_generate.run_with_context(deps, {
      output_path   = "/allowed/out.lua",
      context_files = {},
      prompt        = "p",
    })

    -- A: Check return values
    assert.is_nil(ok)
    assert.equals("write denied by policy", err)

    -- B: Check it was called exactly once
    assert.equals(1, #written, "write_file must be called once on denial")

    -- C: Check correct arguments
    assert.equals("/allowed/out.lua", written[1].path)
    assert.is_truthy(written[1].content)  -- write_file was called with non-nil content
    assert.same({ "/allowed/*" }, written[1].allowed_paths)
    assert.same({},              written[1].blocked_paths)
  end)

end)

-- ---------------------------------------------------------------------------
-- cmd_generate_context.run (file reading + delegation)
-- ---------------------------------------------------------------------------

describe("cmd_generate_context.run", function()

  it("reads a real file and includes it in the prompt", function()
    local tmp = write_tmp("ctx_test_file.lua", "-- real content\n")
    local captured_prompt

    local deps = mocks.make_deps({
      config_overrides = {
        store = { allowed_paths = { "/tmp/*" }, blocked_paths = {} },
      },
      luallm_overrides = {
        complete = function(model, messages, options, port)
          captured_prompt = messages[2].content
          return mocks.fake_response("x=1\n"), nil
        end
      },
    })
    --deps.luallm.complete = function(model, messages, options, port)
    --  captured_prompt = messages[2].content
    --  return fake_response("x=1\n"), nil
    --end

    local ok, err = cmd_generate_context.run(deps, {
      output_path   = "/tmp/out.lua",
      context_paths = { tmp },
      prompt        = "Use it.",
    })

    rm(tmp)

    assert.is_true(ok, tostring(err))
    assert.is_truthy(captured_prompt:find("-- real content\n", 1, true))
  end)

  it("includes file path label in prompt", function()
    local tmp = write_tmp("labelled.lua", "x=1\n")
    local captured_prompt

    local deps = mocks.make_deps({
      config_overrides = {
        store = { allowed_paths = { "/tmp/*" }, blocked_paths = {} },
      },
      luallm_overrides = {
        complete = function(model, messages, options, port)
          captured_prompt = messages[2].content
          return mocks.fake_response("y=2\n"), nil
        end
      },
    })
    --deps.luallm.complete = function(model, messages, options, port)
    --  captured_prompt = messages[2].content
    --  return fake_response("y=2\n"), nil
    --end

    cmd_generate_context.run(deps, {
      output_path   = "/tmp/out.lua",
      context_paths = { tmp },
      prompt        = "p",
    })

    rm(tmp)
    assert.is_truthy(captured_prompt:find("--- " .. tmp .. " ---", 1, true))
  end)

  it("reads multiple files and includes all in order", function()
    local tmp1 = write_tmp("ctx_first.lua",  "-- first\n")
    local tmp2 = write_tmp("ctx_second.lua", "-- second\n")
    local captured_prompt

    local deps = mocks.make_deps({
      config_overrides = {
        store = { allowed_paths = { "/tmp/*" }, blocked_paths = {} },
      },
      luallm_overrides = {
        complete = function(model, messages, options, port)
          captured_prompt = messages[2].content
          return mocks.fake_response("z=3\n"), nil
        end
      },
    })
    --deps.luallm.complete = function(model, messages, options, port)
    --  captured_prompt = messages[2].content
    --  return fake_response("z=3\n"), nil
    --end

    cmd_generate_context.run(deps, {
      output_path   = "/tmp/out.lua",
      context_paths = { tmp1, tmp2 },
      prompt        = "p",
    })

    rm(tmp1); rm(tmp2)

    local pos1 = captured_prompt:find("-- first\n",  1, true)
    local pos2 = captured_prompt:find("-- second\n", 1, true)
    assert.is_truthy(pos1)
    assert.is_truthy(pos2)
    assert.is_true(pos1 < pos2, "first file must appear before second")
  end)

  it("returns an error when a context file does not exist", function()
    local deps, written = mocks.make_deps({
      config_overrides = {
        store = { allowed_paths = { "/tmp/*" }, blocked_paths = {} },
      },
    })

    local ok, err = cmd_generate_context.run(deps, {
      output_path   = "/tmp/out.lua",
      context_paths = { "/nonexistent/path/does_not_exist.lua" },
      prompt        = "p",
    })

    assert.is_nil(ok)
    assert.is_truthy(err:find("cannot open context file") or err:find("does_not_exist"))
    assert.equals(0, #written, "write_file must not be called when context read fails")
  end)

  it("returns an error when context files exceed max size", function()
    -- Write a file slightly over the cap we'll set.
    local big_content = string.rep("x", 100)
    local tmp = write_tmp("ctx_big.lua", big_content)

    local deps, written = mocks.make_deps({
      config_overrides = {
        store = {
          allowed_paths                  = { "/tmp/*" },
          blocked_paths                  = {},
          ["generate.max_context_bytes"] = 50,  -- cap at 50 bytes
        },
      },
    })

    local ok, err = cmd_generate_context.run(deps, {
      output_path   = "/tmp/out.lua",
      context_paths = { tmp },
      prompt        = "p",
    })

    rm(tmp)

    assert.is_nil(ok)
    assert.is_truthy(err:find("exceed") or err:find("size"))
    assert.equals(0, #written)
  end)

  it("returns error when no context files are provided", function()
    local deps = mocks.make_deps()

    local ok, err = cmd_generate_context.run(deps, {
      output_path   = "/tmp/out.lua",
      context_paths = {},
      prompt        = "p",
    })

    assert.is_nil(ok)
    assert.is_truthy(err:find("at least one context file"))
  end)

  it("passes through LLM errors from run_with_context", function()
    local tmp = write_tmp("ctx_err.lua", "-- src\n")

    local deps, _ = mocks.make_deps({
      config_overrides = {
        config_store  = { allowed_paths = { "/tmp/*" }, blocked_paths = {} },
      },
      luallm_overrides = {
        complete_err  = "timeout",
      },
    })

    local ok, err = cmd_generate_context.run(deps, {
      output_path   = "/tmp/out.lua",
      context_paths = { tmp },
      prompt        = "p",
    })

    rm(tmp)

    assert.is_nil(ok)
    assert.is_truthy(err:find("timeout"))
  end)

  it("total size check is cumulative across multiple files", function()
    -- Two files of 40 bytes each = 80 total, cap is 60.
    local content = string.rep("y", 40)
    local tmp1    = write_tmp("ctx_cum1.lua", content)
    local tmp2    = write_tmp("ctx_cum2.lua", content)

    local deps, written = mocks.make_deps({
      config_overrides = {
        store = {
          allowed_paths                  = { "/tmp/*" },
          blocked_paths                  = {},
          ["generate.max_context_bytes"] = 60,
        },
      },
    })

    local ok, err = cmd_generate_context.run(deps, {
      output_path   = "/tmp/out.lua",
      context_paths = { tmp1, tmp2 },
      prompt        = "p",
    })

    rm(tmp1); rm(tmp2)

    assert.is_nil(ok)
    assert.is_truthy(err:find("exceed") or err:find("size"))
    assert.equals(0, #written)
  end)

  it("respects config override for max_context_bytes", function()
    -- Default is 64KB. Set to 100 bytes.
    local content = string.rep("a", 80)
    local tmp     = write_tmp("ctx_override.lua", content)

    local deps, written = mocks.make_deps({
      config_override = {
        store = {
          allowed_paths                  = { "/tmp/*" },
          blocked_paths                  = {},
          ["generate.max_context_bytes"] = 100,
        },
      },
    })

    local ok, err = cmd_generate_context.run(deps, {
      output_path   = "/tmp/out.lua",
      context_paths = { tmp },
      prompt        = "p",
    })

    rm(tmp)

    assert.is_true(ok, "should succeed under 100-byte limit: " .. tostring(err))
    assert.equals(1, #written, "write_file should be called")
  end)

  it("handles empty files gracefully", function()
    local tmp = write_tmp("ctx_empty.lua", "")

    local captured_prompt
    local deps = mocks.make_deps({
      config_overrides = {
        store = { allowed_paths = { "/tmp/*" }, blocked_paths = {} },
      },
      luallm_overrides = {
        complete = function(model, messages, options, port)
          captured_prompt = messages[2].content
          return mocks.fake_response("done\n"), nil
        end,
      },
    })
    --deps.luallm.complete = function(model, messages, options, port)
    --  captured_prompt = messages[2].content
    --  return fake_response("done\n"), nil
    --end

    local ok, err = cmd_generate_context.run(deps, {
      output_path   = "/tmp/out.lua",
      context_paths = { tmp },
      prompt        = "p",
    })

    rm(tmp)

    assert.is_true(ok, tostring(err))
    assert.is_truthy(captured_prompt:find("--- " .. tmp .. " ---", 1, true))
  end)

  it("handles file with non-Lua content correctly", function()
    local content = "This is not code\nBut should be included anyway"
    local tmp = write_tmp("ctx_text.txt", content)

    local captured_prompt
    local deps = mocks.make_deps({
      config_override = {
        store = { allowed_paths = { "/tmp/*" }, blocked_paths = {} },
      },
      luallm_overrides = {
        complete = function(model, messages, options, port)
          captured_prompt = messages[2].content
          return mocks.fake_response("done\n"), nil
        end,
      },
    })
    --deps.luallm.complete = function(model, messages, options, port)
    --  captured_prompt = messages[2].content
    --  return fake_response("done\n"), nil
    --end

    local ok, err = cmd_generate_context.run(deps, {
      output_path   = "/tmp/out.lua",
      context_paths = { tmp },
      prompt        = "p",
    })

    rm(tmp)

    assert.is_true(ok, tostring(err))
    assert.is_truthy(captured_prompt:find(content, 1, true))
  end)

  it("reports error with specific file name when size exceeded", function()
    -- Create a file exactly at the limit, then add a tiny extra file.
    -- Cap is 50 bytes; first file is exactly 50 bytes (hits the limit), second
    -- file adds 1 more byte pushing total to 51 which exceeds the cap.
    local content = string.rep("x", 50)
    local tmp1    = write_tmp("ctx_exact50.lua", content)
    local tmp2    = write_tmp("ctx_extra1.lua",  "y")

    local deps, written = mocks.make_deps({
      config_overrides = {
        store = {
          allowed_paths                  = { "/tmp/*" },
          blocked_paths                  = {},
          ["generate.max_context_bytes"] = 50,
        },
      },
    })

    local ok, err = cmd_generate_context.run(deps, {
      output_path   = "/tmp/out.lua",
      context_paths = { tmp1, tmp2 },
      prompt        = "p",
    })

    rm(tmp1); rm(tmp2)

    assert.is_nil(ok)
    assert.is_truthy(err:find("ctx_extra1.lua"))
  end)

end)
