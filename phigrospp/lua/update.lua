-- updates from github releases, offered in a popup on the chapter screen (see the wiki's Updates page). a release's
-- phigrospp.version is its bundle's first line, the newest game last

local ui = phigrospp.ui
local RELEASES = "https://github.com/ggmolly/PhigrosPlusPlus/releases"
local DOWNLOAD = RELEASES .. "/latest/download/"
local SKIPPED = phigrospp.root .. "/skipped" -- the last version the player skipped

-- the version offered, the game of its app when it needs a newer app, and whether its popup waits for the chapter
-- screen
local latest, game, prompt

local function number(version)
  local major, minor, patch = version:match("^(%d+)%.(%d+)%.(%d+)$")
  return tonumber(major) * 1000000 + tonumber(minor) * 1000 + tonumber(patch)
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
  prompt = nil
  if game then
    if ui.confirm({ title = "Phigros++ " .. latest, message = ("This update comes as a new app, for Phigros %s."):format(game),
          yes = "Download", no = "Skip" }) then
      return CS.UnityEngine.Application.OpenURL(RELEASES .. "/latest")
    end
  elseif ui.confirm({ title = "Phigros++ " .. latest, message = "A new version of Phigros++ is ready to download.",
        yes = "Update", no = "Skip" }) then
    return install()
  end
  phigrospp.write(SKIPPED, latest)
end

link(function() return ("Update to Phigros++ %s"):format(latest) end, offer, nil, function() return latest ~= nil end)

on("scene", function(name)
  if prompt and name == "ChapterSelector" then coroutine.wrap(offer)() end
end)

phigrospp.fetch("GET", DOWNLOAD .. "phigrospp.version", nil, function(status, line)
  if status ~= 200 then return print(("update: no release found (%d)"):format(status)) end
  local native, version, games = line:match("^phigros%+%+ (%d+) (%S+) (.-)%s*$")
  native = tonumber(native)
  local newest = games:match("(%S+)$")
  local runs = native == phigrospp.native and (" " .. games .. " "):find(" " .. phigrospp.game .. " ", 1, true)
  if runs and number(version) > number(phigrospp.version) then
    latest = version
  elseif number(version) > number(phigrospp.app) and (native ~= phigrospp.native or newest ~= phigrospp.game) then
    latest, game = version, newest
  else
    return
  end
  if skipped() == latest then return end
  if scene() == "ChapterSelector" then coroutine.wrap(offer)() else prompt = true end
end)
