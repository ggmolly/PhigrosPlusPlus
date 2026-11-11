-- the song being played, its hits and results, and the game's song list, as read-only copies for mods

local emit = phigrospp.emit
local LANGUAGES = { [40] = "chinese", [41] = "chineseTraditional", [10] = "english", [22] = "japanese", [23] = "korean" }

local chart, scorer, paused

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
    scorer, paused = level.scoreControl, false
    emit("song", chart)
  end,
})

hook(CS.LevelControl, "OnDestroy", {
  before = function()
    if not chart then return end
    chart, scorer = nil, nil
    emit("leave")
  end,
})

-- offset is in ms, positive when late, nil for misses, drags and flicks
for method, judgement in pairs({ Perfect = "perfect", Good = "good", Bad = "bad", Miss = "miss" }) do
  hook(CS.ScoreControl, method, {
    after = function(self, _, judgeTime)
      local offset = judgement ~= "miss" and judgeTime ~= 0 and judgeTime * 1000 or nil
      emit("hit", { judgement = judgement, offset = offset, combo = self._combo })
    end,
  })
end

hook(CS.ProgressControl, "Play", {
  before = function(self, play)
    if not chart or self.isPlaying == play then return end
    if not play then emit("pause") elseif paused then emit("resume") end
    paused = not play
  end,
})

hook(CS.ProgressControl, "LevelOver", { before = function() emit("finish", stats()) end })
