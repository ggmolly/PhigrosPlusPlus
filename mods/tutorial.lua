-- until a song is finished the game starts on the tutorial and greys back and retry in pause menus: both work again.
-- back from the tutorial ends it as finishing it does, so the game starts on the chapters from then on

local UE = CS.UnityEngine
local tutorial -- the tutorial is being played

hook(CS.JudgeControl, "Start", {
  after = function(judge)
    if judge.backButtonCollider.enabled then return end
    for _, button in ipairs({ "back", "retry" }) do
      judge[button .. "ButtonCollider"].enabled = true
      judge[button .. "Button"]:GetComponent(UE.UI.Image).color = { 1, 1, 1, 1 }
    end
    tutorial = CS.GameInformation.main.levelStartInfo.songsId == "Introduction"
    if tutorial then judge.progressControl.pauseBar:GetComponent(CS.Pause).BackToChapterSelect = true end
  end,
})

-- what the result screen's HandleFirstRun saves, and the level background the pause menu's own exits destroy (left
-- alive, every later level would show the tutorial's)
on("scene", function(name)
  if name ~= "ChapterSelector" or not tutorial then return end
  tutorial = false
  CS.SaveManagement.SaveInt("IsFirstRun", 1)
  UE.PlayerPrefs.Save() -- unity writes them when the app pauses, a killed app would forget it
  local main = CS.GameInformation.main
  if il2cpp.alive(main.background) then UE.Object.Destroy(main.background) end
  main.background = nil
end)
