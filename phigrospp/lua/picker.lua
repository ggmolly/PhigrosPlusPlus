-- the replays of a chart: a clock next to the song list's play button slides in a page made like the song list, with
-- the replays where the songs are (date, time, accuracy and grade) and the chosen one's result on the right. its play
-- button watches the replay, the bin left of it deletes it

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

local selector, clock, shown
local sort, descending = "date", true

local function fc(h) return h.bad + h.miss == 0 end

-- a clock: a ring and two hands
local function clockShape(x, y)
  local function hand(hx, hy)
    local t = math.max(0, math.min(1, (x * hx + y * hy) / (hx * hx + hy * hy)))
    return math.sqrt((x - t * hx) ^ 2 + (y - t * hy) ^ 2)
  end
  return math.min(math.abs(math.sqrt(x * x + y * y) - 40), hand(0, 24), hand(17, 0)) - 3.5
end

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

local open

-- the record panel under the cover shows the replay's result, the result screen's numbers go under it
local function result(s, h)
  s.score.text, s.acc.text = ("%07d"):format(h.score), ("%.2f%%"):format(h.accuracy)
  s.rating:SetRatingWithScore(h.score, fc(h))
  for _, stat in ipairs(s.stats) do stat.value.text = tostring(h[stat.key]) end
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

-- the top bar keeps its sort and direction, the song list's other buttons go
local function topBar(page, s)
  local bar = page:part("topbar").transform
  for _, name in ipairs({ "Setting", "Random", "Image", "ToggleSimulate" }) do UE.Object.Destroy(find(bar, name).gameObject) end
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
  local record = find(info, "RecordInfo/Normal")
  s.score, s.acc = find(record, "Score"):GetComponent(UE.UI.Text), find(record, "acc"):GetComponent(UE.UI.Text)
  s.rating = find(record, "Ratings"):GetComponent(CS.RatingDisplayController)
end

open = function(id, difficulty)
  local list = sorted(replay.list(id, difficulty))
  local page = kit.page()
  local s = { stats = {} }
  local levelY -- where the game puts the selected row's level, the grade replacing it moves up from there when it's φ
  local rows = {
    row = function(row, i)
      local h = list[i].header
      row.songName.text, row.difficulty.text = os.date("%Y-%m-%d  %H:%M", h.date), ""
      row:SetRatingWithScore(h.score, fc(h))
    end,
    selected = function(row, i)
      local h = list[i].header
      row.songName.text = os.date("%Y-%m-%d  %H:%M", h.date)
      local player = phigrospp.tag()
      row.artist.text = player and ("%s  ·  %.2f%%"):format(player, h.accuracy) or ("%.2f%%"):format(h.accuracy)
      local rank = grade(h.score, fc(h))
      row.level.text, row.levelText.text = rank, difficulty
      local t = row.level.transform
      levelY = levelY or t.anchoredPosition.y
      t.anchoredPosition = { t.anchoredPosition.x, levelY + (rank == "φ" and row.level.fontSize * PHI_LIFT or 0) }
    end,
    select = function(i)
      s.selected = i
      result(s, list[i].header)
    end,
  }
  function s.refill()
    rows.count = #sorted(list)
    page:list(rows)
  end

  page:part("shadows")
  local cover = page:part("cover").transform
  infoPanel(page, s)
  topBar(page, s)
  page:back()
  local play = page:play(function() replay.watch(list[s.selected].path) end)
  local bin = kit.sideButton(play, 1, kit.icon("bin"), function()
    local entry = list[s.selected]
    local h = entry.header
    if not kit.confirm({ title = "Delete replay", yes = "Delete", danger = true,
      message = ("The replay of %s, %07d, can't be brought back."):format(os.date("%Y-%m-%d %H:%M", h.date), h.score) })
    then return end
    replay.delete(entry.path)
    table.remove(list, s.selected)
    if #list == 0 then return page:close() end
    s.refill()
  end)
  bin:GetComponent(CS.Lean.Gui.LeanPolygon).color = kit.danger
  find(bin.transform, "phigrospp-icon"):GetComponent(UE.UI.Image).color = { 1, 1, 1, 1 }
  judgements(cover, selector.songName.font, s.stats)
  s.refill()
end

-- a replay recorded or deleted: the clock is checked again
on("replays", function() shown = nil end)

on("scene", function(name)
  selector, clock, shown = nil, nil, nil
  if name == "SongSelector" then selector = UE.Object.FindObjectOfType(CS.SongSelector) end
end)

on("update", function()
  if not selector or kit.paging() then return end
  if selector.SongItems._size == 0 then return end -- the list fills in after the scene starts
  local id, difficulty = chart()
  local key = id .. "." .. difficulty
  if key ~= shown then
    shown = key
    clock = clock or kit.sideButton(selector.startButton, 1, phigrospp.sprite(96, clockShape), function()
      if not kit.paging() then open(chart()) end -- a second tap while the page slides in
    end)
    clock:SetActive(replay.has(id, difficulty))
  end
end)
