-- the replays of a chart: a clock next to the song list's play button slides in a page made like the song list, with
-- the player's replays and the chart's top 50 on phigros.tools where the songs are (date, time, accuracy and grade)
-- and the chosen one's result on the right. its play button watches the replay, the bin left of it deletes one of the
-- player's. a checkbox in the top bar shows only the player's

local UE = CS.UnityEngine
local replay, kit, find = phigrospp.replay, phigrospp.ui, phigrospp.find
local SORTS = { "date", "score", "accuracy" }
local SORT_NAMES = { date = "Date", score = "Score", accuracy = "Accuracy" }
-- the result screen's numbers: the judgements over the bottom of the cover, the rest in the record panel's difficulty
-- buttons (the chart's difficulty is in the selected row already)
local JUDGEMENTS = { { "perfect", "Perfect" }, { "good", "Good" }, { "bad", "Bad" }, { "miss", "Miss" } }
local BUTTONS = { { "EZ", "maxcombo", "Max Combo" }, { "HD", "early", "Early" }, { "IN", "late", "Late" } }
local BUTTON_WIDTH = 125 -- room for 4 digits (a difficulty button holds 2) that still leaves the score its place
local PHI_LIFT = 0.2 -- φ hangs below the line in the game's font, onto the difficulty under it

local selector, clock, loading
local sort, descending, onlyMine = "date", true, false

local function chart()
  local info = selector.SongItems._items[selector.nowSong].songInfo
  return info.songsId, info.levels[selector.nowLevel]
end

local function sorted(list)
  table.sort(list, function(a, b)
    local x, y = a.header[sort], b.header[sort]
    if x == y then x, y = a.header.date, b.header.date end
    if descending then return x > y end
    return x < y
  end)
  return list
end

-- the chart's top 50 with a verified replay on phigros.tools, without the player's own (those are on the device).
-- done(entries, reached)
local function online(id, difficulty, done)
  local song = id:gsub("%.0$", ""):gsub("[^%w%.%-_]", function(c) return ("%%%02X"):format(c:byte()) end)
  phigrospp.request("GET", ("/api/charts/%s/%s?verified=1"):format(song, difficulty), nil, function(status, body)
    if status ~= 200 then return done({}, false) end
    local list, me = {}, phigrospp.tag()
    for _, play in ipairs(phigrospp.json.decode(body).plays) do
      local player = ("%s#%04d"):format(play.player.name, play.player.number)
      if player ~= me then
        list[#list + 1] = { header = { date = play.date // 1000, score = play.score, accuracy = play.accuracy },
          fc = play.fc, player = player, sha = play.replay }
      end
    end
    done(list, true)
  end)
end

-- the record panel under the cover shows the replay's result, the result screen's numbers go under it (those of
-- another player's replay once it's downloaded)
-- the score, accuracy and grade of a record panel (SongCoverPanel's, on the page or the song list)
local function record(info)
  local normal = find(info, "RecordInfo/Normal")
  return { score = find(normal, "Score"):GetComponent(UE.UI.Text), acc = find(normal, "acc"):GetComponent(UE.UI.Text),
    rating = find(normal, "Ratings"):GetComponent(CS.RatingDisplayController) }
end

local function showScore(r, entry)
  local h = entry.header
  r.score.text, r.acc.text = ("%07d"):format(h.score), ("%.2f%%"):format(h.accuracy)
  r.rating:SetRatingWithScore(h.score, entry.fc)
end

local function result(s, entry)
  local h = entry.header
  showScore(s.record, entry)
  for _, stat in ipairs(s.stats) do stat.value.text = h[stat.key] and tostring(h[stat.key]) or "-" end
end

-- the page closed, or the song list left
local function gone(s) return s.page.closing or not il2cpp.alive(s.own) end

-- another player's replay downloads when its row is chosen, one at a time: the row chosen meanwhile goes next
local function download(s)
  local entry = s.selected
  if s.downloading or entry.path or entry.failed then return end
  s.downloading = true
  replay.download(entry.sha, function(path, why)
    s.downloading = false
    if path then
      entry.path, entry.header = path, phigrospp.replayfile.header(phigrospp.read(path))
    else
      entry.failed = why
    end
    if gone(s) then return end
    if s.selected == entry then result(s, entry) end
    download(s)
  end)
end

-- a piece of the panel, placed from the cover's centre
local function centred(component)
  component.transform.anchorMin, component.transform.anchorMax = { 0.5, 0.5 }, { 0.5, 0.5 }
  return component
end

-- inside the cover's slanted mask, over a shade darkening its bottom
local function judgements(cover, font, stats)
  local size = cover.sizeDelta
  local bottom = -size.y / 2
  local shade = centred(kit.rect(cover, "phigrospp-stats-shade", { 0, bottom + 140 }, { size.x, 280 },
    { 0, 0, 0, 0.85 }, { 0.5, 0.5 }))
  shade.sprite = phigrospp.sprite(32, function(_, y) return y / 16 end) -- opaque in its bottom half
  local step = 170
  for i, stat in ipairs(JUDGEMENTS) do
    local x = (i - (#JUDGEMENTS + 1) / 2) * step - 70 -- the bottom edge leans left
    local value = centred(kit.text(cover, "phigrospp-stat", font, { x, bottom + 78 }, { 0, 0 }, 42, 4, { 0.5, 0.5 }))
    local name = centred(kit.text(cover, "phigrospp-stat-name", font, { x, bottom + 38 }, { 0, 0 }, 22, 4,
      { 0.5, 0.5 }))
    name.text, name.color = stat[2], { 1, 1, 1, 0.7 }
    stats[#stats + 1] = { key = stat[1], value = value }
  end
end

-- the top bar keeps its sort and direction, its Random button becomes the checkbox, the other buttons go
local function topBar(page, s)
  local bar = page:part("topbar").transform
  local own = find(bar, "Random")
  own.anchoredPosition = find(bar, "Setting").anchoredPosition
  for _, name in ipairs({ "Setting", "Image", "ToggleSimulate" }) do UE.Object.Destroy(find(bar, name).gameObject) end
  local text = find(own, "Text")
  UE.Object.Destroy(text:GetComponent(UE.UI.MultiLanguageFromTextBase)) -- it would translate the text back
  text:GetComponent(UE.UI.Text).text = "Only mine"
  local icon = find(own, "Icon")
  icon.sizeDelta = { 34, 34 }
  local box = icon:GetComponent(UE.UI.Image)
  local function tick() box.sprite = kit.icon(onlyMine and "square-check" or "square") end
  tick()
  phigrospp.click(own:GetComponent(UE.UI.Button), function()
    onlyMine = not onlyMine
    tick()
    s.refill()
  end)
  s.own = own.gameObject
  local label, arrow = find(bar, "SortType/SortTypeText"):GetComponent(UE.UI.Text), find(bar, "SortDirection/Icon")
  local function show()
    label.text, arrow.localScale = SORT_NAMES[sort], { 1, descending and 1 or -1, 1 }
  end
  show()
  phigrospp.click(find(bar, "SortType"):GetComponent(UE.UI.Button), function()
    for i, key in ipairs(SORTS) do
      if key == sort then
        sort = SORTS[i % #SORTS + 1]
        break
      end
    end
    show()
    s.refill()
  end)
  phigrospp.click(find(bar, "SortDirection"):GetComponent(UE.UI.Button), function()
    descending = not descending
    show()
    s.refill()
  end)
end

-- the record panel without the song list's unlock and shop, its difficulty buttons showing numbers
local function infoPanel(page, s)
  local info = page:part("info").transform
  for _, name in ipairs({ "UnlockInfo", "ShopInfo", "Mirror", "RecordInfo/ChallengeMode", "SelectedLevel", "LevelBar/AT" }) do
    UE.Object.Destroy(find(info, name).gameObject)
  end
  local bar = find(info, "LevelBar")
  UE.Object.Destroy(bar:GetComponent(CS.LevelBarController))
  bar.sizeDelta = { BUTTON_WIDTH * #BUTTONS + 6, bar.sizeDelta.y }
  for i, stat in ipairs(BUTTONS) do
    local button = find(bar, stat[1])
    button.gameObject:SetActive(true)
    button.anchoredPosition = { BUTTON_WIDTH * (i - 0.5), button.anchoredPosition.y }
    local label = find(button, "LevelText"):GetComponent(UE.UI.Text)
    label.text, label.horizontalOverflow = stat[3], 1 -- Overflow
    local value = find(button, "Difficulty"):GetComponent(UE.UI.Text)
    value.horizontalOverflow = 1
    s.stats[#s.stats + 1] = { key = stat[2], value = value }
  end
  s.record = record(info)
end

-- the page over the song list with entries { header =, fc =, player =, path = (once on the device), mine = true for
-- the player's, sha = for another player's }. returns its state, entries added later show with s.refill()
local function show(difficulty, entries)
  local page = kit.page()
  local s = { stats = {}, page = page, entries = entries }
  local shown -- the entries listed, sorted
  local levelY -- where the game puts the selected row's level, the grade replacing it moves up from there when it's φ
  local bin
  local rows = {
    row = function(row, i)
      local entry = shown[i]
      row.songName.text, row.difficulty.text = os.date("%Y-%m-%d  %H:%M", entry.header.date), ""
      row:SetRatingWithScore(entry.header.score, entry.fc)
    end,
    selected = function(row, i)
      local entry = shown[i]
      local h = entry.header
      row.songName.text = os.date("%Y-%m-%d  %H:%M", h.date)
      row.artist.text = entry.player and ("%s  ·  %.2f%%"):format(entry.player, h.accuracy)
          or ("%.2f%%"):format(h.accuracy)
      local rank = grade(h.score, entry.fc)
      row.level.text, row.levelText.text = rank, difficulty
      local t = row.level.transform
      levelY = levelY or t.anchoredPosition.y
      t.anchoredPosition = { t.anchoredPosition.x, levelY + (rank == "φ" and row.level.fontSize * PHI_LIFT or 0) }
    end,
    select = function(i)
      s.selected = shown[i]
      result(s, s.selected)
      bin:SetActive(s.selected.mine == true)
      download(s)
    end,
  }
  -- with none of the player's replays, or only theirs, the checkbox would change nothing
  function s.refill()
    local mine = 0
    for _, entry in ipairs(entries) do mine = mine + (entry.mine and 1 or 0) end
    s.own:SetActive(mine > 0 and mine < #entries)
    shown = {}
    for _, entry in ipairs(entries) do
      if entry.mine or not onlyMine or mine == 0 then shown[#shown + 1] = entry end
    end
    rows.count = #sorted(shown)
    page:list(rows)
  end

  page:part("shadows")
  page:part("background") -- dims the list
  local cover = page:part("cover").transform
  infoPanel(page, s)
  topBar(page, s)
  page:back()
  -- the song list shows during the game's start transition, with the replay's score instead of the player's record
  -- (the song list reloads after the song)
  local function watch(entry)
    showScore(record(find(selector.topBar.parent, "SongCoverPanel")), entry)
    page:remove()
    replay.watch(entry.path, entry.player)
  end
  local play = page:play(function()
    local entry = s.selected
    if entry.path then return watch(entry) end
    replay.download(entry.sha, function(path, why)
      if gone(s) then return end
      if not path then return toast(why) end
      entry.path = path
      watch(entry)
    end)
  end)
  bin = kit.sideButton(play, 1, kit.icon("trash-2"), function()
    local entry = s.selected
    local h = entry.header
    if not kit.confirm({ title = "Delete replay", yes = "Delete", danger = true,
      message = ("The replay of %s, %07d, can't be brought back."):format(os.date("%Y-%m-%d %H:%M", h.date), h.score) })
    then return end
    replay.delete(entry.path)
    for i, e in ipairs(entries) do
      if e == entry then table.remove(entries, i) end
    end
    if #entries == 0 then return page:close() end
    s.refill()
  end)
  bin:GetComponent(CS.Lean.Gui.LeanPolygon).color = kit.danger
  find(bin.transform, "phigrospp-icon"):GetComponent(UE.UI.Image).color = { 1, 1, 1, 1 }
  judgements(cover, selector.songName.font, s.stats)
  s.refill()
  return s
end

-- the player's replays show at once, the others join when phigros.tools answers. with none of the player's, the page
-- waits for the answer
local function open(id, difficulty)
  local entries = {}
  for _, r in ipairs(replay.list(id, difficulty)) do
    entries[#entries + 1] = { header = r.header, fc = r.header.bad + r.header.miss == 0, player = phigrospp.tag(),
      path = r.path, mine = true }
  end
  local s = #entries > 0 and show(difficulty, entries)
  loading = not s
  online(id, difficulty, function(list, reached)
    loading = false
    if s then
      if gone(s) then return end
      table.move(list, 1, #list, #entries + 1, entries)
      return s.refill()
    end
    if not selector or kit.paging() then return end -- the song list was left meanwhile
    if #list > 0 then return show(difficulty, list) end
    toast(reached and "No replays of this chart yet" or "phigros.tools can't be reached")
  end)
end

on("scene", function(name)
  selector, clock, loading = nil, nil, false
  if name == "SongSelector" then selector = UE.Object.FindObjectOfType(CS.SongSelector) end
end)

on("update", function()
  if not selector or selector.SongItems._size == 0 then return end -- the list fills in after the scene starts
  clock = clock or kit.sideButton(selector.startButton, 1, kit.icon("clock"), function()
    if not kit.paging() and not loading then open(chart()) end -- a second tap while the page slides in
  end)
  local playable = not selector.locked.activeSelf
  if clock.activeSelf ~= playable then clock:SetActive(playable) end
end)
