#!/usr/bin/env lua

-- ---------------------------------------------------------------------------
-- main.lua — luaLLM-agent CLI runner
-- Rocks: argparse, ansicolors, luafilesystem (lfs)
-- ---------------------------------------------------------------------------

local colors   = require "ansicolors"
local argparse = require "argparse"
local lfs      = require "lfs"

local script_dir = arg[0]:match("(.*/)") or "./"

-- Shorthand: apply an ansicolors tag to text and reset after.
local function co(tag, text)
  return colors(tag .. text .. "%{reset}")
end

-- ---------------------------------------------------------------------------
-- Command: test
-- ---------------------------------------------------------------------------

--- Recursively collect files matching a suffix under a directory,
--- returned in sorted order. Uses lfs.dir() — no shell subprocess needed.
local function find_files(dir, suffix, results)
  results = results or {}
  local attr = lfs.attributes(dir)
  if not attr or attr.mode ~= "directory" then return results end
  local entries = {}
  for entry in lfs.dir(dir) do
    if entry ~= "." and entry ~= ".." then
      entries[#entries + 1] = entry
    end
  end
  table.sort(entries)
  for _, entry in ipairs(entries) do
    local path = dir .. "/" .. entry
    local a    = lfs.attributes(path)
    if a then
      if a.mode == "directory" then
        find_files(path, suffix, results)
      elseif a.mode == "file" and path:sub(-#suffix) == suffix then
        results[#results + 1] = path
      end
    end
  end
  return results
end

local function run_tests()
  local src_dir = script_dir .. "src"

  -- Sanity-check: make sure there are test files before invoking busted
  local files = find_files(src_dir, ".test.lua")
  if #files == 0 then
    print("")
    print(co("%{yellow}", "  ⚠  No test files found")
          .. co("%{dim}", " (looked in " .. src_dir .. "/*.test.lua)"))
    print("")
    os.exit(0)
  end

  -- Hand off entirely to busted — it owns discovery, output, and exit code.
  -- --pattern matches any file ending in .test.lua anywhere under src/
  local cmd = string.format('busted --pattern=".test.lua$" "%s"', src_dir)
  os.exit(os.execute(cmd) == true and 0 or 1)
end


-- ---------------------------------------------------------------------------
-- Command: doctor
-- ---------------------------------------------------------------------------

local function run_doctor(args)
  -- Add src/ to path so doctor.lua can find its siblings.
  package.path = script_dir .. "src/?.lua;" .. package.path
  local doctor = require("doctor")

  local fix = args and args.fix

  print("")
  if fix then
    print(co("%{bright magenta}", "  luaLLM-agent doctor --fix"))
    print(co("%{dim}", "  Checking your environment and fixing what we can…"))
  else
    print(co("%{bright magenta}", "  luaLLM-agent doctor"))
    print(co("%{dim}", "  Checking your environment…"))
  end
  print("")

  local results = doctor.run(fix)
  local n_ok    = 0
  local n_fail  = 0

  for _, r in ipairs(results) do
    if r.ok then
      n_ok = n_ok + 1
      print(co("%{green}", "  ✓ ") .. co("%{bright white}", r.name))
      print(co("%{dim}",   "      " .. r.detail))
      if r.fixed then
        print(co("%{cyan}", "      ↳ fixed: ") .. co("%{dim}", r.fix_detail))
      end
    else
      n_fail = n_fail + 1
      -- Fixed but still failing (e.g. luarocks install failed)
      if r.fixed == false then
        print(co("%{yellow}", "  ~ ") .. co("%{bright white}", r.name))
        print(co("%{yellow}", "      fix attempted but failed:"))
        for line in (r.fix_detail .. "\n"):gmatch("([^\n]*)\n") do
          print(co("%{yellow}", "      " .. line))
        end
      else
        print(co("%{red}", "  ✗ ") .. co("%{bright white}", r.name))
        for line in (r.detail .. "\n"):gmatch("([^\n]*)\n") do
          print(co("%{yellow}", "      " .. line))
        end
        if not fix and r.fixable then
          print(co("%{dim}", "      → run with --fix to attempt auto-fix"))
        end
      end
    end
    print("")
  end

  print(co("%{dim}", "  " .. string.rep("─", 50)))
  if n_fail == 0 then
    print(co("%{bright green}", "  ✓ All " .. n_ok .. " checks passed"))
  else
    print(co("%{bright red}", "  ✗ " .. n_fail .. " check(s) failed, " .. n_ok .. " passed"))
    if not fix then
      print(co("%{dim}", "  Tip: run with --fix to auto-fix what we can"))
    end
  end
  print("")

  os.exit(n_fail > 0 and 1 or 0)
end

-- ---------------------------------------------------------------------------
-- Command: quick-prompt
-- ---------------------------------------------------------------------------

local function run_quick_prompt(args)
  package.path = script_dir .. "src/?.lua;" .. package.path
  local luallm = require("luallm")

  local prompt = args.prompt

  -- One status call to get both model name and port — complete() reuses it.
  local state, state_err = luallm.state()
  if not state then
    print("")
    print(co("%{red}", "  ✗ Could not reach luallm:"))
    print(co("%{yellow}", "    " .. tostring(state_err)))
    print(co("%{dim}", "    Is luallm running? Try: lua main.lua doctor"))
    print("")
    os.exit(1)
  end

  local model, port
  for _, entry in ipairs(state.servers or {}) do
    if entry.state == "running" and (entry.model or entry.name) and entry.port then
      model = entry.model or entry.name
      port  = math.floor(entry.port)
      break
    end
  end

  if not model then
    print("")
    print(co("%{red}", "  ✗ No running model found in luallm status"))
    print(co("%{dim}", "    Is luallm running? Try: lua main.lua doctor"))
    print("")
    os.exit(1)
  end

  io.write(co("%{dim}", "  model: " .. model .. "  …") .. "\n")

  local response, req_err = luallm.complete(model, {
    { role = "user", content = prompt },
  }, nil, port)

  if not response then
    print("")
    print(co("%{red}", "  ✗ Request failed:"))
    print(co("%{yellow}", "    " .. tostring(req_err)))
    print("")
    os.exit(1)
  end

  -- Extract content from OpenAI-style response.
  local content_text = response.choices
                   and response.choices[1]
                   and response.choices[1].message
                   and response.choices[1].message.content

  if not content_text then
    print("")
    print(co("%{red}", "  ✗ Unexpected response shape (no choices[1].message.content)"))
    print(co("%{dim}", "    " .. require("cjson.safe").encode(response):sub(1, 300)))
    print("")
    os.exit(1)
  end

  print("")
  print(content_text)
  print("")
end

-- ---------------------------------------------------------------------------
-- Command: generate
-- ---------------------------------------------------------------------------

-- Default system prompt for Lua code generation.
-- Override via generate.system_prompt in config.json.
local DEFAULT_GENERATE_SYSTEM_PROMPT =
  "You are a Lua code generator. Output ONLY valid Lua code. " ..
  "No markdown fences, no explanations, no commentary. " ..
  "Start with the first line of code."

local function run_generate(args)
  package.path = script_dir .. "src/?.lua;" .. package.path
  local luallm  = require("luallm")
  local safe_fs = require("safe_fs")
  local config  = require("config")

  local output_path = args.output_path
  local prompt      = args.prompt

  -- Load config for policy and optional overrides.
  pcall(config.load)

  -- Resolve path policy from config.
  local allowed = (pcall(config.get, "allowed_paths") and config.get("allowed_paths")) or {}
  local blocked = (pcall(config.get, "blocked_paths") and config.get("blocked_paths")) or {}

  -- Validate policy before doing any LLM work.
  local pol_ok, pol_err = safe_fs.validate_policy(allowed, blocked)
  if not pol_ok then
    print("")
    print(co("%{red}", "  ✗ Path policy is invalid:"))
    print(co("%{yellow}", "    " .. tostring(pol_err)))
    print(co("%{dim}", "    Fix allowed_paths / blocked_paths in your config, then retry."))
    print(co("%{dim}", "    Run: lua main.lua doctor"))
    print("")
    os.exit(1)
  end

  -- Check write permission before spending time on LLM inference.
  local allowed_ok, allowed_err = safe_fs.is_allowed(output_path, allowed, blocked)
  if not allowed_ok then
    print("")
    print(co("%{red}", "  ✗ Write not permitted:"))
    print(co("%{yellow}", "    " .. tostring(allowed_err)))
    print("")
    os.exit(1)
  end

  -- Resolve system prompt (config override or default).
  local sys_prompt
  local sp_ok, sp_val = pcall(config.get, "generate.system_prompt")
  if sp_ok and type(sp_val) == "string" and sp_val ~= "" then
    sys_prompt = sp_val
  else
    sys_prompt = DEFAULT_GENERATE_SYSTEM_PROMPT
  end

  -- Discover model and port in one status call.
  local state, state_err = luallm.state()
  if not state then
    print("")
    print(co("%{red}", "  ✗ Could not reach luallm:"))
    print(co("%{yellow}", "    " .. tostring(state_err)))
    print(co("%{dim}", "    Is luallm running? Try: lua main.lua doctor"))
    print("")
    os.exit(1)
  end

  local model, port
  for _, entry in ipairs(state.servers or {}) do
    if entry.state == "running" and (entry.model or entry.name) and entry.port then
      model = entry.model or entry.name
      port  = math.floor(entry.port)
      break
    end
  end

  -- Allow config to override the model choice.
  local cfg_model_ok, cfg_model = pcall(config.get, "luallm.model")
  if cfg_model_ok and type(cfg_model) == "string" and cfg_model ~= "" then
    model = cfg_model
    -- When a specific model is configured, look up its port fresh.
    port = nil
  end

  if not model then
    print("")
    print(co("%{red}", "  ✗ No running model found in luallm status"))
    print(co("%{dim}", "    Is luallm running? Try: lua main.lua doctor"))
    print("")
    os.exit(1)
  end

  io.write(co("%{dim}", "  model: " .. model .. "  generating…") .. "\n")

  local response, req_err = luallm.complete(model, {
    { role = "system", content = sys_prompt },
    { role = "user",   content = prompt     },
  }, nil, port)

  if not response then
    print("")
    print(co("%{red}", "  ✗ LLM request failed:"))
    print(co("%{yellow}", "    " .. tostring(req_err)))
    print("")
    os.exit(1)
  end

  local content_text = response.choices
                   and response.choices[1]
                   and response.choices[1].message
                   and response.choices[1].message.content

  if not content_text then
    print("")
    print(co("%{red}", "  ✗ Unexpected response shape (no choices[1].message.content)"))
    print(co("%{dim}", "    " .. require("cjson.safe").encode(response):sub(1, 300)))
    print("")
    os.exit(1)
  end

  -- Write file (policy already checked above, but write_file re-checks for safety).
  local write_ok, write_err = safe_fs.write_file(output_path, content_text, allowed, blocked)
  if not write_ok then
    print("")
    print(co("%{red}", "  ✗ Failed to write output file:"))
    print(co("%{yellow}", "    " .. tostring(write_err)))
    print("")
    os.exit(1)
  end

  -- Extract token usage.
  local tokens = "unknown"
  if response.usage and response.usage.total_tokens then
    tokens = tostring(math.floor(response.usage.total_tokens))
  elseif response.usage and response.usage.completion_tokens then
    tokens = tostring(math.floor(response.usage.completion_tokens)) .. " (completion)"
  end

  print("")
  print(co("%{bright green}", "  ✓ ") .. co("%{bright white}", "Wrote:  ") .. output_path)
  print(co("%{dim}",          "    ")  .. co("%{bright white}", "Model:  ") .. model)
  print(co("%{dim}",          "    ")  .. co("%{bright white}", "Tokens: ") .. tokens)
  print("")
end

-- ---------------------------------------------------------------------------
-- Command registry
-- To add a new command: append an entry here, then add its argparse options
-- in the dispatch section below.
-- ---------------------------------------------------------------------------

local COMMANDS = {
  {
    name  = "test",
    usage = "",
    desc  = "Run all tests in src/*.test.lua and report results.",
    fn    = run_tests,
  },
  {
    name  = "doctor",
    usage = "[--fix]",
    desc  = "Check your environment: config, luallm binary, required rocks.",
    fn    = run_doctor,
    setup = function(parser)
      parser:flag("--fix", "Attempt to automatically fix failing checks.")
    end,
  },
  {
    name  = "quick-prompt",
    usage = "<prompt>",
    desc  = "Send a prompt to the first running model and print the response.",
    fn    = run_quick_prompt,
    setup = function(parser)
      parser:argument("prompt", "The prompt text to send.")
    end,
  },
  {
    name  = "generate",
    usage = "<output_path> <prompt>",
    desc  = "Generate Lua code from a prompt and write it to output_path.",
    fn    = run_generate,
    setup = function(parser)
      parser:argument("output_path", "File path to write the generated Lua code to.")
      parser:argument("prompt",      "Description of the Lua code to generate.")
    end,
  },
}

-- ---------------------------------------------------------------------------
-- Colored help printer
-- ---------------------------------------------------------------------------

local function print_help(cmd_name)
  if cmd_name then
    -- Per-command help
    for _, cmd in ipairs(COMMANDS) do
      if cmd.name == cmd_name then
        print("")
        print(co("%{bright cyan}", "  " .. cmd.name)
              .. (cmd.usage ~= "" and "  " .. co("%{dim}", cmd.usage) or ""))
        print("  " .. cmd.desc)
        print("")
        return
      end
    end
    print("")
    print(co("%{yellow}", "  Unknown command: ") .. co("%{bright white}", cmd_name))
    print("  Run " .. co("%{cyan}", "lua main.lua help") .. " to see all commands.")
    print("")
    os.exit(1)
  end

  -- Full help
  print("")
  print(co("%{bright magenta}", "  luaLLM-agent") .. co("%{dim}", " — a Lua LLM agent framework"))
  print("")
  print(co("%{bright white}", "  Usage:"))
  print("    " .. co("%{cyan}", "lua main.lua") .. " " .. co("%{bright white}", "<command>") .. " [options]")
  print("")
  print(co("%{bright white}", "  Commands:"))
  for _, cmd in ipairs(COMMANDS) do
    local name_col = string.format("    %-12s", cmd.name)
    local args_col = cmd.usage ~= "" and co("%{dim}", string.format("%-18s", cmd.usage))
                     or string.rep(" ", 18)
    print(co("%{cyan}", name_col) .. args_col .. cmd.desc)
  end
  -- help is meta; add it manually so it appears in the listing
  print(co("%{cyan}", string.format("    %-12s", "help"))
        .. co("%{dim}", string.format("%-18s", "[command]"))
        .. "Show this help message, or help for a specific command.")
  print("")
  print(co("%{bright white}", "  Flags:"))
  print(co("%{cyan}", "    -h, --help") .. "      Same as the help command.")
  print("")
  print(co("%{dim}", "  Examples:"))
  print(co("%{dim}", "    lua main.lua test"))
  print(co("%{dim}", "    lua main.lua help test"))
  print("")
end

-- ---------------------------------------------------------------------------
-- Dispatch
-- ---------------------------------------------------------------------------

local cmd_name = arg[1]

if cmd_name == nil or cmd_name == "help" or cmd_name == "-h" or cmd_name == "--help" then
  -- bare help / flags → full help; "help <cmd>" → per-command help
  print_help(arg[2])
else
  local matched = false
  for _, cmd in ipairs(COMMANDS) do
    if cmd.name == cmd_name then
      matched = true
      -- Give each command its own argparse parser so it gets --help for free
      local parser = argparse("lua main.lua " .. cmd.name, cmd.desc)
      if cmd.setup then cmd.setup(parser) end
      local sub_arg = {}
      for i = 2, #arg do sub_arg[i - 1] = arg[i] end
      local ok, parsed_args = parser:pparse(sub_arg)
      if not ok then
        print("")
        print(co("%{red}", "  Error: ") .. parsed_args)
        print("  Run " .. co("%{cyan}", "lua main.lua help " .. cmd.name) .. " for usage.")
        print("")
        os.exit(1)
      end
      cmd.fn(parsed_args)
      break
    end
  end

  if not matched then
    print("")
    print(co("%{red}", "  Unknown command: ") .. co("%{bright white}", cmd_name))
    print("  Run " .. co("%{cyan}", "lua main.lua help") .. " to see available commands.")
    print("")
    os.exit(1)
  end
end
