-- the song being played, its hits and results, and the game's song list, as read-only copies for mods

local emit = phigrospp.emit
local LANGUAGES = { [40] = "chinese", [41] = "chineseTraditional", [10] = "english", [22] = "japanese", [23] = "korean" }

local chart, scorer, paused, stage
local speed, clock, ticking = 1 -- phigrospp.speed: how fast the song runs, its clock and the hook giving it to the game
-- what ScoreControl counts of a play, and those counts as the song started
local SCORE = { "_score", "_percent", "_combo", "maxcombo", "perfect", "good", "bad", "miss", "early", "late",
  "isAllPerfect", "isFullCombo" }
local fresh
local lines -- the level's judge lines by index, looked for when a hit needs one

function language() return LANGUAGES[CS.MultiLanguageManager.GetCurrentLanguage()] end

function rks() return CS.GameInformation.main.RankingScore end

-- the letter the game gives a score, a full combo is at least V
local GRADES = { { 960000, "V" }, { 920000, "S" }, { 880000, "A" }, { 820000, "B" }, { 700000, "C" } }

function grade(score, fc)
  if score >= 1000000 then return "φ" end
  if fc then return "V" end
  for _, g in ipairs(GRADES) do
    if score >= g[1] then return g[2] end
  end
  return "F"
end

-- the game's whole song list, read once
local catalog, byId

function songs()
  if catalog then return catalog end
  catalog, byId = {}, {}
  local all = CS.GameInformation.main.song.AllSongsBypassLimited
  for i = 0, all._size - 1 do
    local s = all._items[i]
    local charts = {}
    for j = 0, #s.levels - 1 do charts[s.levels[j]] = { constant = math.floor(s.difficulty[j] * 10 + 0.5) / 10, charter = s.charter[j] } end
    catalog[i + 1] = { id = s.songsId, name = s.songsName, composer = s.composer, illustrator = s.illustrator,
      charts = charts }
    byId[s.songsId] = catalog[i + 1]
  end
  return catalog
end

function song(id)
  songs()
  return byId[id]
end

-- a value of the game's save as SaveManagement.LoadString reads it, without the rewrite LoadString makes of a value
-- saved the old way (DES). nil when the save has none
local function saved(key)
  local SaveManagement, PlayerPrefs = CS.SaveManagement, CS.UnityEngine.PlayerPrefs
  local current, old = SaveManagement.Encrypt(key), SaveManagement.EncryptDES(key)
  if PlayerPrefs.HasKey(current) then return SaveManagement.Decrypt(PlayerPrefs.GetString(current)) end
  if PlayerPrefs.HasKey(old) then return SaveManagement.DecryptDES(PlayerPrefs.GetString(old)) end
end

-- the avatar and background the player picked on their profile, "" while they keep the game's
function appearance()
  return { avatar = saved("UserIconKeyName") or "", background = saved("UserIllustrationKeyName") or "" }
end

-- every chart the player has a record on: { id, difficulty = "IN", score, accuracy, fc }, from their save. the game
-- keeps an empty record (score 0) for charts never played, those aren't records
function records()
  local list = {}
  for _, s in ipairs(songs()) do
    for difficulty in pairs(s.charts) do
      local json = saved(("%s.Record.%s"):format(s.id, difficulty)) -- what GameInformation.GetSongRecord reads
      local r = json and json ~= "" and phigrospp.json.decode(json) -- LevelRecord: s = score, a = accuracy, c = 1 for FC
      if r and r.s > 0 then
        list[#list + 1] = { id = s.id, difficulty = difficulty, score = math.tointeger(r.s), accuracy = r.a, fc = r.c == 1 }
      end
    end
  end
  return list
end

-- the chart being played, nil outside of a song. songsLevel holds the difficulty name and songsDifficulty the level
function playing() return chart end

-- accuracy is over the notes judged so far, like the game's result screen once every note is judged
function stats()
  if not scorer then return nil end
  local s = scorer
  local judged = s.perfect + s.good + s.bad + s.miss
  return {
    score = math.floor(s._score + 0.5), accuracy = judged > 0 and (s.perfect + 0.65 * s.good) / judged * 100 or 100,
    combo = s._combo, maxcombo = s.maxcombo, fc = s.isFullCombo, ap = s.isAllPerfect,
    perfect = s.perfect, good = s.good, bad = s.bad, miss = s.miss, early = s.early, late = s.late,
  }
end

-- the chart is loaded and sorted, the song is about to start
hook(CS.LevelControl, "SortForAllNoteWithTime", {
  after = function(level)
    local info = CS.GameInformation.main.levelStartInfo
    chart = { id = info.songsId, name = info.songsName, difficulty = info.songsLevel, level = info.songsDifficulty,
      composer = info.composer, charter = info.charter, illustrator = info.illustrator, mirror = info.mirror,
      notes = level.levelInformation.numOfNotes }
    scorer, paused, lines, stage = level.scoreControl, false, nil, level
    fresh = {}
    for _, field in ipairs(SCORE) do fresh[field] = scorer[field] end
    emit("song", chart)
  end,
})

hook(CS.LevelControl, "OnDestroy", {
  before = function()
    if not chart then return end
    chart, scorer, speed = nil, nil, 1
    if ticking then ticking = unhook(ticking) end
    emit("leave")
  end,
})

local KINDS = { "tap", "drag", "hold", "flick" } -- by a chart note's type

-- the chart's note a judgement is about and its line, from the note's code: its line (millions), its side of the
-- line (100000 for below) and its place in that side's notes (tens)
local function judged(code)
  if not lines then
    local all = CS.UnityEngine.Object.FindObjectsOfType(CS.JudgeLineControl)
    lines = {}
    for i = 0, #all - 1 do lines[all[i].index] = all[i] end
  end
  code = math.floor(code)
  local line = lines[code // 1000000]
  local notes = code % 1000000 >= 100000 and line.notesBelow or line.notesAbove
  return notes:get_Item(code % 100000 // 10), line
end

-- where a hit is on screen, in pixels: nothing while nothing is drawn (a replay being sought). the game says where a
-- perfect or a good is, a miss or a bad is where its note sits on its line
local function where(note, line, at)
  local camera = CS.UnityEngine.Camera.main
  if not camera then return nil end
  local point = camera:WorldToScreenPoint(at or line.transform:TransformPoint({ note.positionX, 0, 0 }))
  return point.x, point.y
end

-- offset is in ms, positive when late, nil for a miss. note: the kind of note. x, y: where it is on screen
for method, judgement in pairs({ Perfect = "perfect", Good = "good", Bad = "bad", Miss = "miss" }) do
  hook(CS.ScoreControl, method, {
    after = function(self, code, judgeTime, at)
      local offset = judgement ~= "miss" and judgeTime ~= 0 and judgeTime * 1000 or nil
      local note, line = judged(code)
      local x, y = where(note, line, at)
      emit("hit", { judgement = judgement, offset = offset, combo = self._combo, note = KINDS[note.type], x = x, y = y })
    end,
  })
end

-- NoteUpdateManager's notes on the field
local FIELD = { "clickControls", "dragControls", "holdControls", "flickControls" }

-- every note is made when the song starts and destroyed once judged: going back to t the ones left are destroyed and
-- those from t on (up to `to`) made again, unjudged
local function renote(judge, t, to)
  local Object = CS.UnityEngine.Object
  for _, name in ipairs(FIELD) do
    local list = judge.noteUpdateManager[name]
    for i = 0, list._size - 1 do
      if il2cpp.alive(list._items[i]) then Object.Destroy(list._items[i].gameObject) end
    end
    list:Clear()
  end
  local all = judge.judgeLineControls
  for i = 0, all._size - 1 do
    local line = all._items[i]
    line.nowSpeedIndex, line.nowDisappearIndex, line.nowMoveIndex, line.nowRotateIndex = 0, 0, 0, 0
    for _, above in ipairs({ true, false }) do
      local notes = above and line.notesAbove or line.notesBelow
      for n = 0, notes._size - 1 do
        local note = notes._items[n]
        local out = note.realTime < t or note.realTime > to
        note.isJudged, note.isJudgedForFlick = out, false
        if not out then line:CreateNote(n, above) end
      end
    end
  end
  -- touches are judged against the notes from the first one left
  local sorted, first = judge.chartNoteSortByTime, 0
  while first < sorted._size and sorted._items[first].realTime < t do first = first + 1 end
  judge.startIndex, judge.endIndex = first, first
end

-- puts the song being played at t (seconds into the chart) with its music. going forward the game misses the notes
-- jumped over, going back the notes from t on come back unjudged. the score stays as it is. given `to`, only the
-- notes from t to there are on the field whichever way it goes, none is missed: a section to practise
function phigrospp.jump(t, to)
  local progress = stage.progressControl
  if to or t < progress.nowTime then renote(progress.judgeControl, t, to or math.huge) end
  local clip = math.max(0, t + progress._offset)
  progress.audioSource:Seek(clip)
  -- audioTime is where the game starts the music again after a pause
  progress.audioTime, progress.nowTime, clock = clip, t, clip
  emit("jump", t)
end

-- the game's time is the music's, read from a clock that doesn't follow its pitch: at another speed ours is given
-- instead, before the game reads it. AudioSource.time follows the pitch but moves a buffer at a time, so ours runs by
-- itself, pulled to it while the music plays (once it ended the game still counts up to the level's end). a watched
-- replay has its own times
local function tick(progress)
  local music = progress.audioSource
  if not progress.isPlaying or music.CurrentStatus ~= 0 or replaying() then return end
  local source = music.audioSource
  clock = clock + CS.UnityEngine.Time.deltaTime * speed
  if source.isPlaying then
    local heard = source.time
    clock = math.abs(heard - clock) > 0.12 and heard or clock + (heard - clock) * 0.05
  end
  music.time = clock
end

-- how fast the song being played runs, 1 as the game plays it: its music (the pitch follows) and its notes. given a
-- speed, the song takes it until it's left
function phigrospp.speed(x)
  if not x then return speed end
  local music = stage.progressControl.audioSource
  speed, music.audioSource.pitch = x, x
  if ticking and x == 1 then ticking = unhook(ticking) end
  -- the clock starts from the music's, then keeps its own: a jump sets it
  if not ticking and x ~= 1 then clock, ticking = music.time, hook(CS.ProgressControl, "Update", { before = tick }) end
end

-- puts the song being played back at its start in place, every note unjudged and nothing scored. the game then
-- waits before the music like a fresh start does, a replay plays its own recorded start instead
function phigrospp.restart()
  local progress = stage.progressControl
  if not replaying() and progress.isPlaying then progress:Play(false) end -- the music stops as the pause button does
  phigrospp.jump(0)
  for _, field in ipairs(SCORE) do scorer[field] = fresh[field] end
  scorer._noteCodes:Clear()
  if scorer.comboBlocked then scorer:UnblockCombo() end -- Petrichor's blocks lock the combo when touched
  local blocks = progress.judgeControl.previewElementUpdateControl
  if blocks.HasBlocks then blocks:DestroyAndCreateAllBlocks() end -- the ones gone by come back
  if not replaying() then
    -- Play(true) has ProgressControl.Update wait 1.5 s at a first launch, 3 s (the 3, 2, 1) after a pause. the seek
    -- started the music's clock again, Pause stops it until the music is scheduled
    progress.audioSource:Pause()
    progress._isFirstTimeLaunch = true
    progress:Play(true)
    progress.pauseBar:SetActive(false)
    progress.pauseCamera.enabled = false
    progress.judgeControl.pauseTime = 0 -- the ring a first tap on the pause button shows
  end
  emit("restart")
end

-- whether a point of the screen (pixels) is on the pause button of the song being played
function phigrospp.pauseButton(x, y)
  local icon = stage.judgeControl.pauseRing.transform.parent
  local canvas = icon:GetComponentInParent(il2cpp.typeof(CS.UnityEngine.Canvas), true)
  local camera = canvas.renderMode ~= 0 and canvas.worldCamera or nil -- ScreenSpaceOverlay has none
  local at = CS.UnityEngine.RectTransformUtility.WorldToScreenPoint(camera, icon.position)
  local reach = 100 * CS.UnityEngine.Screen.height / 1080
  return math.abs(x - at.x) < reach and math.abs(y - at.y) < reach
end

hook(CS.ProgressControl, "Play", {
  before = function(self, play)
    if not chart or self.isPlaying == play then return end
    if not play then emit("pause") elseif paused then emit("resume") end
    paused = not play
  end,
})

hook(CS.ProgressControl, "LevelOver", { before = function() emit("finish", stats()) end })

-- the game's garbage collector stops it for 100 to 250 ms when it runs, every few seconds, and lua's for up to 40 ms:
-- while a song plays both wait for it to end or pause, the heaps grow by up to 20 MB a minute meanwhile
local collecting = true
local function collect(on)
  if collecting ~= on then
    il2cpp.gc(on)
    collectgarbage(on and "restart" or "stop")
    if on then collectgarbage() end
  end
  collecting = on
end
on("song", function() collect(false) end)
on("pause", function() collect(true) end)
on("resume", function() collect(false) end)
on("leave", function() collect(true) end)
-- the collector is the game's, it outlives a reload
on("unload", function() collect(true) end)
