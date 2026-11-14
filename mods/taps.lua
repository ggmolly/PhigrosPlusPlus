-- a diamond under every finger of the replay being watched, outlined so it shows on any background. a lifted finger
-- fades out where it ended, and a finger leaves a trail that fades behind it

local UE = CS.UnityEngine
local SIZE, OUTLINE, COUNT, FADE, TRAIL = 110, 14, 10, 0.35, 0.2 -- pixels, pixels, squares, seconds, seconds
-- by TouchPhase: began, moved, stationary, ended, canceled
local COLOURS = { [0] = { 1, 0.85, 0.3 }, { 1, 1, 1 }, { 1, 1, 1 }, { 1, 1, 1 }, { 1, 1, 1 } }
local SHADOW = { 0, 0, 0, 0.55 }
local HIDDEN = { 0, 0, 0, 0 }

local canvas, squares, segments = nil, nil, nil
local fading = {}
local trails = {} -- the points of each finger's path by id, oldest first: { x, y, at }

local function square(parent, size)
  local image = UE.GameObject("phigrospp-tap"):AddComponent(UE.UI.Image)
  image.transform:SetParent(parent, false)
  image.raycastTarget = false
  image.color = HIDDEN
  local t = image.transform
  t.anchorMin, t.anchorMax, t.sizeDelta, t.localEulerAngles = { 0, 0 }, { 0, 0 }, { size, size }, { 0, 0, 45 }
  return image
end

-- an overlay canvas with no scaler, so positions are screen pixels
local function build()
  local go = UE.GameObject("phigrospp-taps")
  canvas = go:AddComponent(UE.Canvas)
  canvas.renderMode = 0 -- ScreenSpaceOverlay
  canvas.sortingOrder = 32767
  squares, segments = {}, {}
  for i = 1, COUNT do squares[i] = { shadow = square(go.transform, SIZE + OUTLINE), fill = square(go.transform, SIZE) } end
end

-- the segments are drawn under the squares, a new one goes to the back
local function segment(i)
  if not segments[i] then
    segments[i] = square(canvas.transform, 1)
    segments[i].transform:SetAsFirstSibling()
  end
  return segments[i]
end

local function show(s, x, y, colour, alpha)
  s.shadow.color, s.fill.color = { SHADOW[1], SHADOW[2], SHADOW[3], SHADOW[4] * alpha }, { colour[1], colour[2], colour[3], 0.9 * alpha }
  s.shadow.transform.anchoredPosition, s.fill.transform.anchoredPosition = { x, y }, { x, y }
end

on("update", function()
  local list = replaying() and touches() or {}
  local t = now()
  for _, touch in ipairs(list) do
    if touch.phase == 3 or touch.phase == 4 then fading[#fading + 1] = { x = touch.x, y = touch.y, at = t } end
  end
  for i = #fading, 1, -1 do
    if t - fading[i].at > FADE then table.remove(fading, i) end
  end
  for _, touch in ipairs(list) do
    if touch.phase == 0 or not trails[touch.id] then trails[touch.id] = {} end
    local points = trails[touch.id]
    points[#points + 1] = { x = touch.x, y = touch.y, at = t }
  end
  for id, points in pairs(trails) do
    while points[1] and t - points[1].at > TRAIL do table.remove(points, 1) end
    if not points[1] then trails[id] = nil end
  end
  if not il2cpp.alive(canvas) then
    if #list == 0 and #fading == 0 and not next(trails) then return end
    build()
  end
  local drawn = 0
  for _, points in pairs(trails) do
    for i = 2, #points do
      local a, b = points[i - 1], points[i]
      local fade, dx, dy = 1 - (t - b.at) / TRAIL, b.x - a.x, b.y - a.y
      drawn = drawn + 1
      local image = segment(drawn)
      image.color = { 1, 1, 1, 0.5 * fade }
      local rect = image.transform
      rect.sizeDelta, rect.anchoredPosition = { math.sqrt(dx * dx + dy * dy), SIZE * 0.5 * fade }, { (a.x + b.x) / 2, (a.y + b.y) / 2 }
      rect.localEulerAngles = { 0, 0, math.deg(math.atan(dy, dx)) }
    end
  end
  for i = drawn + 1, #segments do segments[i].color = HIDDEN end
  local used = 0
  for _, touch in ipairs(list) do
    if touch.phase ~= 3 and touch.phase ~= 4 and used < COUNT then
      used = used + 1
      show(squares[used], touch.x, touch.y, COLOURS[touch.phase], 1)
    end
  end
  for _, lifted in ipairs(fading) do
    if used < COUNT then
      used = used + 1
      show(squares[used], lifted.x, lifted.y, COLOURS[3], 1 - (t - lifted.at) / FADE)
    end
  end
  for i = used + 1, COUNT do squares[i].shadow.color, squares[i].fill.color = HIDDEN, HIDDEN end
end)
