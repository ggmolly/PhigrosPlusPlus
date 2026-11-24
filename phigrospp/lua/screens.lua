-- Phigros++'s own screens over the menus (the rooms, the friends). phigrospp.ui.view(name) is one: a canvas made again
-- in each menu with that menu's font, showing one panel at a time whose parts are drawn again only when what they
-- show changed. pieces are placed in the canvas's units from its bottom left corner: 1080 high and view.width wide

local UE = CS.UnityEngine
local kit = phigrospp.ui
local WHITE, DIM, FAINT, DARK = { 1, 1, 1, 1 }, { 1, 1, 1, 0.5 }, { 1, 1, 1, 0.08 }, { 0.02, 0.13, 0.17, 1 }

-- EZ, HD, IN and AT are what a level's plate is drawn in
kit.colours = { white = WHITE, dim = DIM, faint = FAINT, dark = DARK, gold = { 1, 0.82, 0.3, 1 },
  green = { 0.6, 0.92, 0.55, 1 }, red = { 1, 0.5, 0.5, 1 }, EZ = { 0.29, 0.66, 0.29, 1 }, HD = { 0.23, 0.47, 0.75, 1 },
  IN = { 0.77, 0.23, 0.2, 1 }, AT = { 0.29, 0.29, 0.32, 1 } }

-- the song list reads the touches itself: it's off under a view's panel (a page turns it off for itself), and back
-- on once none shows
local views, covered = {}
on("update", function()
  local showing = false
  for _, view in ipairs(views) do showing = showing or view.shown() ~= nil end
  if showing and not il2cpp.alive(covered) then
    covered = scene() == "SongSelector" and UE.Object.FindObjectOfType(CS.SongSelector) or nil
  end
  if covered and not kit.paging() then covered.enabled = not showing end
  if not showing then covered = nil end
end)

-- a reload destroys the panel, the song list comes back at once
on("unload", function()
  if il2cpp.alive(covered) then covered.enabled = true end
end)

-- a checkbox ending at pos, its box before its label, both `size` high: fn runs when either is tapped. returns what
-- ticks it or not, and how wide it is
function kit.checkbox(parent, name, font, pos, size, label, checked, fn)
  local text = kit.text(parent, name, font, pos, { 0, 0 }, size, 5, { 1, 0.5 }) -- MiddleRight
  text.text = label
  local wide = text.preferredWidth
  local box = kit.rect(parent, name .. "-box", { pos[1] - wide - size / 2, pos[2] }, { size * 1.2, size * 1.2 }, WHITE,
    { 1, 0.5 })
  local function tick(on) box.sprite = kit.icon(on and "square-check" or "square") end
  tick(checked)
  local area = kit.rect(parent, name .. "-area", { pos[1] + size * 0.8, pos[2] }, { wide + size * 3.4, size * 2.8 },
    { 0, 0, 0, 0 }, { 1, 0.5 })
  area.raycastTarget = true
  phigrospp.click(area.gameObject:AddComponent(UE.UI.Button), fn)
  return tick, wide + size * 1.7
end

-- a popup of tiles to pick one of, each { icon = one of kit.icon's, label =, colour =, value = }: called like confirm,
-- it returns the value of the tile tapped, nothing when the player backs out
function kit.choose(title, choices)
  local cells = {}
  for i, choice in ipairs(choices) do
    cells[i] = { icon = kit.icon(choice.icon), label = choice.label, colour = choice.colour,
      tap = function() kit.close(choice.value) end, on = function() return false end, note = function() return "" end }
  end
  return kit.confirm({ title = title, yes = false, grid = { columns = #cells, height = 190, cells = cells } }) or nil
end

function kit.view(name)
  local V = { height = 1080, left = 60, top = 1080 - 66 } -- where the columns start, and the middle of the top bar
  local canvas, font, panel, parts

  -- a text from the middle of its left side. given a width (box), what goes past it is cut and ends with "..."
  function V.text(parent, pos, size, value, colour, alignment, pivot, box)
    local t = kit.text(parent, name .. "-text", font, pos, { box or 0, box and size * 1.5 or 0 }, size, alignment or 3, pivot)
    t.text, t.color, t.supportRichText = value, colour or WHITE, false
    if box then
      t.horizontalOverflow, t.verticalOverflow = 0, 0 -- Wrap, Truncate
      -- preferredWidth is the text's width on one line, whatever the box
      while t.preferredWidth > box and #value > 0 do
        value = value:sub(1, utf8.offset(value, -1) - 1)
        t.text = value:gsub("%s+$", "") .. "..."
      end
    end
    return t
  end

  function V.icon(parent, pos, size, icon, colour)
    local image = kit.rect(parent, name .. "-icon", pos, { size, size }, colour or WHITE)
    image.sprite = kit.icon(icon)
    return image
  end

  function V.tappable(shape, fn)
    shape.raycastTarget = true
    phigrospp.click(shape.gameObject:AddComponent(UE.UI.Button), fn)
  end

  -- a slanted bar from its top left corner with a text in its middle, which is left of its box's: its bottom leans
  function V.plate(parent, pos, size, colour, fontSize, label, ink)
    local shape = kit.bar(parent, name .. "-plate", pos, size, colour)
    V.text(shape.transform, { (size[1] - size[2] * CS.SettingItemsManager.InverseSlope) / 2, size[2] / 2 }, fontSize,
      label, ink, 4, { 0.5, 0.5 }) -- MiddleCenter
    return shape
  end

  -- a button, lit in a colour when given one. without fn it's only a label
  function V.action(parent, pos, size, label, fn, lit)
    local shape = V.plate(parent, pos, { size, 76 }, lit or FAINT, 32, label, lit and DARK or fn and WHITE or DIM)
    if fn then V.tappable(shape, fn) end
    return shape
  end

  function V.checkbox(parent, pos, label, checked, fn)
    return kit.checkbox(parent, name .. "-checkbox", font, pos, 36, label, checked, fn)
  end

  -- the back arrow of the top bar, in a square easier to tap than itself
  function V.back(root, fn)
    V.tappable(kit.rect(root, name .. "-back", { 20, V.top }, { 130, 110 }, { 0, 0, 0, 0 }), fn)
    V.icon(root, { V.left, V.top }, 56, "arrow-left")
  end

  -- the top bar's titles, after the back arrow: the screen's own in white, the others dim, and pick(title) runs when
  -- one of those is tapped. for screens that go together, like tabs
  function V.titles(root, titles, own, pick)
    local x = 220
    for _, title in ipairs(titles) do
      local wide = V.text(root, { x, V.top }, 56, title, title == own and WHITE or DIM).preferredWidth
      if title ~= own then
        V.tappable(kit.rect(root, name .. "-title", { x - 24, V.top }, { wide + 48, 110 }, { 0, 0, 0, 0 }),
          function() pick(title) end)
      end
      x = x + wide + 56
    end
  end

  -- a part of the panel shown, drawn again only when what it shows (its key) changed: draw(root) fills it
  function V.part(part, key, draw)
    local p = parts[part]
    if p and p.key == key then return end
    if p then UE.Object.Destroy(p.root.gameObject) end
    local root = UE.GameObject(("%s-%s"):format(name, part)):AddComponent(UE.RectTransform)
    root:SetParent(panel.transform, false)
    root.anchorMin, root.anchorMax, root.sizeDelta = { 0, 0 }, { 0, 0 }, { 0, 0 } -- the panel's bottom left corner
    parts[part] = { key = key, root = root }
    draw(root)
  end

  -- the canvas, made again in each scene, with the font of a text of that scene
  function V.stage()
    if not il2cpp.alive(canvas) then
      canvas, V.width = kit.screen(name, 32000)
      local chapters = UE.Object.FindObjectOfType(CS.ChapterSelector)
      font = chapters and chapters.nowLevel.font or UE.Object.FindObjectOfType(CS.SongSelector).songName.font
    end
    return canvas
  end

  -- the panel shown slides out
  function V.hide()
    if panel and il2cpp.alive(panel.transform) then panel.close() end
    panel = nil
  end

  -- the panel of a screen (any name), made when it isn't the one shown: another one's slides out
  function V.show(screen)
    if panel and (panel.screen ~= screen or not il2cpp.alive(panel.transform)) then V.hide() end
    if panel then return end
    panel = kit.panel(V.stage(), name, nil, 0.93)
    panel.screen, parts = screen, {}
  end

  -- the screen whose panel shows, nil for none
  function V.shown() return panel and il2cpp.alive(panel.transform) and panel.screen or nil end

  views[#views + 1] = V
  return V
end
