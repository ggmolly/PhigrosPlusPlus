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

function phigrospp.click(button, fn) clicks[button] = fn end

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

-- the app's own folder, which no other app can read on any android: for secrets (the phigros.tools key)
function phigrospp.private()
  local dir = call(activity(), "getFilesDir", "()Ljava/io/File;")
  return JNI.GetStringUTFChars(call(dir, "getAbsolutePath", "()Ljava/lang/String;"))
end

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

function image(path)
  path = phigrospp.resolve(path, 2)
  if not images[path] then
    local texture = phigrospp.asset(UE.Texture2D(2, 2))
    UE.ImageConversion.LoadImage(texture, il2cpp.bytes(phigrospp.read(path)))
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

-- the Phigros++ screens (replay player and picker): canvases over everything, pieces placed in screen pixels from the
-- bottom left, and icons drawn from shapes
local function polygon(points)
  return function(x, y)
    local d = -math.huge
    for i, a in ipairs(points) do
      local b = points[i % #points + 1]
      local nx, ny = b[2] - a[2], a[1] - b[1]
      d = math.max(d, ((x - a[1]) * nx + (y - a[2]) * ny) / math.sqrt(nx * nx + ny * ny))
    end
    return d
  end
end

local function union(...)
  local shapes = { ... }
  return function(x, y)
    local d = math.huge
    for _, shape in ipairs(shapes) do d = math.min(d, shape(x, y)) end
    return d
  end
end

local function mirror(shape) return function(x, y) return shape(-x, y) end end
local function flip(shape) return function(x, y) return shape(x, -y) end end
local function box(cx, cy, hw, hh) return polygon({ { cx - hw, cy - hh }, { cx + hw, cy - hh }, { cx + hw, cy + hh }, { cx - hw, cy + hh } }) end

-- a stroke w wide from a to b
local function stroke(ax, ay, bx, by, w)
  local dx, dy = bx - ax, by - ay
  local nx, ny = -dy / math.sqrt(dx * dx + dy * dy) * w / 2, dx / math.sqrt(dx * dx + dy * dy) * w / 2
  return polygon({ { ax - nx, ay - ny }, { bx - nx, by - ny }, { bx + nx, by + ny }, { ax + nx, ay + ny } })
end

local FORWARD = union(polygon({ { -38, -28 }, { 2, 0 }, { -38, 28 } }), polygon({ { 2, -28 }, { 42, 0 }, { 2, 28 } }))
local ARROW = union(polygon({ { -40, 0 }, { -6, -34 }, { -6, 34 } }), box(14, 0, 26, 5)) -- pointing left
-- 96 pixel icons, as signed distances (see phigrospp.sprite)
local ICONS = {
  play = polygon({ { -26, -36 }, { 36, 0 }, { -26, 36 } }),
  pause = union(box(-17, 0, 9, 34), box(17, 0, 9, 34)),
  forward = FORWARD,
  back = mirror(FORWARD),
  restart = union(box(-32, 0, 5, 30), mirror(polygon({ { -24, -32 }, { 32, 0 }, { -24, 32 } }))),
  close = ARROW,
  cross = union(stroke(-32, -32, 32, 32, 10), stroke(-32, 32, 32, -32, 10)),
  bin = union(box(0, 30, 34, 4), box(0, 37, 10, 4), polygon({ { -20, -38 }, { 20, -38 }, { 26, 22 }, { -26, 22 } })),
  down = union(polygon({ { -24, -8 }, { 24, -8 }, { 0, -38 } }), box(0, 14, 5, 24)), -- an arrow pointing down
}
ICONS.up = flip(ICONS.down)
local icons = {}

-- the open dialog's bar, redrawn every frame, and what closes it
local drawBar, closeDialog

on("update", function()
  if drawBar then drawBar() end
end)

phigrospp.ui = {
  overlay = function(name, order)
    local go = UE.GameObject(name)
    local canvas = go:AddComponent(UE.Canvas)
    canvas.renderMode, canvas.sortingOrder = 0, order -- ScreenSpaceOverlay
    return go
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
  icon = function(name)
    icons[name] = icons[name] or phigrospp.sprite(96, ICONS[name])
    return icons[name]
  end,
  danger = { 0.9, 0.27, 0.33, 1 }, -- the red of buttons that delete
  -- a dialog made from the game's own confirmation popup (the cloud save one): { title =, message =, yes =,
  -- danger = true for a red yes, no = false for yes alone (yes = false for no alone), grid = { cells =, columns = }
  -- texts in aligned columns under the message, input = a text box's placeholder, its text returned after the choice,
  -- progress = a function returning how much is done (0 to 1) and the message, a bar redrawn every frame }. called
  -- from a coroutine (a button's function is one), it waits and returns whether yes was picked
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
    local height = math.max(LINE, message.preferredHeight)
    if options.grid then
      local cells, columns = options.grid.cells, options.grid.columns
      local rows, width = math.ceil(#cells / columns), subtitle.rect.m_Width / columns
      -- the message keeps the top of the subtitle, the cells fill the space added under it
      message.alignment = 0 -- UpperLeft
      for i, cell in ipairs(cells) do
        local column, row = (i - 1) % columns, (i - 1) // columns
        local text = phigrospp.ui.text(subtitle, "phigrospp-dialog-cell", message.font, { column * width, (rows - 1 - row) * ROW },
          { width, ROW }, 44, 3, { 0, 0 }) -- MiddleLeft
        text.text, text.fontStyle = cell, 1 -- Bold
      end
      height = height + GAP + rows * ROW
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
