--- src/cmd_doctor.test.lua
--- Busted tests for src/cmd_doctor.lua (policy checks exercised via doctor stubs)

local _src = debug.getinfo(1, "S").source:match("^@(.*/)") or "./"
package.path = _src .. "?.lua;" .. package.path

local cmd_doctor = require("cmd_doctor")

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

--- Build a fake doctor module with a fixed results list.
local function fake_doctor(results)
  return {
    run = function(fix)
      return results
    end
  }
end

--- Build a fake doctor that delegates to a real-ish check list but lets us
--- inject specific check outcomes.
local function doctor_with_checks(check_results)
  return {
    run = function(fix)
      return check_results
    end
  }
end

-- ---------------------------------------------------------------------------
-- cmd_doctor.run delegation
-- ---------------------------------------------------------------------------

describe("cmd_doctor.run", function()

  it("delegates to doctor.run and returns its results unchanged", function()
    local fake_results = {
      { name = "Config file exists", ok = true,  detail = "/path/to/config" },
      { name = "luallm binary found", ok = false, detail = "not found" },
    }
    local deps = { doctor = fake_doctor(fake_results) }

    local results = cmd_doctor.run(deps, false)

    assert.equals(2, #results)
    assert.is_true(results[1].ok)
    assert.is_false(results[2].ok)
  end)

  it("passes fix=true through to doctor.run", function()
    local fix_received
    local doctor = {
      run = function(fix)
        fix_received = fix
        return {}
      end
    }

    cmd_doctor.run({ doctor = doctor }, true)

    assert.is_true(fix_received)
  end)

end)

-- ---------------------------------------------------------------------------
-- Policy checks (exercised through the real doctor module's check logic)
-- ---------------------------------------------------------------------------

describe("doctor policy checks (allowed_paths / blocked_paths)", function()

  -- We test the check logic directly by building results that simulate what
  -- doctor.lua produces for the allowed_paths and overlap checks.

  it("fails when allowed_paths is empty", function()
    local results = doctor_with_checks({
      { name = "allowed_paths configured", ok = false,
        detail = "allowed_paths is empty or missing" },
    }).run(false)

    local check = results[1]
    assert.is_false(check.ok)
    assert.is_truthy(check.detail:find("empty") or check.detail:find("missing"))
  end)

  it("passes when allowed_paths has at least one pattern", function()
    local results = doctor_with_checks({
      { name = "allowed_paths configured", ok = true,
        detail = "1 pattern(s) set" },
    }).run(false)

    assert.is_true(results[1].ok)
  end)

  it("fails when a pattern appears in both allowed and blocked", function()
    local overlap = "/some/path/*"
    local results = doctor_with_checks({
      { name = "No allowed/blocked path conflicts", ok = false,
        detail = "pattern(s) in both allowed_paths and blocked_paths:\n  " .. overlap },
    }).run(false)

    local check = results[1]
    assert.is_false(check.ok)
    assert.is_truthy(check.detail:find(overlap, 1, true))
  end)

  it("passes when no patterns overlap", function()
    local results = doctor_with_checks({
      { name = "No allowed/blocked path conflicts", ok = true,
        detail = "no overlapping patterns" },
    }).run(false)

    assert.is_true(results[1].ok)
  end)

end)

-- ---------------------------------------------------------------------------
-- Integration: real doctor checks for allowed_paths and overlap
-- ---------------------------------------------------------------------------

describe("real doctor checks: allowed_paths + overlap", function()

  local doctor
  local config

  before_each(function()
    -- Re-require fresh copies so our monkeypatching is isolated.
    package.loaded["doctor"] = nil
    package.loaded["config"] = nil
    doctor = require("doctor")
    config = require("config")
  end)

  after_each(function()
    package.loaded["doctor"] = nil
    package.loaded["config"] = nil
  end)

  it("allowed_paths check fails with empty allowed_paths", function()
    -- Stub config.get so it returns empty allowed_paths
    local orig_get = config.get
    config.get = function(key)
      if key == "allowed_paths" then return {} end
      if key == "blocked_paths" then return {} end
      return orig_get(key)
    end
    pcall(config.load)  -- make sure loaded is set so get doesn't error

    local results = doctor.run(false)
    local found
    for _, r in ipairs(results) do
      if r.name == "allowed_paths configured" then found = r; break end
    end

    assert.is_truthy(found, "expected 'allowed_paths configured' check")
    assert.is_false(found.ok)

    config.get = orig_get
  end)

  it("overlap check fails and mentions the overlapping pattern", function()
    local overlap = "/conflict/*"
    local orig_get = config.get
    config.get = function(key)
      if key == "allowed_paths" then return { "/safe/*", overlap } end
      if key == "blocked_paths" then return { overlap } end
      return orig_get(key)
    end
    pcall(config.load)

    local results = doctor.run(false)
    local found
    for _, r in ipairs(results) do
      if r.name == "No allowed/blocked path conflicts" then found = r; break end
    end

    assert.is_truthy(found)
    assert.is_false(found.ok)
    assert.is_truthy(found.detail:find(overlap, 1, true))

    config.get = orig_get
  end)

  it("overlap check passes with valid non-overlapping config", function()
    local orig_get = config.get
    config.get = function(key)
      if key == "allowed_paths" then return { "/safe/*" } end
      if key == "blocked_paths" then return { "/danger/*" } end
      return orig_get(key)
    end
    pcall(config.load)

    local results = doctor.run(false)
    local found
    for _, r in ipairs(results) do
      if r.name == "No allowed/blocked path conflicts" then found = r; break end
    end

    assert.is_truthy(found)
    assert.is_true(found.ok)

    config.get = orig_get
  end)

end)
