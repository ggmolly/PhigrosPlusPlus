-- the rooms' screen, over the menus: the open rooms, then the one the player is in. its players are on the left (the
-- host under a crown, what each plays the chart with, who's ready, spectators grayed, the scores of the match played),
-- its chart on the right over the ones queued after it, the chat under the players

local UE = CS.UnityEngine
local kit, M = phigrospp.ui, phigrospp.modifiers
local chooser = require("modifiers")
local SLOPE = CS.SettingItemsManager.InverseSlope -- the game's slant: sideways per unit of height
local ROW, STEP = 68, 78 -- a player's row, and from a row to the next
local LINES, LINE = 3, 36 -- the chat lines shown, and their height
local QUEUED = 60 -- from a queued chart's row to the next
local BUTTON, GAP = 210, 16 -- the buttons at the bottom right: the host has three
local REFRESH = 4 -- seconds between two reads of the open rooms
local NAMING = "Name it in 24 characters at most, or leave it empty to name it after you."
local C = kit.colours
local WHITE, DIM, FAINT, DARK, GOLD, GREEN, RED = C.white, C.dim, C.faint, C.dark, C.gold, C.green, C.red
local LEVELS = { "EZ", "HD", "IN", "AT" }

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
  local queue -- the queue as drawn: { list =, rows = { { t = its transform, chart = } }, wide =, host = }
  -- the row of it the host drags: { i = its place, to = where it would go, finger =, y = where it began, shape =,
  -- colour = the row's own }
  local moving

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

  -- what the player plays the room's chart with: their own modifiers, and the next level of the song they have
  local function modifiers()
    local chart, me = mp.room.chart, room.seat(mp.room, mp.me.id)
    if not M.fits(chart.id, me.level) then
      return kit.confirm({ title = "Modifiers", message = chooser.PLAIN, yes = "OK", no = false })
    end
    M.pick(me.mods)
    chooser.choose()
    room.send({ t = "pick", level = me.level, mods = M.pick() })
  end

  local function level()
    local chart, me = mp.room.chart, room.seat(mp.room, mp.me.id)
    local at
    for i, name in ipairs(LEVELS) do
      if name == me.level then at = i end
    end
    for i = 1, #LEVELS - 1 do
      local next = LEVELS[(at + i - 1) % #LEVELS + 1]
      if phigrospp.unlocked(chart.id, next) then
        return room.send({ t = "pick", level = next, mods = M.fits(chart.id, next) and me.mods or 0 })
      end
    end
  end

  -- a chart is taken out of the room by the one who added it, or by the host
  local function mine(chart) return chart.by == mp.me.id or mp.room.host == mp.me.id end

  local function unqueue(chart)
    local s = song(chart.id)
    if kit.confirm({ title = ("Remove %s?"):format(s and s.name or chart.song), yes = "Remove", danger = true,
        message = "The room plays the next chart of its queue instead." }) then
      room.send({ t = "unqueue", entry = chart.entry })
    end
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
    elseif p and p.playing and phigrospp.unlocked(r.chart.id, p.level) then
      room.follow(p)
    end
  end

  -- what a player's row says on its right: their score while a match is played, else their place in the last one
  local function state(r, p)
    if p.watching then return "Spectating", DIM end
    if r.playing and (p.playing or p.score > 0) then
      return ("%07d"):format(M.total(p.score, p.mods)), p.playing and WHITE or DIM
    end
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
      keys[i + 1] = ("%s %s %s %s %s %s %s"):format(p.player.id, p.ready, p.able, p.watching, p.player.avatar,
        r.chart and p.level, p.mods)
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
        -- what they play the chart with, before what their row says
        if r.chart and not p.watching then
          plate(shape.transform, { column - 364, ROW - 16 }, { 70, 36 }, C[p.level], 24, p.level, WHITE)
          local strip = M.strip(shape.transform, p.mods, { 0, ROW / 2 }, 32)
          strip.anchoredPosition = { column - 386 - strip.sizeDelta.x, ROW / 2 }
        end
        if not own then tappable(shape, function() tapped(p.player) end) end
      end
    end)
    for _, p in ipairs(r.players) do
      local t = states[p.player.id]
      t.text, t.color = state(r, p)
    end

    -- the chart the room is on, at the level and with the modifiers the player picked: a tap on the level goes to
    -- the next one they have
    local chart = r.chart
    local key = chart and ("%d %s %d %s %s %s %s"):format(chart.entry, me.level, me.mods, me.able, me.watching, r.playing,
      host)
    local cx, wide = LEFT + column + 90, math.min(760, width - column - 210)
    local tall = math.floor(wide * 0.527) -- as wide for its height as the game's covers
    local cy = H - 140 - tall - 46
    part("chart", key or "", function(root)
      if not chart then
        return text(root, { cx + wide / 2, H / 2 + 60 }, 38, "Add the chart everyone plays", DIM, 4, { 0.5, 0.5 })
      end
      local s = song(chart.id)
      local cover = kit.place(root, "phigrospp-room-cover", UE.UI.Image, { cx, H - 140 }, { wide, tall }, { 0, 1 })
      cover.color = s and WHITE or FAINT -- a song this version of the game doesn't have has no cover
      if s then cover.gameObject:AddComponent(CS.AddressableImageLoader).Code = CS.IdBuilder.BuildCoverImageId(chart.id, "") end
      if mine(chart) and not r.playing then
        tappable(kit.rect(root, "phigrospp-room-remove", { cx + wide, H - 140 }, { 72, 72 }, { 0, 0, 0, 0.6 }, { 1, 1 }),
          function() unqueue(chart) end)
        icon(root, { cx + wide - 56, H - 176 }, 40, "x")
      end
      text(root, { cx, cy }, 44, s and s.name or chart.song, WHITE, 3, nil, wide)
      text(root, { cx, cy - 50 }, 28, s and s.composer or "", DIM, 3, nil, wide)
      local rated = s and s.charts[me.level]
      local picked = plate(root, { cx, cy - 84 }, { 170, 56 }, C[me.level], 30,
        rated and ("%s %.1f"):format(me.level, rated.constant) or me.level, WHITE)
      if not r.playing then tappable(picked, level) end
      local strip = M.strip(root, me.mods, { cx + 196, cy - 112 }, 52)
      if me.mods ~= 0 then text(root, { cx + 212 + strip.sizeDelta.x, cy - 112 }, 30, M.multiplier(me.mods), DIM) end
      local note = not me.able and "You don't have this chart at this level, tap the level for another"
        or r.playing and (me.watching and "Tap a player to watch them play" or "A match is being played") or ""
      text(root, { cx, cy - 176 }, 28, note, me.able and DIM or RED, 3, nil, wide)
    end)

    -- the charts queued after it, as rows like the players': the level each was added at, its song, who added it,
    -- and a cross on the ones the player may take back (theirs, or any for the host, who also moves them)
    local entries = {}
    for i, queued in ipairs(r.queue) do entries[i] = queued.entry .. queued.by end
    part("queue", ("%s %s"):format(host, table.concat(entries, " ")), function(root)
      queue = nil
      if #r.queue == 0 then return end
      local top = cy - 220
      text(root, { cx, top }, 30, ("Up next (%d)"):format(#r.queue))
      local list = kit.list(root, "phigrospp-room-queue", { cx - 16, 182 }, { wide + 16, top - 212 })
      queue = { list = list, rows = {}, wide = wide, host = host }
      for i, queued in ipairs(r.queue) do
        local s, by = song(queued.id), room.seat(r, queued.by)
        local shape = kit.bar(list.rows, "phigrospp-room-queued", { 16, -(i - 1) * QUEUED }, { wide, QUEUED - 8 },
          queued.by == mp.me.id and { 1, 1, 1, 0.18 } or FAINT)
        local middle = (QUEUED - 8) / 2
        plate(shape.transform, { 16, QUEUED - 16 }, { 66, QUEUED - 24 }, C[queued.level], 22, queued.level, WHITE)
        text(shape.transform, { 96, middle }, 28, s and s.name or queued.song, WHITE, 3, nil, wide * 0.52)
        local ends = wide - 28
        if mine(queued) then
          ends = ends - 44
          icon(shape.transform, { ends + 14, middle }, 30, "x", DIM)
          tappable(kit.rect(shape.transform, "phigrospp-room-unqueue", { ends, middle }, { 60, QUEUED - 8 }, { 0, 0, 0, 0 }),
            function() unqueue(queued) end)
        end
        text(shape.transform, { ends, middle }, 24, by and by.player.name or "", DIM, 5, { 1, 0.5 }) -- MiddleRight
        queue.rows[i] = { t = shape.transform, chart = queued }
      end
      list.content.sizeDelta = { 0, #r.queue * QUEUED }
    end)

    -- the host starts once everyone who plays and has the chart is ready, and someone plays. everyone adds charts
    -- and picks their modifiers
    local waiting, players = chart == nil, 0
    for _, p in ipairs(r.players) do
      players = players + ((p.watching or not p.able) and 0 or 1)
      waiting = waiting or p.player.id ~= r.host and not p.watching and p.able and not p.ready
    end
    waiting = waiting or players == 0
    part("actions", ("%s %s %s %s %s %s %s"):format(host, r.playing, waiting, me.ready, me.able, me.watching, chart ~= nil),
      function(root)
        if r.playing or not host and me.watching then return end
        local x = width - LEFT - BUTTON
        if host then
          action(root, { x, 158 }, BUTTON, "Start", not waiting and function() room.send({ t = "start" }) end,
            not waiting and GREEN)
        elseif chart and me.able then
          action(root, { x, 158 }, BUTTON, "Ready", function() room.send({ t = "ready", ready = not me.ready }) end,
            me.ready and GREEN)
        else
          action(root, { x, 158 }, BUTTON, chart and "No chart" or "Ready")
        end
        if chart then
          x = x - BUTTON - GAP
          action(root, { x, 158 }, BUTTON, "Modifiers", modifiers)
        end
        action(root, { x - BUTTON - GAP, 158 }, BUTTON, "Add chart", function()
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
      local hint = "Play a chart to add it to the room, or tap here to go back"
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

  -- the host moves a queued chart by holding it, then dragging: its row follows the finger and the others make room,
  -- until the finger lifts. the canvas is drawn over the screen, so a row's position is in pixels
  local function rowAt(x, y)
    if not (queue and queue.host and V.shown() == "room" and il2cpp.alive(queue.list.transform)) then return end
    local u = UE.Screen.height / H
    local view = queue.list.transform.position -- its bottom left corner
    if y < view.y or y > view.y + queue.list.transform.rect.m_Height * u then return end
    for i, row in ipairs(queue.rows) do
      local at = row.t.position -- its top left corner
      if x > at.x and x < at.x + queue.wide * u and y < at.y and y > at.y - (QUEUED - 8) * u then return i end
    end
  end

  -- a finger that moved meanwhile scrolls the list instead
  local pressed
  phigrospp.hold(function(x, y)
    pressed = y
    return rowAt(x, y) ~= nil
  end, 0.3, function()
    for _, finger in ipairs(touches()) do
      local i = rowAt(finger.x, finger.y)
      if i and not moving and math.abs(finger.y - pressed) < 12 * UE.Screen.height / H then
        local shape = queue.rows[i].t:GetComponent(CS.Lean.Gui.LeanPolygon)
        moving = { i = i, to = i, finger = finger.id, y = finger.y, shape = shape, colour = shape.color }
        queue.list.transform:GetComponent(UE.UI.ScrollRect).enabled = false -- the list would scroll along
        queue.rows[i].t:SetAsLastSibling()
        shape.color = { 1, 1, 1, 0.3 }
      end
    end
  end)

  on("update", function()
    if not moving then return end
    local finger
    for _, each in ipairs(touches()) do
      if each.id == moving.finger and each.phase ~= 3 and each.phase ~= 4 then finger = each end -- not Ended or Canceled
    end
    local rows, drawn = queue and queue.rows, queue and il2cpp.alive(queue.list.transform)
    if not (finger and drawn) then
      -- dropped: the room says the new order, which draws the queue again. one drawn again meanwhile is left as it is
      if drawn then
        queue.list.transform:GetComponent(UE.UI.ScrollRect).enabled = true
        if moving.to ~= moving.i then room.send({ t = "move", entry = rows[moving.i].chart.entry, to = moving.to - 1 }) end
        rows[moving.i].t.anchoredPosition = { 16, -(moving.to - 1) * QUEUED }
        moving.shape.color = moving.colour
      end
      moving = nil
      return
    end
    local down = (moving.i - 1) * QUEUED - (finger.y - moving.y) / (UE.Screen.height / H)
    down = math.max(0, math.min((#rows - 1) * QUEUED, down))
    moving.to = math.floor(down / QUEUED + 0.5) + 1
    for i, row in ipairs(rows) do
      -- the rows between where it was and where it is step into the place it left
      local place = i
      if i > moving.i and i <= moving.to then place = i - 1 elseif i < moving.i and i >= moving.to then place = i + 1 end
      row.t.anchoredPosition = { 16, i == moving.i and -down or -(place - 1) * QUEUED }
    end
  end)

  -- what the keyboard put in the box is sent, unless it was closed with back
  local typing
  on("update", function()
    local focused = field and il2cpp.alive(field) and field.isFocused
    if typing and not focused and field and il2cpp.alive(field) and not field.wasCanceled then say() end
    typing = focused
  end)

  return S
end
