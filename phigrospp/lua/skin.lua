-- cosmetics for mods: hitsounds, note skins and judge line colours. note skins fit inside the game's own notes and
-- lines keep the chart's alpha, so a skin changes how the chart looks, never what it lets a player read

local UE = CS.UnityEngine
skin = {}

local function hex(h)
  return { tonumber(h:sub(2, 3), 16) / 255, tonumber(h:sub(4, 5), 16) / 255, tonumber(h:sub(6, 7), 16) / 255 }
end

-- an AudioClip of a 16 bit pcm wav file
local function wav(path)
  local data = phigrospp.read(path)
  local pos, channels, rate, samples = 13, nil, nil, nil
  while pos < #data do
    local id, size = string.unpack("<c4I4", data, pos)
    if id == "fmt " then
      local format, bits
      format, channels, rate = string.unpack("<I2I2I4", data, pos + 8)
      bits = string.unpack("<I2", data, pos + 22)
      assert(format == 1 and bits == 16, path .. " isn't a 16 bit pcm wav")
    elseif id == "data" then
      samples = {}
      for i = 1, size // 2 do samples[i] = string.unpack("<i2", data, pos + 6 + i * 2) / 32768 end
    end
    pos = pos + 8 + size + size % 2
  end
  local clip = UE.AudioClip.Create(path, #samples // channels, channels, rate, false)
  clip:SetData(samples, 0)
  return clip
end

-- SEPlayer plays its sound 7 for taps and holds, 8 for drags and 9 for flicks
local SOUNDS = { tap = 7, drag = 8, flick = 9 }
local sounds, original = {}, {}

function hitsound(kind, file) sounds[SOUNDS[kind]] = phigrospp.resolve(file, 2) end

local function loadSounds()
  local pointers = CS.SEPlayer.pointers
  for index, path in pairs(sounds) do
    original[index] = original[index] or pointers[index]
    pointers[index] = CS.E7.Native.NativeAudio.Load(wav(path))
  end
end

-- the game loads its sounds once, in SEPlayer.Start, which may not have run yet when mods load
hook(CS.SEPlayer, "Start", { after = loadSounds })
on("load", function() if CS.SEPlayer.pointers then loadSounds() end end)

on("unload", function()
  local pointers = CS.SEPlayer.pointers
  for index, sound in pairs(original) do
    pointers[index]:Unload()
    pointers[index] = sound
  end
end)

-- the note prefab of each kind on a judge line, its script, and the sprite it wears when hit with another note
local NOTES = {
  tap = { "Click", CS.ClickControl, "ClickHL" },
  drag = { "Drag", CS.DragControl, "DragHL" },
  flick = { "Flick", CS.FlickControl, "FlickHL" },
}
local notes, fitted, prefabs = {}, {}, {}

-- skin.note("tap", "tap.png"), or "tap_multi" for the look of notes hit at the same time as another
function skin.note(kind, file) notes[kind] = phigrospp.resolve(file, 2) end

-- the image scaled to fit inside the game's sprite, so a skin never makes notes bigger
local function fit(kind, sprite)
  if not fitted[kind] then
    local texture = image(notes[kind]).texture
    local width, height = sprite.rect.m_Width / sprite.pixelsPerUnit, sprite.rect.m_Height / sprite.pixelsPerUnit
    local scale = math.max(texture.width / width, texture.height / height)
    fitted[kind] = phigrospp.asset(UE.Sprite.Create(texture, { 0, 0, texture.width, texture.height }, { 0.5, 0.5 }, scale))
  end
  return fitted[kind]
end

local colours, lines = nil, {}

-- skin.line({ ap = "#ffd27f", fc = "#7fd4ff", normal = "#ffffff" }), any of them
function skin.line(given)
  colours = {}
  for state, colour in pairs(given) do colours[state] = hex(colour) end
end

hook(CS.JudgeLineControl, "Start", {
  before = function(line)
    lines[#lines + 1] = line
    for kind, note in pairs(NOTES) do
      -- the prefabs are assets shared by every line and level, put back on reload
      if notes[kind] then
        local control = line[note[1]]:GetComponent(note[2])
        if not prefabs[control] then prefabs[control] = control.noteImage end
        control.noteImage = fit(kind, prefabs[control])
      end
      if notes[kind .. "_multi"] then line[note[3]] = fit(kind .. "_multi", line[note[3]]) end
    end
  end,
})

on("leave", function() lines = {} end)

on("unload", function()
  for control, sprite in pairs(prefabs) do
    if il2cpp.alive(control) then control.noteImage = sprite end
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
