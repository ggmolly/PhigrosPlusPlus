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

-- the "Replay" mark stays, the controls fade in and out
local function build()
  local u, width, height = Screen.height / 1080, Screen.width, Screen.height
  local mark = overlay("phigrospp-replay")
  label(mark.transform, "phigrospp-replay-text", { 110 * u, height - 64 * u }, { 300 * u, 60 * u }, 40 * u, 3,
    { 0, 0.5 }).text = "Replay" -- MiddleLeft
  local go = overlay("phigrospp-player")
  local p = { group = go:AddComponent(UE.CanvasGroup), go = go, mark = mark, buttons = {} }
  p.group.alpha = 0
  local parent = go.transform

  -- black at the bottom of the screen, fading out above the seek bar
  rect(parent, "phigrospp-shade", { 0, 170 * u }, { width, 340 * u }, { 0, 0, 0, 0.6 }).sprite =
    phigrospp.sprite(32, function(_, y) return y / 31 end)

  local barWidth, barY = width * 0.5, 230 * u
  p.bar = { x = (width - barWidth) / 2, y = barY, width = barWidth, reach = 50 * u }
  rect(parent, "phigrospp-seek", { p.bar.x, barY }, { barWidth, 8 * u }, { 1, 1, 1, 0.3 })
  p.fill = rect(parent, "phigrospp-seek-fill", { p.bar.x, barY }, { 0, 8 * u }, { 1, 1, 1, 0.9 })

  local size, gap, rowY = 72 * u, 150 * u, 120 * u
  local names = { "restart", "back", "play", "forward", "speed" }
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
  if name == "restart" then return replay.seek(1) end
  if name == "back" then return replay.seek(frameAt(now - JUMP)) end
  if name == "forward" then return replay.seek(frameAt(now + JUMP)) end
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

on("update", function()
  local state = replay.state()
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
