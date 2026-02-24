--- src/safe_fs.test.lua
--- Busted tests for src/safe_fs.lua

local lfs = require("lfs")

local _src = debug.getinfo(1, "S").source:match("^@(.*/)") or "./"
package.path = _src .. "?.lua;" .. package.path

local safe_fs = require("safe_fs")

-- ---------------------------------------------------------------------------
-- Test directory setup
-- ---------------------------------------------------------------------------

local cwd          = lfs.currentdir()
local TMP_ALLOWED  = cwd .. "/tmp_test_allowed"
local TMP_BLOCKED  = cwd .. "/tmp_test_blocked"

local function mkdir_if_missing(path)
  local attr = lfs.attributes(path)
  if not attr then
    assert(lfs.mkdir(path), "failed to create test dir: " .. path)
  end
end

local function rm_file(path)
  os.remove(path)
end

-- Create both dirs once before all tests.
mkdir_if_missing(TMP_ALLOWED)
mkdir_if_missing(TMP_BLOCKED)

-- Standard policy used by most tests.
local ALLOWED  = { TMP_ALLOWED .. "/*" }
local BLOCKED  = { TMP_BLOCKED .. "/*" }

-- ---------------------------------------------------------------------------
-- validate_policy
-- ---------------------------------------------------------------------------

describe("safe_fs.validate_policy", function()

  it("passes with valid non-empty allowed and no conflicts", function()
    local ok, err = safe_fs.validate_policy(ALLOWED, BLOCKED)
    assert.is_truthy(ok)
    assert.is_nil(err)
  end)

  it("fails when allowed_paths is nil", function()
    local ok, err = safe_fs.validate_policy(nil, BLOCKED)
    assert.is_nil(ok)
    assert.is_truthy(err)
  end)

  it("fails when allowed_paths is empty", function()
    local ok, err = safe_fs.validate_policy({}, BLOCKED)
    assert.is_nil(ok)
    assert.is_truthy(err)
  end)

  it("fails when a pattern appears in both lists", function()
    local overlap = TMP_ALLOWED .. "/*"
    local ok, err = safe_fs.validate_policy({ overlap }, { overlap })
    assert.is_nil(ok)
    assert.is_truthy(err)
    assert.is_truthy(err:find("conflict") or err:find("both"))
  end)

  it("passes when blocked_paths is nil", function()
    local ok, err = safe_fs.validate_policy(ALLOWED, nil)
    assert.is_truthy(ok)
    assert.is_nil(err)
  end)

end)

-- ---------------------------------------------------------------------------
-- glob_to_lua_pattern
-- ---------------------------------------------------------------------------

describe("safe_fs.glob_to_lua_pattern", function()

  it("anchors the pattern", function()
    local pat = safe_fs.glob_to_lua_pattern("/foo/bar")
    assert.equals("^/foo/bar$", pat)
  end)

  it("converts * to .*", function()
    local pat = safe_fs.glob_to_lua_pattern("/foo/*")
    assert.is_truthy(pat:find("%.%*"))
  end)

  it("converts ? to .", function()
    local pat = safe_fs.glob_to_lua_pattern("/foo/?.lua")
    assert.is_truthy(("/foo/x.lua"):match(pat))
    assert.is_falsy(("/foo/xy.lua"):match(pat))
  end)

  it("escapes Lua magic chars", function()
    local pat = safe_fs.glob_to_lua_pattern("/foo/bar.lua")
    -- The dot should be escaped so it only matches a literal dot
    assert.is_truthy(("/foo/bar.lua"):match(pat))
    assert.is_falsy(("/foo/barXlua"):match(pat))
  end)

  it("*.lua matches only .lua files", function()
    local pat = safe_fs.glob_to_lua_pattern(TMP_ALLOWED .. "/*.lua")
    assert.is_truthy((TMP_ALLOWED .. "/x.lua"):match(pat))
    assert.is_falsy((TMP_ALLOWED  .. "/x.txt"):match(pat))
  end)

end)

-- ---------------------------------------------------------------------------
-- normalize
-- ---------------------------------------------------------------------------

describe("safe_fs.normalize", function()

  it("resolves . segments", function()
    local n = safe_fs.normalize("/foo/./bar")
    assert.equals("/foo/bar", n)
  end)

  it("resolves .. segments", function()
    local n = safe_fs.normalize("/foo/bar/../baz")
    assert.equals("/foo/baz", n)
  end)

  it("makes relative paths absolute", function()
    local n = safe_fs.normalize("somefile.txt")
    assert.equals(cwd .. "/somefile.txt", n)
  end)

  it("does not go above filesystem root", function()
    local n = safe_fs.normalize("/../../etc/passwd")
    assert.equals("/etc/passwd", n)
  end)

end)

-- ---------------------------------------------------------------------------
-- is_allowed
-- ---------------------------------------------------------------------------

describe("safe_fs.is_allowed", function()

  it("allows a path inside allowed dir", function()
    local ok, err = safe_fs.is_allowed(TMP_ALLOWED .. "/out.lua", ALLOWED, BLOCKED)
    assert.is_true(ok)
    assert.is_nil(err)
  end)

  it("denies a path inside blocked dir", function()
    local ok, err = safe_fs.is_allowed(TMP_BLOCKED .. "/hack.lua", ALLOWED, BLOCKED)
    assert.is_false(ok)
    assert.is_truthy(err)
  end)

  it("denies traversal that resolves into blocked dir", function()
    local traversal = TMP_ALLOWED .. "/../tmp_test_blocked/escape.lua"
    local ok, err = safe_fs.is_allowed(traversal, ALLOWED, BLOCKED)
    assert.is_false(ok)
    assert.is_truthy(err)
  end)

  it("denies when allowed_paths is empty", function()
    local ok, err = safe_fs.is_allowed(TMP_ALLOWED .. "/out.lua", {}, BLOCKED)
    assert.is_false(ok)
    assert.is_truthy(err)
  end)

  it("denies when policy has overlap conflict", function()
    local overlap = TMP_BLOCKED .. "/*"
    local ok, err = safe_fs.is_allowed(
      TMP_BLOCKED .. "/file.lua",
      { TMP_ALLOWED .. "/*", overlap },
      { overlap }
    )
    assert.is_false(ok)
    assert.is_truthy(err)
  end)

  it("glob *.lua: allows .lua, denies .txt", function()
    local lua_patterns = { TMP_ALLOWED .. "/*.lua" }
    local ok1 = safe_fs.is_allowed(TMP_ALLOWED .. "/x.lua", lua_patterns, {})
    local ok2 = safe_fs.is_allowed(TMP_ALLOWED .. "/x.txt", lua_patterns, {})
    assert.is_true(ok1)
    assert.is_false(ok2)
  end)

end)

-- ---------------------------------------------------------------------------
-- write_file
-- ---------------------------------------------------------------------------

describe("safe_fs.write_file", function()

  it("writes a file inside the allowed path", function()
    local target = TMP_ALLOWED .. "/out.lua"
    rm_file(target)

    local ok, err = safe_fs.write_file(target, "-- hello\n", ALLOWED, BLOCKED)
    assert.is_truthy(ok)
    assert.is_nil(err)

    -- Confirm it actually landed on disk with the right content
    local f = assert(io.open(target, "r"))
    local content = f:read("*a")
    f:close()
    assert.equals("-- hello\n", content)

    rm_file(target)
  end)

  it("refuses to write inside the blocked path", function()
    local target = TMP_BLOCKED .. "/hack.lua"
    rm_file(target)

    local ok, err = safe_fs.write_file(target, "evil()\n", ALLOWED, BLOCKED)
    assert.is_nil(ok)
    assert.is_truthy(err)

    -- File must not have been created
    assert.is_nil(lfs.attributes(target), "file must not exist after denied write")
  end)

  it("refuses path traversal escaping the allowed dir", function()
    local traversal = TMP_ALLOWED .. "/../tmp_test_blocked/escape.lua"
    local target    = TMP_BLOCKED .. "/escape.lua"
    rm_file(target)

    local ok, err = safe_fs.write_file(traversal, "evil()\n", ALLOWED, BLOCKED)
    assert.is_nil(ok)
    assert.is_truthy(err)

    assert.is_nil(lfs.attributes(target), "escaped file must not exist")
  end)

  it("refuses when policy has an overlap conflict (blocked overrides allowed)", function()
    local overlap = TMP_BLOCKED .. "/*"
    local allowed = { TMP_ALLOWED .. "/*", overlap }
    local blocked = { overlap }

    local ok, err = safe_fs.write_file(
      TMP_BLOCKED .. "/file.lua", "x=1\n", allowed, blocked)
    assert.is_nil(ok)
    assert.is_truthy(err)
  end)

  it("glob *.lua: allows writing .lua but not .txt", function()
    local lua_patterns = { TMP_ALLOWED .. "/*.lua" }

    local ok_lua, _   = safe_fs.write_file(TMP_ALLOWED .. "/x.lua", "x=1\n", lua_patterns, {})
    local ok_txt, err = safe_fs.write_file(TMP_ALLOWED .. "/x.txt", "x=1\n", lua_patterns, {})

    assert.is_truthy(ok_lua)
    assert.is_nil(ok_txt)
    assert.is_truthy(err)

    rm_file(TMP_ALLOWED .. "/x.lua")
  end)

  it("fails if parent directory does not exist", function()
    local target = TMP_ALLOWED .. "/nonexistent_subdir/out.lua"
    local ok, err = safe_fs.write_file(target, "x=1\n",
      { TMP_ALLOWED .. "/*" }, {})
    assert.is_nil(ok)
    assert.is_truthy(err:find("parent directory"))
  end)

end)
