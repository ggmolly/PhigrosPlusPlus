-- the friends' screen, over the menus: the player's friends and the requests, those online first with what they play.
-- its top bar goes to the rooms and adds a friend, the bottom right says how the player shows to them (invisible or
-- not, their plays watched or not)

local UE = CS.UnityEngine
local kit = phigrospp.ui
local SLOPE = CS.SettingItemsManager.InverseSlope -- the game's slant: sideways per unit of height
local ROW, STEP = 88, 104 -- a friend's row, and from a row to the next
local C = kit.colours
local WHITE, DIM, FAINT, GOLD, GREEN, RED = C.white, C.dim, C.faint, C.gold, C.green, C.red

-- F is the mod (init.lua): its friends and what it does with them
return function(F)
  local S = {}
  local V = kit.view("phigrospp-friends")
  local TOP = V.top
  local text, action, part = V.text, V.action, V.part
  local open -- whether the player opened it
  local selector -- the song list turned off under it

  local function add()
    local ok, typed = kit.confirm({ title = "Add a friend", input = "Name#0042", yes = "Add",
      message = "Type your friend's name and number, as the bottom of their friends' screen shows them." })
    if ok and typed:find("%S") then F.add(typed) end
  end

  -- what a row says on its right
  local function state(f)
    if f.state == "incoming" then return "Wants to be your friend", GOLD end
    if f.state == "outgoing" then return "Request sent", DIM end
    if not f.online then return "Offline", DIM end
    if not f.playing then return "Online", GREEN end
    local chart = song(f.playing.id)
    return ("Playing %s  %s"):format(chart and chart.name or "a custom chart", f.playing.level), f.watch and GREEN or WHITE
  end

  -- a request is answered or taken back, a friend's play watched, a friend removed
  local function tapped(f)
    local id, choices = f.player.id, {}
    if f.state == "incoming" then
      choices[1] = { icon = "check", label = "Accept", colour = GREEN, value = F.add }
      choices[2] = { icon = "x", label = "Decline", colour = RED, value = F.remove }
    elseif f.state == "outgoing" then
      choices[1] = { icon = "x", label = "Take back", colour = RED, value = F.remove }
    else
      if f.watch then choices[1] = { icon = "eye", label = "Watch", colour = GREEN, value = F.watch } end
      choices[#choices + 1] = { icon = "trash-2", label = "Remove", colour = RED, value = F.remove }
    end
    local chosen = kit.choose(("%s#%04d"):format(f.player.name, f.player.number), choices)
    if chosen == F.watch then return F.watch(f) end
    if chosen then chosen(id) end
  end

  local function draw()
    local width, tag = V.width, phigrospp.tag()
    part("top", tostring(tag), function(root)
      V.back(root, S.close)
      V.titles(root, { "Rooms", "Friends" }, "Friends", function()
        S.close()
        F.rooms()
      end)
      if not tag then
        return text(root, { width / 2, V.height / 2 }, 44, "Friends need a phigros.tools profile, turn on Sync in the "
          .. "settings", DIM, 4, { 0.5, 0.5 }) -- MiddleCenter
      end
      action(root, { width - 360, TOP + 38 }, 300, "Add a friend", add)
      text(root, { V.left, 120 }, 28, ("Your friends add you as %s"):format(tag), DIM)
    end)
    if not tag then return end
    -- how the player shows to their friends
    part("status", ("%s %s"):format(F.invisible(), F.spectating()), function(root)
      local _, wide = V.checkbox(root, { width - V.left, 120 }, "Allow spectating", F.spectating(),
        function() F.flip(F.spectating) end)
      V.checkbox(root, { width - V.left - wide - 48, 120 }, "Appear invisible", F.invisible(),
        function() F.flip(F.invisible) end)
    end)
    local list, keys = F.friends or {}, { tostring(F.connected()) }
    for i, f in ipairs(list) do
      local playing = f.playing or {}
      keys[i + 1] = ("%s %s %s %s %s %s %s"):format(f.player.id, f.player.name, f.player.avatar, f.state, f.online,
        playing.play, f.watch)
    end
    part("list", table.concat(keys, "\n"), function(root)
      if #list == 0 then
        local why = not F.connected() and "phigros.tools can't be reached"
          or F.friends and "Add a friend with their name and number to see when they play" or ""
        return text(root, { width / 2, V.height / 2 }, 44, why, DIM, 4, { 0.5, 0.5 }) -- MiddleCenter
      end
      local rows = kit.list(root, "phigrospp-friends-list", { 0, 180 }, { width, TOP - 264 }, math.floor(width * 0.7))
      for i, f in ipairs(list) do
        local y, lit = (i - 1) * STEP, f.online or f.state == "incoming"
        local shape = kit.bar(rows.rows, "phigrospp-friends-row", { -y * SLOPE, -y }, { rows.width, ROW }, FAINT)
        local avatar = kit.avatar(shape.transform, "phigrospp-friends-avatar", { 40, ROW / 2 }, 64, f.player.avatar)
        if not lit then avatar.color = DIM end
        local name = text(shape.transform, { 128, ROW / 2 }, 40, f.player.name, lit and WHITE or DIM)
        text(shape.transform, { 138 + name.preferredWidth, ROW / 2 }, 30, ("#%04d"):format(f.player.number), DIM)
        local says, colour = state(f)
        text(shape.transform, { rows.width - 48, ROW / 2 }, 30, says, colour, 5, { 1, 0.5 }, rows.width * 0.5) -- MiddleRight
        V.tappable(shape, function() tapped(f) end)
      end
      rows.content.sizeDelta = { 0, #list * STEP + 32 }
    end)
  end

  -- what shows follows the friends and the scene: the mod calls it at each change
  function S.refresh()
    if not open then return V.hide() end
    V.show("friends")
    draw()
  end

  -- the rooms' screen leaves its place while this one shows ("friends" tells it)
  function S.showing() return open == true end

  function S.open()
    open = true
    phigrospp.emit("friends")
    F.wake()
    -- the song list reads the touches itself: it's off under the screen, unless a page turned it off already
    selector = scene() == "SongSelector" and not kit.paging() and UE.Object.FindObjectOfType(CS.SongSelector) or nil
    S.refresh()
  end

  function S.close()
    if not open then return end
    open = false
    phigrospp.emit("friends")
    if il2cpp.alive(selector) then selector.enabled = true end
    S.refresh()
  end

  -- the rooms turn the song list back on when theirs changes
  on("update", function()
    if open and il2cpp.alive(selector) then selector.enabled = false end
  end)

  return S
end
