local core = require "core"
local common = require "core.common"
local config = require "core.config"
local json = require "core.json"
local build = require "plugins.build"
local util = require "plugins.build.util"

local meson = {}

---Infer standard configurations for a Meson project.
---@return table[]? targets Debug and release targets when meson.build exists
function meson.infer()
  if system.get_file_info(core.root_project():absolute_path("meson.build")) then
    return { { name = "debug", buildtype = "debug" }, { name = "release", buildtype = "release" } }
  end
end

---Normalize Ninja's parent-relative compiler paths before parsing a diagnostic.
---@param line string Compiler output line
---@return string|table message Output line or parsed diagnostic
function meson.parse_compile_line(line)
  return build.parse_compile_line((line:gsub("^(%s*)%.%.[/\\]", "%1")))
end

---Configure, discover the default executable, and build through Meson's backend.
---@param target table Build target
---@param callback fun(status:integer)? Completion callback
function meson.build(target, callback)
  local directory = util.build_directory(target)
  local function compile()
    local args = { "meson", "compile", "-C", directory, "-j", tostring(build.threads) }
    if target.build_target then args[#args + 1] = target.build_target end
    build.run_tasks({ args }, function(status)
      if callback then callback(util.build_status(build, status)) end
    end, function(line) build.message_view:add_message(meson.parse_compile_line(line)) end)
  end
  local function discover()
    if target.checked or target.binary then target.checked = true; compile(); return end
    local output = {}
    build.run_tasks({ { "meson", "introspect", directory, "--targets" } }, function(status)
      if status ~= 0 then if callback then callback(status) end; return end
      local targets, err = json.decode(table.concat(output, "\n"))
      if type(targets) ~= "table" then
        build.message_view:add_message({ "error", err or "Invalid Meson introspection output" })
        if callback then callback(1) end
        return
      end
      for _, executable in ipairs(targets) do
        if executable.build_by_default and executable.type == "executable" and executable.filename then
          target.binary = executable.filename[1]
          target.wd = target.wd or common.dirname(target.binary)
          if build.targets[build.state.target] == target then config.target_binary = target.binary end
          break
        end
      end
      target.checked = true
      compile()
    end, function(line) output[#output + 1] = line end)
  end
  if system.get_file_info(directory .. PATHSEP .. "meson-private" .. PATHSEP .. "coredata.dat") then
    discover()
  else
    build.run_tasks({ { "meson", "setup", directory, core.root_project().path,
      "--buildtype", target.buildtype or "debug" } }, function(status)
      if status ~= 0 then if callback then callback(status) end; return end
      discover()
    end)
  end
end

---Clean generated targets while retaining configuration and user-owned files.
---@param target table Build target
---@param callback fun(status:integer)? Completion callback
function meson.clean(target, callback)
  build.run_tasks({ { "meson", "compile", "-C", util.build_directory(target), "--clean" } }, callback)
end

return meson
