local core = require "core"
local build = require "plugins.build"
local util = require "plugins.build.util"

local gradle = { }

---Choose the wrapper executable and shell needed by the host platform.
---@return string[] command Gradle wrapper command prefix
local function wrapper()
  if PLATFORM == "Windows" then return { os.getenv("COMSPEC") or "cmd.exe", "/d", "/c", "gradlew.bat" } end
  return { "./gradlew" }
end

local function grep(t, cond) local nt = {} for i,v in ipairs(t) do if cond(v, i) then table.insert(nt, v) end end return nt end


function gradle.infer()
  return system.get_file_info(core.root_project():absolute_path(PLATFORM == "Windows" and "gradlew.bat" or "gradlew")) and {
    { name = "build" }
  }
end

function gradle.can_build(target) return target.task ~= "executable" end
function gradle.can_run(target) return target.task == "executable" end
function gradle.run(target)
  return build.execute_command(build.get_shell_command(target, (PLATFORM == "Windows" and "gradlew.bat" or "./gradlew"), { target.name }))
end
function gradle.build(target, callback)
  local args = wrapper()
  args[#args + 1] = target.name
  build.run_tasks({ args }, function(status)
    if callback then callback(util.build_status(build, status)) end
  end)
end


function gradle.clean(target, callback)
  local args = wrapper()
  args[#args + 1] = "clean"
  build.run_tasks({ args }, callback)
end


return gradle
