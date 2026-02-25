--- src/skill_runner_test.lua
--- Busted tests for src/skill_runner.lua

local lfs   = require("lfs")
local cjson = require("cjson.safe")

local _src = debug.getinfo(1, "S").source:match("^@(.*/)") or "./"
package.path = _src .. "?.lua;" .. package.path

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local cwd      = lfs.currentdir()
local TEST_DIR = cwd .. "/skill_runner_test_" .. tostring(os.time())

local function mkdir_p(path)
  local acc = ""
  for seg in path:gmatch("[^/]+") do
    acc = acc .. "/" .. seg
    lfs.mkdir(acc)
  end
end

local function write_file(path, content)
  local f = assert(io.open(path, "w"))
  f:write(content)
  f:close()
end

local function read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local c = f:read("*a")
  f:close()
  return c
end

local function read_lines(path)
  local lines = {}
  local f = io.open(path, "r")
  if not f then return lines end
  for line in f:lines() do
    lines[#lines + 1] = line
  end
  f:close()
  return lines
end

local function cleanup()
  os.execute("rm -rf " .. TEST_DIR)
end

--- Re-require a module fresh (reset cached state).
local function fresh_require(name)
  package.loaded[name] = nil
  return require(name)
end

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------

local SKILLS_DIR  = TEST_DIR .. "/skills"
local CONFIG_PATH = TEST_DIR .. "/config.json"
local AUDIT_PATH  = TEST_DIR .. "/audit.log"

setup(function()
  mkdir_p(SKILLS_DIR)
  mkdir_p(TEST_DIR .. "/tests")

  -- ---- Skill fixtures ----

  -- A good skill with a run() that returns its args
  write_file(SKILLS_DIR .. "/echo.lua", [[
---@skill {
---  name = "echo",
---  version = "1.0",
---  description = "Echoes args back",
---  dependencies = {},
---  paths = {},
---  urls = {},
---  public_functions = { "run" },
---}

local M = {}
function M.run(args)
  return args
end
return M
]])

  -- A skill whose run() always errors
  write_file(SKILLS_DIR .. "/exploder.lua", [[
---@skill {
---  name = "exploder",
---  version = "1.0",
---  public_functions = { "run" },
---}

local M = {}
function M.run(args)
  error("skill went boom")
end
return M
]])

  -- A skill that doesn't return a table
  write_file(SKILLS_DIR .. "/bad_return.lua", [[
---@skill {
---  name = "bad_return",
---  version = "1.0",
---  public_functions = { "run" },
---}

return "not a table"
]])

  -- A skill without a run function
  write_file(SKILLS_DIR .. "/no_run.lua", [[
---@skill {
---  name = "no_run",
---  version = "1.0",
---  public_functions = { "process" },
---}

local M = {}
function M.process() end
return M
]])

  -- A skill that declares paths
  write_file(SKILLS_DIR .. "/file_reader.lua", [[
---@skill {
---  name = "file_reader",
---  version = "1.0",
---  paths = { "/tmp/allowed/*" },
---  public_functions = { "run" },
---}

local M = {}
function M.run() return "ok" end
return M
]])

  -- A skill that declares a blocked path
  write_file(SKILLS_DIR .. "/bad_path_skill.lua", [[
---@skill {
---  name = "bad_path_skill",
---  version = "1.0",
---  paths = { "/etc/shadow" },
---  public_functions = { "run" },
---}

local M = {}
function M.run() return "ok" end
return M
]])

  -- A skill that declares a path not in any allowed list
  write_file(SKILLS_DIR .. "/unallowed_path_skill.lua", [[
---@skill {
---  name = "unallowed_path_skill",
---  version = "1.0",
---  paths = { "/opt/secret/*" },
---  public_functions = { "run" },
---}

local M = {}
function M.run() return "ok" end
return M
]])

  -- A skill that declares public_functions that don't exist
  write_file(SKILLS_DIR .. "/missing_fn.lua", [[
---@skill {
---  name = "missing_fn",
---  version = "1.0",
---  public_functions = { "run", "nonexistent" },
---}

local M = {}
function M.run() end
return M
]])

  -- ---- Test script fixtures ----

  -- A passing test script (plain Lua, no busted needed)
  write_file(TEST_DIR .. "/tests/pass.lua", [[
print("all good")
os.exit(0)
]])

  -- A failing test script
  write_file(TEST_DIR .. "/tests/fail.lua", [[
io.stderr:write("something failed\n")
os.exit(1)
]])

  -- A script that loops forever (for timeout testing)
  write_file(TEST_DIR .. "/tests/hang.lua", [[
while true do end
]])

  -- ---- Config file ----
  write_file(CONFIG_PATH, cjson.encode({
    allowed_paths   = { "/tmp/allowed/*", SKILLS_DIR .. "/*" },
    blocked_paths   = { "/etc" },
    model_selection = { default = { prefer = {}, fallback = {} } },
    limits          = { skill_exec_timeout_seconds = 10 },
  }))

  -- ---- Initialise global singletons for execute() tests ----
  local audit_mod  = fresh_require("audit")
  audit_mod.init(AUDIT_PATH)

  local config_mod = fresh_require("config")
  config_mod.load(CONFIG_PATH)
end)

teardown(cleanup)

-- ---------------------------------------------------------------------------
-- skill_runner.execute
-- ---------------------------------------------------------------------------

describe("skill_runner.execute", function()

  it("loads and runs a skill, returning the result", function()
    local runner = fresh_require("skill_runner")
    local result, err = runner.execute("echo", { msg = "hi" }, { SKILLS_DIR })
    assert.is_truthy(result, tostring(err))
    assert.equals("hi", result.msg)
  end)

  it("logs execution events to audit", function()
    local runner = fresh_require("skill_runner")
    runner.execute("echo", "test", { SKILLS_DIR })

    local lines = read_lines(AUDIT_PATH)
    assert.is_truthy(#lines >= 1, "audit log should have entries")

    -- At least one line should reference the skill
    local found = false
    for _, line in ipairs(lines) do
      if line:find("echo", 1, true) then
        found = true
        break
      end
    end
    assert.is_true(found, "audit should contain an entry mentioning 'echo'")
  end)

  it("returns error when run() raises", function()
    local runner = fresh_require("skill_runner")
    local result, err = runner.execute("exploder", {}, { SKILLS_DIR })
    assert.is_nil(result)
    assert.is_truthy(err:find("boom", 1, true))
  end)

  it("returns error when skill does not return a module table", function()
    local runner = fresh_require("skill_runner")
    local result, err = runner.execute("bad_return", {}, { SKILLS_DIR })
    assert.is_nil(result)
    assert.is_truthy(err:find("did not return a module table", 1, true))
  end)

  it("returns error when skill has no run() function", function()
    local runner = fresh_require("skill_runner")
    local result, err = runner.execute("no_run", {}, { SKILLS_DIR })
    assert.is_nil(result)
    assert.is_truthy(err:find("no run() function", 1, true))
  end)

  it("returns error when skill is not found", function()
    local runner = fresh_require("skill_runner")
    local result, err = runner.execute("nonexistent", {}, { SKILLS_DIR })
    assert.is_nil(result)
    assert.is_truthy(err:find("not found", 1, true))
  end)

  it("returns error for empty skill_name", function()
    local runner = fresh_require("skill_runner")
    local result, err = runner.execute("", {}, { SKILLS_DIR })
    assert.is_nil(result)
    assert.is_truthy(err:find("non-empty string", 1, true))
  end)

  it("returns error for empty search_dirs", function()
    local runner = fresh_require("skill_runner")
    local result, err = runner.execute("echo", {}, {})
    assert.is_nil(result)
    assert.is_truthy(err:find("non-empty array", 1, true))
  end)

end)

-- ---------------------------------------------------------------------------
-- skill_runner.run_tests
-- ---------------------------------------------------------------------------

describe("skill_runner.run_tests", function()

  it("runs a passing test file and reports success", function()
    local runner = fresh_require("skill_runner")
    local result, err = runner.run_tests(TEST_DIR .. "/tests/pass.lua")
    assert.is_truthy(result, tostring(err))
    assert.equals(0, result.exit_code)
    assert.is_true(result.passed)
    assert.is_truthy(result.output:find("all good", 1, true))
  end)

  it("runs a failing test file and reports failure", function()
    local runner = fresh_require("skill_runner")
    local result, err = runner.run_tests(TEST_DIR .. "/tests/fail.lua")
    assert.is_truthy(result, tostring(err))
    assert.is_truthy(result.exit_code ~= 0)
    assert.is_false(result.passed)
  end)

  it("captures stderr in output", function()
    local runner = fresh_require("skill_runner")
    local result, err = runner.run_tests(TEST_DIR .. "/tests/fail.lua")
    assert.is_truthy(result, tostring(err))
    assert.is_truthy(result.output:find("something failed", 1, true))
  end)

  it("times out on a hanging test (requires timeout/gtimeout)", function()
    -- Probe for a timeout binary; skip gracefully if unavailable.
    local has_timeout = false
    for _, name in ipairs({ "timeout", "gtimeout" }) do
      local ok = os.execute(name .. " 0 true >/dev/null 2>&1")
      if ok == true or ok == 0 then has_timeout = true; break end
    end
    if not has_timeout then
      pending("no timeout/gtimeout binary available — skipping")
      return
    end

    local runner = fresh_require("skill_runner")
    local result, err = runner.run_tests(TEST_DIR .. "/tests/hang.lua", 2)
    assert.is_truthy(result, tostring(err))
    assert.is_true(result.timed_out)
    assert.is_false(result.passed)
    assert.equals(124, result.exit_code)
  end)

  it("returns error for nonexistent file", function()
    local runner = fresh_require("skill_runner")
    local result, err = runner.run_tests(TEST_DIR .. "/tests/nope.lua")
    assert.is_nil(result)
    assert.is_truthy(err:find("not found", 1, true))
  end)

  it("returns error for empty path", function()
    local runner = fresh_require("skill_runner")
    local result, err = runner.run_tests("")
    assert.is_nil(result)
    assert.is_truthy(err:find("non-empty string", 1, true))
  end)

  it("returns error for invalid timeout", function()
    local runner = fresh_require("skill_runner")
    local result, err = runner.run_tests(TEST_DIR .. "/tests/pass.lua", -1)
    assert.is_nil(result)
    assert.is_truthy(err:find("positive number", 1, true))
  end)

end)

-- ---------------------------------------------------------------------------
-- skill_runner.validate_skill
-- ---------------------------------------------------------------------------

describe("skill_runner.validate_skill", function()

  local good_cfg = {
    allowed_paths = { "/tmp/allowed/*", SKILLS_DIR .. "/*" },
    blocked_paths = { "/etc" },
  }

  it("passes for a valid skill with no declared paths", function()
    local runner = fresh_require("skill_runner")
    local ok, errs = runner.validate_skill(SKILLS_DIR .. "/echo.lua", good_cfg)
    assert.is_true(ok, errs and table.concat(errs, "; "))
  end)

  it("passes for a skill whose paths are in allowed_paths", function()
    local runner = fresh_require("skill_runner")
    local ok, errs = runner.validate_skill(SKILLS_DIR .. "/file_reader.lua", good_cfg)
    assert.is_true(ok, errs and table.concat(errs, "; "))
  end)

  it("fails when a declared path is blocked", function()
    local runner = fresh_require("skill_runner")
    local ok, errs = runner.validate_skill(SKILLS_DIR .. "/bad_path_skill.lua", good_cfg)
    assert.is_false(ok)
    assert.is_truthy(#errs > 0)

    local found = false
    for _, e in ipairs(errs) do
      if e:find("blocked", 1, true) then found = true; break end
    end
    assert.is_true(found, "should mention blocked path")
  end)

  it("fails when a declared path is not in allowed_paths", function()
    local runner = fresh_require("skill_runner")
    local ok, errs = runner.validate_skill(SKILLS_DIR .. "/unallowed_path_skill.lua", good_cfg)
    assert.is_false(ok)

    local found = false
    for _, e in ipairs(errs) do
      if e:find("not within any allowed_paths", 1, true) then found = true; break end
    end
    assert.is_true(found, "should mention path not in allowed_paths")
  end)

  it("fails when public_functions are missing from the module", function()
    local runner = fresh_require("skill_runner")
    local ok, errs = runner.validate_skill(SKILLS_DIR .. "/missing_fn.lua", good_cfg)
    assert.is_false(ok)

    local found = false
    for _, e in ipairs(errs) do
      if e:find("nonexistent", 1, true) then found = true; break end
    end
    assert.is_true(found, "should report missing 'nonexistent' function")
  end)

  it("fails when skill code does not return a table", function()
    local runner = fresh_require("skill_runner")
    local ok, errs = runner.validate_skill(SKILLS_DIR .. "/bad_return.lua", good_cfg)
    assert.is_false(ok)

    local found = false
    for _, e in ipairs(errs) do
      if e:find("module table", 1, true) then found = true; break end
    end
    assert.is_true(found, "should mention module table")
  end)

  it("returns error for nonexistent skill file", function()
    local runner = fresh_require("skill_runner")
    local ok, errs = runner.validate_skill(SKILLS_DIR .. "/nope.lua", good_cfg)
    assert.is_false(ok)
    assert.is_truthy(#errs > 0)
  end)

  it("returns error for empty skill_path", function()
    local runner = fresh_require("skill_runner")
    local ok, errs = runner.validate_skill("", good_cfg)
    assert.is_false(ok)
    assert.is_truthy(errs[1]:find("non-empty string", 1, true))
  end)

  it("returns error when cfg is not a table", function()
    local runner = fresh_require("skill_runner")
    local ok, errs = runner.validate_skill(SKILLS_DIR .. "/echo.lua", "bad")
    assert.is_false(ok)
    assert.is_truthy(errs[1]:find("cfg must be a table", 1, true))
  end)

end)
