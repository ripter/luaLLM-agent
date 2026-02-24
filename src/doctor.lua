--- src/doctor.lua
--- Health checks for luaLLM-agent. Called by `lua main.lua doctor [--fix]`.

local lfs = require("lfs")

local _src = debug.getinfo(1, "S").source:match("^@(.*/)") or "./"
package.path = _src .. "?.lua;" .. package.path

local config = require("config")

local M = {}

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

--- Try to resolve a bare command name or path to a real executable.
local function which(binary)
  if binary:match("^[./]") then
    local a = lfs.attributes(binary)
    return (a and a.mode == "file") and binary or nil
  end
  local fh = io.popen('command -v ' .. binary .. ' 2>/dev/null', "r")
  if not fh then return nil end
  local out = fh:read("*l")
  fh:close()
  return (out and out ~= "") and out or nil
end

--- Check whether a rock is loadable via require().
local function rock_available(mod)
  return pcall(require, mod)
end

--- Run `luarocks install <label>` and return (ok, output).
local function luarocks_install(label)
  local fh = io.popen('luarocks install ' .. label .. ' 2>&1', "r")
  if not fh then return false, "could not run luarocks" end
  local out = fh:read("*a")
  local ok  = fh:close()
  return ok == true, out
end

-- ---------------------------------------------------------------------------
-- Check definitions
-- Each check is a table with:
--   run()        → { name, ok, detail }
--   fix()?       → { ok, detail }   (only present when auto-fix is possible)
-- ---------------------------------------------------------------------------

local checks = {}

-- 1. Config file exists -------------------------------------------------------
checks[#checks+1] = {
  run = function()
    local path = config.default_path()
    local attr = lfs.attributes(path)
    if attr and attr.mode == "file" then
      return { name = "Config file exists", ok = true, detail = path }
    else
      return { name = "Config file exists", ok = false,
               detail = "not found at " .. path }
    end
  end,
  fix = function()
    local path, err = config.init()
    if path then
      return { ok = true,  detail = "created config and directory skeleton at " .. path }
    else
      return { ok = false, detail = "config.init() failed: " .. tostring(err) }
    end
  end,
}

-- 2. Config is valid JSON and passes validation -------------------------------
checks[#checks+1] = {
  run = function()
    local ok, err = config.load()
    if ok then
      return { name = "Config is valid", ok = true, detail = config.path() }
    else
      return { name = "Config is valid", ok = false, detail = tostring(err) }
    end
  end,
  -- No auto-fix: corrupted/invalid config requires human intervention.
}

-- 3. luallm.binary is set in config -------------------------------------------
checks[#checks+1] = {
  run = function()
    pcall(config.load)
    local ok, binary = pcall(config.get, "luallm.binary")
    if ok and type(binary) == "string" and binary ~= "" then
      return { name = "luallm.binary configured", ok = true, detail = binary }
    else
      return { name = "luallm.binary configured", ok = false,
               detail = "luallm.binary is missing or empty in config" }
    end
  end,
  -- No auto-fix: user must choose the correct binary path themselves.
}

-- 4. luallm binary is reachable -----------------------------------------------
checks[#checks+1] = {
  run = function()
    pcall(config.load)
    local ok, binary = pcall(config.get, "luallm.binary")
    binary = (ok and binary) or "luallm"
    local resolved = which(binary)
    if resolved then
      return { name = "luallm binary found", ok = true, detail = resolved }
    else
      return { name = "luallm binary found", ok = false,
               detail = "'" .. binary .. "' not found on PATH\n"
                     .. "Set luallm.binary in your config to the correct path" }
    end
  end,
  -- No auto-fix: we can't install luallm on the user's behalf.
}

-- 5. Required rocks -----------------------------------------------------------
local REQUIRED_ROCKS = {
  { rock = "cjson.safe",  label = "lua-cjson"    },
  { rock = "lfs",         label = "luafilesystem" },
  { rock = "socket.http", label = "luasocket"     },
  { rock = "ltn12",       label = "luasocket"     },  -- same rock as above
  { rock = "ansicolors",  label = "ansicolors"    },
  { rock = "argparse",    label = "argparse"      },
}

for _, r in ipairs(REQUIRED_ROCKS) do
  local rock, label = r.rock, r.label
  checks[#checks+1] = {
    run = function()
      if rock_available(rock) then
        return { name = "Rock: " .. label, ok = true,
                 detail = "require('" .. rock .. "') OK" }
      else
        return { name = "Rock: " .. label, ok = false,
                 detail = "not loadable" }
      end
    end,
    fix = function()
      local ok, out = luarocks_install(label)
      if ok then
        return { ok = true,  detail = "luarocks install " .. label .. " succeeded" }
      else
        local snippet = (out or ""):sub(1, 300)
        return { ok = false, detail = "luarocks install " .. label .. " failed:\n" .. snippet }
      end
    end,
  }
end

-- 6. State directory exists ---------------------------------------------------
checks[#checks+1] = {
  run = function()
    local dir  = config.default_dir() .. "/state"
    local attr = lfs.attributes(dir)
    if attr and attr.mode == "directory" then
      return { name = "State directory exists", ok = true, detail = dir }
    else
      return { name = "State directory exists", ok = false,
               detail = "not found: " .. dir }
    end
  end,
  fix = function()
    -- config.init() creates the full skeleton including state/.
    local path, err = config.init()
    if path then
      return { ok = true,  detail = "created directory skeleton" }
    else
      return { ok = false, detail = "config.init() failed: " .. tostring(err) }
    end
  end,
}

-- 7. allowed_paths is non-empty -----------------------------------------------
checks[#checks+1] = {
  run = function()
    pcall(config.load)
    local ok, paths = pcall(config.get, "allowed_paths")
    if ok and type(paths) == "table" and #paths > 0 then
      return { name = "allowed_paths configured", ok = true,
               detail = #paths .. " pattern(s) set" }
    else
      return { name = "allowed_paths configured", ok = false,
               detail = "allowed_paths is empty or missing — generate will deny all writes\n"
                     .. "Add at least one path glob to allowed_paths in your config" }
    end
  end,
}

-- 8. No pattern overlap between allowed_paths and blocked_paths ---------------
checks[#checks+1] = {
  run = function()
    pcall(config.load)
    local ok1, allowed = pcall(config.get, "allowed_paths")
    local ok2, blocked = pcall(config.get, "blocked_paths")
    allowed = (ok1 and type(allowed) == "table") and allowed or {}
    blocked = (ok2 and type(blocked) == "table") and blocked or {}

    local allowed_set = {}
    for _, p in ipairs(allowed) do allowed_set[p] = true end
    local overlaps = {}
    for _, p in ipairs(blocked) do
      if allowed_set[p] then overlaps[#overlaps+1] = p end
    end

    if #overlaps == 0 then
      return { name = "No allowed/blocked path conflicts", ok = true,
               detail = "no overlapping patterns" }
    else
      return { name = "No allowed/blocked path conflicts", ok = false,
               detail = "pattern(s) in both allowed_paths and blocked_paths:\n"
                     .. "  " .. table.concat(overlaps, "\n  ") }
    end
  end,
}

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Run all checks. If `fix` is true, attempt to auto-fix failing checks.
--- Returns a list of result tables:
---   { name, ok, detail, fixed?, fix_detail? }
function M.run(fix)
  local results = {}
  for _, check in ipairs(checks) do
    local r = check.run()
    if not r.ok and fix and check.fix then
      local fr = check.fix()
      r.fixed      = fr.ok
      r.fix_detail = fr.detail
      -- Re-run the check so the final status reflects whether the fix worked.
      if fr.ok then
        r = check.run()
        r.fixed      = true
        r.fix_detail = fr.detail
      end
    end
    results[#results+1] = r
  end
  return results
end

return M
