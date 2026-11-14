-- the phigros.tools leaderboard: a trophy left of the chapter screen's settings slides the players by RKS in over it, 50
-- more each time the list nears its end. the player's own row is white, a row opens the player's page on phigros.tools

local UE = CS.UnityEngine
local kit, find = phigrospp.ui, phigrospp.find
local SLIDE = 0.35 -- seconds
local SLOPE = CS.SettingItemsManager.InverseSlope -- the game's slant: sideways per unit of height
local ROW, STEP, MORE = 88, 104, 10 -- a row's height, from a row to the next, rows left when the next 50 load
local WHITE, BLACK, DIM = { 1, 1, 1, 1 }, { 0, 0, 0, 1 }, { 1, 1, 1, 0.5 }

local canvas, font, screen
local verified = false

-- a bar slanted like the game's, its bottom further left, placed from its top left corner
local function bar(parent, name, pos, size, colour)
  local shape = kit.place(parent, name, CS.Lean.Gui.LeanPolygon, pos, size, { 0, 1 })
  local lean = -size[2] * SLOPE
  for _, point in ipairs({ { 0, 0, 0, 1 }, { 0, 0, 1, 1 }, { lean, 0, 1, 0 }, { lean, 0, 0, 0 } }) do
    shape.Points:Add(point) -- offset x, y from the anchor x, y in the shape
  end
  shape.Blur, shape.color = 0.5, colour
  shape:SetVerticesDirty()
  return shape
end

-- a copy of a tab of the chapter screen showing a Lucide icon
local function tab(original, offset, icon, fn)
  local copy = kit.clone(original, offset, fn)
  local image = find(copy.transform, "Image")
  image.sizeDelta = { 44, 44 } -- like the game's icons
  image:GetComponent(UE.UI.Image).sprite = kit.icon(icon)
  return copy
end

local function row(s, entry)
  local player = entry.player
  local mine = ("%s#%04d"):format(player.name, player.number) == phigrospp.tag()
  local ink = mine and BLACK or WHITE
  local y = #s.rows * STEP
  local shape = bar(s.list, "phigrospp-leaderboard-row", { -y * SLOPE, -y }, { s.width, ROW },
    mine and WHITE or { 1, 1, 1, 0.08 })
  shape.raycastTarget = true
  local function text(x, size, alignment, pivot, value, colour)
    local t = kit.text(shape.transform, "phigrospp-leaderboard-text", font, { x, ROW / 2 }, { 0, 0 }, size, alignment, pivot)
    t.text, t.color, t.supportRichText = value, colour, false
    return t
  end
  text(100, 40, 5, { 1, 0.5 }, tostring(entry.rank), ink) -- MiddleRight
  local avatar = kit.rect(shape.transform, "phigrospp-leaderboard-avatar", { 124, ROW / 2 }, { 64, 64 }, WHITE)
  -- an avatar this version of the game doesn't have yet shows as the default one
  local avatars = UE.Object.FindObjectOfType(CS.GetCollectionControl).Avatars
  local key = avatars:ContainsKey(player.avatar) and player.avatar or "Introduction"
  avatar.gameObject:AddComponent(CS.AddressableImageLoader).Code = avatars:get_Item(key).addressableKey
  local name = text(212, 40, 3, { 0, 0.5 }, player.name, ink) -- MiddleLeft
  text(220 + name.preferredWidth, 32, 3, { 0, 0.5 }, ("#%04d"):format(player.number), mine and { 0, 0, 0, 0.5 } or DIM)
  text(s.width - 48, 40, 5, { 1, 0.5 }, ("%.2f"):format(entry.rks), ink)
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
      s.content.sizeDelta = { 0, #s.rows * STEP + 32 }
      s.message.text = #s.rows == 0 and "No player is ranked yet" or ""
    end)
end

local function restart(s)
  for _, r in ipairs(s.rows) do UE.Object.Destroy(r) end
  s.rows, s.page, s.count, s.asked = {}, 0, math.huge, s.asked + 1
  s.content.anchoredPosition, s.message.text = { 0, 0 }, ""
  load(s)
end

local function close()
  if screen.closing then return end
  screen.closing, screen.start = true, now()
end

local function open()
  if screen then return end
  local width, height = canvas.rect.m_Width, canvas.rect.m_Height
  local root = UE.GameObject("phigrospp-leaderboard"):AddComponent(UE.RectTransform)
  root:SetParent(canvas, false)
  root.anchorMin, root.anchorMax, root.sizeDelta = { 0, 0 }, { 1, 1 }, { 0, 0 }
  local s = { root = root, group = root.gameObject:AddComponent(UE.CanvasGroup), start = now(), asked = 0, rows = {},
    width = math.floor(width * 0.6) }
  kit.rect(root, "phigrospp-leaderboard-shade", { 0, 0 }, { width, height }, { 0, 0, 0, 0.85 }, { 0, 0 }).raycastTarget = true
  tab(find(canvas, "Collection"), { 0, 0 }, "arrow-left", close).transform:SetParent(root, false)

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

  local view = kit.rect(root, "phigrospp-leaderboard-list", { 0, 30 }, { width, middle - 114 }, { 0, 0, 0, 0 }, { 0, 0 })
  view.raycastTarget = true -- drags between rows scroll too
  view.gameObject:AddComponent(UE.UI.RectMask2D)
  s.view = view.transform
  local function stretched(name, parent)
    local t = UE.GameObject(name):AddComponent(UE.RectTransform)
    t:SetParent(parent, false)
    t.anchorMin, t.anchorMax, t.pivot, t.sizeDelta = { 0, 1 }, { 1, 1 }, { 0, 1 }, { 0, 0 }
    return t
  end
  s.content = stretched("Content", s.view)
  s.list = stretched("Rows", s.content)
  -- centred on the middle of the list, rows above it lean right and below it left
  s.x = (width - s.width) / 2 + s.view.rect.m_Height / 2 * SLOPE
  local scroll = view.gameObject:AddComponent(UE.UI.ScrollRect)
  scroll.viewport, scroll.content, scroll.horizontal = s.view, s.content, false
  s.message = kit.text(root, "phigrospp-leaderboard-message", font, { width / 2, height / 2 }, { 0, 0 }, 44, 4,
    { 0.5, 0.5 }) -- MiddleCenter
  s.message.color = DIM
  screen = s
  restart(s)
end

on("scene", function(name)
  screen = nil
  if name ~= "ChapterSelector" then return end
  local settings = UE.GameObject.Find("Canvas/Settings").transform
  canvas, font = settings.parent, UE.Object.FindObjectOfType(CS.ChapterSelector).nowLevel.font
  -- under the settings tab, which hides its square right end behind its stripe. the icon moves left by what the stripe
  -- covers, to the middle of what shows
  local trophy = tab(settings, { -settings.sizeDelta.x, 0 }, "trophy", open).transform
  trophy:SetSiblingIndex(settings:GetSiblingIndex())
  local icon = find(trophy, "Image")
  icon.anchoredPosition = { icon.anchoredPosition.x - 12, icon.anchoredPosition.y }
end)

on("update", function()
  local s = screen
  if not s then return end
  local f = math.min(1, (now() - s.start) / SLIDE)
  f = f * f * (3 - 2 * f)
  local shown = s.closing and 1 - f or f
  s.group.alpha, s.group.blocksRaycasts = shown, not s.closing
  s.root.anchoredPosition = { 160 * (1 - shown), 0 }
  if s.closing and f == 1 then
    UE.Object.Destroy(s.root.gameObject)
    screen = nil
    return
  end
  -- the rows slide sideways as they scroll, along the slant, like the game's lists
  local scrolled = s.content.anchoredPosition.y
  s.list.anchoredPosition = { s.x + scrolled * SLOPE, -16 }
  if not s.loading and #s.rows < s.count and scrolled > (#s.rows - MORE) * STEP - s.view.rect.m_Height then load(s) end
end)
