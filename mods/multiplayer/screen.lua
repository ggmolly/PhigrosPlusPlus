-- the rooms' screen, over the menus: the open rooms, then the one the player is in. its players are on the left (the
-- host under a crown, who's ready, the scores of the match played), its chart on the right, the chat under the players

local UE = CS.UnityEngine
local kit, M = phigrospp.ui, phigrospp.modifiers
local chooser = require("modifiers")
local SLOPE = CS.SettingItemsManager.InverseSlope -- the game's slant: sideways per unit of height
local H = 1080 -- the screen's height in the canvas's units
local LEFT, TOP = 60, H - 66 -- where the columns start, and the middle of the top bar
local ROW, STEP = 68, 78 -- a player's row, and from a row to the next
local LINES, LINE = 3, 36 -- the chat lines shown, and their height
local BUTTON, GAP = 210, 16 -- the buttons at the bottom right: the host has three
local REFRESH = 4 -- seconds between two reads of the open rooms
local WHITE, DIM, FAINT, DARK = { 1, 1, 1, 1 }, { 1, 1, 1, 0.5 }, { 1, 1, 1, 0.08 }, { 0.02, 0.13, 0.17, 1 }
local GOLD, GREEN, RED = { 1, 0.82, 0.3, 1 }, { 0.6, 0.92, 0.55, 1 }, { 1, 0.5, 0.5, 1 }
local LEVEL = { EZ = { 0.29, 0.66, 0.29, 1 }, HD = { 0.23, 0.47, 0.75, 1 }, IN = { 0.77, 0.23, 0.2, 1 },
  AT = { 0.29, 0.29, 0.32, 1 } }

-- mp is the mod's state (init.lua), room what it can do: send, enter, join, and shown
return function(mp, room)
  local S = {}
  local canvas, width, font -- the canvas over the menu, as wide as the screen in its units
  local panel, parts -- the view shown ("list" or "room"), and its parts by name: { key =, root = }
  local pill -- the host's way back to the room while picking a chart
  local field -- the chat's text box
  local listing, rooms, polling -- the list is open, the rooms it shows (false when they can't be read), its timer
  local states -- each player's text on the right of their row, by id

  -- a text from the middle of its left side. given a width, it's cut where it ends
  local function text(parent, pos, size, value, colour, alignment, pivot, box)
    local t = kit.text(parent, "phigrospp-room-text", font, pos, { box or 0, box and size * 1.5 or 0 }, size, alignment or 3, pivot)
    t.text, t.color, t.supportRichText = value, colour or WHITE, false
    if box then t.horizontalOverflow, t.verticalOverflow = 0, 0 end -- Wrap, Truncate
    return t
  end

  local function icon(parent, pos, size, name, colour)
    local image = kit.rect(parent, "phigrospp-room-icon", pos, { size, size }, colour or WHITE)
    image.sprite = kit.icon(name)
    return image
  end

  local function tappable(shape, fn)
    shape.raycastTarget = true
    phigrospp.click(shape.gameObject:AddComponent(UE.UI.Button), fn)
  end

  -- a slanted bar from its top left corner with a text in its middle, which is left of its box's: its bottom leans
  local function plate(parent, pos, size, colour, fontSize, label, ink)
    local shape = kit.bar(parent, "phigrospp-room-plate", pos, size, colour)
    text(shape.transform, { (size[1] - size[2] * SLOPE) / 2, size[2] / 2 }, fontSize, label, ink, 4, { 0.5, 0.5 }) -- MiddleCenter
    return shape
  end

  -- a button, lit in a colour when given one. without fn it's only a label
  local function action(parent, pos, size, label, fn, lit)
    local shape = plate(parent, pos, { size, 76 }, lit or FAINT, 32, label, lit and DARK or fn and WHITE or DIM)
    if fn then tappable(shape, fn) end
    return shape
  end

  -- the back arrow of the top bar, in a square easier to tap than itself
  local function back(root, fn)
    tappable(kit.rect(root, "phigrospp-room-back", { 20, TOP }, { 130, 110 }, { 0, 0, 0, 0 }), fn)
    icon(root, { LEFT, TOP }, 56, "arrow-left")
  end

  -- a part of the panel, drawn again only when what it shows (its key) changed: scores come every second
  local function part(name, key, draw)
    local p = parts[name]
    if p and p.key == key then return end
    if p then UE.Object.Destroy(p.root.gameObject) end
    local root = UE.GameObject("phigrospp-room-" .. name):AddComponent(UE.RectTransform)
    root:SetParent(panel.transform, false)
    root.anchorMin, root.anchorMax, root.sizeDelta = { 0, 0 }, { 0, 0 }, { 0, 0 } -- the panel's bottom left corner
    parts[name] = { key = key, root = root }
    draw(root)
  end

  local function hide()
    if panel and il2cpp.alive(panel.transform) then panel.close() end
    panel, field = nil, nil
  end

  -- the canvas, made again in each scene, with the font of a text of that scene
  local function stage()
    if il2cpp.alive(canvas) then return end
    canvas, width = kit.screen("phigrospp-rooms", 32000)
    local chapters = UE.Object.FindObjectOfType(CS.ChapterSelector)
    font = chapters and chapters.nowLevel.font or UE.Object.FindObjectOfType(CS.SongSelector).songName.font
  end

  -- the panel of a view, made when it isn't the one shown: another view's slides out
  local function show(view)
    if panel and (panel.view ~= view or not il2cpp.alive(panel.transform)) then hide() end
    if panel then return end
    stage()
    panel = kit.panel(canvas, "phigrospp-room", nil, 0.93)
    panel.view, parts = view, {}
  end

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
    local named, name = kit.confirm({ title = "Create a room", input = "Room name", yes = "Next",
      message = "Name it in 24 characters at most, or leave it empty for a room named after you." })
    if not named then return end
    local made, password = kit.confirm({ title = "Protect it with a password?", input = "Password", yes = "Create",
      message = "Leave it empty for a room anyone can join, whose matches show on phigros.tools. With a password "
        .. "only the players who have it join, and its matches stay between them." })
    if made then room.enter({ t = "create", name = name, password = password }) end
  end

  local function drawList()
    part("top", "", function(root)
      back(root, function()
        closeList()
        S.refresh()
      end)
      text(root, { 220, TOP }, 56, "Rooms")
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

  local function kick(player)
    if kit.confirm({ title = ("Remove %s#%04d?"):format(player.name, player.number), yes = "Remove", danger = true,
        message = "They can't join this room again." }) then
      room.send({ t = "kick", player = player.id })
    end
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

  -- what a player's row says on its right: their score while a match is played, else their place in the last one
  local function state(r, p)
    if r.playing and (p.playing or p.score > 0) then return ("%07d"):format(p.score), p.playing and WHITE or DIM end
    if r.chart and not p.able then return "No chart", RED end
    for _, play in ipairs(r.last and r.last.plays or {}) do
      if play.player.id == p.player.id then return ("#%d  %07d"):format(play.rank, play.total), DIM end
    end
    return "", DIM
  end

  local function drawRoom(r)
    local me, column = nil, math.min(860, width * 0.5)
    local host = r.host == mp.me.id
    for _, p in ipairs(r.players) do
      if p.player.id == mp.me.id then me = p end
    end

    part("top", r.name, function(root)
      back(root, leave)
      local title = text(root, { 220, TOP }, 56, r.name)
      if r.locked then icon(root, { 244 + title.preferredWidth, TOP }, 40, "lock", DIM) end
      action(root, { width - 320, TOP + 38 }, 260, "Invite", function()
        phigrospp.share(("%s/rooms/%s"):format(phigrospp.site, r.id))
      end)
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

    local keys = { r.host }
    for i, p in ipairs(r.players) do
      keys[i + 1] = ("%s %s %s %s"):format(p.player.id, p.ready, p.able, p.player.avatar)
    end
    part("players", table.concat(keys, "\n"), function(root)
      states = {}
      for i, p in ipairs(r.players) do
        local own = p.player.id == mp.me.id
        local shape = kit.bar(root, "phigrospp-room-player", { LEFT + 20, H - 140 - (i - 1) * STEP }, { column, ROW },
          own and { 1, 1, 1, 0.18 } or FAINT)
        if p.player.id == r.host then icon(shape.transform, { 14, ROW / 2 }, 38, "crown", GOLD) end
        kit.avatar(shape.transform, "phigrospp-room-avatar", { 64, ROW / 2 }, 52, p.player.avatar)
        local name = text(shape.transform, { 132, ROW / 2 }, 34, p.player.name)
        text(shape.transform, { 142 + name.preferredWidth, ROW / 2 }, 26, ("#%04d"):format(p.player.number), DIM)
        if p.ready then icon(shape.transform, { column - 64, ROW / 2 }, 38, "check", GREEN) end
        states[p.player.id] = text(shape.transform, { column - 84, ROW / 2 }, 30, "", DIM, 5, { 1, 0.5 }) -- MiddleRight
        if host and not own then tappable(shape, function() kick(p.player) end) end
      end
    end)
    for _, p in ipairs(r.players) do
      local t = states[p.player.id]
      t.text, t.color = state(r, p)
    end

    local chart = r.chart
    part("chart", chart and ("%s %s %d %s %s"):format(chart.id, chart.level, chart.mods, me.able, r.playing) or tostring(host),
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
        local note = r.playing and "A match is being played" or not me.able and "You don't have this chart, so you sit "
          .. "this match out" or ""
        text(root, { x, y - 176 }, 28, note, me.able and DIM or RED, 3, nil, wide)
      end)

    -- the host starts once everyone who has the chart is ready
    local waiting = chart == nil
    for _, p in ipairs(r.players) do waiting = waiting or p.player.id ~= r.host and p.able and not p.ready end
    part("actions", ("%s %s %s %s %s"):format(host, r.playing, waiting, me.ready, me.able), function(root)
      if r.playing then return end
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

    local last = mp.chat[#mp.chat]
    part("chat", #mp.chat .. (last and last.text or ""), function(root)
      for i = 1, LINES do
        local said = mp.chat[#mp.chat - LINES + i]
        if said then
          text(root, { LEFT, 164 + (LINES - i + 0.5) * LINE }, 28, ("%s: %s"):format(said.name, said.text), WHITE, 3, nil, column)
        end
      end
    end)
  end

  -- what shows follows the room, the scene and what the player is doing: the mod calls it at each change
  function S.refresh()
    local r, shown = mp.room, room.shown()
    if r and listing then closeList() end
    local view = shown and (r and not mp.picking and "room" or listing and "list") or nil
    -- the song list reads the touches itself: it's turned off under the screen once it filled in and the game's
    -- loading screen, which waits for it, is gone, unless a page or a dialog did already
    local selector = scene() == "SongSelector" and not kit.paging() and not il2cpp.alive(kit.dialog)
      and UE.Object.FindObjectOfType(CS.SongSelector)
    if view and selector and (selector.SongItems._size == 0 or CS.Loading.IsActive) then return after(0.1, S.refresh) end
    if selector then selector.enabled = view == nil end
    if il2cpp.alive(pill) then UE.Object.Destroy(pill.gameObject) end
    if not view then
      hide()
      if not (shown and r) then return end
      stage()
      -- at the bottom, between the song list and its play button, where the chapter screen has nothing either
      local hint = "Play a chart to pick it, or tap here to go back"
      local measure = text(canvas, { 0, 0 }, 26, hint)
      local wide = measure.preferredWidth + 96
      UE.Object.Destroy(measure.gameObject)
      pill = plate(canvas, { width * 0.525 - wide / 2, 112 }, { wide, 70 }, GOLD, 26, hint, DARK)
      tappable(pill, function()
        mp.picking = false
        S.refresh()
      end)
      return
    end
    show(view)
    if view == "list" then drawList() else drawRoom(r) end
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
