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

-- 7b. State dir is in allowed_paths -------------------------------------------
-- The agent writes plan.md files into the state directory.  Without write
-- access there, commands like `agent run` and `plan run` will fail.
checks[#checks+1] = {
  run = function()
    pcall(config.load)
    local state_dir = config.default_dir() .. "/state"
    local ok, paths = pcall(config.get, "allowed_paths")
    paths = (ok and type(paths) == "table") and paths or {}

    for _, p in ipairs(paths) do
      if p == state_dir then
        return { name = "State dir in allowed_paths", ok = true,
                 detail = state_dir }
      end
    end

    return { name = "State dir in allowed_paths", ok = false,
             detail = state_dir .. " is not in allowed_paths.\n"
                   .. "The agent writes plan files here. Without it, `agent run` and\n"
                   .. "`plan run` will fail with a write-denied error.\n"
                   .. "Add it to your config.json:\n"
                   .. '  "allowed_paths": ["' .. state_dir .. '", ...]' }
  end,
  -- No auto-fix: allowed_paths is 100% human-controlled.
}

-- Helper: read agent.output_dir from the raw config file (not merged defaults).
-- Returns the string value, or nil if not set by the user.
local function raw_output_dir()
  local cjson = require("cjson.safe")
  local path  = config.default_path()
  local f     = io.open(path, "r")
  if not f then return nil end
  local raw = f:read("*a")
  f:close()
  local parsed = cjson.decode(raw)
  if type(parsed) ~= "table" then return nil end
  if type(parsed.agent) ~= "table" then return nil end
  local dir = parsed.agent.output_dir
  if type(dir) ~= "string" or dir == "" then return nil end
  -- Expand ~ so lfs.attributes and glob checks work correctly.
  local pl_path = require("pl.path")
  return pl_path.expanduser(dir)
end

-- 7c. agent.output_dir is configured -----------------------------------------
checks[#checks+1] = {
  run = function()
    local dir = raw_output_dir()
    if dir then
      return { name = "agent.output_dir configured", ok = true, detail = dir }
    else
      return { name = "agent.output_dir configured", ok = false,
               detail = "agent.output_dir is not set in your config.json.\n"
                     .. "Agent task outputs will have nowhere to go.\n"
                     .. "Add to your config.json:\n"
                     .. '  "agent": { "output_dir": "~/agent_wrote" }' }
    end
  end,
  -- No auto-fix: the user must choose their preferred output location.
}

-- 7d. agent.output_dir exists on disk -----------------------------------------
checks[#checks+1] = {
  run = function()
    local dir = raw_output_dir()
    if not dir then
      return { name = "agent.output_dir exists", ok = false,
               detail = "agent.output_dir is not configured (see previous check)" }
    end
    local attr = lfs.attributes(dir)
    if attr and attr.mode == "directory" then
      return { name = "agent.output_dir exists", ok = true, detail = dir }
    else
      return { name = "agent.output_dir exists", ok = false,
               detail = "directory not found: " .. dir .. "\n"
                     .. "Run with --fix to create it, or create it manually:\n"
                     .. "  mkdir -p " .. dir }
    end
  end,
  fix = function()
    local dir = raw_output_dir()
    if not dir then
      return { ok = false, detail = "agent.output_dir is not configured" }
    end
    local util = require("util")
    local ok, err = util.mkdir_p(dir)
    if ok then
      return { ok = true, detail = "created " .. dir }
    else
      return { ok = false, detail = "mkdir failed: " .. tostring(err) }
    end
  end,
}

-- 7e. agent.output_dir is covered by allowed_paths ----------------------------
-- Without this, every agent task will fail with a write-denied error when
-- trying to write generated files into the task output directory.
checks[#checks+1] = {
  run = function()
    local dir = raw_output_dir()
    if not dir then
      return { name = "agent.output_dir in allowed_paths", ok = false,
               detail = "agent.output_dir is not configured (see previous check)" }
    end
    pcall(config.load)
    local ok, paths = pcall(config.get, "allowed_paths")
    paths = (ok and type(paths) == "table") and paths or {}

    local safe_fs = require("safe_fs")
    -- Probe a representative nested path to test real glob matching.
    local probe = dir:gsub("/*$", "") .. "/test-task-id/main.lua"
    for _, p in ipairs(paths) do
      if safe_fs.glob_match(probe, p) then
        return { name = "agent.output_dir in allowed_paths", ok = true,
                 detail = dir .. " is covered by pattern: " .. p }
      end
    end

    local glob = dir:gsub("/*$", "") .. "/*"
    return { name = "agent.output_dir in allowed_paths", ok = false,
             detail = dir .. " is not covered by any allowed_paths pattern.\n"
                   .. "Generated files will be denied by safe_fs.\n"
                   .. "Add to your config.json allowed_paths:\n"
                   .. '  "' .. glob .. '"' }
  end,
  -- No auto-fix: allowed_paths is human-controlled.
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

-- 9. luallm server is running with at least one loaded model ------------------
checks[#checks+1] = {
  run = function()
    local luallm = require("luallm")
    local state, err = luallm.state()
    if not state then
      return { name = "luallm server running", ok = false,
               detail = "could not reach luallm daemon: " .. tostring(err) .. "\n"
                     .. "Start it with:  luallm start <model>" }
    end

    local running = {}
    for _, s in ipairs(state.servers or {}) do
      if s.state == "running" then
        running[#running + 1] = s.model .. " (port " .. tostring(s.port) .. ")"
      end
    end

    if #running == 0 then
      local hint = "Start a model with:  luallm start <model>"
      if state.last_used and state.last_used ~= "" then
        hint = "Restart last-used model with:  luallm start " .. state.last_used
      end
      return { name = "luallm server running", ok = false,
               detail = "luallm daemon is reachable but no model is currently loaded.\n"
                     .. hint }
    end

    return { name = "luallm server running", ok = true,
             detail = table.concat(running, ", ") }
  end,
}

-- 10. A model can be resolved for agent tasks ---------------------------------
checks[#checks+1] = {
  run = function()
    local luallm = require("luallm")

    -- Check config key first.
    pcall(config.load)
    local model
    pcall(function()
      model = config.get("luallm.model")
    end)
    if model and model ~= "" then
      return { name = "Agent model resolvable", ok = true,
               detail = model .. " (from config)" }
    end

    -- Ask luallm.state() directly — ground truth.
    local state, state_err = luallm.state()
    if state then
      local resolved, port = luallm.resolve_model(state)
      if resolved and resolved ~= "" then
        return { name = "Agent model resolvable", ok = true,
                 detail = resolved .. " (live, port " .. tostring(port) .. ")"
                       .. "\n      Tip: pin it in config.json to avoid surprises:"
                       .. '\n        "luallm": { "model": "' .. resolved .. '" }' }
      end
      local hint = state.last_used and state.last_used ~= ""
        and "Restart last-used model:  luallm start " .. state.last_used
        or  "Start a model with:       luallm start <model>"
      return { name = "Agent model resolvable", ok = false,
               detail = "luallm is running but no model is loaded.\n" .. hint }
    end

    return { name = "Agent model resolvable", ok = false,
             detail = "Could not reach luallm: " .. tostring(state_err) .. "\n"
                   .. "Start it with:  luallm start <model>" }
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
