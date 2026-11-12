-- until a song is finished the game starts on the tutorial and greys back and retry in pause menus: both work again,
-- back from the tutorial goes to the chapters, and the save is left as it is

local UE = CS.UnityEngine

hook(CS.JudgeControl, "Start", {
  after = function(judge)
    if judge.backButtonCollider.enabled then return end
    for _, button in ipairs({ "back", "retry" }) do
      judge[button .. "ButtonCollider"].enabled = true
      judge[button .. "Button"]:GetComponent(UE.UI.Image).color = { 1, 1, 1, 1 }
    end
    if CS.GameInformation.main.levelStartInfo.songsId == "Introduction" then
      judge.progressControl.pauseBar:GetComponent(CS.Pause).BackToChapterSelect = true
    end
  end,
})
