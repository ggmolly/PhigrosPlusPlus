-- the replay file: a header with the play's result, then every frame coded losslessly as residuals against predictions
-- the decoder repeats, through an adaptive binary range coder (like ../../chart-codec, the web player's chart codec).
-- 132 s of play are about 46 kB, 7.5 times less than the plain floats. it's kept unsigned: sent to phigros.tools, the
-- player's public key and an ed25519 signature of everything before them end it (sign)
--
-- frame: { t = song time, dt = delta time, touches = { { id =, phase =, x =, y = } }, and what the game's other clocks
-- said: udt = unscaled delta time, scale = time scale, real = realtime since startup, music = the music's time (all
-- f32), mono = the system's monotonic clock and dsp = the audio clock (integer µs), focus = whether the game had focus }
-- positions are on the 1/1024 pixel grid Unity reports them on
-- event: { kind = "pause" or "resume", frame = frames recorded before it, mono = when }, nothing is recorded in a pause

local MAGIC, VERSION = "PIGEON", 4
local DOMAIN = "phigros++ replay v4\0" -- what the signature is of, before the file's bytes
-- the header, in order: the chart, the screen it was played on, when, the result (the picker reads only this), then
-- what it was played with: the game (its update count), phigros++, the device, its android version and refresh rate,
-- the target frame rate, the song's offset in seconds, every mods/ and core/ file with the start of its sha-512, and
-- what the game's judgement depends on: the screen's dpi (flicks), mirror mode and challenge mode (1 when on)
local FIELDS = {
  { "version", "B" }, { "id", "s1" }, { "difficulty", "s1" }, { "width", "I2" }, { "height", "I2" }, { "date", "i8" },
  { "score", "i4" }, { "accuracy", "f" }, { "maxcombo", "I2" }, { "perfect", "I2" }, { "good", "I2" },
  { "bad", "I2" }, { "miss", "I2" }, { "early", "I2" }, { "late", "I2" }, { "duration", "f" },
  { "game", "I4" }, { "phigrospp", "s1" }, { "device", "s1" }, { "android", "s1" }, { "refresh", "d" },
  { "fps", "i2" }, { "offset", "f" }, { "files", "s2" }, { "dpi", "f" }, { "mirror", "B" }, { "challenge", "B" },
}
local EVENTS = { "pause", "resume" }
local HEADER = "<c6"
for _, field in ipairs(FIELDS) do HEADER = HEADER .. field[2] end
local BITS, LIMIT, MANT = 15, 30, 4 -- probability precision, slowest adaptation 1/32, adaptive bits under the top one
local ONE, TOP, MASK = 1 << BITS, 1 << 24, 0xFFFFFFFF
local ENDED, CANCELED = 3, 4 -- TouchPhase

local function f32(x) return (string.unpack("<f", string.pack("<f", x))) end

-- f32 <-> an integer ordered like the float, so a residual is the number of floats between two values
local function ordf(x)
  local bits = string.unpack("<I4", string.pack("<f", x))
  return bits < 0x80000000 and bits or -1 - (bits - 0x80000000)
end

local function unordf(o)
  return (string.unpack("<f", string.pack("<I4", o >= 0 and o or -1 - o + 0x80000000)))
end

local function bucket(v, cap) -- bit length of |v|, at most cap
  local n, a = 0, v < 0 and -v or v
  while a > 0 and n < cap do n, a = n + 1, a >> 1 end
  return n
end

local function signed(v, cap) return v < 0 and -bucket(v, cap) or bucket(v, cap) end

local function near(v, cap) return math.max(-cap, math.min(cap, v)) end

-- touch panels report on a grid coarser than Unity's (1/10 pixel on the tablet): a position is its step on that
-- grid and what is left, which is 0 for a raw position and anything for one Android interpolated
local function split(v)
  local n = (v * 10 + 512) // 1024
  return n, v - (n * 1024 + 5) // 10
end

local function join(n, rest) return (n * 1024 + 5) // 10 + rest end

-- one coder for both directions: encoding takes values and returns them, decoding ignores them and returns the
-- decoded ones, so a single function describes the format
local Coder = {}
Coder.__index = Coder

local function coder(data)
  local c = setmetatable({ contexts = {}, range = MASK, low = 0, decoding = data ~= nil }, Coder)
  if data then
    c.data, c.pos, c.code = data, 1, 0
    for _ = 1, 5 do c.code = ((c.code << 8) | c:byte()) & MASK end
  else
    c.out, c.cache, c.pending = {}, 0, 1
  end
  return c
end

function Coder:byte()
  local b = self.data:byte(self.pos) or 0
  self.pos = self.pos + 1
  return b
end

-- LZMA's carry handling: a byte is held until no carry can reach it
function Coder:shift()
  if self.low < 0xFF000000 or self.low > MASK then
    local carry, byte = self.low >> 32, self.cache
    repeat
      self.out[#self.out + 1] = string.char((byte + carry) & 0xFF)
      byte, self.pending = 0xFF, self.pending - 1
    until self.pending == 0
    self.cache = (self.low >> 24) & 0xFF
  end
  self.pending = self.pending + 1
  self.low = (self.low << 8) & MASK
end

function Coder:normalize()
  while self.range < TOP do
    self.range = (self.range << 8) & MASK
    if self.decoding then self.code = ((self.code << 8) | self:byte()) & MASK else self:shift() end
  end
end

-- one bit with the adaptive probability of a 0, kept in probs[i] above the count of bits seen: the n-th bit moves
-- it by 1/(n + 2), so a context learns fast then settles
function Coder:bit(probs, i, b)
  local state = probs[i] or ONE << 4
  local p, n = state >> 5, state & 31
  local bound = (self.range >> BITS) * p
  if self.decoding then b = self.code < bound and 0 or 1 end
  if b == 0 then
    self.range, p = bound, p + (ONE - p) // (n + 2)
  else
    if self.decoding then self.code = self.code - bound else self.low = self.low + bound end
    self.range, p = self.range - bound, p - p // (n + 2)
  end
  probs[i] = p << 5 | math.min(n + 1, LIMIT)
  self:normalize()
  return b
end

-- n bits at even odds
function Coder:raw(n, v)
  local r = 0
  for i = n - 1, 0, -1 do
    self.range = self.range >> 1
    local b
    if self.decoding then
      b = self.code >= self.range and 1 or 0
      if b == 1 then self.code = self.code - self.range end
    else
      b = (v >> i) & 1
      if b == 1 then self.low = self.low + self.range end
    end
    r = (r << 1) | b
    self:normalize()
  end
  return r
end

-- a signed integer in a named context: its bit length through a 6 level tree, a sign, MANT adaptive bits under the
-- leading one, the rest raw
function Coder:int(name, v)
  local probs = self.contexts[name]
  if not probs then
    probs = {}
    self.contexts[name] = probs
  end
  local a = not self.decoding and (v < 0 and -v or v) or 0
  local n = bucket(a, 63)
  local node = 1
  for i = 5, 0, -1 do node = node * 2 + self:bit(probs, node, (n >> i) & 1) end
  n = node - 64
  if n == 0 then return 0 end
  local negative = self:bit(probs, 64, not self.decoding and v < 0 and 1 or 0)
  local below, m = n - 1, 1
  local adaptive = math.min(MANT, below)
  for i = 1, adaptive do m = m * 2 + self:bit(probs, 100 + n * 32 + m, (a >> (below - i)) & 1) end
  local rest = below - adaptive
  if rest > 0 then m = (m << rest) | self:raw(rest, a & ((1 << rest) - 1)) end
  return negative == 1 and -m or m
end

function Coder:finish()
  for _ = 1, 5 do self:shift() end
  return table.concat(self.out)
end

local FRAME = ordf(f32(1 / 120))

local function us(seconds) return math.floor(seconds * 1e6 + 0.5) end

-- a f32 coded as the floats between it and a prediction
local function float(c, name, predicted, v)
  return unordf(ordf(predicted) + c:int(name, v and ordf(v) - ordf(predicted)))
end

-- the clocks besides the song's: each predicted from the frame's delta time or another clock, so a game running at
-- the wrong speed shows as residuals that keep growing
local function clocks(c, frame, last, dt, t, offset)
  local now = {}
  now.udt = float(c, "udt", dt, frame and frame.udt)
  now.scale = float(c, "scale", last.scale, frame and frame.scale)
  now.mono = last.mono + us(now.udt) + c:int("mono", frame and frame.mono - last.mono - us(now.udt))
  now.real = float(c, "real", f32(last.real + (now.mono - last.mono) / 1e6), frame and frame.real)
  -- the audio clock moves in steps of a buffer
  now.dspStep = c:int("dsp" .. bucket(last.dspStep, 20), frame and frame.dsp - last.dsp)
  now.dsp = last.dsp + now.dspStep
  now.music = float(c, "music", f32(t + offset), frame and frame.music)
  now.focus = c:bit(c.contexts, "focus" .. last.focus, frame and (frame.focus and 1 or 0))
  return now
end

-- the format: codes `frames` and `events` when encoding, rebuilds them when decoding
local function frames(c, list, events, offset)
  local decoding = c.decoding
  local n = c:int("count", list and #list)
  local out = {}
  local t1, rdt, fix, fix2 = 0.0, 0, 0, 0 -- the last song time, delta time residual and two clock corrections
  local clock = { scale = 1.0, mono = 0, real = 0.0, dsp = 0, dspStep = 0, focus = 1 } -- the last clocks
  local fingers = {} -- last frame's touches: id, phase, grid steps nx ny, rests rx ry, last move vx vy, moves
  for k = 1, n do
    local frame = list and list[k]
    -- delta times sit within nanoseconds of 1/120 s, a long one follows a short one
    rdt = c:int("dt" .. near(rdt // 8, 6), frame and ordf(frame.dt) - FRAME)
    local dt = unordf(FRAME + rdt)
    -- the song time is the last one plus the delta time, plus the correction the game's music clock makes, which
    -- changes slowly
    local step = ordf(f32(t1 + dt))
    fix2, fix = fix, fix + c:int("t" .. signed(fix, 3) .. "." .. signed(fix - fix2, 3),
      frame and ordf(frame.t) - step - fix)
    local t = unordf(step + fix)

    local alive, used = {}, {}
    for _, f in ipairs(fingers) do
      if f.phase ~= ENDED and f.phase ~= CANCELED then
        alive[#alive + 1] = f
        used[f.id] = true
      end
    end
    -- continuing fingers come first and in order nearly always, then the new ones. otherwise ids are listed
    local touches = frame and frame.touches
    local regular = 1
    if touches then
      for i, f in ipairs(alive) do
        if not touches[i] or touches[i].id ~= f.id then regular = 0 end
      end
    end
    local order = {}
    if c:bit(c.contexts, "regular", regular) == 1 then
      for i, f in ipairs(alive) do order[i] = f end
      for _ = 1, c:int("new", touches and #touches - #alive) do order[#order + 1] = false end
    else
      local byId = {}
      for _, f in ipairs(alive) do byId[f.id] = f end
      for i = 1, c:int("listed", touches and #touches) do
        local id = c:int("id", touches and touches[i].id)
        order[i] = byId[id] or { id = id }
      end
    end

    local now, decoded = {}, {}
    for i, last in ipairs(order) do
      local touch = touches and touches[i]
      local tx = touch and math.tointeger(touch.x * 1024)
      local ty = touch and math.tointeger(touch.y * 1024)
      assert(not touch or tx and ty, "replay: a touch position isn't on the 1/1024 pixel grid")
      local nx, rx, ny, ry
      if touch then
        nx, rx = split(tx)
        ny, ry = split(ty)
      end
      local f
      if last and last.nx then
        -- a finger seen last frame: its phase and whether it moved, both after its last two frames
        local phase = c:int("phase" .. last.phase .. last.moves, touch and touch.phase)
        local moved = c:bit(c.contexts, "moved" .. phase .. last.moves, touch and
          ((nx ~= last.nx or rx ~= last.rx or ny ~= last.ny or ry ~= last.ry) and 1 or 0))
        f = { id = last.id, phase = phase, nx = last.nx, rx = last.rx, ny = last.ny, ry = last.ry, vx = last.vx,
          vy = last.vy, moves = (last.moves << 1 | moved) & 3 }
        if moved == 1 then
          -- fingers keep their speed: the move is coded after the last one, the y one in the context of the x one.
          -- a slow move leaves about the same rest every time
          f.vx = last.vx + c:int("dx" .. phase, touch and nx - last.nx - last.vx)
          f.vy = last.vy + c:int("dy" .. phase .. "." .. bucket(f.vx - last.vx, 8), touch and ny - last.ny - last.vy)
          f.nx, f.ny = last.nx + f.vx, last.ny + f.vy
          f.rx = c:int("rx" .. near(f.vx, 2) .. (last.rx == 0 and "=" or ""), rx)
          f.ry = c:int("ry" .. near(f.vy, 2) .. (f.rx == 0 and "=" or ""), ry)
        end
      else
        -- a new finger: its id after the smallest free one, then where it is
        local id = last and last.id
        if not id then
          local free = 0
          while used[free] do free = free + 1 end
          id = free + c:int("newid", touch and touch.id - free)
        end
        f = { id = id, phase = c:int("phase", touch and touch.phase), vx = 0, vy = 0, moves = 0 }
        f.nx, f.ny, f.rx = c:int("x", nx), c:int("y", ny), c:int("rx", rx)
        f.ry = c:int("ry" .. (f.rx == 0 and "=" or ""), ry)
      end
      used[f.id] = true
      now[i] = f
      if decoding then
        decoded[i] = { id = f.id, phase = f.phase, x = join(f.nx, f.rx) / 1024, y = join(f.ny, f.ry) / 1024 }
      end
    end
    fingers = now
    clock = clocks(c, frame, clock, dt, t, offset)
    if decoding then
      out[k] = { t = t, dt = dt, touches = decoded, udt = clock.udt, scale = clock.scale, mono = clock.mono,
        real = clock.real, dsp = clock.dsp, music = clock.music, focus = clock.focus == 1 }
    end
    t1 = t
  end

  -- events after the last one, at a time after their frame's
  local happened, at, mono = {}, 0, 0
  for k = 1, c:int("events", events and #events) do
    local event = events and events[k]
    local kind = EVENTS[c:int("kind", event and (event.kind == "pause" and 1 or 2))]
    at = at + c:int("at", event and event.frame - at)
    local base = at > 0 and (out[at] or list[at]).mono or mono
    mono = base + c:int("when", event and event.mono - base)
    happened[k] = { kind = kind, frame = at, mono = mono }
  end
  return out, happened
end

-- the header as a table of FIELDS, and where the frames start
local function header(data)
  local values = table.pack(HEADER:unpack(data))
  assert(values[1] == MAGIC and values[2] == VERSION, "replay: not a Phigros++ replay of this version")
  local h = {}
  for i, field in ipairs(FIELDS) do h[field[1]] = values[i + 1] end
  return h, values[#FIELDS + 2]
end

phigrospp.replayfile = {
  -- whether the data is a replay this version reads
  current = function(data) return data:sub(1, #MAGIC) == MAGIC and data:byte(#MAGIC + 1) == VERSION end,
  header = function(data) return (header(data)) end,
  encode = function(h, list, events)
    local values = {}
    for i, field in ipairs(FIELDS) do values[i] = h[field[1]] end
    values[1] = VERSION
    local c = coder()
    frames(c, list, events, f32(h.offset)) -- the offset the decoder reads back from the header
    return HEADER:pack(MAGIC, table.unpack(values, 1, #FIELDS)) .. c:finish()
  end,
  -- the replay as it's uploaded, signed with the player's key
  sign = function(data)
    local identity = phigrospp.identity
    return data .. identity.public() .. identity.sign(DOMAIN .. data)
  end,
  -- the header, frames and events
  decode = function(data)
    local h, pos = header(data)
    return h, frames(coder(data:sub(pos)), nil, nil, h.offset)
  end,
}
