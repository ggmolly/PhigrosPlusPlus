-- friends: players of phigros.tools who see each other online and what they play, watch each other's plays live and
-- invite each other into their room. the game keeps one socket to phigros.tools while it runs (its server/friends.ts
-- says what goes through it). their screen (screen.lua) goes with the rooms': the chapter screen's tab opens both, and
-- so does the avatar at the top right of the song list

local UE = CS.UnityEngine
local ui = phigrospp.ui
local DOMAIN = "phigros.tools friends v1\0" -- the profile's key signs requests, replays and rooms too
local MENUS = { ChapterSelector = true, SongSelector = true } -- where the screen shows
local RETRY, SLOWEST = 5, 60 -- seconds before a dropped connection is made again, twice as long each time
-- why the server refused a friend
local ERRORS = {
  unknown = { "No player has this name and number", "Ask your friend for both: they show on the Profile page of "
    .. "their settings and at the top of their friends, like Name#0042." },
  self = { "That's you", "Type a friend's name and number instead." },
  full = { "Your friends list is full", "It takes 200 friends and requests, remove some first." },
  slow = { "Not so fast", "You asked for a lot in a short time, try again in a minute." },
}
-- seconds before the same news of the same player is told again: a request once, however often it's made again
local QUIET = { request = math.huge, friend = 0, presence = 60, invite = 30 }

local INVISIBLE, SPECTATING = "Appear invisible to my friends", "Allow my friends to spectate me"
local invisible, spectating = setting(INVISIBLE, false), setting(SPECTATING, true)
local notify = setting("Tell me when a friend comes online or leaves", true)

-- friends: the player's friends and requests as the server last sent them, nil until it did. each is { player =,
-- state = "friend", "incoming" or "outgoing", online =, playing = { id =, level =, play = }, watch = whether their play
-- can be watched }
local F = { invisible = invisible, spectating = spectating }
local screen
local socket, online, signed, parked = nil, false, nil, false -- online: the server knows who this is, signed: as who
local fails, retry = 0, 0 -- the connections that dropped in a row, and when the next one is made
local play -- the play of this game: { told = the server heard of it, frames = those streamed, nil when it isn't }
local unsent = {} -- its frames the connection couldn't take
local watching -- the friend's play watched: { id =, play =, parts = those heard, started = once it shows }
local inRoom -- a room streams its plays itself, and its matches come before a friend's play
local told = {} -- when each news of each player was last told

-- frames wait for the connection (keep), a part missing would break what a friend watches. the rest is said again
-- once it's back
local function send(message, keep)
  if online then return socket.send(message) end
  if keep then unsent[#unsent + 1] = message end
end

local function status() send({ t = "status", visible = not invisible(), spectating = spectating() }) end

local function friend(id)
  for _, f in ipairs(F.friends or {}) do
    if f.player.id == id then return f end
  end
end

-- what a player did (news: a key of QUIET), after their avatar, name and number. what happens during a song is old
-- news once it ends, and nobody fills the screen by doing the same thing over and over
local function tell(player, news, did, seconds, tap)
  local key = player.id .. news
  if playing() or now() - (told[key] or -math.huge) < QUIET[news] then return end
  told[key] = now()
  toast(("%s#%04d %s"):format(player.name, player.number, did), { avatar = player.avatar, seconds = seconds,
    tap = tap and function()
      if MENUS[scene()] then tap() end
    end })
end

-- what the game plays now, nothing outside of a song. friends may watch a play told from its start, while one of
-- them is online to
local function tellPlay()
  local chart = playing()
  local watched = not invisible() and spectating() and not inRoom and #F.online() > 0
  play = chart and { told = online, frames = watched and 0 or nil }
  unsent = {}
  send({ t = "playing", song = chart and chart.id or "", level = chart and chart.difficulty or "" })
end

local function stream()
  if not (play and play.frames) then return end
  local data
  data, play.frames = phigrospp.replay.chunk(play.frames)
  if data then send({ t = "frames", data = phigrospp.base64(data) }, true) end
end

-- watches a friend's play from where it is, until it ends or the player leaves it (nil)
local function watch(f)
  watching = f and { id = f.player.id, play = f.playing.play, parts = 0 }
  send({ t = "follow", player = f and f.player.id or "", from = 0 })
  phigrospp.replay.follow(f and ("%s#%04d"):format(f.player.name, f.player.number))
end

local heard = {} -- what the server says, by its t

function heard.welcome(m)
  F.me, online, fails = m.player, true, 0
  status()
  -- a play the server still has goes on with the frames it missed, one it never heard of is told with all of them.
  -- one it forgot lost its first frames: it's told without any
  local kept, known = unsent, play and play.told
  unsent = {}
  if play then
    if not (known and m.playing) then
      send({ t = "playing", song = playing().id, level = playing().difficulty })
      play.told = true
    end
    if known and not m.playing then play.frames = nil end
    for _, message in ipairs(play.frames and kept or {}) do send(message) end
  elseif m.playing then
    send({ t = "playing", song = "", level = "" })
  end
  -- the play watched goes on from the part missed
  if watching then send({ t = "follow", player = watching.id, from = watching.parts }) end
end

-- those online first, the ones playing before them, then the requests to answer
local function rank(f)
  return f.state == "incoming" and 1 or f.state == "outgoing" and 5 or f.playing and 2 or f.online and 3 or 4
end

-- what changed since the last list: a request, an answer to one, a friend coming or going
local function changes(was)
  local before = {}
  for _, f in ipairs(was) do before[f.player.id] = f end
  for _, f in ipairs(F.friends) do
    local old = before[f.player.id]
    if f.state == "incoming" and not old then
      tell(f.player, "request", "wants to be your friend", 8, screen.open)
    elseif f.state == "friend" and old and old.state == "outgoing" then
      tell(f.player, "friend", "is now your friend")
    elseif old and old.state == "friend" and f.state == "friend" and f.online ~= old.online and notify() then
      tell(f.player, "presence", f.online and "is online" or "went offline")
    end
  end
end

function heard.friends(m)
  local was = F.friends
  F.friends = m.friends
  for i, f in ipairs(F.friends) do f.order = i end
  table.sort(F.friends, function(a, b)
    if rank(a) ~= rank(b) then return rank(a) < rank(b) end
    return a.order < b.order
  end)
  if was then
    changes(was)
  else
    -- the first list of a launch: the requests that came while the game was closed are told together
    local asking = 0
    for _, f in ipairs(F.friends) do asking = asking + (f.state == "incoming" and 1 or 0) end
    if asking > 0 then
      toast(("%d pending friend request%s"):format(asking, asking == 1 and "" or "s"), { icon = "users", seconds = 8,
        tap = function()
          if MENUS[scene()] then screen.open() end
        end })
    end
  end
  -- the play watched ended once its player plays something else or nothing, their last frames came before. one that
  -- ended before any came never shows
  local f = watching and friend(watching.id)
  if watching and not (f and f.playing and f.playing.play == watching.play) then
    if watching.parts == 0 then watch(nil) else phigrospp.replay.feed() end
  end
  screen.refresh()
end

function heard.frames(m)
  if not watching or m.player ~= watching.id then return end
  watching.parts = watching.parts + 1
  phigrospp.replay.feed(phigrospp.unbase64(m.data))
end

-- a friend asks the player into their room: the toast joins it, as its link does
function heard.invite(m)
  tell(m.player, "invite", "invites you to " .. m.name, 10, function()
    phigrospp.emit("link", "phigrospp://room/" .. m.room)
  end)
end

-- a friend refused is told why. anything else ends the connection for good: the player joined from another device,
-- or the server doesn't know this one. opening the screen makes it again
function heard.error(m)
  local why = ERRORS[m.code]
  if why then
    return coroutine.wrap(ui.confirm)({ title = why[1], message = why[2], yes = "OK", no = false })
  end
  parked = true
  socket.close()
  socket, online = nil, false
  screen.refresh()
end

-- the socket follows the profile: made once there's one, again a while after it dropped, gone with the profile
every(1, function()
  local tag = phigrospp.tag()
  if tag ~= signed then
    if socket then socket.close() end
    socket, online, signed, parked, retry, F.friends = nil, false, tag, false, 0, nil
  end
  if not tag or socket or parked or now() < retry then return end
  socket = phigrospp.channel("/api/friends", DOMAIN, heard, function()
    socket, online, fails = nil, false, fails + 1
    retry = now() + math.min(SLOWEST, RETRY * 2 ^ (fails - 1))
    screen.refresh()
  end)
end)

-- the player's own plays: a replay watched isn't one, nor a friend's play
on("song", function()
  if watching then watching.started = true end
  if not phigrospp.replay.state() then tellPlay() end
end)

on("restart", function()
  if play then tellPlay() end
end)

on("leave", function()
  if play then tellPlay() end
end)

every(0.5, stream)
on("finish", stream)

-- back in a menu, the play watched is over
on("scene", function(name)
  if watching and watching.started and MENUS[name] then watch(nil) end
end)

on("room", function(room) inRoom = room ~= nil end)
on("setting", function(label)
  if label == INVISIBLE or label == SPECTATING then status() end
end)

-- what the screen and the rooms do with friends ---------------------------------------------------------------------

function F.connected() return online end

-- the friends who are online
function F.online()
  local list = {}
  for _, f in ipairs(F.friends or {}) do
    if f.online then list[#list + 1] = f end
  end
  return list
end

-- what a player (their id) is to this one: "friend", "incoming" or "outgoing" for a request, nothing otherwise
function F.state(id) return (friend(id) or {}).state end

-- asks a player to be a friend, by id or name#0042, or accepts their request
function F.add(player) send({ t = "add", player = player }) end

-- ends a friendship, turns a request down or takes one back
function F.remove(id) send({ t = "remove", player = id }) end

-- asks a friend into the room the player is in
function F.invite(id) send({ t = "invite", player = id }) end

-- watches the play of a friend (an entry of F.friends), once nothing is in the way
function F.watch(f)
  local chart = f.playing
  if inRoom then
    return ui.confirm({ title = "You're in a room", message = "Leave it to watch a friend play.", yes = "OK", no = false })
  end
  if not phigrospp.unlocked(chart.id, chart.level) then
    return ui.confirm({ title = "You don't have this chart", yes = "OK", no = false,
      message = "A play is watched in your own game, which needs the chart unlocked." })
  end
  screen.close()
  watch(f)
end

-- turns one of the player's two switches (F.invisible, F.spectating) the other way
function F.flip(switch)
  switch(not switch())
  status()
  screen.refresh()
end

-- a connection that ended for good is made again
function F.wake() parked, retry = false, 0 end

screen = require("screen")(F)
F.open, F.close, F.showing = screen.open, screen.close, screen.showing -- F.rooms opens the rooms', theirs to set

-- the avatar of the song list opens the screen. without a profile the game slides the player's name out as it does
on("scene", function(name)
  screen.close()
  if name ~= "SongSelector" then return end
  local bar = UE.Object.FindObjectOfType(CS.PlayerBarControl)
  phigrospp.click(bar:GetComponent(UE.UI.Button), function()
    if not phigrospp.tag() then return end
    bar._playerIdAppear = true -- which the game turns off right after: the name stays in
    screen.open()
  end)
end)

return F
