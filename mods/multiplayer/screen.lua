-- the rooms' screen, over the menus: the open rooms, then the one the player is in. its players are on the left (the
-- host under a crown, who's ready, spectators grayed, the scores of the match played), its chart on the right, the chat
-- under the players

local UE = CS.UnityEngine
local kit, M = phigrospp.ui, phigrospp.modifiers
local chooser = require("modifiers")
local SLOPE = CS.SettingItemsManager.InverseSlope -- the game's slant: sideways per unit of height
local ROW, STEP = 68, 78 -- a player's row, and from a row to the next
local LINES, LINE = 3, 36 -- the chat lines shown, and their height
local BUTTON, GAP = 210, 16 -- the buttons at the bottom right: the host has three
local REFRESH = 4 -- seconds between two reads of the open rooms
local NAMING = "Name it in 24 characters at most, or leave it empty to name it after you."
local C = kit.colours
local WHITE, DIM, FAINT, DARK, GOLD, GREEN, RED = C.white, C.dim, C.faint, C.dark, C.gold, C.green, C.red
local LEVEL = { EZ = { 0.29, 0.66, 0.29, 1 }, HD = { 0.23, 0.47, 0.75, 1 }, IN = { 0.77, 0.23, 0.2, 1 },
  AT = { 0.29, 0.29, 0.32, 1 } }

-- mp is the mod's state (init.lua), room what it can do: send, enter, join, follow, seat, shown, and the friends mod
return function(mp, room)
  local S = {}
  local V = kit.view("phigrospp-room") -- the canvas over the menu, with the list's panel or the room's
  local H, LEFT, TOP = V.height, V.left, V.top
  local text, icon, tappable, plate, action, back, part = V.text, V.icon, V.tappable, V.plate, V.action, V.back, V.part
  local pill -- the host's way back to the room while picking a chart
  local field -- the chat's text box
  local listing, rooms, polling -- the list is open, the rooms it shows (false when they can't be read), its timer
  local states -- each player's text on the right of their row, by id

  -- the open rooms ---------------------------------------------------------------------------------------------------

  local function fetch()
    phigrospp.request("GET", "/api/rooms", nil, function(status, body)
      if not listing then return end
      rooms = status == 200 and { body = body, list = phigrospp.json.decode(body) }
      S.refresh()
    end)
  end

  local function closeList()
    if polling then polling() end
    listing, polling = false, nil
  end

  -- a room is named first, then given a password or none
  local function create()
    local named, name = kit.confirm({ title = "Create a room", input = "Room name", yes = "Next", message = NAMING })
    if not named then return end
    local made, password = kit.confirm({ title = "Protect it with a password?", input = "Password", yes = "Create",
      message = "Leave it empty for a room anyone can join, whose matches show on phigros.tools. With a password "
        .. "only the players who have it join, and its matches stay between them." })
    if made then room.enter({ t = "create", name = name, password = password }) end
  end

  local function drawList()
    local width = V.width
    part("top", "", function(root)
      back(root, function()
        closeList()
        S.refresh()
      end)
      V.titles(root, { "Rooms", "Friends" }, "Rooms", function()
        closeList()
        S.refresh()
        room.friends.open()
      end)
      action(root, { width - 400, TOP + 38 }, 340, "Create a room", create)
    end)
    part("rooms", rooms and rooms.body or tostring(rooms), function(root)
      local list = rooms and rooms.list or {}
      if #list == 0 then
        local why = rooms == nil and "" or rooms and "No room is open, create the first one" or "phigros.tools can't be reached"
        return text(root, { width / 2, H / 2 }, 44, why, DIM, 4, { 0.5, 0.5 })
      end
      local rows = kit.list(root, "phigrospp-rooms", { 0, 30 }, { width, TOP - 114 }, math.floor(width * 0.7))
      for i, r in ipairs(list) do
        local y = (i - 1) * 104
        local shape = kit.bar(rows.rows, "phigrospp-rooms-row", { -y * SLOPE, -y }, { rows.width, 88 }, FAINT)
        local name = text(shape.transform, { 48, 44 }, 40, r.name)
        if r.locked then icon(shape.transform, { 64 + name.preferredWidth, 44 }, 34, "lock", DIM) end
        local chart = r.chart and song(r.chart.id)
        local playing = r.playing and "Playing" or chart and ("%s  %s"):format(chart.name, r.chart.level) or ""
        text(shape.transform, { rows.width * 0.45, 44 }, 30, playing, DIM, 3, nil, rows.width * 0.4)
        text(shape.transform, { rows.width - 48, 44 }, 40, ("%d/8"):format(r.players), WHITE, 5, { 1, 0.5 }) -- MiddleRight
        tappable(shape, function() room.join(r.id) end)
      end
      rows.content.sizeDelta = { 0, #list * 104 + 32 }
    end)
  end

  -- the room ---------------------------------------------------------------------------------------------------------

  local function leave()
    local r = mp.room
    if kit.confirm({ title = ("Leave %s?"):format(r.name), yes = "Leave",
        message = #r.players == 1 and "The room closes when its last player leaves."
          or r.host == mp.me.id and "The player who joined after you becomes its host."
          or "You can join it again from the rooms." }) then
      room.send({ t = "leave" })
    end
  end

  local function rename()
    local ok, name = kit.confirm({ title = "Rename the room", input = "Room name", yes = "Rename", message = NAMING })
    if ok then room.send({ t = "rename", name = name }) end
  end

  -- a player's row: anyone asks them to be their friend, the host hands them the room or removes them
  local function manage(player)
    local choices, state = {}, room.friends.state(player.id)
    if state ~= "friend" and state ~= "outgoing" then
      choices[1] = { icon = "user-plus", label = state and "Accept friend" or "Add friend", colour = GREEN, value = "friend" }
    end
    if mp.room.host == mp.me.id then
      choices[#choices + 1] = { icon = "crown", label = "Make host", colour = GOLD, value = "host" }
      choices[#choices + 1] = { icon = "x", label = "Remove", colour = RED, value = "kick" }
    end
    if #choices == 0 then return end
    local t = kit.choose(("%s#%04d"):format(player.name, player.number), choices)
    if t == "friend" then return room.friends.add(player.id) end
    if t then room.send({ t = t, player = player.id }) end
  end

  -- the friends who are online and not in the room yet, to tap one into it: they get a toast that joins it
  local function invite()
    local cells, invited = {}, {}
    for _, f in ipairs(room.friends.online()) do
      local id = f.player.id
      if not room.seat(mp.room, id) then
        cells[#cells + 1] = { icon = kit.icon("users"), label = f.player.name, colour = GREEN,
          on = function() return invited[id] end, note = function() return invited[id] and "Invited" or "" end,
          tap = function()
            invited[id] = true
            room.friends.invite(id)
          end }
      end
    end
    kit.confirm({ title = "Invite friends", yes = false, no = "Done",
      message = #cells > 0 and "Tap a friend to invite them to this room."
        or "No friend of yours is online outside this room. Friends are added from the rooms' Friends.",
      grid = #cells > 0 and { columns = 4, height = 190, cells = cells } or nil })
  end

  -- the host's modifiers become the room's
  local function modifiers()
    local chart = mp.room.chart
    if not M.fits(chart.id, chart.level) then
      return kit.confirm({ title = "Modifiers", message = chooser.PLAIN, yes = "OK", no = false })
    end
    M.pick(chart.mods)
    chooser.choose()
    room.send({ t = "chart", song = chart.id, level = chart.level, mods = M.pick() })
  end

  local function say()
    local line = field.text
    if not line:find("%S") then return end
    room.send({ t = "chat", text = line })
    field.text = ""
  end

  -- a spectator watches a player of the match, anyone manages one otherwise
  local function tapped(player)
    local r = mp.room
    local me, p = room.seat(r, mp.me.id), room.seat(r, player.id)
    if not r.playing or not me.watching then
      manage(player)
    elseif p and p.playing and me.able then
      room.follow(p)
    end
  end

  -- what a player's row says on its right: their score while a match is played, else their place in the last one
  local function state(r, p)
    if p.watching then return "Spectating", DIM end
    if r.playing and (p.playing or p.score > 0) then return ("%07d"):format(p.score), p.playing and WHITE or DIM end
    if r.chart and not p.able then return "No chart", RED end
    for _, play in ipairs(r.last and r.last.plays or {}) do
      if play.player.id == p.player.id then return ("#%d  %07d"):format(play.rank, play.total), DIM end
    end
    return "", DIM
  end

  local function drawRoom(r)
    local width = V.width
    local me, column = room.seat(r, mp.me.id), math.min(860, width * 0.5)
    local host = r.host == mp.me.id

    part("top", r.id, function(root)
      back(root, leave)
      action(root, { width - 320, TOP + 38 }, 260, "Invite", invite)
      -- the chat's text box stays as it is while the rest is drawn again. it ends before the host's buttons
      local box = math.min(column - 84, width - 3 * (BUTTON + GAP) - 2 * LEFT - 112)
      local area = kit.rect(root, "phigrospp-room-input", { LEFT, 120 }, { box, 60 }, { 1, 1, 1, 0.1 })
      area.raycastTarget = true
      area.gameObject:AddComponent(UE.UI.RectMask2D)
      field = area.gameObject:AddComponent(UE.UI.InputField)
      field.textComponent = text(area.transform, { 20, 30 }, 28, "", WHITE, 3, nil, box - 40)
      field.lineType, field.characterLimit = 0, 200 -- SingleLine
      local hint = text(area.transform, { 20, 30 }, 28, "", { 1, 1, 1, 0.4 }, 3, nil, box - 40)
      hint.text, field.placeholder = "Say something to the room", hint
      tappable(kit.rect(root, "phigrospp-room-send", { LEFT + box + 12, 120 }, { 60, 60 }, FAINT), say)
      icon(root, { LEFT + box + 22, 120 }, 40, "send")
    end)

    -- the host renames the room by tapping its name
    part("title", ("%s %s"):format(host, r.name), function(root)
      local x = 244 + text(root, { 220, TOP }, 56, r.name).preferredWidth
      if r.locked then
        icon(root, { x, TOP }, 40, "lock", DIM)
        x = x + 56
      end
      if not host then return end
      icon(root, { x, TOP }, 40, "pencil", DIM)
      tappable(kit.rect(root, "phigrospp-room-rename", { 200, TOP }, { x + 60 - 200, 110 }, { 0, 0, 0, 0 }), rename)
    end)

    -- left of Invite: spectating, and how many watch from a browser
    part("spectate", ("%s %d"):format(me.watching, r.watchers), function(root)
      local x = width - 596
      action(root, { x, TOP + 38 }, 260, "Spectate", function()
        room.send({ t = "spectate", spectate = not me.watching })
      end, me.watching and GOLD)
      if r.watchers > 0 then
        text(root, { x - 24, TOP }, 30, ("%d watching"):format(r.watchers), DIM, 5, { 1, 0.5 }) -- MiddleRight
      end
    end)

    local keys = { r.host }
    for i, p in ipairs(r.players) do
      keys[i + 1] = ("%s %s %s %s %s"):format(p.player.id, p.ready, p.able, p.watching, p.player.avatar)
    end
    part("players", table.concat(keys, "\n"), function(root)
      states = {}
      for i, p in ipairs(r.players) do
        local own = p.player.id == mp.me.id
        local shape = kit.bar(root, "phigrospp-room-player", { LEFT + 20, H - 140 - (i - 1) * STEP }, { column, ROW },
          own and { 1, 1, 1, 0.18 } or FAINT)
        if p.player.id == r.host then icon(shape.transform, { 14, ROW / 2 }, 38, "crown", GOLD) end
        local avatar = kit.avatar(shape.transform, "phigrospp-room-avatar", { 64, ROW / 2 }, 52, p.player.avatar)
        if p.watching then avatar.color = DIM end
        local name = text(shape.transform, { 132, ROW / 2 }, 34, p.player.name, p.watching and DIM or WHITE)
        text(shape.transform, { 142 + name.preferredWidth, ROW / 2 }, 26, ("#%04d"):format(p.player.number), DIM)
        if p.ready then icon(shape.transform, { column - 64, ROW / 2 }, 38, "check", GREEN) end
        states[p.player.id] = text(shape.transform, { column - 84, ROW / 2 }, 30, "", DIM, 5, { 1, 0.5 }) -- MiddleRight
        if not own then tappable(shape, function() tapped(p.player) end) end
      end
    end)
    for _, p in ipairs(r.players) do
      local t = states[p.player.id]
      t.text, t.color = state(r, p)
    end

    local chart = r.chart
    local key = chart and ("%s %s %d %s %s %s"):format(chart.id, chart.level, chart.mods, me.able, me.watching, r.playing)
    part("chart", key or tostring(host),
      function(root)
        local x, wide = LEFT + column + 90, math.min(760, width - column - 210)
        if not chart then
          return text(root, { x + wide / 2, H / 2 + 60 }, 38, host and "Choose the chart everyone plays"
            or "The host is choosing a chart", DIM, 4, { 0.5, 0.5 })
        end
        local s, high = song(chart.id), math.floor(wide * 0.527) -- as wide for its height as the game's covers
        local cover = kit.place(root, "phigrospp-room-cover", UE.UI.Image, { x, H - 140 }, { wide, high }, { 0, 1 })
        cover.color = s and WHITE or FAINT -- a song this version of the game doesn't have has no cover
        if s then cover.gameObject:AddComponent(CS.AddressableImageLoader).Code = CS.IdBuilder.BuildCoverImageId(chart.id, "") end
        local y = H - 140 - high - 46
        text(root, { x, y }, 44, s and s.name or chart.song, WHITE, 3, nil, wide)
        text(root, { x, y - 50 }, 28, s and s.composer or "", DIM, 3, nil, wide)
        local rated = s and s.charts[chart.level]
        plate(root, { x, y - 84 }, { 170, 56 }, LEVEL[chart.level], 30,
          rated and ("%s %.1f"):format(chart.level, rated.constant) or chart.level, WHITE)
        local strip = M.strip(root, chart.mods, { x + 196, y - 112 }, 52)
        if chart.mods ~= 0 then text(root, { x + 212 + strip.sizeDelta.x, y - 112 }, 30, M.multiplier(chart.mods), DIM) end
        local note = not me.able and "You don't have this chart, so you sit this match out"
          or r.playing and (me.watching and "Tap a player to watch them play" or "A match is being played") or ""
        text(root, { x, y - 176 }, 28, note, me.able and DIM or RED, 3, nil, wide)
      end)

    -- the host starts once everyone who plays and has the chart is ready, and someone plays
    local waiting, players = chart == nil, 0
    for _, p in ipairs(r.players) do
      players = players + (p.watching and 0 or 1)
      waiting = waiting or p.player.id ~= r.host and not p.watching and p.able and not p.ready
    end
    waiting = waiting or players == 0
    part("actions", ("%s %s %s %s %s %s"):format(host, r.playing, waiting, me.ready, me.able, me.watching), function(root)
      if r.playing or not host and me.watching then return end
      local x = width - LEFT - BUTTON
      if not host then
        if not me.able then return action(root, { x, 158 }, BUTTON, "No chart") end
        return action(root, { x, 158 }, BUTTON, "Ready", function()
          room.send({ t = "ready", ready = not me.ready })
        end, me.ready and GREEN)
      end
      action(root, { x, 158 }, BUTTON, "Start", not waiting and function() room.send({ t = "start" }) end,
        not waiting and GREEN)
      if chart then
        x = x - BUTTON - GAP
        action(root, { x, 158 }, BUTTON, "Modifiers", modifiers)
      end
      action(root, { x - BUTTON - GAP, 158 }, BUTTON, "Chart", function()
        mp.picking = true
        S.refresh()
      end)
    end)

    -- it scrolls to its newest line, which is right above the text box even while the chat is short
    part("chat", tostring(mp.chat[#mp.chat]), function(root)
      local view = LINES * LINE
      local list = kit.list(root, "phigrospp-room-chat", { LEFT, 164 }, { column, view })
      local high = math.max(view, #mp.chat * LINE)
      for i, said in ipairs(mp.chat) do
        local y = high - (#mp.chat - i + 0.5) * LINE
        text(list.rows, { 0, -y }, 28, ("%s: %s"):format(said.name, said.text), WHITE, 3, nil, column)
      end
      list.content.sizeDelta, list.content.anchoredPosition = { 0, high }, { 0, high - view }
    end)
  end

  -- a spectator who picked a player until their play comes, like the replay player's "Preparing..."
  local function drawWaiting(player)
    part("top", player.id, function(root)
      back(root, function() room.follow(nil) end)
      text(root, { V.width / 2, H / 2 }, 56, ("Waiting for %s's play..."):format(player.name), WHITE, 4, { 0.5, 0.5 })
    end)
  end

  -- what shows follows the room, the scene and what the player is doing: the mod calls it at each change
  function S.refresh()
    local r, shown = mp.room, room.shown()
    if r and listing then closeList() end
    local view = shown and (r and not mp.picking and (mp.waiting and "waiting" or "room") or listing and "list") or nil
    -- the song list reads the touches itself: it's turned off under the screen once it filled in and the game's
    -- loading screen, which waits for it, is gone, unless a page or a dialog did already
    local selector = scene() == "SongSelector" and not kit.paging() and not il2cpp.alive(kit.dialog)
      and UE.Object.FindObjectOfType(CS.SongSelector)
    if view and selector and (selector.SongItems._size == 0 or CS.Loading.IsActive) then return after(0.1, S.refresh) end
    if selector then selector.enabled = view == nil end
    if il2cpp.alive(pill) then UE.Object.Destroy(pill.gameObject) end
    if not view then
      V.hide()
      if not (shown and r) then return end
      local canvas = V.stage()
      -- at the bottom, between the song list and its play button, where the chapter screen has nothing either
      local hint = "Play a chart to pick it, or tap here to go back"
      local measure = text(canvas, { 0, 0 }, 26, hint)
      local wide = measure.preferredWidth + 96
      UE.Object.Destroy(measure.gameObject)
      pill = plate(canvas, { V.width * 0.525 - wide / 2, 112 }, { wide, 70 }, GOLD, 26, hint, DARK)
      tappable(pill, function()
        mp.picking = false
        S.refresh()
      end)
      return
    end
    V.show(view)
    if view == "list" then drawList() elseif view == "waiting" then drawWaiting(mp.waiting) else drawRoom(r) end
  end

  -- the chapter screen's tab: the room when in one, else the open rooms
  function S.open()
    mp.picking = false
    if not mp.room then
      listing, rooms = true, nil
      fetch()
      polling = polling or every(REFRESH, fetch)
    end
    S.refresh()
  end

  -- what the keyboard put in the box is sent, unless it was closed with back
  local typing
  on("update", function()
    local focused = field and il2cpp.alive(field) and field.isFocused
    if typing and not focused and field and il2cpp.alive(field) and not field.wasCanceled then say() end
    typing = focused
  end)

  return S
end
