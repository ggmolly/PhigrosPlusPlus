-- provisional grade and accuracy under the score, osu! style hit error bar at the bottom

local UE = CS.UnityEngine

-- same colours as phigros.tools (web/src/components/primitives.tsx)

local function hex(h)
  return { tonumber(h:sub(2, 3), 16) / 255, tonumber(h:sub(4, 5), 16) / 255, tonumber(h:sub(6, 7), 16) / 255, 1 }
end

local PHI, FC, WHITE = hex("#f5f25b"), hex("#4f8df5"), { 1, 1, 1, 1 }

-- windows in ms, read from the game when a song starts
local JUDGE = {
  perfect = { colour = hex("#ffeca0") },
  good = { colour = hex("#a2eeff") },
  bad = { colour = hex("#e2696d") },
}

-- sizes are in canvas units (the score font is 50) or relative to the score font size
local LAYOUT = {
  infoSize = 0.55,
  infoGap = 0.12,
  phiLift = 0.12, -- φ sits low in this font
  barLength = 420,
  barThickness = 3,
  tickLength = 16,
  tickThickness = 3,
  ticks = 50, -- osu! max_concurrent_judgements
}

local function place(component, anchor, pos, size)
  local t = component.transform
  t.anchorMin = anchor
  t.anchorMax = anchor
  t.pivot = anchor
  t.anchoredPosition = pos
  t.sizeDelta = size
  return t
end

-- a plain rectangle: an Image without sprite
local function rectangle(parent, layer, name, colour, pos, size)
  local go = UE.GameObject(name)
  go.layer = layer
  local image = go:AddComponent(UE.UI.Image)
  image.transform:SetParent(parent, false)
  image.raycastTarget = false
  image.color = colour
  return image, place(image, { 0.5, 0.5 }, pos, size)
end

-- a copy of the score text next to it, so it keeps the score's font and rect
local function cloneText(score, name, fontSize, pos)
  local text = UE.Object.Instantiate(score, score.transform.parent, false)
  text.gameObject.name = name
  text.fontSize = fontSize
  text.horizontalOverflow = 1 -- Overflow
  text.verticalOverflow = 1
  text.raycastTarget = false
  text.transform.anchoredPosition = pos
  return text
end

-- the biggest RectTransform above the score is the whole HUD area
local function canvasOf(score)
  local best, bestArea = nil, -1
  local t = score.transform.parent
  while t and il2cpp.classof(t) == UE.RectTransform do
    local rect = t.rect
    if rect.m_Width * rect.m_Height > bestArea then best, bestArea = t, rect.m_Width * rect.m_Height end
    t = t.parent
  end
  return best
end

local showGrade = setting("Grade preview", true)
local showAccuracy = setting("Accuracy", true)
local showBar = setting("Timing bar", true)
local hud
local pending = {}
-- reused for every tick, every frame: the bridge copies their values into the game
local tickColour, tickSize = { 0, 0, 0, 0 }, { LAYOUT.tickThickness, 0 }

-- the parts are picked when a song starts, settings can't change during one
local function buildHud(owner, score)
  local judge = CS.JudgeControl
  JUDGE.perfect.window, JUDGE.good.window = judge.PerfectTimeRange * 1000, judge.GoodTimeRange * 1000
  JUDGE.bad.window = judge.BadTimeRange * 1000
  local layer, size, alignment = score.gameObject.layer, score.fontSize, score.alignment
  local scorePos = score.transform.anchoredPosition
  -- TextAnchor is row * 3 + column, the line goes under the score whatever its vertical anchor
  local scoreMid = ({ -size / 2, 0, size / 2 })[alignment // 3 + 1]
  local infoSize = math.floor(size * LAYOUT.infoSize + 0.5)
  local infoY = scorePos.y + scoreMid - size / 2 - size * LAYOUT.infoGap - infoSize / 2
  local h = { owner = owner, scoreRight = scorePos.x, infoY = infoY, infoSize = infoSize }

  if showAccuracy() then h.acc = cloneText(score, "phigrospp-acc", infoSize, { scorePos.x, infoY }) end
  if showGrade() then
    h.grade = cloneText(score, "phigrospp-grade", infoSize, { scorePos.x, infoY })
    h.grade.text = ""
  end
  if not showBar() then return h end

  -- the bar sits as far from the bottom as the score is from the top, on the song title's line
  local canvas = canvasOf(score)
  local barY = -canvas:InverseTransformPoint(score.transform.position).y
  local function x(ms) return math.max(-1, math.min(1, ms / JUDGE.bad.window)) * LAYOUT.barLength / 2 end
  for _, kind in ipairs({ "bad", "good", "perfect" }) do
    rectangle(canvas, layer, "phigrospp-bar-" .. kind, JUDGE[kind].colour, { 0, barY },
      { x(JUDGE[kind].window) * 2, LAYOUT.barThickness })
  end
  rectangle(canvas, layer, "phigrospp-bar-centre", WHITE, { 0, barY }, { 2, LAYOUT.tickLength * 0.6 })
  local ticks = {}
  for i = 1, LAYOUT.ticks do
    local image, rect = rectangle(canvas, layer, "phigrospp-bar-tick", { 1, 1, 1, 0 }, { 0, barY },
      { LAYOUT.tickThickness, 0 })
    ticks[i] = { image = image, rect = rect, born = 0, live = false }
  end
  local arrowY = barY - LAYOUT.tickLength * 0.75
  local _, arrow = rectangle(canvas, layer, "phigrospp-bar-average", WHITE, { 0, arrowY }, { 7, 7 })
  arrow.localEulerAngles = { 0, 0, 45 }
  h.ticks, h.next, h.x, h.barY = ticks, 1, x, barY
  h.arrow, h.arrowY, h.arrowX, h.average, h.lastFrame = arrow, arrowY, 0, 0, now() * 1000
  return h
end

local function outQuint(t) return 1 - (1 - t) ^ 5 end

-- osu! BarHitErrorMeter: ticks fade in over 100 ms, then fade and shrink over 5 s
local function updateBar(time)
  if #pending > 0 then
    for _, event in ipairs(pending) do
      local tick = hud.ticks[hud.next]
      hud.next = hud.next % #hud.ticks + 1
      tick.born, tick.colour, tick.live = time, JUDGE[event.kind].colour, true
      tick.rect.anchoredPosition = { hud.x(event.ms), hud.barY }
      hud.average = hud.average * 0.9 + event.ms * 0.1
    end
    pending = {}
  end
  for _, tick in ipairs(hud.ticks) do
    if tick.live then
      local age, alpha, length = time - tick.born, 0, 0
      if age < 100 then
        alpha, length = 0.6 * outQuint(age / 100), outQuint(age / 100)
      elseif age < 5100 then
        local t = (age - 100) / 5000
        alpha, length = 0.6 * (1 - t), 1 - t ^ 5
      else
        tick.live = false
      end
      tickColour[1], tickColour[2], tickColour[3], tickColour[4] = tick.colour[1], tick.colour[2], tick.colour[3], alpha
      tickSize[2] = LAYOUT.tickLength * length
      tick.image.color = tickColour
      tick.rect.sizeDelta = tickSize
    end
  end
  -- frame rate independent easing towards the average
  hud.arrowX = hud.arrowX + (hud.x(hud.average) - hud.arrowX) * (1 - math.exp(-(time - hud.lastFrame) / 160))
  hud.lastFrame = time
  local shown = math.floor(hud.arrowX * 10 + 0.5)
  if shown ~= hud.arrowShown then
    hud.arrowShown = shown
    hud.arrow.anchoredPosition = { hud.arrowX, hud.arrowY }
  end
end

local function refresh(self)
  local score = self.score
  if not hud or hud.owner ~= self then
    pending = {}
    hud = buildHud(self, score)
  end

  local p, g, b, m = self.perfect, self.good, self.bad, self.miss
  local judged, fc = p + g + b + m, b + m == 0
  local exact = judged > 0 and (p + 0.65 * g) / judged or 1
  local accuracy = math.floor(exact * 10000) -- in hundredths of a percent, as shown
  -- the grade if the rest of the chart goes like it went so far
  local pace = 900000 * exact + (fc and 100000 or 100000 * self.maxcombo / judged)
  local rank = judged > 0 and grade(math.floor(pace + 0.5), fc) or ""

  if accuracy ~= hud.accuracy or rank ~= hud.rank then
    hud.accuracy, hud.rank = accuracy, rank
    if hud.acc then hud.acc.text = ("%.2f%%"):format(accuracy / 100) end
    if hud.grade then
      local lift = rank == "φ" and hud.infoSize * LAYOUT.phiLift or 0
      local right = hud.acc and hud.scoreRight - hud.acc.preferredWidth - hud.infoSize * 0.35 or hud.scoreRight
      hud.grade.text = rank
      hud.grade.color = rank == "φ" and PHI or fc and FC or WHITE
      hud.grade.transform.anchoredPosition = { right, hud.infoY + lift }
    end
  end
  if hud.ticks then updateBar(now() * 1000) end
end

hook(CS.ScoreControl, "Update", { after = refresh })

-- judgeTime is the signed hit offset in seconds, 0 for drags and flicks
for method, kind in pairs({ Perfect = "perfect", Good = "good", Bad = "bad" }) do
  hook(CS.ScoreControl, method, {
    before = function(_, _, judgeTime)
      if hud and hud.ticks and judgeTime ~= 0 then
        pending[#pending + 1] = { kind = kind, ms = judgeTime * 1000 }
      end
    end,
  })
end
