-- a SKIP pill at the bottom right of a song: over a long intro it jumps to just before the first note shows, after
-- the last note to the end of the music, where the game ends the song. a replay makes the jumps its play made

local UE = CS.UnityEngine
local Screen = UE.Screen
local kit = phigrospp.ui

local enabled = setting("SKIP button", false)

local INTRO = 3 -- seconds before the first note that make an intro worth skipping
local LEAD = 0.3 -- seconds left before the first note shows
local FALLBACK = 1.5 -- seconds left before the first note when nothing says where it shows
local OUTRO = 1.5 -- seconds of music left that make an ending worth skipping
local REACH = 1.1 -- screen heights around its line where a note may be on screen, lines turn and move
local STEP = 0.05 -- seconds between the moments looked at

local level, pill, shape
local intro, left -- where a tap in the intro goes (nil once past it), and the notes not judged yet

-- when the first of the chart's early notes comes onto the screen: a note is drawn its floor position minus its
-- line's, times its speed, times 0.6 screen heights away from the line, which moves through its speed events
local function entrance(first)
  local chart = level.levelInformation
  local sorted, lines, byLine = chart.chartNoteSortByTime, {}, {}
  for i = 0, sorted._size - 1 do
    local note = sorted._items[i]
    if note.realTime > first + INTRO then break end
    local line = byLine[note.judgeLineIndex]
    if not line then
      local data = chart.judgeLineList._items[note.judgeLineIndex]
      local unit, events = 1.875 / data.bpm, data.speedEvents -- seconds per unit of an event's time
      line = { events = {}, notes = {}, at = 1 }
      for e = 0, events._size - 1 do
        local event = events._items[e]
        line.events[e + 1] = { start = event.startTime * unit, floor = event.floorPosition, speed = event.value }
      end
      byLine[note.judgeLineIndex], lines[#lines + 1] = line, line
    end
    -- a hold's speed is its length
    line.notes[#line.notes + 1] = { floor = note.floorPosition, speed = note.type == 3 and 1 or note.speed }
  end
  for t = 0, first, STEP do
    for _, line in ipairs(lines) do
      while line.events[line.at + 1] and line.events[line.at + 1].start <= t do line.at = line.at + 1 end
      local event = line.events[line.at]
      local floor = event.floor + event.speed * (t - event.start)
      for _, note in ipairs(line.notes) do
        local away = (note.floor - floor) * note.speed * 0.6
        if away >= -0.05 and away <= REACH then return t end
      end
    end
  end
end

local function build()
  local u = Screen.height / 1080
  local width, height = 176 * u, 60 * u
  local go = kit.overlay("phigrospp-skip", 32765)
  local group = go:AddComponent(UE.CanvasGroup)
  group.alpha = 0
  local x, y = Screen.width - 48 * u - width, 150 * u
  local n = math.floor(height)
  -- a disc with its middle stretched is a pill
  if not shape then
    local disc = phigrospp.sprite(n, function(dx, dy) return math.sqrt(dx * dx + dy * dy) - n / 2 end)
    shape = phigrospp.asset(UE.Sprite.Create(disc.texture, { 0, 0, n, n }, { 0.5, 0.5 }, 100, 0, 0,
      { n / 2, n / 2, n / 2, n / 2 }))
  end
  local back = kit.rect(go.transform, "phigrospp-skip-pill", { x, y }, { width, n }, { 0, 0, 0, 0.55 })
  back.sprite, back.type = shape, 1 -- Sliced
  local font = level.scoreControl.score.font
  kit.text(go.transform, "phigrospp-skip-text", font, { x + 30 * u, y }, { 0, 0 }, 30 * u, 3).text = "SKIP" -- MiddleLeft
  kit.rect(go.transform, "phigrospp-skip-icon", { x + width - 58 * u, y }, { 32 * u, 32 * u }, { 1, 1, 1, 1 }).sprite =
    kit.icon("fast-forward")
  return { group = group, alpha = 0, x = x, y = y, width = width, reach = height }
end

-- the notes left and where a tap in the intro goes, from the song's start
local function start()
  left, intro = playing().notes, nil
  local first = level.levelInformation.chartNoteSortByTime._items[0].realTime
  if first < INTRO then return end
  local shows = entrance(first)
  local target = shows and shows - LEAD or first - FALLBACK
  if target >= 1 then intro = target end
end

on("song", function()
  pill, level = nil, enabled() and UE.Object.FindObjectOfType(CS.LevelControl)
  if level then start() end
end)
on("restart", function() if level then start() end end)

on("hit", function() if level then left = left - 1 end end)
on("leave", function() level = nil end)

-- nothing is read from the game between the intro and the last note
on("update", function()
  if not level or not (intro or left == 0 or pill and pill.alpha > 0) then return end
  local progress = level.progressControl
  local time, target = progress.nowTime, nil
  -- a jump less than 0.25 s ahead isn't offered
  if intro and time > intro - 0.25 then intro = nil end
  if progress.isPlaying and progress.audioSource.CurrentStatus == 0 and not replaying() then
    local last = progress._audioLength - progress._offset - 0.02
    target = intro or left == 0 and last - time > OUTRO and last or nil
  end
  if not target and not pill then return end
  pill = pill or build()
  local shown = target and 1 or 0
  if pill.alpha ~= shown then
    pill.alpha = math.abs(shown - pill.alpha) < 0.01 and shown or pill.alpha + (shown - pill.alpha) * 0.25
    pill.group.alpha = pill.alpha
  end
  if not target then return end
  for _, touch in ipairs(touches()) do
    local dx, dy = touch.x - pill.x, math.abs(touch.y - pill.y)
    if touch.phase == 0 and dx > -pill.reach and dx < pill.width + pill.reach and dy < pill.reach then -- Began
      print(("skip: %.2f s to %.2f s"):format(time, target))
      intro = nil
      return phigrospp.jump(target)
    end
  end
end)
