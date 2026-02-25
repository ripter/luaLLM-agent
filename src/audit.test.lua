--- src/audit.test.lua
--- Busted tests for src/audit.lua

local lfs = require("lfs")

local _src = debug.getinfo(1, "S").source:match("^@(.*/)") or "./"
package.path = _src .. "?.lua;" .. package.path

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local cwd = lfs.currentdir()

--- Return a unique temporary file path that does not yet exist.
local function tmp_path(name)
  return cwd .. "/audit_test_" .. name .. "_" .. tostring(os.time()) .. ".log"
end

--- Read all lines from a file into a table.
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

--- Decode a JSONL line into a table. Fails the test if it can't be decoded.
local function decode_line(line)
  local cjson = require("cjson.safe")
  local obj, err = cjson.decode(line)
  assert.is_truthy(obj, "failed to decode JSON line: " .. tostring(err) .. " | line: " .. tostring(line))
  return obj
end

--- Remove a file and all numbered rotations (.1 .. .N) that exist.
local function cleanup(path, max_n)
  os.remove(path)
  for i = 1, (max_n or 10) do
    os.remove(path .. "." .. i)
  end
end

-- Re-require audit fresh for each test to reset module state.
local function fresh_audit()
  package.loaded["audit"] = nil
  return require("audit")
end

-- ---------------------------------------------------------------------------
-- audit.init
-- ---------------------------------------------------------------------------

describe("audit.init", function()

  it("creates the log file when it does not exist", function()
    local audit = fresh_audit()
    local path  = tmp_path("init_create")

    local ok, err = audit.init(path)
    assert.is_true(ok, tostring(err))
    assert.is_truthy(lfs.attributes(path), "file should exist after init")

    cleanup(path)
  end)

  it("succeeds when the file already exists (does not truncate)", function()
    local audit = fresh_audit()
    local path  = tmp_path("init_existing")

    -- Pre-create with content
    local f = assert(io.open(path, "w"))
    f:write("existing content\n")
    f:close()

    local ok, err = audit.init(path)
    assert.is_true(ok, tostring(err))

    -- Content must be preserved
    local f2 = assert(io.open(path, "r"))
    local content = f2:read("*a")
    f2:close()
    assert.equals("existing content\n", content)

    cleanup(path)
  end)

  it("returns error for empty path", function()
    local audit = fresh_audit()
    local ok, err = audit.init("")
    assert.is_nil(ok)
    assert.is_truthy(err:find("non-empty string", 1, true))
  end)

  it("returns error for non-string path", function()
    local audit = fresh_audit()
    local ok, err = audit.init(42)
    assert.is_nil(ok)
    assert.is_truthy(err)
  end)

  it("returns error when directory does not exist", function()
    local audit = fresh_audit()
    local ok, err = audit.init("/nonexistent/dir/audit.log")
    assert.is_nil(ok)
    assert.is_truthy(err)
  end)

end)

-- ---------------------------------------------------------------------------
-- audit.log
-- ---------------------------------------------------------------------------

describe("audit.log", function()

  it("appends a valid JSON line", function()
    local audit = fresh_audit()
    local path  = tmp_path("log_basic")
    audit.init(path)

    local ok, err = audit.log("test.event", { key = "value" })
    assert.is_true(ok, tostring(err))

    local lines = read_lines(path)
    assert.equals(1, #lines)

    local obj = decode_line(lines[1])
    assert.equals("test.event", obj.event)
    assert.equals("value",      obj.data.key)

    cleanup(path)
  end)

  it("line includes ts, event, task_id, data fields", function()
    local audit = fresh_audit()
    local path  = tmp_path("log_fields")
    audit.init(path)
    audit.set_task_id("task-42")

    audit.log("fields.check", { x = 1 })

    local obj = decode_line(read_lines(path)[1])
    assert.is_truthy(obj.ts,      "ts field must be present")
    assert.is_truthy(obj.event,   "event field must be present")
    assert.equals("task-42",      obj.task_id)
    assert.is_truthy(obj.data,    "data field must be present")

    cleanup(path)
  end)

  it("ts is a valid ISO 8601 UTC timestamp", function()
    local audit = fresh_audit()
    local path  = tmp_path("log_ts")
    audit.init(path)
    audit.log("ts.check", {})

    local obj = decode_line(read_lines(path)[1])
    -- Format: 2024-01-15T10:30:00Z
    assert.is_truthy(obj.ts:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$"),
      "ts must match ISO 8601 UTC format, got: " .. tostring(obj.ts))

    cleanup(path)
  end)

  it("task_id is null in JSON when not set", function()
    local audit = fresh_audit()
    local path  = tmp_path("log_null_task")
    audit.init(path)
    -- Explicitly clear task_id
    audit.set_task_id(nil)
    audit.log("null.task", {})

    -- task_id should be JSON null, which cjson decodes as cjson.null (not Lua nil).
    -- We verify the field is present and falsy (null), not a real value.
    local cjson = require("cjson.safe")
    local raw   = read_lines(path)[1]
    local obj   = decode_line(raw)
    -- JSON null decodes to cjson.null userdata — confirm it is not a real value
    assert.is_true(obj.task_id == cjson.null, "task_id should be JSON null")
    -- Also confirm the raw JSON contains the null literal
    assert.is_truthy(raw:find('"task_id":null', 1, true))

    cleanup(path)
  end)

  it("multiple calls append multiple lines", function()
    local audit = fresh_audit()
    local path  = tmp_path("log_multi")
    audit.init(path)

    audit.log("first",  { n = 1 })
    audit.log("second", { n = 2 })
    audit.log("third",  { n = 3 })

    local lines = read_lines(path)
    assert.equals(3, #lines)
    assert.equals("first",  decode_line(lines[1]).event)
    assert.equals("second", decode_line(lines[2]).event)
    assert.equals("third",  decode_line(lines[3]).event)

    cleanup(path)
  end)

  it("each line is independent valid JSON (JSONL format)", function()
    local audit = fresh_audit()
    local path  = tmp_path("log_jsonl")
    audit.init(path)

    audit.log("a", { v = 1 })
    audit.log("b", { v = 2 })

    for _, line in ipairs(read_lines(path)) do
      local obj = decode_line(line)
      assert.is_truthy(obj.event)
    end

    cleanup(path)
  end)

  it("set_task_id changes the task_id in subsequent lines", function()
    local audit = fresh_audit()
    local path  = tmp_path("log_task_switch")
    audit.init(path)

    audit.set_task_id("task-A")
    audit.log("event.a", {})

    audit.set_task_id("task-B")
    audit.log("event.b", {})

    local lines = read_lines(path)
    assert.equals("task-A", decode_line(lines[1]).task_id)
    assert.equals("task-B", decode_line(lines[2]).task_id)

    cleanup(path)
  end)

  it("data can be any JSON-encodable value", function()
    local audit = fresh_audit()
    local path  = tmp_path("log_data_types")
    audit.init(path)

    audit.log("data.string", "hello")
    audit.log("data.number", 42)
    audit.log("data.table",  { nested = { deep = true } })
    audit.log("data.bool",   false)

    local lines = read_lines(path)
    assert.equals(4, #lines)
    assert.equals("hello", decode_line(lines[1]).data)
    assert.equals(42,      decode_line(lines[2]).data)
    assert.is_true(        decode_line(lines[3]).data.nested.deep)
    assert.is_false(       decode_line(lines[4]).data)

    cleanup(path)
  end)

  it("returns error when not initialised", function()
    local audit = fresh_audit()
    local ok, err = audit.log("some.event", {})
    assert.is_nil(ok)
    assert.is_truthy(err:find("not initialised"))
  end)

  it("returns error for empty event string", function()
    local audit = fresh_audit()
    local path  = tmp_path("log_empty_event")
    audit.init(path)

    local ok, err = audit.log("", {})
    assert.is_nil(ok)
    assert.is_truthy(err)

    cleanup(path)
  end)

  it("does not read the log file back during normal operation", function()
    -- Verify write-only by replacing io.open for reads and confirming no "r" opens happen.
    local audit  = fresh_audit()
    local path   = tmp_path("log_no_read")
    local read_attempts = 0

    audit.init(path)  -- init before patching

    local orig_open = io.open
    io.open = function(p, mode)
      if mode == "r" then read_attempts = read_attempts + 1 end
      return orig_open(p, mode)
    end

    audit.log("no.read", { x = 1 })
    audit.log("no.read", { x = 2 })

    io.open = orig_open

    assert.equals(0, read_attempts, "audit.log must never open the file for reading")

    cleanup(path)
  end)

end)

-- ---------------------------------------------------------------------------
-- audit.rotate
-- ---------------------------------------------------------------------------

describe("audit.rotate", function()

  it("does not rotate when file is under the size limit", function()
    local audit = fresh_audit()
    local path  = tmp_path("rot_small")
    audit.init(path)
    audit.log("event", { data = "small" })

    local ok, err = audit.rotate(100, 5)  -- 100 MB limit — will never trigger
    assert.is_true(ok, tostring(err))

    -- No .1 file should exist
    assert.is_nil(lfs.attributes(path .. ".1"), ".1 must not exist when under limit")

    cleanup(path)
  end)

  it("renames current log to .1 when size limit exceeded", function()
    local audit = fresh_audit()
    local path  = tmp_path("rot_rename")
    audit.init(path)

    -- Write enough to exceed a tiny limit
    for i = 1, 50 do
      audit.log("fill", { i = i, padding = string.rep("x", 100) })
    end

    local original_size = lfs.attributes(path, "size")
    assert.is_truthy(original_size > 0)

    -- Rotate with a 0.001 MB (1 KB) limit so it definitely triggers
    local ok, err = audit.rotate(0.001, 5)
    assert.is_true(ok, tostring(err))

    assert.is_truthy(lfs.attributes(path .. ".1"), ".1 must exist after rotation")
    assert.is_truthy(lfs.attributes(path),         "current log must exist (empty) after rotation")

    cleanup(path)
  end)

  it("creates a fresh empty log file after rotation", function()
    local audit = fresh_audit()
    local path  = tmp_path("rot_fresh")
    audit.init(path)

    for i = 1, 50 do
      audit.log("fill", { i = i, padding = string.rep("x", 100) })
    end

    audit.rotate(0.001, 5)

    local size = lfs.attributes(path, "size")
    assert.equals(0, size, "log file must be empty after rotation")

    cleanup(path)
  end)

  it("can log to the fresh file after rotation", function()
    local audit = fresh_audit()
    local path  = tmp_path("rot_after")
    audit.init(path)

    for i = 1, 50 do
      audit.log("fill", { i = i, padding = string.rep("x", 100) })
    end

    audit.rotate(0.001, 5)
    local ok, err = audit.log("post.rotation", { ok = true })
    assert.is_true(ok, tostring(err))

    local lines = read_lines(path)
    assert.equals(1, #lines)
    assert.equals("post.rotation", decode_line(lines[1]).event)

    cleanup(path)
  end)

  it("shifts .1 → .2 when rotating again", function()
    local audit = fresh_audit()
    local path  = tmp_path("rot_shift")
    audit.init(path)

    -- First rotation
    for i = 1, 50 do audit.log("fill", { i = i, p = string.rep("x", 100) }) end
    audit.rotate(0.001, 5)

    -- Second rotation
    for i = 1, 50 do audit.log("fill2", { i = i, p = string.rep("x", 100) }) end
    audit.rotate(0.001, 5)

    assert.is_truthy(lfs.attributes(path .. ".1"), ".1 must exist")
    assert.is_truthy(lfs.attributes(path .. ".2"), ".2 must exist after second rotation")

    cleanup(path)
  end)

  it("deletes oldest file beyond max_files", function()
    local audit = fresh_audit()
    local path  = tmp_path("rot_maxfiles")
    audit.init(path)

    -- Rotate max_files+1 times with max_files = 3
    for rotation = 1, 4 do
      for i = 1, 50 do audit.log("fill", { i = i, p = string.rep("x", 100) }) end
      audit.rotate(0.001, 3)
    end

    assert.is_truthy(lfs.attributes(path .. ".1"), ".1 must exist")
    assert.is_truthy(lfs.attributes(path .. ".2"), ".2 must exist")
    assert.is_truthy(lfs.attributes(path .. ".3"), ".3 must exist")
    assert.is_nil(lfs.attributes(path .. ".4"),    ".4 must not exist (max_files = 3)")

    cleanup(path, 5)
  end)

  it("returns error when not initialised", function()
    local audit = fresh_audit()
    local ok, err = audit.rotate(10, 5)
    assert.is_nil(ok)
    assert.is_truthy(err:find("not initialised"))
  end)

  it("returns error for invalid max_size_mb", function()
    local audit = fresh_audit()
    local path  = tmp_path("rot_bad_size")
    audit.init(path)

    local ok, err = audit.rotate(-1, 5)
    assert.is_nil(ok)
    assert.is_truthy(err)

    cleanup(path)
  end)

  it("returns error for invalid max_files", function()
    local audit = fresh_audit()
    local path  = tmp_path("rot_bad_files")
    audit.init(path)

    local ok, err = audit.rotate(10, 0)
    assert.is_nil(ok)
    assert.is_truthy(err)

    cleanup(path)
  end)

end)
