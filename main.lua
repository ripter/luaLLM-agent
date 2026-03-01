#!/usr/bin/env lua

-- ---------------------------------------------------------------------------
-- main.lua — luaLLM-agent CLI dispatcher
-- Rocks: argparse, ansicolors, luafilesystem (lfs)
-- ---------------------------------------------------------------------------

local colors   = require "ansicolors"
local argparse = require "argparse"
local lfs      = require "lfs"

local script_dir = arg[0]:match("(.*/)") or "./"
package.path = script_dir .. "src/?.lua;" .. package.path

-- Shorthand: apply an ansicolors tag to text and reset after.
local function co(tag, text)
  return colors(tag .. text .. "%{reset}")
end

-- ---------------------------------------------------------------------------
-- Command: test
-- ---------------------------------------------------------------------------

local function find_files(dir, suffix, results)
  results = results or {}
  local attr = lfs.attributes(dir)
  if not attr or attr.mode ~= "directory" then return results end
  local entries = {}
  for entry in lfs.dir(dir) do
    if entry ~= "." and entry ~= ".." then entries[#entries + 1] = entry end
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
  local files   = find_files(src_dir, ".test.lua")
  if #files == 0 then
    print("")
    print(co("%{yellow}", "  ⚠  No test files found")
          .. co("%{dim}", " (looked in " .. src_dir .. "/*.test.lua)"))
    print("")
    os.exit(0)
  end
  local cmd = string.format('busted --pattern=".test.lua$" "%s"', src_dir)
  os.exit(os.execute(cmd) == true and 0 or 1)
end

-- ---------------------------------------------------------------------------
-- Command: doctor
-- ---------------------------------------------------------------------------

local function run_doctor(args)
  local doctor = require("doctor")
  local fix    = args and args.fix

  print("")
  if fix then
    print(co("%{bright magenta}", "  luaLLM-agent doctor --fix"))
    print(co("%{dim}", "  Checking your environment and fixing what we can…"))
  else
    print(co("%{bright magenta}", "  luaLLM-agent doctor"))
    print(co("%{dim}", "  Checking your environment…"))
  end
  print("")

  local results = require("cmd_doctor").run({ doctor = doctor }, fix)
  local n_ok, n_fail = 0, 0

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
  local luallm = require("luallm")
  local config = require("config")

  local content, err_or_info = require("cmd_quick").run(
    { luallm = luallm, config = config },
    { prompt = args.prompt }
  )

  if not content then
    print("")
    -- err_or_info may be a multiline error string — print each line indented.
    for line in (tostring(err_or_info) .. "\n"):gmatch("([^\n]*)\n") do
      if line ~= "" then
        print(co("%{red}", "  ✗ ") .. line)
      end
    end
    print("")
    os.exit(1)
  end

  if err_or_info.started then
    io.write(co("%{dim}", "  (auto-started luallm)\n"))
  end
  io.write(co("%{dim}", "  model: " .. err_or_info.model .. "  …") .. "\n")
  print("")
  print(content)
  print("")
end

-- ---------------------------------------------------------------------------
-- Command: generate
-- ---------------------------------------------------------------------------

local function run_generate(args)
  local luallm      = require("luallm")
  local safe_fs     = require("safe_fs")
  local config      = require("config")
  local cmd_gen     = require("cmd_generate")

  local prompt, prompt_err = cmd_gen.resolve_prompt(args.prompt)
  if not prompt then
    print("")
    print(co("%{red}", "  ✗ " .. tostring(prompt_err)))
    print("")
    os.exit(1)
  end

  io.write(co("%{dim}", "  generating…") .. "\n")

  local ok, err_or_info = cmd_gen.run(
    { luallm = luallm, safe_fs = safe_fs, config = config },
    { output_path = args.output_path, prompt = prompt }
  )

  if not ok then
    print("")
    print(co("%{red}", "  ✗ " .. tostring(err_or_info)))
    print("")
    os.exit(1)
  end

  print("")
  print(co("%{bright green}", "  ✓ ") .. co("%{bright white}", "Wrote:  ") .. err_or_info.output_path)
  print(co("%{dim}",          "    ")  .. co("%{bright white}", "Model:  ") .. err_or_info.model)
  print(co("%{dim}",          "    ")  .. co("%{bright white}", "Tokens: ") .. err_or_info.tokens)
  print("")
end

-- ---------------------------------------------------------------------------
-- Command: generate-with-context
-- ---------------------------------------------------------------------------

local function run_generate_with_context(args)
  local luallm  = require("luallm")
  local safe_fs = require("safe_fs")
  local config  = require("config")
  local cmd_gen = require("cmd_generate")

  local prompt, prompt_err = cmd_gen.resolve_prompt(args.prompt)
  if not prompt then
    print("")
    print(co("%{red}", "  ✗ " .. tostring(prompt_err)))
    print("")
    os.exit(1)
  end

  -- Show where the prompt came from so the user can confirm the right source.
  local prompt_source
  if args.prompt == "-" then
    prompt_source = "stdin"
  elseif args.prompt:sub(1,1) == "@" then
    prompt_source = args.prompt:sub(2)
  else
    prompt_source = "inline"
  end

  local context_paths = args.context

  io.write(co("%{dim}", "  prompt: " .. prompt_source) .. "\n")
  io.write(co("%{dim}", "  reading " .. #context_paths .. " context file(s)…") .. "\n")
  io.write(co("%{dim}", "  generating…") .. "\n")

  local ok, err_or_info = require("cmd_generate_context").run(
    { luallm       = luallm,
      safe_fs      = safe_fs,
      config       = config,
      cmd_generate = cmd_gen },
    { output_path   = args.output_path,
      context_paths = context_paths,
      prompt        = prompt }
  )

  if not ok then
    print("")
    print(co("%{red}", "  ✗ " .. tostring(err_or_info)))
    print("")
    os.exit(1)
  end

  print("")
  print(co("%{bright green}", "  ✓ ") .. co("%{bright white}", "Wrote:  ") .. err_or_info.output_path)
  print(co("%{dim}",          "    ")  .. co("%{bright white}", "Model:  ") .. err_or_info.model)
  print(co("%{dim}",          "    ")  .. co("%{bright white}", "Tokens: ") .. err_or_info.tokens)
  print(co("%{dim}",          "    ")  .. co("%{bright white}", "Context files: ") .. #context_paths)
  print("")
end

-- ---------------------------------------------------------------------------
-- Command: plan
-- ---------------------------------------------------------------------------

local function run_plan(args)
  local cmd_plan = require("cmd_plan")

  local ok, err = cmd_plan.run({
    subcommand = args.subcommand,
    plan_path  = args.plan_path,
  })

  if not ok then
    print("")
    for line in (tostring(err) .. "\n"):gmatch("([^\n]*)\n") do
      if line ~= "" then
        print(co("%{red}", "  ✗ ") .. line)
      end
    end
    print("")
    os.exit(1)
  end
end

-- ---------------------------------------------------------------------------
-- Command registry
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
    detail = [[
  Arguments:
    output_path   File to write the generated Lua code to (must be in allowed_paths).
    prompt        What to generate. Three forms are accepted:

                  Inline string (most common):
                    lua main.lua generate out.lua "write a config loader"

                  File prefixed with @  — reads the prompt from a file:
                    lua main.lua generate out.lua @prompts/my_prompt.md

                  Stdin via -  — pipe or type the prompt interactively:
                    cat prompt.md | lua main.lua generate out.lua -
                    lua main.lua generate out.lua -   (then type, then Ctrl-D)
    ]],
  },
  {
    name  = "generate-with-context",
    usage = "<output_path> <prompt> <context_file>...",
    desc  = "Generate Lua code with existing source files provided as context.",
    fn    = run_generate_with_context,
    setup = function(parser)
      parser:argument("output_path", "File path to write the generated Lua code to.")
      parser:argument("prompt",      "Description of the Lua code to generate.")
      parser:argument("context",     "Source file(s) to include as context.")
            :args("+")
    end,
    detail = [[
  Arguments:
    output_path     File to write the generated Lua code to (must be in allowed_paths).
    prompt          What to generate. Three forms are accepted:

                    Inline string (most common):
                      ./agent generate-with-context out.lua "write a cache module" src/config.lua

                    File prefixed with @  — reads the prompt from a .md or .txt file.
                    Useful when your prompt is long or you want to version-control it:
                      ./agent generate-with-context out.lua @prompts/cache.md src/config.lua

                    Stdin via -  — pipe or type the prompt interactively.
                    Useful for composing prompts with other shell tools:
                      cat prompts/cache.md | ./agent generate-with-context out.lua - src/config.lua
                      echo "write a cache" | ./agent generate-with-context out.lua - src/a.lua src/b.lua

    context_file... One or more existing Lua source files passed to the model as
                    reference material. The model sees their full contents, so it
                    can match your conventions, use the right require() paths, and
                    call real APIs instead of hallucinating them.

                    Pass the files you expect the generated module to import or
                    interact with. For example, if generating a new command module:
                      ./agent generate-with-context src/cmd_foo.lua @prompts/foo.md \
                        src/config.lua src/luallm.lua src/safe_fs.lua

                    Total context size is capped at generate.max_context_bytes in
                    config.json (default 64 KB). Reduce files or raise the cap if
                    you hit the limit.

  Timeouts:
    Large context payloads take longer to process. If you see timeout errors,
    set generate.timeout_seconds in config.json to override the global limit:
      "generate": { "timeout_seconds": 600 }
    The global fallback is limits.llm_timeout_seconds (default 300s).
    ]],
  },
  {
    name  = "plan",
    usage = "<new|run|check|resume> <plan_path>",
    desc  = "Create, run, check, or resume a Markdown plan file.",
    fn    = run_plan,
    setup = function(parser)
      parser:argument("subcommand", "Subcommand: new, run, check, or resume.")
      parser:argument("plan_path",  "Path to the .md plan file.")
    end,
    detail = [[
  Subcommands:
    new     Create a blank plan file with all default keys filled in.
    run     Execute the plan: call generate-with-context for each declared output.
    check   Validate the plan file and resolve context globs; no LLM calls.
    resume  Generate only the outputs that are missing (for interrupted runs).

  Quickstart:
    ./agent plan new    plans/my_feature.md
    ./agent plan check  plans/my_feature.md
    ./agent plan run    plans/my_feature.md
    ./agent plan resume plans/my_feature.md

  Plan file format:

    Plans are Markdown files with ## sections:

      # Title (optional)

      ## plan
      model: Qwen3-Coder-Next-Q8_0
      sanitize_fences: true
      context: src/config.lua
      context: src/**/*.test.lua
      output: src/my_module.lua
      output: src/my_module.test.lua
      test_runner: busted
      test_goal: handles edge case X

      ## system prompt
      You are a Lua code generator. Output ONLY valid Lua code.

      ## prompt
      Implement a module that does X, following the patterns in the context files.

  Plan section keys:
    model            Override the running model (optional).
    sanitize_fences  Strip markdown fences from output (default true).
    context          File or glob pattern to include as context (repeatable).
    output           File to generate (repeatable). Used by check and resume.
    test_runner      Testing tool to use (note: plan runner does NOT execute tests).
    test_goal        Human-readable test objective (informational, repeatable).

  Notes:
    - Only ## headers (not ###) begin a new section.
    - Section names are case-insensitive.
    - resume regenerates any declared outputs that don't exist on disk.
    - Tests are NOT executed automatically by the plan runner.
    ]],
  },
}

-- ---------------------------------------------------------------------------
-- Help printer
-- ---------------------------------------------------------------------------

local function print_help(cmd_name)
  if cmd_name then
    for _, cmd in ipairs(COMMANDS) do
      if cmd.name == cmd_name then
        print("")
        print(co("%{bright cyan}", "  " .. cmd.name)
              .. (cmd.usage ~= "" and "  " .. co("%{dim}", cmd.usage) or ""))
        print("")
        print("  " .. cmd.desc)
        if cmd.detail then
          print("")
          -- detail is a multiline string; print each line with dim styling
          -- for the section headers and normal text for the rest.
          for line in (cmd.detail):gmatch("([^\n]*)\n?") do
            local trimmed = line:match("^%s*(.-)%s*$")
            if trimmed:match("^%u%l+:") or trimmed:match("^%u[%u%s]+:") then
              -- "Arguments:", "Options:", etc — print as a bright header
              print(co("%{bright white}", "  " .. line))
            else
              print(co("%{dim}", line))
            end
          end
        end
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
  print_help(arg[2])
else
  local matched = false
  for _, cmd in ipairs(COMMANDS) do
    if cmd.name == cmd_name then
      matched = true
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
