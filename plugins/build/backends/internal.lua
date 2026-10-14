local core = require "core"
local common = require "core.common"
local config = require "core.config"
local build = require "plugins.build"

-- Takes project configuration like so:
-- `name` is your target name
-- `binary` is the target full link
-- `type` is your type of build; valid values are `executable`, `static` or `shared`.
-- `ignored_files` will ignore any file that matches the pattern based on the normal ignore syntax.
-- `files` will take specific files and add them to the compile with override options based on any of these other options
-- `cflags` will specify compile time flags.
-- `ldflags` will specify link time flags
-- `cc` will specify your c compiler
-- `cxx` will specify your c++ compiler
-- `ar` specifies your archiver
-- `srcs` specifies the folders where your source is located.
-- { name = string, cc = "gcc", cxx = "g++", ar = "ar", binary = path, ignored_files = { "src/api.c" }, cflags = string, ldflags = string, files = {}, obj = path, srcs = { "." } }

if not config.plugins.build.internal then config.plugins.build.internal = {} end
local internal = common.merge({
  threads = build.threads,
  running_programs = nil,
  remaining_programs = {},
  interval = 0.1,
  priority = 10
}, config.plugins.build.internal)

local function table_concat(t1, t2)
  local t = {}
  for i,v in ipairs(t1) do table.insert(t, v) end
  for i,v in ipairs(t2) do table.insert(t, v) end
  return t
end


local function get_field(target, path, field)
  local file = path and target.files and (target.files[path] or target.files[core.root_project():normalize_path(path)])
  local value = file and file[field] or target[field] or internal[field] or build[field]
  if (field == "cflags" or field == "cxxflags" or field == "ldflags") and type(value) == "string" then
    return build.argument_string_to_table(value)
  end
  return value
end
local function get_type(target) return get_field(target, nil, "type") end
local function get_ldflags(target) return get_field(target, nil, "ldflags") end
local function get_binary(target) return core.root_project():absolute_path(assert(get_field(target, nil, "binary"), "No output binary configured")) end
local function get_compiler(target, path)
  local field = path:find("%.c$") and "cc"
    or (path:find("%.cc$") or path:find("%.cpp$") or path:find("%.cxx$")) and "cxx"
  if not field then return nil end
  local value = get_field(target, path, field)
  return type(value) == "table" and value or build.argument_string_to_table(value)
end
local function get_archiver(target) return get_field(target, nil, "ar") end
local function get_linker(target) return get_field(target, nil, "ld") end

local function get_source_files(target)
  local files, included = {}, {}
  for project, file in core.root_project():files() do
    local file = file.filename
    for i, src in ipairs(target.srcs or { target.src or "src" }) do
      local path = core.root_project():absolute_path(src)
      if common.path_belongs_to(file, path) and get_compiler(target, file)
        and not common.match_pattern(core.root_project():normalize_path(file), target.ignored_files or {}) then
        table.insert(files, file)
        included[file] = true
        break
      end
    end
  end
  for filename in pairs(target.files or {}) do
    local path = core.root_project():absolute_path(filename)
    if not included[path] and get_compiler(target, path) and system.get_file_info(path) then
      files[#files + 1] = path
      included[path] = true
    end
  end
  table.sort(files)
  return files
end


local function get_compile_flags(target, file)
  if file:find("%.cpp$") or file:find("%.cc$") or file:find("%.cxx$") then return get_field(target, file, "cxxflags") end
  return get_field(target, file, "cflags")
end

function internal.infer()
  if system.get_file_info(core.root_project():absolute_path("src")) then
    return {
      { name = "debug", binary = common.basename(core.root_project().path) .. "-debug" .. (PLATFORM == "Windows" and ".exe" or ""), cflags = {"-g", "-O0" }, cxxflags = { "-g", "-O0" }, srcs = { "src" } },
      { name = "release", binary = common.basename(core.root_project().path) .. "-release" .. (PLATFORM == "Windows" and ".exe" or ""), cflags = { "-O3" }, cxxflags = { "-O3" }, srcs = { "src" } },
    }
  end
end

function internal.build(target, callback)
  local commands = {}
  local files = get_source_files(target)
  if #files == 0 then error("can't find source files for project") end
  local has_cpp = false
  for i, v in ipairs(files) do if v:find("%.cpp$") or v:find("%.cc$") or v:find("%.cxx$") then has_cpp = true end end
  -- pick targets for dependency generation
  local dependencies = {}
  local objects = {}
  local stats = {}
  local max_ostat = nil
  common.mkdirp(core.root_project():absolute_path(target.obj or "obj"))
  for i, v in ipairs(files) do
    local handle = (target.name .. v):gsub("[/\\]+", "_")
    dependencies[i] = core.root_project():absolute_path(target.obj or "obj") .. PATHSEP .. handle .. ".d"
    objects[i] = core.root_project():absolute_path(target.obj or "obj") .. PATHSEP .. handle .. ".o"
    stats[i] = system.get_file_info(v)
  end
  local dependency_jobs = {}
  for i, d in ipairs(dependencies) do
    local d_stat = system.get_file_info(d)
    if not d_stat or d_stat.modified < stats[i].modified then
      table.insert(dependency_jobs, table_concat(get_compiler(target, files[i]), { "-MM", core.root_project():normalize_path(files[i]), "-MF", core.root_project():normalize_path(d), table.unpack(get_compile_flags(target, files[i])) }))
    end
  end

  build.run_tasks(dependency_jobs, function(status)
    if status ~= 0 then if callback then callback(status) end return end
    local compile_jobs = {}
    for i, d in ipairs(dependencies) do
      local o_stat = system.get_file_info(objects[i])
      if o_stat and (not max_ostat or o_stat.modified > max_ostat) then max_ostat = o_stat.modified end
      local compile = not o_stat or o_stat.modified < stats[i].modified
      if not compile then
        local handle = assert(io.open(d, "rb"))
        local dependency_text = handle:read("*all")
        handle:close()
        for j, h in ipairs(build.argument_string_to_table(dependency_text:gsub("\\\r?\n", " "):gsub("^.-:%s+", ""))) do
          if h then
            local h_stat = system.get_file_info(h)
            if h_stat and o_stat.modified < h_stat.modified then
              compile = true
              break
            end
          end
        end
      end
      if compile then
        table.insert(compile_jobs, table_concat(get_compiler(target, core.root_project():normalize_path(files[i])), { "-fdiagnostics-color=always", "-c", core.root_project():normalize_path(files[i]), "-o", core.root_project():normalize_path(objects[i]), table.unpack(get_compile_flags(target, files[i])) }))
      end
    end
    build.run_tasks(compile_jobs, function(status)
      if status ~= 0 then if callback then callback(status) end return end
      local link_job = {}
      local output_type = get_type(target)
      local linker = get_linker(target) or (has_cpp and get_field(target, nil, "cxx") or get_field(target, nil, "cc"))
      if type(linker) == "string" then linker = build.argument_string_to_table(linker) end
      local binary = get_binary(target)
      local binary_stat = system.get_file_info(binary)
      if not binary_stat or #compile_jobs > 0 or (max_ostat and binary_stat.modified < max_ostat) then
        local binary_folder = common.dirname(binary)
        if binary_folder then common.mkdirp(binary_folder) end
        if not output_type or output_type == "executable" then
          link_job = table_concat(linker, { "-o", binary })
        elseif output_type == "static" then
          link_job = { get_archiver(target), "-r", "-s", binary }
        elseif output_type == "shared" then
          link_job = table_concat(linker, { "-shared", "-o", binary })
        end
        for i, object in ipairs(objects) do table.insert(link_job, object) end
        for i, ldflag in ipairs(get_ldflags(target) or {}) do table.insert(link_job, ldflag) end
        build.run_tasks({ link_job }, callback)
      else
        if callback then callback(0) end
      end
    end)
  end)
end


function internal.clean(target, callback)
  local files = get_source_files(target)
  for i, v in ipairs(files) do
    local handle = (target.name .. v):gsub("[/\\]+", "_")
    local dependency = core.root_project():absolute_path(target.obj or "obj") .. PATHSEP .. handle .. ".d"
    local object = core.root_project():absolute_path(target.obj or "obj") .. PATHSEP .. handle .. ".o"
    if system.get_file_info(dependency) then os.remove(dependency) end
    if system.get_file_info(object) then os.remove(object) end
  end
  if system.get_file_info(get_binary(target)) then os.remove(get_binary(target)) end
  if callback then callback(0) end
end


return internal
