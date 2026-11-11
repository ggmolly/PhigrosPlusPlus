-- removes the artificial delays around loading

local enabled = setting("Reduce load times", false)

-- a coroutine yielding null instead of a WaitForSeconds resumes on the next frame, skipped(owner) runs after
local function skipWaits(coroutine, skipped)
  hook(il2cpp.find(coroutine)[1], "MoveNext", {
    after = function(self)
      if enabled() and il2cpp.is(self["<>2__current"], CS.UnityEngine.WaitForSeconds) then
        self["<>2__current"] = nil
        if skipped then skipped(self["<>4__this"]) end
      end
    end,
  })
end

-- the loading screen cover waits 0.9 to 1.5 s before loading starts
skipWaits("^Loading%.<LoadImage>")

-- tapping play waits 4 s on the start animation then 1 s on its fade out before the song loads.
-- both are hidden before they get drawn so the song list stays on screen until the song
skipWaits("^SongSelector%.<StartAnimation>", function(selector)
  selector.startAnimation:SetActive(false)
  selector.startFadeOutBackground:SetActive(false)
end)

-- leaving a screen fades it out while a leave time counts up to 0.67 s, starting past it skips the fade
local LEAVE = {
  ["SongSelector.<TurnToNextScene>"] = "leaveTime",
  ["ChapterSelector.<TurnToNextScene>"] = "_leaveTime",
  ["ProgressControl.<TurnToNextScene>"] = "_leaveTime",
  ["ChallengeSongSelectorControl.<TurnToNextScene>"] = "leaveTime",
  ["ChallengeModeOverControl.<TurnToNextScene>"] = "leaveTime",
  ["Chapter9FakeChallengeSongSelector.<TurnToNextScene>"] = "leaveTime",
  ["RrharilEventLevelStart001Control.<TurnToNextScene>"] = "_leaveTime",
  ["Loading.<LoadOver>"] = "_leaveTime",
}
for coroutine, field in pairs(LEAVE) do
  -- owners may sit in a namespace, %f[%w] keeps SongSelector from matching FakeChallengeSongSelector
  hook(il2cpp.find("%f[%w]" .. coroutine:gsub("%.", "%%."))[1], "MoveNext", {
    before = function(self) if enabled() then self["<>4__this"][field] = 1 end end,
  })
end

-- once the scene is ready the loading screen holds until time reaches 1 s
hook(CS.Loading, "OnGUI", {
  after = function(self)
    if enabled() and self.time > 0 and self.time < 1 then self.startTime = self.startTime - 1 end
  end,
})
