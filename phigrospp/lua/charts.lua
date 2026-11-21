-- custom chapters and their songs (the wiki's Custom charts page). the game's song list never changes (it checks it
-- at boot): hooks on its lookups answer for our chapter codes and song ids, and its asset keys of them read our files

local UE, IO = CS.UnityEngine, CS.System.IO
local GI, SaveManagement = CS.GameInformation, CS.SaveManagement
local crypto, json = phigrospp.crypto, phigrospp.json
local DIR = phigrospp.root .. "/charts"
local LEVELS = { "EZ", "HD", "IN", "AT" }
local DOMAIN = "phigros++ charts v1\0" -- so a chart key's signature can't pass for anything else
local ALWAYS = -1 -- the unlockType of songs and charts that are always unlocked
local MONEY = 1 -- the unlockType of songs bought with data

local chapters, byCode, byId = {}, {}, {}

IO.Directory.CreateDirectory(DIR)

local function credit(value, what, where)
  if type(value) ~= "string" or value == "" then error(("%s needs %s"):format(where, what), 0) end
  return value
end

-- a file a chapter uses: { path } on the device, with the url it's downloaded from and the sha-512 (hex) it must have
-- for a chapter from a url
local function locate(chapter, ref, folder, name)
  if not chapter.url then
    local path = chapter.base .. ref
    if not IO.File.Exists(path) then error(("%s: no file %s"):format(chapter.code, path), 0) end
    return { path = path }
  end
  local hash = chapter.files[ref]
  if chapter.key and not hash then error(("%s: the signed chapter doesn't hash %s"):format(chapter.code, ref), 0) end
  return { path = ("%s/%s/%s%s"):format(DIR, folder, name, ref:match("%.%w+$") or ""), url = chapter.base .. ref,
    hash = hash }
end

-- the keys each table of a chapter takes: any other is a typo, an error rather than ignored
local KEYS = {
  chapter = { code = 1, title = 1, subtitle = 1, banner = 1, after = 1, cover = 1, blur = 1, songs = 1, files = 1 },
  song = { folder = 1, title = 1, artist = 1, illustrator = 1, preview = 1, price = 1, music = 1, cover = 1, blur = 1,
    levels = 1 },
  levels = { EZ = 1, HD = 1, IN = 1, AT = 1 },
  level = { difficulty = 1, charter = 1, chart = 1 },
}

local function known(t, kind, where)
  for k in pairs(t) do
    if not KEYS[kind][k] then error(("%s: unknown %s key %s"):format(where, kind, tostring(k)), 0) end
  end
end

-- what a chapter definition (a mod's table or a manifest's json) describes, checked: credits are required
local function define(def, base, url, key)
  known(def, "chapter", tostring(def.code))
  local c = { code = credit(def.code, "a code", "a chapter"), title = credit(def.title, "a title", "a chapter"),
    subtitle = def.subtitle or "", banner = def.banner or def.title, after = def.after, base = base, url = url, key = key,
    files = def.files or {}, songs = {} }
  c.cover = locate(c, credit(def.cover, "a cover", c.code), c.code, "cover")
  c.blur = def.blur and locate(c, def.blur, c.code, "blur") or c.cover
  for _, d in ipairs(def.songs or {}) do
    local where = ("%s: %s"):format(c.code, tostring(d.title))
    known(d, "song", where)
    known(d.levels or {}, "levels", where)
    -- a song's folder holds its files under their usual names, a path given instead wins
    local function file(given, name) return given or d.folder and d.folder .. "/" .. name end
    local s = { chapter = c, title = credit(d.title, "a title", where), artist = credit(d.artist, "an artist", where),
      illustrator = credit(d.illustrator, "an illustrator", where), preview = d.preview or { 0, 15 },
      price = d.price or 0, levels = {} }
    s.id = ("%s_%s_%s"):format(c.code, s.title, s.artist):gsub('[%c/\\:*?"<>|]', "")
    s.music = locate(c, credit(file(d.music, "music.webm"), "music", where), s.id, "music")
    s.cover = locate(c, credit(file(d.cover, "cover.jpg"), "a cover", where), s.id, "cover")
    local blur = file(d.blur, "blur.jpg")
    s.blur = blur and locate(c, blur, s.id, "blur") or s.cover
    for _, name in ipairs(LEVELS) do
      local l = (d.levels or {})[name]
      if l then
        known(l, "level", where .. " " .. name)
        if type(l.difficulty) ~= "number" then error(("%s needs a difficulty for %s"):format(where, name), 0) end
        s.levels[#s.levels + 1] = { name = name, difficulty = l.difficulty, charter = credit(l.charter, "a charter for " .. name, where),
          chart = locate(c, credit(file(l.chart, name .. ".phc"), "a chart for " .. name, where), s.id, name) }
      end
    end
    if #s.levels == 0 then error(where .. " has no levels", 0) end
    c.songs[#c.songs + 1] = s
  end
  return c
end

-- a chapter replaces the one of the same code (a manifest downloaded again), its songs the same
local function add(c)
  local old = byCode[c.code]
  for _, s in ipairs(old and old.songs or {}) do byId[s.id] = nil end
  if old then
    for i, o in ipairs(chapters) do
      if o == old then chapters[i] = c end
    end
  else
    chapters[#chapters + 1] = c
  end
  byCode[c.code] = c
  for _, s in ipairs(c.songs) do byId[s.id] = s end
end

-- a chapter from a url: its manifest (and the signature of it when key is given) is kept, so it shows offline and
-- before the new one arrives
local function remote(url, key, after)
  local cache = ("%s/%s"):format(DIR, phigrospp.hex(crypto.sha512(url)):sub(1, 16))
  local base = url:match("^(.*/)")
  local function accept(manifest, signature)
    if key and not crypto.verify(key, DOMAIN .. manifest, signature or "") then
      return print(("charts: %s isn't signed by its key"):format(url))
    end
    local def = json.decode(manifest)
    def.after = def.after or after
    add(define(def, base, url, key))
    return true
  end
  if IO.File.Exists(cache .. ".json") then
    accept(phigrospp.read(cache .. ".json"), key and phigrospp.read(cache .. ".sig"))
  end
  phigrospp.fetch("GET", url, nil, function(status, manifest)
    if status ~= 200 then return print(("charts: %s answered %d"):format(url, status)) end
    local function done(signature)
      if not accept(manifest, signature) then return end
      phigrospp.write(cache .. ".json", manifest)
      if signature then phigrospp.write(cache .. ".sig", signature) end
    end
    if not key then return done() end
    phigrospp.fetch("GET", url .. ".sig", nil, function(code, signature)
      if code ~= 200 then return print(("charts: %s.sig answered %d"):format(url, code)) end
      done(signature)
    end)
  end)
end

-- chapter{ url =, key = } for a chapter described at a url (key: the hex ed25519 public key that must sign it), or
-- chapter{ code =, title =, cover =, songs = {...} } with files next to the mod. after = the code of the chapter
-- it's shown after
function chapter(def)
  if def.url then return remote(def.url, def.key and phigrospp.unhex(def.key), def.after) end
  add(define(def, phigrospp.resolve("", 2)))
end

-- downloads ------------------------------------------------------------------------------------------------------

local function ready(file) return IO.File.Exists(file.path) end

-- gets a file once, then runs done(ok) (at once when it's there already). a file that isn't what its chapter hashed
-- is refused
local function get(file, done)
  if ready(file) then return done(true) end
  if file.waiting then
    file.waiting[#file.waiting + 1] = done
    return
  end
  file.waiting = { done }
  file.request = phigrospp.fetch("GET", file.url, nil, function(status, body)
    local waiting, ok = file.waiting, false
    file.waiting, file.request = nil, nil
    if status ~= 200 then
      print(("charts: %s answered %d"):format(file.url, status))
    elseif file.hash and phigrospp.hex(crypto.sha512(body)) ~= file.hash then
      print(("charts: %s isn't the file its chapter hashed"):format(file.url))
    else
      IO.Directory.CreateDirectory(file.path:match("^(.*)/"))
      phigrospp.write(file.path, body)
      ok = true
    end
    for _, fn in ipairs(waiting) do fn(ok) end
  end, 0)
end

-- what a song needs to be played: its music and charts
local function playable(s)
  local files = { s.music }
  for _, l in ipairs(s.levels) do files[#files + 1] = l.chart end
  return files
end

-- the game's objects --------------------------------------------------------------------------------------------

-- the first official song without judge line images or level mods: its lists stand in for ours, and its EZ chart
-- is what the level loads before ours replaces it
local plain

local function plainSong()
  if plain then return plain end
  local all = GI.main.song.AllSongsBypassLimited
  for i = 0, all._size - 1 do
    local s, empty = all._items[i], true
    for j = 0, s.judgeLineImages._size - 1 do empty = empty and s.judgeLineImages._items[j]._size == 0 end
    for j = 0, s.levelMods._size - 1 do empty = empty and s.levelMods._items[j].levelMods._size == 0 end
    if empty and #s.levels == 4 then
      plain = s
      return s
    end
  end
end

-- a new List<string> of the strings given
local function strings(list)
  local out = il2cpp.classof(plainSong().levelMods._items[0].levelMods)()
  for _, s in ipairs(list) do out:Add(s) end
  return out
end

local function songsItem(s)
  if s.item then return s.item end
  local item, p = CS.SongsItem(), plainSong()
  item.songsId, item.songsKey, item.songsName, item.songsTitle = s.id, s.id, s.title, s.title
  item.composer, item.illustrator = s.artist, s.illustrator
  item.previewTime, item.previewEndTime = s.preview[1], s.preview[2]
  -- the game wants four levels and shows the first ones: ours go first, the missing ones pad the arrays
  local levels, difficulty, charter, unlock, named = {}, {}, {}, {}, {}
  for _, l in ipairs(s.levels) do named[l.name] = true end
  for _, l in ipairs(s.levels) do levels[#levels + 1] = l end
  for _, name in ipairs(LEVELS) do
    if not named[name] then levels[#levels + 1] = { name = name, difficulty = 0, charter = "" } end
  end
  for i, l in ipairs(levels) do
    levels[i], difficulty[i], charter[i] = l.name, l.difficulty, l.charter
    unlock[i] = CS.ChartUnlock()
    unlock[i].unlockType, unlock[i].unlockInfo = ALWAYS, strings({})
  end
  item.levels, item.difficulty, item.charter, item.unlockInfo = levels, difficulty, charter, unlock
  item.judgeLineImages, item.levelMods = p.judgeLineImages, p.levelMods
  s.item = item
  return item
end

local function chapterObject(c)
  if c.object then return c.object end
  local single = GI.main:GetChapterWithCode("Single")
  local info, items = CS.ChapterSongInfo(), il2cpp.classof(single.songInfo.songs)()
  info.title, info.subTitle, info.banner = c.title, c.subtitle, c.banner
  for _, s in ipairs(c.songs) do
    local item = CS.ChapterSongItem()
    item.songsId, item.secretType, item.secretInfo = s.id, 0, strings({})
    item.unlockType, item.unlockInfo = s.price > 0 and MONEY or ALWAYS, strings(s.price > 0 and { tostring(s.price) } or {})
    items:Add(item)
  end
  info.songs, info.songsBypassLimited = items, items
  c.object = CS.Chapter()
  c.object.chapterCode, c.object.songInfo, c.object.unlockInfo = c.code, info, single.unlockInfo
  return c.object
end

hook(GI, "GetChapterWithCode", { after = function(_, code) return byCode[code] and chapterObject(byCode[code]) end })

-- the game looks for a song's unlock rules in its own chapters only: while it checks one of ours, they include ours
local own

hook(GI, "CheckSongUnlock", {
  before = function(info, id)
    if not byId[id] then return end
    own = info.chapters
    local all = {}
    for i = 0, #own - 1 do all[i + 1] = own[i] end
    all[#all + 1] = chapterObject(byId[id].chapter)
    info.chapters = all
  end,
  after = function(info)
    if own then info.chapters, own = own, nil end
  end,
})
hook(GI, "GetSongInformation", { after = function(_, id) return byId[id] and songsItem(byId[id]) end })

phigrospp.charts = { custom = function(id) return byId[id] ~= nil end }

-- the song or chapter an asset key of the game is about, and which of its files: Assets/Tracks/<id>/music.wav,
-- .../Illustration[Blur|LowRes].jpg, Assets/Tracks/#ChapterCover/<code>[Blur].jpg
local function asset(key)
  local folder, name = key:match("^Assets/Tracks/([^/]+)/(.+)$")
  local s = byId[folder]
  if folder == "#ChapterCover" then
    local code, blur = name:match("^(.-)(Blur)%.jpg$")
    local c = byCode[code or name:match("^(.-)%.jpg$")]
    return c and (blur and c.blur or c.cover)
  end
  if not s then return end
  if name:find("^music") then return s.music, s end
  return name:find("^IllustrationBlur") and s.blur or name:find("^Illustration") and s.cover or nil
end

-- images ---------------------------------------------------------------------------------------------------------

-- the game's illustrations are 40.96 units wide in the world (a 256 px blur at 6.25 pixels per unit): a level's
-- background, a sprite renderer, only fills the screen at that size
local WIDTH = 40.96
local illustrations = {}

local function illustration(path)
  if not illustrations[path] then
    local texture = image(path).texture
    illustrations[path] = phigrospp.asset(UE.Sprite.Create(texture, { 0, 0, texture.width, texture.height },
      { 0.5, 0.5 }, texture.width / WIDTH))
  end
  return illustrations[path]
end

-- shows a custom cover in a loader of the game once it's downloaded, unless the loader moved on to another key
local function show(loader, key, file)
  loader._code = key
  get(file, function(ok)
    if not ok or not il2cpp.alive(loader) or loader._code ~= key then return end
    -- what the game's LoadImage does around loading its sprite
    loader:CheckInitialized()
    loader:set__settedFile(illustration(file.path))
    loader:set_imageEnabled(true)
    loader:set_ImageLoaded(true)
    if loader.onLoaded then loader.onLoaded:Invoke() end
    if il2cpp.is(loader, CS.AddressableImageLoaderWithLowResPreview) then
      loader.loadedImage, loader.loadImageOver, loader.loadedLowResImage = true, true, true
    end
  end)
end

-- sharp: a loader showing a low-res image before a transition to the sharp one, which ours skip straight to
local function imageHook(class, method, sharp)
  hook(class, method, {
    skip = function(loader, key)
      if sharp then key = key:gsub("LowRes(%.jpg)$", "%1"):gsub("Blur(%.jpg)$", "%1") end
      local file, music = asset(key)
      if not file or music then return false end
      show(loader, key, file)
      return true
    end,
  })
end

imageHook(CS.AddressableImageLoader, "set_Code")
imageHook(CS.AddressableImageLoader, "LoadImage") -- the level yields it itself, a skipped one yields a frame
for _, method in ipairs({ "set_Code", "SetLowResImage", "SetImageWithTransition" }) do
  imageHook(CS.AddressableImageLoaderWithLowResPreview, method, true)
end

-- music ----------------------------------------------------------------------------------------------------------

-- the decoded music of one custom song at a time (its preview, level and result screen share it), the song being
-- decoded, and the game's audio sources set to our songs: each gets the music when it's its song's
local music, decoding, sources = nil, nil, {}

local function refresh()
  local alive = {}
  for _, s in ipairs(sources) do
    if il2cpp.alive(s.source) and s.source.clipKey == s.key then
      local clip = music and music.id == s.id and music.clip or nil
      s.source.clipFile, s.source.audioSource.clip, s.source.loadOver = clip, clip, clip ~= nil
      alive[#alive + 1] = s
    end
  end
  sources = alive
end

-- decodes a song's music, unless it's the one decoded or being decoded
local function want(s)
  if music and music.id == s.id or decoding and decoding.id == s.id then return end
  decoding = { id = s.id, started = now() }
  local mine = decoding
  for _, f in ipairs(playable(s)) do get(f, function() end) end -- the charts too, a level start needs them
  get(s.music, function(ok)
    if ok and decoding == mine then decoding.job = phigrospp.decode(s.music.path) end
  end)
end

hook(CS.AddressableAudioSource, "set_Clip", {
  skip = function(source, key)
    local _, s = asset(key)
    if not s then return false end
    source.clipKey = key
    sources[#sources + 1] = { source = source, key = key, id = s.id }
    refresh()
    -- the song list sets every song's preview at once, it decodes the one picked
    if scene() ~= "SongSelector" then want(s) end
    return true
  end,
})

local list -- the song list's SongSelector

on("update", function()
  if scene() == "SongSelector" then
    list = il2cpp.alive(list) and list or UE.Object.FindObjectOfType(CS.SongSelector)
    local items = list and list.SongItems
    local picked = items and items._size > 0 and byId[items._items[list.nowSong].songInfo.songsId]
    if picked then want(picked) end
  end
  if not (decoding and decoding.job) then return end
  local samples, channels, rate = decoding.job:poll()
  if not samples then return end
  local clip = UE.AudioClip.Create(decoding.id, #samples // channels, channels, rate, false)
  clip:SetData(samples, 0)
  clip.hideFlags = 32 -- DontUnloadUnusedAsset, it outlives scenes
  if music then UE.Object.Destroy(music.clip) end
  print(("charts: %s decoded in %.1fs"):format(decoding.id, now() - decoding.started))
  music, decoding = { id = decoding.id, clip = clip }, nil
  refresh()
end)

-- a reload drops the result screen's protection, so one of our songs is left before it can count
on("unload", function()
  if music then UE.Object.Destroy(music.clip) end
  if playing() and byId[playing().id] then phigrospp.leave() end
end)

-- playing --------------------------------------------------------------------------------------------------------

-- the song screen shows as many levels as the constructor counts (2 to 4, from which charts are unlocked)
local WIDTHS = { 200, 150, 115, 100 } -- the level bar's width for 1 to 4 levels, from the constructor

hook(CS.SongSelectorItem, ".ctor", 4, {
  after = function(item, info)
    local s = byId[info.songsId]
    if not s then return end
    item["<PlayableLevelCount>k__BackingField"] = #s.levels
    item["<SelectorTargetWidth>k__BackingField"] = WIDTHS[#s.levels]
  end,
})

-- the level slider names and colours a level by its position: it gets our song's order, or the game's back
local POSITION = { EZ = 0, HD = 1, IN = 2, AT = 3 }
local colors

local function slide(slider)
  colors = colors or { [0] = slider.levelColor[0], slider.levelColor[1], slider.levelColor[2], slider.levelColor[3] }
  list = il2cpp.alive(list) and list or UE.Object.FindObjectOfType(CS.SongSelector)
  local s = byId[list.SongItems._items[list.nowSong].songInfo.songsId]
  for i = 0, 3 do
    local name = s and s.item.levels[i] or LEVELS[i + 1]
    CS.LevelSliderController.LEVEL_NAMES[i], slider.levelColor[i] = name, colors[POSITION[name]]
  end
end

hook(CS.LevelSliderController, "MoveToLevel", { before = slide })
hook(CS.LevelSliderController, "JumpToLevel", { before = slide })

-- the level loads the plain song's EZ chart (its asset must exist), then ours replaces it before anything reads it
hook(CS.SongsItem, "GetLevelStartInfo", {
  after = function(item, _, info)
    if byId[item.songsId] then info.chartAddressableKey = ("Assets/Tracks/%s/Chart_EZ.json"):format(plainSong().songsId) end
  end,
})

hook(CS.DoppelgangerLevelEffect, "TryStripHdUnlockNote", {
  before = function(chart, info)
    local s = byId[info.songsId]
    for _, l in ipairs(s and s.levels or {}) do
      if l.name == info.songsLevel then
        UE.JsonUtility.FromJsonOverwrite(phigrospp.phc(phigrospp.read(l.chart.path)), chart)
      end
    end
    if s and info.mirror then chart:Mirror() end
    -- any song's Chart as it's about to be played: loaded, mirrored, and not laid out for the screen yet
    phigrospp.emit("chart", chart)
  end,
})

-- play waits for a song's files, with the download's progress shown
hook(CS.SongSelector, "NormalStart", {
  skip = function(selector)
    local s = byId[selector.SongItems._items[selector.nowSong].songInfo.songsId]
    if not s then return false end
    local files, missing = playable(s), false
    for _, f in ipairs(files) do missing = missing or not ready(f) end
    if not missing then return false end
    coroutine.wrap(function()
      local left, open, failed = #files, true, false
      for _, f in ipairs(files) do
        get(f, function(ok)
          left, failed = ok and left - 1 or left, failed or not ok
          if open and (not ok or left == 0) then phigrospp.ui.close(ok) end
        end)
      end
      local fine = phigrospp.ui.confirm({ title = s.title, yes = false, no = "Cancel", progress = function()
        local done = 0
        for _, f in ipairs(files) do
          local length = f.request and tonumber(f.request:GetResponseHeader("Content-Length"))
          done = done + (ready(f) and 1 or length and f.request.downloadedBytes / length or 0)
        end
        return done / #files, "Downloading"
      end })
      open = false
      if fine and il2cpp.alive(selector) then return selector:NormalStart() end
      if failed then toast("The download failed") end
    end)()
    return true
  end,
})

-- records --------------------------------------------------------------------------------------------------------

-- what the player did with our songs, kept by Phigros++ since the game's save can't: { records = { ["<id>.<level>"] =
-- { score, accuracy, fc } }, bought = { [id] = true } }
local PROGRESS = DIR .. "/progress.lua"
local progress = IO.File.Exists(PROGRESS) and load(phigrospp.read(PROGRESS))() or { records = {}, bought = {} }

local function saveProgress()
  local lines = { "return { records = {" }
  for k, v in pairs(progress.records) do
    lines[#lines + 1] = ("  [%q] = { score = %d, accuracy = %.17g, fc = %s },"):format(k, v.score, v.accuracy, v.fc)
  end
  lines[#lines + 1] = "}, bought = {"
  for id in pairs(progress.bought) do lines[#lines + 1] = ("  [%q] = true,"):format(id) end
  lines[#lines + 1] = "} }"
  phigrospp.write(PROGRESS, table.concat(lines, "\n"))
end

on("finish", function(result)
  local chart = playing()
  if not byId[chart.id] or not phigrospp.counts() or phigrospp.modifiers.play() ~= 0 then return end
  local key = chart.id .. "." .. chart.difficulty
  local r = progress.records[key] or {}
  progress.records[key] = { score = math.max(r.score or 0, result.score),
    accuracy = math.max(r.accuracy or 0, result.accuracy), fc = r.fc or result.fc }
  saveProgress()
end)

hook(GI, "GetSongRecord", {
  after = function(_, id, level)
    if not byId[id] then return end
    local r, record = progress.records[id .. "." .. level], CS.LevelRecord()
    if r then record.s, record.a, record.c = r.score, r.accuracy, r.fc and 1 or 0 end
    return record
  end,
})

-- the save -------------------------------------------------------------------------------------------------------

-- the game saves where its chapter and song screens were: none of it may name ours (nothing outside Phigros++ knows
-- them), and the chapter screen's index is saved as it'd be without our cards. buying a song is the exception
local cards, leaving, passing, reopen

-- the index a chapter card would have without ours, nil for ours
local function vanilla(index)
  if cards[index] then return nil end
  local ours = 0
  for i in pairs(cards) do
    if i < index then ours = ours + 1 end
  end
  return index - ours
end

-- whether a save key or value names a custom song or chapter: keys hold song ids (<id>.Record.EZ) or end with
-- chapter codes (NowSong<code>), values are song ids, codes or asset keys
local function names(s, key)
  if type(s) ~= "string" then return false end
  if byId[s] or byCode[s] or asset(s) then return true end
  if not key then return false end
  for id in pairs(byId) do
    if s:find(id, 1, true) then return true end
  end
  for code in pairs(byCode) do
    if s:sub(-#code) == code then return true end
  end
  return false
end

for _, method in ipairs({ "SaveBool", "SaveInt", "SaveFloat", "SaveString" }) do
  hook(SaveManagement, method, {
    skip = function(key, value)
      if passing then return false end
      if key:find("^LastChapter") and leaving and cards then
        -- the screen opens on our card again until the game saves another one
        reopen = cards[leaving] and leaving or nil
        if reopen then return true end
        if key == "LastChapterSelectorIndex" and vanilla(value) ~= value then
          passing = true
          SaveManagement.SaveInt(key, vanilla(value))
          passing = false
          return true
        end
      end
      return names(key, true) or names(value)
    end,
  })
end

hook(SaveManagement, "LoadInt", {
  after = function(key, _, index)
    if key ~= "LastChapterSelectorIndex" or not cards then return end
    if reopen then return reopen end
    for i = index, index + #chapters do
      if vanilla(i) == index then return i end
    end
  end,
})

-- a priced song is locked until bought: the game's Buy spends the data, but the key it then gives is one of its own
-- keys only, so Phigros++ keeps that the song was bought
hook(GI, "GetRemainingUnlockTimes", {
  after = function(_, key) if byId[key] then return progress.bought[key] and 0 or 1 end end,
})

hook(CS.SongSelector, "Buy", {
  after = function(selector)
    local item = selector.SongItems._items[selector.nowSong]
    if byId[item.songInfo.songsId] and item.Unlocked then
      progress.bought[item.songInfo.songsId] = true
      saveProgress()
    end
  end,
})
-- the cards as the screen collected them, which a reload since its Start can't remember
hook(CS.ChapterSelector, "OnDisable", {
  before = function(selector)
    local infos = selector._chapterInfos
    leaving, cards = selector._nowChapterIndex, {}
    for i = 0, #infos - 1 do cards[i] = byCode[infos[i].chapterCode] and true or nil end
  end,
  after = function() leaving = nil end,
})

-- the chapter screen -----------------------------------------------------------------------------------------------

-- our cards are copies of the one of the chapter they follow, made before the screen's Start collects its cards
hook(CS.ChapterSelector, "Start", {
  before = function(selector)
    local panel, found, last = selector.chapterPanel, {}, {}
    for i = 0, panel.childCount - 1 do
      local child = panel:GetChild(i)
      local info = child:GetComponent(CS.ChapterInfo)
      if info then found[info.chapterCode] = child end
    end
    for _, c in ipairs(chapters) do
      local anchor = c.after or ""
      local after = last[anchor] or found[anchor] or panel:GetChild(panel.childCount - 1)
      local card = UE.Object.Instantiate(after.gameObject, panel, false)
      card.name = "phigrospp-" .. c.code
      card:GetComponent(CS.ChapterInfo).chapterCode = c.code
      card.transform:SetSiblingIndex(after:GetSiblingIndex() + 1)
      last[anchor], found[c.code] = card.transform, card.transform
    end
    cards = {}
    local index = 0
    for i = 0, panel.childCount - 1 do
      local info = panel:GetChild(i):GetComponent(CS.ChapterInfo)
      if info then
        cards[index] = byCode[info.chapterCode] and true or nil
        index = index + 1
      end
    end
  end,
})
