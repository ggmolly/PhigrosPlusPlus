-- the ios side of the platform api (android.lua has the same functions). phigrospp.thermal and refreshRate come from ios.c
if phigrospp.platform ~= "ios" then return end

local UE = CS.UnityEngine
local ui = phigrospp.ui

-- the game's own toast goes through android's jni, so this one is drawn over everything at the bottom of the screen
local shown
function toast(message)
  if shown then UE.Object.Destroy(shown) end
  local go = ui.overlay("phigrospp-toast", 32767)
  local font = UE.Resources.FindObjectsOfTypeAll(il2cpp.typeof(UE.Font))[0]
  local size = math.floor(UE.Screen.height / 28)
  local text = ui.text(go.transform, "phigrospp-toast-text", font, { UE.Screen.width / 2, size * 3 }, { 0, size },
    size, 4, { 0.5, 0.5 }) -- MiddleCenter
  text.text = tostring(message)
  local back = ui.rect(go.transform, "phigrospp-toast-back", { UE.Screen.width / 2, size * 3 },
    { text.preferredWidth + size * 2, size * 2 }, { 0, 0, 0, 0.75 }, { 0.5, 0.5 })
  back.transform:SetAsFirstSibling()
  shown = go
  after(2.5, function()
    if shown == go then shown = nil end
    UE.Object.Destroy(go)
  end)
end

-- no share sheet without objective-c, the text goes to the clipboard instead
function phigrospp.share(text)
  UE.GUIUtility.systemCopyBuffer = text
  toast("Copied to the clipboard")
end

function phigrospp.feature() return false end

-- other apps can't be opened by name on ios
function phigrospp.launch() return false end

-- unity paces the frames itself on ios (CADisableMinimumFrameDurationOnPhone, set by patch_ipa.py, unlocks 120 Hz)
function phigrospp.frameRate() end

-- Library/ is the app's own, unlike Documents/ which the Files app shows
function phigrospp.private() return os.getenv("HOME") .. "/Library" end
