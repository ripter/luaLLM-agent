--- src/luallm.lua
--- Thin wrapper around the luallm CLI and its HTTP completion API.
--- Rocks: lua-cjson (cjson.safe), luasocket (socket.http, ltn12)

local cjson = require("cjson.safe")
local http  = require("socket.http")
local ltn12 = require("ltn12")

-- Ensure sibling modules in src/ are findable regardless of working directory.
local _src = debug.getinfo(1, "S").source:match("^@(.*/)" ) or "./"
package.path = _src .. "?.lua;" .. package.path

local config = require("config")

local M = {}

local DEFAULT_BINARY = "luallm"
local MAX_BODY_IN_ERR = 2048

local function get_timeout(override)
  if type(override) == "number" and override > 0 then
    return override
  end
  local ok, val = pcall(config.get, "limits.llm_timeout_seconds")
  if ok and type(val) == "number" and val > 0 then
    return val
  end
  return 300
end

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

local function get_binary()
  local ok, val = pcall(config.get, "luallm.binary")
  if ok and type(val) == "string" and val ~= "" then
    return val
  end
  config.load()
  local ok2, val2 = pcall(config.get, "luallm.binary")
  if ok2 and type(val2) == "string" and val2 ~= "" then
    return val2
  end
  return DEFAULT_BINARY
end

local function build_cmd(binary, args)
  local parts = { binary }
  for _, a in ipairs(args) do
    parts[#parts + 1] = "'" .. tostring(a):gsub("'", "'\\''") .. "'"
  end
  return table.concat(parts, " ")
end

local function has_json_flag(args)
  for _, a in ipairs(args) do
    if a == "--json" then return true end
  end
  return false
end

--- Return the list of server entries from a status response.
local function get_servers(state)
  return state.servers
      or state.models
      or state.running_models
      or (type(state[1]) ~= "nil" and state)
      or {}
end

--- Extract the model name from a server entry.
local function entry_name(entry)
  return entry.model or entry.name
end

--- Locate a server entry matching model_name.
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

function M.state()
  return M.exec("status")
end

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

--- Pick the best model+port from a status response.
--- Priority: config luallm.model > first running server > state.last_used.
--- Returns (model_name, port_or_nil).
--- This is the SINGLE implementation — cmd_generate and cmd_quick both use it.
function M.resolve_model(state)
  -- 1. Config explicit model.
  local cfg_ok, cfg_model = pcall(config.get, "luallm.model")
  if cfg_ok and type(cfg_model) == "string" and cfg_model ~= "" then
    return cfg_model, nil
  end

  -- 2. First running server.
  for _, entry in ipairs(get_servers(state)) do
    if entry.state == "running" and (entry.model or entry.name) and entry.port then
      return entry.model or entry.name, math.floor(entry.port)
    end
  end

  -- 3. last_used fallback — only if it is actually running.
  -- We deliberately do NOT fall back to a stopped/loading last_used model:
  -- attempting complete() against a non-running model produces a confusing
  -- "connection refused" error rather than a clear "no model running" message.
  if type(state.last_used) == "string" and state.last_used ~= "" then
    for _, entry in ipairs(get_servers(state)) do
      if (entry.model or entry.name) == state.last_used
         and entry.state == "running"
         and entry.port then
        return state.last_used, math.floor(entry.port)
      end
    end
  end

  return nil, nil
end

function M.complete(model_name, messages, options, port)
  if port then
    port = math.floor(port)
  else
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

  local timeout_override = nil
  local payload = { model = model_name, messages = messages }
  if type(options) == "table" then
    for k, v in pairs(options) do
      if k == "_timeout" then
        timeout_override = v
      else
        payload[k] = v
      end
    end
  end

  local body, encode_err = cjson.encode(payload)
  if not body then
    return nil, "failed to encode request body: " .. tostring(encode_err)
  end

  local url = "http://127.0.0.1:" .. port .. "/v1/chat/completions"

  http.TIMEOUT = get_timeout(timeout_override)
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

--- Start the luallm server.
--- When model_name is provided, starts that specific model; otherwise starts
--- the default (luallm picks it).
--- Returns (true) on success or (nil, error_string) on failure.
function M.start(model_name)
  local args = { "start" }
  if type(model_name) == "string" and model_name ~= "" then
    args[#args + 1] = model_name
  end
  local result, err = M.exec(table.unpack(args))
  if not result then
    return nil, "luallm start failed: " .. tostring(err)
  end
  return true
end

return M
