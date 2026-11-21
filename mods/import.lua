-- on a rooted device, a fresh install offers once to take the save of Phigros installed next to it: its PlayerPrefs
-- file is copied as root over Phigros++'s own, then the app is killed, since quitting would write its prefs back over it

if phigrospp.platform ~= "android" then return end

local UE = CS.UnityEngine
local ASKED = phigrospp.root .. "/import-asked"
local GAME = "/data/data/com.PigeonGames.Phigros/shared_prefs/com.PigeonGames.Phigros.v2.playerprefs.xml"

-- the copy takes the owner and SELinux label of the folder it goes in, as files the app writes itself have
local function copy()
  local app = UE.Application.identifier
  local dir = ("/data/data/%s/shared_prefs"):format(app)
  local to = ("%s/%s.v2.playerprefs.xml"):format(dir, app)
  local script = ("test -f %s && cp %s %s && chown $(stat -c %%u:%%g %s) %s && chmod 660 %s && chcon $(stat -c %%C %s) %s"
    .. " && am force-stop %s"):format(GAME, GAME, to, dir, to, to, dir, to, app)
  io.popen(("su -c '%s'"):format(script)):close()
end

local function offer()
  phigrospp.write(ASKED, "")
  if not phigrospp.ui.confirm({ title = "Bring your Phigros save over?", yes = "Copy my save", no = "No",
        message = "Phigros++ can copy the save of Phigros on this device, records, unlocks and settings included. It "
          .. "needs root access, and Phigros itself is left as it is. Phigros++ closes once the save is copied, open "
          .. "it again." }) then
    return
  end
  copy()
  -- still running: the copy didn't happen
  phigrospp.ui.confirm({ title = "Couldn't copy the save", yes = "OK", no = false,
    message = "Root access was refused, or Phigros has no save on this device." })
end

on("scene", function(name)
  if name ~= "ChapterSelector" or CS.System.IO.File.Exists(ASKED) or CS.CloudSaveSummary.FromLocalSave().RankingScore ~= 0
      or not io.popen("command -v su"):read("l") then
    return
  end
  coroutine.wrap(offer)()
end)
