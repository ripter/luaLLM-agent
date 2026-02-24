--- src/cmd_doctor.lua
--- Logic for the `doctor` command: runs health checks, optionally fixes them.
--- Wraps the existing doctor.lua check registry.

local M = {}

--- Run all checks. If `fix` is true, attempt to auto-fix failing ones.
--- deps = { doctor }   (the existing doctor module)
--- Returns list of { name, ok, detail, fixed?, fix_detail? }
function M.run(deps, fix)
  return deps.doctor.run(fix)
end

return M
