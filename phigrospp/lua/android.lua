-- the android side of the platform api (ios.lua has the same functions): toasts, sharing and the screen, through
-- raw jni since unity's java helpers are generic methods the bridge can't call
if phigrospp.platform ~= "android" then return end

local UE = CS.UnityEngine

function toast(message) CS.Tools.AndroidAPIs.Toast(tostring(message)) end

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

-- the link the app was opened with (phigrospp://...), given once
function phigrospp.link()
  local intent = call(activity(), "getIntent", "()Landroid/content/Intent;")
  local link = call(intent, "getDataString", "()Ljava/lang/String;")
  if link == 0 then return nil end -- a null object
  call(intent, "setData", "(Landroid/net/Uri;)Landroid/content/Intent;", { { l = 0 } })
  return JNI.GetStringUTFChars(link)
end
