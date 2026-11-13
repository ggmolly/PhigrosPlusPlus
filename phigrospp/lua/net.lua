-- requests to phigros.tools through the game's UnityWebRequest, checked each frame. this unity has no SetRequestHeader,
-- so a signed request puts the player's public key, the signature and the time before its body

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

-- done(status, body) runs on the main thread, status is 0 when the server couldn't be reached. returns the
-- UnityWebRequest, to follow or abort it
function phigrospp.fetch(method, url, body, done)
  local request = Networking.UnityWebRequest(url, method)
  request.downloadHandler = Networking.DownloadHandlerBuffer()
  if body then request.uploadHandler = Networking.UploadHandlerRaw(il2cpp.bytes(body)) end
  request.timeout = 30
  request:SendWebRequest()
  pending[#pending + 1] = { request = request, done = done }
  return request
end

function phigrospp.request(method, path, body, done) phigrospp.fetch(method, HOST .. path, body, done) end

-- the server checks the signature of "<method> <path>\n<time><body>" and that the time (ms) only goes forward. a clock
-- that ran ahead once leaves the server a later time: it answers 409 with it, and the request goes again after it
local DOMAIN = "phigros.tools request v1\0" -- the key also signs replays, a signature is only good for one use
local stamp = 0

local function send(method, path, body, done, again)
  local identity = phigrospp.identity
  stamp = math.max(os.time() * 1000, stamp + 1)
  local message = string.pack("<i8", stamp) .. body
  local signature = identity.sign(DOMAIN .. ("%s %s\n"):format(method, path) .. message)
  phigrospp.request(method, path, identity.public() .. signature .. message, function(status, response)
    if status ~= 409 or again then return done(status, response) end
    stamp = math.max(stamp, math.tointeger(tonumber(response:match("\"last\":%s*(%d+)"))))
    send(method, path, body, done, true)
  end)
end

function phigrospp.signed(method, path, body, done) send(method, path, body, done) end

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

on("unload", function()
  for _, p in ipairs(pending) do p.request:Dispose() end
end)
