local core = require "core"
local build = require "plugins.build"
local util = require "plugins.build.util"

local make = { }

local function grep(t, cond) local nt = {} for i,v in ipairs(t) do if cond(v, i) then table.insert(nt, v) end end return nt end


function make.infer()
  return system.get_file_info(core.root_project().path .. PATHSEP .. "Makefile") and { { name = "all" } }
end

function make.build(target, callback)
  build.run_tasks({ { "make", target.name, "-j", tostring(build.threads) } }, function(status)
    if callback then callback(util.build_status(build, status)) end
  end)
end


function make.clean(target, callback)
  build.run_tasks({ { "make", "clean" } }, callback)
end


return make
