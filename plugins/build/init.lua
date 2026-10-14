-- mod-version:3.12.3
local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"
local config = require "core.config"
local common = require "core.common"
local style = require "core.style"
local View = require "core.view"
local DocView = require "core.docview"
local StatusView = require "core.statusview"
local ToolbarView = require "plugins.toolbarview"
local storage = require "core.storage"
local plugin_directory = common.dirname(debug.getinfo(1, "S").source:sub(2))

local build = common.merge({
  targets = { },
  thread = nil,
  interval = 0.01,
  running_bundles = {},
  -- Config variables
  threads = 8,
  cc = os.getenv("CC") or "gcc",
  cxx = os.getenv("CXX") or "g++",
  ar = os.getenv("AR") or "ar",
  cflags = os.getenv("CFLAGS") or {},
  cxxflags = os.getenv("CXXFLAGS") or {},
  ldflags = os.getenv("LDFLAGS") or {},
  error_pattern = "^%s*(.-):(%d+):(%d*):?%s*([%a ]-):%s*(.+)",
  file_pattern = "^%s*(.-):(%d+):(%d*):?%s*(.+)",
  error_color = style.error,
  warning_color = style.warn,
  good_color = style.good,
  drawer_size = 100,
  max_previous_arguments = 100,
  on_success = "minimize",
  terminal = false,
  shell = (PLATFORM == "Windows" and { os.getenv("COMSPEC") or "cmd.exe", "/d", "/s", "/c" } or { "sh", "-c" })
}, config.plugins.build)


if not style.build then style.build = {} end
style.build.font = style.code_font:copy(style.code_font:get_height()*0.7)

local executable_cache = {}

---Resolve a project executable or a command available through PATH.
---@param binary string? Program filename or command name
---@return string? filename Absolute executable path, if found
function build.get_binary(binary)
  if not binary or binary == "" then return nil end
  local project_path = core.root_project():absolute_path(binary)
  local info = system.get_file_info(project_path)
  if info and info.type == "file" then return project_path end
  if binary:find("[/\\]") or common.is_absolute_path(binary) then return nil end
  local path = os.getenv("PATH") or ""
  local extensions = PLATFORM == "Windows" and (os.getenv("PATHEXT") or ".COM;.EXE;.BAT;.CMD") or ""
  local cached = executable_cache[binary]
  if cached and cached.path == path and cached.extensions == extensions
    and system.get_time() - cached.time < 1 then return cached.filename end
  local suffixes = { "" }
  if PLATFORM == "Windows" and not binary:match("%.[^%.]+$") then
    for extension in extensions:gmatch("[^;]+") do suffixes[#suffixes + 1] = extension end
  end
  for directory in path:gmatch(PLATFORM == "Windows" and "[^;]+" or "[^:]+") do
    directory = directory:gsub('^"(.*)"$', "%1")
    for _, suffix in ipairs(suffixes) do
      local filename = directory .. PATHSEP .. binary .. suffix
      info = system.get_file_info(filename)
      if info and info.type == "file" then
        executable_cache[binary] = { path = path, extensions = extensions, time = system.get_time(), filename = filename }
        return filename
      end
    end
  end
  executable_cache[binary] = { path = path, extensions = extensions, time = system.get_time() }
end

---Split shell-style arguments, preserving quoted spaces, empty values and escapes.
---@param str string? Argument text
---@return string[] arguments Parsed arguments
function build.argument_string_to_table(str)
  if not str or str == "" then return {} end
  local result, buffer, quote, started = {}, {}, nil, false
  local i = 1
  while i <= #str do
    local char = str:sub(i, i)
    if quote then
      if char == quote then
        quote = nil
      elseif char == "\\" and quote == '"' and str:sub(i + 1, i + 1):match('["\\]') then
        i = i + 1
        buffer[#buffer + 1] = str:sub(i, i)
      else
        buffer[#buffer + 1] = char
      end
    elseif char == '"' or char == "'" then
      quote, started = char, true
    elseif char:match("%s") then
      if started then result[#result + 1] = table.concat(buffer); buffer, started = {}, false end
    elseif char == "\\" and str:sub(i + 1, i + 1):match("[%s\\'\"]") then
      i = i + 1
      buffer[#buffer + 1], started = str:sub(i, i), true
    else
      buffer[#buffer + 1], started = char, true
    end
    i = i + 1
  end
  assert(not quote, "Unclosed quote in arguments")
  if started then result[#result + 1] = table.concat(buffer) end
  return result
end

---Load available build backends, or return one by name.
---@param specific string? Backend name
---@return table|table[] backends Selected backend or all backends
function build.get_backends(specific)
  local backends = {}
  for _, backend in ipairs(system.list_dir(plugin_directory .. PATHSEP .. "backends")) do
    if backend:find("%.lua$") then
      local module = require("plugins.build.backends." .. backend:gsub("%.lua", ""))
      table.insert(backends, module)
      backends[#backends].id = backend:gsub("%.lua", "")
    end
  end
  if specific then
    for i,backend in ipairs(backends) do
      if backend.id == specific then return backend end
    end
    error("can't find backend " .. specific)
  end
  return backends
end

build.state = storage.load("build", "state") or {}
build.state.previous_arguments = build.state.previous_arguments or {}
build.state.target = tonumber(build.state.target) or 1
for _, field in ipairs { "cflags", "cxxflags", "ldflags" } do
  if type(build[field]) == "string" then build[field] = build.argument_string_to_table(build[field]) end
end

local function save_state()
  storage.save("build", "state", build.state)
end


local function jump_to_file(file, line, col)
  if not core.active_view or not core.active_view.doc or core.active_view.doc.abs_filename ~= file then
    -- Check to see if the file is in the project. If it is, open it, and go to the line.
    for i = 1, #core.projects do
      if file and common.path_belongs_to(file, core.projects[i].path) then
        local view = core.root_view:open_doc(core.open_doc(file))
        if line then
          view:scroll_to_line(math.max(1, line - 20), true)
          view.doc:set_selection(line, col or 1, line, col or 1)
        end
        break
      end
    end
  end
end


---Parse GCC/Clang and MSVC diagnostics, including Windows drive-letter paths.
---@param line string One complete compiler output line
---@return string|table message Plain output or severity/file/line/column/text fields
function build.parse_compile_line(line)
  local stripped = line:gsub("\27%[[%d;]*%a", "")
  local file, number, column, severity, message = stripped:match(build.error_pattern)
  if not file then
    file, number, column, severity, message = stripped:match("^%s*(.-)%((%d+),?(%d*)%):%s*(%a+)%s*[^:]*:%s*(.+)")
  end
  if file and (severity == "warning" or severity == "error" or severity == "fatal" or severity == "fatal error") then
    return { severity:find("^fatal") and "error" or severity,
      core.root_project():normalize_path(file), tonumber(number), tonumber(column) or 1, message }
  end
  file, number, column, message = stripped:match(build.file_pattern)
  return file and { "info", core.root_project():normalize_path(file), tonumber(number), tonumber(column) or 1, message } or line
end

local function default_on_line(line)
  build.message_view:add_message(build.parse_compile_line(line))
end

---Queue commands and stream complete output lines with bounded concurrency.
---Start and exit failures finish the bundle once; partial final lines are retained.
---@param tasks string[][] Commands to execute in the current project
---@param on_done fun(status:integer)? Completion callback
---@param on_line fun(line:string)? Output callback
function build.run_tasks(tasks, on_done, on_line)
  if #tasks == 0 then if on_done then on_done(0) end; return end
  local bundle = { tasks = {}, on_done = on_done, on_line = on_line or default_on_line, status = 0, cwd = core.root_project().path }
  for _, arguments in ipairs(tasks) do
    local cmd = {}
    for i, value in ipairs(arguments) do cmd[i] = tostring(value) end
    bundle.tasks[#bundle.tasks + 1] = { cmd = cmd, buffer = "", done = false }
  end
  build.running_bundles[#build.running_bundles + 1] = bundle
  if build.thread and (not core.threads[build.thread] or coroutine.status(core.threads[build.thread].cr) == "dead") then build.thread = nil end
  if build.thread then return end
  build.thread = core.add_thread(function()
    local function output(task, owner, chunk, finished)
      task.buffer = task.buffer .. (chunk or "")
      while true do
        local newline = task.buffer:find("\n", 1, true)
        if not newline then break end
        owner.on_line(task.buffer:sub(1, newline - 1):gsub("\r$", ""))
        task.buffer = task.buffer:sub(newline + 1)
      end
      if finished and task.buffer ~= "" then
        owner.on_line(task.buffer:gsub("\r$", ""))
        task.buffer = ""
      end
    end
    while #build.running_bundles > 0 do
      local running = 0
      for i = #build.running_bundles, 1, -1 do
        local owner = build.running_bundles[i]
        local unfinished = false
        for _, task in ipairs(owner.tasks) do
          if not task.done and task.program then
            repeat
              local chunk = task.program:read_stdout()
              if not chunk or chunk == "" then break end
              output(task, owner, chunk)
            until false
            if task.program:running() then
              running = running + 1
            else
              output(task, owner, nil, true)
              task.done = true
              local status = task.program:returncode() or 1
              if status ~= 0 then owner.status = status end
            end
          end
          if not task.done then unfinished = true end
        end
        if owner.status ~= 0 then
          for _, task in ipairs(owner.tasks) do
            if task.program and not task.done then task.program:terminate(); running = running - 1 end
            task.done = true
          end
          unfinished = false
        end
        if not unfinished then
          table.remove(build.running_bundles, i)
          if owner.on_done then core.try(owner.on_done, owner.status) end
        end
      end
      for _, owner in ipairs(build.running_bundles) do
        for _, task in ipairs(owner.tasks) do
          if running >= math.max(1, build.threads) then break end
          if not task.done and not task.program then
            build.message_view:add_message(table.concat(task.cmd, " "))
            local program, err = process.start(task.cmd, {
              stderr = process.REDIRECT_STDOUT, cwd = owner.cwd,
              background = PLATFORM == "Windows", env = { TERM = "ansi" }
            })
            if not program then
              owner.on_line("Unable to start " .. tostring(task.cmd[1]) .. ": " .. tostring(err))
              task.done, owner.status = true, 1
              break
            end
            task.program, running = program, running + 1
          end
        end
      end
      coroutine.yield(build.interval)
    end
    build.thread = nil
  end, "build-thread")
end

---Return whether commands are queued or running.
---@return boolean running
function build.is_running() return build.thread ~= nil end
---Write a build status line to the editor log.
---@param line string Status text
function build.output(line) core.log_quiet(line) end

---Select a target and restore its most recent program arguments.
---@param target integer Target index
function build.set_target(target)
  if not build.targets or #build.targets == 0 then
    core.log_quiet("No build targets available")
    return
  end
  if not target then
    core.log_quiet("No target given")
    return
  end

  target = common.clamp(target, 1, #build.targets)
  build.state.target = target
  config.target_binary = build.targets and build.targets[target] and build.targets[target].binary
  local arguments
  for i = #build.state.previous_arguments, 1, -1 do
    local v = build.state.previous_arguments[i]
    if v[1] == build.state.target then
      arguments = v[2]
      break
    end
  end
  local parsed = arguments ~= nil and build.argument_string_to_table(arguments)
    or build.targets[target].binary_arguments or {}
  if type(parsed) == "string" then parsed = build.argument_string_to_table(parsed) end
  config.target_binary_arguments = #parsed > 0 and parsed or nil
  save_state()
end

---Configure targets and resolve their backend names.
---@param targets table[]? Build targets
---@param backend string? Default backend overriding per-target choices
function build.set_targets(targets, backend)
  build.targets = targets or {}
  targets = build.targets
  for i,v in ipairs(targets) do
    v.name = v.name or "Target " .. i
    if backend or type(v.backend) == "string" then
      v.backend = build.get_backends(backend or v.backend)
    elseif not v.backend then
      v.backend = build.get_backends("internal")
    end
  end
  if #build.targets > 0 then config.target_binary = build.targets[1].binary end
end

---Check whether a target can be built.
---@param target table? Target
---@return boolean|function? available
function build.can_build(target)
  return target and target.backend and target.build ~= false and (target.build or (target.backend.build and (not target.backend.can_build or target.backend.can_build(target))))
end

---Build the selected target and show diagnostics in the output pane.
---@param callback fun(status:integer,error:string?)? Completion callback
function build.build(callback)
  local target = build.targets[build.state.target]
  if build.is_running() or not build.can_build(target) then return false end
  build.message_view:clear_messages()
  build.message_view.visible = true
  build.message_view:add_message("Building " .. (target.binary and common.basename(target.binary) or "target") .. "...")
  build.message_view.minimized = false
  local status, err = pcall(function()
    if not target then error("No build target selected") end
    if not target.backend then error("No backend for target " .. tostring(target.name)) end
    local perform = type(target.build) == "function" and target.build or target.backend.build
    perform(target, function (status)
      local name = target.binary and common.basename(target.binary) or "target"
      local line = status == 0 and ("Built " .. name .. ".")
        or ("Build failed for " .. name .. " (exit status " .. status .. ").")
      build.message_view:add_message({ status == 0 and "good" or "error", line })
      build.message_view.visible = status ~= 0 or build.on_success ~= "close"
      build.output(line)
      build.message_view.scroll.to.y = 0
      if status == 0 and build.on_success == "minimize" then build.message_view.minimized = true end
      if callback then callback(status) end
    end)
  end)
  if not status then
    build.message_view:add_message({ "error", err }) 
    if callback then callback(-1, err) end
  end
end

---Quote argument values for the configured platform shell.
---@param arguments string[]|string Argument values or an already-written command line
---@return string[]|string arguments Quoted values
function build.escape_arguments(arguments)
  if type(arguments) ~= "table" then return arguments end
  local result = {}
  for i, value in ipairs(arguments) do
    value = tostring(value)
    if PLATFORM == "Windows" then
      result[i] = '"' .. value:gsub('"', '""') .. '"'
    else
      result[i] = "'" .. value:gsub("'", "'\"'\"'") .. "'"
    end
  end
  return result
end

---Build a subprocess argument vector with an optional external terminal prefix.
---@param target table Target whose binary and working directory are used
---@param executable string|string[]|function Executable, command vector or target callback
---@param arguments string[]|string? Program arguments
---@return string[] command Subprocess command without shell quoting around argv elements
function build.get_shell_command(target, executable, arguments)
  target = target or build.targets[build.state.target] or {}
  if type(arguments) == "string" then arguments = build.argument_string_to_table(arguments) end
  arguments = arguments or config.target_binary_arguments or {}
  if type(executable) == "function" then return executable(target, arguments) end
  local values = {}
  if type(executable) == "table" then
    for _, value in ipairs(executable) do values[#values + 1] = tostring(value) end
  else
    assert(executable, "No executable configured")
    if executable == target.binary or executable == config.target_binary then
      executable = build.get_binary(executable) or core.root_project():absolute_path(executable)
    end
    values[1] = executable
  end
  for _, argument in ipairs(arguments) do values[#values + 1] = tostring(argument) end
  local quote = build.escape_arguments
  local cwd = core.root_project():absolute_path(target.wd or ".")
  local script = (PLATFORM == "Windows" and "cd /d " or "cd ") .. quote({cwd})[1]
    .. " && " .. table.concat(quote(values), " ")
  local result = {}
  local function add(values)
    if type(values) == "string" then values = build.argument_string_to_table(values) end
    for _, value in ipairs(values or {}) do
      result[#result + 1] = type(value) == "function" and value(target, executable) or tostring(value)
    end
  end
  if build.terminal then add(build.terminal) end
  add(build.shell)
  result[#result + 1] = script
  return result
end

---Execute a command asynchronously through the build output pane.
---@param command string[] Command and arguments
function build.execute_command(command)
  build.message_view.visible, build.message_view.minimized = true, false
  build.run_tasks({ command })
end

---Check whether a target has a runnable program or backend.
---@param target table? Target
---@return boolean|string|function? available
function build.can_run(target)
  return target and target.backend and target.run ~= false and (target.run or target.binary or (target.backend.run and (not target.backend.can_run or target.backend.can_run(target))))
end

---Run the selected target with optional program arguments.
---@param arguments string|string[]? Arguments
function build.run(arguments)
  local target = build.targets[build.state.target] or { binary = config.target_binary, backend = {} }
  if build.is_running() or not build.can_run(target) then return false end
  build.message_view:clear_messages()
  if target.backend.run then
    target.backend.run(target)
  else
    build.execute_command(build.get_shell_command(target, target.run or config.target_binary, arguments))
  end
end

---Check whether a target supports cleaning its generated outputs.
---@param target table? Target
---@return boolean|function? available
function build.can_clean(target)
    return target and target.backend and target.clean ~= false and (target.clean or (target.backend.clean and (not target.backend.can_clean or target.backend.can_clean(target))))
end

---Clean the selected target and report success or failure.
---@param callback fun(status:integer,error:string?)? Completion callback
function build.clean(callback)
  local target = build.targets[build.state.target]
  if build.is_running() or not build.can_clean(target) then return false end
  build.message_view:clear_messages()
  build.message_view.visible, build.message_view.minimized = true, false
  build.message_view:add_message("Started cleaning " .. (target.binary or "target") .. ".")
  local perform = type(target.clean) == "function" and target.clean or target.backend.clean
  local ok, err = pcall(perform, target, function(status)
    status = status or 0
    build.message_view:add_message({ status == 0 and "good" or "error",
      (status == 0 and "Completed cleaning " or "Failed cleaning ") .. (target.binary or "target") .. "." })
    if status == 0 and build.on_success == "minimize" then build.message_view.minimized = true end
    if callback then callback(status) end
  end)
  if not ok then
    build.message_view:add_message({ "error", err })
    if callback then callback(-1, err) end
  end
end

---Cancel queued work before notifying callbacks so follow-up tasks remain valid.
---@param force boolean Whether to kill rather than terminate subprocesses
local function stop_tasks(force)
  local bundles = build.running_bundles
  build.running_bundles = {}
  for _, bundle in ipairs(bundles) do
    for _, task in ipairs(bundle.tasks) do
      if task.program and not task.done then
        if force then task.program:kill() else task.program:terminate() end
      end
      task.done = true
    end
    if bundle.on_done then core.try(bundle.on_done, 1) end
  end
end

---Terminate active commands and report cancellation once to their callbacks.
---@param callback function? Cancellation callback
---@return false? unavailable False when no build is running
function build.terminate(callback)
  if not build.is_running() then return false end
  stop_tasks(false)
  build.message_view:add_message({ "warning", "Terminated running build." })
  if callback then callback() end
end

---Kill active commands and report cancellation once to their callbacks.
---@param callback function? Cancellation callback
---@return false? unavailable False when no build is running
function build.kill(callback)
  if not build.is_running() then return false end
  stop_tasks(true)
  build.message_view:add_message({ "error", "Killed running build." })
  if callback then callback() end
end


------------------ UI Elements
core.status_view:add_item({
  predicate = function() return build.state.target and build.targets[build.state.target] and build.targets[build.state.target].backend end,
  name = "build:target",
  alignment = StatusView.Item.RIGHT,
  get_item = function()
    local dv = core.active_view
    return {
      style.text, string.format("target: %s (%s)", build.targets[build.state.target].name or "default", build.targets[build.state.target].backend.id)
    }
  end,
  command = function()
     core.command_view:enter("Select Build Target", {
      text = build.targets[build.state.target].name or "",
      submit = function(text)
        local has = false
        for i,v in ipairs(build.targets) do
          if text == v.name then
            build.set_target(i)
            has = true
          end
        end
        if not has then core.error("Can't find target " .. text) end
      end,
      suggest = function()
        local names = {}
        for i,v in ipairs(build.targets) do
          table.insert(names, v.name)
        end
        return names
      end
    })
  end
})

local doc_view_draw_line_gutter = DocView.draw_line_gutter
function DocView:draw_line_gutter(idx, x, y, width)
  if build.message_view and self.doc.abs_filename == build.message_view.active_file
    and build.message_view.active_message
    and idx == build.message_view.active_line
  then
    renderer.draw_rect(x, y, style.padding.x, self:get_line_height(), build.error_color)
  end
  return doc_view_draw_line_gutter(self, idx, x, y, width)
end

local BuildMessageView = View:extend()
function BuildMessageView:new()
  BuildMessageView.super.new(self)
  self.messages = { }
  self.target_size = build.drawer_size
  self.minimized = false
  self.scrollable = true
  self.init_size = true
  self.hovered_message = nil
  self.visible = false
  self.active_message = nil
  self.active_file = nil
  self.active_line = nil
end

function BuildMessageView:update()
  local dest = self.visible and ((self.minimized and style.code_font:get_height() + style.padding.y * 2) or self.target_size) or 0
  if self.init_size then
    self.size.y = dest
    self.init_size = false
  else
    self:move_towards(self.size, "y", dest)
  end
  BuildMessageView.super.update(self)
end

function BuildMessageView:set_target_size(axis, value)
  if axis == "y" then
    self.target_size = value
    return true
  end
end

function BuildMessageView:clear_messages()
  self.messages = {}
  self.measured_messages, self.messages_width = 0, 0
  self.hovered_message = nil
  self.active_message = nil
  self.active_file = nil
  self.active_line = nil
end

function BuildMessageView:add_message(message)
  local should_scroll = self:get_scrollable_size() <= self.size.y or self.scroll.to.y == self:get_scrollable_size() - self.size.y
  table.insert(self.messages, message)
  if should_scroll then
    self.scroll.to.y = self:get_scrollable_size() - self.size.y
  end
end

function BuildMessageView:get_item_height()
  return style.build.font:get_height() + style.padding.y
end

---Measure new messages once and invalidate cached widths on font changes.
---@return number width Content width
function BuildMessageView:get_h_scrollable_size()
  local font = style.build.font
  if self.width_font ~= font or self.width_font_size ~= font:get_size() then
    self.width_font, self.width_font_size = font, font:get_size()
    self.measured_messages, self.messages_width = 0, 0
  end
  for i = (self.measured_messages or 0) + 1, #self.messages do
    local message = self.messages[i]
    local text = type(message) == "table" and (#message > 2
      and (message[2] .. ":" .. message[3] .. " [" .. message[1] .. "]: " .. message[5]) or message[2]) or message
    self.messages_width = math.max(self.messages_width or 0,
      font:get_width((text:gsub("\27%[[%d;]*%a", ""))) + style.padding.x * 2)
  end
  self.measured_messages = #self.messages
  return self.messages_width or 0
end

function BuildMessageView:get_scrollable_size()
  return #self.messages and self:get_item_height() * (#self.messages + 1)
end

function BuildMessageView:on_mouse_moved(px, py, ...)
  BuildMessageView.super.on_mouse_moved(self, px, py, ...)
  if self:scrollbar_dragging() or self:scrollbar_hovering() then self.hovered_message = nil; return end
  local ox, oy = self:get_content_offset()
  if px > self.position.x and py > self.position.y and px < self.position.x + self.size.x and py < self.position.y + self.size.y then
    local offset = math.floor((py - oy) / self:get_item_height())
    self.hovered_message = offset >= 1 and offset <= #self.messages and offset
  else
    self.hovered_message = nil
  end
end


---Clear row hover when a popup or another view owns the pointer.
function BuildMessageView:on_mouse_left()
  BuildMessageView.super.on_mouse_left(self)
  self.hovered_message = nil
end

local ansi_colors = {
  [30] = { 0, 0, 0 },
  [31] = { 205, 49, 49 },
  [32] = { 13, 188, 121 },
  [33] = { 229, 229, 16 },
  [34] = { 36, 114 , 200 },
  [35] = { 188, 63, 188 },
  [36] = { 17, 168, 205 },
  [37] = { 229, 229, 229 },
  [38] = { 102, 120, 102 },
  [91] = { 241, 76, 76 },
  [92] = { 35, 209, 139 },
  [93] = { 245, 245, 67 },
  [94] = { 59, 142, 234 },
  [95] = { 214, 112, 214 },
  [96] = { 41, 184, 219 },
  [97] = { 255, 255, 255 }
}
function BuildMessageView:draw()
  self:draw_background(style.background3)
  local item_height = self:get_item_height()
  local ox, oy = self:get_content_offset()
  local title = "Build Messages"
  local subtitle = { }
  if build.is_running() then
    local t = { "|", "/", "-", "\\", "|", "/", "-", "\\" }
    title = title .. " " .. t[(math.floor(system.get_time()*8) % #t) + 1]
    core.redraw = true
  elseif type(self.messages[#self.messages]) == "table" and #self.messages[#self.messages] == 2 then
    subtitle = self.messages[#self.messages]
  end
  local colors = {
    error = build.error_color,
    warning = build.warning_color,
    good = build.good_color
  }
  local x = common.draw_text(style.build.font, style.accent, title, "left", ox + style.padding.x, self.position.y + style.padding.y, 0, item_height)
  if subtitle and #subtitle == 2 then
    common.draw_text(style.build.font, colors[subtitle[1]] or style.accent, subtitle[2], "left", x + style.padding.x, self.position.y + style.padding.y, 0, item_height)
  end
  core.push_clip_rect(self.position.x, self.position.y + item_height  + style.padding.y, self.size.x, self.size.y - item_height - style.padding.y)
  local default_color = style.text
  for i,v in ipairs(self.messages) do
    local yoffset = style.padding.y + i*item_height
    if type(v) == "table" and self.hovered_message == i or self.active_message == i then
      renderer.draw_rect(ox, oy + yoffset, self.size.x, item_height, style.line_highlight)
    end
    if type(v) == "table" then
      if #v > 2 then
        common.draw_text(style.build.font, colors[v[1]] or style.text, v[2] .. ":" .. v[3] .. " [" .. v[1] .. "]: " .. v[5], "left", ox + style.padding.x, oy + yoffset, 0, item_height)
      else
        common.draw_text(style.build.font, colors[v[1]] or style.text, v[2], "left", ox + style.padding.x, oy + yoffset, 0, item_height)
      end
    else
      if v:find("\x1b") then
        local x = ox + style.padding.x
        while true do
          local s,e,color = v:find("\x1b%[%d+;(%d+)m")
          default_color = ansi_colors[tonumber(color)] or style.text
          local line = v:sub(1, s and (s-1) or #v):gsub("\x1b%[[^a-zA-Z]*%a", "")
          x = common.draw_text(style.build.font, default_color, line, "left", x, oy + yoffset, 0, item_height)
          if not e then break end
          v = v:sub(e + 1)
        end
      else
        common.draw_text(style.build.font, default_color, v, "left", ox + style.padding.x, oy + yoffset, 0, item_height)
      end
    end
  end
  core.pop_clip_rect()
  self:draw_scrollbar()
end



local BuildBarView = ToolbarView:extend()

---Create a horizontal toolbar inside the build output drawer.
function BuildBarView:new()
  BuildBarView.super.new(self)
  self:set_orientation("horizontal")
  self.toolbar_font = renderer.font.load(plugin_directory .. PATHSEP .. "build.ttf", style.icon_big_font:get_size())
  self.toolbar_commands = {
    {symbol = "!", command = "build:build"},
    {symbol = '"', command = "build:run-or-term-or-kill"},
    {symbol = "#", command = "build:rebuild"},
    {symbol = "$", command = "build:terminate"},
    {symbol = "&", command = "build:next-target"},
    {symbol = "%", command = "build:toggle-drawer"},
  }
end

build.build_bar_view = BuildBarView()
build.message_view = BuildMessageView()
local node = core.root_view:get_active_node_default()
build.message_view_node = node:split("down", build.message_view, { y = true }, true)
local drawer = build.message_view_node
build.build_bar_node = drawer:split("up", build.build_bar_view, { y = true })
build.message_view_node = drawer.b



core.status_view:add_item({
  predicate = function() return config.target_binary end,
  name = "build:binary",
  alignment = StatusView.Item.RIGHT,
  get_item = function()
    local dv = core.active_view
    return {
      style.text, config.target_binary .. (config.target_binary_arguments and "*" or "")
    }
  end,
  command = function()
     core.command_view:enter("Set Target Binary", {
      text = table.concat(build.escape_arguments({ config.target_binary }), " ")
        .. (config.target_binary_arguments and (" " .. table.concat(build.escape_arguments(config.target_binary_arguments), " ")) or ""),
      submit = function(text)
        local arguments = build.argument_string_to_table(text)
        config.target_binary = table.remove(arguments, 1)
        config.target_binary_arguments = #arguments > 0 and arguments or nil
        table.insert(build.state.previous_arguments, { build.state.target,
          table.concat(build.escape_arguments(arguments), " ") })
        if #build.state.previous_arguments > build.max_previous_arguments then table.remove(build.state.previous_arguments, 1) end
        save_state()
      end
    })
  end
})

command.add(function(x, y)
  return core.active_view and core.active_view:is(BuildMessageView) and build.message_view.visible and (y == nil or y <= build.message_view.position.y + style.padding.y * 2 + style.build.font:get_height())
end, {
  ["build:toggle-minimize"] = function()
    build.message_view.minimized = not build.message_view.minimized
  end
})

command.add(function()
  local mv = build.message_view
  return mv.hovered_message and type(mv.messages[mv.hovered_message]) == "table" and #mv.messages[mv.hovered_message] > 2
end, {
  ["build:jump-to-hovered"] = function()
    local mv = build.message_view
    mv.active_message = mv.hovered_message
    mv.active_file = core.root_project():absolute_path(mv.messages[mv.hovered_message][2])
    mv.active_line = tonumber(mv.messages[mv.hovered_message][3])
    jump_to_file(mv.active_file, tonumber(mv.messages[mv.hovered_message][3]), tonumber(mv.messages[mv.hovered_message][4]))
  end
})

local tried_term = false
command.add(function(root_view, arguments)
  return not build.is_running() and build.can_build(build.targets[build.state.target]), arguments
end, {
  ["build:build"] = function()
    for i,v in ipairs(core.docs) do
      if v:is_dirty() and v.filename and v.abs_filename then
        v:save()
      end
    end
    if #build.targets > 0 then
      build.build()
    end
  end
})

command.add(function(root_view, arguments)
  return not build.is_running() and build.can_build(build.targets[build.state.target]) and build.can_run(build.targets[build.state.target]), arguments
end, {
  ["build:build-and-run"] = function(arguments)
    for i,v in ipairs(core.docs) do
      if v:is_dirty() and v.filename and v.abs_filename then
        v:save()
      end
    end
    if #build.targets > 0 then
      build.build(function(status)
        if status == 0 then
          build.run(arguments)
        end
      end)
    end
  end,
})

command.add(function(root_view, arguments)
  return not build.is_running() and build.can_build(build.targets[build.state.target]) and build.can_clean(build.targets[build.state.target]), arguments
end, {
  ["build:rebuild"] = function()
    build.clean(function(status)
      if status == 0 and #build.targets > 0 then
        build.build()
      end
    end)
  end
})


command.add(function(root_view, arguments)
  return not build.is_running() and build.can_clean(build.targets[build.state.target]), arguments
end, {
  ["build:clean"] = function()
    build.clean()
  end
})

command.add(function(root_view, arguments)
  return #build.targets > 0
end, {
  ["build:next-target"] = function()
    if #build.targets > 0 then
      build.set_target((build.state.target % #build.targets) + 1)
    end
  end
})

command.add(function()
  return build.is_running()
end, {
  ["build:terminate"] = function()
    build.terminate()
  end
})

command.add(function(root_view, options)
  return build.is_running() or build.get_binary(config.target_binary) or build.can_run(build.targets[build.state.target]), options
end, {
  ["build:run-or-term-or-kill"] = function(arguments)
    if build.is_running() then
      if tried_term then
        build.kill()
      else
        build.terminate()
        tried_term = true
      end
    else
      tried_term = false
      build.run(arguments)
    end
  end,
  ["build:run-or-term-or-kill-with-arguments"] = function(arguments)
    local relevant_previous_arguments
    for i,v in ipairs(build.state.previous_arguments) do if v[1] == build.state.target then relevant_previous_arguments = v[2] break end end
    core.command_view:enter((config.target_binary or build.targets[build.state.target].name) .. " ", {
      submit = function(text)
        config.target_binary_arguments = build.argument_string_to_table(text)
        command.perform("build:run-or-term-or-kill", text)
        local has = false
        for i,v in ipairs(build.state.previous_arguments) do
          if v[1] == build.state.target and v[2] == text then
            has = i
          end
        end
        if has then table.remove(build.state.previous_arguments, has) end
        table.insert(build.state.previous_arguments, { build.state.target, text })
        if #build.state.previous_arguments > build.max_previous_arguments then table.remove(build.state.previous_arguments, 1) end
        save_state()
      end,
      suggest = function(text)
        local arguments = {}
        for _, previous in ipairs(build.state.previous_arguments) do
          if previous[1] == build.state.target and previous[2] then arguments[#arguments + 1] = previous[2] end
        end
        return common.fuzzy_match(arguments, text)
      end,
      text = relevant_previous_arguments or ""
    })
  end
})

local function select_target_commandview(submit, target, condition)
  if target then
    for i, candidate in ipairs(build.targets) do if candidate == target then submit(target, i); return end end
    return
  end
  local target_names = {}
  for i,v in ipairs(build.targets) do if (not condition or condition(v)) then table.insert(target_names, v.name) end end
  if #target_names == 0 then
    core.log("No targets found")
    return
  end
  core.command_view:enter("Select Target", {
    submit = function(text)
      for i,v in ipairs(build.targets) do if v.name == text then submit(v, i); return end end
    end,
    suggest = function(text)
      return common.fuzzy_match(target_names, text)
    end,
    validate = function(text)
      for i,v in ipairs(target_names) do if v == text then return true end end
      return false
    end
  })
end

command.add(nil, {
  ["build:toggle-drawer"] = function()
    build.message_view.visible = not build.message_view.visible
  end,
  ["build:select-target"] = function(target)
    select_target_commandview(function(target, idx)
      build.set_target(idx)
    end, target)
  end,
  ["build:select-target-and-run"] = function(target)
    select_target_commandview(function(target, idx)
      build.set_target(idx)
      command.perform("build:run-or-term-or-kill")
    end, target, function(target)
      return target.binary
    end)
  end,
  ["build:select-target-and-build"] = function(target)
    select_target_commandview(function(target, idx)
      build.set_target(idx)
      command.perform("build:build")
    end, target)
  end
})

command.add(function()
  return core.active_view == build.message_view and build.message_view.visible
end, {
  ["build:contextual-close-drawer"] = function()
    build.message_view.visible = false
  end
})

keymap.add {
  ["lclick"]             = { "build:toggle-minimize", "build:jump-to-hovered" },
  ["ctrl+b"]             = { "build:build", "build:terminate" },
  ["alt+b"]         = "build:build-and-run",
  ["ctrl+alt+b"]         = "build:rebuild",
  ["ctrl+e"]             = "build:run-or-term-or-kill",
  ["ctrl+shift+e"]       = "build:run-or-term-or-kill-with-arguments",
  ["ctrl+t"]             = "build:next-target",
  ["ctrl+shift+t"]       = "build:select-target",
  ["ctrl+shift+alt+e"]   = "build:select-target-and-run",
  ["ctrl+shift+alt+b"]   = "build:select-target-and-build",
  ["ctrl+shift+b"]       = "build:clean",
  ["f6"]                 = "build:toggle-drawer",
  ["escape"]             = "build:contextual-close-drawer"
}

core.menu_view:register({ "tools" }, {
  core.menu_view.DIVIDER,
  { id = "build", text = "Build", items = {
    { id = "build", text = "Build", command = "build:build" },
    { id = "run", text = "Run", command = "build:run-or-term-or-kill" },
    { id = "build-run", text = "Build and Run", command = "build:build-and-run" },
    { id = "arguments", text = "Run with Arguments...", command = "build:run-or-term-or-kill-with-arguments" },
    core.menu_view.DIVIDER,
    { id = "target", text = "Select Target...", command = "build:select-target" },
    { id = "clean", text = "Clean", command = "build:clean" },
    { id = "rebuild", text = "Rebuild", command = "build:rebuild" },
    { id = "stop", text = "Stop", command = "build:terminate" },
    { id = "output", text = "Show Build Output", command = "build:toggle-drawer",
      checked = function() return build.message_view.visible end }
  } }
}, "build")

core.add_thread(function()
  if config.plugins.build.targets then
    build.set_targets(config.plugins.build.targets, config.plugins.build.type)
  else
    local backends = build.get_backends()
    table.sort(backends, function(a,b) return (a.priority or 0) < (b.priority or 0) end)
    local targets = {}
    for _, backend in ipairs(backends) do
      if backend.id ~= "internal" then
        for _, target in ipairs(backend.infer and backend.infer() or {}) do
          target.backend = backend
          table.insert(targets, target)
        end
      end
    end
    if #targets == 0 then
      local internal = build.get_backends("internal")
      for _, target in ipairs(internal.infer() or {}) do
        target.backend = internal
        table.insert(targets, target)
      end
    end
    build.set_targets(targets)
  end
  build.set_target(build.state.target)
  build.initialized = true
end)

return build

