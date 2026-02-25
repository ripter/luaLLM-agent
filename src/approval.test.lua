--- src/approval.test.lua
--- Busted tests for src/approval.lua

local lfs = require("lfs")

local _src = debug.getinfo(1, "S").source:match("^@(.*/)") or "./"
package.path = _src .. "?.lua;" .. package.path

local approval = require("approval")

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local TEST_ROOT = "/tmp/approval_test_" .. tostring(os.time())

--- Recursive directory removal (rm -rf equivalent in Lua).
local function rm_rf(path)
  local attr = lfs.attributes(path)
  if not attr then return end
  if attr.mode == "directory" then
    for entry in lfs.dir(path) do
      if entry ~= "." and entry ~= ".." then
        rm_rf(path .. "/" .. entry)
      end
    end
    lfs.rmdir(path)
  else
    os.remove(path)
  end
end

--- Create a unique temp subdirectory for one test.
local function make_test_dirs(name)
  local base         = TEST_ROOT .. "/" .. name .. "_" .. tostring(os.time())
  local approvals    = base .. "/approvals"
  local allowed      = base .. "/allowed"
  lfs.mkdir(TEST_ROOT)
  lfs.mkdir(base)
  lfs.mkdir(approvals)
  lfs.mkdir(allowed)
  return approvals, allowed, base
end

--- Write a dummy Lua file to a directory.
local function write_dummy_skill(dir, skill_name)
  local path = dir .. "/" .. skill_name .. ".lua"
  local f    = assert(io.open(path, "w"))
  f:write("-- dummy skill\nreturn {}\n")
  f:close()
  return path
end

--- Stub out audit.log so tests don't depend on audit initialisation.
local function stub_audit()
  local audit_ok, audit = pcall(require, "audit")
  if audit_ok and audit then
    audit.log = function(...) end  -- no-op
  end
end

-- ---------------------------------------------------------------------------
-- Setup / teardown
-- ---------------------------------------------------------------------------

-- Stub audit before any tests run.
stub_audit()

-- Clean the entire test root before and after the suite.
rm_rf(TEST_ROOT)

-- ---------------------------------------------------------------------------
-- 1. resolve does not promote
-- ---------------------------------------------------------------------------

describe("approval.resolve does not promote", function()

  local approvals_dir, allowed_dir, base

  before_each(function()
    approvals_dir, allowed_dir, base = make_test_dirs("resolve_no_promote")
  end)

  after_each(function()
    rm_rf(base)
  end)

  it("sets approved=true without touching allowed_dir", function()
    local record, err = approval.create(
      "my_skill",
      "/tmp/my_skill.lua",
      "/tmp/my_skill_test.lua",
      { { name = "it works", passed = true } },
      { version = "1.0" },
      approvals_dir
    )
    assert.is_not_nil(record, "create failed: " .. tostring(err))

    local updated, uerr = approval.resolve(approvals_dir, record.id, true)
    assert.is_not_nil(updated, "resolve failed: " .. tostring(uerr))

    -- approved must be true
    assert.is_true(updated.approved, "approved should be true")

    -- promoted must remain false
    assert.is_false(updated.promoted, "promoted must not change after resolve")

    -- allowed_dir must be empty — no file was written there
    local file_count = 0
    for entry in lfs.dir(allowed_dir) do
      if entry ~= "." and entry ~= ".." then
        file_count = file_count + 1
      end
    end
    assert.equals(0, file_count, "allowed_dir must be empty after resolve")
  end)

  it("sets approved=false without touching allowed_dir", function()
    local record = assert(approval.create("skill_b", "/tmp/b.lua", "", {}, {}, approvals_dir))
    local updated = assert(approval.resolve(approvals_dir, record.id, false))

    assert.is_false(updated.approved)
    assert.is_false(updated.promoted)
  end)

  it("sets resolved_at timestamp", function()
    local record = assert(approval.create("skill_c", "/tmp/c.lua", "", {}, {}, approvals_dir))
    local updated = assert(approval.resolve(approvals_dir, record.id, true))
    assert.is_truthy(updated.resolved_at)
    -- Should look like an ISO 8601 timestamp
    assert.is_truthy(
      tostring(updated.resolved_at):match("^%d%d%d%d%-%d%d%-%d%dT"),
      "resolved_at should be ISO 8601"
    )
  end)

  it("rejects opts table containing promote=true", function()
    local record = assert(approval.create("skill_d", "/tmp/d.lua", "", {}, {}, approvals_dir))
    local ok, err = approval.resolve(approvals_dir, record.id, true, { promote = true })
    assert.is_nil(ok)
    assert.is_truthy(err:find("not permitted", 1, true) or err:find("manually", 1, true))
  end)

  it("rejects opts table containing copy=true", function()
    local record = assert(approval.create("skill_e", "/tmp/e.lua", "", {}, {}, approvals_dir))
    local ok, err = approval.resolve(approvals_dir, record.id, true, { copy = true })
    assert.is_nil(ok)
    assert.is_truthy(err)
  end)

end)

-- ---------------------------------------------------------------------------
-- 2. get_promotion_commands returns commands but does not execute
-- ---------------------------------------------------------------------------

describe("approval.get_promotion_commands", function()

  it("returns cp and chmod commands as strings", function()
    local record = {
      skill_name = "cool_skill",
      skill_path = "/tmp/agent_wrote/cool_skill.lua",
    }
    local allowed_dir = "/skills/allowed"

    local cmds, err = approval.get_promotion_commands(record, allowed_dir)
    assert.is_not_nil(cmds, tostring(err))
    assert.is_truthy(#cmds >= 3, "expected at least 3 commands")

    -- Find the cp command
    local has_cp = false
    for _, cmd in ipairs(cmds) do
      if cmd:match("^cp ") then has_cp = true end
    end
    assert.is_true(has_cp, "must contain a cp command")

    -- Find the chmod command
    local has_chmod = false
    for _, cmd in ipairs(cmds) do
      if cmd:match("^chmod") then has_chmod = true end
    end
    assert.is_true(has_chmod, "must contain a chmod command")
  end)

  it("includes the skill source path in the cp command", function()
    local record = {
      skill_name = "my_skill",
      skill_path = "/some/path/my_skill.lua",
    }
    local cmds = assert(approval.get_promotion_commands(record, "/allowed"))
    local cp_cmd = ""
    for _, cmd in ipairs(cmds) do
      if cmd:match("^cp ") then cp_cmd = cmd; break end
    end
    assert.is_truthy(cp_cmd:find("/some/path/my_skill.lua", 1, true),
      "cp command must include source path")
  end)

  it("includes the destination path in the cp command", function()
    local record = { skill_name = "foo", skill_path = "/src/foo.lua" }
    local cmds = assert(approval.get_promotion_commands(record, "/skills/allowed"))
    local cp_cmd = ""
    for _, cmd in ipairs(cmds) do
      if cmd:match("^cp ") then cp_cmd = cmd; break end
    end
    assert.is_truthy(cp_cmd:find("/skills/allowed/foo.lua", 1, true),
      "cp command must include destination path")
  end)

  it("quotes paths containing spaces", function()
    local record = {
      skill_name = "my skill",
      skill_path = "/path with spaces/my skill.lua",
    }
    local cmds = assert(approval.get_promotion_commands(record, "/allowed dir"))
    for _, cmd in ipairs(cmds) do
      if cmd:match("^cp ") then
        assert.is_truthy(cmd:find('"', 1, true), "paths should be double-quoted")
      end
    end
  end)

  it("returns nil+error for non-table record", function()
    local cmds, err = approval.get_promotion_commands("bad", "/allowed")
    assert.is_nil(cmds)
    assert.is_truthy(err)
  end)

  it("returns nil+error for missing allowed_dir", function()
    local cmds, err = approval.get_promotion_commands({ skill_name = "x" }, "")
    assert.is_nil(cmds)
    assert.is_truthy(err)
  end)

end)

-- ---------------------------------------------------------------------------
-- 3. promote() always fails with HumanRequired
-- ---------------------------------------------------------------------------

describe("approval.promote", function()

  it("always returns nil + HumanRequired error", function()
    local ok, err = approval.promote()
    assert.is_nil(ok)
    assert.is_truthy(err:find("HumanRequired", 1, true))
  end)

  it("fails even when called with arguments", function()
    local ok, err = approval.promote("skill_name", "/path/to/skill.lua", "/allowed")
    assert.is_nil(ok)
    assert.is_truthy(err:find("HumanRequired", 1, true))
  end)

  it("fails even when called with a table argument", function()
    local ok, err = approval.promote({ skill_name = "x", promote = true })
    assert.is_nil(ok)
    assert.is_truthy(err:find("HumanRequired", 1, true))
  end)

  it("error message mentions get_promotion_commands", function()
    local _, err = approval.promote()
    assert.is_truthy(
      err:find("get_promotion_commands", 1, true),
      "error should guide user to get_promotion_commands"
    )
  end)

end)

-- ---------------------------------------------------------------------------
-- 4. mark_promoted only works after manual file exists
-- ---------------------------------------------------------------------------

describe("approval.mark_promoted", function()

  local approvals_dir, allowed_dir, base

  before_each(function()
    approvals_dir, allowed_dir, base = make_test_dirs("mark_promoted")
  end)

  after_each(function()
    rm_rf(base)
  end)

  it("fails when skill file does not exist in allowed_dir", function()
    local record = assert(approval.create(
      "target_skill", "/tmp/target_skill.lua", "", {}, {}, approvals_dir
    ))
    -- Approve it first
    assert(approval.resolve(approvals_dir, record.id, true))

    -- File does not exist in allowed_dir yet
    local updated, err = approval.mark_promoted(approvals_dir, record.id, allowed_dir)
    assert.is_nil(updated, "should fail when file does not exist")
    assert.is_truthy(err:find("NotPromoted", 1, true) or err:find("not found", 1, true))
  end)

  it("succeeds and sets promoted=true after file is manually placed", function()
    local record = assert(approval.create(
      "target_skill", "/tmp/target_skill.lua", "", {}, {}, approvals_dir
    ))
    assert(approval.resolve(approvals_dir, record.id, true))

    -- Manually write the file (simulating what a human would do with cp)
    write_dummy_skill(allowed_dir, "target_skill")

    local updated, err = approval.mark_promoted(approvals_dir, record.id, allowed_dir)
    assert.is_not_nil(updated, "mark_promoted should succeed: " .. tostring(err))
    assert.is_true(updated.promoted, "promoted must be true")
  end)

  it("sets promoted_at timestamp on success", function()
    local record = assert(approval.create(
      "ts_skill", "/tmp/ts_skill.lua", "", {}, {}, approvals_dir
    ))
    assert(approval.resolve(approvals_dir, record.id, true))
    write_dummy_skill(allowed_dir, "ts_skill")

    local updated = assert(approval.mark_promoted(approvals_dir, record.id, allowed_dir))
    assert.is_truthy(updated.promoted_at)
    assert.is_truthy(
      tostring(updated.promoted_at):match("^%d%d%d%d%-%d%d%-%d%dT"),
      "promoted_at should be ISO 8601"
    )
  end)

  it("mark_promoted does not create the skill file itself", function()
    local record = assert(approval.create(
      "no_create_skill", "/tmp/nc.lua", "", {}, {}, approvals_dir
    ))
    assert(approval.resolve(approvals_dir, record.id, true))

    -- Do NOT manually place the file
    local expected_path = allowed_dir .. "/no_create_skill.lua"
    assert.is_nil(lfs.attributes(expected_path), "file must not exist before test")

    approval.mark_promoted(approvals_dir, record.id, allowed_dir)

    -- File still must not exist — mark_promoted must not create it
    assert.is_nil(lfs.attributes(expected_path),
      "mark_promoted must not create the skill file")
  end)

end)

-- ---------------------------------------------------------------------------
-- 5. Hard ban: module must not call os.execute
-- ---------------------------------------------------------------------------

describe("approval hard ban: no os.execute", function()

  local approvals_dir, allowed_dir, base
  local orig_execute

  before_each(function()
    approvals_dir, allowed_dir, base = make_test_dirs("os_exec_ban")
    orig_execute = os.execute
    os.execute = function(cmd)
      error("os.execute called with: " .. tostring(cmd))
    end
  end)

  after_each(function()
    os.execute = orig_execute
    rm_rf(base)
  end)

  it("resolve does not call os.execute", function()
    -- Create record without the patch active (mkdir may use shell on some systems)
    os.execute = orig_execute
    local record = assert(approval.create(
      "exec_test_skill", "/tmp/e.lua", "", {}, {}, approvals_dir
    ))
    os.execute = function(cmd)
      error("os.execute called with: " .. tostring(cmd))
    end

    -- This must not raise
    local ok, err = pcall(function()
      approval.resolve(approvals_dir, record.id, true)
    end)
    assert.is_true(ok, "resolve must not call os.execute: " .. tostring(err))
  end)

  it("get_promotion_commands does not call os.execute", function()
    local record = { skill_name = "x", skill_path = "/tmp/x.lua" }
    local ok, err = pcall(function()
      approval.get_promotion_commands(record, allowed_dir)
    end)
    assert.is_true(ok, "get_promotion_commands must not call os.execute: " .. tostring(err))
  end)

  it("mark_promoted does not call os.execute", function()
    os.execute = orig_execute
    local record = assert(approval.create(
      "mark_exec_skill", "/tmp/m.lua", "", {}, {}, approvals_dir
    ))
    assert(approval.resolve(approvals_dir, record.id, true))
    write_dummy_skill(allowed_dir, "mark_exec_skill")

    os.execute = function(cmd)
      error("os.execute called with: " .. tostring(cmd))
    end

    local ok, err = pcall(function()
      approval.mark_promoted(approvals_dir, record.id, allowed_dir)
    end)
    assert.is_true(ok, "mark_promoted must not call os.execute: " .. tostring(err))
  end)

end)

-- ---------------------------------------------------------------------------
-- Additional: create / list / get
-- ---------------------------------------------------------------------------

describe("approval.create / list_pending / get", function()

  local approvals_dir, _, base

  before_each(function()
    approvals_dir, _, base = make_test_dirs("crud")
  end)

  after_each(function()
    rm_rf(base)
  end)

  it("create returns a record with required fields", function()
    local record, err = approval.create(
      "my_skill", "/tmp/a.lua", "/tmp/a_test.lua",
      { { name = "passes", passed = true } },
      { version = "2.0" },
      approvals_dir
    )
    assert.is_not_nil(record, tostring(err))
    assert.is_string(record.id)
    assert.is_truthy(#record.id > 0)
    assert.equals("my_skill",          record.skill_name)
    assert.equals("/tmp/a.lua",        record.skill_path)
    assert.equals("/tmp/a_test.lua",   record.test_path)
    assert.is_false(record.promoted)
    assert.is_truthy(record.created_at)
  end)

  it("list_pending returns all created records", function()
    approval.create("skill_1", "/p1.lua", "", {}, {}, approvals_dir)
    approval.create("skill_2", "/p2.lua", "", {}, {}, approvals_dir)
    approval.create("skill_3", "/p3.lua", "", {}, {}, approvals_dir)

    local records = approval.list_pending(approvals_dir)
    assert.equals(3, #records)
  end)

  it("list_pending returns empty list for empty dir", function()
    local records = approval.list_pending(approvals_dir)
    assert.equals(0, #records)
  end)

  it("list_pending returns empty list for non-existent dir", function()
    local records = approval.list_pending("/nonexistent/dir/xyz")
    assert.equals(0, #records)
  end)

  it("get retrieves correct record by id", function()
    local created = assert(approval.create("lookup_skill", "/tmp/l.lua", "", {}, {}, approvals_dir))
    local fetched, err = approval.get(approvals_dir, created.id)
    assert.is_not_nil(fetched, tostring(err))
    assert.equals(created.id,    fetched.id)
    assert.equals("lookup_skill", fetched.skill_name)
  end)

  it("get returns error for unknown id", function()
    local record, err = approval.get(approvals_dir, "nonexistent-id-000")
    assert.is_nil(record)
    assert.is_truthy(err)
  end)

  it("records have unique IDs", function()
    local r1 = assert(approval.create("s1", "/p1.lua", "", {}, {}, approvals_dir))
    local r2 = assert(approval.create("s2", "/p2.lua", "", {}, {}, approvals_dir))
    assert.not_equals(r1.id, r2.id, "IDs must be unique")
  end)

end)

-- ---------------------------------------------------------------------------
-- Teardown: remove test root
-- ---------------------------------------------------------------------------

rm_rf(TEST_ROOT)
