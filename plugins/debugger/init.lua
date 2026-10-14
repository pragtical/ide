-- mod-version:3.12.3


--[[
# Debugger Plugin

The debugger plugin is architected as follows:

1. A presentation layer (`init.lua`). The presentation layer is a number of dialogs that calls into the secondary layer to get information there.
2. An agnostic model layer (`debugger.lua`). This layer represents the current state of the debugger, with no debugger specific info. Manages agnostic state, described below.
3. A specific debugger layer (`gdb.lua`). Provides functions to read, and set state of the underlying debugger. Should manage as little state as possible in and of itself, purely functions to access the debugger. All functions take callbacks.

## Model Layer

### States

The model layer has the following states.

1. Inactive
2. Running
3. Stopped

#### Inactive

In the inactive state, the debugger is compeltely inactive, and only renders breakpoints.

#### Started

In a started state. Can take input about actviating breakpoints, etc..

#### Running

In the running state, the debugger renders breakpoints, and a status icon showing that the program is running.

#### Stopped

In the stopped state, renders:

* The instruction marker (which is retrieved upon immediate access to this state).
* All breakpoints
* Stack Trace
* Debugger Variables
* Hovered Variables

### Transitions

Transitions can be triggered by either the backend layer, or the user. Triggers are given as (<user> | <backend>)

#### Inactive -> Starting (`debugger.start` | )

Happens when a user manually initiates a start.

#### Starting -> Stopped  ( | `debugger.started`)

First callback from starting; debugger should pause when it's engaged at the primary entrypoint.

* Active debugger determined based on file, active debugger set to that backend.
* All breakpoints applied.
* Continue

#### Running -> Stopped (`debugger.break` | `debugger.stopped`)

Happens on breakpoint trigger, or on break.

* Watched variables queried
* Stacktrace retrieved
* Instruction point retrieved

#### Stopped -> Running (`debugger.continue`, `debugger.step_into`, `debugger.step_out`, debugger.step_over` |)

Happens when a user hits a step or continue function.

#### Stopped -> Inactive (`debugger.terminate` | `debugger.completed`)

Happens when the program completes, or the user terminates debugger.

Any other state transitions are illegal, and will throw an error.

## Backend Layer

The backend has the following functions:

* `variable(name, callback)`
* `stacktrace(callback)`
* `status(callback)`
* `instruction(callback)`
* `start(path, arguments, started, stopped, completed)`
* `continue()`
* `halt()`
* `frame(idx)`
* `terminate()`
* `add_breakpoint(path, line)`
* `remove_breakpoint(path, line)`
* `should_engage(path)`

--]]

local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"
local DocView = require "core.docview"
local Doc = require "core.doc"
local common = require "core.common"
local style  = require "core.style"
local config  = require "core.config"
local tokenizer = require "core.tokenizer"
local syntax = require "core.syntax"
local View = require "core.view"
local StatusView = require "core.statusview"

local storage = require "core.storage"
config.plugins.debugger = config.plugins.debugger or {}
local model = require "plugins.debugger.model"
local build = require "plugins.build"

local draw_line_gutter = DocView.draw_line_gutter
local docview_on_mouse_moved = DocView.on_mouse_moved
local docview_on_mouse_pressed = DocView.on_mouse_pressed
local docview_update = DocView.update
local docview_on_mouse_left = DocView.on_mouse_left

local debugger = {
  drawer_visible = nil,
  state = nil,
  instruction = nil,
  last_exited = nil
}

if not style.debugger then style.debugger = {} end
style.debugger.breakpoint = style.debugger.breakpoint or { common.color "#ca3434" }
style.debugger.instruction = style.debugger.instruction or { common.color "#3434ca" }
style.debugger.font = style.code_font:copy(style.code_font:get_height()*0.7)

debugger.state = storage.load("debugger", "state") or {}
debugger.state.breakpoints = debugger.state.breakpoints or {}
for file, lines in pairs(debugger.state.breakpoints) do
  for line in pairs(lines) do
    model:add_breakpoint(file, line)
  end
end
function debugger:save()
  storage.save("debugger", "state", debugger.state)
end

config.plugins.debugger = common.merge({
  step_refresh_watches = true,
  hide_drawer_after = 3,
  interval = 0.01,
  backend = "gdb",
  gdb_path = "gdb",
  entrypoint = "main",
  drawer_size = 200,
  hover_time_watch = 0.5,
  time_to_trigger_uninteractable_background = 0.1,
  skip_files = {
    "/usr/include/*",
    "/usr/include/*/*",
    "/usr/include/*/*/*",
    "/usr/include/*/*/*/*"
  }
}, config.plugins.debugger)

for i,v in ipairs(config.plugins.debugger.skip_files) do table.insert(model.skip_files, v) end

local function jump_to_file(file, line)
  -- Check to see if the file is in the project. If it is, open it, and go to the line.
  if file and system.get_file_info(file) then
    local view = core.root_view:open_doc(core.open_doc(file))
    if line then
      view:scroll_to_line(line, true, true)
      view.doc:set_selection(line, 1, line, 1)
    end
  end
end

function debugger:set_instruction(path, line)
  self.instruction = path and { path, line } or nil
  if path then jump_to_file(path, line) end
end

function debugger:refresh()
  model:stacktrace(function(frames)
    local frame = frames[1]
    for i,v in ipairs(frames) do
      local func, args, file, line = table.unpack(v)
      if file and system.get_file_info(file) then
        frame = v
        break
      end
    end
    if frame then self:set_instruction(frame[3], frame[4]) end
  end)
  if self:should_show_drawer() then
    self.stack_view:refresh(function() self.watch_result_view:refresh() end)
  end
end

function debugger:paused()
  self:refresh()
end

function debugger:exited()
  debugger.instruction = nil
  debugger.last_exited = system.get_time()
  debugger.stack_view.stack = { }
  debugger.stack_view.refreshing = nil
  debugger.hover_view:hide_floating()
  if self.drawer_visible then self.drawer_visible = false end
end

function debugger:should_show_drawer()
  return self.drawer_visible == true or (self.drawer_visible == nil and (model.state ~= "inactive"
    or (self.last_exited ~= nil and system.get_time() - self.last_exited < (config.plugins.debugger.hide_drawer_after or 0))))
end

---Extract a hovered expression with balanced subscripts and member access.
---@param docview core.docview Document view
---@param line integer Source line
---@param col integer Hovered column
---@return string? expression Expression ending at the hovered identifier
---@return integer? line1 Selection start line
---@return integer? col1 Selection start column
---@return integer? line2 Selection end line
---@return integer? col2 Selection end column
function debugger:get_hovering_token(docview, line, col)
  local text = docview.doc.lines[line] or ""
  if not text:sub(col, col):match("[%w_%]%)]") then return nil end
  local word = text:sub(col):match("^[%w_]+")
  local finish = word and col + #word - 1 or col
  local start, stack = finish, {}
  while start >= 1 do
    local char = text:sub(start, start)
    if char == "]" or char == ")" then
      stack[#stack + 1] = char == "]" and "[" or "("
    elseif char == "[" or char == "(" then
      if stack[#stack] ~= char then break end
      stack[#stack] = nil
    elseif #stack == 0 and not char:match("[%w_%.:]") then
      if char == ">" and text:sub(start - 1, start - 1) == "-" then start = start - 1 else break end
    end
    start = start - 1
  end
  if #stack > 0 then return nil end
  return text:sub(start + 1, finish), line, start + 1, line, finish
end

function DocView:on_mouse_pressed(button, x, y, clicks)
  if button == "left" and self.hovering_gutter and command.perform("debugger:toggle-line-breakpoint", self.hovering_gutter) then
    return true
  end
  return docview_on_mouse_pressed(self, button, x, y, clicks)
end

function DocView:on_mouse_moved(x, y, ...)
  self.hovering_gutter = nil
  self.last_moved_time = { x, y, system.get_time() }
  self.watch_hover_value = nil
  self.watch_token = nil
  if docview_on_mouse_moved(self, x, y, ...) then return true end
  if x > self.position.x and x < self.position.x + self:get_gutter_width() then
    self.cursor = "arrow"
    local line = self:resolve_screen_position(x + self:get_gutter_width(), y)
    self.hovering_gutter = line >= 1 and line <= #self.doc.lines and line or nil
  end
end

function DocView:draw_line_gutter(vline, x, y, width)
  local idx = vline
  if model:has_breakpoint(self.doc.abs_filename, idx) then
    renderer.draw_rect(x, y, self:get_gutter_width(), self:get_line_height(), style.debugger.breakpoint)
  end
  if model.state == "stopped" and debugger.instruction and debugger.instruction[1] == self.doc.abs_filename and idx == debugger.instruction[2] then
    renderer.draw_rect(x, y+1, self:get_gutter_width(), self:get_line_height()-2, style.debugger.instruction)
  end
  return draw_line_gutter(self, vline, x, y, width)
end

---Hide debugger hover information when another view takes the pointer.
function DocView:on_mouse_left()
  self.hovering_gutter, self.watch_hover_value, self.watch_token = nil, nil, nil
  if debugger.hover_view and debugger.hover_view.owner_view == self then debugger.hover_view:hide_floating() end
  return docview_on_mouse_left(self)
end

---Request the hovered expression once and ignore responses after the hover changes.
function DocView:update()
  docview_update(self)
  if self.watch_generation ~= model.stack_generation then
    self.watch_generation = model.stack_generation
    self.watch_hover_value, self.watch_token = nil, nil
  end
  if model.state ~= "stopped" or not self:is(DocView) or core.active_view ~= self
    or not self.doc or not self.last_moved_time or self.watch_token ~= nil then return end
  local x, y = self.last_moved_time[1], self.last_moved_time[2]
  if core.root_view:get_floating_view_at(x, y) then return end
  if system.get_time() - math.max(debugger.last_start_time or 0, self.last_moved_time[3]) < config.plugins.debugger.hover_time_watch then return end
  local line, col = self:resolve_screen_position(x, y)
  local expression, line1, col1, line2, col2 = debugger:get_hovering_token(self, line, col)
  if not expression then self.watch_token = false; return end
  local token = { line1, col1, col2 }
  self.watch_token = token
  model:variable(expression, function(value)
    if self.watch_token ~= token or core.active_view ~= self or model.state ~= "stopped" then return end
    self.watch_hover_value = value
    if value then
      local popup = debugger.hover_view
      popup.owner_view, popup.floating_options.owner = self, self
      local height = style.font:get_height() + style.padding.y * 2
      popup:set_floating_bounds(x, y - height - style.padding.y,
        style.font:get_width(value) + style.padding.x * 2, height)
      popup:show_floating()
    end
  end)
end

local hover_view = View()
debugger.hover_view = hover_view
hover_view:set_floating(true, { focus = "none", interactive = false })
---Dismiss stale hover values through the shared floating lifecycle.
function hover_view:update()
  local owner = self.owner_view
  if not owner or core.active_view ~= owner or model.state ~= "stopped" or not owner.watch_hover_value then
    self:hide_floating()
  elseif self.last_font ~= style.font or self.last_font_size ~= style.font:get_size() then
    self.last_font, self.last_font_size = style.font, style.font:get_size()
    self:set_floating_bounds(self.position.x, self.position.y,
      style.font:get_width(owner.watch_hover_value) + style.padding.x * 2,
      style.font:get_height() + style.padding.y * 2)
  end
end
---Draw debugger information in the popup layer instead of the document draw path.
function hover_view:draw()
  local value = self.owner_view and self.owner_view.watch_hover_value
  if not value then return end
  self:draw_background(style.accent)
  renderer.draw_rect(self.position.x + SCALE, self.position.y + SCALE,
    self.size.x - 2 * SCALE, self.size.y - 2 * SCALE, style.background3)
  renderer.draw_text(style.font, value, self.position.x + style.padding.x,
    self.position.y + style.padding.y, style.text)
end

function debugger:should_look_uninteractable()
  if model.state == "running" then
    self.last_change_state = self.last_change_state or system.get_time()
  elseif model.state == "starting" then
    self.last_change_state = 0
  else
    self.last_change_state = nil
  end
  if self.last_change_state then
    if system.get_time() - self.last_change_state > config.plugins.debugger.time_to_trigger_uninteractable_background then
      return true
    end
    core.redraw = true
  end
  return false
end

local DebuggerWatchVariableDoc = Doc:extend()
function DebuggerWatchVariableDoc:new()
  DebuggerWatchVariableDoc.super.new(self)
end

local DebuggerWatchHalf = DocView:extend()
DebuggerWatchHalf.disable_save = true
function DebuggerWatchHalf:new(title, doc)
  DebuggerWatchHalf.super.new(self, doc)
  self.title = title
  self.is_debugger_view = true
  self.target_size = config.plugins.debugger.drawer_size
  self.init_size = true
end
function DebuggerWatchHalf:try_close(do_close) end
---Include the watch header in the content height while allowing long lists to scroll.
---@return number height Watch content height
function DebuggerWatchHalf:get_scrollable_size()
  return self:get_line_height() * (self:visual_line_count() + 1) + style.padding.y * 2
end
function DebuggerWatchHalf:get_gutter_width() return 0 end
function DebuggerWatchHalf:draw_line_gutter(idx, x, y) end
function DebuggerWatchHalf:get_font() return style.debugger.font end
function DebuggerWatchHalf:get_line_height() return style.debugger.font:get_height() + style.padding.y * 2 end
function DebuggerWatchHalf:draw_background(color)
  DebuggerWatchHalf.super.draw_background(self, debugger:should_look_uninteractable() and style.dim or style.background3)
end

function DebuggerWatchHalf:update()
  local dest = debugger:should_show_drawer() and self.target_size or 0
  if self.init_size then
    self.size.y = dest
    self.init_size = false
  else
    self:move_towards(self.size, "y", dest)
  end
  DebuggerWatchHalf.super.update(self)
end
function DebuggerWatchHalf:set_target_size(axis, value)
  if axis == "y" then
    self.target_size = value
    return true
  end
end
function DebuggerWatchHalf:draw_line_body(idx, x, y)
  renderer.draw_rect(x - style.padding.x, y + self:get_line_height(), self.size.x, 1, style.divider)
  return DebuggerWatchHalf.super.draw_line_body(self, idx, x, y)
end

---Offset document layout and hit testing below the watch header.
---@return number x Content origin x
---@return number y Content origin y
function DebuggerWatchHalf:get_content_offset()
  local x, y = DebuggerWatchHalf.super.get_content_offset(self)
  return x, y + self:get_line_height()
end

function DebuggerWatchHalf:draw()
  DebuggerWatchHalf.super.draw(self)
  common.draw_text(style.font, style.text, self.title, "left", self.position.x + style.padding.x, self.position.y, self.size.x, self:get_line_height())
  renderer.draw_rect(self.position.x, self.position.y + self:get_line_height(), self.size.x, 1, style.divider)
end

local DebuggerWatchResultView = DebuggerWatchHalf:extend()
function DebuggerWatchResultView:new()
  DebuggerWatchResultView.super.new(self, "Watch Values", DebuggerWatchVariableDoc(self))
end

---Refresh watch results with valid document lines and reject responses from older frames.
---@param index integer? Expression row to refresh, or nil for all rows
function DebuggerWatchResultView:refresh(index)
  self.refresh_generation = (self.refresh_generation or 0) + 1
  local generation = self.refresh_generation
  local expressions = debugger.watch_variable_view.doc.lines
  local values = {}
  for line = 1, #expressions do
    values[line] = index and self.doc.lines[line] and self.doc.lines[line]:gsub("\n$", "") or ""
  end
  local function render()
    self.doc:remove(1, 1, #self.doc.lines, #self.doc.lines[#self.doc.lines])
    self.doc:insert(1, 1, table.concat(values, "\n"))
    self.doc:sanitize_selection()
  end
  render()
  for line, expression in ipairs(expressions) do
    if (not index or index == line) and expression:find("%S") and model.state == "stopped" then
      local row = line
      model:variable(expression:gsub("\n$", ""), function(value)
        if generation ~= self.refresh_generation or model.state ~= "stopped" then return end
        values[row] = (value or "undefined"):gsub("[\r\n]+", " ")
        render()
      end)
    end
  end
end


local DebuggerWatchVariableView = DebuggerWatchHalf:extend()
function DebuggerWatchVariableView:new()
  DebuggerWatchVariableView.super.new(self, "Watch Expressions", DebuggerWatchVariableDoc(self))
end


local DebuggerStackView = View:extend()
debugger.DebuggerStackView = DebuggerStackView

function DebuggerStackView:new()
  DebuggerStackView.super.new(self)
  self.stack = { }
  self.is_debugger_view = true
  self.target_size = config.plugins.debugger.drawer_size
  self.scrollable = true
  self.init_size = true
  self.hovered_frame = nil
  self.active_frame = nil
end

function DebuggerStackView:update()
  local dest = debugger:should_show_drawer() and self.target_size or 0
  if self.init_size then
    self.size.y = dest
    self.init_size = false
  else
    self:move_towards(self.size, "y", dest)
  end
  DebuggerStackView.super.update(self)
end

function DebuggerStackView:set_target_size(axis, value)
  if axis == "y" then
    self.target_size = value
    return true
  end
end

local c_syntax
function DebuggerStackView:set_stack(stack, on_finish)
  self.stack = stack
  self.stack_tokens = {}

  c_syntax = c_syntax or syntax.get(".c")
  for i,v in ipairs(stack) do
    local tokens, state = tokenizer.tokenize(c_syntax, v[2] or "")
    self.stack_tokens[i] = {}
    for j, type, text in tokenizer.each_token(tokens) do
      table.insert(self.stack_tokens[i], { type, text })
    end
  end

  self.hovered_frame = nil

  self.active_frame = 1
  for i,v in ipairs(stack) do
    local func, args, file, line = table.unpack(v)
    if file and core.root_project():get_file_info(file) then
      self.active_frame = i
      break
    end
  end

  model:frame(self.active_frame - 1, on_finish)
  core.redraw = true
end

function DebuggerStackView:get_item_height() return style.debugger.font:get_height() + style.padding.y end
function DebuggerStackView:get_scrollable_size() return #self.stack and self:get_item_height() * (#self.stack + 1) end
---Return the measured stack width rather than an infinite scrollbar range.
---@return number width Stack content width
function DebuggerStackView:get_h_scrollable_size()
  if self.measured_stack == self.stack and self.width_font == style.debugger.font
    and self.width_font_size == style.debugger.font:get_size() then return self.stack_width end
  local width = 0
  for i, frame in ipairs(self.stack) do
    local text = "#" .. i .. " " .. (frame[1] or "?") .. " " .. (frame[2] or "") .. " "
      .. (frame[3] and core.root_project():normalize_path(frame[3]) or "") .. (frame[4] and " line " .. frame[4] or "")
    width = math.max(width, style.debugger.font:get_width(text) + style.padding.x * 2)
  end
  self.measured_stack, self.stack_width = self.stack, width
  self.width_font, self.width_font_size = style.debugger.font, style.debugger.font:get_size()
  return width
end

function DebuggerStackView:on_mouse_moved(px, py, ...)
  DebuggerStackView.super.on_mouse_moved(self, px, py, ...)
  if self:scrollbar_dragging() or self:scrollbar_hovering() then self.hovered_frame = nil; return end
  local ox, oy = self:get_content_offset()
  local offset = math.floor((py - oy) / self:get_item_height())
  if px >= self.position.x and px < self.position.x + self.size.x then
    self.hovered_frame = offset >= 1 and offset <= #self.stack and offset
  else
    self.hovered_frame = nil
  end
end


---Clear stack hover state when another view takes the pointer.
function DebuggerStackView:on_mouse_left()
  self.hovered_frame = nil
  return DebuggerStackView.super.on_mouse_left(self)
end

function DebuggerStackView:draw()
  self:draw_background(((self.refreshing and (#self.stack == 0 or system.get_time() - self.refreshing > config.plugins.debugger.time_to_trigger_uninteractable_background)) or debugger:should_look_uninteractable()) and style.dim or style.background3)
  if not core.root_project() then return end
  local h = style.debugger.font:get_height()
  local item_height = self:get_item_height()
  local ox, oy = self:get_content_offset()
  common.draw_text(style.font, style.text, "Stack Trace", "left", ox + style.padding.x, oy, 0, item_height)
  for i,v in ipairs(self.stack) do
    local yoffset = i*item_height
    local y = oy + yoffset
    if y + h + style.padding.y*2 >= self.position.y and y < self.position.y + self.size.y then
      if not debugger:should_look_uninteractable() and (self.hovered_frame == i or self.active_frame == i) then
        renderer.draw_rect(self.position.x, y, self.size.x, item_height, self.active_frame == i and style.debugger.instruction or style.line_highlight)
      end
      local tx = ox + style.padding.y
      tx = common.draw_text(style.debugger.font, style.accent, "#" .. i .. " ", "left", tx, oy + yoffset, 0, item_height)
      tx = common.draw_text(style.debugger.font, style.text, (v[1] or "?") .. " ", "left", tx, oy + yoffset, 0, item_height)
      for _,  token in ipairs(self.stack_tokens[i]) do
        local type, text = table.unpack(token)
        if tx < self.position.x + self.size.x then
          tx = common.draw_text(style.debugger.font, style.syntax[type] or style.text, text, "left", tx, oy + yoffset, 0, item_height)
        end
      end
      if tx < self.position.x + self.size.x then
        tx = common.draw_text(style.debugger.font, style.text, " " .. (v[3] and core.root_project():normalize_path(v[3]) or "") .. (v[4] and (" line " .. v[4]) or ""), "left", tx, oy + yoffset, 0, item_height)
      end
    end
  end
  self:draw_scrollbar()
end

function DebuggerStackView:refresh(on_finish)
  self.refreshing = system.get_time()
  model:stacktrace(function(stack)
    self.refreshing = nil
    self:set_stack(stack, on_finish and function() on_finish(stack) end)
  end)
end


local terminal
if config.plugins.terminal ~= false and (package.loaded["plugins.terminal"] or package.searchpath("plugins.terminal", package.path)) then
  terminal = require "plugins.terminal"
end
local has_terminal = terminal ~= nil
local TerminalView = terminal and terminal.class
debugger.stack_view = DebuggerStackView()
debugger.watch_variable_view = DebuggerWatchVariableView()
debugger.watch_result_view = DebuggerWatchResultView()
debugger.terminal_view = has_terminal and TerminalView({ shell = "DUMMY", font = style.debugger.font })
if debugger.terminal_view then debugger.terminal_view.is_debugger_view = true end

local old_set_active_view = core.set_active_view
function core.set_active_view(view)
  local result = old_set_active_view(view)
  if model.state == "inactive" and view and view.is_debugger_view and (debugger.last_exited and config.plugins.debugger.hide_drawer_after and (system.get_time() - debugger.last_exited) < config.plugins.debugger.hide_drawer_after) then
    debugger.drawer_visible = true
  end
  return result
end

core.add_thread(function()
  local node = core.root_view:get_active_node_default()
  debugger.stack_view_node = node:split("down", debugger.stack_view, { y = true }, true)
  if debugger.terminal_view then
    debugger.terminal_view_node = debugger.stack_view_node:split("right", debugger.terminal_view, { y = false }, true)
    debugger.watch_variable_view_node = debugger.terminal_view_node:split("up", debugger.watch_variable_view, { y = false }, true)
    debugger.watch_result_view_node = debugger.watch_variable_view_node:split("right", debugger.watch_result_view, { y = false }, true)
  else
    debugger.watch_variable_view_node = debugger.stack_view_node:split("right", debugger.watch_variable_view, { y = true }, true)
    debugger.watch_result_view_node = debugger.watch_variable_view_node:split("right", debugger.watch_result_view, { y = true }, true)
  end
end)

core.add_thread(function()
  local item = core.status_view:add_item({
    predicate = function() return config.target_binary or model.state ~= "inactive" end,
    name = "debugger:status",
    alignment = StatusView.Item.RIGHT,
    command = function()
      if model.state == "inactive" then
        command.perform("debugger:start")
      elseif model.state == "stopped" then
        command.perform("debugger:continue")
      elseif model.state == "running" then
        command.perform("debugger:halt")
      end
    end
  })
  item.on_draw = function(x, y, h, hovered, calc_only)
    local color = {
      stopped = style.debugger.breakpoint,
      running = style.good,
      starting = style.warn
    }
    local size = (h - style.padding.y * 2) / 2
    local width = size + style.padding.x / 2 + style.font:get_width(model.state)
    if not calc_only then
      renderer.draw_rect(x, y + (h - size) / 2, size, size, color[model.state] or style.dim)
      common.draw_text(style.font, style.text, model.state, "left", x + size + style.padding.x / 2, y, nil, h)
    end
    return width
  end
end)

command.add(function()
  return model.state == "stopped"
end, {
  ["debugger:continue"] = function()
    model:continue()
  end
})
command.add(function()
  return model.state == "running"
end, {
  ["debugger:halt"] = function()
    model:halt()
  end
})

command.add(function()
  return config.target_binary and build.get_binary(config.target_binary) and model.state == "inactive"
end, {
  ["debugger:start"] = function()
    debugger.last_start_time = system.get_time()
    if debugger.terminal_view and debugger.terminal_view.terminal then debugger.terminal_view.terminal:clear() end
    model:start(build.get_binary(config.target_binary), config.target_binary_arguments, function()
      debugger:paused()
    end, function()
      debugger:exited()
    end, function(line, source)
      if debugger.terminal_view then
        debugger.terminal_view:input(line .. "\r\n")
      else
        print(line)
      end
    end)
  end
})

command.add(function()
  return (model.state == "stopped") or (model.state == "inactive" and config.target_binary
    and (build.get_binary(config.target_binary) or build.can_build(build.targets[build.state.target])))
end, {
  ["debugger:start-or-continue"] = function()
    if not build.get_binary(config.target_binary) then
      build.build(function(status) if status == 0 then command.perform("debugger:start") end end)
    else
      command.perform(model.state == "stopped" and "debugger:continue" or "debugger:start")
    end
  end
})

command.add(function()
  return core.active_view and core.active_view:extends(DocView) and core.active_view.doc.abs_filename ~= nil
end, {
  ["debugger:toggle-line-breakpoint"] = function(line)
    if not line then line = core.active_view.doc:get_selection(true) end
    if line then
      local file = core.active_view.doc.abs_filename
      if not model:has_breakpoint(file, line) then
        model:add_breakpoint(file, line)
        if not debugger.state.breakpoints then debugger.state.breakpoints = {} end
        if not debugger.state.breakpoints[file] then debugger.state.breakpoints[file] = {} end
        debugger.state.breakpoints[file][line] = true
      else
        model:remove_breakpoint(file, line)
        if debugger.state.breakpoints[file] then debugger.state.breakpoints[file][line] = nil end
      end
      debugger:save()
    end
  end
})

command.add(function()
  return core.active_view and core.active_view:is(DebuggerStackView) and core.active_view.hovered_frame, core.active_view
end, {
  ["debugger:jump-hovered-frame"] = function(view)
    jump_to_file(view.stack[view.hovered_frame][3], view.stack[view.hovered_frame][4])
  end
})

command.add(function()
  return core.active_view and core.active_view:is(DebuggerStackView) and core.active_view.hovered_frame and model.state == "stopped", core.active_view
end, {
  ["debugger:select-hovered-frame"] = function(view)
    model:frame(view.hovered_frame - 1, function()
      debugger.watch_result_view:refresh()
    end)
    view.active_frame = view.hovered_frame
    debugger:set_instruction(view.stack[view.hovered_frame][3], view.stack[view.hovered_frame][4])
  end
})

command.add(nil, {
  ["debugger:toggle-drawer"] = function() debugger.drawer_visible = not debugger.drawer_visible end
})

command.add(function()
  return model.state ~= "inactive"
end, {
  ["debugger:terminate"] = function() model:terminate() end
})

command.add(DebuggerWatchVariableView, {
  ["debugger:refresh-watches"] = function()
    debugger.watch_result_view:refresh()
    core.set_active_view(core.next_active_view or core.last_active_view)
  end
})


command.add(function()
  return model.state == "stopped"
end, {
  ["debugger:step-over"] = function() model:step_over() end,
  ["debugger:step-into"] = function() model:step_into() end,
  ["debugger:step-out"] =  function() model:step_out() end,
})

keymap.add {
  ["1lclick"]            = "debugger:jump-hovered-frame",
  ["2lclick"]            = "debugger:select-hovered-frame",
  ["return"]             = "debugger:refresh-watches",
  ["keypad enter"]       = "debugger:refresh-watches",
  ["f7"]                 = "debugger:step-over",
  ["shift+f7"]           = "debugger:step-into",
  ["ctrl+f7"]            = "debugger:step-out",
  ["f8"]                 = { "debugger:start-or-continue", "debugger:halt" },
  ["shift+f8"]           = "debugger:terminate",
  ["f9"]                 = "debugger:toggle-line-breakpoint",
  ["f12"]                = "debugger:toggle-drawer",
}

---Attach GDB to a terminal view without modifying its native userdata.
---@param attached_view table Terminal view with terminal, options and selection fields
function debugger:attach_terminal(attached_view)
  local proc = {
    buffer = "",
    view = attached_view,
    read_stdout = function(self)
      if self.closed then return nil end
      local a = self.buffer
      self.buffer = ""
      return a
    end,
    write = function(self, chunk)
      self.view.terminal:input(chunk)
      return #chunk
    end
  }

  local old_shift_update = attached_view.shift_selection_update
  proc.read_stderr = function() return nil end
  proc.running = function(self) return not self.closed end
  proc.returncode = function() return 0 end
  proc.terminate = function(self)
    if self.closed then return end
    self.closed = true
    self.view.terminal:input("\3-gdb-exit\n")
    self.view.shift_selection_update = old_shift_update
  end
  ---Capture native terminal output without assigning methods to its userdata.
  ---@return integer|boolean shifts Scrollback shift count or false when idle
  function attached_view:shift_selection_update()
    local shifts = self.terminal:update(function(chunk) proc.buffer = proc.buffer .. chunk end)
    if shifts and not self.focused then self.modified_since_last_focus = true end
    if self.selection and shifts then
      self.selection[2], self.selection[4] = self.selection[2] - shifts, self.selection[4] - shifts
      if math.abs(math.min(self.selection[2], self.selection[4])) > self.options.scrollback_limit then self.selection = nil end
    end
    return shifts
  end
  model:attach(proc, model.backends.gdb, function()
    debugger:paused()
  end, function()
    debugger:exited()
  end)
end

if has_terminal then
  command.add(function()
    return terminal and model.state == "inactive" and core.active_view and core.active_view:is(TerminalView)
  end, {
    ["debugger:attach"] = function()
      local attached_view = core.active_view
      debugger.last_start_time = system.get_time()

      debugger:attach_terminal(attached_view)
    end,
    ["debugger:insert-run"] = function()
      core.active_view.terminal:input("gdb -q -nx --interpreter=mi3 --args ")
    end
  })
  command.add(function()
    return terminal and model.state ~= "inactive" and core.active_view and core.active_view:is(TerminalView)
  end, {
    ["debugger:detach"] = function()
      model:terminate()
    end
  })
  keymap.add {
    ["f8"]                 = { "debugger:attach", "debugger:detach" },
    ["ctrl+shift+d"]       = "debugger:insert-run"
  }
end

do
  -- overwrite the build plugins' "play" toolbar button to activate the debugger, if this is a debug build.
  build.build_bar_view.toolbar_commands[2] = { symbol = '"', command = "debugger:start-or-continue"}
  build.build_bar_view.toolbar_commands[4] = { symbol = '$', command = "debugger:terminate"}
end

core.menu_view:register({ "tools" }, {
  core.menu_view.DIVIDER,
  { id = "debugger", text = "Debugger", items = {
    { id = "start", text = "Start or Continue", command = "debugger:start-or-continue" },
    { id = "pause", text = "Pause", command = "debugger:halt" },
    { id = "stop", text = "Stop", command = "debugger:terminate" },
    core.menu_view.DIVIDER,
    { id = "over", text = "Step Over", command = "debugger:step-over" },
    { id = "into", text = "Step Into", command = "debugger:step-into" },
    { id = "out", text = "Step Out", command = "debugger:step-out" },
    core.menu_view.DIVIDER,
    { id = "breakpoint", text = "Toggle Breakpoint", command = "debugger:toggle-line-breakpoint" },
    { id = "drawer", text = "Show Debugger", command = "debugger:toggle-drawer",
      checked = function() return debugger:should_show_drawer() end }
  } }
}, "debugger")

return debugger
