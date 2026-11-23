-- the ios side of the platform api (android.lua has the same functions). phigrospp.thermal and refreshRate come from ios.c
if phigrospp.platform ~= "ios" then return end

local UE = CS.UnityEngine

-- no share sheet without objective-c, the text goes to the clipboard instead
function phigrospp.share(text)
  UE.GUIUtility.systemCopyBuffer = text
  toast("Copied to the clipboard")
end

function phigrospp.feature() return false end

-- other apps can't be opened by name on ios
function phigrospp.launch() return false end

-- unity paces the frames itself on ios (CADisableMinimumFrameDurationOnPhone, set by scripts/ipa.ts, unlocks 120 Hz)
function phigrospp.frameRate() end

-- unity strips Application.targetFrameRate's getter on ios, where it caps the rate the game asks for (380) at the
-- screen's top one
phigrospp.targetFrameRate = phigrospp.refreshRate

function phigrospp.system() return UE.SystemInfo.operatingSystem end

-- Library/ is the app's own, unlike Documents/ which the Files app shows
function phigrospp.private() return os.getenv("HOME") .. "/Library" end

-- no file picker without objective-c: it answers like a player backing out of android's
function phigrospp.pick() end
