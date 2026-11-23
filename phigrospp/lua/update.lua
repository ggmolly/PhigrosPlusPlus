-- updates from github releases, offered in a toast on the chapter screen (see the wiki's Updates page). a release's
-- phigrospp.version is its bundle's first line, with each platform's games as "android:4.0.1.2", the newest last

local ui = phigrospp.ui
local DOWNLOAD = "https://github.com/ggmolly/PhigrosPlusPlus/releases/latest/download/"
-- on ios phigros++ is patched into the game again from a computer (the wiki's Development page)
local INSTALLER = phigrospp.platform == "ios" and "https://github.com/ggmolly/PhigrosPlusPlus/releases/latest"
  or "https://github.com/ggmolly/PhigrosPlusPlus-Installer/releases/latest"
local SKIPPED = phigrospp.root .. "/skipped" -- the last version the player skipped

-- the version offered, the game of its app when it needs a newer app, whether its toast waits for the chapter
-- screen, and what dismisses that toast
local latest, game, prompt, dismiss

-- as bundle.c compares them: a beta ("1.2.3-beta.4") comes before its release
local function number(version)
  local major, minor, patch, rest = version:match("^(%d+)%.(%d+)%.(%d+)(.*)$")
  local beta = rest == "" and 999 or tonumber(rest:match("^%-beta%.(%d+)$"))
  return ((tonumber(major) * 1000 + tonumber(minor)) * 1000 + tonumber(patch)) * 1000 + beta
end

local function skipped()
  local file = io.open(SKIPPED, "rb")
  if not file then return nil end
  file:close()
  return phigrospp.read(SKIPPED)
end

-- downloads the bundle in a dialog with a progress bar, then reloads into it
local function install()
  local request, why
  request = phigrospp.fetch("GET", DOWNLOAD .. "phigrospp.bundle", nil, function(status, data)
    if not request then return end -- cancelled
    local version
    if status == 200 then version, why = phigrospp.check(data) else why = ("error %d"):format(status) end
    if version then
      phigrospp.write(phigrospp.root .. "/bundle", data)
      toast("Phigros++ updated to " .. version)
      phigrospp.reload()
    end
    ui.close(version ~= nil)
  end)
  local installed = ui.confirm({ title = "Phigros++ " .. latest, message = "Downloading", yes = false, no = "Cancel",
    progress = function()
      local length, got = request:GetResponseHeader("Content-Length"), request.downloadedBytes // 1024
      if not length then return 0, "Downloading" end
      local total = tonumber(length) // 1024
      return got / total, ("Downloading, %d of %d KB"):format(got, total)
    end })
  if installed then return end
  if why then
    return ui.confirm({ title = "The update failed", message = ("Nothing was changed (%s)."):format(why), yes = "OK", no = false })
  end
  local cancelled = request
  request = nil
  cancelled:Abort()
end

-- the popup offering the latest version, from a coroutine
local function offer()
  if game then
    local ios = phigrospp.platform == "ios"
    if ui.confirm({ title = "Phigros++ " .. latest, no = "Skip", yes = ios and "Open the release" or "Open the installer",
          message = (ios and "This update for Phigros %s is patched into the game from a computer."
            or "This update for Phigros %s is installed with the Phigros++ Installer."):format(game) }) then
      -- the installer that installed this app, else its download on the release page
      if not phigrospp.launch("sh.molly.phigrosplusplus.installer") then
        CS.UnityEngine.Application.OpenURL(INSTALLER)
      end
      return
    end
  elseif ui.confirm({ title = "Phigros++ " .. latest, message = "A new version of Phigros++ is ready to download.",
        yes = "Update", no = "Skip" }) then
    return install()
  end
  phigrospp.write(SKIPPED, latest)
end

link(function() return ("Update to Phigros++ %s"):format(latest) end, offer, nil, function() return latest ~= nil end)

-- nothing waits on the player: the toast opens the popup when tapped, and goes with the chapter screen
local function announce()
  prompt = nil
  dismiss = toast(("Phigros++ %s is out, tap to update"):format(latest), { seconds = 10, tap = offer })
end

on("scene", function(name)
  if dismiss then dismiss() end
  dismiss = nil
  if prompt and name == "ChapterSelector" then announce() end
end)

phigrospp.fetch("GET", DOWNLOAD .. "phigrospp.version", nil, function(status, line)
  if status ~= 200 then return print(("update: no release found (%d)"):format(status)) end
  local native, version, games = line:match("^phigros%+%+ (%d+) (%S+) (.-)%s*$")
  native = tonumber(native)
  local newest, runs
  for platform, listed in games:gmatch("(%a+):(%S+)") do
    if platform == phigrospp.platform then newest, runs = listed, runs or listed == phigrospp.game end
  end
  runs = runs and native == phigrospp.native
  if runs and number(version) > number(phigrospp.version) then
    latest = version
  elseif newest and number(version) > number(phigrospp.app)
    and (native ~= phigrospp.native or newest ~= phigrospp.game) then
    latest, game = version, newest
  else
    return
  end
  if skipped() == latest then return end
  if scene() == "ChapterSelector" then announce() else prompt = true end
end)
