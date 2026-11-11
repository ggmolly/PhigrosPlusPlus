-- the Phigros++ version on the title screen's bottom left and next to the game's version in the settings, and a
-- "++" on the Phigros logo of both

local UE = CS.UnityEngine
local LABEL = "Phigros++ " .. phigrospp.version
local PINK, GLOW = { 1, 0.89, 0.95, 1 }, { 1, 0.31, 0.66, 0.07 }

local label, looking

local function findVersion()
  local texts = UE.Object.FindObjectsOfType(UE.UI.Text)
  for i = 0, #texts - 1 do
    if texts[i] ~= label and (texts[i].text or ""):find("^Version") then return texts[i] end
  end
end

local function mirror(text)
  local copy = UE.Object.Instantiate(text, text.transform.parent, false)
  local from, to = text.transform, copy.transform
  local min, max, pivot, pos = from.anchorMin, from.anchorMax, from.pivot, from.anchoredPosition
  copy.gameObject.name = "phigrospp-version"
  copy.raycastTarget = false
  to.anchorMin = { 1 - max.x, min.y }
  to.anchorMax = { 1 - min.x, max.y }
  to.pivot = { 1 - pivot.x, pivot.y }
  to.anchoredPosition = { -pos.x, pos.y }
  -- TextAnchor is row * 3 + column, swap the left and right columns
  copy.alignment = text.alignment - text.alignment % 3 + 2 - text.alignment % 3
  return copy
end

local function plusText(logo, font, colour, scale, x, y)
  local go = UE.GameObject("phigrospp-plusplus")
  go.layer = logo.gameObject.layer
  local text = go:AddComponent(UE.UI.Text)
  local t = text.transform
  t:SetParent(logo, false)
  t.anchorMin, t.anchorMax, t.pivot = { 1, 1 }, { 1, 1 }, { 0, 1 }
  t.sizeDelta, t.anchoredPosition = { 200 * scale, 100 * scale }, { (x - 12) * scale, (y - 6) * scale }
  text.font, text.fontSize, text.color, text.text = font, math.floor(72 * scale + 0.5), colour, "++"
  text.fontStyle, text.horizontalOverflow, text.verticalOverflow, text.raycastTarget = 1, 1, 1, false -- Bold
end

-- a pink "++" in superscript on a logo, glowing like it through faint copies around it. sizes are for the
-- settings' logo, 187 high
local function plusPlus(logo, font)
  local scale = logo.rect.m_Height / 187
  for _, radius in ipairs({ 2, 4, 6, 8, 10 }) do
    for i = 0, 11 do
      local angle = i * math.pi / 6
      plusText(logo, font, GLOW, scale, radius * math.cos(angle), radius * math.sin(angle))
    end
  end
  plusText(logo, font, PINK, scale, 0, 0)
end

local function findLogo()
  local images = UE.Object.FindObjectsOfType(UE.UI.Image)
  for i = 0, #images - 1 do
    local sprite = images[i].sprite
    if sprite and sprite.name == "Phigros" then return images[i].transform end
  end
end

on("scene", function(name)
  if looking then looking() end
  if name == "Setting" then
    local version = UE.Object.FindObjectOfType(CS.Setting).versionText
    -- a reload finds the text as the previous run left it, maybe with another version after an update
    version.text = ("%s (%s)"):format((version.text:gsub(" %(Phigros%+%+ [^)]*%)$", "")), LABEL)
    plusPlus(version.transform.parent.parent:Find("Logo"), version.font)
  elseif name == "SplashScene" then
    -- the title screen's version and logo show up once the splash logos are over
    looking = every(0.5, function()
      local source = findVersion()
      if not source then return end
      label = mirror(source)
      label.text = LABEL
      plusPlus(findLogo(), source.font)
      looking()
    end)
  end
end)

-- a script copied along with the label may write the game version back into it
on("update", function()
  if il2cpp.alive(label) and label.text ~= LABEL then label.text = LABEL end
end)
