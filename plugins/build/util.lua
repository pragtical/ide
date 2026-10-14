local core = require "core"

local util = {}

---Resolve a target's build directory relative to the current project.
---@param target table Build target
---@return string directory Absolute build directory
function util.build_directory(target)
  local name = (target.name or "debug"):lower():gsub("%W+", "-"):gsub("^-", ""):gsub("-$", "")
  return core.root_project():absolute_path(target.build_directory or "build-" .. name)
end

---Combine process failure with parsed compiler diagnostics.
---@param build table Build plugin instance
---@param status integer Process exit status
---@return integer status Nonzero when the process or compiler reported errors
function util.build_status(build, status)
  if status ~= 0 then return status end
  for _, message in ipairs(build.message_view.messages) do
    if type(message) == "table" and message[1] == "error" then return 1 end
  end
  return 0
end

return util
