--- src/skill_loader_test.lua
--- Busted tests for src/skill_loader.lua

local lfs = require("lfs")

local _src = debug.getinfo(1, "S").source:match("^@(.*/)") or "./"
package.path = _src .. "?.lua;" .. package.path

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local cwd      = lfs.currentdir()
local TEST_DIR = cwd .. "/skill_loader_test_" .. tostring(os.time())

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

local function cleanup()
  os.execute("rm -rf " .. TEST_DIR)
end

local function fresh_loader()
  package.loaded["skill_loader"] = nil
  return require("skill_loader")
end

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------

setup(function()
  mkdir_p(TEST_DIR .. "/skills")
  mkdir_p(TEST_DIR .. "/skills2")
  mkdir_p(TEST_DIR .. "/deps")
  mkdir_p(TEST_DIR .. "/empty")

  -- A valid skill with all fields
  write_file(TEST_DIR .. "/skills/read_csv.lua", [[
---@skill {
---  name = "read_csv",
---  version = "1.0",
---  description = "Parse a CSV file into a table of rows",
---  dependencies = {},
---  paths = { "~/data/*" },
---  urls = {},
---  public_functions = { "run", "parse_args" },
---}

local M = {}
function M.run() return "ok" end
function M.parse_args() return {} end
return M
]])

  -- A valid skill with minimal fields (only required)
  write_file(TEST_DIR .. "/skills/minimal.lua", [[
---@skill {
---  name = "minimal",
---  version = "0.1",
---  public_functions = { "execute" },
---}

local M = {}
function M.execute() end
return M
]])

  -- A skill with a dependency
  write_file(TEST_DIR .. "/skills/with_dep.lua", [[
---@skill {
---  name = "with_dep",
---  version = "1.0",
---  dependencies = { "helper" },
---  public_functions = { "run" },
---}

local M = {}
function M.run() end
return M
]])

  -- A file with no metadata block
  write_file(TEST_DIR .. "/skills/no_meta.lua", [[
-- This file has no @skill block
local M = {}
function M.run() end
return M
]])

  -- A file with invalid metadata (missing required field)
  write_file(TEST_DIR .. "/skills/bad_meta.lua", [[
---@skill {
---  name = "bad_meta",
---  version = "1.0",
---}

local M = {}
return M
]])

  -- A file with broken Lua in metadata
  write_file(TEST_DIR .. "/skills/broken_meta.lua", [[
---@skill {
---  name = "broken"
---  this is not valid lua {{{{
---}

local M = {}
return M
]])

  -- A test file that should be excluded from list()
  write_file(TEST_DIR .. "/skills/read_csv_test.lua", [[
-- test file
]])

  -- A second directory with a skill (for search order testing)
  write_file(TEST_DIR .. "/skills2/fallback.lua", [[
---@skill {
---  name = "fallback",
---  version = "2.0",
---  public_functions = { "run" },
---}

local M = {}
function M.run() end
return M
]])

  -- Dependencies for resolve_dependencies tests
  write_file(TEST_DIR .. "/deps/helper.lua", [[
---@skill {
---  name = "helper",
---  version = "1.0",
---  dependencies = {},
---  public_functions = { "help" },
---}

local M = {}
function M.help() end
return M
]])

  write_file(TEST_DIR .. "/deps/deep_a.lua", [[
---@skill {
---  name = "deep_a",
---  version = "1.0",
---  dependencies = { "deep_b" },
---  public_functions = { "a" },
---}

local M = {}
return M
]])

  write_file(TEST_DIR .. "/deps/deep_b.lua", [[
---@skill {
---  name = "deep_b",
---  version = "1.0",
---  dependencies = {},
---  public_functions = { "b" },
---}

local M = {}
return M
]])

  -- Circular dependency pair
  write_file(TEST_DIR .. "/deps/circ_a.lua", [[
---@skill {
---  name = "circ_a",
---  version = "1.0",
---  dependencies = { "circ_b" },
---  public_functions = { "a" },
---}

local M = {}
return M
]])

  write_file(TEST_DIR .. "/deps/circ_b.lua", [[
---@skill {
---  name = "circ_b",
---  version = "1.0",
---  dependencies = { "circ_a" },
---  public_functions = { "b" },
---}

local M = {}
return M
]])

end)

teardown(cleanup)

-- ---------------------------------------------------------------------------
-- skill_loader.parse_metadata
-- ---------------------------------------------------------------------------

describe("skill_loader.parse_metadata", function()

  it("parses a full metadata block", function()
    local loader = fresh_loader()
    local meta, err = loader.parse_metadata(TEST_DIR .. "/skills/read_csv.lua")
    assert.is_truthy(meta, tostring(err))
    assert.equals("read_csv", meta.name)
    assert.equals("1.0",     meta.version)
    assert.equals("Parse a CSV file into a table of rows", meta.description)
    assert.equals(2, #meta.public_functions)
    assert.equals("run",        meta.public_functions[1])
    assert.equals("parse_args", meta.public_functions[2])
    assert.equals(0, #meta.dependencies)
    assert.equals(1, #meta.paths)
    assert.equals("~/data/*", meta.paths[1])
  end)

  it("parses a minimal metadata block and fills defaults", function()
    local loader = fresh_loader()
    local meta, err = loader.parse_metadata(TEST_DIR .. "/skills/minimal.lua")
    assert.is_truthy(meta, tostring(err))
    assert.equals("minimal", meta.name)
    assert.equals("0.1",    meta.version)
    assert.equals("",       meta.description)
    assert.equals(1, #meta.public_functions)
    assert.equals(0, #meta.dependencies)
    assert.equals(0, #meta.paths)
    assert.equals(0, #meta.urls)
  end)

  it("returns error when no @skill block is present", function()
    local loader = fresh_loader()
    local meta, err = loader.parse_metadata(TEST_DIR .. "/skills/no_meta.lua")
    assert.is_nil(meta)
    assert.is_truthy(err:find("no @skill metadata block found", 1, true))
  end)

  it("returns error when required fields are missing", function()
    local loader = fresh_loader()
    local meta, err = loader.parse_metadata(TEST_DIR .. "/skills/bad_meta.lua")
    assert.is_nil(meta)
    assert.is_truthy(err:find("public_functions", 1, true))
  end)

  it("returns error when metadata has syntax errors", function()
    local loader = fresh_loader()
    local meta, err = loader.parse_metadata(TEST_DIR .. "/skills/broken_meta.lua")
    assert.is_nil(meta)
    assert.is_truthy(err:find("failed to compile metadata", 1, true)
                  or err:find("failed to evaluate metadata", 1, true))
  end)

  it("returns error for a nonexistent file", function()
    local loader = fresh_loader()
    local meta, err = loader.parse_metadata(TEST_DIR .. "/nonexistent.lua")
    assert.is_nil(meta)
    assert.is_truthy(err:find("cannot read", 1, true))
  end)

  it("returns error for empty path", function()
    local loader = fresh_loader()
    local meta, err = loader.parse_metadata("")
    assert.is_nil(meta)
    assert.is_truthy(err:find("non-empty string", 1, true))
  end)

end)

-- ---------------------------------------------------------------------------
-- skill_loader.load
-- ---------------------------------------------------------------------------

describe("skill_loader.load", function()

  it("loads a skill from the first matching directory", function()
    local loader = fresh_loader()
    local skill, err = loader.load("read_csv", { TEST_DIR .. "/skills" })
    assert.is_truthy(skill, tostring(err))
    assert.equals("read_csv",  skill.metadata.name)
    assert.equals("1.0",       skill.metadata.version)
    assert.is_truthy(skill.code:find("function M.run", 1, true))
    assert.equals(TEST_DIR .. "/skills/read_csv.lua", skill.path)
  end)

  it("searches directories in order", function()
    local loader = fresh_loader()
    -- skills/ does not have "fallback", skills2/ does
    local skill, err = loader.load("fallback", {
      TEST_DIR .. "/skills",
      TEST_DIR .. "/skills2",
    })
    assert.is_truthy(skill, tostring(err))
    assert.equals("fallback", skill.metadata.name)
    assert.equals("2.0",     skill.metadata.version)
  end)

  it("returns error when skill is not found in any directory", function()
    local loader = fresh_loader()
    local skill, err = loader.load("nonexistent", { TEST_DIR .. "/skills" })
    assert.is_nil(skill)
    assert.is_truthy(err:find("not found in", 1, true))
  end)

  it("returns error when skill file has no metadata", function()
    local loader = fresh_loader()
    local skill, err = loader.load("no_meta", { TEST_DIR .. "/skills" })
    assert.is_nil(skill)
    assert.is_truthy(err:find("no @skill metadata block found", 1, true))
  end)

  it("returns error for empty skill_name", function()
    local loader = fresh_loader()
    local skill, err = loader.load("", { TEST_DIR .. "/skills" })
    assert.is_nil(skill)
    assert.is_truthy(err:find("non-empty string", 1, true))
  end)

  it("returns error for empty search_dirs", function()
    local loader = fresh_loader()
    local skill, err = loader.load("read_csv", {})
    assert.is_nil(skill)
    assert.is_truthy(err:find("non-empty array", 1, true))
  end)

end)

-- ---------------------------------------------------------------------------
-- skill_loader.resolve_dependencies
-- ---------------------------------------------------------------------------

describe("skill_loader.resolve_dependencies", function()

  it("returns empty list when there are no dependencies", function()
    local loader = fresh_loader()
    local order, err = loader.resolve_dependencies({ dependencies = {} }, TEST_DIR .. "/deps")
    assert.is_truthy(order, tostring(err))
    assert.equals(0, #order)
  end)

  it("resolves a single direct dependency", function()
    local loader = fresh_loader()
    local order, err = loader.resolve_dependencies(
      { dependencies = { "helper" } },
      TEST_DIR .. "/deps"
    )
    assert.is_truthy(order, tostring(err))
    assert.equals(1, #order)
    assert.equals("helper", order[1])
  end)

  it("resolves transitive dependencies in correct order", function()
    local loader = fresh_loader()
    -- deep_a depends on deep_b, so deep_b must appear first
    local order, err = loader.resolve_dependencies(
      { dependencies = { "deep_a" } },
      TEST_DIR .. "/deps"
    )
    assert.is_truthy(order, tostring(err))
    assert.equals(2, #order)
    assert.equals("deep_b", order[1])
    assert.equals("deep_a", order[2])
  end)

  it("detects circular dependencies", function()
    local loader = fresh_loader()
    local order, err = loader.resolve_dependencies(
      { dependencies = { "circ_a" } },
      TEST_DIR .. "/deps"
    )
    assert.is_nil(order)
    assert.is_truthy(err:find("circular dependency", 1, true))
  end)

  it("returns error for missing dependency file", function()
    local loader = fresh_loader()
    local order, err = loader.resolve_dependencies(
      { dependencies = { "nonexistent_dep" } },
      TEST_DIR .. "/deps"
    )
    assert.is_nil(order)
    assert.is_truthy(err:find("not found", 1, true))
  end)

  it("does not duplicate shared dependencies", function()
    local loader = fresh_loader()
    -- Both deep_a and helper are deps; deep_a itself depends on deep_b.
    -- helper and deep_b should each appear exactly once.
    local order, err = loader.resolve_dependencies(
      { dependencies = { "deep_a", "helper" } },
      TEST_DIR .. "/deps"
    )
    assert.is_truthy(order, tostring(err))

    -- Count occurrences
    local counts = {}
    for _, name in ipairs(order) do
      counts[name] = (counts[name] or 0) + 1
    end
    for name, count in pairs(counts) do
      assert.equals(1, count, name .. " should appear exactly once")
    end
  end)

  it("returns error for non-table metadata", function()
    local loader = fresh_loader()
    local order, err = loader.resolve_dependencies("bad", TEST_DIR .. "/deps")
    assert.is_nil(order)
    assert.is_truthy(err:find("metadata must be a table", 1, true))
  end)

  it("returns error for empty allowed_dir", function()
    local loader = fresh_loader()
    local order, err = loader.resolve_dependencies({ dependencies = { "x" } }, "")
    assert.is_nil(order)
    assert.is_truthy(err:find("non-empty string", 1, true))
  end)

end)

-- ---------------------------------------------------------------------------
-- skill_loader.list
-- ---------------------------------------------------------------------------

describe("skill_loader.list", function()

  it("lists all skill files with parsed metadata", function()
    local loader = fresh_loader()
    local results = loader.list(TEST_DIR .. "/skills")

    -- Should find read_csv, minimal, with_dep — but NOT no_meta, bad_meta,
    -- broken_meta (failed parse), or read_csv_test (test file excluded).
    assert.is_truthy(#results >= 3, "expected at least 3 skills, got " .. #results)

    -- Results are sorted by name
    local names = {}
    for _, r in ipairs(results) do
      names[#names + 1] = r.name
    end

    local found_csv = false
    local found_min = false
    local found_dep = false
    for _, n in ipairs(names) do
      if n == "read_csv" then found_csv = true end
      if n == "minimal"  then found_min = true end
      if n == "with_dep" then found_dep = true end
    end

    assert.is_true(found_csv, "read_csv should be listed")
    assert.is_true(found_min, "minimal should be listed")
    assert.is_true(found_dep, "with_dep should be listed")
  end)

  it("excludes test files", function()
    local loader = fresh_loader()
    local results = loader.list(TEST_DIR .. "/skills")

    for _, r in ipairs(results) do
      assert.is_falsy(r.path:find("_test%.lua$"), "test files must be excluded: " .. r.path)
    end
  end)

  it("each result has name, version, description, path", function()
    local loader = fresh_loader()
    local results = loader.list(TEST_DIR .. "/skills")

    for _, r in ipairs(results) do
      assert.is_truthy(r.name,    "name must be present")
      assert.is_truthy(r.version, "version must be present")
      assert.equals("string", type(r.description))
      assert.is_truthy(r.path,    "path must be present")
    end
  end)

  it("returns results sorted by name", function()
    local loader = fresh_loader()
    local results = loader.list(TEST_DIR .. "/skills")

    for i = 2, #results do
      assert.is_truthy(results[i - 1].name <= results[i].name,
        "results must be sorted: " .. results[i - 1].name .. " > " .. results[i].name)
    end
  end)

  it("returns empty list for empty directory", function()
    local loader = fresh_loader()
    local results = loader.list(TEST_DIR .. "/empty")
    assert.equals(0, #results)
  end)

  it("returns empty list for nonexistent directory", function()
    local loader = fresh_loader()
    local results = loader.list(TEST_DIR .. "/no_such_dir")
    assert.equals(0, #results)
  end)

  it("returns empty list for empty string", function()
    local loader = fresh_loader()
    local results = loader.list("")
    assert.equals(0, #results)
  end)

end)
