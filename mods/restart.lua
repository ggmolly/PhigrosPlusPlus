-- instant restart: the pause menu's Retry and holding the pause button put the song back at its start in place,
-- without loading the level again

local enabled = setting("Instant restart", true)
local HOLD = 0.3 -- seconds the pause button is held to restart

local progress, held -- the song's ProgressControl, and the finger on the pause button with when it came

-- the pause menu's Retry (Pause.Update) is the only LoadScene("Level") while a song is played
hook(CS.UnityEngine.SceneManagement.SceneManager, "LoadScene", { "System.String" }, {
  skip = function(name)
    if name ~= "Level" or not progress or replaying() or not enabled() then return false end
    phigrospp.restart()
    return true
  end,
})

on("song", function() progress = CS.UnityEngine.Object.FindObjectOfType(CS.ProgressControl) end)
on("leave", function() progress, held = nil, nil end)

on("update", function()
  if not progress or not progress.isPlaying or replaying() or not enabled() then return end
  local still
  for _, t in ipairs(touches()) do
    if held and t.id == held.id and t.phase ~= 3 and t.phase ~= 4 then still = true end -- not Ended or Canceled
    if t.phase == 0 and phigrospp.pauseButton(t.x, t.y) then held, still = { id = t.id, since = now() }, true end -- Began
  end
  if not still then held = nil end
  if held and now() - held.since >= HOLD then
    held = nil
    phigrospp.restart()
  end
end)
