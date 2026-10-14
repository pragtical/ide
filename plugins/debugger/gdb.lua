local core = require "core"
local config = require "core.config"
local json = require "core.json"

---@class plugins.debugger.gdb
local gdb = { command_queue = {}, breakpoints = {}, sequence = 0 }

---Parse a machine-interface record, including nested lists and C string escapes.
---@param line string Complete output line
---@return table? record Token, kind, class, payload or stream text
function gdb.parse_record(line)
  local token, kind, body = line:match("^(%d*)([%^%*=%+~@&])(.*)$")
  if not kind then return nil end
  local index = 1
  local parse_value, parse_fields
  local function parse_string()
    assert(body:sub(index, index) == '"', "Expected a quoted MI string")
    index = index + 1
    local text = {}
    local escapes = { n = "\n", r = "\r", t = "\t", b = "\b", f = "\f", v = "\v", a = "\7" }
    while index <= #body do
      local char = body:sub(index, index)
      index = index + 1
      if char == '"' then return table.concat(text) end
      if char == "\\" then
        char = body:sub(index, index)
        index = index + 1
        if char:match("[0-7]") then
          local digits = char
          for _ = 1, 2 do
            local next_char = body:sub(index, index)
            if not next_char:match("[0-7]") then break end
            digits, index = digits .. next_char, index + 1
          end
          char = string.char(tonumber(digits, 8))
        else
          char = escapes[char] or char
        end
      end
      text[#text + 1] = char
    end
    error("Unclosed MI string")
  end
  parse_fields = function(closing, array)
    local result = {}
    while index <= #body and body:sub(index, index) ~= closing do
      local name = body:match("^([%w_%-]+)=", index)
      if name then
        index = index + #name + 1
        local value = parse_value()
        if array then result[#result + 1] = { [name] = value } else result[name] = value end
      else
        result[#result + 1] = parse_value()
      end
      if body:sub(index, index) ~= "," then break end
      index = index + 1
    end
    if closing then
      assert(body:sub(index, index) == closing, "Unclosed MI container")
      index = index + 1
    end
    return result
  end
  parse_value = function()
    local char = body:sub(index, index)
    if char == '"' then return parse_string() end
    if char == "{" or char == "[" then
      index = index + 1
      return parse_fields(char == "{" and "}" or "]", char == "[")
    end
    error("Invalid MI value at " .. index)
  end
  if kind == "~" or kind == "@" or kind == "&" then
    return { kind = kind, text = parse_string() }
  end
  local category = body:match("^([^,]+)")
  index = #category + 2
  return { token = tonumber(token), kind = kind, class = category, payload = parse_fields() }
end

---Queue an MI command; the editor scheduler resumes the process loop.
---@param command string Machine-interface command without a token
---@param callback fun(kind:string,category:string,payload:table)? Result callback
function gdb:cmd(command, callback)
  self.sequence = self.sequence + 1
  self.command_queue[#self.command_queue + 1] = { id = self.sequence, command = command, callback = callback }
end

---Select GDB by default for native executable debugging.
---@param path string Executable path
---@return boolean supported Always true
function gdb:should_engage(path) return true end

---Step into the next source statement.
---@param callback function? Completion callback
function gdb:step_into(callback) self:cmd("-exec-step", callback) end
---Step over the next source statement.
---@param callback function? Completion callback
function gdb:step_over(callback) self:cmd("-exec-next", callback) end
---Run until the current function returns.
---@param callback function? Completion callback
function gdb:step_out(callback) self:cmd("-exec-finish", callback) end
---Resume the inferior process.
---@param callback function? Completion callback
function gdb:continue(callback) self:cmd("-exec-continue", callback) end
---Interrupt the inferior without signaling the editor or terminal process.
---@param callback function? Completion callback
function gdb:halt(callback) self:cmd("-exec-interrupt --all", callback) end
---End the session and terminate an owned GDB process.
function gdb:terminate()
  self.completed = true
  if self.running_program then self.running_program:terminate() end
end
---Select a zero-based stack frame.
---@param index integer Stack frame level
---@param callback function? Completion callback
function gdb:frame(index, callback) self:cmd("-stack-select-frame " .. tostring(index), callback) end
---Skip a configured source-file glob while stepping.
---@param file string File glob
---@param callback function? Completion callback
function gdb:skip_file(file, callback)
  self:cmd("-interpreter-exec console " .. json.encode("skip -gfi " .. file), callback)
end

---Install a breakpoint and retain GDB's ID for later removal.
---@param path string Source filename
---@param line integer Source line
---@param callback function? Completion callback
function gdb:add_breakpoint(path, line, callback)
  self:cmd("-break-insert " .. json.encode(path .. ":" .. line), function(kind, category, payload)
    if payload.bkpt then self.breakpoints[path .. ":" .. line] = payload.bkpt.number end
    if callback then callback(kind, category, payload) end
  end)
end

---Remove a previously installed breakpoint.
---@param path string Source filename
---@param line integer Source line
---@param callback function? Completion callback
function gdb:remove_breakpoint(path, line, callback)
  local key = path .. ":" .. line
  local id = self.breakpoints[key]
  self.breakpoints[key] = nil
  if id then self:cmd("-break-delete " .. id, callback) elseif callback then callback() end
end

---Evaluate a debugger expression in the selected frame.
---@param expression string Expression to evaluate
---@param callback fun(value:string?) Evaluation result
function gdb:variable(expression, callback)
  self:cmd("-data-evaluate-expression " .. json.encode(expression), function(_, category, payload)
    callback(category == "done" and payload.value or nil)
  end)
end

gdb.print = gdb.variable

---Retrieve structured stack frames with absolute source paths when available.
---@param callback fun(frames:table[]) Stack frame callback
function gdb:stacktrace(callback)
  self:cmd("-stack-list-frames", function(_, _, payload)
    local stack = {}
    for _, entry in ipairs(payload.stack or {}) do
      local frame = entry.frame or entry
      stack[#stack + 1] = { frame.func or "?", "", frame.fullname or frame.file, tonumber(frame.line) }
    end
    callback(stack)
  end)
end

---Return the most recently stopped source location.
---@param callback function Source location callback
function gdb:instruction(callback)
  if self.stack_frame then callback(table.unpack(self.stack_frame)) end
end

---Complete a session once, including early process-start failures.
function gdb:finish()
  if self.completed then return end
  self.completed = true
  if self.debugger_completed then self.debugger_completed() end
end

---Drain complete MI records and write queued commands without losing partial I/O.
---@return boolean running Whether the process loop should continue
function gdb:loop()
  if self.completed then return false end
  local proc = self.running_program
  if not proc then return false end
  if proc.read_stderr then
    local err = proc:read_stderr()
    if err and err ~= "" and self.debugger_out then self.debugger_out(err, "stderr") end
  end
  local chunk = proc:read_stdout()
  self.saved_result = self.saved_result .. (chunk or "")
  while true do
    local newline = self.saved_result:find("\n", 1, true)
    if not newline then break end
    local line = self.saved_result:sub(1, newline - 1):gsub("\r$", "")
    self.saved_result = self.saved_result:sub(newline + 1)
    local ok, record = pcall(self.parse_record, line)
    if not ok then
      core.error("Invalid GDB response: %s", record)
    elseif record then
      if record.kind == "^" then
        local pending = self.pending
        if pending and record.token == pending.id then
          self.pending = nil
          if record.class == "error" then core.error("GDB: %s", record.payload.msg or "Command failed") end
          if pending.callback then pending.callback(record.kind, record.class, record.payload) end
          if self.completed then return false end
        end
      elseif record.kind == "*" and record.class == "stopped" then
        local data = record.payload
        if data.reason and data.reason:find("^exited") then
          self:finish()
          proc:terminate()
          return false
        end
        local frame = data.frame
        self.stack_frame = frame and { frame.fullname or frame.file, tonumber(frame.line), frame.func } or nil
        if not self.started then
          self.started = true
          self.debugger_started()
          self:continue()
        elseif self.debugger_stopped then self.debugger_stopped() end
      elseif (record.kind == "~" or record.kind == "@" or record.kind == "&") and self.debugger_out then
        self.debugger_out(record.text, record.kind == "&" and "stderr" or "stdout")
      end
    elseif line ~= "" and not line:find("^%(gdb%)") and self.debugger_out then
      self.debugger_out(line, "stdout")
    end
  end
  if not self.pending and #self.command_queue > 0 then
    self.pending = table.remove(self.command_queue, 1)
    self.pending.wire = self.pending.id .. self.pending.command .. "\n"
  end
  if self.pending and self.pending.wire ~= "" then
    local written, err = proc:write(self.pending.wire)
    if written then self.pending.wire = self.pending.wire:sub(written + 1)
    elseif err ~= process.ERROR_WOULDBLOCK then
      core.error("Unable to write to GDB: %s", tostring(err))
      self:finish()
      proc:terminate()
      return false
    end
  end
  if chunk == nil and proc.running and not proc:running() then self:finish(); return false end
  return true
end

---Start GDB and stop at its entrypoint before applying persistent breakpoints.
---@param program string Executable filename
---@param arguments string[]? Program arguments
---@param started function Initial-stop callback
---@param stopped function Later-stop callback
---@param completed function Session completion callback
---@param out function? Output callback
function gdb:start(program, arguments, started, stopped, completed, out)
  self.session = (self.session or 0) + 1
  local session = self.session
  self.command_queue, self.breakpoints, self.sequence = {}, {}, 0
  self.saved_result, self.pending, self.completed, self.started = "", nil, false, false
  self.stack_frame = nil
  self.debugger_started, self.debugger_stopped, self.debugger_completed, self.debugger_out = started, stopped, completed, out
  self.running_thread = core.add_thread(function()
    if self.session ~= session or self.completed then return end
    local settings = config.plugins.debugger
    local args = { settings.gdb_path or "gdb", "-q", "-nx", "--interpreter=mi3", "--args",
      core.root_project():absolute_path(program) }
    for _, argument in ipairs(arguments or {}) do args[#args + 1] = tostring(argument) end
    local err
    self.running_program, err = process.start(args, {
      cwd = core.root_project().path, background = PLATFORM == "Windows"
    })
    if not self.running_program then
      core.error("Unable to start GDB: %s", tostring(err))
      self:finish()
    else
      self:cmd("-gdb-set mi-async on")
      self:cmd("-gdb-set breakpoint pending on")
      self:cmd("-gdb-set filename-display absolute")
      local function launch_result(_, category)
        if category == "error" then self.running_program:terminate(); self:finish() end
      end
      self:cmd("-break-insert -t " .. (settings.entrypoint or "main"), launch_result)
      self:cmd("-exec-run", launch_result)
      while self.session == session and self:loop() do coroutine.yield(settings.interval or 0.01) end
    end
    if self.session == session then self.running_program, self.running_thread = nil, nil end
  end)
end

---Attach the model to an existing terminal exposing the process stream interface.
---@param terminal table Process-like terminal adapter
---@param started function Initial-stop callback
---@param stopped function Later-stop callback
---@param completed function Completion callback
---@param out function? Output callback
function gdb:attach(terminal, started, stopped, completed, out)
  self.session = (self.session or 0) + 1
  local session = self.session
  self.command_queue, self.breakpoints, self.sequence = {}, {}, 0
  self.saved_result, self.pending, self.completed, self.started = "", nil, false, false
  self.stack_frame = nil
  self.debugger_started, self.debugger_stopped, self.debugger_completed, self.debugger_out = started, stopped, completed, out
  self.running_program = terminal
  self:cmd("-gdb-set mi-async on")
  self:cmd("-break-insert -t main")
  self:cmd("-exec-run")
  self.running_thread = core.add_thread(function()
    if self.session ~= session or self.completed then return end
    while self.session == session and self:loop() do coroutine.yield(config.plugins.debugger.interval or 0.01) end
    if self.session == session then self.running_program, self.running_thread = nil, nil end
  end)
end

return gdb
