local core = require "core"
local build = require "plugins.build"
local util = require "plugins.build.util"

local cmake = {}

---Infer configuration names without treating them as CMake target names.
---@return table[]? targets Debug and release configurations when a project exists
function cmake.infer()
  if system.get_file_info(core.root_project():absolute_path("CMakeLists.txt")) then
    return { { name = "debug", buildtype = "Debug" }, { name = "release", buildtype = "Release" } }
  end
end

---Configure when necessary and stop before building if configuration fails.
---@param target table Build target; build_target optionally names a CMake target
---@param callback fun(status:integer)? Completion callback
function cmake.build(target, callback)
  local directory = util.build_directory(target)
  local function compile()
    local args = { "cmake", "--build", directory, "--parallel", tostring(build.threads) }
    if target.build_target then
      args[#args + 1], args[#args + 2] = "--target", target.build_target
    end
    build.run_tasks({ args }, function(status)
      if callback then callback(util.build_status(build, status)) end
    end)
  end
  if system.get_file_info(directory .. PATHSEP .. "CMakeCache.txt") then
    compile()
  else
    build.run_tasks({ { "cmake", "-S", core.root_project().path, "-B", directory,
      "-DCMAKE_BUILD_TYPE=" .. (target.buildtype or "Debug") } }, function(status)
      if status ~= 0 then if callback then callback(status) end; return end
      compile()
    end)
  end
end

---Clean generated outputs without deleting the user's build directory.
---@param target table Build target
---@param callback fun(status:integer)? Completion callback
function cmake.clean(target, callback)
  build.run_tasks({ { "cmake", "--build", util.build_directory(target), "--target", "clean" } }, callback)
end

return cmake
