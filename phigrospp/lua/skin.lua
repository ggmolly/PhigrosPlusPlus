-- cosmetics for mods: hitsounds, note skins, hit effects and judge line colours. note skins fit inside the game's own
-- notes and lines keep the chart's alpha, so a skin changes how the chart looks, never what it lets a player read

local UE = CS.UnityEngine
skin = {}

-- "#rrggbb" or "#rrggbbaa" as a colour
local function hex(h)
  local colour = { 0, 0, 0, 1 }
  for i = 2, #h, 2 do colour[i // 2] = tonumber(h:sub(i, i + 1), 16) / 255 end
  return colour
end

-- SEPlayer plays its sound 7 for taps and holds, 8 for drags and 9 for flicks
local SOUNDS = { tap = 7, drag = 8, flick = 9 }
-- by SEPlayer index: the files being decoded, their clips once they are, and the game's own sounds they replaced
local decoding, clips, original = {}, {}, {}

-- hitsound("tap", "tap.ogg"), a file of any format android plays
function hitsound(kind, file) decoding[SOUNDS[kind]] = phigrospp.decode(phigrospp.resolve(file, 2)) end

-- the game loads its sounds once, in SEPlayer.Start, which may not have run yet when a clip is ready
local function replace(index)
  local pointers = CS.SEPlayer.pointers
  if not pointers then return end
  original[index] = original[index] or pointers[index]
  pointers[index] = CS.E7.Native.NativeAudio.Load(clips[index])
end

hook(CS.SEPlayer, "Start", {
  after = function()
    for index in pairs(clips) do replace(index) end
  end,
})

on("update", function()
  for index, job in pairs(decoding) do
    local samples, channels, rate = job:poll()
    if samples then
      decoding[index] = nil
      clips[index] = phigrospp.asset(UE.AudioClip.Create("hitsound", #samples // channels, channels, rate, false))
      clips[index]:SetData(samples, 0)
      replace(index)
    end
  end
end)

on("unload", function()
  local pointers = CS.SEPlayer.pointers
  for index, sound in pairs(original) do
    pointers[index]:Unload()
    pointers[index] = sound
  end
end)

-- where a judge line keeps the sprite of each kind of note: in a field of its own for the look of notes hit together,
-- else in the script of one of its note prefabs (a hold's has three, by index). a kind comes before its _multi, so a
-- skin sizing its notes itself can size both alike
local KINDS = {
  { "tap", "Click", CS.ClickControl }, { "tap_multi", "ClickHL" },
  { "drag", "Drag", CS.DragControl }, { "drag_multi", "DragHL" },
  { "flick", "Flick", CS.FlickControl }, { "flick_multi", "FlickHL" },
  { "hold_head", "Hold", CS.HoldControl, 0 }, { "hold_head_multi", "HoldHL0" },
  { "hold", "Hold", CS.HoldControl, 1 }, { "hold_multi", "HoldHL1" },
  { "hold_tail", "Hold", CS.HoldControl, 2 },
}
-- what a skin replaced with its own as { holder, key, the game's }: in the game's prefabs, which outlive levels, and in
-- the level being played
local notes, worn, prefabs, level = {}, {}, {}, {}

-- skin.note("tap", "tap.png"): an image, or a function making the Sprite from the game's own for a skin sizing its
-- notes itself
function skin.note(kind, source) notes[kind] = type(source) == "string" and phigrospp.resolve(source, 2) or source end

-- a texture made of `rows` rows taken evenly from the `height` rows above row y of another. the game stretches a
-- hold's body over the hold from the shape of its own, so a skin's is brought to that shape first
function skin.stretch(texture, y, height, rows)
  -- RGBA32 without smaller copies, which would blur it sideways when the game squeezes it into a short hold
  local width, stretched = texture.width, phigrospp.asset(UE.Texture2D(texture.width, rows, 4, false))
  local from, to = texture:GetPixels32(), stretched:GetPixels32()
  for row = 0, rows - 1 do CS.System.Array.Copy(from, (y + row * height // rows) * width, to, row * width, width) end
  stretched.wrapMode = 1 -- Clamp, so its ends don't blend with each other
  stretched:SetPixels32(to)
  stretched:Apply()
  return stretched
end

-- the sprite a kind wears in place of the game's, with its pivot. an image is scaled to fit inside the game's, so a
-- skin never makes notes bigger, but for a hold's body: as wide as the game's, and stretched to its height
local function wear(kind, game)
  if worn[kind] then return worn[kind] end
  local source, sprite = notes[kind]
  if type(source) == "function" then
    sprite = source(game)
  else
    local texture, rect, units = image(source).texture, game.rect, game.pixelsPerUnit
    local scale = math.max(texture.width / rect.m_Width, texture.height / rect.m_Height) * units
    if kind == "hold" or kind == "hold_multi" then
      scale = texture.width / rect.m_Width * units
      texture = skin.stretch(texture, 0, texture.height, math.floor(rect.m_Height / units * scale + 0.5))
    end
    sprite = UE.Sprite.Create(texture, { 0, 0, texture.width, texture.height },
      { game.pivot.x / rect.m_Width, game.pivot.y / rect.m_Height }, scale)
  end
  worn[kind] = phigrospp.asset(sprite)
  return sprite
end

local colours, lines = nil, {}

-- skin.line({ ap = "#ffd27f", fc = "#7fd4ff", normal = "#ffffff" }), any of them
function skin.line(given)
  colours = {}
  for state, colour in pairs(given) do colours[state] = hex(colour) end
end

local effect, frames, copies = nil, {}, {}
local life, playing = nil, {} -- seconds a hit effect lasts, and the renderer of each one on screen by its timer

-- a hit effect shows the frame of its age, counted by the script that ends it
local function animate(timer)
  local age, renderer = timer.i, playing[timer]
  if age < 0 then return end -- one of the two the game copies
  if not renderer then
    renderer = timer:GetComponent(UE.SpriteRenderer)
    if not (renderer and frames[renderer.sprite]) then return end -- something else of the game's that ends
    playing[timer] = renderer
  end
  if age < life then renderer.sprite = frames[age / life * #frames // 1 + 1] else playing[timer] = nil end
end

-- skin.effect("hit.png", { columns = 8, rows = 4, seconds = 0.5, scale = 1, perfect = "#ffec9f", good = "#b4e1ff",
-- sparks = false }): the image's frames, from its top left one, played in place of the game's hit effect
function skin.effect(file, options)
  effect = options
  effect.file = phigrospp.resolve(file, 2)
  hook(CS.DestroyThis, "Update", { before = animate })
end

-- the frames as sprites, each as wide as the game's effect times the scale asked. frames[sprite] tells ours apart
local function cut(game)
  local texture = image(effect.file).texture
  texture:Apply(false, true) -- a big image, whose pixels only the gpu keeps from here
  local width, height = texture.width / effect.columns, texture.height / effect.rows
  local units = width * game.pixelsPerUnit / game.rect.m_Width / (effect.scale or 1)
  for i = 0, effect.columns * effect.rows - 1 do
    local rect = { i % effect.columns * width, texture.height - (i // effect.columns + 1) * height, width, height }
    frames[i + 1] = phigrospp.asset(UE.Sprite.Create(texture, rect, { 0.5, 0.5 }, units))
    frames[frames[i + 1]] = true
  end
end

-- the game copies a prefab for each hit: it's given a copy of it that plays the frames instead of the game's
-- animation, in the colour asked. that copy is kept from ending, the age of its own copies starts at 0
local function dress(prefab, colour)
  local copy = UE.Object.Instantiate(prefab)
  UE.Object.DestroyImmediate(copy:GetComponent(UE.Animator))
  local renderer, timer = copy:GetComponent(UE.SpriteRenderer), copy:GetComponent(CS.DestroyThis)
  if not frames[1] then cut(renderer.sprite) end
  renderer.sprite, renderer.color = frames[1], colour and hex(colour) or { 1, 1, 1, 1 }
  life = effect.seconds or timer.TimeLenth
  timer.TimeLenth, timer.i = life, -math.huge
  phigrospp.find(copy.transform, "Particle System").gameObject:SetActive(effect.sparks ~= false)
  copy.transform.position = { 0, 0, -1e6 } -- behind the camera
  return copy
end

-- a level's two effects, in its score and in the hold prefab, which keeps the last level's dead copies
local function dressAll(line)
  local score, hold = line.scoreControl, line.Hold:GetComponent(CS.HoldControl)
  level = {}
  for _, judgement in ipairs({ "perfect", "good" }) do
    local field = judgement .. "Judge"
    local prefab = score[field]
    if hold[judgement] == prefab then prefabs[#prefabs + 1] = { hold, judgement, prefab } end
    copies[judgement] = dress(prefab, effect[judgement])
    level[#level + 1] = { score, field, prefab }
    score[field], hold[judgement] = copies[judgement], copies[judgement]
  end
end

hook(CS.JudgeLineControl, "Start", {
  before = function(line)
    lines[#lines + 1] = line
    if effect and line.scoreControl.perfectJudge ~= copies.perfect then dressAll(line) end
    for _, kind in ipairs(KINDS) do
      local name, field, script, index = table.unpack(kind)
      if notes[name] and not script then
        line[field] = wear(name, line[field])
      elseif notes[name] then
        -- the prefabs are assets shared by every line and level, put back on reload
        local control = line[field]:GetComponent(script)
        local holder, key = index and control.noteImages or control, index or "noteImage"
        prefabs[#prefabs + 1] = worn[name] ~= holder[key] and { holder, key, holder[key] } or nil
        holder[key] = wear(name, holder[key])
      end
    end
  end,
})

on("leave", function() lines, playing = {}, {} end)

on("unload", function()
  for _, list in ipairs({ prefabs, level }) do
    for _, swapped in ipairs(list) do swapped[1][swapped[2]] = swapped[3] end
  end
end)

-- the game paints the lines white, blue for a full combo or gold for an all perfect each frame, this runs after it
on("update", function()
  if not colours then return end
  for _, line in ipairs(lines) do
    if not line.isShowingPic then
      local renderer = line._judgeLineSpriteRenderer
      local c = renderer.color
      local colour = colours[c.b < 0.8 and "ap" or c.r < 0.8 and "fc" or "normal"]
      if colour then renderer.color = { colour[1], colour[2], colour[3], c.a } end
    end
  end
end)
