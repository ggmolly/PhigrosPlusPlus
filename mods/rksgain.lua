-- on the result screen, the player bar's RKS shows the one from before the play, then counts up to the new one in
-- amber with the gain under it. it writes the bar's own text in whatever precision it already shows (the game's 2
-- decimals, or 3 with the rks precision mod)

local UE = CS.UnityEngine

local enabled = setting("RKS gain on results", true)

-- the number sits on the bar's white box and needs a darker gold than the chip's text
local AMBER, GOLD, CHIP = { 0.86, 0.6, 0.16 }, { 1, 0.84, 0.5 }, { 0.05, 0.05, 0.07, 0.6 }
-- seconds: before counting (the screen slides in), the longest wait for the game's new RKS, the count, the warm up
-- to amber, the cool down once it landed, and the chip's fade in
local SETTLE, GIVE_UP, COUNT, WARM, COOL, CHIP_IN = 1.5, 6, 1.4, 0.3, 0.6, 0.45

local before -- the RKS when the last song ended, nil for a replay
local gain -- the bar being animated: { rank, from, to, start, ink, text, decimals, chip }

local function thousandths(v) return math.floor(v * 1000 + 0.5) end

local function easeOut(t)
  t = math.max(0, math.min(1, t))
  return 1 - (1 - t) ^ 3
end

-- what's in the text and isn't ours was written by the game or another mod: its decimals are the ones to keep
local function show(value)
  local current = gain.rank.text
  if current ~= gain.text then gain.decimals = #current:match("%.(%d+)") end
  gain.text = ("%." .. gain.decimals .. "f"):format(value)
  if gain.text ~= current then gain.rank.text = gain.text end
end

-- a dark slanted chip with "+0.012" under the digits, its right end on theirs. TextAnchor is row * 3 + column
local function chip(rank, delta)
  local ui, size, column, row = phigrospp.ui, rank.fontSize, rank.alignment % 3, rank.alignment // 3
  local label = UE.Object.Instantiate(rank, rank.transform, false) -- the rank's own font and look
  label.gameObject.name = "phigrospp-rks-gain-text"
  label.fontSize, label.alignment, label.raycastTarget = math.floor(size * 0.6 + 0.5), 4, false -- MiddleCenter
  label.text = ("+%d.%03d"):format(delta // 1000, delta % 1000)
  local h = size * 0.8
  local w, lean = label.preferredWidth + h, h * CS.SettingItemsManager.InverseSlope
  local bar = ui.bar(rank.transform, "phigrospp-rks-gain", { 0, 0 }, { w, h }, { 0, 0, 0, 0 })
  local t = bar.transform
  t.anchorMin = { column / 2, 1 - row / 2 }
  t.anchorMax = t.anchorMin
  label.transform:SetParent(t, false)
  label.transform.anchorMin, label.transform.anchorMax, label.transform.pivot = { 0.5, 0.5 }, { 0.5, 0.5 }, { 0.5, 0.5 }
  label.transform.anchoredPosition, label.transform.sizeDelta = { -lean / 2, 0 }, { w, h }
  -- the digits end preferredWidth right of the rect's left, half of it right of its middle, or at its right
  local x = rank.preferredWidth * (2 - column) / 2 - w
  local y = -size * (2 - row) / 2 - size * 0.15
  return { bar = bar, label = label, x = x, y = y, drop = size * 0.25 }
end

local function mix(a, b, u) return { a.r + (b[1] - a.r) * u, a.g + (b[2] - a.g) * u, a.b + (b[3] - a.b) * u, a.a } end

on("finish", function() before = enabled() and not replaying() and rks() or nil end)

hook(CS.PlayerBarControl, "Start", {
  after = function(bar)
    if before and UE.Object.FindObjectOfType(CS.LevelOverControl) then
      gain = { rank = bar.rank, from = before, start = now(), ink = bar.rank.color }
      show(before)
    end
    before = nil
  end,
})

on("update", function()
  if not gain then return end
  if not il2cpp.alive(gain.rank) then
    gain = nil
    return
  end
  local t = now() - gain.start
  if not gain.to then
    local current = rks()
    local delta = thousandths(current) - thousandths(gain.from)
    if delta < 1 or t < SETTLE then
      show(t < GIVE_UP and gain.from or current)
      if t >= GIVE_UP then gain = nil end
      return
    end
    gain.to, gain.start, gain.chip, t = current, now(), chip(gain.rank, delta), 0
  end

  show(gain.from + (gain.to - gain.from) * easeOut(t / COUNT))
  local warm = t < COUNT and easeOut(t / WARM) or 1 - easeOut((t - COUNT - 0.2) / COOL)
  gain.rank.color = mix(gain.ink, AMBER, warm)
  local c, a = gain.chip, easeOut((t - 0.15) / CHIP_IN)
  c.bar.color = { CHIP[1], CHIP[2], CHIP[3], CHIP[4] * a }
  c.label.color = { GOLD[1], GOLD[2], GOLD[3], a }
  c.bar.transform.anchoredPosition = { c.x, c.y + c.drop * (1 - a) }
  if t >= COUNT + 0.2 + COOL then
    show(gain.to)
    gain = nil -- the chip stays until the screen goes
  end
end)
