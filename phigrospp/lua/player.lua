-- the replay player: a seek bar and restart, -5 s, play/pause, +5 s and speed buttons over a shade at the bottom. it
-- reads the real touches, the game only sees the recorded ones. a tap shows it, another one away from it hides it, and
-- it hides by itself 3 s after the last touch unless paused

local UE = CS.UnityEngine
local Input, Screen = UE.Input, UE.Screen
local replay = phigrospp.replay
local SPEEDS = { 0.25, 0.5, 1, 2, 4, 16 }
local SHOWN_FOR, JUMP = 3, 5 -- seconds

local kit = phigrospp.ui
local rect, icon = kit.rect, kit.icon

local ui -- the player of the current song, rebuilt with each song scene
local shownUntil, dragging = 0, nil
-- the goods (blue, like in the game), bads and misses of each replay watched, by path: { frame, good } marked on the
-- seek bar where they happened. they fill in as the replay plays or seeks, and stay for the next time
local MARK = { [true] = { 0.63, 0.88, 1, 1 }, [false] = { 1, 0.36, 0.36, 1 } }
local marks = {}

local function frameAt(t)
  local frames = replay.state().frames
  local low, high = 1, #frames
  while low < high do
    local mid = (low + high) // 2
    if frames[mid].t < t then low = mid + 1 else high = mid end
  end
  return low
end

-- text in the score's font
local function label(parent, name, pos, size, fontSize, alignment, pivot)
  local font = UE.Object.FindObjectOfType(CS.ScoreControl).score.font
  return kit.text(parent, name, font, pos, size, fontSize, alignment, pivot)
end

-- a screen space canvas over the song, under the taps
local function overlay(name) return kit.overlay(name, 32766) end

-- "Replay", with whose it is when known
local function title()
  local by = replay.by()
  return by and ("Replay (%s)"):format(by) or "Replay"
end

-- the "Replay" mark stays right of the cross (in the game's UI, it moves with it), the controls fade in and out
local function build()
  local u, width = Screen.height / 1080, Screen.width
  local cross = replay.cross()
  local mark = label(cross, "phigrospp-replay-text", { cross.rect.m_Width + 24, cross.rect.m_Height / 2 }, { 0, 0 }, 40, 3,
    { 0, 0.5 }) -- MiddleLeft
  mark.text = title()
  local go = overlay("phigrospp-player")
  local p = { group = go:AddComponent(UE.CanvasGroup), go = go, mark = mark.gameObject, buttons = {} }
  p.group.alpha = 0
  local parent = go.transform

  -- black at the bottom of the screen, fading out above the seek bar
  rect(parent, "phigrospp-shade", { 0, 170 * u }, { width, 340 * u }, { 0, 0, 0, 0.6 }).sprite =
    phigrospp.sprite(32, function(_, y) return y / 31 end)

  local barWidth, barY = width * 0.5, 230 * u
  p.bar = { x = (width - barWidth) / 2, y = barY, width = barWidth, reach = 50 * u }
  rect(parent, "phigrospp-seek", { p.bar.x, barY }, { barWidth, 8 * u }, { 1, 1, 1, 0.3 })
  p.fill = rect(parent, "phigrospp-seek-fill", { p.bar.x, barY }, { 0, 8 * u }, { 1, 1, 1, 0.9 })
  p.addMark = function(m)
    local x = p.bar.x + p.bar.width * m.frame / #replay.state().frames
    rect(parent, "phigrospp-seek-mark", { x - u, barY }, { 2 * u, 24 * u }, MARK[m.good])
  end
  for _, m in ipairs(marks[replay.state().path] or {}) do p.addMark(m) end

  local size, gap, rowY = 72 * u, 150 * u, 120 * u
  local names = { "skip-back", "rewind", "play", "fast-forward", "speed" }
  for i, name in ipairs(names) do
    local x = width / 2 + (i - (#names + 1) / 2) * gap
    local button = { name = name, x = x, y = rowY, reach = gap / 2 }
    if name == "speed" then
      button.text = label(parent, "phigrospp-speed", { x, rowY }, { gap, size }, 48 * u, 4, { 0.5, 0.5 }) -- MiddleCenter
    else
      button.image = rect(parent, "phigrospp-" .. name, { x - size / 2, rowY }, { size, size }, { 1, 1, 1, 1 })
      button.image.sprite = icon(name)
    end
    p.buttons[#p.buttons + 1] = button
  end
  return p
end

local function press(name)
  local state = replay.state()
  local now = state.frames[math.max(state.cursor, 1)].t
  if name == "play" then return replay.pause(not state.paused) end
  if name == "skip-back" then return replay.seek(1) end
  if name == "rewind" then return replay.seek(frameAt(now - JUMP)) end
  if name == "fast-forward" then return replay.seek(frameAt(now + JUMP)) end
  for i, speed in ipairs(SPEEDS) do
    if speed == state.speed then return replay.speed(SPEEDS[i % #SPEEDS + 1]) end
  end
end

local function seekFraction(x)
  local bar = ui.bar
  return math.max(0, math.min(1, (x - bar.x) / bar.width))
end

-- a touch starting on the bar drags the seek, which happens when it's lifted. while hidden a tap only shows the player,
-- while shown a tap away from it hides it
local function handle(touch)
  local x, y, phase = touch.m_Position.x, touch.m_Position.y, touch.m_Phase
  if touch.m_FingerId == dragging then
    if phase == 3 or phase == 4 then -- Ended, Canceled
      dragging = nil
      local frames = replay.state().frames
      replay.seek(math.floor(seekFraction(x) * (#frames - 1)) + 1)
    end
    ui.preview = seekFraction(x)
    return
  end
  if phase ~= 0 then return end -- Began
  local visible = now() < shownUntil
  shownUntil = now() + SHOWN_FOR
  if not visible then return end
  local bar = ui.bar
  if math.abs(y - bar.y) < bar.reach and x > bar.x - bar.reach and x < bar.x + bar.width + bar.reach then
    dragging, ui.preview = touch.m_FingerId, seekFraction(x)
    return
  end
  for _, button in ipairs(ui.buttons) do
    if math.abs(x - button.x) < button.reach and math.abs(y - button.y) < button.reach then
      press(button.name)
      -- paused, the player stays until a tap hides it
      if button.name == "play" and replay.state().paused then shownUntil = math.huge end
      return
    end
  end
  shownUntil = 0
end

-- while the replay is judged before it plays (see replay.lua), the song's background covers it, dimmed. the game
-- loads that background in the meantime, the cover stays dark until then
local cover, art, painted
local function judging()
  local width, height, u = Screen.width, Screen.height, Screen.height / 1080
  if not il2cpp.alive(cover) then
    cover, painted = overlay("phigrospp-judging"), false
    art = rect(cover.transform, "phigrospp-judging-background", { width / 2, height / 2 }, { width, height },
      { 0.08, 0.08, 0.08, 1 }, { 0.5, 0.5 })
    label(cover.transform, "phigrospp-judging-text", { width / 2, height / 2 }, { 0, 0 }, 56 * u, 4,
      { 0.5, 0.5 }).text = "Preparing..." -- MiddleCenter
  end
  if painted then return end
  local sprite = UE.Object.FindObjectOfType(CS.LevelControl).background:GetComponent(UE.SpriteRenderer).sprite
  if not sprite then return end
  local size = sprite.rect
  local scale = math.max(width / size.m_Width, height / size.m_Height) -- fills the screen, cropped like the game's
  art.sprite, art.color, painted = sprite, { 0.4, 0.4, 0.4, 1 }, true
  art.transform.sizeDelta = { size.m_Width * scale, size.m_Height * scale }
end

on("update", function()
  local state = replay.state()
  if state and state.judging then return judging() end
  if not state or state.ended then
    if ui and il2cpp.alive(ui.go) then
      ui.go:SetActive(false)
      ui.mark:SetActive(false)
    end
    return
  end
  if not ui or not il2cpp.alive(ui.go) then ui, dragging = build(), nil end
  ui.mark:SetActive(true)
  -- the game's pause menu takes the taps while it's open
  ui.go:SetActive(not replay.halted())
  if replay.halted() then
    shownUntil, dragging = 0, nil
    return
  end
  for i = 0, Input.touchCount - 1 do handle(Input.GetTouch(i)) end
  local shown = now() < shownUntil or dragging ~= nil
  ui.group.alpha = ui.group.alpha + ((shown and 1 or 0) - ui.group.alpha) * 0.25
  local fraction = dragging and ui.preview or (state.target or state.cursor) / #state.frames
  ui.fill.transform.sizeDelta = { ui.bar.width * fraction, ui.fill.transform.sizeDelta.y }
  if ui.paused ~= state.paused then
    ui.paused = state.paused
    ui.buttons[3].image.sprite = icon(state.paused and "play" or "pause")
  end
  if ui.speed ~= state.speed then
    ui.speed = state.speed
    ui.buttons[5].text.text = ("%g×"):format(state.speed)
  end
end)

-- the result screen of a replay says it's one, right of its retry button
on("scene", function(name)
  if name ~= "LevelOver" or replay.by() == nil then return end
  local over = UE.Object.FindObjectOfType(CS.LevelOverControl)
  local retry = over.retryButton:GetComponent(UE.RectTransform)
  kit.text(retry, "phigrospp-replay-text", over.songsName.font, { retry.rect.m_Width + 24, retry.rect.m_Height / 2 },
    { 0, 0 }, 40, 3).text = title() -- MiddleLeft
end)

-- a chord's notes judged alike at once share one mark
on("hit", function(hit)
  local state = replay.state()
  if not state or hit.judgement == "perfect" then return end
  local list = marks[state.path] or {}
  marks[state.path] = list
  local m = { frame = math.max(state.cursor, 1), good = hit.judgement == "good" }
  for _, seen in ipairs(list) do
    if seen.frame == m.frame and seen.good == m.good then return end
  end
  list[#list + 1] = m
  if ui and il2cpp.alive(ui.go) then ui.addMark(m) end
end)
