-- modifiers: a switch by the song list's Mirror one opens them, and the song then plays with the picked ones, like
-- osu!'s mods. such a play never touches the save: its replay and its total go to their own leaderboard on
-- phigros.tools, which judges the replay again with the same rules (phigrospp/lua/modifiers.lua and the site's
-- src/modifiers.ts), so what a modifier does here can't change without the site

local UE = CS.UnityEngine
local M, ui = phigrospp.modifiers, phigrospp.ui
local NORMAL = { 0.08, 0.18, 0.22 } -- the game's perfect, good and bad windows in seconds
local WINDOWS = { EZ = { 0.112, 0.252, 0.308 }, HR = { 0.057, 0.129, 0.157 } }
local SPEEDS = { HT = 0.75, NC = 1.5 }
local LANE, EDGE = 3, 7.5 -- Random moves the notes from -7.5 to 7.5 by lanes this wide
local AHEAD = 0.1 -- seconds of music Nightcore's drums are scheduled ahead
local BLACK = { 0, 0, 0, 1 }

local BY = {}
for _, m in ipairs(M.list) do BY[m.id] = m end

local level, mods, hooks = nil, 0, {}
local combo, broken = 0, false
local seen = {} -- a note's control -> what Hidden and Flashlight need of it, read once
local tint = { 1, 1, 1, 1 } -- reused for every note, every frame: the bridge copies it into the game
local drums -- Nightcore's: { sources = by kind, half = seconds per tick, next = the tick to schedule }
local dark -- Flashlight's: the Image dimming the level's background
local clips

local function has(id) return mods & BY[id].bit ~= 0 end

local function windows(w)
  local judge = CS.JudgeControl
  judge.PerfectTimeRange, judge.GoodTimeRange, judge.BadTimeRange = w[1], w[2], w[3]
end

-- Hidden and Flashlight ------------------------------------------------------------------------------------------

local function clamp(x) return math.max(0, math.min(1, x)) end

-- how visible a note is d screen heights from its line: Hidden fades it out as it comes, Flashlight shows it only
-- near the line, nearer as the combo grows
local function alpha(d)
  local a = 1
  if has("HD") then a = a * clamp((d - 0.15) / 0.15) end
  if has("FL") then
    local lit = combo >= 200 and 0.625 or combo >= 100 and 0.8125 or 1
    a = a * clamp((0.5 * lit - d) / (0.1 * lit))
  end
  return a
end

-- the note's distance to its line as the game places it: its floor position minus its line's, times its speed (a
-- hold's is its length, it comes at 1), times LevelInformation.Speed of the 10 units the screen is high
local function distance(control)
  local note = seen[control]
  if not note then
    local info = control.noteInfor
    note = { floor = info.floorPosition, line = info.judgeLineIndex // 2, floors = control.levelInformation.floorPositions,
      scale = (info.type == 3 and 1 or info.speed) * CS.LevelInformation.Speed / 10 }
    seen[control] = note
  end
  return (note.floor - note.floors[note.line]) * note.scale
end

-- the game only tints a note gone past its line (it fades while it's missed). Hidden keeps that one unseen too
local function fade(control)
  local d = distance(control)
  if d < 0 and not has("HD") then return end
  tint[4] = alpha(d)
  control._spriteRenderer.color = tint
end

-- a hold is seen as its head is, which sits on the line once its time came. a missed one keeps the game's dimming
local function fadeHold(control)
  if control.missed then return end
  tint[4] = alpha(math.max(0, distance(control)))
  control._holdHeadSpriteRenderer.color, control._holdSpriteRenderer.color = tint, tint
  control._holdEndSpriteRenderer1.color = tint
end

-- Nightcore's drums ----------------------------------------------------------------------------------------------

-- a kick, a hat and a clap, the samples the site makes too (its src/player/hit-sounds.ts): { seconds, seed of its
-- noise, the sample at t seconds from white noise through a high-pass (h) }
local RATE = 44100
local DRUMS = {
  kick = { 0.25, 0, function(t) return 0.9 * math.sin(2 * math.pi * (45 * t + 3.6 * (1 - math.exp(-t / 0.03)))) * math.exp(-t / 0.07) end },
  hat = { 0.05, 1, function(t, h) return 0.3 * h * math.exp(-t / 0.01) end },
  clap = { 0.2, 2, function(t, h)
    return 0.5 * h * (t < 0.022 and math.exp(-(t % 0.011) / 0.004) or math.exp(-(t - 0.022) / 0.045))
  end },
}
local BEAT = { "kick", "hat", "clap", "hat" } -- a half beat each

local function clip(name)
  local seconds, seed, sample = table.unpack(DRUMS[name])
  local noise, last, samples = M.random(seed), 0, {}
  for i = 0, math.floor(seconds * RATE) - 1 do
    local white = noise() / 2 ^ 31 - 1
    samples[i + 1], last = sample(i / RATE, (white - last) / 2), white
  end
  local made = phigrospp.asset(UE.AudioClip.Create("phigrospp-" .. name, #samples, 1, RATE, false))
  made:SetData(samples, 0)
  return made
end

-- a tick every half beat from the chart's start, at the first line's tempo (halved from 300)
local function drum()
  clips = clips or { kick = clip("kick"), hat = clip("hat"), clap = clip("clap") }
  local bpm = level.levelInformation.judgeLineList._items[0].bpm
  while bpm >= 300 do bpm = bpm / 2 end
  local go = UE.GameObject("phigrospp-drums")
  go.transform:SetParent(level.transform, false)
  drums = { sources = {}, half = 30 / bpm }
  for name, made in pairs(clips) do
    local source = go:AddComponent(UE.AudioSource)
    source.clip, source.playOnAwake = made, false
    drums.sources[name] = source
  end
end

-- the ticks coming within AHEAD are scheduled on the audio clock, where the music's time is exact. after anything
-- stopped or moved the music (a pause, a restart, a replay sought) it starts again from the tick coming
local function beat()
  local progress = level.progressControl
  local music = progress.audioSource.audioSource
  if not music.isPlaying then
    drums.next = nil
    return
  end
  local t, half = music.time - progress._offset, drums.half
  if not drums.next or (drums.next - 1) * half > t + AHEAD or drums.next * half < t then
    drums.next = math.max(0, math.ceil(t / half))
  end
  while drums.next * half - t < AHEAD do
    local source = drums.sources[BEAT[drums.next % 4 + 1]]
    source.volume = music.volume * 0.6
    source:PlayScheduled(UE.AudioSettings.dspTime + (drums.next * half - t) / music.pitch)
    drums.next = drums.next + 1
  end
end

-- the song ---------------------------------------------------------------------------------------------------------

-- Random: the chart's notes change lanes before the game lays it out, the same way each time it loads with the seed
on("chart", function(chart)
  local picked, seed = M.play()
  if picked & BY.RD.bit == 0 then return end
  local lanes, lines = M.lanes(seed), chart.judgeLineList
  for i = 0, lines._size - 1 do
    for _, side in ipairs({ "notesAbove", "notesBelow" }) do
      local notes = lines._items[i][side]
      for n = 0, notes._size - 1 do
        local note = notes._items[n]
        local x = note.positionX
        if x >= -EDGE and x < EDGE then
          local lane = (x + EDGE) // LANE
          note.positionX = x + (lanes[lane + 1] - lane) * LANE
        end
      end
    end
  end
end)

on("song", function()
  mods, combo, broken, seen, drums, dark = M.play(), 0, false, {}, nil, nil
  if mods == 0 then return end
  level = UE.Object.FindObjectOfType(CS.LevelControl)
  for id, w in pairs(WINDOWS) do
    if has(id) then
      windows(w)
      -- ProgressControl.Update sets the game's windows again every frame
      hooks[#hooks + 1] = hook(CS.ProgressControl, "Update", { after = function() windows(w) end })
    end
  end
  for id, speed in pairs(SPEEDS) do
    if has(id) then phigrospp.speed(speed) end
  end
  if has("NC") then drum() end
  if has("HD") or has("FL") then
    for _, kind in ipairs({ CS.ClickControl, CS.DragControl, CS.FlickControl }) do
      hooks[#hooks + 1] = hook(kind, "NoteMove", { after = fade })
    end
    hooks[#hooks + 1] = hook(CS.HoldControl, "NoteMove", { after = fadeHold })
  end
  if has("FL") then dark = level.levelInformation.backgroundBlack end
  -- the score shown is the total, the game writes its own again every frame
  local total, text = M.total, level.scoreControl.score
  hooks[#hooks + 1] = hook(CS.ScoreControl, "Update", {
    after = function(self) text.text = ("%07d"):format(total(math.floor(self._score + 0.5), mods)) end,
  })
  local name = UE.Object.FindObjectOfType(CS.LevelUICont).songsName.transform
  M.strip(name, mods, { 0, name.rect.m_Height + 12 }, 44, { 0, 0 })
end)

on("leave", function()
  for _, id in ipairs(hooks) do unhook(id) end
  hooks, level, seen, drums, dark = {}, nil, {}, nil, nil
  if mods ~= 0 then windows(NORMAL) end
  mods = 0
end)

on("restart", function() combo, broken = 0, false end)

-- Sudden Death ends the song when the combo breaks, Perfect starts it again at anything but a perfect. a hit comes
-- from inside the game's loop over its notes, so both wait for the frame's end
on("hit", function(hit)
  combo = hit.combo
  local lost = hit.judgement == "bad" or hit.judgement == "miss"
  broken = broken or has("SD") and lost or has("PF") and hit.judgement ~= "perfect"
end)

on("update", function()
  if not level then return end
  if drums then beat() end
  -- Flashlight plays in the dark, the game fades its own dimming in as the song starts
  if dark then dark.color = BLACK end
  if not broken or replaying() then return end
  broken = false
  if has("PF") then return phigrospp.restart() end
  phigrospp.leave()
end)

-- the result screen shows the total, with what gave it. its grade stays the score's
hook(il2cpp.class("LevelOverControl.<>c__DisplayClass43_0"), "<Start>g__SetResultInfo|2", {
  after = function(self)
    local picked = M.play()
    if picked == 0 then return end
    local over = self["<>4__this"]
    local score = over.scoreText
    score.text = ("%07d"):format(M.total(over.levelResultInfo.IntScore, picked))
    M.strip(score.transform, picked, { 0, score.transform.rect.m_Height + 12 }, 56, { 0, 0 })
  end,
})

-- the song list ------------------------------------------------------------------------------------------------------

local selector, strip, shown

-- the tiles, the two that can't go together in a column: easier and harder, slower and faster, ...
local GRID = { "EZ", "HT", "SD", "HD", "RD", "HR", "NC", "PF", "FL" }

-- whether the chart selected has effects of its own, which play without modifiers (see phigrospp/lua/modifiers.lua)
local function effects()
  return selector.SongItems._items[selector.nowSong].songInfo.levelMods._items[selector.nowLevel].levelMods._size > 0
end

local function open()
  if ui.paging() or selector.locked.activeSelf then return end
  if effects() then
    return ui.confirm({ title = "Modifiers", yes = "OK", no = false,
      message = "This song has effects of its own, so it plays without modifiers." })
  end
  local cells = {}
  for i, id in ipairs(GRID) do
    local m = BY[id]
    cells[i] = { icon = ui.icon(m.icon), label = m.name, colour = m.colour,
      on = function() return M.pick() & m.bit ~= 0 end,
      note = function() return m.percent == 100 and "" or M.multiplier(m.bit) end,
      tap = function() M.pick((M.pick() ~ m.bit) & ~m.excludes) end }
  end
  cells[#cells + 1] = { icon = ui.icon("x"), label = "Reset", colour = { 1, 1, 1, 1 },
    on = function() return false end, note = function() return "" end,
    tap = function() M.pick(0) end }
  selector.enabled = false -- the song list reads the touches itself
  ui.confirm({ title = "Modifiers", yes = "Done", no = false, grid = { cells = cells, columns = 5, height = 190 } })
  if il2cpp.alive(selector) then selector.enabled = true end
end

on("scene", function(name)
  selector, strip, shown = nil, nil, nil
  if name ~= "SongSelector" then return end
  selector = UE.Object.FindObjectOfType(CS.SongSelector)
  ui.switch("Modifiers", function() return M.pick() ~= 0 end, open)
end)

-- the picks show over Play, on a song that plays with them
on("update", function()
  if not selector or selector.SongItems._size == 0 then return end -- the list fills in after the scene starts
  local picked = effects() and 0 or M.pick()
  if shown == picked then return end
  shown = picked
  if strip then UE.Object.Destroy(strip.gameObject) end
  local play = selector.startButton.transform
  strip = M.strip(play.parent, shown, { 0, 0 }, 56, { 1, 0 })
  strip.anchorMin, strip.anchorMax = play.anchorMin, play.anchorMax
  local at, size, pivot = play.anchoredPosition, play.sizeDelta, play.pivot
  strip.anchoredPosition = { at.x + size.x * (1 - pivot.x) - 32, at.y + size.y * (1 - pivot.y) + 16 }
end)
