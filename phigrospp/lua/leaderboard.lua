-- the phigros.tools leaderboard: a trophy left of the chapter screen's settings slides the players by RKS in over it, 50
-- more each time the list nears its end. the player's own row is white, a row opens the player's page on phigros.tools

local UE = CS.UnityEngine
local kit, find = phigrospp.ui, phigrospp.find
local SLOPE = CS.SettingItemsManager.InverseSlope -- the game's slant: sideways per unit of height
local ROW, STEP, MORE = 88, 104, 10 -- a row's height, from a row to the next, rows left when the next 50 load
local WHITE, BLACK, DIM = { 1, 1, 1, 1 }, { 0, 0, 0, 1 }, { 1, 1, 1, 0.5 }

local canvas, font, screen
local verified = false
local shortcuts -- the last tab kit.shortcut made on this chapter screen, and how many there are

-- a copy of a tab of the chapter screen showing a Lucide icon
local function tab(original, offset, icon, fn)
  local copy = kit.clone(original, offset, fn)
  local image = find(copy.transform, "Image")
  image.sizeDelta = { 44, 44 } -- like the game's icons
  image:GetComponent(UE.UI.Image).sprite = kit.icon(icon)
  return copy
end

-- a tab left of the chapter screen's settings one and of those made before it, showing an icon and running fn. each
-- goes under the one on its right, which hides its square end behind its stripe: the icon moves left by what that
-- covers, to the middle of what shows
function kit.shortcut(icon, fn)
  local settings = UE.GameObject.Find("Canvas/Settings").transform
  shortcuts = shortcuts or { last = settings, count = 0 }
  shortcuts.count = shortcuts.count + 1
  local made = tab(settings, { -settings.sizeDelta.x * shortcuts.count, 0 }, icon, fn).transform
  made:SetSiblingIndex(shortcuts.last:GetSiblingIndex())
  local image = find(made, "Image")
  image.anchoredPosition = { image.anchoredPosition.x - 12, image.anchoredPosition.y }
  shortcuts.last = made
end

-- a player's avatar (the game's key of it, as phigros.tools gives it) in a square placed like kit.rect does. one
-- this version of the game doesn't have yet shows as the default one
function kit.avatar(parent, name, pos, size, key)
  local image = kit.rect(parent, name, pos, { size, size }, WHITE)
  local avatars = UE.Object.FindObjectOfType(CS.GetCollectionControl).Avatars
  key = avatars:ContainsKey(key) and key or "Introduction"
  image.gameObject:AddComponent(CS.AddressableImageLoader).Code = avatars:get_Item(key).addressableKey
  return image
end

local function row(s, entry)
  local player = entry.player
  local mine = ("%s#%04d"):format(player.name, player.number) == phigrospp.tag()
  local ink = mine and BLACK or WHITE
  local y = #s.rows * STEP
  local shape = kit.bar(s.list.rows, "phigrospp-leaderboard-row", { -y * SLOPE, -y }, { s.list.width, ROW },
    mine and WHITE or { 1, 1, 1, 0.08 })
  shape.raycastTarget = true
  local function text(x, size, alignment, pivot, value, colour)
    local t = kit.text(shape.transform, "phigrospp-leaderboard-text", font, { x, ROW / 2 }, { 0, 0 }, size, alignment, pivot)
    t.text, t.color, t.supportRichText = value, colour, false
    return t
  end
  text(100, 40, 5, { 1, 0.5 }, tostring(entry.rank), ink) -- MiddleRight
  kit.avatar(shape.transform, "phigrospp-leaderboard-avatar", { 124, ROW / 2 }, 64, player.avatar)
  local name = text(212, 40, 3, { 0, 0.5 }, player.name, ink) -- MiddleLeft
  text(220 + name.preferredWidth, 32, 3, { 0, 0.5 }, ("#%04d"):format(player.number), mine and { 0, 0, 0, 0.5 } or DIM)
  text(s.list.width - 48, 40, 5, { 1, 0.5 }, ("%.2f"):format(entry.rks), ink)
  phigrospp.click(shape.gameObject:AddComponent(UE.UI.Button), function()
    UE.Application.OpenURL(("%s/players/%s"):format(phigrospp.site, player.id))
  end)
  s.rows[#s.rows + 1] = shape.gameObject
end

-- the next 50 players. an answer for the list before a switch of Verified only is dropped
local function load(s)
  local asked = s.asked
  s.loading = true
  phigrospp.request("GET", ("/api/players?page=%d%s"):format(s.page + 1, verified and "&verified=1" or ""), nil,
    function(status, body)
      if screen ~= s or s.asked ~= asked then return end
      s.loading = false
      if status ~= 200 then
        s.count = #s.rows -- nothing more is asked until the list starts again
        if #s.rows == 0 then s.message.text = "phigros.tools can't be reached" else toast("phigros.tools can't be reached") end
        return
      end
      local answer = phigrospp.json.decode(body)
      s.page, s.count = s.page + 1, answer.count
      for _, entry in ipairs(answer.players) do row(s, entry) end
      s.list.content.sizeDelta = { 0, #s.rows * STEP + 32 }
      s.message.text = #s.rows == 0 and "No player is ranked yet" or ""
    end)
end

local function restart(s)
  for _, r in ipairs(s.rows) do UE.Object.Destroy(r) end
  s.rows, s.page, s.count, s.asked = {}, 0, math.huge, s.asked + 1
  s.list.content.anchoredPosition, s.message.text = { 0, 0 }, ""
  load(s)
end

local function open()
  if screen then return end
  local width, height = canvas.rect.m_Width, canvas.rect.m_Height
  local s = kit.panel(canvas, "phigrospp-leaderboard", function() screen = nil end)
  local root = s.transform
  s.asked, s.rows = 0, {}
  tab(find(canvas, "Collection"), { 0, 0 }, "arrow-left", s.close).transform:SetParent(root, false)

  local middle = height - 66 -- of the tabs at the top
  kit.text(root, "phigrospp-leaderboard-title", font, { 220, middle }, { 0, 0 }, 56, 3, { 0, 0.5 }).text = "Leaderboard"
  local label = kit.text(root, "phigrospp-leaderboard-verified", font, { width - 64, middle }, { 0, 0 }, 40, 5, { 1, 0.5 })
  label.text = "Verified only"
  local box = kit.rect(root, "phigrospp-leaderboard-box", { width - 84 - label.preferredWidth, middle }, { 48, 48 }, WHITE,
    { 1, 0.5 })
  local function tick() box.sprite = kit.icon(verified and "square-check" or "square") end
  tick()
  local toggle = kit.rect(root, "phigrospp-leaderboard-toggle", { width - 32, middle }, { label.preferredWidth + 136, 112 },
    { 0, 0, 0, 0 }, { 1, 0.5 })
  toggle.raycastTarget = true
  phigrospp.click(toggle.gameObject:AddComponent(UE.UI.Button), function()
    verified = not verified
    tick()
    restart(s)
  end)

  s.list = kit.list(root, "phigrospp-leaderboard-list", { 0, 30 }, { width, middle - 114 }, math.floor(width * 0.6))
  s.message = kit.text(root, "phigrospp-leaderboard-message", font, { width / 2, height / 2 }, { 0, 0 }, 44, 4,
    { 0.5, 0.5 }) -- MiddleCenter
  s.message.color = DIM
  screen = s
  restart(s)
end

on("scene", function(name)
  screen, shortcuts = nil, nil
  if name ~= "ChapterSelector" then return end
  canvas = UE.GameObject.Find("Canvas/Settings").transform.parent
  font = UE.Object.FindObjectOfType(CS.ChapterSelector).nowLevel.font
  kit.shortcut("trophy", open)
end)

on("update", function()
  local s = screen
  if not s or s.loading or #s.rows >= s.count then return end
  local scrolled = s.list.content.anchoredPosition.y
  if scrolled > (#s.rows - MORE) * STEP - s.list.transform.rect.m_Height then load(s) end
end)
