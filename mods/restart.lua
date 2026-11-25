-- instant restart: the pause menu's Retry and holding the pause button put the song back at its start in place,
-- without loading the level again (a challenge run starts again from its first song)

local enabled = setting("Instant restart", true)
local HOLD = 0.3 -- seconds the pause button is held to restart

local progress -- the song's ProgressControl

-- the pause menu's Retry (Pause.Update) is the only LoadScene("Level") while a song is played
hook(CS.UnityEngine.SceneManagement.SceneManager, "LoadScene", { "System.String" }, {
  skip = function(name)
    if name ~= "Level" or not progress or replaying() or not enabled() then return false end
    phigrospp.restart()
    return true
  end,
})

on("song", function() progress = CS.UnityEngine.Object.FindObjectOfType(CS.ProgressControl) end)
on("leave", function() progress = nil end)

phigrospp.hold(function(x, y)
  return progress and progress.isPlaying and not replaying() and enabled() and phigrospp.pauseButton(x, y)
end, HOLD, phigrospp.restart)
