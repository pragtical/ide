local core = require "core"
local config = require "core.config"
local json = require "core.json"

---@class plugins.debugger.dap
local dap = { command_queue = {}, breakpoints = {}, sequence = 0, thread_id = 1, frame_id = nil }

---Decode one complete framed message, retaining incomplete headers and bodies.
---@param buffer string Buffered adapter bytes
---@return table? message Decoded complete message
---@return string remainder Bytes not consumed by this message
function dap.parse_message(buffer)
  local header_end = buffer:find("\r\n\r\n", 1, true)
  if not header_end then return nil, buffer end
  local length = tonumber(buffer:sub(1, header_end - 1):match("[Cc]ontent%-[Ll]ength:%s*(%d+)"))
  assert(length, "Missing DAP Content-Length")
  local body_start = header_end + 4
  if #buffer < body_start + length - 1 then return nil, buffer end
  local message, err = json.decode(buffer:sub(body_start, body_start + length - 1))
  assert(type(message) == "table", err or "Invalid DAP JSON message")
  return message, buffer:sub(body_start + length)
end

---Queue a request; response callbacks receive the response body and any error.
---@param name string DAP request name
---@param arguments table? Request arguments
---@param callback fun(body:table,error:string?)? Response callback
function dap:cmd(name, arguments, callback)
  self.sequence = self.sequence + 1
  local payload = json.encode { seq = self.sequence, type = "request", command = name, arguments = arguments or {} }
  -- core.json encodes empty tables as objects; DAP requires an array here.
  payload = payload:gsub('"breakpoints":{}', '"breakpoints":[]')
  self.pending_output = (self.pending_output or "") .. "Content-Length: " .. #payload .. "\r\n\r\n" .. payload
  if callback then self.command_queue[self.sequence] = callback end
end

---Use DAP only when explicitly selected in the debugger configuration.
---@param path string Executable path
---@return boolean supported Whether DAP is the configured backend
function dap:should_engage(path) return config.plugins.debugger.backend == "dap" end
---Step into a source statement on the stopped thread.
function dap:step_into() self:cmd("stepIn", { threadId = self.thread_id }) end
---Step over a source statement on the stopped thread.
function dap:step_over() self:cmd("next", { threadId = self.thread_id }) end
---Step out of the selected frame.
function dap:step_out() self:cmd("stepOut", { threadId = self.thread_id }) end
---Resume the stopped thread.
function dap:continue() self:cmd("continue", { threadId = self.thread_id }) end
---Ask the adapter to pause its debuggee.
function dap:halt() self:cmd("pause", { threadId = self.thread_id }) end
---Terminate an owned adapter session without notifying the model twice.
function dap:terminate()
  self.completed = true
  if self.running_program then self.running_program:terminate() end
end

---Select a displayed frame, mapping its zero-based row to the adapter's frame ID.
---@param index integer Zero-based stack row
---@param callback function? Completion callback
function dap:frame(index, callback)
  self.frame_id = self.frame_ids and self.frame_ids[index + 1] or nil
  if callback then callback() end
end

---Send the complete breakpoint set for one source, including an empty clear request.
---@param path string Source filename
function dap:refresh_breakpoints(path)
  local breakpoints = {}
  for line, enabled in pairs(self.breakpoints[path] or {}) do
    if enabled then breakpoints[#breakpoints + 1] = { line = line } end
  end
  table.sort(breakpoints, function(a, b) return a.line < b.line end)
  self:cmd("setBreakpoints", { source = { path = path }, breakpoints = breakpoints })
end

---Add a breakpoint to the adapter's source set.
---@param path string Source filename
---@param line integer Source line
---@param callback function? Completion callback
function dap:add_breakpoint(path, line, callback)
  self.breakpoints[path] = self.breakpoints[path] or {}
  self.breakpoints[path][line] = true
  self:refresh_breakpoints(path)
  if callback then callback() end
end

---Remove a breakpoint from the adapter's source set.
---@param path string Source filename
---@param line integer Source line
---@param callback function? Completion callback
function dap:remove_breakpoint(path, line, callback)
  if self.breakpoints[path] then self.breakpoints[path][line] = nil end
  self:refresh_breakpoints(path)
  if callback then callback() end
end

---Evaluate a watch expression in the selected stack frame.
---@param expression string Expression to evaluate
---@param callback fun(value:string?) Evaluation callback
function dap:variable(expression, callback)
  if self.frame_id == nil then
    self:stacktrace(function(frames)
      if #frames > 0 then self:variable(expression, callback) else callback(nil) end
    end)
    return
  end
  self:cmd("evaluate", { expression = expression, frameId = self.frame_id, context = "watch" }, function(body, err)
    callback(not err and body.result or nil)
  end)
end

dap.print = dap.variable

---Retrieve source frames and retain their adapter IDs for subsequent watch evaluation.
---@param callback fun(frames:table[]) Stack callback
function dap:stacktrace(callback)
  self:cmd("stackTrace", { threadId = self.thread_id }, function(body)
    local stack = {}
    self.frame_ids = {}
    for _, frame in ipairs(body.stackFrames or {}) do
      stack[#stack + 1] = { frame.name or "?", "", frame.source and frame.source.path, tonumber(frame.line) }
      self.frame_ids[#stack] = frame.id
    end
    self.frame_id = self.frame_ids[1]
    callback(stack)
  end)
end

---Return the last recorded source location when one is available.
---@param callback function Location callback
function dap:instruction(callback)
  if self.stack_frame then callback(table.unpack(self.stack_frame)) end
end

---Complete the session once on adapter termination or process failure.
function dap:finish()
  if self.completed then return end
  self.completed = true
  if self.debugger_completed then self.debugger_completed() end
end

---Handle all complete buffered responses/events and retain partial I/O.
---@return boolean running Whether the adapter loop should continue
function dap:loop()
  if self.completed then return false end
  local proc = self.running_program
  if self.pending_output ~= "" then
    local written, err = proc:write(self.pending_output)
    if written then self.pending_output = self.pending_output:sub(written + 1)
    elseif err ~= process.ERROR_WOULDBLOCK then core.error("DAP write failed: %s", tostring(err)); self:finish(); proc:terminate(); return false end
  end
  local chunk = proc:read_stdout()
  self.accumulator = self.accumulator .. (chunk or "")
  while true do
    local ok, message, remainder = pcall(self.parse_message, self.accumulator)
    if not ok then core.error("Invalid DAP response: %s", message); self:finish(); proc:terminate(); return false end
    if not message then break end
    self.accumulator = remainder
    if message.type == "response" and message.request_seq then
      local callback = self.command_queue[message.request_seq]
      self.command_queue[message.request_seq] = nil
      local err = message.success == false and (message.message or "Adapter request failed") or nil
      if err then core.error("DAP: %s", err) end
      if callback then callback(message.body or {}, err) end
      if self.completed then return false end
    elseif message.type == "event" then
      if message.event == "initialized" and not self.started then
        self.started = true
        self.debugger_started()
        self:cmd("configurationDone")
      elseif message.event == "stopped" then
        self.frame_id, self.frame_ids = nil, nil
        self.thread_id = message.body and message.body.threadId or self.thread_id
        self.debugger_stopped()
      elseif message.event == "terminated" or message.event == "exited" then
        self:finish()
        proc:terminate()
        return false
      elseif message.event == "output" and message.body and self.debugger_out then
        self.debugger_out(message.body.output or "", message.body.category or "stdout")
      end
    end
  end
  local err = proc:read_stderr()
  if err and err ~= "" and self.debugger_out then self.debugger_out(err, "stderr") end
  if chunk == nil and not proc:running() then self:finish(); return false end
  return true
end

---Launch a configured adapter and negotiate capabilities before launching the program.
---@param program string Executable path
---@param arguments string[]? Program arguments
---@param started function Configuration callback
---@param stopped function Pause callback
---@param completed function Completion callback
---@param out function? Output callback
function dap:start(program, arguments, started, stopped, completed, out)
  self.session = (self.session or 0) + 1
  local session = self.session
  self.command_queue, self.breakpoints, self.sequence = {}, {}, 0
  self.accumulator, self.pending_output = "", ""
  self.started, self.completed = false, false
  self.thread_id, self.frame_id, self.frame_ids, self.stack_frame = 1, nil, nil, nil
  self.debugger_started, self.debugger_stopped, self.debugger_completed, self.debugger_out = started, stopped, completed, out
  self.running_thread = core.add_thread(function()
    if self.session ~= session or self.completed then return end
    local settings = config.plugins.debugger
    local args = settings.dap_command or { settings.gdb_path or "gdb", "-q", "-nx", "--interpreter=dap" }
    local err
    self.running_program, err = process.start(args, { cwd = core.root_project().path, background = PLATFORM == "Windows" })
    if not self.running_program then core.error("Unable to start debug adapter: %s", tostring(err)); self:finish(); return end
    self:cmd("initialize", { clientID = "pragtical", clientName = "Pragtical", adapterID = "gdb",
      pathFormat = "path", linesStartAt1 = true, columnsStartAt1 = true }, function(_, initialize_error)
      if initialize_error then self.running_program:terminate(); self:finish(); return end
      local options = { program = core.root_project():absolute_path(program), cwd = core.root_project().path, stopOnEntry = true }
      if arguments and #arguments > 0 then options.args = arguments end
      self:cmd("launch", options, function(_, launch_error)
        if launch_error then self.running_program:terminate(); self:finish() end
      end)
    end)
    while self.session == session and self:loop() do coroutine.yield(settings.interval or 0.01) end
    if self.session == session then self.running_program, self.running_thread = nil, nil end
  end)
end

---Reject terminal attachment, which requires GDB's machine-interface stream.
function dap:attach() error("Terminal attachment is supported only by the GDB backend") end

return dap
