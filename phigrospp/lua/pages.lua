-- pages over the song list, made of copies of its own parts so they look and move like the game. phigrospp.ui.page()
-- slides the song list out to the left and an empty page in from the right, page:close() slides back

local UE = CS.UnityEngine
local Input, Screen = UE.Input, UE.Screen
local kit, find = phigrospp.ui, phigrospp.find
local SLIDE = 0.35 -- seconds
local STAY = { PlayerBar = true, Money = true } -- the player's bar and data stay over both pages
-- the song list's parts by name: where they are under its content canvas, or its buttons canvas
local PARTS = {
  topbar = "TopBar", shadows = "Shadows", info = "SongCoverPanel", up = "upSideMask", down = "downSideMask",
  selected = "StartInfos/SelectedSong", cover = "StartInfos/SongsCover",
}
local BUTTONS = { back = "Back", play = "Play" }
-- the list: rows step down and left along the song list's slant, the selected one is a bigger row between the halves
local STEP, SLANT = 100, 26.8
local UP, DOWN = { -796.5, 128.9 }, { -809.0, 84.9 } -- where the selected row's copies sit, hidden by the masks
local TICK = 4 -- the sound (SEPlayer's) the song list plays for each row reaching the middle

local selector, page

on("scene", function(name)
  selector = name == "SongSelector" and UE.Object.FindObjectOfType(CS.SongSelector) or nil
  page = nil
end)

-- a canvas set up like the song list's one, and a container that slides in it
local function mirror(original)
  local go = UE.GameObject("phigrospp-page")
  local canvas, from = go:AddComponent(UE.Canvas), original:GetComponent(UE.Canvas)
  canvas.renderMode, canvas.worldCamera, canvas.planeDistance = from.renderMode, from.worldCamera, from.planeDistance
  canvas.sortingLayerID, canvas.sortingOrder = from.sortingLayerID, from.sortingOrder
  local scaler, fromScaler = go:AddComponent(UE.UI.CanvasScaler), original:GetComponent(UE.UI.CanvasScaler)
  scaler.uiScaleMode, scaler.referenceResolution = fromScaler.uiScaleMode, fromScaler.referenceResolution
  scaler.screenMatchMode, scaler.matchWidthOrHeight = fromScaler.screenMatchMode, fromScaler.matchWidthOrHeight
  go:AddComponent(UE.UI.GraphicRaycaster)
  -- a new canvas gets its size and scale on its first update, the copies are made before
  local t = go.transform
  t.position, t.rotation, t.localScale, t.sizeDelta = original.position, original.rotation, original.localScale,
    original.sizeDelta
  local container = UE.GameObject("phigrospp-page-content"):AddComponent(UE.RectTransform)
  container:SetParent(t, false)
  container.sizeDelta = original.sizeDelta
  return { go = go, root = original, container = container, width = original.sizeDelta.x, keys = {} }
end

-- what slides: the song list canvases' children but the ones staying, and the page's containers
local function sliding(p)
  local list = {}
  for _, canvas in ipairs({ p.content, p.buttons }) do
    for i = 0, canvas.root.childCount - 1 do
      local child = canvas.root:GetChild(i)
      if not STAY[child.name] then list[#list + 1] = { t = child, x = child.anchoredPosition.x, width = canvas.width } end
    end
  end
  return list
end

local function slide(p, f)
  f = f * f * (3 - 2 * f)
  for _, r in ipairs(p.moving) do r.t.anchoredPosition = { r.x - r.width * f, r.t.anchoredPosition.y } end
  for _, canvas in ipairs({ p.content, p.buttons }) do
    canvas.container.anchoredPosition = { canvas.width * (1 - f), 0 }
  end
end

-- a copy of a game object where it is on the song list, wherever the page's container is, its buttons cleared so they
-- don't do what the song list's do
-- where a part is in the song list's drawing order: its sibling indices from the canvas down
local function order(original, root)
  local key, t = {}, original
  while t ~= root do
    table.insert(key, 1, t:GetSiblingIndex())
    t = t.parent
  end
  return key
end

local function before(a, b)
  for i = 1, math.min(#a, #b) do
    if a[i] ~= b[i] then return a[i] < b[i] end
  end
  return #a < #b
end

local function copy(original, canvas)
  local clone = UE.Object.Instantiate(original.gameObject, canvas.container, false)
  local scale, root = original.lossyScale, canvas.root.lossyScale
  clone.transform.localPosition = canvas.root:InverseTransformPoint(original.position)
  clone.transform.localScale = { scale.x / root.x, scale.y / root.y, scale.z / root.z }
  -- drawn, and touched, in the song list's order: a part made later can't cover one that was on top of it
  local key = order(original, canvas.root)
  canvas.keys[#canvas.keys + 1] = { t = clone.transform, key = key }
  table.sort(canvas.keys, function(a, b) return before(a.key, b.key) end)
  for i, entry in ipairs(canvas.keys) do entry.t:SetSiblingIndex(i - 1) end
  local buttons = clone:GetComponentsInChildren(il2cpp.typeof(UE.UI.Button), true)
  for i = 0, #buttons - 1 do buttons[i].onClick = UE.UI.Button.ButtonClickedEvent() end
  return clone
end

-- a copy of a play button `slot` buttons left of it, showing a sprite instead of the triangle
function kit.sideButton(play, slot, sprite, fn)
  local t = play.transform
  local clone = UE.Object.Instantiate(t.gameObject, t.parent, false)
  clone.name = "phigrospp-button"
  clone.transform.anchoredPosition = { t.anchoredPosition.x - (t.sizeDelta.x + 24) * slot, t.anchoredPosition.y }
  local triangle = find(clone.transform, "LeanPolygon")
  local icon = UE.GameObject("phigrospp-icon"):AddComponent(UE.UI.Image)
  icon.transform:SetParent(clone.transform, false)
  icon.transform.anchoredPosition, icon.transform.sizeDelta = triangle.anchoredPosition, { 84, 84 }
  icon.sprite, icon.raycastTarget = sprite, false
  icon.color = triangle:GetComponent(CS.Lean.Gui.LeanPolygon).color
  UE.Object.Destroy(triangle.gameObject)
  local button = clone:GetComponent(UE.UI.Button)
  button.onClick = UE.UI.Button.ButtonClickedEvent() -- the copy would start the song
  phigrospp.click(button, fn)
  return clone
end

local Page = {}
Page.__index = Page

-- a copy of a part of the song list (see PARTS and BUTTONS) where it is on the song list
function Page:part(name)
  if BUTTONS[name] then return copy(find(self.buttons.root, BUTTONS[name]), self.buttons) end
  return copy(find(self.content.root, PARTS[name]), self.content)
end

-- the back button closing the page, the play button running fn
function Page:back() phigrospp.click(self:part("back"):GetComponent(UE.UI.Button), function() self:close() end) end

function Page:play(fn)
  local play = self:part("play")
  phigrospp.click(play:GetComponent(UE.UI.Button), fn)
  return play
end

function Page:close()
  if self.closing then return end
  self.closing, self.start = true, now()
  selector.enabled = true
end

local function placeRows(p)
  local l = p.listed
  for _, r in ipairs(l.rows) do
    local k = r.i - 1 - l.value
    r.item.transform.position = p.content.container:TransformPoint({ r.at[1] - SLANT * k, r.at[2] - STEP * k, 0 })
  end
  local shown = math.max(1, math.min(l.count, math.floor(l.value + 0.5) + 1))
  if shown ~= l.shown then
    if l.shown then CS.SEPlayer.Play:Invoke(TICK) end
    l.shown = shown
    l.options.selected(l.selected, shown)
    l.options.select(shown)
  end
end

local function fillRows(l)
  for _, r in ipairs(l.rows) do l.options.row(r.item, r.i) end
end

-- the song list's list: { count =, row = function(row, i), selected = function(selected, i), select = function(i) }.
-- row sets a SongListItem's songName, difficulty and rating, selected the middle row's songName, artist, level and
-- levelText (its box), select runs when the middle row changes. called again, it shows a new order or count
function Page:list(options)
  local l = self.listed
  if not l then
    l = { halves = {}, rows = {}, value = 0, target = 0 }
    for _, half in ipairs({ { "up", UP }, { "down", DOWN } }) do
      local mask = self:part(half[1]).transform
      for i = mask.childCount - 1, 0, -1 do UE.Object.Destroy(mask:GetChild(i).gameObject) end
      l.halves[#l.halves + 1] = { mask = mask, at = half[2] }
    end
    local selected = self:part("selected").transform
    local function text(path) return find(selected, path):GetComponent(UE.UI.Text) end
    l.selected = { songName = text("SongName"), artist = text("Artist"), level = text("Level/Difficulty"),
      levelText = text("Level/LevelText") }
    find(selected, "Level/Locked").gameObject:SetActive(false)
    self.listed = l
  end
  l.options, l.shown = options, nil
  if options.count ~= l.count then
    for _, r in ipairs(l.rows) do UE.Object.Destroy(r.item.gameObject) end
    l.rows, l.count = {}, options.count
    local original = find(self.content.root, PARTS.up):GetComponentInChildren(il2cpp.typeof(CS.SongListItem), true)
    for _, half in ipairs(l.halves) do
      for i = 1, l.count do
        local row = UE.Object.Instantiate(original.gameObject, half.mask, false):GetComponent(CS.SongListItem)
        row.locked:SetActive(false)
        l.rows[#l.rows + 1] = { item = row, i = i, at = half.at }
      end
    end
  end
  fillRows(l)
  l.target = math.max(0, math.min(l.target, l.count - 1))
  l.value = l.target
  placeRows(self)
  return l
end

-- a drag on the left half scrolls the list, a tap picks a row, both settle on a row. at rest nothing moves
local function touchList(p, dt)
  local l = p.listed
  if il2cpp.alive(kit.dialog) then
    l.finger = nil
    return
  end
  local scale = Screen.height / p.content.root.sizeDelta.y -- screen pixels per canvas unit
  local resting = not l.finger and l.value == l.target
  for i = 0, Input.touchCount - 1 do
    local touch = Input.GetTouch(i)
    local x, y, phase = touch.m_Position.x, touch.m_Position.y, touch.m_Phase
    if phase == 0 and x < Screen.width * 0.45 and not l.finger then -- Began
      l.finger, l.y0, l.value0, l.moved, resting = touch.m_FingerId, y, l.value, false, false
    elseif touch.m_FingerId == l.finger then
      local dy = (y - l.y0) / scale
      l.moved = l.moved or math.abs(dy) > 10
      if l.moved then l.value = math.max(-0.4, math.min(l.count - 0.6, l.value0 + dy / STEP)) end
      if phase == 3 or phase == 4 then -- Ended, Canceled
        l.finger = nil
        local row = l.moved and l.value or l.value + (Screen.height / 2 + 107 * scale - y) / scale / STEP
        l.target = math.max(0, math.min(l.count - 1, math.floor(row + 0.5)))
      end
    end
  end
  if resting then return end
  if not l.finger then
    l.value = l.value + (l.target - l.value) * (1 - 0.75 ^ (dt * 60)) -- a quarter of the way per 60 Hz frame
    if math.abs(l.target - l.value) < 0.001 then l.value = l.target end
  end
  placeRows(p)
end

function kit.page()
  assert(not page, "a page is open already")
  local content, buttons = mirror(selector.topBar.parent), mirror(selector.startButton.transform.parent)
  page = setmetatable({ content = content, buttons = buttons, start = now(), last = now() }, Page)
  page.moving = sliding(page)
  selector.enabled = false -- its update moves the list and reads touches
  slide(page, 0)
  return page
end

function kit.paging() return page ~= nil end

on("update", function()
  if not page then return end
  local t = now()
  local dt = t - page.last
  page.last = t
  local f = math.min(1, (t - page.start) / SLIDE)
  if page.closing or not page.open then
    slide(page, page.closing and 1 - f or f)
    page.open = f == 1
  end
  if page.closing and f == 1 then
    UE.Object.Destroy(page.content.go)
    UE.Object.Destroy(page.buttons.go)
    page = nil
    return
  end
  if page.listed and not page.closing then touchList(page, dt) end
end)

-- a reload destroys the page, the song list comes back at once
on("unload", function()
  if not page then return end
  slide(page, 0)
  selector.enabled = true
end)
