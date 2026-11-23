-- toast(message, options): a message at the bottom left of the screen in any scene, slanted like the game's bars. it
-- slides in, stays `seconds` (4 when not given, 10 at most) and slides out, or goes as soon as it's tapped. three show
-- at once, the newest on top, the next ones wait their turn. none shows over a song: they wait for it to end. one
-- saying what another on screen or waiting already says isn't made. options is the seconds, or { seconds =, icon = one of
-- phigrospp.ui.icon's or avatar = a player's (the game's key of it), tap = what a tap runs }. returns a function
-- dismissing it

local UE = CS.UnityEngine
local kit = phigrospp.ui
local FONT = "Source Han Sans & Saira Hybrid-Regular" -- the game's, loaded with its first menu
local SECONDS, LONGEST, SHOWN = 4, 10, 3
local HIGH, GAP, BOTTOM = 76, 12, 124 -- a one line toast, between two, and under the lowest: the chapter screen's news
local PAD, TEXT, WIDEST = 40, 30, 900 -- around the text, its size, and where it wraps
local ICON, AVATAR = 40, 56
local OFF = 60 -- how far past the screen's left edge a toast starts, so its slanted end never shows
local IN, OUT = 0.3, 0.2 -- seconds it takes to come and go
local waiting, shown = {}, {}
local canvas, font, looked

-- the game loads its font with a menu, toasts made before wait for it
local function ready()
  if il2cpp.alive(font) then return true end
  if looked and now() - looked < 0.5 then return false end
  looked = now()
  local fonts = UE.Resources.FindObjectsOfTypeAll(il2cpp.typeof(UE.Font))
  for i = 0, #fonts - 1 do
    if fonts[i].name == FONT then font = fonts[i] end
  end
  return il2cpp.alive(font)
end

local function leave(t) t.leaving = t.leaving or now() end

-- placed from its bottom left corner, the screen's edge: the bar starts before it and ends, slanted, after the text
local function show(t)
  if not il2cpp.alive(canvas) then
    canvas = kit.screen("phigrospp-toasts", 0)
    UE.Object.DontDestroyOnLoad(canvas.gameObject)
    -- under a dialog only. unity sorts a canvas when its order changes, and forgets it as the canvas is moved out
    -- of its scene
    canvas:GetComponent(UE.Canvas).sortingOrder = 32766
  end
  local root = UE.GameObject("phigrospp-toast"):AddComponent(UE.RectTransform)
  root:SetParent(canvas, false)
  root.anchorMin, root.anchorMax, root.pivot, root.sizeDelta = { 0, 0 }, { 0, 0 }, { 0, 0 }, { 0, 0 }
  local art = t.avatar and AVATAR or t.icon and ICON
  local left = PAD + (art and art + 20 or 0)
  local label = kit.text(root, "Text", font, { left, 0 }, { 0, 0 }, TEXT, 3) -- MiddleLeft
  label.text, label.supportRichText = t.message, false
  local wide = math.min(WIDEST, label.preferredWidth)
  label.horizontalOverflow, label.transform.sizeDelta = 0, { wide + 1, 0 } -- Wrap
  local high = math.max(HIGH, label.preferredHeight + 32)
  label.transform.anchoredPosition = { left, high / 2 }
  local lean = high * CS.SettingItemsManager.InverseSlope
  t.root, t.group, t.high, t.wide = root, root.gameObject:AddComponent(UE.CanvasGroup), high, left + wide + PAD
  local bar = kit.bar(root, "Bar", { -OFF, high }, { OFF + t.wide + lean, high }, { 0, 0, 0, 0.92 })
  bar.transform:SetAsFirstSibling()
  bar.raycastTarget = true
  phigrospp.click(bar.gameObject:AddComponent(UE.UI.Button), function()
    leave(t)
    if t.tap then t.tap() end
  end)
  if t.avatar then
    kit.avatar(root, "Avatar", { PAD, high / 2 }, AVATAR, t.avatar)
  elseif t.icon then
    kit.rect(root, "Icon", { PAD, high / 2 }, { ICON, ICON }, { 1, 1, 1, 1 }).sprite = kit.icon(t.icon)
  end
  t.left = kit.rect(root, "Left", { 0, 0 }, { t.wide - lean, 3 }, { 1, 1, 1, 0.5 }, { 0, 0 }).transform -- the time it has left
  t.start = now()
  shown[#shown + 1] = t
end

function toast(message, options)
  if type(options) ~= "table" then options = { seconds = options } end
  local seconds = options.seconds or SECONDS
  if seconds < 0 then error("toast: a toast can't stay less than 0 seconds", 2) end
  message = tostring(message)
  -- the same words are told once, whatever they come with: the toast already saying them is the one dismissed
  for _, list in ipairs({ shown, waiting }) do
    for _, t in ipairs(list) do
      if t.message == message and not t.leaving then return function() leave(t) end end
    end
  end
  local t = { message = message, seconds = math.min(seconds, LONGEST), icon = options.icon, avatar = options.avatar,
    tap = options.tap }
  waiting[#waiting + 1] = t
  return function() leave(t) end
end

-- whether a point of the screen (pixels) is on a toast, for what reads the touches itself
function kit.toasted(x, y)
  local scale = UE.Screen.height / 1080
  for _, t in ipairs(shown) do
    if x < t.wide * scale and y > t.y * scale and y < (t.y + t.high) * scale then return true end
  end
  return false
end

local function smooth(f) return f * f * (3 - 2 * f) end

on("update", function()
  if #waiting + #shown == 0 or not ready() then return end
  -- a song has the screen to itself: the toasts on it go as it starts, the others wait until it's left
  local song, staying = playing() ~= nil, 0
  for _, t in ipairs(shown) do
    if song then leave(t) end
    staying = staying + (t.leaving and 0 or 1)
  end
  while not song and staying < SHOWN and waiting[1] do
    local t = table.remove(waiting, 1)
    if not t.leaving then -- dismissed before its turn
      show(t)
      staying = staying + 1
    end
  end
  local time, y = now(), BOTTOM
  local eased = 1 - 0.75 ^ (UE.Time.unscaledDeltaTime * 60) -- a quarter of the way per 60 Hz frame
  for _, t in ipairs(shown) do
    local age = time - t.start
    if age >= t.seconds then leave(t) end
    t.gone = t.leaving and math.min(1, (time - t.leaving) / OUT) or 0
    -- it slides in from the left edge and back out, and down to its place as the ones under it go
    local there = smooth(math.min(1, age / IN)) * (1 - smooth(t.gone))
    t.y = t.y and t.y + (y - t.y) * eased or y
    t.root.anchoredPosition = { -(t.wide + t.high) * (1 - there), t.y }
    t.group.alpha, t.group.blocksRaycasts = there, not t.leaving
    t.left.localScale = { math.max(0, 1 - age / t.seconds), 1, 1 }
    if not t.leaving then y = y + t.high + GAP end
  end
  for i = #shown, 1, -1 do
    if shown[i].gone == 1 then UE.Object.Destroy(table.remove(shown, i).root.gameObject) end
  end
  -- the song list reads the touches itself, and would take a tap on a toast for one on the row under it: a finger on
  -- a toast counts as one that moved, which picks no row
  for i = 0, UE.Input.touchCount - 1 do
    local at = UE.Input.GetTouch(i).m_Position
    local selector = kit.toasted(at.x, at.y) and UE.Object.FindObjectOfType(CS.SongSelector)
    if selector then selector.moved = true end
  end
end)
