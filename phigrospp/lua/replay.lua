-- replays: every frame of a song keeps its touches, song time and delta time, and playback feeds them back one frame
-- per frame, so the game judges the same touches at the same times. a replay's result screen only shows, it never saves.
-- every play is kept, as replays/<song id>.<difficulty>/<unix time>.pigeon

local UE = CS.UnityEngine
local Input, Time, Screen, IO = UE.Input, UE.Time, UE.Screen, CS.System.IO
local DIR = phigrospp.root .. "/replays"
local ONLINE = phigrospp.root .. "/online" -- other players' replays downloaded to be watched, until the next load
local SIGNED = 96 -- phigros.tools keeps a replay with its player's key and signature after it
local file = phigrospp.replayfile
local SEEK_SPEED = 32 -- recorded frames per screen frame while seeking
local JUDGE_SPEED = 256 -- and while judging a replay before it plays

if IO.Directory.Exists(ONLINE) then IO.Directory.Delete(ONLINE, true) end

local record = setting("Record replays", true)

local level, mode
local armed, watchNext, resume -- the replay the next song start watches, and where a rewind's restart goes
local whose -- the name#number of the player of the replay started from the song list
local judged = {} -- the replays (by path) played through once since the game started, see on("song")
local recorded, events, kept -- recording, and the play just kept until its result screen compares it with the record
local playback, serving, hooks, simulating, enabled, cross, quit, leave -- watching

local function folder(id, difficulty) return ("%s/%s.%s"):format(DIR, id, difficulty) end

-- the result fields a replay keeps and compares when it's watched (accuracy is kept too, as an f32 for showing)
local RESULT = { "score", "maxcombo", "perfect", "good", "bad", "miss", "early", "late" }

local function readTouches()
  local list, all = {}, Input.touches
  for i = 0, #all - 1 do
    local t = all[i]
    list[i + 1] = { id = t.m_FingerId, phase = t.m_Phase, x = t.m_Position.x, y = t.m_Position.y }
  end
  return list
end

-- the touches of this frame, replayed ones while watching (none while the game pauses the replay or judges it first)
function touches()
  if not serving then return readTouches() end
  return level.progressControl.isPlaying and not playback.judging and serving.touches or {}
end

function replaying() return serving ~= nil end

local function hex(s) return (s:gsub(".", function(c) return ("%02x"):format(c:byte()) end)) end

local function getprop(name)
  local p = io.popen("getprop " .. name)
  local value = p:read("l")
  p:close()
  return value
end

-- the screen's refresh rate (Hz)
local function refresh()
  local rate = Screen.currentResolution.m_RefreshRate
  return rate.numerator / rate.denominator
end

-- what every replay was played with, read once: see replayfile.lua's header
local environment

local function played()
  if environment then return environment end
  local files, recurse = {}, IO.EnumerationOptions()
  recurse.RecurseSubdirectories = true
  for _, dir in ipairs({ "mods", "core" }) do
    local path = phigrospp.root .. "/" .. dir
    if IO.Directory.Exists(path) then
      local found = IO.Directory.GetFiles(path, "*", recurse)
      for i = 0, #found - 1 do
        local data = IO.File.ReadAllBytes(found[i])
        files[#files + 1] = found[i]:sub(#phigrospp.root + 2) .. ":" .. hex(phigrospp.crypto.sha512(il2cpp.unbytes(data)):sub(1, 4))
      end
    end
  end
  table.sort(files)
  environment = { game = CS.CloudSaveSummary.FromLocalSave().GameVersion, phigrospp = phigrospp.version,
    device = UE.SystemInfo.deviceModel, android = getprop("ro.build.version.release"),
    refresh = refresh(), fps = UE.Application.targetFrameRate,
    files = table.concat(files, ","), dpi = Screen.dpi }
  return environment
end

-- the Touch structs Input.touches returns while watching
local function structs(list)
  local out = {}
  for i, t in ipairs(list) do
    local position = { t.x, t.y }
    out[i] = { m_FingerId = t.id, m_Position = position, m_RawPosition = position, m_Phase = t.phase, m_TapCount = 1 }
  end
  return out
end

-- the recorded touches and delta time while the song plays. paused by the game, it gets the real ones, for its pause
-- menu (Resume, Retry, Back)
local function live() return level.progressControl.isPlaying end

local function serve()
  local mute = { skip = function() return simulating end }
  hooks = {
    hook(Input, "get_touches", { after = function() if live() then return serving.structs end end }),
    hook(Time, "get_deltaTime", { after = function() if live() then return serving.dt end end }),
    -- the recorded taps on the pause button don't pause, its cross quits (see quitButton)
    hook(CS.JudgeControl, "CheckPause", { skip = function() return true end }),
    -- the game derives its time (and the progress bar) from the music player's clock, so that clock is set first.
    -- the exact time is written after, since (t + offset) - offset can round
    hook(CS.ProgressControl, "Update", {
      before = function(self) self.audioSource.time = serving.t + self._offset end,
      after = function(self) self.nowTime = serving.t end,
    }),
    hook(CS.SEPlayer, "PlayHit", mute),
    hook(CS.SEPlayer, "PlayNA", mute),
  }
end

-- the header of the replay a song plays or is about to play
local loaded
local function watchedHeader()
  local path = watchNext or playback and playback.path
  if not path then return nil end
  if not loaded or loaded.path ~= path then loaded = { path = path, header = file.header(phigrospp.read(path)) } end
  return loaded.header
end

-- while the game lays a replay's chart out, it gets the screen the replay was played on: lines, note sizes and the
-- flick speed come from Screen's size and dpi, the notes' spread from the size GameInformation kept at launch, which
-- LevelControl's start reads (the rest of that start needs the real Screen)
local laying, layout = 0, nil
for method, field in pairs({ get_width = "width", get_height = "height", get_dpi = "dpi" }) do
  hook(Screen, method, { after = function() if layout then return layout[field] end end })
end
for _, m in ipairs({ { CS.JudgeLineControl, "Start" }, { CS.JudgeLineControl, "CreateNote" }, { CS.FingerManagement, "Start" } }) do
  hook(m[1], m[2], {
    before = function() laying, layout = laying + 1, watchedHeader() end,
    after = function()
      laying = laying - 1
      if laying == 0 then layout = nil end
    end,
  })
end

local real
hook(il2cpp.find("%f[%w]LevelControl%.<Start>")[1], "MoveNext", {
  before = function()
    local h, info = watchedHeader(), CS.GameInformation.main
    if not h then return end
    real = { info.screenW, info.screenH }
    info.screenW, info.screenH = h.width, h.height
  end,
  after = function()
    if not real then return end
    local info = CS.GameInformation.main
    info.screenW, info.screenH, real = real[1], real[2], nil
  end,
})

-- touches of another screen moved to where they meet the same world point through this screen's camera, which shows
-- 5 units up and down from the middle and as much across as its aspect allows
local function moveTouches(h, frames)
  local width, height = Screen.width, Screen.height
  if h.width == width and h.height == height then return end
  local k = h.width / h.height / (width / height)
  for _, frame in ipairs(frames) do
    for _, t in ipairs(frame.touches) do
      t.x, t.y = ((t.x / h.width * 2 - 1) * k + 1) / 2 * width, t.y / h.height * height
    end
  end
end

-- the fingers of a frame kept still, for a moment the replay waits through
local function still(frame)
  local list = {}
  for _, t in ipairs(frame.touches) do
    if t.phase ~= 3 and t.phase ~= 4 then list[#list + 1] = { id = t.id, phase = 2, x = t.x, y = t.y } end -- Stationary
  end
  return { t = frame.t, dt = frame.dt, touches = list, structs = structs(list) }
end

-- the game's pause button is a cross while watching: quit(position) is whether a real tap is on it
local function quitButton()
  local icon = level.judgeControl.pauseRing.transform.parent
  icon:GetComponent(UE.UI.Image).sprite = phigrospp.ui.icon("cross")
  local canvas = icon:GetComponentInParent(il2cpp.typeof(UE.Canvas), true)
  local camera = canvas.renderMode ~= 0 and canvas.worldCamera or nil -- ScreenSpaceOverlay has none
  local reach = 100 * Screen.height / 1080
  cross = icon:GetComponent(UE.RectTransform)
  quit = function(position)
    local at = UE.RectTransformUtility.WorldToScreenPoint(camera, icon.position)
    return math.abs(position.x - at.x) < reach and math.abs(position.y - at.y) < reach
  end
end

local function unserve()
  for _, id in ipairs(hooks or {}) do unhook(id) end
  hooks, serving, playback = nil, nil, nil
end

-- the components judging a song, in the order Unity updates them. while they're off the song stands still
local function judging()
  local judge = level.judgeControl
  return { level.progressControl, judge.fingerManagement, judge, judge.noteUpdateManager }
end

local function setJudging(on)
  if on == enabled then return end
  enabled = on
  for _, component in ipairs(judging()) do component.enabled = on end
end

-- recorded frames played inside the current screen frame: the game's per-frame judging and scoring steps with the song
-- time set like the hook does, hit sounds muted
local function simulate(p, n)
  local _, fingers, judge, notes = table.unpack(judging())
  simulating = true
  for _ = 1, n do
    p.cursor = p.cursor + 1
    local frame = p.frames[p.cursor]
    serving, frame.structs = frame, structs(frame.touches)
    level.progressControl.nowTime = frame.t
    fingers:Update()
    judge:Update()
    notes:Update()
    -- the game samples its max combo there once a frame: skipped, a simulated frame's peak would be lost
    level.scoreControl:Update()
  end
  simulating = false
end

-- the music plays along at normal and slow speeds, from where the replay is, and waits otherwise
local function music(p)
  local source = level.progressControl.audioSource.audioSource
  if p.paused or p.target or p.speed > 1 then return source:Pause() end
  source.time = p.frames[p.cursor].t + level.progressControl._offset
  source.pitch = p.speed
  source:UnPause()
end

-- what the coming screen frame plays: k recorded frames, the first by the game's own update and the others simulated
-- at its end. JudgeControl only judges once the music plays, which happens on its own clock, so until then k is 1
local function plan(p)
  -- one recorded frame per screen frame when the screen runs at the recorded rate (see on("song")), more when it
  -- can't go that fast
  local rate = math.floor(refresh() + 0.5)
  p.credit = p.credit + (p.judging and JUDGE_SPEED or p.target and SEEK_SPEED or p.paused and 0 or p.speed * math.floor(p.header.refresh + 0.5) / rate)
  local k = math.min(math.floor(p.credit), #p.frames - p.cursor, p.target and p.target - p.cursor or math.huge)
  p.credit = p.credit - math.floor(p.credit)
  if level.progressControl.audioSource.CurrentStatus ~= 0 then k = math.min(k, 1) end
  p.live, p.extra = k > 0, math.max(k - 1, 0)
  setJudging(p.live)
end

-- the song again from its start, then played fast up to target
local function reload(p, target)
  resume, watchNext = { target = target, speed = p.speed, paused = p.paused }, p.path
  UE.SceneManagement.SceneManager.LoadScene("Level")
end

-- the replays of a chart and control of the one being watched, for the picker and the player on screen
phigrospp.replay = {
  -- { path =, header = } of every replay of the chart in this version's format, in no particular order
  list = function(id, difficulty)
    local dir, list = folder(id, difficulty), {}
    if not IO.Directory.Exists(dir) then return list end
    local paths = IO.Directory.GetFiles(dir, "*")
    for i = 0, #paths - 1 do
      local data = phigrospp.read(paths[i])
      if file.current(data) then list[#list + 1] = { path = paths[i], header = file.header(data) } end
    end
    return list
  end,
  -- done(path) once a replay of phigros.tools is on the device, done(nil, why) when it can't be watched
  download = function(sha256, done)
    local path = ("%s/%s.pigeon"):format(ONLINE, sha256)
    if IO.File.Exists(path) then return done(path) end
    phigrospp.request("GET", "/api/replays/" .. sha256, nil, function(status, body)
      if status ~= 200 then return done(nil, "phigros.tools can't be reached") end
      if not file.current(body) then return done(nil, "This replay is from another version of Phigros++") end
      IO.Directory.CreateDirectory(ONLINE)
      phigrospp.write(path, body:sub(1, -SIGNED - 1))
      done(path)
    end)
  end,
  -- starts the selected chart in the song list as that replay of player (name#number, nil when unknown)
  watch = function(path, player)
    armed, whose = path, player
    local selector = UE.Object.FindObjectOfType(CS.SongSelector)
    selector.enabled = true -- a page over the song list turns it off
    selector:NormalStart()
  end,
  delete = function(path)
    assert(os.remove(path))
    phigrospp.emit("replays")
  end,
  state = function() return playback end,
  -- the cross quitting the replay, in the game's UI
  cross = function() return cross end,
  -- the game paused the song (its pause menu is open)
  halted = function() return not live() end,
  pause = function(paused)
    playback.paused = paused
    music(playback)
  end,
  speed = function(speed)
    playback.speed = speed
    music(playback)
  end,
  -- forward plays fast up to the frame, backward restarts the song and does that
  seek = function(frame)
    local p = playback
    frame = math.max(1, math.min(frame, #p.frames))
    if frame > p.cursor then
      p.target = frame
      return music(p)
    end
    reload(p, frame)
  end,
}

-- every step of the result screen that saves or unlocks something (LevelOverControl.<Start>d__43.MoveNext calls
-- these and display ones only). a replay skips them all, so its result screen shows without counting
local START = il2cpp.class("LevelOverControl.<>c__DisplayClass43_0")
local SAVING = {
  { START, "<Start>g__UpdateRecord|18" }, { START, "<Start>g__SetNewbestInNormalPlaying|19" },
  { START, "<Start>g__HandleFirstRun|4" }, { START, "<Start>g__HandleTutorialPlaying|5" },
  { START, "<Start>g__Handle92wRequirement|6" }, { START, "<Start>g__HandlePassRequirement|7" },
  { START, "<Start>g__HandleSpasmodicEvent|8" }, { START, "<Start>g__HandleIgalltaUnlock|9" },
  { START, "<Start>g__HandleIgalltaReplay|10" }, { START, "<Start>g__HandleCraveWaveEvent|11" },
  { START, "<Start>g__HandleLuminescenceEvent|12" }, { START, "<Start>g__HandleRandomUnlock|13" },
  { START, "<Start>g__HandleTrueHomeTrueWorldEvent|15" }, { START, "<Start>g__HandelAmetrineEvent|16" },
  { START, "<Start>g__HandlePetrichorEvent|17" }, { CS.LevelOverControl, "HandleC9ImplexroughUnlock" },
  { CS.LevelOverControl, "HandleC9EvanescentUnlock" }, { CS.LevelOverControl, "HandleAboutTheUniverseUnlock" },
  { CS.LevelOverControl, "GetCollection" },
}
local blockers

-- from a replay's start until the song list, its result screen saves nothing and its retry watches again
local function protect()
  if blockers then return end
  blockers = { hook(CS.LevelOverControl, "Retry", { before = function() watchNext = playback and playback.path or watchNext end }) }
  for _, saving in ipairs(SAVING) do
    blockers[#blockers + 1] = hook(saving[1], saving[2], { skip = function() return true end })
  end
end

-- the player of the replay watched or whose result shows (false when unknown), nil when none is
function phigrospp.replay.by()
  if blockers then return whose or false end
end

local function unprotect()
  for _, id in ipairs(blockers or {}) do unhook(id) end
  blockers = nil
end

on("song", function()
  level, enabled = UE.Object.FindObjectOfType(CS.LevelControl), true
  local path = watchNext
  watchNext = nil
  if path then
    local header, frames = file.decode(phigrospp.read(path))
    moveTouches(header, frames)
    phigrospp.frameRate(header.refresh)
    protect()
    quitButton()
    local r = resume or {}
    mode, resume = "watch", nil
    playback = { path = path, header = header, frames = frames, cursor = 0, credit = 0, live = true, extra = 0,
      speed = r.speed or 1, paused = r.paused or false, target = r.target }
    -- the first time, it's played through fast and silently, so the seek bar marks every good, bad and miss before it
    -- plays again from its start
    if not judged[path] then
      playback.judging, playback.target = true, #frames - 1
      local cameras = UE.Camera.allCameras -- nothing of it is drawn, the reload brings them back
      for i = 0, #cameras - 1 do cameras[i].enabled = false end
    end
    print(("replay: watching %s, %d frames"):format(path, #frames))
  else
    unprotect()
    mode, recorded, events = record() and "record" or nil, {}, {}
  end
end)

-- runs at the end of every frame, after the game's updates
on("update", function()
  if not mode or not level.progressControl.isPlaying then return end
  local progress = level.progressControl
  if mode == "record" then
    recorded[#recorded + 1] = { t = progress.nowTime, dt = Time.deltaTime, touches = readTouches(),
      udt = Time.unscaledDeltaTime, scale = Time.timeScale, real = Time.realtimeSinceStartup,
      music = progress.audioSource.audioSource.time, mono = math.floor(now() * 1e6 + 0.5),
      dsp = math.floor(UE.AudioSettings.dspTime * 1e6 + 0.5), focus = UE.Application.isFocused }
    return
  end
  local p = playback
  if not p or p.ended then return end
  for i = 0, Input.touchCount - 1 do
    local touch = Input.GetTouch(i)
    if touch.m_Phase == 0 and quit(touch.m_Position) then return leave() end -- Began
  end
  -- resumed from the game's pause menu, the song stands still until the music plays again after its 3, 2, 1
  if p.countdown then
    if progress.audioSource.CurrentStatus ~= 0 then
      serving = still(p.frames[math.max(p.cursor, 1)])
      return
    end
    p.countdown = nil
  end
  if p.live then p.cursor = p.cursor + 1 end
  if not hooks then serve() end
  if p.extra > 0 then simulate(p, p.extra) end
  if p.judging and p.cursor >= p.target then
    judged[p.path] = true
    return reload(p)
  end
  if p.target and p.cursor >= p.target then
    p.target = nil
    music(p)
  end
  plan(p)
  progress.nowTime = p.frames[p.cursor].t
  serving = p.frames[p.cursor + 1]
  if serving then
    serving.structs = structs(serving.touches)
    return
  end
  -- a recording stops where the game ended the song, so the replay ends it there too and holds that last moment,
  -- whatever the music's clock says
  p.ended, serving = true, { t = p.frames[p.cursor].t, dt = p.frames[p.cursor].dt, touches = {}, structs = {} }
  setJudging(true)
  progress:StartCoroutine(progress:LevelOver())
end)

-- nothing is recorded while paused, the replay knows when it was
for _, kind in ipairs({ "pause", "resume" }) do
  on(kind, function()
    if mode == "record" then events[#events + 1] = { kind = kind, frame = #recorded, mono = math.floor(now() * 1e6 + 0.5) } end
  end)
end

-- a watched replay checks it gave the recorded result, a recorded play is written with its result
on("finish", function(result)
  if mode == "watch" then
    local header, differences = playback.header, {}
    for _, field in ipairs(RESULT) do
      if result[field] ~= header[field] then
        differences[#differences + 1] = ("%s %s, recorded %s"):format(field, result[field], header[field])
      end
    end
    print("replay: " .. (#differences == 0 and "same result as recorded" or table.concat(differences, ", ")))
  end
  if mode ~= "record" then return end
  local chart = playing()
  local header = { id = chart.id, difficulty = chart.difficulty, width = Screen.width, height = Screen.height,
    date = os.time(), duration = recorded[#recorded].t, accuracy = result.accuracy,
    offset = level.progressControl._offset, mirror = chart.mirror and 1 or 0,
    challenge = level.progressControl._inChallengeMode and 1 or 0 }
  for _, field in ipairs(RESULT) do header[field] = result[field] end
  for key, value in pairs(played()) do header[key] = value end
  local dir = folder(chart.id, chart.difficulty)
  IO.Directory.CreateDirectory(dir)
  local path, data = ("%s/%d.pigeon"):format(dir, header.date), file.encode(header, recorded, events)
  phigrospp.write(path, data)
  print(("replay: %s, %d frames, %d bytes"):format(path, #recorded, #data))
  phigrospp.emit("replays")
  kept = { path = path, score = header.score }
end)

-- the result screen raises the chart's record with the play, and record still holds the one from before it. a tie
-- counts too, its replay proves a record that was only imported until then
hook(START, "<Start>g__UpdateRecord|18", {
  before = function(self)
    if not kept then return end
    if kept.score >= self.record.s then phigrospp.emit("best", kept.path) end
    kept = nil
  end,
})

-- back to the song list without a result screen. ProgressControl.Update only acts on a level break once the level is
-- over, and then goes to the next scene instead of the result screen
function leave()
  setJudging(true)
  level.judgeControl.stopJudge = true
  CS.GameInformation.nextScene = "SongSelector"
  level.progressControl:LevelBreak("Loading")
  level.levelInformation.levelOver = true
end

-- a reload drops the replay's hooks and protection, so the song is left before it can count
on("unload", function()
  if mode == "watch" then leave() end
end)

on("resume", function()
  if mode == "watch" then playback.countdown = true end
end)

-- a replay restarted from the game's pause menu is watched again, the song list forgets it
on("leave", function()
  if mode == "watch" then
    watchNext = watchNext or playback.path
    phigrospp.frameRate(0)
  end
  unserve()
  mode = nil
end)

-- a song started by watch() is that replay. the flag lives from there to the song, through the scenes in between
hook(CS.SongSelector, "NormalStart", { before = function() watchNext, armed = armed, nil end })

on("scene", function(name)
  if name ~= "SongSelector" then return end
  watchNext, resume = nil, nil
  unprotect()
end)
