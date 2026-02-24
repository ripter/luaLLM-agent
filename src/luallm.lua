--- src/luallm.lua
--- Thin wrapper around the luallm CLI and its HTTP completion API.
--- Rocks: lua-cjson (cjson.safe), luasocket (socket.http, ltn12)

local cjson = require("cjson.safe")
local http  = require("socket.http")
local ltn12 = require("ltn12")

-- Ensure sibling modules in src/ are findable regardless of working directory.
local _src = debug.getinfo(1, "S").source:match("^@(.*/)") or "./"
package.path = _src .. "?.lua;" .. package.path

-- Config is loaded lazily so this module can be required before config.load().
local config = require("config")

local M = {}

-- Fallback binary name if config is unavailable.
local DEFAULT_BINARY = "luallm"

-- Truncation limit for error response bodies.
local MAX_BODY_IN_ERR = 2048

-- LLM inference can be slow. Override luasocket's default 60s timeout with
-- the value from config (limits.llm_timeout_seconds, default 120), and apply
-- it to socket.http before each request.
local function get_timeout()
  local ok, val = pcall(config.get, "limits.llm_timeout_seconds")
  if ok and type(val) == "number" and val > 0 then
    return val
  end
  return 120
end

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

--- Return the luallm binary path, loading config lazily if needed.
local function get_binary()
  local ok, val = pcall(config.get, "luallm.binary")
  if ok and type(val) == "string" and val ~= "" then
    return val
  end
  -- Config not loaded yet — try to load with default path.
  config.load()
  local ok2, val2 = pcall(config.get, "luallm.binary")
  if ok2 and type(val2) == "string" and val2 ~= "" then
    return val2
  end
  return DEFAULT_BINARY
end

--- Build a shell-safe quoted argument string from a list of strings.
local function build_cmd(binary, args)
  local parts = { binary }
  for _, a in ipairs(args) do
    -- Wrap each arg in single-quotes, escaping any single-quotes inside.
    parts[#parts + 1] = "'" .. tostring(a):gsub("'", "'\\''") .. "'"
  end
  return table.concat(parts, " ")
end

--- Return true if the args list already contains "--json".
local function has_json_flag(args)
  for _, a in ipairs(args) do
    if a == "--json" then return true end
  end
  return false
end

--- Return the list of server entries from a status response.
--- Tolerates several shapes:
---   { servers = [...] }         actual luallm shape, entry.model = name
---   { models = [...] }          entry.name = name
---   { running_models = [...] }  entry.name = name
---   bare array                  entry.name = name
local function get_servers(state)
  return state.servers
      or state.models
      or state.running_models
      or (type(state[1]) ~= "nil" and state)
      or {}
end

--- Extract the model name from a server entry (handles both .model and .name).
local function entry_name(entry)
  return entry.model or entry.name
end

--- Locate a server entry matching model_name (checks all entries, any state).
--- Returns the matching entry table, or nil.
local function find_model(state, model_name)
  for _, entry in ipairs(get_servers(state)) do
    if entry_name(entry) == model_name then
      return entry
    end
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Run `<binary> <args...> --json` and return the decoded JSON response.
--- Returns (table, nil) on success or (nil, error_string) on failure.
function M.exec(...)
  local args = { ... }

  if not has_json_flag(args) then
    args[#args + 1] = "--json"
  end

  local binary = get_binary()
  local cmd    = build_cmd(binary, args) .. " 2>&1"

  local fh, open_err = io.popen(cmd, "r")
  if not fh then
    return nil, "io.popen failed for: " .. cmd .. " (" .. tostring(open_err) .. ")"
  end

  local raw = fh:read("*a")
  fh:close()

  if not raw or raw == "" then
    return nil, "no output from command: " .. cmd
  end

  local decoded, parse_err = cjson.decode(raw)
  if not decoded then
    local snippet = raw:sub(1, 512):gsub("%s+$", "")
    return nil, "JSON parse error for `" .. cmd .. "`: " .. tostring(parse_err)
              .. "\n  output was: " .. snippet
  end

  return decoded, nil
end

--- Run `luallm status --json` and return the decoded state table.
--- Returns (table, nil) or (nil, error_string).
function M.state()
  return M.exec("status")
end

--- Return the name of the first model with state == "running", or (nil, err).
--- Useful when no specific model name is known.
function M.first_model()
  local state, err = M.state()
  if not state then
    return nil, err
  end
  for _, entry in ipairs(get_servers(state)) do
    if entry.state == "running" then
      local name = entry_name(entry)
      if name then return name, nil end
    end
  end
  return nil, "no running models found in luallm status"
end

--- Send a chat completion request to the running model.
---
--- @param model_name  string   Model to target (must appear in luallm state).
--- @param messages    table    Array of { role=..., content=... } messages.
--- @param options     table?   Optional extra fields merged into the request body.
--- @param port        number?  If provided, skips the luallm status call entirely.
--- Returns (table, nil) on success or (nil, error_string) on failure.
function M.complete(model_name, messages, options, port)
  if port then
    port = math.floor(port)
  else
    -- Locate the model port via luallm state (one subprocess call).
    local state, state_err = M.state()
    if not state then
      return nil, "luallm.state() failed: " .. tostring(state_err)
    end

    local entry = find_model(state, model_name)
    if not entry then
      return nil, "model not found in luallm state: " .. tostring(model_name)
    end

    if type(entry.port) ~= "number" or entry.port < 1 then
      return nil, "model '" .. model_name .. "' has no valid port in state"
    end
    port = math.floor(entry.port)
  end

  -- Build request payload.
  local payload = { model = model_name, messages = messages }
  if type(options) == "table" then
    for k, v in pairs(options) do
      payload[k] = v
    end
  end

  local body, encode_err = cjson.encode(payload)
  if not body then
    return nil, "failed to encode request body: " .. tostring(encode_err)
  end

  local url = "http://127.0.0.1:" .. port .. "/v1/chat/completions"

  -- Collect response body via ltn12 sink.
  -- Apply timeout before the request — luasocket's default 60s is too short
  -- for LLM inference. TIMEOUT is checked per-connection by socket.http.
  http.TIMEOUT = get_timeout()
  local resp_chunks = {}
  local result, status, resp_headers, status_line = http.request({
    url     = url,
    method  = "POST",
    headers = {
      ["Content-Type"]   = "application/json",
      ["Accept"]         = "application/json",
      ["Content-Length"] = tostring(#body),
    },
    source = ltn12.source.string(body),
    sink   = ltn12.sink.table(resp_chunks),
  })

  if not result then
    -- luasocket returns nil + error string on connection failure.
    return nil, "HTTP request failed: " .. tostring(status)
  end

  local resp_body = table.concat(resp_chunks)

  if type(status) ~= "number" or status < 200 or status > 299 then
    local snippet = resp_body:sub(1, MAX_BODY_IN_ERR)
    return nil, string.format(
      "HTTP %s from %s: %s", tostring(status), url, snippet)
  end

  local decoded, parse_err = cjson.decode(resp_body)
  if not decoded then
    local snippet = resp_body:sub(1, MAX_BODY_IN_ERR)
    return nil, "JSON decode failed (" .. tostring(parse_err) .. "): " .. snippet
  end

  return decoded, nil
end

return M
