-- the player's key on phigros.tools: 16 random bytes made when they turn sync on, kept in the app's private folder
-- once they saved its words. they're hashed into an ed25519 key, and shown as 16 words (one per byte) to bring the key
-- to another device

local crypto = phigrospp.crypto
local PATH = phigrospp.private() .. "/phigros++.identity"
local SHARED = phigrospp.root .. "/identity" -- where it was kept before, readable by other apps up to android 10
local SIZE = 16
local WORDS, BYTE = {}, {} -- a byte's word, and the byte of a word's first 4 letters (unique to it)
for word in phigrospp.bundle["words.txt"]:gmatch("%l+") do
  assert(not BYTE[word:sub(1, 4)], "words.txt: two words start with " .. word:sub(1, 4))
  BYTE[word:sub(1, 4)] = #WORDS
  WORDS[#WORDS + 1] = word
end
assert(#WORDS == 256, "words.txt: one word per byte value, 256 of them")

local entropy, seed, public

-- an empty or cut file would give a key anyone can make, so it stops here and stays as it is for the player to see
local function use(bytes)
  assert(#bytes == SIZE, ("identity: %s holds %d bytes, a key is %d"):format(PATH, #bytes, SIZE))
  entropy = bytes
  seed = crypto.sha512("phigros++ identity" .. bytes):sub(1, 32)
  public = crypto.keypair(seed)
end

local function write(bytes)
  use(bytes)
  phigrospp.write(PATH, bytes)
end

local shared = io.open(SHARED, "rb")
if shared then
  shared:close()
  phigrospp.write(PATH, phigrospp.read(SHARED))
  os.remove(SHARED)
end

local found = io.open(PATH, "rb")
if found then
  found:close()
  use(phigrospp.read(PATH))
end

-- public() is nil until the player has a key
phigrospp.identity = {
  public = function() return public end,
  entropy = function() return entropy end,
  sign = function(message) return crypto.sign(seed, message) end,
  words = function()
    local list = {}
    for i = 1, #entropy do list[i] = WORDS[entropy:byte(i) + 1] end
    return list
  end,
  -- a new key, or the key of 16 bytes, only in memory until save()
  create = function() use(crypto.random(SIZE)) end,
  load = use,
  -- the 16 bytes of typed recovery words, read by their first 4 letters so a typo past them doesn't matter. nil and
  -- why when they aren't 16 words of the list
  fromWords = function(text)
    local bytes = {}
    for word in text:lower():gmatch("%a+") do
      local byte = BYTE[word:sub(1, 4)]
      if not byte then return nil, ("%q isn't one of the recovery words"):format(word) end
      bytes[#bytes + 1] = byte
    end
    if #bytes ~= SIZE then return nil, ("that's %d words, the phrase has %d"):format(#bytes, SIZE) end
    return string.char(table.unpack(bytes))
  end,
  save = function() phigrospp.write(PATH, entropy) end,
  replace = write,
  -- a key the player turned down is dropped, so the next try starts over
  forget = function()
    os.remove(PATH)
    entropy, seed, public = nil, nil, nil
  end,
}
