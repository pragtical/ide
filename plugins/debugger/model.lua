local config = require "core.config"

---@class plugins.debugger.model
---@field state "inactive"|"starting"|"running"|"stopped"
---@field active table? Selected debugger backend
local model = {
  breakpoints = {},
  skip_files = {},
  backends = {
    gdb = require "plugins.debugger.gdb",
    dap = require "plugins.debugger.dap"
  },
  state = "inactive"
}

---Return whether a persistent source breakpoint is enabled.
---@param path string Source filename
---@param line integer Source line
---@return boolean enabled Whether a breakpoint exists
function model:has_breakpoint(path, line)
  return self.breakpoints[path] ~= nil and self.breakpoints[path][line] == true
end

---Resume after a breakpoint update only when it interrupted a running session.
---@param backend table Backend receiving the update
---@param state string State before the update
local function resume_after_update(backend, state)
  if state ~= "running" then return nil end
  return function()
    if model.active ~= backend then return end
    if model.state == "stopped" then model:continue() else backend:continue() end
  end
end

---Persist and install a source breakpoint in the active backend.
---@param path string Source filename
---@param line integer Source line
function model:add_breakpoint(path, line)
  local state, backend = self.state, self.active
  self.breakpoints[path] = self.breakpoints[path] or {}
  self.breakpoints[path][line] = true
  if state == "running" then backend:halt() end
  if state == "stopped" or state == "running" then
    backend:add_breakpoint(path, line, resume_after_update(backend, state))
  end
end

---Remove a persistent breakpoint and update the active backend.
---@param path string Source filename
---@param line integer Source line
function model:remove_breakpoint(path, line)
  local state, backend = self.state, self.active
  if self.breakpoints[path] then self.breakpoints[path][line] = nil end
  if state == "running" then backend:halt() end
  if state == "stopped" or state == "running" then
    backend:remove_breakpoint(path, line, resume_after_update(backend, state))
  end
end

---Create session callbacks which ignore late events from previous sessions.
---@param backend table Backend selected for this session
---@param paused function? Pause callback
---@param exited function? Completion callback
---@param out function? Output callback
---@return function started
---@return function stopped
---@return function completed
---@return function output
function model:session_callbacks(backend, paused, exited, out)
  self.session = (self.session or 0) + 1
  local session = self.session
  self.active, self.state, self.current_frame = backend, "starting", 0
  self.view_paused, self.view_exited, self.view_out = paused, exited, out
  self.saved_stacktrace, self.stack_callbacks = nil, nil
  self.stack_generation = (self.stack_generation or 0) + 1
  local function wrap(method)
    return function(...)
      if self.session == session and self.active == backend then method(self, ...) end
    end
  end
  return wrap(self.started), wrap(self.stopped), wrap(self.completed), wrap(self.out)
end

---Start the configured backend and register session-scoped UI callbacks.
---@param path string Executable filename
---@param arguments string[]? Program arguments
---@param paused function? Pause callback
---@param exited function? Completion callback
---@param out function? Output callback
function model:start(path, arguments, paused, exited, out)
  assert(path, "requires a path")
  assert(self.state == "inactive", "can only start from inactive state")
  local selected = config.plugins.debugger.backend
  local backend = selected and assert(self.backends[selected], "Unknown debugger backend: " .. selected)
  if not backend then
    for _, name in ipairs { "gdb", "dap" } do
      if self.backends[name]:should_engage(path) then backend = self.backends[name]; break end
    end
  end
  assert(backend, "can't find appropriate backend for " .. path)
  backend:start(path, arguments or {}, self:session_callbacks(backend, paused, exited, out))
end

---Attach a backend to an existing process-like terminal stream.
---@param terminal table Terminal adapter
---@param backend table Debugger backend
---@param paused function? Pause callback
---@param exited function? Completion callback
---@param out function? Output callback
function model:attach(terminal, backend, paused, exited, out)
  assert(self.state == "inactive", "can only attach from inactive state")
  backend:attach(terminal, self:session_callbacks(backend, paused, exited, out))
end

---Invalidate stopped-frame data as the inferior resumes.
function model:run()
  self.saved_stacktrace, self.stack_callbacks = nil, nil
  self.stack_generation = (self.stack_generation or 0) + 1
  self.state, self.current_frame = "running", 0
end

---Apply persisted breakpoints and optional skip patterns during initialization.
function model:started()
  assert(self.state == "starting", "can only initialize from starting state")
  self.state = "stopped"
  for path, lines in pairs(self.breakpoints) do
    for line, enabled in pairs(lines) do if enabled then self:add_breakpoint(path, line) end end
  end
  if self.active.skip_file then
    for _, pattern in ipairs(self.skip_files) do self.active:skip_file(pattern) end
  end
  self:run()
end

---Continue execution from a stopped state.
function model:continue()
  assert(self.state == "stopped", "can only continue from stopped state")
  self:run()
  self.active:continue()
end

---Step into the next source statement.
function model:step_into()
  assert(self.state == "stopped", "can only step from stopped state")
  self:run()
  self.active:step_into()
end

---Step over the next source statement.
function model:step_over()
  assert(self.state == "stopped", "can only step from stopped state")
  self:run()
  self.active:step_over()
end

---Run until the selected function returns.
function model:step_out()
  assert(self.state == "stopped", "can only step from stopped state")
  self:run()
  self.active:step_out()
end

---Request a pause; the backend's stopped event confirms the transition.
function model:halt()
  assert(self.state == "running", "can only halt from running state")
  self.active:halt()
end

---End the session, clearing model state before invoking UI callbacks.
function model:terminate()
  assert(self.state ~= "inactive", "can only terminate an active session")
  local backend = self.active
  backend:terminate()
  self:completed()
end

---Notify the UI once when the backend pauses the inferior.
function model:stopped()
  if self.state == "stopped" then return end
  assert(self.state == "running", "can only stop from running state")
  self.state = "stopped"
  if self.view_paused then self.view_paused() end
end

---Complete an active session once, dropping cached frames and pending consumers.
function model:completed()
  if self.state == "inactive" then return end
  local callback = self.view_exited
  self.state, self.active = "inactive", nil
  self.saved_stacktrace, self.stack_callbacks = nil, nil
  self.stack_generation = (self.stack_generation or 0) + 1
  if callback then callback() end
end

---Forward debugger output when the UI registered a consumer.
---@param line string Output text
---@param source string? Stream category
function model:out(line, source)
  if self.view_out then self.view_out(line, source) end
end

---Select a zero-based stack frame.
---@param index integer Frame index
---@param callback function? Completion callback
function model:frame(index, callback)
  assert(self.state == "stopped", "can only select frames from stopped state")
  if self.current_frame ~= index then
    self.current_frame = index
    self.stack_generation = (self.stack_generation or 0) + 1
    self.stack_callbacks = nil
  end
  return self.active:frame(index, callback)
end

---Share one stack query among consumers and reject replies after resuming.
---@param callback fun(stack:table[]) Stack result callback
function model:stacktrace(callback)
  assert(self.state == "stopped", "can only retrieve frames from stopped state")
  if self.saved_stacktrace then callback(self.saved_stacktrace); return end
  if self.stack_callbacks then self.stack_callbacks[#self.stack_callbacks + 1] = callback; return end
  self.stack_callbacks = { callback }
  local generation = self.stack_generation
  self.active:stacktrace(function(stack)
    if generation ~= self.stack_generation or self.state ~= "stopped" then return end
    local callbacks = self.stack_callbacks
    self.saved_stacktrace, self.stack_callbacks = stack, nil
    for _, consume in ipairs(callbacks) do consume(stack) end
  end)
end

---Evaluate a watch expression in the selected frame.
---@param name string Expression
---@param callback fun(value:string?) Result callback
function model:variable(name, callback)
  assert(self.state == "stopped", "can only evaluate expressions from stopped state")
  local generation = self.stack_generation
  return self.active:variable(name, function(value)
    if self.state == "stopped" and self.stack_generation == generation then callback(value) end
  end)
end

---Retrieve the last known source location.
---@param callback function Location callback
function model:instruction(callback)
  assert(self.state == "stopped", "can only retrieve a location from stopped state")
  return self.active:instruction(callback)
end

return model
