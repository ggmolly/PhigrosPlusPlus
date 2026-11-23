-- requests to phigros.tools through the game's UnityWebRequest, checked each frame. this unity has no SetRequestHeader,
-- so a signed request puts the player's public key, the signature and the time before its body. and WebSockets

local Networking = CS.UnityEngine.Networking
local HOST = "https://phigros.tools"
local pending = {}

phigrospp.site = HOST

-- json as the server sends it (null is nil), and flat objects of strings, numbers and booleans as it takes them
local ESCAPES = { b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }

-- the value starting at or after at, and where it ends
local function parse(json, at)
  at = assert(json:find("%S", at), "json: the answer ends early")
  local c = json:sub(at, at)
  if c == '"' then
    local parts, i = {}, at + 1
    while json:sub(i, i) ~= '"' do
      local ch = json:sub(i, i)
      assert(ch ~= "", "json: a string never ends") -- a cut answer would loop here forever
      if ch ~= "\\" then
        parts[#parts + 1], i = ch, i + 1
      elseif json:sub(i + 1, i + 1) == "u" then
        parts[#parts + 1], i = utf8.char(tonumber(json:sub(i + 2, i + 5), 16)), i + 6
      else
        parts[#parts + 1], i = ESCAPES[json:sub(i + 1, i + 1)] or json:sub(i + 1, i + 1), i + 2
      end
    end
    return table.concat(parts), i + 1
  end
  if c ~= "{" and c ~= "[" then
    local word, after = json:match("^([^,}%]%s]+)()", at)
    if word == "null" then return nil, after end
    return tonumber(word) or word == "true", after
  end
  local out, close, n = {}, c == "{" and "}" or "]", 0
  if json:match("^%s*(.)", at + 1) == close then return out, json:find(close, at + 1, true) + 1 end
  repeat
    local key
    n = n + 1
    if close == "}" then
      key, at = parse(json, at + 1)
      at = json:find(":", at, true)
    end
    out[key or n], at = parse(json, at + 1)
    at = json:find("%S", at)
  until json:sub(at, at) ~= ","
  assert(json:sub(at, at) == close, "json: a list never ends")
  return out, at + 1
end

phigrospp.json = {
  encode = function(object)
    local fields = {}
    for key, value in pairs(object) do
      local json = type(value) ~= "string" and tostring(value)
          or '"' .. value:gsub('[%c"\\]', function(c) return ("\\u%04x"):format(c:byte()) end) .. '"'
      fields[#fields + 1] = ("%q:%s"):format(key, json)
    end
    return "{" .. table.concat(fields, ",") .. "}"
  end,
  decode = function(json) return (parse(json, 1)) end,
}

-- done(status, body) runs on the main thread, status is 0 when the server couldn't be reached. timeout is in seconds
-- (30 when not given, 0 for none, for big files). returns the UnityWebRequest, to follow or abort it
function phigrospp.fetch(method, url, body, done, timeout)
  local request = Networking.UnityWebRequest(url, method)
  request.downloadHandler = Networking.DownloadHandlerBuffer()
  if body then request.uploadHandler = Networking.UploadHandlerRaw(il2cpp.bytes(body)) end
  request.timeout = timeout or 30
  request:SendWebRequest()
  pending[#pending + 1] = { request = request, done = done }
  return request
end

function phigrospp.request(method, path, body, done) phigrospp.fetch(method, HOST .. path, body, done) end

-- the server checks the signature of "<method> <path>\n<time><body>" and that the time (ms) only goes forward. a clock
-- that ran ahead once leaves the server a later time: it answers 409 with it, and the request goes again after it.
-- requests go one at a time, so they reach the server in the order of their times
local DOMAIN = "phigros.tools request v1\0" -- the key also signs replays, a signature is only good for one use
local stamp = 0
local queue = {}

local function send(method, path, body, done, again)
  local identity = phigrospp.identity
  stamp = math.max(os.time() * 1000, stamp + 1)
  local message = string.pack("<i8", stamp) .. body
  local signature = identity.sign(DOMAIN .. ("%s %s\n"):format(method, path) .. message)
  phigrospp.request(method, path, identity.public() .. signature .. message, function(status, response)
    if status == 409 and not again then
      stamp = math.max(stamp, math.tointeger(tonumber(response:match("\"last\":%s*(%d+)"))))
      return send(method, path, body, done, true)
    end
    table.remove(queue, 1)
    if queue[1] then send(table.unpack(queue[1])) end
    done(status, response)
  end)
end

function phigrospp.signed(method, path, body, done)
  queue[#queue + 1] = { method, path, body, done }
  if #queue == 1 then send(method, path, body, done) end
end

on("update", function()
  for i = #pending, 1, -1 do
    local request, done = pending[i].request, pending[i].done
    if request.isDone then
      table.remove(pending, i)
      local data = request.downloadHandler.data
      local status, body = request.responseCode, data and il2cpp.unbytes(data) or ""
      request:Dispose()
      local ok, err = xpcall(done, debug.traceback, status, body)
      if not ok then print("request failed: " .. err) end
    end
  end
end)

-- sockets: a WebSocket of .NET's, which works on tasks. each is checked every frame, with one send and one receive
-- going at a time
local WebSockets = CS.System.Net.WebSockets
local CHUNK = 8192 -- bytes read at once, a longer message comes in parts
local NEVER = {} -- a CancellationToken that never cancels
local sockets = {}

-- a text WebSocket to a url: handlers.open(), handlers.message(text) and handlers.close() (it ended, or couldn't be
-- made) run on the main thread. returns { send = function(text), close = function() }, a closed one tells nothing
function phigrospp.socket(url, handlers)
  local s = { ws = WebSockets.ClientWebSocket(), handlers = handlers, queue = {}, parts = {},
    buffer = il2cpp.bytes(("\0"):rep(CHUNK)) }
  s.connecting = s.ws:ConnectAsync(CS.System.Uri(url), NEVER)
  sockets[#sockets + 1] = s
  return {
    send = function(text) s.queue[#s.queue + 1] = text end,
    close = function()
      s.closed = true
      s.ws:Abort()
    end,
  }
end

-- nil while a task runs, then whether it went well
local function done(task)
  if task.IsCompleted then return not task.IsFaulted and not task.IsCanceled end
end

local function tell(s, event, ...)
  local ok, err = xpcall(s.handlers[event], debug.traceback, ...)
  if not ok then print(("socket %s failed: %s"):format(event, err)) end
end

local function drop(s)
  s.closed = true
  s.ws:Abort()
  tell(s, "close")
end

local function receive(s) return s.ws:ReceiveAsync({ s.buffer, 0, CHUNK }, NEVER) end

local function poll(s)
  if s.connecting then
    local ok = done(s.connecting)
    if ok == nil then return end
    if not ok then return drop(s) end
    s.connecting, s.receiving = nil, receive(s)
    tell(s, "open")
    if s.closed then return end
  end
  if s.sending and done(s.sending) ~= nil then s.sending = nil end -- a failed one fails the receive too
  -- a socket the server closed refuses to send, its receive says so next
  if not s.sending and s.queue[1] and s.ws.State == 2 then -- Open
    local bytes = il2cpp.bytes(table.remove(s.queue, 1))
    s.sending = s.ws:SendAsync({ bytes, 0, #bytes }, 0, true, NEVER) -- Text, the whole message
  end
  local ok = done(s.receiving)
  while ok do
    local result = s.receiving.m_result
    if result.MessageType == 2 then return drop(s) end -- Close
    s.parts[#s.parts + 1] = il2cpp.unbytes(s.buffer):sub(1, result.Count)
    if result.EndOfMessage then
      local text = table.concat(s.parts)
      s.parts = {}
      tell(s, "message", text)
      if s.closed then return end -- by what heard it
    end
    s.receiving = receive(s)
    ok = done(s.receiving)
  end
  if ok == false then drop(s) end
end

on("update", function()
  for i = #sockets, 1, -1 do
    if sockets[i].closed then table.remove(sockets, i) else poll(sockets[i]) end
  end
end)

-- a socket of phigros.tools that knows who this is (rooms, friends), carrying json objects named by their t: the
-- server greets with a nonce, signed with the profile's key after `domain` so the signature is good for nothing else.
-- heard[t](message) runs for what it says next ("welcome" first), closed() once it ended. send takes a table
function phigrospp.channel(path, domain, heard, closed)
  local socket
  socket = phigrospp.socket(HOST:gsub("^http", "ws", 1) .. path, {
    open = function() end,
    message = function(text)
      local m = phigrospp.json.decode(text)
      if m.t ~= "hello" then return heard[m.t](m) end
      local identity = phigrospp.identity
      socket.send({ t = "auth", key = phigrospp.hex(identity.public()),
        sig = phigrospp.hex(identity.sign(domain .. m.nonce)) })
    end,
    close = closed,
  })
  local text = socket.send
  socket.send = function(message) text(phigrospp.json.encode(message)) end
  return socket
end

on("unload", function()
  for _, p in ipairs(pending) do p.request:Dispose() end
  for _, s in ipairs(sockets) do s.ws:Abort() end
end)
