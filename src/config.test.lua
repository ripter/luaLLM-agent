--- src/config.test.lua
--- Tests for src/config.lua  (busted test suite)

local cjson = require("cjson.safe")
local lfs   = require("lfs")

-- Make sure busted can find src/ modules regardless of where it is invoked from
local src_dir = debug.getinfo(1, "S").source:match("^@(.*/)") or "./"
package.path = src_dir .. "?.lua;" .. package.path

local config = require("config")

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------

local TEST_DIR  = "/tmp/luallm-agent-config-test-" .. os.time()
local TEST_CONF = TEST_DIR .. "/config.json"

local function write_config(tbl)
  lfs.mkdir(TEST_DIR)
  local f = assert(io.open(TEST_CONF, "w"))
  f:write(cjson.encode(tbl))
  f:close()
end

local function cleanup()
  os.execute("rm -rf " .. TEST_DIR)
end

-- Run cleanup once before the whole suite in case a previous run left debris
cleanup()

-- ---------------------------------------------------------------------------
-- Tests: validate
-- ---------------------------------------------------------------------------

describe("config.validate", function()

  it("accepts a valid full config", function()
    local ok, errs = config.validate({
      allowed_paths = { "/tmp" },
      blocked_paths = { "/etc" },
      approvals = {
        task_confirmation     = "prompt",
        path_read             = "auto",
        path_write            = "prompt",
        skill_promotion       = "manual",
        destructive_overwrite = "prompt",
        network_access        = "prompt",
      },
      limits = {
        max_task_steps              = 50,
        max_plan_retries            = 2,
        max_node_retries            = 3,
        max_skill_retries           = 3,
        llm_timeout_seconds         = 120,
        llm_backoff_base_seconds    = 1,
        llm_backoff_max_seconds     = 60,
        skill_exec_timeout_seconds  = 30,
        skill_memory_limit_mb       = 50,
        max_open_file_handles       = 10,
        model_start_timeout_seconds = 120,
      },
      audit          = { max_size_mb = 50, max_files = 5 },
      luallm         = { binary = "luallm", auto_start = false, auto_stop = false },
      model_selection = { default = { prefer = { "llama3-8b" }, fallback = {} } },
      editor         = "vim",
    })
    assert.is_true(ok)
  end)

  it("rejects a non-table", function()
    local ok, errs = config.validate("not a table")
    assert.is_false(ok)
    assert.equals(errs[1], "config must be a table")
  end)

  it("rejects an invalid approval value", function()
    local ok, errs = config.validate({
      approvals       = { task_confirmation = "yolo" },
      model_selection = { default = { prefer = {}, fallback = {} } },
    })
    assert.is_false(ok)
    assert.truthy(errs[1]:find("task_confirmation"))
  end)

  it("rejects a negative limit", function()
    local ok, errs = config.validate({
      limits          = { max_task_steps = -1 },
      model_selection = { default = { prefer = {}, fallback = {} } },
    })
    assert.is_false(ok)
    assert.truthy(errs[1]:find("max_task_steps"))
  end)

  it("rejects a string in limits", function()
    local ok = config.validate({
      limits          = { llm_timeout_seconds = "fast" },
      model_selection = { default = { prefer = {}, fallback = {} } },
    })
    assert.is_false(ok)
  end)

  it("rejects a non-boolean auto_start", function()
    local ok, errs = config.validate({
      luallm          = { auto_start = "yes" },
      model_selection = { default = { prefer = {}, fallback = {} } },
    })
    assert.is_false(ok)
    assert.truthy(errs[1]:find("auto_start"))
  end)

  it("rejects missing model_selection.default", function()
    local ok, errs = config.validate({
      model_selection = { planning = { prefer = { "x" }, fallback = {} } },
    })
    assert.is_false(ok)
    assert.truthy(errs[1]:find("default"))
  end)

  it("accepts an empty config (defaults will fill in)", function()
    local ok = config.validate({
      model_selection = { default = { prefer = {}, fallback = {} } },
    })
    assert.is_true(ok)
  end)

  it("rejects a non-string in allowed_paths", function()
    local ok, errs = config.validate({
      allowed_paths   = { "/tmp", 123 },
      model_selection = { default = { prefer = {}, fallback = {} } },
    })
    assert.is_false(ok)
    assert.truthy(errs[1]:find("allowed_paths"))
  end)

end)

-- ---------------------------------------------------------------------------
-- Tests: load + merge
-- ---------------------------------------------------------------------------

describe("config.load", function()

  after_each(cleanup)

  it("loads a valid config file", function()
    write_config({
      allowed_paths   = { "/tmp/test" },
      model_selection = { default = { prefer = { "test-model" }, fallback = {} } },
    })
    local ok, err = config.load(TEST_CONF)
    assert.is_true(ok, "load should succeed: " .. tostring(err))

    local paths = config.get("allowed_paths")
    assert.equals(type(paths), "table")
    assert.equals(paths[1], "/tmp/test")

    assert.equals(config.get("limits.llm_timeout_seconds"), 120)
  end)

  it("merges user overrides over defaults", function()
    write_config({
      limits          = { max_task_steps = 100 },
      model_selection = { default = { prefer = {}, fallback = {} } },
    })
    assert.is_true(config.load(TEST_CONF))
    assert.equals(config.get("limits.max_task_steps"), 100)
    assert.equals(config.get("limits.max_node_retries"), 3)
  end)

  it("enforces skill_promotion = manual", function()
    write_config({
      approvals       = { skill_promotion = "auto" },
      model_selection = { default = { prefer = {}, fallback = {} } },
    })
    assert.is_true(config.load(TEST_CONF))
    assert.equals(config.get("approvals.skill_promotion"), "manual")
  end)

  it("expands ~ in paths", function()
    local home = os.getenv("HOME") or ""
    write_config({
      allowed_paths   = { "~/data" },
      blocked_paths   = { "~/.ssh" },
      model_selection = { default = { prefer = {}, fallback = {} } },
    })
    assert.is_true(config.load(TEST_CONF))

    assert.equals(config.get("allowed_paths")[1], home .. "/data")

    local found = false
    for _, p in ipairs(config.get("blocked_paths")) do
      if p == home .. "/.ssh" then found = true; break end
    end
    assert.is_true(found, "~/.ssh should be expanded in blocked_paths")
  end)

  it("rejects invalid JSON", function()
    lfs.mkdir(TEST_DIR)
    local f = assert(io.open(TEST_CONF, "w"))
    f:write("not json {{{")
    f:close()
    local ok, err = config.load(TEST_CONF)
    assert.is_falsy(ok)
    assert.truthy(err:find("invalid JSON"))
  end)

  it("rejects a missing file", function()
    local ok, err = config.load("/tmp/nonexistent-luallm-config-" .. os.time() .. ".json")
    assert.is_falsy(ok)
    assert.truthy(err:find("cannot read"))
  end)

  it("rejects a config that fails validation", function()
    write_config({
      limits          = { max_task_steps = -5 },
      model_selection = { default = { prefer = {}, fallback = {} } },
    })
    local ok, err = config.load(TEST_CONF)
    assert.is_falsy(ok)
    assert.truthy(err:find("validation failed"))
  end)

end)

-- ---------------------------------------------------------------------------
-- Tests: get
-- ---------------------------------------------------------------------------

describe("config.get", function()

  after_each(cleanup)

  it("traverses nested keys", function()
    write_config({ model_selection = { default = { prefer = {}, fallback = {} } } })
    config.load(TEST_CONF)
    assert.equals(config.get("luallm.binary"),    "luallm")
    assert.equals(config.get("luallm.auto_start"), false)
    assert.equals(config.get("audit.max_files"),   5)
  end)

  it("returns nil for a missing path", function()
    write_config({ model_selection = { default = { prefer = {}, fallback = {} } } })
    config.load(TEST_CONF)
    assert.is_nil(config.get("nonexistent.deeply.nested"))
  end)

end)

-- ---------------------------------------------------------------------------
-- Tests: is_path_blocked / is_path_allowed
-- ---------------------------------------------------------------------------

describe("config.is_path_blocked", function()

  after_each(cleanup)

  it("matches exact paths and prefixes", function()
    write_config({
      blocked_paths   = { "/etc", "/var" },
      model_selection = { default = { prefer = {}, fallback = {} } },
    })
    config.load(TEST_CONF)
    assert.is_true(config.is_path_blocked("/etc"))
    assert.is_true(config.is_path_blocked("/etc/passwd"))
    assert.is_falsy(config.is_path_blocked("/tmp/safe"))
  end)

end)

describe("config.is_path_allowed", function()

  after_each(cleanup)

  it("checks allowed and blocked lists", function()
    write_config({
      allowed_paths   = { "/tmp/work", "~/data/*" },
      blocked_paths   = { "/etc" },
      model_selection = { default = { prefer = {}, fallback = {} } },
    })
    config.load(TEST_CONF)

    assert.is_true(config.is_path_allowed("/tmp/work/file.txt"))
    assert.is_falsy(config.is_path_allowed("/etc/passwd"))
    assert.is_falsy(config.is_path_allowed("/opt/random"))

    local home = os.getenv("HOME") or ""
    assert.is_true(config.is_path_allowed(home .. "/data/foo.csv"))
  end)

  it("blocked takes precedence over allowed", function()
    write_config({
      allowed_paths   = { "/etc/safe" },
      blocked_paths   = { "/etc" },
      model_selection = { default = { prefer = {}, fallback = {} } },
    })
    config.load(TEST_CONF)
    assert.is_falsy(config.is_path_allowed("/etc/safe/file"))
  end)

end)

-- ---------------------------------------------------------------------------
-- Tests: approval_tier
-- ---------------------------------------------------------------------------

describe("config.approval_tier", function()

  after_each(cleanup)

  it("returns configured values", function()
    write_config({
      approvals       = { path_read = "auto", path_write = "prompt" },
      model_selection = { default = { prefer = {}, fallback = {} } },
    })
    config.load(TEST_CONF)
    assert.equals(config.approval_tier("path_read"),  "auto")
    assert.equals(config.approval_tier("path_write"), "prompt")
  end)

  it("always returns manual for skill_promotion", function()
    write_config({
      approvals       = { skill_promotion = "auto" },
      model_selection = { default = { prefer = {}, fallback = {} } },
    })
    config.load(TEST_CONF)
    assert.equals(config.approval_tier("skill_promotion"), "manual")
  end)

  it("defaults to prompt for an unknown tier", function()
    write_config({ model_selection = { default = { prefer = {}, fallback = {} } } })
    config.load(TEST_CONF)
    assert.equals(config.approval_tier("unknown_tier"), "prompt")
  end)

end)

-- ---------------------------------------------------------------------------
-- Tests: model_policy
-- ---------------------------------------------------------------------------

describe("config.model_policy", function()

  after_each(cleanup)

  it("returns the specific policy when defined", function()
    write_config({
      model_selection = {
        planning = { prefer = { "big-model" },   fallback = { "small-model" } },
        default  = { prefer = { "small-model" }, fallback = {} },
      },
    })
    config.load(TEST_CONF)
    local p = config.model_policy("planning")
    assert.equals(p.prefer[1],   "big-model")
    assert.equals(p.fallback[1], "small-model")
  end)

  it("falls back to default for an unknown type", function()
    write_config({
      model_selection = { default = { prefer = { "fallback-model" }, fallback = {} } },
    })
    config.load(TEST_CONF)
    assert.equals(config.model_policy("some_unknown_type").prefer[1], "fallback-model")
  end)

end)

-- ---------------------------------------------------------------------------
-- Tests: init
-- ---------------------------------------------------------------------------

describe("config.init", function()

  it("creates the directory skeleton and a default config", function()
    local dir = "/tmp/luallm-agent-init-test-" .. os.time()
    local path, err = config.init(dir)
    assert.truthy(path, "init should return a path: " .. tostring(err))
    assert.truthy(lfs.attributes(path))
    assert.truthy(lfs.attributes(dir .. "/state"))
    assert.truthy(lfs.attributes(dir .. "/state/pending_approvals"))
    assert.truthy(lfs.attributes(dir .. "/skills/agent"))
    assert.truthy(lfs.attributes(dir .. "/skills/allowed"))
    assert.truthy(lfs.attributes(dir .. "/skills/allowed/.archive"))
    assert.is_true(config.load(path))
    os.execute("rm -rf " .. dir)
  end)

  it("does not overwrite an existing config", function()
    local dir = "/tmp/luallm-agent-init-test2-" .. os.time()
    config.init(dir)
    local path, note = config.init(dir)
    assert.truthy(path)
    assert.equals(note, "already exists")
    os.execute("rm -rf " .. dir)
  end)

end)

-- ---------------------------------------------------------------------------
-- Tests: pretty_json
-- ---------------------------------------------------------------------------

describe("config.pretty_json", function()

  it("round-trips through cjson", function()
    local tbl = { name = "test", items = { 1, 2, 3 }, nested = { a = true, b = "hello" } }
    local decoded = cjson.decode(config.pretty_json(tbl))
    assert.equals(decoded.name,      "test")
    assert.equals(#decoded.items,    3)
    assert.equals(decoded.nested.a,  true)
  end)

end)
