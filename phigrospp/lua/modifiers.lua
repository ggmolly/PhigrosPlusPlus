-- modifiers: what a song can be played with to make it easier, harder or different, like osu!'s mods. a play with some
-- is no record of the game's: it's recorded and sent to phigros.tools, which judges its replay again with the same
-- rules (web/src/modifiers.ts, read alongside this file: neither changes alone), and the save never hears of it.
-- here is what they are, the total they give a score, the player's picks and the ones of the play going on.
-- mods/modifiers.lua is what each does to the game

local ui = phigrospp.ui
local EASIER, HARDER, OTHER = { 0.7, 1, 0.4, 1 }, { 1, 0.4, 0.4, 1 }, { 0.55, 0.4, 1, 1 } -- osu!'s colours
local DARK = { 0.02, 0.13, 0.17, 1 }
local M = 0xFFFFFFFF
local LANES = 5 -- Random's, 3 wide and centred on the positions charts put most notes at

-- bit: the modifier in a replay's mods (osu!'s values), percent: what it makes of the score, excludes: the bit of the
-- one it can't go with, icon: its glyph, stroked in a 24 by 24 box
local LIST = {
  { id = "EZ", bit = 2, name = "Easy", percent = 50, colour = EASIER, excludes = 16,
    icon = [[<path d="M9 7 4 12l5 5M15 7l5 5-5 5M10 12h4"/>]] },
  { id = "HR", bit = 16, name = "Hard Rock", percent = 106, colour = HARDER, excludes = 2,
    icon = [[<path d="M4 7l5 5-5 5M20 7l-5 5 5 5M12 9v6"/>]] },
  { id = "HT", bit = 256, name = "Half Time", percent = 30, colour = EASIER, excludes = 512,
    icon = [[<path d="M7 5v14M11 6l8 6-8 6z"/>]] },
  { id = "NC", bit = 512, name = "Nightcore", percent = 112, colour = HARDER, excludes = 256,
    icon = [[<path d="M4 7l5 5-5 5M11 7l5 5-5 5M20 7v10"/>]] },
  { id = "HD", bit = 8, name = "Hidden", percent = 106, colour = HARDER, excludes = 0,
    icon = [[<path d="M2 12s3.6-6 10-6 10 6 10 6-3.6 6-10 6S2 12 2 12M9.5 12a2.5 2.5 0 1 0 5 0a2.5 2.5 0 1 0-5 0M4 4l16 16"/>]] },
  { id = "FL", bit = 1024, name = "Flashlight", percent = 112, colour = HARDER, excludes = 0,
    icon = [[<path d="M2 12h20M12 8V4M12 20v-4M6 8 4.5 5.5M18 8l1.5-2.5M6 16l-1.5 2.5M18 16l1.5 2.5"/>]] },
  { id = "SD", bit = 32, name = "Sudden Death", percent = 100, colour = HARDER, excludes = 16384,
    icon = [[<path d="M13 2 4 14h7l-1 8 9-12h-7z"/>]] },
  { id = "PF", bit = 16384, name = "Perfect", percent = 100, colour = HARDER, excludes = 32,
    icon = [[<path d="M6 12a6 6 0 1 0 12 0a6 6 0 1 0-12 0M12 3v18"/>]] },
  { id = "RD", bit = 2097152, name = "Random", percent = 100, colour = OTHER, excludes = 0,
    icon = [[<path d="M3 7h4l10 10h4M3 17h4l10-10h4M18 4l3 3-3 3M18 14l3 3-3 3"/>]] },
}

local picks = 0 -- what the player picked, until the game closes
local mods, seed = 0, 0 -- the play's, from the song list's Play to the song list again
local plate

-- the score's multiplier as a fraction of integers, so the site's total and this one never differ
local function ratio(mask)
  local num, den = 1, 1
  for _, m in ipairs(LIST) do
    if mask & m.bit ~= 0 and m.percent ~= 100 then num, den = num * m.percent, den * 100 end
  end
  return num, den
end

-- mulberry32: what gives the next 32 bits from a seed
local function random(from)
  local a = from
  return function()
    a = (a + 0x6D2B79F5) & M
    local t = ((a ~ (a >> 15)) * (1 | a)) & M
    t = ((t + (((t ~ (t >> 7)) * (61 | t)) & M)) & M) ~ t
    return t ~ (t >> 14)
  end
end

-- Random's shuffle: lanes[i + 1] is the lane the notes of lane i go to, counted from 0
local function lanes(from)
  local next, list = random(from), {}
  for i = 1, LANES do list[i] = i - 1 end
  for i = LANES - 1, 1, -1 do
    local j = next() % (i + 1)
    list[i + 1], list[j + 1] = list[j + 1], list[i + 1]
  end
  return list
end

phigrospp.modifiers = {
  list = LIST,
  random = random,
  lanes = lanes,
  -- the modifiers the player picked as their bits, which the next song started from the song list plays with. given
  -- some, they're picked instead
  pick = function(mask)
    picks = mask or picks
    return picks
  end,
  -- the modifiers of the song loading, played or on its result screen, and its seed: a watched replay's are its own
  play = function() return mods, seed end,
  -- whether a chart of the game plays with modifiers: one with effects of its own doesn't (see the hook below)
  fits = function(id, difficulty)
    local info = CS.GameInformation.main:GetSongInformation(id)
    for i = 0, #info.levels - 1 do
      if info.levels[i] == difficulty then return info.levelMods._items[i].levelMods._size == 0 end
    end
  end,
  -- what the song list's Play starts: the replay it watches if any (or what a play is given: { mods =, seed = }), else
  -- the picks, with a seed that shuffles
  start = function(header)
    mods, seed = header and header.mods or picks, header and header.seed or 0
    if header or mods & 2097152 == 0 then return end
    repeat
      seed = math.random(1, M)
    until table.concat(lanes(seed)) ~= "01234"
  end,
  -- the score a play counts for with its modifiers. the grade stays the score's
  total = function(score, mask)
    local num, den = ratio(mask)
    return (score * num + den // 2) // den
  end,
  -- what they make of a score, as it's shown: ×1.19
  multiplier = function(mask)
    local num, den = ratio(mask)
    return ("×%.2f"):format(num / den)
  end,
  -- their short names: "HR HD"
  names = function(mask)
    local names = {}
    for _, m in ipairs(LIST) do
      if mask & m.bit ~= 0 then names[#names + 1] = m.id end
    end
    return table.concat(names, " ")
  end,
  -- the modifiers' plates in a row under parent, each `size` wide, placed like ui.place does: its RectTransform
  strip = function(parent, mask, pos, size, pivot)
    -- a square with round corners
    plate = plate or phigrospp.sprite(48, function(x, y)
      local dx, dy = math.max(math.abs(x) - 16, 0), math.max(math.abs(y) - 16, 0)
      return math.sqrt(dx * dx + dy * dy) - 8
    end)
    local row, n = ui.rect(parent, "phigrospp-modifiers", pos, { 0, size }, { 0, 0, 0, 0 }, pivot), 0
    for _, m in ipairs(LIST) do
      if mask & m.bit ~= 0 then
        local back = ui.rect(row.transform, m.id, { n * size * 1.15, 0 }, { size, size }, m.colour, { 0, 0 })
        local glyph = ui.rect(back.transform, "Glyph", { size / 2, size / 2 }, { size * 0.8, size * 0.8 }, DARK, { 0.5, 0.5 })
        back.sprite, glyph.sprite, n = plate, ui.icon(m.icon), n + 1
        -- a canvas a camera draws only shows its own layer
        back.gameObject.layer, glyph.gameObject.layer = parent.gameObject.layer, parent.gameObject.layer
      end
    end
    row.gameObject.layer = parent.gameObject.layer
    row.transform.sizeDelta = { math.max(0, n * size * 1.15 - size * 0.15), size }
    return row.transform
  end,
}

on("scene", function(name)
  if name == "SongSelector" then mods, seed = 0, 0 end
end)

-- a song with effects of its own saves from inside them (its unlocks), which a play with modifiers must never do:
-- it plays without
hook(CS.LevelControl, "Awake", {
  before = function()
    if CS.GameInformation.main.levelStartInfo.levelMods._size > 0 then mods, seed = 0, 0 end
  end,
})

