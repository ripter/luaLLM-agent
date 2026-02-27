--- agent/config.lua
--- Configuration loader, validator, and accessor for luallm-agent.
--- Uses luarocks: cjson, luafilesystem (lfs), penlight

local cjson = require("cjson.safe")
local lfs   = require("lfs")
local util  = require("util")

local M = {}

-- ---------------------------------------------------------------------------
-- Internal state
-- ---------------------------------------------------------------------------

local loaded   = nil   -- parsed config table (nil until load() succeeds)
local cfg_path = nil   -- absolute path that was loaded

local HOME = os.getenv("HOME") or os.getenv("USERPROFILE") or ""
local DEFAULT_DIR  = HOME .. "/.config/luallmagent"
local DEFAULT_PATH = DEFAULT_DIR .. "/config.json"

-- ---------------------------------------------------------------------------
-- Defaults
-- ---------------------------------------------------------------------------

local DEFAULT_CONFIG = {
  ["$schema"] = "luallm-agent-config-v1",

  allowed_paths = {},
  blocked_paths = {
    "~/.ssh",
    "~/.gnupg",
    "/etc",
    "/usr",
    "/var",
  },

  approvals = {
    task_confirmation    = "prompt",
    path_read            = "auto",
    path_write           = "prompt",
    skill_promotion      = "manual",
    destructive_overwrite = "prompt",
    network_access       = "prompt",
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

  audit = {
    max_size_mb = 50,
    max_files   = 5,
  },

  luallm = {
    binary     = "luallm",
    auto_start = false,
    auto_stop  = false,
  },

  model_selection = {
    default = {
      prefer   = {},
      fallback = {},
    },
  },

  editor = "$EDITOR",
}

-- ---------------------------------------------------------------------------
-- Validation
-- ---------------------------------------------------------------------------

local VALID_APPROVAL_VALUES = { auto = true, prompt = true, manual = true }

local APPROVAL_KEYS = {
  "task_confirmation", "path_read", "path_write",
  "skill_promotion", "destructive_overwrite", "network_access",
}

local LIMIT_KEYS = {
  "max_task_steps", "max_plan_retries", "max_node_retries",
  "max_skill_retries", "llm_timeout_seconds", "llm_backoff_base_seconds",
  "llm_backoff_max_seconds", "skill_exec_timeout_seconds",
  "skill_memory_limit_mb", "max_open_file_handles",
  "model_start_timeout_seconds",
}

--- Validate a config table. Returns true or false + list of error strings.
function M.validate(cfg)
  local errors = {}

  local function err(msg)
    errors[#errors + 1] = msg
  end

  if type(cfg) ~= "table" then
    return false, { "config must be a table" }
  end

  -- allowed_paths / blocked_paths: must be arrays of strings
  for _, key in ipairs({ "allowed_paths", "blocked_paths" }) do
    if cfg[key] ~= nil then
      if type(cfg[key]) ~= "table" then
        err(key .. " must be an array of strings")
      else
        for i, v in ipairs(cfg[key]) do
          if type(v) ~= "string" then
            err(key .. "[" .. i .. "] must be a string")
          end
        end
      end
    end
  end

  -- approvals
  if cfg.approvals ~= nil then
    if type(cfg.approvals) ~= "table" then
      err("approvals must be a table")
    else
      for _, key in ipairs(APPROVAL_KEYS) do
        local v = cfg.approvals[key]
        if v ~= nil and not VALID_APPROVAL_VALUES[v] then
          err("approvals." .. key .. " must be one of: auto, prompt, manual (got: " .. tostring(v) .. ")")
        end
      end
    end
  end

  -- limits: all must be positive numbers
  if cfg.limits ~= nil then
    if type(cfg.limits) ~= "table" then
      err("limits must be a table")
    else
      for _, key in ipairs(LIMIT_KEYS) do
        local v = cfg.limits[key]
        if v ~= nil then
          if type(v) ~= "number" or v <= 0 then
            err("limits." .. key .. " must be a positive number (got: " .. tostring(v) .. ")")
          end
        end
      end
    end
  end

  -- audit
  if cfg.audit ~= nil then
    if type(cfg.audit) ~= "table" then
      err("audit must be a table")
    else
      if cfg.audit.max_size_mb ~= nil then
        if type(cfg.audit.max_size_mb) ~= "number" or cfg.audit.max_size_mb <= 0 then
          err("audit.max_size_mb must be a positive number")
        end
      end
      if cfg.audit.max_files ~= nil then
        if type(cfg.audit.max_files) ~= "number" or cfg.audit.max_files < 1 then
          err("audit.max_files must be a positive integer")
        end
      end
    end
  end

  -- luallm
  if cfg.luallm ~= nil then
    if type(cfg.luallm) ~= "table" then
      err("luallm must be a table")
    else
      if cfg.luallm.binary ~= nil and type(cfg.luallm.binary) ~= "string" then
        err("luallm.binary must be a string")
      end
      if cfg.luallm.auto_start ~= nil and type(cfg.luallm.auto_start) ~= "boolean" then
        err("luallm.auto_start must be a boolean")
      end
      if cfg.luallm.auto_stop ~= nil and type(cfg.luallm.auto_stop) ~= "boolean" then
        err("luallm.auto_stop must be a boolean")
      end
    end
  end

  -- model_selection
  if cfg.model_selection ~= nil then
    if type(cfg.model_selection) ~= "table" then
      err("model_selection must be a table")
    else
      if not cfg.model_selection.default then
        err("model_selection must contain a 'default' entry")
      end
      for name, entry in pairs(cfg.model_selection) do
        if type(entry) ~= "table" then
          err("model_selection." .. name .. " must be a table")
        else
          if entry.prefer ~= nil and type(entry.prefer) ~= "table" then
            err("model_selection." .. name .. ".prefer must be an array")
          end
          if entry.fallback ~= nil and type(entry.fallback) ~= "table" then
            err("model_selection." .. name .. ".fallback must be an array")
          end
        end
      end
    end
  end

  -- editor
  if cfg.editor ~= nil and type(cfg.editor) ~= "string" then
    err("editor must be a string")
  end

  if #errors > 0 then
    return false, errors
  end
  return true
end

-- ---------------------------------------------------------------------------
-- Enforcement (post-validation fixups that are not optional)
-- ---------------------------------------------------------------------------

local function enforce_invariants(cfg)
  if cfg.approvals then
    cfg.approvals.skill_promotion = "manual"
  end
  return cfg
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function M.default_dir()
  return DEFAULT_DIR
end

function M.default_path()
  return DEFAULT_PATH
end

--- Generate the default config.json and directory skeleton.
function M.init(dir)
  dir = dir or DEFAULT_DIR
  local ok, err = util.mkdir_p(dir)
  if not ok then return nil, err end

  for _, sub in ipairs({ "state", "state/pending_approvals", "skills", "skills/agent", "skills/allowed", "skills/allowed/.archive" }) do
    local subdir = dir .. "/" .. sub
    ok, err = util.mkdir_p(subdir)
    if not ok then return nil, err end
  end

  local path = dir .. "/config.json"

  if lfs.attributes(path) then
    return path, "already exists"
  end

  local content = M.pretty_json(DEFAULT_CONFIG)

  ok, err = util.write_file_atomic(path, content .. "\n")
  if not ok then return nil, err end

  return path
end

--- Load config from disk, merge with defaults, validate, enforce invariants.
function M.load(path)
  path = path or DEFAULT_PATH

  local raw, read_err = util.read_file(path)
  if not raw then
    return nil, "cannot read config: " .. (read_err or path)
  end

  local parsed, parse_err = cjson.decode(raw)
  if not parsed then
    return nil, "invalid JSON in " .. path .. ": " .. (parse_err or "unknown error")
  end

  local merged = util.deep_merge(DEFAULT_CONFIG, parsed)

  local ok, errs = M.validate(merged)
  if not ok then
    return nil, "config validation failed:\n  " .. table.concat(errs, "\n  ")
  end

  merged = enforce_invariants(merged)
  merged = util.expand_paths(merged)

  loaded   = merged
  cfg_path = path
  return true
end

--- Get a value by dotted path, e.g. config.get("luallm.binary").
function M.get(dotted_path)
  if not loaded then
    error("config not loaded: call config.load() first")
  end

  local current = loaded
  for segment in dotted_path:gmatch("[^%.]+") do
    if type(current) ~= "table" then return nil end
    current = current[segment]
  end
  return current
end

function M.all()
  if not loaded then
    error("config not loaded: call config.load() first")
  end
  return loaded
end

function M.path()
  return cfg_path
end

--- Check whether a path is blocked or allowed.
--- Delegates to safe_fs for the actual matching (single source of truth).
--- safe_fs is lazy-loaded to avoid circular dependency at require time.
function M.is_path_blocked(path)
  if not loaded then
    error("config not loaded: call config.load() first")
  end
  local safe_fs = require("safe_fs")
  path = util.expand_tilde(path)
  local abs = util.normalize(path)
  for _, blocked in ipairs(loaded.blocked_paths or {}) do
    if safe_fs.glob_match(abs, blocked) then
      return true, blocked
    end
  end
  return false
end

function M.is_path_allowed(path)
  if not loaded then
    error("config not loaded: call config.load() first")
  end

  local blocked, by = M.is_path_blocked(path)
  if blocked then
    return false, "blocked by: " .. by
  end

  local safe_fs = require("safe_fs")
  path = util.expand_tilde(path)
  local abs = util.normalize(path)
  for _, allowed in ipairs(loaded.allowed_paths or {}) do
    if safe_fs.glob_match(abs, allowed) then
      return true
    end
  end

  return false, "not in allowed_paths"
end

function M.approval_tier(tier_name)
  if not loaded then
    error("config not loaded: call config.load() first")
  end

  if tier_name == "skill_promotion" then
    return "manual"
  end

  local val = loaded.approvals and loaded.approvals[tier_name]
  if not val then
    return "prompt"
  end
  return val
end

function M.model_policy(task_type)
  if not loaded then
    error("config not loaded: call config.load() first")
  end

  local sel = loaded.model_selection or {}
  local policy = sel[task_type] or sel["default"]

  if not policy then
    return { prefer = {}, fallback = {} }
  end

  return {
    prefer   = policy.prefer   or {},
    fallback = policy.fallback or {},
  }
end

function M.is_writable()
  if not cfg_path then return false end
  local f = io.open(cfg_path, "a")
  if f then
    f:close()
    return true
  end
  return false
end

-- ---------------------------------------------------------------------------
-- Pretty JSON (minimal, for init output)
-- ---------------------------------------------------------------------------

function M.pretty_json(val, indent)
  indent = indent or 0
  local pad  = string.rep("  ", indent)
  local pad1 = string.rep("  ", indent + 1)

  if type(val) == "nil" then
    return "null"
  elseif type(val) == "boolean" then
    return tostring(val)
  elseif type(val) == "number" then
    return tostring(val)
  elseif type(val) == "string" then
    return cjson.encode(val)
  elseif type(val) == "table" then
    if util.is_array(val) then
      if #val == 0 then return "[]" end
      local items = {}
      for _, v in ipairs(val) do
        items[#items + 1] = pad1 .. M.pretty_json(v, indent + 1)
      end
      return "[\n" .. table.concat(items, ",\n") .. "\n" .. pad .. "]"
    else
      local keys = {}
      for k in pairs(val) do keys[#keys + 1] = k end
      table.sort(keys)

      if #keys == 0 then return "{}" end

      local items = {}
      for _, k in ipairs(keys) do
        items[#items + 1] = pad1 .. cjson.encode(k) .. ": " .. M.pretty_json(val[k], indent + 1)
      end
      return "{\n" .. table.concat(items, ",\n") .. "\n" .. pad .. "}"
    end
  else
    return cjson.encode(tostring(val))
  end
end

return M
