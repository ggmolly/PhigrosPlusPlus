-- the Mods tab of the settings: the mods installed from GitHub (a switch each, a mark when a release is newer), the
-- ones phigros.tools lists, then the built-in ones and those of mods/. a row opens the mod's page: its clip, what its
-- README says and what can be done with it. a repository's link in the clipboard, or a
-- phigrospp://install/<owner>/<name> link, installs any other mod behind a warning

local UE, IO = CS.UnityEngine, CS.System.IO
local kit, mods = phigrospp.ui, phigrospp.mods
local SLOPE = CS.SettingItemsManager.InverseSlope
local ROW, STEP, HEADER = 112, 128, 72 -- a row's height, from a row to the next, a section title's
local LEFT, COLUMN = 330, 1050 -- a mod's page: where it starts (as the rows' texts do) and how wide it is
local HEADINGS = { 44, 36, 30 } -- the font sizes of a README's headings, by level
local CLIPS = 2 -- the videos of a README that play, the others show their poster
local CHECK = 3600 -- seconds github's answer about a mod is kept for
local WHITE, DIM, FAINT, NEW = { 1, 1, 1, 1 }, { 1, 1, 1, 0.5 }, { 1, 1, 1, 0.08 }, { 0.56, 0.86, 1, 1 }
local WARNING = "Nobody reviewed this mod. A mod can do everything Phigros++ can, like reading your phigros.tools key: "
    .. "install it only if you trust who made it."

local page -- the tab while the settings show it: { view =, font =, list =, rows = its objects, y = where the next goes }
local latest = {} -- repo -> the latest release of an installed mod that isn't of the catalog, from github
local posters, readmes = {}, {} -- path -> Texture, repo -> its README's blocks
local link -- the repo of the link the app was opened with, until the chapter screen can ask about it
local shown -- the mod's page while it's open
local redraw

local function size(bytes) return bytes < 1e6 and ("%d KB"):format(bytes // 1000 + 1) or ("%.1f MB"):format(bytes / 1e6) end

-- waits in a coroutine for what start gives its callback
local function wait(start)
  local co = coroutine.running()
  start(function(...) assert(coroutine.resume(co, ...)) end)
  return coroutine.yield()
end

-- whether a mod's author is who the registry says: a mod of the catalog not installed yet (its release is checked
-- as it's installed), or an installed one whose release their key signed
local function verified(repo)
  local m, author = mods.installed[repo], mods.registry.authors[repo:match("^[^/]+")]
  return author ~= nil and (not m or m.key == phigrospp.hex(author))
end

-- the newest release known of a mod: the catalog's for its mods, github's for the others
local function newest(repo) return mods.catalog and mods.catalog[repo] or latest[repo] end

-- what phigros.tools lists, then what github has for the installed mods it doesn't. done() runs once phigros.tools
-- answered or didn't
local function load(done)
  mods.refresh(function()
    for repo in pairs(mods.installed) do
      if not mods.registry.listed[repo] then
        mods.latest(repo, function(release)
          latest[repo] = release
          redraw()
        end, CHECK)
      end
    end
    done()
  end)
end

-- downloads and installs releases one after the other behind a progress bar, then reloads into them. from a coroutine
local function install(releases)
  local at, job, failed = 0, nil, nil
  local function step()
    at = at + 1
    local release = releases[at]
    if not release then return kit.close(true) end
    job = mods.install(release, function(why)
      if not why then return step() end
      failed = ("%s wasn't installed: %s."):format(release.name or release.repo, why)
      kit.close(false)
    end)
  end
  step()
  -- a mod of the catalog goes by its name, another by its repository
  local function name(release) return release.name or release.repo end
  local done = kit.confirm({ title = #releases == 1 and name(releases[1]) or "Updating mods", message = "Downloading",
    yes = false, no = "Cancel", progress = function()
      local release = releases[at]
      return job.progress(), #releases == 1 and ("Downloading %s"):format(size(release.size))
        or ("Downloading %s, %s"):format(name(release), size(release.size))
    end })
  if failed then
    kit.confirm({ title = "Mods", message = failed, yes = "OK", no = false })
  elseif not done then
    job.cancelled = true
    job.request:Abort()
  end
  if done or at > 1 then phigrospp.reload() end -- into the ones that were installed
end

-- asks whether to install the mod a link names, behind a warning when it isn't of the catalog. from a coroutine
local function ask(repo)
  wait(load)
  local release, why = newest(repo), nil
  if not release then release, why = wait(function(done) mods.latest(repo, done) end) end
  if not release then
    return kit.confirm({ title = repo, message = ("This mod can't be installed: %s."):format(why), yes = "OK", no = false })
  end
  local listed = mods.registry.listed[repo]
  if kit.confirm({ title = ("%s %s"):format(repo, release.version), yes = "Install", danger = not listed,
        message = listed and ("A mod of the catalog, %s to download."):format(size(release.size)) or WARNING }) then
    install({ release })
  end
end

-- the "Install from GitHub" row: the mod the clipboard names
local function paste()
  local repo = mods.repo(UE.GUIUtility.systemCopyBuffer or "")
  if repo then return ask(repo) end
  kit.confirm({ title = "Install from GitHub", yes = "OK", no = false,
    message = "Copy the link of a mod's GitHub repository, then tap here again." })
end

-- drawing ----------------------------------------------------------------------------------------------------------

-- texts never read markup: names and descriptions come from other people
local function text(parent, pos, fontSize, value, colour, alignment, pivot)
  local t = kit.text(parent, "phigrospp-mods-text", page.font, pos, { 0, 0 }, fontSize, alignment or 3, pivot) -- MiddleLeft
  t.text, t.color, t.supportRichText = value, colour, false
  return t
end

-- a text kept inside a box, from its top left corner: it wraps and what doesn't fit is cut
local function boxed(parent, pos, box, fontSize, value, colour)
  local t = text(parent, pos, fontSize, value, colour, 0, { 0, 1 }) -- UpperLeft
  t.transform.sizeDelta, t.horizontalOverflow, t.verticalOverflow = box, 0, 0 -- Wrap, Truncate
  return t
end

-- a text as wide as given that takes the lines it needs, from its top left corner: the text and its height. markup
-- is only read when asked (ours, see rich), and before the height is: tags would count as text
local function flowed(parent, pos, width, fontSize, value, colour, markup)
  local t = boxed(parent, pos, { width, 0 }, fontSize, value, colour)
  t.verticalOverflow, t.supportRichText = 1, markup or false -- Overflow
  return t, t.preferredHeight
end

-- shows a poster of phigros.tools in a RawImage once it's downloaded
local function poster(view, path)
  local function show()
    if not il2cpp.alive(view) then return end
    view.color = WHITE
    kit.fit(view, posters[path])
  end
  if posters[path] then return show() end
  phigrospp.request("GET", "/catalog/" .. path, nil, function(status, body)
    if status ~= 200 then return end
    posters[path] = posters[path] or phigrospp.texture(body)
    show()
  end)
end

-- a line of facts about a mod at pos: its author's verified mark before them, its stars behind a star after them
local function facts(parent, pos, fontSize, values, repo, stars)
  local x = pos[1]
  if verified(repo) then
    kit.rect(parent, "phigrospp-mods-verified", pos, { fontSize * 1.1, fontSize * 1.1 }, NEW).sprite = kit.icon("badge-check")
    x = x + fontSize * 1.4
  end
  local line = text(parent, { x, pos[2] }, fontSize, table.concat(values, " · ") .. (stars and " ·" or ""), DIM)
  if not stars then return end
  x = x + line.preferredWidth + fontSize * 0.35
  kit.rect(parent, "phigrospp-mods-star", { x, pos[2] }, { fontSize * 0.9, fontSize * 0.9 }, DIM).sprite = kit.icon("star")
  text(parent, { x + fontSize * 1.15, pos[2] }, fontSize, tostring(stars), DIM)
end

local function tappable(shape, fn)
  shape.raycastTarget = true
  phigrospp.click(shape.gameObject:AddComponent(UE.UI.Button), fn)
end

-- how many characters the game counts in a text: its strings are utf-16
local function units(value)
  local n = 0
  for _, c in utf8.codes(value) do n = n + (c > 0xFFFF and 2 or 1) end
  return n
end

-- a README's spans as the game's rich text, and its links: { from = the place of the link's first character in that
-- text, count =, url = }. the only tags are ours: a "<" of theirs is kept from starting one
local function rich(spans, bold)
  local parts, links, at = {}, {}, bold and 3 or 0 -- after the "<b>" around a bold text
  for i, span in ipairs(spans) do
    local t = span.text:gsub("<", "<\u{200B}")
    local colour = (span.code or span.link) and ("<color=%s>"):format(span.code and "#ffd9a0" or "#8fdcff") or ""
    local open = (span.bold and "<b>" or "") .. (span.italic and "<i>" or "") .. colour
    if span.link then links[#links + 1] = { from = at + #open, count = units(t), url = span.link } end
    parts[i] = open .. t .. (colour ~= "" and "</color>" or "") .. (span.italic and "</i>" or "") .. (span.bold and "</b>" or "")
    at = at + units(parts[i])
  end
  local value = table.concat(parts)
  return bold and "<b>" .. value .. "</b>" or value, links
end

-- a link of a README is another mod to install, or a page for the browser
local function follow(url)
  local repo = url:match("^phigrospp://install/") and mods.repo(url)
  if repo then return ask(repo) end
  UE.Application.OpenURL(url)
end

-- tap areas over the links of a text, a line of it each. the game says where its characters are (tags count as
-- characters without a width) once it drew the text
local function linked(t, links)
  local generator, scale = t.cachedTextGenerator, t.pixelsPerUnit
  local chars, lines = generator.characters, generator.lines
  for _, found in ipairs(links) do
    for i = 0, lines.Count - 1 do
      local line = lines:get_Item(i)
      local next = i + 1 < lines.Count and lines:get_Item(i + 1).startCharIdx or chars.Count
      local from, to = math.max(found.from, line.startCharIdx), math.min(found.from + found.count, next) - 1
      if from <= to then
        local first, last = chars:get_Item(from), chars:get_Item(to)
        local area = kit.rect(t.transform, "phigrospp-mod-link", { first.cursorPos.x / scale, (line.topY - line.height) / scale },
          { (last.cursorPos.x + last.charWidth - first.cursorPos.x) / scale, line.height / scale }, { 0, 0, 0, 0 }, { 0, 0 })
        tappable(area, function() follow(found.url) end)
      end
    end
  end
end

-- draws a README's blocks (server/readme.ts of phigros.tools) in body, down from y: where they end. its title and
-- what the page already shows on top aren't drawn again
local function document(body, blocks, y, shownAbove)
  local clips, texts = 0, {}
  local function write(spans, indent, fontSize, colour, bold)
    local value, links = rich(spans, bold)
    local t, height = flowed(body, { LEFT + indent, -y }, COLUMN - indent, fontSize, value, colour, true)
    if #links > 0 then texts[#texts + 1] = { text = t, links = links } end
    return height
  end
  for i, block in ipairs(blocks) do
    if block.kind == "heading" then
      if i > 1 or block.level > 1 then
        y = y + 20
        y = y + write(block.spans, 0, HEADINGS[block.level], WHITE, true) + 16
        -- a line under the two biggest, as github draws them
        if block.level < 3 then
          kit.rect(body, "phigrospp-mod-rule", { LEFT, -y + 8 }, { COLUMN, 2 }, FAINT, { 0, 1 })
          y = y + 14
        end
      end
    elseif block.kind == "text" then
      y = y + write(block.spans, 0, 28, WHITE) + 18
    elseif block.kind == "item" then
      local indent = block.depth * 40
      text(body, { LEFT + indent, -y - 18 }, 28, block.mark, DIM)
      y = y + write(block.spans, indent + 48, 28, WHITE) + 10
    elseif block.kind == "quote" then
      local height = write(block.spans, 28, 28, DIM)
      kit.rect(body, "phigrospp-mod-quote", { LEFT, -y }, { 6, height }, DIM, { 0, 1 })
      y = y + height + 18
    elseif block.kind == "code" then
      local t, height = flowed(body, { LEFT + 20, -y - 16 }, COLUMN - 40, 24, block.text, { 1, 0.85, 0.63, 1 })
      kit.rect(body, "phigrospp-mod-code", { LEFT, -y }, { COLUMN, height + 32 }, FAINT, { 0, 1 })
      t.transform:SetAsLastSibling()
      y = y + height + 32 + 18
    elseif block.kind == "rule" then
      kit.rect(body, "phigrospp-mod-rule", { LEFT, -y - 10 }, { COLUMN, 2 }, FAINT, { 0, 1 })
      y = y + 40
    elseif block.poster ~= shownAbove then
      -- as wide as it is, within the column and 480 high
      local scale = math.min(1, COLUMN / block.width, 480 / block.height)
      local box = { block.width * scale, block.height * scale }
      if block.clip and clips < CLIPS then
        clips = clips + 1
        kit.video(body, "phigrospp-mod-media", { LEFT, -y }, box, ("%s/catalog/%s"):format(phigrospp.site, block.clip),
          posters[block.poster], { 0, 1 })
      else
        local view = kit.place(body, "phigrospp-mod-media", UE.UI.RawImage, { LEFT, -y }, box, { 0, 1 })
        view.color = FAINT
        poster(view, block.poster)
      end
      y = y + box[2] + 24
    end
  end
  -- the links are found once the texts are drawn
  after(0.1, function()
    for _, linking in ipairs(texts) do
      if il2cpp.alive(linking.text) then linked(linking.text, linking.links) end
    end
  end)
  return y
end

-- a mod's page, in place of the list on the tab's own background: its clip or poster beside its name, what can be
-- done with it, then its README. it scrolls as a whole. the game's back button closes it (see the hook below)
local function show(repo)
  local m, info, new = mods.installed[repo], mods.catalog and mods.catalog[repo], newest(repo)
  local list, area = page.list.transform.gameObject, page.view.rect
  list:SetActive(false)
  shown = kit.panel(page.view, "phigrospp-mod", function()
    shown = nil
    if il2cpp.alive(list) then list:SetActive(true) end
  end, 0)
  local scroll = kit.list(shown.transform, "phigrospp-mod-page", { 0, 0 }, { area.m_Width, area.m_Height })
  local body = scroll.rows
  local y, side = 160, LEFT -- under the name and its facts, which go right of the preview when there's one
  if info and info.poster then
    local box = { 640, 360 }
    if info.clip then
      kit.video(body, "phigrospp-mod-clip", { LEFT, -30 }, box, ("%s/catalog/%s"):format(phigrospp.site, info.clip),
        posters[info.poster], { 0, 1 })
    else
      local view = kit.place(body, "phigrospp-mod-poster", UE.UI.RawImage, { LEFT, -30 }, box, { 0, 1 })
      view.color = FAINT
      poster(view, info.poster)
    end
    side, y = LEFT + box[1] + 40, 30 + box[2]
  end
  text(body, { side, -66 }, 52, info and info.name or repo:match("/(.*)"), WHITE)
  local update = m and new and new.version ~= m.version
  facts(body, { side, -130 }, 28, { repo:match("^[^/]+"),
    update and ("%s, %s is out"):format(m.version, new.version) or (m or new).version, size((m or new).size) }, repo,
    info and info.stars)

  y = y + 30
  local at = LEFT
  local function action(label, fn, colour)
    -- five of them fit the column
    local shape = kit.bar(body, "phigrospp-mod-action", { at, -y }, { 196, 76 }, FAINT)
    text(shape.transform, { 98, 38 }, 28, label, colour or WHITE, 4, { 0.5, 0.5 }) -- MiddleCenter
    tappable(shape, fn)
    at = at + 212
  end
  if update or not m then
    action(m and "Update" or "Install", function()
      shown.close() -- the download shows over the list
      install({ new })
    end, NEW)
  end
  local settings = m and phigrospp.tabOf(mods.folder(repo))
  if settings then
    action("Settings", function()
      shown.close()
      phigrospp.openTab(settings)
    end)
  end
  if m then
    action(m.enabled and "Disable" or "Enable", function()
      mods.enable(repo, not m.enabled)
      phigrospp.reload()
    end)
    action("Uninstall", function()
      if kit.confirm({ title = "Uninstall " .. repo, message = "Its settings are kept.", yes = "Uninstall", danger = true }) then
        mods.uninstall(repo)
        phigrospp.reload()
      end
    end, kit.danger)
  end
  action("GitHub", function() UE.Application.OpenURL("https://github.com/" .. repo) end)

  y = y + 76 + 36
  local function fits() scroll.content.sizeDelta = { 0, y + 60 } end
  if m and m.error then y = y + select(2, flowed(body, { LEFT, -y }, COLUMN, 28, m.error, kit.danger)) + 30 end
  if not info then
    y = y + select(2, flowed(body, { LEFT, -y }, COLUMN, 28, WARNING, WHITE))
    return fits()
  end
  fits()
  local function read()
    y = document(body, readmes[repo], y, info.poster)
    fits()
  end
  if readmes[repo] then return read() end
  phigrospp.request("GET", ("/catalog/%s/readme.json"):format(repo), nil, function(status, answer)
    if status ~= 200 then return end
    readmes[repo] = phigrospp.json.decode(answer)
    if il2cpp.alive(body) then read() end
  end)
end

-- a line of text between rows: a section's title, or what there is to say of an empty one
local function label(value, colour)
  local t = text(page.list.rows, { 8 - page.y * SLOPE, -page.y - HEADER / 2 }, 30, value, colour)
  page.rows[#page.rows + 1] = t.gameObject
  page.y = page.y + HEADER
end

-- a row: { title =, text = the dimmer line under it, or facts = (with repo = and stars =) for a mod's, poster = shown
-- on its left, mark = and colour = said on its right, switch = whether its box is ticked and toggle = what tapping the
-- box does, tap = what tapping the row does }
local function row(r)
  local list = page.list
  local shape = kit.bar(list.rows, "phigrospp-mods-row", { -page.y * SLOPE, -page.y }, { list.width, ROW }, FAINT)
  local parent, x, right = shape.transform, 40, list.width - 48
  if r.poster then
    local view = kit.place(parent, "phigrospp-mods-poster", UE.UI.RawImage, { x, ROW / 2 }, { 160, 90 })
    view.color = FAINT
    poster(view, r.poster)
    x = x + 184
  end
  if r.toggle then
    kit.rect(parent, "phigrospp-mods-box", { right, ROW / 2 }, { 48, 48 }, WHITE, { 1, 0.5 }).sprite =
        kit.icon(r.switch and "square-check" or "square")
    -- easier to hit than the box
    tappable(kit.rect(parent, "phigrospp-mods-switch", { right + 32, ROW / 2 }, { 112, ROW }, { 0, 0, 0, 0 }, { 1, 0.5 }), r.toggle)
    right = right - 80
  end
  if r.mark then right = right - text(parent, { right, ROW / 2 }, 30, r.mark, r.colour, 5, { 1, 0.5 }).preferredWidth - 32 end
  text(parent, { x, ROW / 2 + 22 }, 36, r.title, WHITE)
  if r.facts then
    facts(parent, { x, ROW / 2 - 21 }, 26, r.facts, r.repo, r.stars)
  else
    boxed(parent, { x, ROW / 2 - 4 }, { right - x, 36 }, 26, r.text, DIM)
  end
  if r.tap then tappable(shape, r.tap) end
  page.rows[#page.rows + 1] = shape.gameObject
  page.y = page.y + STEP
end

-- what a mod's file says of itself: the comment it starts with
local function described(source)
  local lines = {}
  for line in source:gmatch("([^\n]*)\n") do
    local comment = line:match("^%-%-%s?(.*)")
    if not comment then break end
    lines[#lines + 1] = comment
  end
  return table.concat(lines, " ")
end

-- the mods that come with Phigros++ and the ones of mods/, which run in place of a built-in one of the same name
local function others()
  local builtin, here = {}, {}
  for path, source in pairs(phigrospp.bundle) do
    local name = path:match("^mods/([^/]+)%.lua$") or path:match("^mods/([^/]+)/init%.lua$")
    if name then builtin[name] = described(source) end
  end
  local dir = phigrospp.root .. "/mods/"
  local function add(name, file)
    -- the loader skips these names, and a folder is only a mod with its init.lua
    if name:find("^[._]") or not IO.File.Exists(file) then return end
    here[name], builtin[name] = described(phigrospp.read(file)), nil
  end
  local files, folders = IO.Directory.GetFiles(dir, "*.lua"), IO.DirectoryInfo(dir):GetDirectories()
  for i = 0, #files - 1 do add(files[i]:match("([^/]+)%.lua$"), files[i]) end
  for i = 0, #folders - 1 do add(folders[i].Name, folders[i].FullName .. "/init.lua") end
  return builtin, here
end

-- a section of mods that are only shown: what each says of itself, by name
local function section(title, texts)
  local names = {}
  for name in pairs(texts) do names[#names + 1] = name end
  table.sort(names)
  if #names > 0 then label(title, WHITE) end
  for _, name in ipairs(names) do row({ title = name, text = texts[name] }) end
end

function redraw()
  if not page or not il2cpp.alive(page.view) then return end
  for _, object in ipairs(page.rows) do UE.Object.Destroy(object) end
  page.rows, page.y = {}, 0
  row({ title = "Install from GitHub", text = "Copy the link of a mod's repository, then tap here", tap = paste })

  local repos, updates = {}, {}
  for repo in pairs(mods.installed) do repos[#repos + 1] = repo end
  table.sort(repos)
  if #repos > 0 then label("Installed", WHITE) end
  for _, repo in ipairs(repos) do
    local m, info, new = mods.installed[repo], mods.catalog and mods.catalog[repo], newest(repo)
    local update = new and new.version ~= m.version
    if update then updates[#updates + 1] = new end
    row({ title = info and info.name or repo:match("/(.*)"), poster = info and info.poster, repo = repo,
      facts = { repo:match("^[^/]+"), m.version, size(m.size) }, stars = info and info.stars,
      mark = m.error and "Failed to load" or update and "Update", colour = m.error and kit.danger or NEW,
      switch = m.enabled, toggle = function()
        mods.enable(repo, not m.enabled)
        phigrospp.reload()
      end, tap = function() show(repo) end })
  end
  if #updates > 1 then
    row({ title = "Update all", text = ("%d mods have a new release"):format(#updates), tap = function() install(updates) end })
  end

  label("Catalog", WHITE)
  local offered = 0
  for _, mod in ipairs(mods.catalog or {}) do
    if not mods.installed[mod.repo] then
      offered = offered + 1
      row({ title = mod.name, poster = mod.poster, repo = mod.repo, tap = function() show(mod.repo) end,
        facts = { mod.author, mod.version, size(mod.size) }, stars = mod.stars })
    end
  end
  if offered == 0 then
    label(not mods.catalog and "Asking phigros.tools" or mods.catalog.failed and "phigros.tools can't be reached"
      or #mods.catalog == 0 and "No mod is listed yet" or "Every mod of the catalog is installed", DIM)
  end

  local builtin, here = others()
  section("Built-in", builtin)
  section("In mods/", here)
  page.list.content.sizeDelta = { 0, page.y + 32 }
end

-- back closes a mod's page before it leaves the settings
hook(CS.Setting, "Back", {
  skip = function()
    if not shown or not il2cpp.alive(shown.transform) then return false end -- it dies with the settings
    shown.close()
    return true
  end,
})

tab("Mods", nil, function(view, font)
  local area = view.rect
  page = { view = view, font = font, rows = {},
    list = kit.list(view, "phigrospp-mods", { 0, 0 }, { area.m_Width, area.m_Height }, math.floor(area.m_Width * 0.8)) }
  redraw()
  load(redraw)
end)

-- the mod a link names is asked about on the chapter screen, where the game's popup is loaded
on("link", function(url) link = mods.repo(url) or link end)

on("update", function()
  if link and scene() == "ChapterSelector" and not il2cpp.alive(kit.dialog) then
    local repo = link
    link = nil
    coroutine.wrap(ask)(repo)
  end
end)
