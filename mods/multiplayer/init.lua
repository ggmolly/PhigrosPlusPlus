-- rooms: players in a room play the chart its host picks at the same time, and see each other's scores. a tab on the
-- chapter screen lists the open rooms of phigros.tools, which carries them over a socket (its server/rooms.ts says
-- what goes through it) and keeps the matches of the rooms without a password. a play in a room counts like any other

local UE = CS.UnityEngine
local ui, json, M = phigrospp.ui, phigrospp.json, phigrospp.modifiers
local DOMAIN = "phigros.tools rooms v1\0" -- the profile's key signs requests and replays too
local MENUS = { ChapterSelector = true, SongSelector = true } -- where the room shows
local LEVELS = { EZ = true, HD = true, IN = true, AT = true }
local RETRY, TRIES = 3, 10 -- seconds before a dropped connection is made again, and how many times
local LOST = 20 -- seconds a match may take to reach its song
local KEPT = 100 -- the chat lines kept, the oldest go first
local NO_PROFILE = { "Rooms need a phigros.tools profile",
  "Turn on Sync to phigros.tools in the settings' Profile page, then come back." }
local UNREACHABLE = { "Couldn't reach phigros.tools", "Check your connection and try again." }
-- why the server refused, a wrong password aside
local ERRORS = {
  ["no-profile"] = NO_PROFILE,
  auth = { "phigros.tools doesn't know this device", "Sign in to your profile again in the settings' Profile page." },
  gone = { "This room is closed", "Its last player left it." },
  full = { "This room is full", "A room takes 8 players." },
  kicked = { "The host removed you from this room", "You can't join it again." },
  rooms = { "No room is free", "Too many rooms are open on phigros.tools, try again later." },
  elsewhere = { "You joined from another device", "This one left the room." },
}

local scores = setting("Show the room's scores while playing", true)

-- me: the player phigros.tools knows this device as, room: the room as the server last sent it, chat: what was said
-- since joining ({ name =, text = }), picking: its host is away from its screen to pick a chart
local mp = { chat = {} }
local screen
local socket, online, unsent, tries = nil, false, {}, 0 -- online: the server knows who this is
local entering -- the id of the room being joined (it may ask a password), true while one is made
local checked -- the chart this game last said it has or not
local match -- the match being played: { at =, started =, done =, sent = the score last sent }
local dialogs = {} -- what waits for a menu to show its popup

-- a function showing dialogs runs once a menu can show the game's popup, after the ones before it
local function ask(fn) dialogs[#dialogs + 1] = fn end

local function say(why)
  ask(function() ui.confirm({ title = why[1], message = why[2], yes = "OK", no = false }) end)
end

-- what waits for the connection goes once the server knows who this is
local function send(message)
  if online then return socket.send(json.encode(message)) end
  unsent[#unsent + 1] = message
end

local function hang()
  if socket then socket.close() end
  socket, online, unsent, tries = nil, false, {}, 0
end

local heard = {} -- what the server says, by its t

local function connect()
  if socket then return end
  socket = phigrospp.socket(phigrospp.site:gsub("^http", "ws") .. "/api/room", {
    open = function() end,
    message = function(text)
      local m = json.decode(text)
      heard[m.t](m)
    end,
    -- the server keeps a player's place for a while: the connection is made again, a few times
    close = function()
      socket, online, tries = nil, false, tries + 1
      if mp.room and tries <= TRIES then return after(RETRY, connect) end
      entering = nil
      say(UNREACHABLE)
      heard.room({})
    end,
  })
end

-- makes or joins a room, which takes a profile
local function enter(message)
  if not phigrospp.tag() then return say(NO_PROFILE) end
  entering = message.room or true
  send(message)
  connect()
end

local function join(id, password) enter({ t = "join", room = id, password = password or "" }) end

function heard.hello(m)
  local identity = phigrospp.identity
  socket.send(json.encode({ t = "auth", key = phigrospp.hex(identity.public()),
    sig = phigrospp.hex(identity.sign(DOMAIN .. m.nonce)) }))
end

function heard.welcome(m)
  mp.me, online, tries = m.player, true, 0
  local waiting = unsent
  unsent = {}
  for _, message in ipairs(waiting) do send(message) end
end

-- the room as it is now, none once out of it
function heard.room(m)
  local room, was = m.room, mp.room
  mp.room = room
  if not room then
    mp.chat, mp.picking, checked, match = {}, false, nil, nil
    if not entering then hang() end
    return screen.refresh()
  end
  if not was or was.id ~= room.id then mp.chat, checked, entering = {}, nil, nil end
  -- each game says whether it has a chart, once
  local chart = room.chart
  local key = chart and chart.id .. " " .. chart.level
  if key ~= checked then
    checked = key
    if chart and not phigrospp.unlocked(chart.id, chart.level) then send({ t = "able", able = false }) end
  end
  screen.refresh()
end

function heard.start(m)
  local chart = mp.room.chart
  match, mp.picking = { at = now(), sent = -1 }, false
  screen.refresh()
  phigrospp.play(chart.id, chart.level, chart.mods, m.seed)
end

function heard.chat(m)
  local name = m.player
  for _, p in ipairs(mp.room.players) do
    if p.player.id == m.player then name = p.player.name end
  end
  mp.chat[#mp.chat + 1] = { name = name, text = m.text }
  if #mp.chat > KEPT then table.remove(mp.chat, 1) end
  screen.refresh()
end

function heard.error(m)
  if m.code ~= "password" then
    entering = nil
    say(ERRORS[m.code])
    -- out of the room on this device, or never in one
    if m.code == "elsewhere" or not mp.room then heard.room({}) end
    return
  end
  local id = entering
  ask(function()
    local ok, typed = ui.confirm({ title = "This room has a password", input = "Password", yes = "Join" })
    if ok then return join(id, typed) end
    entering = nil
    if not mp.room then hang() end
  end)
end

-- the song list's Play picks the room's chart instead of starting it, until the room starts it for everyone. what
-- called it then marks the song list as starting (onStart), which is taken back once it returned
hook(CS.SongSelector, "GameStart", {
  skip = function(selector, index, level)
    if not mp.room or match then return false end
    after(0, function() selector.onStart = false end)
    local info = selector.SongItems._items[index].songInfo
    local difficulty = level < #info.levels and info.levels[level]
    mp.picking = false
    if mp.room.host ~= mp.me.id then
      screen.refresh()
      return true
    end
    if phigrospp.charts.custom(info.songsId) or not LEVELS[difficulty] then
      say({ "This chart can't be played in a room", "Rooms play the game's own EZ, HD, IN and AT charts." })
      mp.picking = true
      return true
    end
    send({ t = "chart", song = info.songsId, level = difficulty,
      mods = M.fits(info.songsId, difficulty) and M.pick() or 0 })
    screen.refresh()
    return true
  end,
})

-- the song: the score goes to the room as it's played, the result at its end -------------------------------------

local board -- the room's scores over the song: its texts, best first

local function ranked()
  local list, mine = {}, stats()
  for _, p in ipairs(mp.room.players) do
    local own = p.player.id == mp.me.id
    if p.playing or p.score > 0 or own then
      list[#list + 1] = { name = p.player.name, score = own and mine and not match.done and mine.score or p.score, own = own }
    end
  end
  table.sort(list, function(a, b) return a.score > b.score end)
  return list
end

-- a song started again from the result screen is the player's own
on("song", function()
  if not match or match.done then return end
  match.started, board = true, nil
  phigrospp.pausing(false) -- the others wait on this play
  if not scores() then return end
  local u = UE.Screen.height / 1080
  local canvas = ui.overlay("phigrospp-room-scores", 32000).transform
  local font = UE.Object.FindObjectOfType(CS.ScoreControl).score.font
  board = {}
  for i = 1, 8 do
    board[i] = ui.text(canvas, "phigrospp-room-score", font, { 36 * u, (700 - i * 44) * u }, { 0, 0 }, 28 * u, 3) -- MiddleLeft
    board[i].supportRichText = false
  end
end)

every(0.5, function()
  if not match then return end
  if not match.started and now() - match.at > LOST then
    send({ t = "quit" })
    match = nil
    return screen.refresh()
  end
  if not playing() or not mp.room then return end
  local s = stats()
  -- a score the connection can't take now is dropped, the next one says more
  if online and not match.done and s.score ~= match.sent then
    match.sent = s.score
    send({ t = "score", score = s.score, accuracy = s.accuracy, combo = s.combo })
  end
  if not board or not il2cpp.alive(board[1]) then return end
  local list = ranked()
  for i, row in ipairs(board) do
    local p = list[i]
    row.text = p and ("%d  %07d  %s"):format(i, p.score, p.name) or ""
    row.color = { 1, 1, 1, p and p.own and 1 or 0.6 }
  end
end)

on("finish", function(result)
  if not match or match.done then return end
  match.done = true
  send({ t = "result", score = result.score, accuracy = result.accuracy, maxcombo = result.maxcombo,
    perfect = result.perfect, good = result.good, bad = result.bad, miss = result.miss })
end)

-- back in a menu, the match is over for this player: one who left the song before its end gave up
on("scene", function(name)
  if match and match.started and MENUS[name] then
    if not match.done then send({ t = "quit" }) end
    match = nil
  end
  screen.refresh()
end)

-- a link to a room (phigrospp://room/<id>) joins it
on("link", function(url)
  local id = url:match("^phigrospp://room/(%w+)")
  if id then join(id:upper()) end
end)

-- a dialog waits for the game's loading screen to go. the song list reads the touches itself, so it's off under one
on("update", function()
  if #dialogs == 0 or not MENUS[scene()] or il2cpp.alive(ui.dialog) or CS.Loading.IsActive then return end
  coroutine.wrap(function(dialog)
    local selector = scene() == "SongSelector" and not ui.paging() and UE.Object.FindObjectOfType(CS.SongSelector)
    if selector then selector.enabled = false end
    dialog()
    screen.refresh()
  end)(table.remove(dialogs, 1))
end)

-- shown: whether the room's screen has its place, in a menu while no match is played
screen = require("screen")(mp, { send = send, enter = enter, join = join,
  shown = function() return MENUS[scene()] and not match end })

on("scene", function(name)
  if name == "ChapterSelector" then ui.shortcut("users", screen.open) end
end)
