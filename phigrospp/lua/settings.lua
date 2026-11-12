-- setting(label, default, options, tab), button(label, fn, tab), link(label, fn, tab) and progress(fn, tab) for mods, in a tab of the game
-- settings. a setting is a toggle, a slider with a { min, max } range or a choice with a list, its value saved in
-- settings.lua. tab(name, shown) shows a tab only while shown() is true, and a last shown argument does the same for
-- a row. a tab named like one of the game's own pages (PAGES) puts its rows into that page

local UE = CS.UnityEngine
local PATH = phigrospp.root .. "/settings.lua"
local TAG = "phigrospp:" -- prefix of the objects we add to the settings screen
local LANGUAGES = { "chinese", "chineseTraditional", "english", "japanese", "korean" }

local chunk = loadfile(PATH, "t", {})
local values, tabs, kinds = chunk and chunk() or {}, {}, {}

-- every value, also those of mods not loaded this time, so a disabled or broken mod keeps its settings
local function save()
  local labels = {}
  for label in pairs(values) do labels[#labels + 1] = label end
  table.sort(labels)
  local lines = { "return {" }
  for _, label in ipairs(labels) do
    local value = values[label]
    lines[#lines + 1] = ("  [%q] = %s,"):format(label, type(value) == "string" and ("%q"):format(value) or tostring(value))
  end
  lines[#lines + 1] = "}\n"
  phigrospp.write(PATH, table.concat(lines, "\n"))
end

-- a slider changes every frame while dragged, it's saved once it rests
local saving

local function saveSoon()
  if saving then saving() end
  saving = after(0.5, function()
    saving = nil
    save()
  end)
end

on("unload", function()
  if saving then save() end
end)

local added -- what we added to the settings screen, to keep it in sync and remove it on reload
local built -- what was shown when it was last built: each tab's name and the place of each of its rows shown

local function newTab(name)
  if not tabs[name] then
    tabs[name] = {}
    table.insert(tabs, name)
  end
  return tabs[name]
end

local function register(label, tab, kind)
  if kinds[label] then error(("%q is already a setting or button"):format(label), 3) end
  kinds[label] = kind
  table.insert(newTab(tab or "Phigros++"), label)
end

-- the getter sets the value too when given one, as if the player had
function setting(label, default, options, tab, shown)
  if type(options) ~= "table" then options, tab, shown = nil, options, tab end
  if values[label] == nil then values[label] = default end
  local kind = not options and "toggle" or type(options[1]) == "number" and "slider" or "choice"
  register(label, tab, { type = kind, options = options, shown = shown })
  return function(value)
    if value ~= nil and value ~= values[label] then
      values[label] = value
      local item = added and added.items[label]
      if item then item.Value = value end
      save()
    end
    return values[label]
  end
end

-- a label can be a function, for a button showing something that changes. danger makes its label red, for what can't
-- be undone
function button(label, fn, tab, shown, danger)
  register(label, tab, { type = "button", fn = fn, shown = shown, danger = danger })
end

-- a label with the game's arrow button, for a row that opens something
function link(label, fn, tab, shown) register(label, tab, { type = "link", fn = fn, shown = shown }) end

-- fn returns how far along it is, from 0 to 1, and what to write on the bar if anything: a text in its middle, or
-- { left =, center =, right = }
function progress(fn, tab, shown) register(fn, tab, { type = "progress", shown = shown }) end

function tab(name, shown) newTab(name).shown = shown end

local function shownTabs()
  local list = {}
  for _, name in ipairs(tabs) do
    if not tabs[name].shown or tabs[name].shown() then list[#list + 1] = name end
  end
  return list
end

local function layout() return table.concat(shownTabs(), "\n") end

local function text(s)
  local t = CS.Phigros2.Utils.MultiLanguageText.MultiLanguageTextString()
  for _, language in ipairs(LANGUAGES) do t[language] = s end
  return t
end

-- the game's sliders and buttons show no value, so it goes in the title
local function title(label)
  local kind, value = kinds[label].type, values[label]
  if type(label) == "function" then return text(label()) end
  if kind == "slider" then
    value = math.type(value) == "integer" and value or ("%.2f"):format(value)
  elseif kind ~= "choice" then
    return text(label)
  end
  return text(("%s: %s"):format(label, value))
end

local function cycle(label)
  local choices, index = kinds[label].options, 1
  for i, choice in ipairs(choices) do
    if choice == values[label] then index = i % #choices + 1 end
  end
  values[label] = choices[index]
  save()
  phigrospp.emit("setting", label, values[label])
end

-- returns the item, and whether its Value follows the setting
-- a button row turned into a bar: its shape is the track, and a copy of it is the fill. each text is written twice,
-- white on the track and black on the fill, which clips its copy to what it covers
local SIDES = { left = 3, center = 4, right = 5 } -- TextAnchor.MiddleLeft, MiddleCenter, MiddleRight
local BAR_PADDING = 48 -- keeps the side texts clear of the slanted ends

local function progressRow(manager)
  local item = manager:AddButton(text(""), {})
  local track = item.button.transform
  local shape = track:GetComponent(CS.Lean.Gui.LeanPolygon)
  shape.color, shape.raycastTarget = { 1, 1, 1, 0.15 }, false
  local centre = track:Find("Text")
  centre:GetComponent(UE.UI.Text).color = { 1, 1, 1, 1 }
  centre.offsetMin, centre.offsetMax = { BAR_PADDING, 0 }, { -BAR_PADDING, 0 }
  for side, anchor in pairs(SIDES) do
    local t = side == "center" and centre or UE.Object.Instantiate(centre.gameObject, track, false).transform
    t.name = side
    t:GetComponent(UE.UI.Text).alignment = anchor
  end
  local fill = UE.Object.Instantiate(track.gameObject, track, false)
  UE.Object.Destroy(fill:GetComponent(UE.UI.Button))
  fill:AddComponent(UE.UI.RectMask2D)
  fill:GetComponent(CS.Lean.Gui.LeanPolygon).color = { 1, 1, 1, 1 }
  local f = fill.transform
  f.anchorMin, f.anchorMax, f.pivot, f.sizeDelta, f.anchoredPosition = { 0, 0 }, { 0, 1 }, { 0, 0.5 }, { 0, 0 }, { 0, 0 }
  local texts = {}
  for side in pairs(SIDES) do
    local light, dark = track:Find(side):GetComponent(UE.UI.Text), f:Find(side):GetComponent(UE.UI.Text)
    dark.color = { 0, 0, 0, 1 }
    -- as wide as the track, so the fill only uncovers it
    local t = dark.transform
    t.anchorMin, t.anchorMax, t.pivot, t.anchoredPosition = { 0, 0 }, { 0, 1 }, { 0, 0.5 }, { BAR_PADDING, 0 }
    texts[side] = { light, dark }
  end
  return item, { track = track, fill = f, texts = texts }
end

local function drawBar(fn, b)
  local done, label = fn()
  done = math.max(0, math.min(1, done))
  b.fill.anchorMax = { done, 1 }
  b.fill.gameObject:SetActive(done > 0)
  if type(label) ~= "table" then label = { center = label } end
  local width = b.track.rect.m_Width - 2 * BAR_PADDING
  for side, pair in pairs(b.texts) do
    pair[1].text, pair[2].text = label[side] or "", label[side] or ""
    pair[2].transform.sizeDelta = { width, 0 }
  end
end

-- a toggle row with the arrow button of the game's Misc page in place of its toggle
local function linkRow(manager, label, fn)
  local item = manager:AddToggle(title(label), false, {})
  local toggle = item.toggle.transform
  local arrow = UE.Object.Instantiate(added.screen.audioFixText.transform.parent:Find("Button").gameObject,
    item.transform, false).transform
  arrow.anchorMin, arrow.anchorMax, arrow.pivot = toggle.anchorMin, toggle.anchorMax, toggle.pivot
  arrow.anchoredPosition = toggle.anchoredPosition
  toggle.gameObject:SetActive(false)
  -- the copy still opens what the original does
  local click = arrow:GetComponent(UE.UI.Button).onClick
  click.m_PersistentCalls.m_Calls:Clear()
  click.m_CallsDirty = true
  phigrospp.click(arrow:GetComponent(UE.UI.Button), fn)
  return item, false
end

-- a plain Text where the game has a MultiLanguageText, which writes its own translation back each time it's enabled
local function plainText(multi, s)
  local go, font, size, alignment, colour = multi.gameObject, multi.font, multi.fontSize, multi.alignment, multi.color
  local overflow = { multi.horizontalOverflow, multi.verticalOverflow }
  UE.Object.DestroyImmediate(multi)
  local t = go:AddComponent(UE.UI.Text)
  t.font, t.fontSize, t.alignment, t.color, t.text, t.raycastTarget = font, size, alignment, colour, s, false
  t.horizontalOverflow, t.verticalOverflow = overflow[1], overflow[2]
  return t
end

-- the copies would still change the game's own chart offset
local function unhooked(event)
  event.m_PersistentCalls.m_Calls:Clear()
  event.m_CallsDirty = true
end

-- a slider with - and + buttons moving it by its step, and its value on the right, made from the game's Chart Offset
-- row. it stands for a slider item: Value is the setting's, SetTitle shows it
local function stepperRow(manager, label, options)
  local row = UE.Object.Instantiate(added.screen.offsetSlider.transform.parent.parent.gameObject, manager.itemsHolder,
    false).transform
  row.name = TAG .. label
  local find = function(path) return phigrospp.find(row, path) end
  -- one line however long, the game's box only fits "Chart Offset"
  plainText(find("OffsetSettingText"):GetComponent(UE.UI.MultiLanguageText), label).horizontalOverflow = 1
  UE.Object.DestroyImmediate(find("OffsetSettingTipText (1)").gameObject)
  local hint = find("OffsetSettingTipText (0)")
  if options.hint then
    plainText(hint:GetComponent(UE.UI.MultiLanguageText), options.hint)
  else
    UE.Object.DestroyImmediate(hint.gameObject)
    row.sizeDelta = { row.sizeDelta.x, manager.sliderPrefab.transform.sizeDelta.y } -- spaced like a slider
  end
  local value = find("OffsetText"):GetComponent(UE.UI.Text)
  local slider = find("OffsetSetting/OffsetSettingSlider"):GetComponent(UE.UI.Slider)
  unhooked(slider.onValueChanged)
  local min, max, step = options[1], options[2], options.step
  -- the copy keeps the game's whole milliseconds otherwise
  slider.wholeNumbers = math.type(values[label]) == "integer"
  slider.minValue, slider.maxValue, slider.value = min, max, values[label]
  local item = setmetatable({
    gameObject = row.gameObject,
    SetTitle = function()
      local v = values[label]
      value.text = (math.type(v) == "integer" and "%d%s" or "%.2f%s"):format(v, options.unit or "")
    end,
  }, {
    __index = function() return math.floor(slider.value / step + 0.5) * step end, -- Value, on the step
    __newindex = function(_, _, v) slider.value = math.max(min, math.min(max, v)) end,
  })
  for name, sign in pairs({ AddButton = 1, SubButton = -1 }) do
    local button = find("OffsetSetting/" .. name):GetComponent(UE.UI.Button)
    unhooked(button.onClick)
    phigrospp.click(button, function() item.Value = item.Value + sign * step end)
  end
  item.SetTitle()
  return item, true
end

local function addItem(manager, label)
  local kind = kinds[label]
  if kind.type == "progress" then return progressRow(manager) end
  if kind.type == "link" then return linkRow(manager, label, kind.fn) end
  if kind.type == "toggle" then return manager:AddToggle(title(label), values[label], {}), true end
  if kind.type == "slider" and kind.options.step then return stepperRow(manager, label, kind.options) end
  if kind.type == "slider" then
    local min, max = kind.options[1], kind.options[2]
    return manager:AddSlider(title(label), values[label], min, max, math.type(values[label]) == "integer", {}), true
  end
  local item = manager:AddButton(title(label), {})
  if kind.danger then item.title.color = phigrospp.ui.danger end
  phigrospp.click(item.button, kind.type == "button" and kind.fn or function()
    cycle(label)
    item:SetTitle(title(label))
  end)
  return item, false
end

-- the first n entries of a C# array followed by `extra`, as a lua list (which becomes a new array when set)
local function entries(array, n, extra)
  local list = {}
  for i = 0, n - 1 do list[i + 1] = array[i] end
  for i, value in ipairs(extra or {}) do list[n + i] = value end
  return list
end

local function copy(original, name)
  local object = UE.Object.Instantiate(original.gameObject, original.transform.parent, false)
  object.name = TAG .. name
  return object
end

-- the game's list of setting rows, made of its own items, with the tab's rows shown
local function list(screen, viewport, content, holder, name)
  local gameplay = screen.settingItemsManager
  local manager = content.gameObject:AddComponent(CS.SettingItemsManager)
  manager.viewport, manager.content, manager.itemsHolder = viewport, content, holder
  manager.buttonPrefab, manager.sliderPrefab, manager.togglePrefab = gameplay.buttonPrefab, gameplay.sliderPrefab,
      gameplay.togglePrefab
  local rows = {}
  for _, label in ipairs(tabs[name]) do
    local item, follows = addItem(manager, label)
    if follows == true then added.items[label] = item end
    if type(follows) == "table" then added.bars[label] = follows
    elseif type(label) == "function" then added.titles[label] = { item = item, shown = label() } end
    if kinds[label].shown then
      rows[#rows + 1] = { item = item.gameObject, shown = kinds[label].shown }
      item.gameObject:SetActive(kinds[label].shown() and true or false)
    end
  end
  added.lists[#added.lists + 1] = { manager = manager, rows = rows }
  return manager, added.lists[#added.lists]
end

-- the game's own settings pages a tab name puts its rows into: the page's index, and the block the rows go above
local PAGES = { Profile = { index = 1, above = "Account" } } -- above the cloud save login
local PAGE_GAP = 50 -- the space the Profile page leaves between its blocks

-- the blocks of a page sit on its slant, each one moved sideways by its height times the slope
local function shift(block, dy)
  local at = block.anchoredPosition
  block.anchoredPosition = { at.x + dy * CS.SettingItemsManager.InverseSlope, at.y + dy }
end

-- the rows take the place of the block they go above, which moves down with the ones after it. the list follows the
-- slant on its own (SettingItemsManager.RefreshPosition), and the page grows by the rows. the game turns the page's
-- scrolling off as it fits the screen, it's on while the rows are there
local function addPage(screen, name)
  local page = PAGES[name]
  local view = phigrospp.find(screen.frameAnimators[page.index].transform, "Scroll View")
  local scroll, content = view:GetComponent(UE.UI.ScrollRect), phigrospp.find(view, "Viewport/Content")
  local blocks = phigrospp.find(content, "Items")
  local above = phigrospp.find(blocks, page.above)
  local box = UE.GameObject(TAG .. name):AddComponent(UE.RectTransform)
  box:SetParent(blocks, false)
  box.anchorMin, box.anchorMax, box.pivot = above.anchorMin, above.anchorMax, above.pivot
  box.sizeDelta, box.anchoredPosition = { above.sizeDelta.x, 0 }, { 0, above.anchoredPosition.y }
  local holder = UE.GameObject("Items"):AddComponent(UE.RectTransform)
  holder:SetParent(box, false)
  holder.anchorMin, holder.anchorMax, holder.pivot, holder.sizeDelta = { 0, 1 }, { 1, 1 }, { 0.5, 1 }, { 0, 0 }
  local manager, rows = list(screen, box, box, holder, name)
  manager.offset = 0
  manager:RefreshItems()
  manager:RefreshPosition()
  local grown = box.sizeDelta.y + PAGE_GAP
  local moved, at = {}, {}
  for i = above:GetSiblingIndex(), blocks.childCount - 2 do -- the box is the last child
    moved[#moved + 1] = blocks:GetChild(i)
    shift(moved[#moved], -grown)
    at[#moved] = moved[#moved].anchoredPosition.y
  end
  content.sizeDelta = { content.sizeDelta.x, content.sizeDelta.y + grown }
  added.pages[#added.pages + 1] = { box = box, content = content, blocks = blocks, grown = grown, moved = moved,
    scroll = scroll, scrolled = scroll.enabled, manager = manager, at = at }
  rows.page = added.pages[#added.pages]
  scroll.enabled = true
end

-- rows shown or hidden by their condition, and the list closing or opening the gap. a page's blocks below move along
local function refresh(rows)
  local changed
  for _, row in ipairs(rows.rows) do
    local shown = row.shown() and true or false
    if shown ~= row.item.activeSelf then
      row.item:SetActive(shown)
      changed = true
    end
  end
  if not changed then return end
  local page = rows.page
  if not page then return rows.manager:RefreshItems() end
  -- in the order addPage lays it out
  page.manager.offset = 0
  page.manager:RefreshItems()
  page.manager:RefreshPosition()
  local grown = page.box.sizeDelta.y + PAGE_GAP
  for i, block in ipairs(page.moved) do
    shift(block, page.grown - grown)
    page.at[i] = block.anchoredPosition.y
  end
  page.content.sizeDelta = { page.content.sizeDelta.x, page.content.sizeDelta.y + grown - page.grown }
  page.grown = grown
end

-- a copy of the last tab and page, emptied and filled with one toggle per setting
local function addTab(screen, name, index)
  -- the button comes from a closed tab. the page comes from the last one, which may be open: its animator keeps
  -- writing the opacity it saw when created, so it's copied while wearing a closed page's for an instant
  local button = copy(screen.tabAnimators[added.closed], name)
  local source = screen.frameAnimators[added.first - 1]:GetComponent(UE.CanvasGroup)
  local closed = screen.frameAnimators[added.closed]:GetComponent(UE.CanvasGroup)
  local open = { source.alpha, source.interactable, source.blocksRaycasts }
  source.alpha, source.interactable, source.blocksRaycasts = closed.alpha, closed.interactable, closed.blocksRaycasts
  local page = copy(source, name)
  source.alpha, source.interactable, source.blocksRaycasts = table.unpack(open)
  button:GetComponent(UE.UI.Text).text = name
  -- the copied button still calls Setting.ChangeTab with the copied tab's index
  local click = button:GetComponentInChildren(UE.UI.Button).onClick
  click.m_PersistentCalls.m_Calls._items[0].m_Arguments.m_IntArgument = index
  click.m_CallsDirty = true

  local content = page.transform:Find("Scroll View/Viewport/Content")
  local items = content:Find("Items")
  for i = items.childCount - 1, 0, -1 do UE.Object.Destroy(items:GetChild(i).gameObject) end
  for i = page.transform.childCount - 1, 0, -1 do
    local child = page.transform:GetChild(i)
    if child.name ~= "Scroll View" then UE.Object.Destroy(child.gameObject) end
  end

  local manager = list(screen, content.parent, content, items, name)
  manager.offset = screen.settingItemsManager.offset
  manager:RefreshItems()
  return { button = button, page = page, content = content, index = index }
end

local function stretched(name, parent)
  local go = UE.GameObject(TAG .. name)
  go.layer = parent.gameObject.layer
  local t = go:AddComponent(UE.RectTransform)
  t:SetParent(parent, false)
  t.anchorMin, t.anchorMax, t.pivot, t.sizeDelta, t.anchoredPosition = { 0, 0 }, { 1, 1 }, { 0, 0.5 }, { 0, 0 }, { 0, 0 }
  return t
end

-- a chevron just outside one side of the tab bar, shown while more tabs are hidden that way
local function arrow(view, glyph, side)
  local tab = added.bar.transform:GetChild(0):GetComponent(UE.UI.Text)
  local t = stretched(glyph, view.parent)
  t.anchorMin, t.anchorMax, t.pivot, t.sizeDelta = { side, 0 }, { side, 1 }, { 1 - side, 0.5 }, { tab.fontSize, 0 }
  local label = t.gameObject:AddComponent(UE.UI.Text)
  label.font, label.fontSize, label.color, label.text = tab.font, tab.fontSize, { 1, 1, 1, 1 }, glyph
  label.alignment, label.raycastTarget = 4, false -- MiddleCenter, drags go to the scroll view
  return label
end

-- the game's tab bar only fits a few tabs, so its tabs and their highlight go in a horizontal scroll view
local function scrollable(bar)
  local strip = bar.transform
  local root, slider = strip.parent, UE.Object.FindObjectOfType(CS.SettingTabSliderController).transform
  local view = stretched("Scroll", root)
  local content = stretched("Content", view)
  view:SetSiblingIndex(slider:GetSiblingIndex())
  content.anchorMax = { 0, 1 }
  slider:SetParent(content, false)
  strip:SetParent(content, false)
  view.gameObject:AddComponent(UE.UI.RectMask2D)
  view.gameObject:AddComponent(UE.UI.Image).color = { 0, 0, 0, 0 } -- so drags between tabs scroll too
  local scroll = view.gameObject:AddComponent(UE.UI.ScrollRect)
  scroll.viewport, scroll.content, scroll.horizontal, scroll.vertical = view, content, true, false
  scroll.movementType = 2 -- Clamped
  added.scroll = { view = view, content = content, slider = slider, left = arrow(view, "<", 0), right = arrow(view, ">", 1) }
end

local function unscrollable(s, strip)
  local root, index = s.view.parent, s.view:GetSiblingIndex()
  s.slider:SetParent(root, false)
  s.slider:SetSiblingIndex(index)
  strip:SetParent(root, false)
  strip:SetSiblingIndex(index + 1)
  for _, object in ipairs({ s.view, s.left, s.right }) do UE.Object.DestroyImmediate(object.gameObject) end
end

-- fits the scroll view to the tabs, and brings a newly selected tab into view
local function follow()
  local s, strip = added.scroll, added.bar.transform
  local last, viewWidth = strip:GetChild(strip.childCount - 1), s.view.rect.m_Width
  local width = math.max(viewWidth, last.anchoredPosition.x + last.rect.m_Width / 2 + added.bar.paddingLeft)
  if width ~= s.width then
    s.width = width
    s.content.sizeDelta = { width, 0 }
  end
  if added.screen.currentTab ~= s.tab then
    s.tab = added.screen.currentTab
    local x = strip:GetChild(s.tab).anchoredPosition.x
    s.content.anchoredPosition = { math.max(viewWidth - width, math.min(0, viewWidth / 2 - x)), 0 }
  end
  local x = s.content.anchoredPosition.x
  s.left.enabled, s.right.enabled = x < -1, x > viewWidth - width + 1
end

local function inject(screen)
  built = layout()
  added = { screen = screen, tabs = {}, pages = {}, items = {}, titles = {}, bars = {}, lists = {} }
  local shown = {}
  for _, name in ipairs(shownTabs()) do
    if PAGES[name] then addPage(screen, name) else shown[#shown + 1] = name end
  end
  if #shown == 0 then return end
  local bar = UE.Object.FindObjectOfType(CS.SettingTabController)
  local first = #screen.tabAnimators
  added.bar, added.first = bar, first
  added.closed = screen.currentTab == first - 1 and first - 2 or first - 1
  added.original = {
    entries(screen.tabAnimators, first), entries(screen.frameAnimators, first),
    entries(screen.tabScrollContents, first), entries(bar.tabTitles, first),
  }
  local buttons, pages, contents, titles = {}, {}, {}, {}
  for i, name in ipairs(shown) do
    local tab = addTab(screen, name, first + i - 1)
    added.tabs[i] = tab
    buttons[i], pages[i], contents[i] = tab.button:GetComponent(UE.Animator), tab.page:GetComponent(UE.Animator),
        tab.content
    titles[i] = text(name)
  end
  screen.tabAnimators = entries(screen.tabAnimators, first, buttons)
  screen.frameAnimators = entries(screen.frameAnimators, first, pages)
  screen.tabScrollContents = entries(screen.tabScrollContents, first, contents)
  bar.tabTitles = entries(bar.tabTitles, first, titles)
  bar:Refresh()
  scrollable(bar)
end

-- the copies start in the state of the tab they come from, which may be the open one, and their animators
-- only take parameters once they ran a frame
local function hide()
  added.hidden = true
  for _, tab in ipairs(added.tabs) do
    if added.screen.currentTab ~= tab.index then
      tab.page:GetComponent(UE.Animator):SetBool("Hide", true)
      tab.button:GetComponent(UE.Animator):SetBool("Selected", false)
    end
  end
end

local function remove()
  for _, page in ipairs(added.pages) do
    UE.Object.DestroyImmediate(page.box.gameObject)
    for _, block in ipairs(page.moved) do shift(block, page.grown) end
    page.content.sizeDelta = { page.content.sizeDelta.x, page.content.sizeDelta.y - page.grown }
    page.content.anchoredPosition, page.blocks.anchoredPosition = { 0, 0 }, { 0, 0 }
    page.scroll.enabled = page.scrolled
  end
  local screen, bar = added.screen, added.bar
  if bar then
    if screen.currentTab >= added.first then screen:ChangeTab(added.first - 1) end
    screen.tabAnimators, screen.frameAnimators, screen.tabScrollContents, bar.tabTitles = table.unpack(added.original)
    for _, tab in ipairs(added.tabs) do
      UE.Object.DestroyImmediate(tab.button) -- Destroy waits for the end of the frame, after Refresh
      UE.Object.DestroyImmediate(tab.page)
    end
    unscrollable(added.scroll, bar.transform)
    bar:Refresh()
  end
  added = nil
end

on("update", function()
  if added and not il2cpp.alive(added.screen) then added = nil end
  -- a tab or row shown or hidden while the screen is open: it's built again
  local wanted = layout()
  if wanted ~= built then
    built = wanted
    local screen = added and added.screen or UE.Object.FindObjectOfType(CS.Setting)
    local open = screen and screen.currentTab
    if added then remove() end
    if screen then
      inject(screen)
      -- the tab that was open, once the copies ran a frame (see hide)
      if added and open < #screen.tabAnimators then added.reopen = open end
    end
  end
  if added then
    if not added.hidden then
      hide()
    elseif added.reopen then
      added.screen:ChangeTab(added.reopen)
      added.reopen = nil
    end
    if added.scroll then follow() end
    -- a scrolled page slides sideways along the slant, like the game's lists (SettingItemsManager.RefreshPosition)
    for _, page in ipairs(added.pages) do
      page.blocks.anchoredPosition = { page.content.anchoredPosition.y * CS.SettingItemsManager.InverseSlope, 0 }
      -- the page's animator puts its blocks back where the game has them as it opens, they go below the rows again
      -- and the rows take the place of the block they go above
      for i, block in ipairs(page.moved) do
        if block.anchoredPosition.y ~= page.at[i] then
          if i == 1 then page.box.anchoredPosition = { 0, block.anchoredPosition.y } end
          shift(block, -page.grown)
          page.at[i] = block.anchoredPosition.y
        end
      end
    end
    for label, item in pairs(added.items) do
      if item.Value ~= values[label] then
        values[label] = math.type(values[label]) == "integer" and math.floor(item.Value + 0.5) or item.Value
        if kinds[label].type == "slider" then item:SetTitle(title(label)) end
        saveSoon()
        phigrospp.emit("setting", label, values[label])
      end
    end
    for _, rows in ipairs(added.lists) do refresh(rows) end
    for fn, b in pairs(added.bars) do drawBar(fn, b) end
    for label, row in pairs(added.titles) do
      if label() ~= row.shown then
        row.shown = label()
        row.item:SetTitle(text(row.shown))
      end
    end
  end
end)

-- the settings screen builds its own tabs in Start, ours go after them
hook(CS.Setting, "Start", { after = inject })

-- or right away when mods load while it's open
on("load", function()
  local screen = UE.Object.FindObjectOfType(CS.Setting)
  if screen then inject(screen) end
end)

on("unload", function()
  if added then remove() end
end)


