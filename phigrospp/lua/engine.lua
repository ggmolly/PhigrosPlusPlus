-- timers, the current scene, toasts and images for mods

local UE = CS.UnityEngine
local SceneManager, Scene = UE.SceneManagement.SceneManager, UE.SceneManagement.Scene

local timers = {}

local function schedule(delay, fn, period)
  local timer = { at = now() + delay, fn = fn, period = period }
  timers[#timers + 1] = timer
  return function() timer.cancelled = true end
end

-- both return a function cancelling the timer
function after(seconds, fn) return schedule(seconds, fn) end

function every(seconds, fn) return schedule(seconds, fn, seconds) end

local function runTimers()
  local t = now()
  for i = #timers, 1, -1 do
    local timer = timers[i]
    if not timer.cancelled and t >= timer.at then
      local ok, err = xpcall(timer.fn, debug.traceback)
      if not ok then print("timer failed: " .. err) end
      if ok and timer.period then timer.at = t + timer.period else timer.cancelled = true end
    end
    if timer.cancelled then table.remove(timers, i) end
  end
end

-- scenes are told apart by handle, their name is the file name of their path
local handle, current

local function nameOf(scene) return Scene.GetPathInternal(scene.m_Handle):match("([^/]+)%.unity$") end

function scene() return current end

on("update", function()
  runTimers()
  local active = SceneManager.GetActiveScene()
  if active.m_Handle ~= handle then
    handle, current = active.m_Handle, nameOf(active)
    phigrospp.emit("scene", current)
  end
end)

-- the game's Button calls listeners we can't make from lua, so clicks on buttons we made are caught here. a button's
-- function runs in a coroutine, so it can wait for a choice in a dialog (phigrospp.ui.confirm)
local clicks = {}
local holds = {} -- what phigrospp.hold waits on

function phigrospp.click(button, fn) clicks[button] = fn end

-- fn runs, like a click's, once a finger stayed `seconds` where on(x, y) says a point of the screen (pixels) is
function phigrospp.hold(on, seconds, fn) holds[#holds + 1] = { on = on, seconds = seconds, fn = fn } end

local function resume(co, ...)
  local ok, err = coroutine.resume(co, ...)
  if not ok then print("button failed: " .. debug.traceback(co, err)) end
end

-- the game checks interactable after this hook runs
hook(UE.UI.Button, "OnPointerClick", {
  before = function(clicked)
    local click = clicks[clicked]
    if click and clicked:IsInteractable() then resume(coroutine.create(click)) end
  end,
})

on("update", function()
  if #holds == 0 or UE.Input.touchCount == 0 then return end
  local fingers = touches()
  for _, held in ipairs(holds) do
    local still
    for _, t in ipairs(fingers) do
      if t.id == held.id and t.phase ~= 3 and t.phase ~= 4 then still = true end -- not Ended or Canceled
      if t.phase == 0 and held.on(t.x, t.y) then held.id, held.since, still = t.id, now(), true end -- Began
    end
    if not still then held.id = nil end
    if held.id and now() - held.since >= held.seconds then
      held.id = nil
      resume(coroutine.create(held.fn))
    end
  end
end)

-- buttons that died with their scene are forgotten
on("scene", function()
  for button in pairs(clicks) do
    if not il2cpp.alive(button) then clicks[button] = nil end
  end
end)

function toast(message) CS.Tools.AndroidAPIs.Toast(tostring(message)) end

-- android through raw jni: unity's java helpers are generic methods the bridge can't call
local JNI = UE.AndroidJNI
local function jstring(s) return { l = JNI.NewStringUTF(s) } end

local function activity()
  local Player = JNI.FindClass("com/unity3d/player/UnityPlayer")
  return JNI.GetStaticObjectField(Player, JNI.GetStaticFieldID(Player, "currentActivity", "Landroid/app/Activity;"))
end

local function call(object, name, signature, args, kind)
  return JNI["Call" .. (kind or "Object") .. "Method"](object, JNI.GetMethodID(JNI.GetObjectClass(object), name, signature),
    args or {})
end

-- android's share sheet for a text
function phigrospp.share(text)
  local Intent, returnsIntent = JNI.FindClass("android/content/Intent"), "Landroid/content/Intent;"
  local intent = JNI.NewObject(Intent, JNI.GetMethodID(Intent, "<init>", "(Ljava/lang/String;)V"),
    { jstring("android.intent.action.SEND") })
  call(intent, "setType", "(Ljava/lang/String;)" .. returnsIntent, { jstring("text/plain") })
  call(intent, "putExtra", "(Ljava/lang/String;Ljava/lang/String;)" .. returnsIntent,
    { jstring("android.intent.extra.TEXT"), jstring(text) })
  local chooser = JNI.CallStaticObjectMethod(Intent,
    JNI.GetStaticMethodID(Intent, "createChooser", "(Landroid/content/Intent;Ljava/lang/CharSequence;)" .. returnsIntent),
    { { l = intent }, jstring("Share") })
  call(activity(), "startActivity", "(Landroid/content/Intent;)V", { { l = chooser } }, "Void")
end

-- whether the device has an android hardware feature, "android.hardware.telephony" for a mobile network
function phigrospp.feature(name)
  local packages = call(activity(), "getPackageManager", "()Landroid/content/pm/PackageManager;")
  return call(packages, "hasSystemFeature", "(Ljava/lang/String;)Z", { jstring(name) }, "Boolean")
end

-- opens an installed app, false when there's none or android hides it from this one (it shows an app the one that
-- installed it)
function phigrospp.launch(package)
  local packages = call(activity(), "getPackageManager", "()Landroid/content/pm/PackageManager;")
  local intent = call(packages, "getLaunchIntentForPackage", "(Ljava/lang/String;)Landroid/content/Intent;",
    { jstring(package) })
  if intent == 0 then return false end -- a null object
  call(activity(), "startActivity", "(Landroid/content/Intent;)V", { { l = intent } }, "Void")
  return true
end

-- the highest rate picked in android's settings, 0 when there's none
local function peakRate()
  local System = JNI.FindClass("android/provider/Settings$System")
  local getFloat = JNI.GetStaticMethodID(System, "getFloat", "(Landroid/content/ContentResolver;Ljava/lang/String;F)F")
  local resolver = call(activity(), "getContentResolver", "()Landroid/content/ContentResolver;")
  return JNI.CallStaticFloatMethod(System, getFloat, { { l = resolver }, jstring("peak_refresh_rate"), { f = 0 } })
end

local rate, focused

-- asks android to run the screen at hz while nothing touches it, through unity's surface. without hz it's the peak
-- rate: hyperos keeps the renamed package at 60 Hz otherwise
function phigrospp.frameRate(hz)
  rate = hz
  local SurfaceView, ViewGroup = JNI.FindClass("android/view/SurfaceView"), JNI.FindClass("android/view/ViewGroup")
  local function find(view)
    if JNI.IsInstanceOf(view, SurfaceView) then return view end
    if not JNI.IsInstanceOf(view, ViewGroup) then return nil end
    for i = 0, call(view, "getChildCount", "()I", nil, "Int") - 1 do
      local found = find(call(view, "getChildAt", "(I)Landroid/view/View;", { { i = i } }))
      if found then return found end
    end
  end
  local view = find(call(call(activity(), "getWindow", "()Landroid/view/Window;"), "getDecorView", "()Landroid/view/View;"))
  local surface = call(call(view, "getHolder", "()Landroid/view/SurfaceHolder;"), "getSurface", "()Landroid/view/Surface;")
  call(surface, "setFrameRate", "(FI)V", { { f = hz or peakRate() }, { i = 0 } }, "Void") -- FRAME_RATE_COMPATIBILITY_DEFAULT
end

-- the game gets a new surface each time it comes back, without the rate
on("update", function()
  if UE.Application.isFocused and not focused then phigrospp.frameRate(rate) end
  focused = UE.Application.isFocused
end)

-- a function calling a java getter of an object, with no local reference left behind each time
local function getter(object, name, signature, kind)
  object = JNI.NewGlobalRef(object)
  local method = JNI.GetMethodID(JNI.GetObjectClass(object), name, signature)
  return function() return JNI["Call" .. kind .. "Method"](object, method, {}) end
end

-- the screen's refresh rate right now (Hz), and android's thermal status from 0 (none) to 6 (shutdown)
phigrospp.refreshRate = getter(call(activity(), "getDisplay", "()Landroid/view/Display;"), "getRefreshRate", "()F", "Float")
phigrospp.thermal = getter(call(activity(), "getSystemService", "(Ljava/lang/String;)Ljava/lang/Object;", { jstring("power") }),
  "getCurrentThermalStatus", "()I", "Int")

-- the app's own folder, which no other app can read on any android: for secrets (the phigros.tools key)
function phigrospp.private()
  local dir = call(activity(), "getFilesDir", "()Ljava/io/File;")
  return JNI.GetStringUTFChars(call(dir, "getAbsolutePath", "()Ljava/lang/String;"))
end

-- the link the app was opened with or brought back by (phigrospp://...), given once
local function opened()
  local intent = call(activity(), "getIntent", "()Landroid/content/Intent;")
  local link = call(intent, "getDataString", "()Ljava/lang/String;")
  if link == 0 then return nil end -- a null object
  call(intent, "setData", "(Landroid/net/Uri;)Landroid/content/Intent;", { { l = 0 } })
  return JNI.GetStringUTFChars(link)
end

-- on("link") hears of it. the app doesn't always see itself lose the focus, so it's looked for twice a second
every(0.5, function()
  JNI.PushLocalFrame(8)
  local link = opened()
  JNI.PopLocalFrame(0)
  if link then phigrospp.emit("link", link) end
end)

-- android's file picker, showing the files of the mime types given: the picked file's bytes and name, nothing when
-- the player backs out, nil and why when it can't be read. it waits for the player, so it's called from a coroutine
-- (a button's function is one). the picker answers the Fragment of the bundle's picker.dex (Picker.java)
local Picker, picking

function phigrospp.pick(...)
  local waiting, main = coroutine.running()
  assert(not main, "phigrospp.pick waits for the player: call it from a button's function or a coroutine")
  if picking then return end -- a second tap before the picker shows
  JNI.PushLocalFrame(16)
  if not Picker then
    local Buffer, Loader = JNI.FindClass("java/nio/ByteBuffer"), JNI.FindClass("dalvik/system/InMemoryDexClassLoader")
    local dex = JNI.CallStaticObjectMethod(Buffer, JNI.GetStaticMethodID(Buffer, "wrap", "([B)Ljava/nio/ByteBuffer;"),
      { { l = JNI.ToByteArray(il2cpp.bytes(phigrospp.bundle["picker.dex"])) } })
    local loader = JNI.NewObject(Loader, JNI.GetMethodID(Loader, "<init>", "(Ljava/nio/ByteBuffer;Ljava/lang/ClassLoader;)V"),
      { { l = dex }, { l = call(activity(), "getClassLoader", "()Ljava/lang/ClassLoader;") } })
    Picker = JNI.NewGlobalRef(call(loader, "loadClass", "(Ljava/lang/String;)Ljava/lang/Class;",
      { jstring("phigrospp.Picker") }))
  end
  local types = JNI.NewObjectArray(select("#", ...), JNI.FindClass("java/lang/String"), 0)
  for i, mime in ipairs({ ... }) do JNI.SetObjectArrayElement(types, i - 1, JNI.NewStringUTF(mime)) end
  JNI.CallStaticVoidMethod(Picker, JNI.GetStaticMethodID(Picker, "pick", "(Landroid/app/Activity;[Ljava/lang/String;)V"),
    { { l = activity() }, { l = types } })
  JNI.PopLocalFrame(0)
  picking = waiting
  return coroutine.yield()
end

on("update", function()
  if not picking or not JNI.GetStaticBooleanField(Picker, JNI.GetStaticFieldID(Picker, "done", "Z")) then return end
  JNI.PushLocalFrame(16)
  local field = JNI.GetStaticFieldID(Picker, "data", "[B")
  local data = JNI.GetStaticObjectField(Picker, field)
  local name = JNI.GetStaticStringField(Picker, JNI.GetStaticFieldID(Picker, "name", "Ljava/lang/String;"))
  data = data ~= 0 and il2cpp.unbytes(JNI.FromByteArray(data)) or nil
  JNI.SetStaticObjectField(Picker, field, 0) -- java keeps no copy
  JNI.PopLocalFrame(0)
  local waiting = picking
  picking = nil
  resume(waiting, data, name)
end)

-- a path relative to the file of the mod calling an api function `level` frames up
function phigrospp.resolve(path, level)
  if path:sub(1, 1) == "/" then return path end
  return debug.getinfo(level + 1, "S").source:match("^@(.*/)") .. path
end

-- unity destroys textures and sprites nothing in a scene uses when scenes change, assets made by the api are kept
-- until the next reload instead
local assets = {}

function phigrospp.asset(object)
  object.hideFlags = 32 -- DontUnloadUnusedAsset
  assets[#assets + 1] = object
  return object
end

on("unload", function()
  for _, asset in ipairs(assets) do UE.Object.Destroy(asset) end
end)

-- image("logo.png") is a Sprite of a png or jpg next to the calling mod's file
local images = {}

-- a Texture2D of a png's or jpg's bytes
function phigrospp.texture(bytes)
  local texture = phigrospp.asset(UE.Texture2D(2, 2))
  UE.ImageConversion.LoadImage(texture, il2cpp.bytes(bytes))
  return texture
end

function image(path)
  path = phigrospp.resolve(path, 2)
  if not images[path] then
    local texture = phigrospp.texture(phigrospp.read(path))
    images[path] = phigrospp.asset(UE.Sprite.Create(texture, { 0, 0, texture.width, texture.height }, { 0.5, 0.5 }))
  end
  return images[path]
end

-- a white n by n sprite drawn from shape(x, y), the signed distance in pixels from the pixel to the shape's edge
-- (negative inside) with the centre at 0, 0. it's tinted by the Image showing it
function phigrospp.sprite(n, shape)
  local pixels, c = {}, (n - 1) / 2
  for y = 0, n - 1 do
    for x = 0, n - 1 do
      local alpha = math.max(0, math.min(1, 0.5 - shape(x - c, y - c)))
      pixels[y * n + x + 1] = { r = 255, g = 255, b = 255, a = math.floor(alpha * 255) }
    end
  end
  local texture = phigrospp.asset(UE.Texture2D(n, n))
  texture.wrapMode = 1 -- Clamp, so a stretched sprite's edges don't blend with the opposite ones
  texture:SetPixels32(pixels)
  texture:Apply()
  return phigrospp.asset(UE.Sprite.Create(texture, { 0, 0, n, n }, { 0.5, 0.5 }))
end

-- what the open dialog redraws every frame (its bar, its tiles), and what closes it
local drawBar, closeDialog
local DARK = { 0.02, 0.13, 0.17, 1 } -- what's drawn on a lit tile

-- a tile of a dialog's grid: a plate to tap, an icon over a label and a note. returns what repaints it, lit in its
-- colour while cell.on() says so
local function tile(parent, font, cell, pos, size)
  local ui = phigrospp.ui
  local plate = ui.rect(parent, "phigrospp-dialog-tile", pos, size, { 1, 1, 1, 1 }, { 0, 0 })
  plate.raycastTarget = true
  phigrospp.click(plate.gameObject:AddComponent(UE.UI.Button), cell.tap)
  local icon = ui.rect(plate.transform, "Icon", { size[1] / 2, size[2] - 14 }, { 76, 76 }, cell.colour, { 0.5, 1 })
  icon.sprite = cell.icon
  local label = ui.text(plate.transform, "Label", font, { size[1] / 2, 46 }, { size[1], 36 }, 30, 4, { 0.5, 0 })
  local note = ui.text(plate.transform, "Note", font, { size[1] / 2, 12 }, { size[1], 30 }, 24, 4, { 0.5, 0 })
  label.text = cell.label
  return function()
    local lit = cell.on()
    plate.color, icon.color = lit and cell.colour or { 1, 1, 1, 0.08 }, lit and DARK or cell.colour
    label.color, note.color, note.text = lit and DARK or { 1, 1, 1, 1 }, lit and DARK or { 1, 1, 1, 0.6 }, cell.note()
  end
end
-- the panels, lists and videos of phigrospp.ui that are on screen
local panels, lists, videos = {}, {}, {}
local SLIDE = 0.35 -- seconds a panel takes to come and go

-- calls each(item) for the ones whose object lives, an item whose object died with its scene or each() says is done
-- (true) is forgotten
local function live(items, each)
  for i = #items, 1, -1 do
    if not il2cpp.alive(items[i].transform) or each(items[i]) then table.remove(items, i) end
  end
end

on("update", function()
  if drawBar then drawBar() end
  live(panels, function(p)
    local f = math.min(1, (now() - p.start) / SLIDE)
    f = f * f * (3 - 2 * f)
    local shown = p.closing and 1 - f or f
    p.group.alpha, p.group.blocksRaycasts = shown, not p.closing
    p.transform.anchoredPosition = { 160 * (1 - shown), 0 }
    if not p.closing or f < 1 then return false end
    UE.Object.Destroy(p.transform.gameObject)
    if p.closed then p.closed() end
    return true
  end)
  -- the rows slide sideways as they scroll, along the slant, like the game's lists. they're centred on the middle of
  -- the list: rows above it lean right and below it left
  live(lists, function(l)
    if not l.width then return true end -- an upright one stays where it is
    local view, slope = l.transform.rect, CS.SettingItemsManager.InverseSlope
    l.rows.anchoredPosition = { (view.m_Width - l.width) / 2 + (view.m_Height / 2 + l.content.anchoredPosition.y) * slope, -16 }
  end)
  live(videos, function(v)
    if not v.player.isPrepared then return false end
    v.view.color = { 1, 1, 1, 1 }
    phigrospp.ui.fit(v.view, v.player.texture)
    v.player:Play()
    return true
  end)
end)

-- the Phigros++ screens (replay player and picker): canvases over everything, pieces placed in screen pixels from the
-- bottom left, and icons (icons.lua)
phigrospp.ui = {
  overlay = function(name, order)
    local go = UE.GameObject(name)
    local canvas = go:AddComponent(UE.Canvas)
    canvas.renderMode, canvas.sortingOrder = 0, order -- ScreenSpaceOverlay
    return go
  end,
  -- a canvas over everything in any scene, 1080 units high like the game's menus, whose buttons take taps: its
  -- transform and its width. it gets its size on its first frame, so pieces go from its bottom left corner
  screen = function(name, order)
    local go = phigrospp.ui.overlay(name, order)
    local scaler = go:AddComponent(UE.UI.CanvasScaler)
    scaler.uiScaleMode, scaler.referenceResolution, scaler.matchWidthOrHeight = 1, { 1920, 1080 }, 1 -- ScaleWithScreenSize
    go:AddComponent(UE.UI.GraphicRaycaster)
    return go.transform, 1080 * UE.Screen.width / UE.Screen.height
  end,
  -- a component on a new object under parent, from its bottom left corner
  place = function(parent, name, kind, pos, size, pivot)
    local component = UE.GameObject(name):AddComponent(kind)
    local t = component.transform
    t:SetParent(parent, false)
    t.anchorMin, t.anchorMax, t.pivot = { 0, 0 }, { 0, 0 }, pivot or { 0, 0.5 }
    t.anchoredPosition, t.sizeDelta = pos, size
    component.raycastTarget = false
    return component
  end,
  rect = function(parent, name, pos, size, colour, pivot)
    local image = phigrospp.ui.place(parent, name, UE.UI.Image, pos, size, pivot)
    image.color = colour
    return image
  end,
  -- alignment is a TextAnchor, text overflows its box
  text = function(parent, name, font, pos, size, fontSize, alignment, pivot)
    local text = phigrospp.ui.place(parent, name, UE.UI.Text, pos, size, pivot)
    text.font, text.fontSize, text.alignment = font, math.floor(fontSize), alignment
    text.horizontalOverflow, text.verticalOverflow, text.color = 1, 1, { 1, 1, 1, 1 } -- Overflow
    return text
  end,
  -- a copy of a button of the game beside it, moved by offset ({ x, y }), running fn instead of what the original does
  clone = function(original, offset, fn)
    local t = original.transform
    local clone = UE.Object.Instantiate(t.gameObject, t.parent, false)
    clone.name = "phigrospp-" .. t.name
    clone.transform.anchoredPosition = { t.anchoredPosition.x + offset[1], t.anchoredPosition.y + offset[2] }
    local button = clone:GetComponent(UE.UI.Button)
    button.onClick = UE.UI.Button.ButtonClickedEvent()
    phigrospp.click(button, fn)
    return clone
  end,
  danger = { 0.9, 0.27, 0.33, 1 }, -- the red of buttons that delete
  -- a bar slanted like the game's, its bottom further left, placed from its top left corner
  bar = function(parent, name, pos, size, colour)
    local shape = phigrospp.ui.place(parent, name, CS.Lean.Gui.LeanPolygon, pos, size, { 0, 1 })
    local lean = -size[2] * CS.SettingItemsManager.InverseSlope
    for _, point in ipairs({ { 0, 0, 0, 1 }, { 0, 0, 1, 1 }, { lean, 0, 1, 0 }, { lean, 0, 0, 0 } }) do
      shape.Points:Add(point) -- offset x, y from the anchor x, y in the shape
    end
    shape.Blur, shape.color = 0.5, colour
    shape:SetVerticesDirty()
    return shape
  end,
  -- a screen over a canvas, sliding in over a shade that catches the taps: { transform =, close = }. closed() runs
  -- once it slid out and is gone. shade is how dark it is, for a screen whose texts go over what's under
  panel = function(canvas, name, closed, shade)
    local root = UE.GameObject(name):AddComponent(UE.RectTransform)
    root:SetParent(canvas, false)
    root.anchorMin, root.anchorMax, root.sizeDelta = { 0, 0 }, { 1, 1 }, { 0, 0 }
    local p = { transform = root, group = root.gameObject:AddComponent(UE.CanvasGroup), start = now(), closed = closed }
    local dark = phigrospp.ui.rect(root, name .. "-shade", { 0, 0 }, { 0, 0 }, { 0, 0, 0, shade or 0.85 }, { 0, 0 })
    dark.transform.anchorMax, dark.raycastTarget = { 1, 1 }, true
    function p.close()
      if not p.closing then p.closing, p.start = true, now() end
    end
    panels[#panels + 1] = p
    return p
  end,
  -- a list scrolling like the game's: { transform = its view, content =, rows = }. rows `width` wide go in rows from
  -- its top (a bar at { -y * slope, -y }), and content.sizeDelta's y is the height they take. without a width it's
  -- upright: what's put in rows scrolls straight up and down
  list = function(parent, name, pos, size, width)
    local view = phigrospp.ui.rect(parent, name, pos, size, { 0, 0, 0, 0 }, { 0, 0 })
    view.raycastTarget = true -- drags between rows scroll too
    view.gameObject:AddComponent(UE.UI.RectMask2D)
    local function stretched(child, under)
      local t = UE.GameObject(child):AddComponent(UE.RectTransform)
      t:SetParent(under, false)
      t.anchorMin, t.anchorMax, t.pivot, t.sizeDelta = { 0, 1 }, { 1, 1 }, { 0, 1 }, { 0, 0 }
      return t
    end
    local l = { transform = view.transform, width = width }
    l.content = stretched("Content", l.transform)
    l.rows = stretched("Rows", l.content)
    local scroll = view.gameObject:AddComponent(UE.UI.ScrollRect)
    scroll.viewport, scroll.content, scroll.horizontal = l.transform, l.content, false
    lists[#lists + 1] = l
    return l
  end,
  -- shows a texture in a RawImage, which shrinks to the texture's shape inside the box it had
  fit = function(view, texture)
    local box = view.transform.sizeDelta
    local scale = math.min(box.x / texture.width, box.y / texture.height)
    view.texture, view.transform.sizeDelta = texture, { texture.width * scale, texture.height * scale }
  end,
  -- a video of a url or a file, looping without sound in a RawImage that shows poster (a Texture, if any) until it
  -- plays. it keeps its shape inside size
  video = function(parent, name, pos, size, url, poster, pivot)
    local view = phigrospp.ui.place(parent, name, UE.UI.RawImage, pos, size, pivot)
    view.color = { 1, 1, 1, poster and 1 or 0.08 }
    if poster then phigrospp.ui.fit(view, poster) end
    local player = view.gameObject:AddComponent(UE.Video.VideoPlayer)
    -- APIOnly: the frames are only drawn to player.texture
    player.playOnAwake, player.renderMode, player.isLooping, player.url = false, 4, true, url
    player:Prepare()
    videos[#videos + 1] = { transform = view.transform, view = view, player = player }
    return view
  end,
  -- a dialog made from the game's own confirmation popup (the cloud save one): { title =, message =, yes =,
  -- danger = true for a red yes, no = false for yes alone (yes = false for no alone), grid = { cells =, columns = }
  -- texts in aligned columns under the message (one column centered), a cell being false for none or a tile to tap
  -- { icon = a Sprite, label =, colour =, tap = what a tap runs, on = whether it's lit and note = the text under
  -- its label, both functions asked every frame } in rows grid.height high, input = a text box's placeholder, its text
  -- returned after the choice, progress = a function returning how much is done (0 to 1) and the message, a bar
  -- redrawn every frame }. called from a coroutine (a button's function is one), it waits and returns whether yes was
  -- picked
  confirm = function(options)
    local waiting, main = coroutine.running()
    assert(not main, "phigrospp.ui.confirm waits for the player: call it from a button's function or a coroutine")
    local prefab = UE.Resources.FindObjectsOfTypeAll(il2cpp.typeof(CS.ConfirmationPopup))[0]
    assert(prefab, "the game's confirmation popup isn't loaded")
    local go = UE.Object.Instantiate(prefab.gameObject)
    UE.Object.Destroy(go:GetComponent(CS.ConfirmationPopup))
    local canvas = phigrospp.find(go.transform, "ContentCanvas")
    local c = canvas:GetComponent(UE.Canvas)
    c.renderMode, c.sortingOrder = 0, 32767 -- over everything, pages included
    local shade = phigrospp.ui.rect(canvas, "phigrospp-dialog-shade", { 0, 0 }, { 0, 0 }, { 0, 0, 0, 0.75 }, { 0, 0 })
    shade.transform.anchorMax, shade.raycastTarget = { 1, 1 }, true -- and catches the taps meant for what's under
    shade.transform:SetAsFirstSibling()
    local panel = phigrospp.find(canvas, "Box")
    for _, name in ipairs({ "Contents", "ContentCover", "Warning" }) do UE.Object.Destroy(phigrospp.find(panel, name).gameObject) end
    local back = panel:GetComponent(CS.Lean.Gui.LeanPolygon)
    local colour = back.color
    back.color = { colour.r, colour.g, colour.b, 0.95 } -- the game blurs what's under it, a page can't be
    phigrospp.find(panel, "Title"):GetComponent(UE.UI.Text).text = options.title
    -- the message wraps, the grid's cells go under it in aligned columns, and the panel grows to fit all of them (430
    -- high with a line)
    local LINE, ROW, GAP, INPUT, BAR = 44, 64, 24, 3 * 44 + 40, 12
    local subtitle = phigrospp.find(panel, "SubTitle")
    local message = subtitle:GetComponent(UE.UI.Text)
    message.text, message.horizontalOverflow = options.message, 0 -- Wrap
    -- without a message its line is only kept for the one a progress bar writes
    local height = (options.message or options.progress) and math.max(LINE, message.preferredHeight) or 0
    if options.grid then
      local cells, columns, high = options.grid.cells, options.grid.columns, options.grid.height or ROW
      local rows, width = math.ceil(#cells / columns), subtitle.rect.m_Width / columns
      local tiles = {}
      -- the message keeps the top of the subtitle, the cells fill the space added under it
      message.alignment = 0 -- UpperLeft
      for i, cell in ipairs(cells) do
        local row = (i - 1) // columns
        local pos = { (i - 1) % columns * width, (rows - 1 - row) * high }
        if type(cell) == "table" then
          -- tiles fill the width, so each row goes left with the panel's slanted edges
          pos[1] = pos[1] - row * high * CS.SettingItemsManager.InverseSlope
          tiles[#tiles + 1] = tile(subtitle, message.font, cell, pos, { width - GAP / 2, high - GAP / 2 })
        elseif cell then
          -- one column has nothing to line up with, so it's centered
          local text = phigrospp.ui.text(subtitle, "phigrospp-dialog-cell", message.font, pos, { width, high }, 44,
            columns == 1 and 4 or 3, { 0, 0 }) -- MiddleCenter, MiddleLeft
          text.text, text.fontStyle = cell, 1 -- Bold
        end
      end
      if #tiles > 0 then
        drawBar = function()
          for _, paint in ipairs(tiles) do paint() end
        end
      end
      height = height + GAP + rows * high
    end
    -- a text box under the message, the game opens its keyboard when it's tapped
    local field
    if options.input then
      message.alignment = 0 -- UpperLeft
      -- three lines of text, a longer one scrolls inside the box. it ends with the yes button's label, before the
      -- panel's slanted edge
      local width = subtitle.rect.m_Width - 150
      local area = phigrospp.ui.rect(subtitle, "phigrospp-dialog-input", { 0, 0 }, { width, INPUT },
        { 1, 1, 1, 0.1 }, { 0, 0 })
      area.raycastTarget = true
      area.gameObject:AddComponent(UE.UI.RectMask2D)
      local function line(name, tint)
        local text = phigrospp.ui.text(area.transform, name, message.font, { 24, 20 }, { width - 48, INPUT - 40 },
          message.fontSize, 0, { 0, 0 }) -- UpperLeft
        text.horizontalOverflow, text.verticalOverflow, text.supportRichText, text.color = 0, 0, false, tint -- Wrap, Truncate
        return text
      end
      field = area.gameObject:AddComponent(UE.UI.InputField)
      field.textComponent, field.lineType = line("Text", { 1, 1, 1, 1 }), 1 -- MultiLineSubmit
      local hint = line("Placeholder", { 1, 1, 1, 0.4 })
      hint.text, field.placeholder = options.input, hint
      height = height + GAP + INPUT
    end
    if options.progress then
      message.alignment = 0 -- UpperLeft
      local width = subtitle.rect.m_Width - 150
      phigrospp.ui.rect(subtitle, "phigrospp-dialog-track", { 0, 0 }, { width, BAR }, { 1, 1, 1, 0.15 }, { 0, 0 })
      local fill = phigrospp.ui.rect(subtitle, "phigrospp-dialog-fill", { 0, 0 }, { 0, BAR }, { 1, 1, 1, 1 }, { 0, 0 })
      drawBar = function()
        local done, text = options.progress()
        fill.transform.sizeDelta = { width * math.max(0, math.min(1, done)), BAR }
        message.text = text
      end
      height = height + GAP + BAR
    end
    subtitle.sizeDelta = { subtitle.sizeDelta.x, height }
    panel.sizeDelta = { panel.sizeDelta.x, 430 - LINE + height }
    local function choice(name, label, answer)
      local t = phigrospp.find(panel, "Operations/" .. name)
      local text = phigrospp.find(t, "Text"):GetComponent(UE.UI.Text)
      text.text, text.color = label, { 1, 1, 1, 1 } -- the popup greys its yes until its own checks pass
      local button = t:GetComponent(UE.UI.Button)
      button.onClick, button.interactable = UE.UI.Button.ButtonClickedEvent(), true -- the popup can start it disabled
      phigrospp.click(button, function() closeDialog(answer, field and field.text) end)
      return t
    end
    closeDialog = function(...)
      UE.Object.Destroy(go)
      phigrospp.ui.dialog, drawBar, closeDialog = nil, nil, nil
      resume(waiting, ...)
    end
    local yes = choice("OkButton", options.yes or "", true)
    if options.yes == false then yes.gameObject:SetActive(false) end
    if options.danger then phigrospp.find(yes, "Text"):GetComponent(UE.UI.Text).color = phigrospp.ui.danger end
    local no = choice("CancelButton", options.no or "Cancel", false)
    if options.no == false then no.gameObject:SetActive(false) end
    go:SetActive(true)
    phigrospp.ui.dialog = go -- what reads touches itself leaves them alone while it's open
    return coroutine.yield()
  end,
  -- closes the open dialog, its confirm returning what's given
  close = function(...) closeDialog(...) end,
}
