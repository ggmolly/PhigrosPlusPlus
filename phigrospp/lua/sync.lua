-- phigros.tools: turning sync on makes the player's key and registers it under their Phigros name, which the server
-- gives a number (name#0042), then shows the 16 words that bring the key back to another device. while it's on, the
-- profile follows the game's, and with the player's toggles a play that beats or ties the chart's record sends its
-- replay and the whole save goes after each song. what the server didn't get waits (replays in phigros++/outbox, their
-- paths one per line) and goes again at every scene change

local UE, IO = CS.UnityEngine, CS.System.IO
local OUTBOX, PROFILE, SAVE = phigrospp.root .. "/outbox", phigrospp.root .. "/profile.lua", phigrospp.root .. "/save/"
local PLAYS = phigrospp.root .. "/plays" -- finished songs not sent yet, one json object per line
local TAB = "Profile" -- the game's Profile page, under its cloud save login
local identity, json, ui = phigrospp.identity, phigrospp.json, phigrospp.ui

local sync = setting("Sync to phigros.tools", false, TAB)
local uploadSave, uploadReplays, uploadPlays, mobileData, details, unlisted -- the player's toggles, made with the tab's rows
local chunk = loadfile(PROFILE, "t", {})
-- { id =, name =, number = (as the server has them), intro = the self-introduction the game last showed, sent = { name =,
-- intro =, avatar =, background =, unlisted = } as they were when last sent }
local profile = chunk and chunk()
local name, intro -- what the game shows, seen each time it reads them
-- the self-introduction of a player who never wrote one (GameInformation.GetSelfIntro), sent as none
local PLACEHOLDER = "There is a self-introduction, write something just like:\r\nTwitter: @Phigros_PGS\r\n"
    .. "YouTube: Pigeon Games\r\n\r\nHope you have fun in Phigros.\r\nBest regards,\r\nPigeon Games"
local outbox, sending = {}, {}
local plays, sendingPlays, started = {}, false, 0 -- the summaries waiting, and when the song being played started
local saveChanged -- a song ended since the save was last sent

-- sync is only on once signed up: a sign up the game closed during is off again
if sync() and not profile then sync(false) end

local waiting = io.open(PLAYS, "rb")
if waiting then
  for line in waiting:read("a"):gmatch("[^\n]+") do plays[#plays + 1] = line end
  waiting:close()
end

local found = io.open(OUTBOX, "rb")
if found then
  for path in found:read("a"):gmatch("[^\n]+") do outbox[path] = true end
  found:close()
end

local function tag() return ("%s#%04d"):format(profile.name, profile.number) end

-- the player's name#number on phigros.tools, nil before they have a profile
function phigrospp.tag() return profile and tag() end
local function link() return ("%s/players/%s"):format(phigrospp.site, profile.id) end

local FIELDS = { "name", "intro", "avatar", "background", "unlisted" }

local function saveProfile(p, sent)
  local known = intro or profile and profile.intro or ""
  profile = { id = p.id, name = p.name, number = math.tointeger(p.number), intro = known, sent = sent }
  local fields = {}
  for _, field in ipairs(FIELDS) do fields[#fields + 1] = ("%s = %q"):format(field, sent[field]) end
  phigrospp.write(PROFILE, ("return { id = %q, name = %q, number = %d, intro = %q, sent = { %s } }\n"):format(
    profile.id, profile.name, profile.number, known, table.concat(fields, ", ")))
end

-- the profile as it goes to phigros.tools now: the name and intro as last sent until the game reads them, the details
-- empty when the player keeps them to themselves
local function current()
  local look, shared = appearance(), details()
  return { name = name or profile and profile.sent.name, unlisted = unlisted(),
    intro = shared and (intro or profile and profile.intro) or "",
    avatar = shared and look.avatar or "", background = shared and look.background or "" }
end

-- a signed request from inside a coroutine, waiting for its answer
local function call(method, path, body)
  local co = coroutine.running()
  phigrospp.signed(method, path, body, function(status, response) assert(coroutine.resume(co, status, response)) end)
  return coroutine.yield()
end

-- the words in a grid of four columns. signingUp asks to confirm they're saved, with a way out
local function showPhrase(signingUp)
  return ui.confirm({
    title = "Your phigros.tools password",
    message = "These 16 words are the password to your phigros.tools profile. Write them down in this order or take "
        .. "a photo of this screen, and keep them private: you need them to use your profile on another device, and "
        .. "nobody can recover them for you.",
    grid = { cells = identity.words(), columns = 4 },
    yes = signingUp and "I saved them" or "Close",
    no = signingUp and "Cancel" or false,
  })
end

-- why the server refused, for the player, and whether choosing another name fixes it
local function why(status, body)
  local code = json.decode(body).code
  if code == "no-name" then
    return "Choose a name first", "phigros.tools shows the name you have in Phigros. Tap Edit on your profile to "
        .. "choose one, and sync turns on once you save it.", true
  elseif code == "name-full" then
    return "This name is taken", ("Every number for %s is already used on phigros.tools. Tap Edit on your profile "
        .. "to choose another name, and sync turns on once you save it."):format(name), true
  end
  return "Couldn't reach phigros.tools", ("Check your connection, then turn sync on again (%d)."):format(status)
end

local PROFILE_TAB = 1 -- the game's settings tabs are Gameplay, Profile and Misc.
local choosing -- the name refused, while waiting on the profile tab for the player to save another one
local forceSync -- sends everything, defined with its button below

-- signing up: a new key's words come first, and only once the player saved them is it registered under the game's
-- name and written to the device. cancelling drops it. a refused sign up keeps it in memory, so a retry shows the
-- same words, and a refused name opens the profile tab to pick another
local function join()
  -- the game may not have read them since loading, the settings screen's profile tab shows them
  local stats = UE.Object.FindObjectOfType(CS.StatsFrameController)
  name = name or stats.playerName.text
  intro = intro or (stats.selfIntro.text == PLACEHOLDER and "" or stats.selfIntro.text)
  local first, now = not profile, current()
  local sent = now.name
  if first and sent and sent ~= "GUEST" then
    if not identity.public() then identity.create() end
    if not showPhrase(true) then
      identity.forget()
      return sync(false)
    end
  end
  local status, body = 400, '{"code":"no-name"}'
  if sent and sent ~= "GUEST" then
    status, body = call("PUT", "/api/profile", json.encode(now))
  end
  if status == 200 then
    if first then identity.save() end
    sync(true)
    saveProfile(json.decode(body), now)
    return forceSync()
  end
  sync(false)
  local title, message, naming = why(status, body)
  if ui.confirm({ title = title, message = message, yes = naming and "Choose a name" or "OK", no = naming and "Cancel" or false })
      and naming then
    choosing = sent or "GUEST"
    UE.Object.FindObjectOfType(CS.Setting):ChangeTab(PROFILE_TAB)
  end
end

-- sync turned on signs up, a changed toggle may change what phigros.tools has (update is defined below)
local update

on("setting", function(label, value)
  if label == "Sync to phigros.tools" and value then return coroutine.wrap(join)() end
  update()
end)

-- leaving the settings screen stops waiting for a name
on("scene", function() choosing = nil end)

-- a profile changed in the game goes to phigros.tools. a refused name isn't sent again until the next rename, the
-- rest goes with the name the server has
local updating

function update()
  if not sync() or not profile or updating then return end
  local now, sent = current(), profile.sent
  local changed = false
  for _, field in ipairs(FIELDS) do changed = changed or now[field] ~= sent[field] end
  if not changed then return end
  updating = true
  coroutine.wrap(function()
    local renamed = now.name ~= sent.name
    local status, body = call("PUT", "/api/profile", json.encode({ name = renamed and now.name or profile.name,
      intro = now.intro, avatar = now.avatar, background = now.background, unlisted = now.unlisted }))
    updating = false
    if status == 200 then
      local before = tag()
      saveProfile(json.decode(body), now)
      if tag() ~= before then toast("phigros.tools: you're now " .. tag()) end
      update() -- what changed while this was sent
    elseif status ~= 0 and renamed then
      toast(("phigros.tools: %s, you stay %s"):format((why(status, body)), tag()))
      sent.name = now.name
      update()
    end
  end)()
end

-- the game reads both each time it shows them, after an edit too
hook(CS.GameInformation, "GetUserName", {
  after = function(result)
    name = result
    if choosing and result ~= choosing and result ~= "GUEST" then
      choosing = nil
      return coroutine.wrap(join)()
    end
    update()
  end,
})

hook(CS.GameInformation, "GetSelfIntro", {
  after = function(result)
    intro = result == PLACEHOLDER and "" or result
    update()
  end,
})

local function saveOutbox()
  local lines = {}
  for path in pairs(outbox) do lines[#lines + 1] = path end
  table.sort(lines)
  phigrospp.write(OUTBOX, table.concat(lines, "\n"))
end

-- uploads wait for wi-fi unless the player lets them use mobile data
local function canUpload()
  return sync() and profile ~= nil and (mobileData() or UE.Application.internetReachability ~= 1) -- carrier data
end

-- the save as the game's cloud save makes it (CloudSaveManager.SaveToFolder: each module read from the game and
-- written encrypted to its own file), sent as the files one after the other. it holds the intro, avatar and
-- background and anyone can download it, so it only goes while the player shares those
local function sendSave()
  if not uploadSave() or not details() or not canUpload() then return end
  saveChanged = false
  IO.Directory.CreateDirectory(SAVE)
  CS.CloudSaveManager.SaveToFolder(SAVE)
  local parts = {}
  for _, module in ipairs({ "gameKey", "gameProgress", "gameRecord", "settings", "user" }) do
    parts[#parts + 1] = string.pack("<s1s4", module, phigrospp.read(SAVE .. module))
  end
  phigrospp.signed("PUT", "/api/save", table.concat(parts), function(status, body)
    if status ~= 200 then
      saveChanged = true
      print(("sync: the save waits, server answered %d %s"):format(status, body))
    end
  end)
end

local function savePlays() phigrospp.write(PLAYS, table.concat(plays, "\n")) end

-- the finished songs waiting go together, as many as the server takes at once, then the next ones
local MAX_PLAYS = 500

local function sendPlays()
  if #plays == 0 or sendingPlays or not uploadPlays() or not canUpload() then return end
  sendingPlays = true
  local sent = math.min(#plays, MAX_PLAYS)
  phigrospp.signed("POST", "/api/plays", table.concat(plays, "\n", 1, sent), function(status, body)
    sendingPlays = false
    if status == 0 or status >= 500 then return print(("sync: %d plays wait, server answered %d"):format(sent, status)) end
    if status >= 300 then print(("sync: %d plays refused, %d %s"):format(sent, status, body)) end
    plays = table.pack(table.unpack(plays, sent + 1))
    plays.n = nil
    savePlays()
    sendPlays()
  end)
end

-- a refused replay is dropped, it would be refused again. one the player deleted is too
local function flush()
  if saveChanged then sendSave() end
  sendPlays()
  if not uploadReplays() or not canUpload() then return end
  for path in pairs(outbox) do
    if not IO.File.Exists(path) then
      outbox[path] = nil
      saveOutbox()
    elseif not sending[path] then
      sending[path] = true
      phigrospp.signed("POST", "/api/replays", phigrospp.replayfile.sign(phigrospp.read(path)), function(status, body)
        sending[path] = nil
        if status == 0 or status >= 500 then return print(("sync: %s waits, server answered %d"):format(path, status)) end
        if status >= 300 then print(("sync: %s refused, %d %s"):format(path, status, body)) end
        outbox[path] = nil
        saveOutbox()
      end)
    end
  end
end

on("best", function(path)
  if not sync() or not profile or not uploadReplays() then return end
  outbox[path] = true
  saveOutbox()
  flush()
end)

on("song", function() started = now() end)

-- a song played to its end: the save changes (records, progress) and goes at the next scene change, and a summary of
-- the play joins the ones waiting, for the player's stats on phigros.tools
on("finish", function(result)
  if replaying() then return end
  saveChanged = true
  if not sync() or not profile or not uploadPlays() then return end
  local chart = playing()
  plays[#plays + 1] = json.encode({ song = chart.id, level = chart.difficulty, score = result.score,
    accuracy = result.accuracy, maxcombo = result.maxcombo, perfect = result.perfect, good = result.good,
    bad = result.bad, miss = result.miss, duration = now() - started, date = os.time() })
  savePlays()
end)

on("scene", flush)

-- the first scene of a launch tells phigros.tools the player is online, even with nothing to send, and gets back the
-- profile as the server has it (a number changed there shows here)
local greeted
on("scene", function()
  if greeted or not sync() or not profile then return end
  greeted = true
  phigrospp.signed("POST", "/api/me", "", function(status, body)
    if status == 200 then saveProfile(json.decode(body), profile.sent) end
  end)
end)

-- a profile made on another device, from its 16 words: the key is checked with the server before it's kept, and replaces the
-- one this device had
local function restore()
  if profile and not ui.confirm({ title = "Replace " .. tag() .. "?", danger = true, yes = "Continue",
        message = ("This device is %s on phigros.tools. Restoring another profile replaces it here, keep its "
          .. "recovery phrase to come back to it."):format(tag()) }) then
    return
  end
  local ok, typed = ui.confirm({ title = "Restore your phigros.tools profile", yes = "Restore", input = "16 words",
    message = "Type the 16 words of your recovery phrase, in order, with spaces between them." })
  if not ok then return end
  local entropy, problem = identity.fromWords(typed)
  if not entropy then
    return ui.confirm({ title = "These aren't your 16 words", message = ("Check the phrase and try again: %s.")
      :format(problem), yes = "OK", no = false })
  end
  local previous = identity.entropy()
  identity.load(entropy)
  local status, body = call("POST", "/api/me", "")
  if status ~= 200 then
    if previous then identity.load(previous) else identity.forget() end
    return ui.confirm({ yes = "OK", no = false, title = status == 404 and "No profile has these words"
      or "Couldn't reach phigros.tools", message = status == 404 and "They are recovery words, but no "
      .. "phigros.tools profile was made with them. Check each word and their order." or
      ("Check your connection and try again (%d)."):format(status) })
  end
  identity.save()
  -- nothing counts as sent, so this device's profile goes to phigros.tools as the game shows it
  saveProfile(json.decode(body), { name = "", intro = "", avatar = "", background = "", unlisted = false })
  sync(true)
  toast("Welcome back, " .. tag())
  forceSync()
end

-- the tab holds the sync toggle and restoring, and the profile's rows once there's one
local function joined() return sync() and profile ~= nil end


-- a copy of the profile's Edit button, left of it, sharing the profile's link, and the number after the profile's
-- name, small and lowered like an index
local share, number

-- the number follows where the name was drawn: the game fits the name to its box, so it's placed from the drawn
-- glyphs (the end of the last one, the line's height and baseline), in the name's own units
local function placeNumber(label)
  local drawn, ppu = label.cachedTextGenerator, label.pixelsPerUnit
  local chars = drawn.characters
  if chars._size == 0 then return end -- drawn on the next frame
  local line = drawn.lines._items[0]
  local height = line.height / ppu
  local baseline = line.topY / ppu - height * 0.78
  number.fontSize = math.floor(height * 0.38)
  number.text = ("#%04d"):format(profile.number)
  number.transform.anchoredPosition = { chars._items[chars._size - 1].cursorPos.x / ppu + height * 0.08, baseline }
end

-- the profile's frame, kept from its Start (or found once when mods load while it's open): looking for it every
-- frame would cost during songs too
local frame
hook(CS.StatsFrameController, "Start", { after = function(self) frame = self end })
on("load", function() frame = UE.Object.FindObjectOfType(CS.StatsFrameController) end)

on("update", function()
  if not il2cpp.alive(frame) then frame = nil end
  local stats = joined() and frame and frame.isActiveAndEnabled and frame
  if stats and not il2cpp.alive(number) then
    local label = stats.playerName.textComponent
    number = ui.text(label.transform, "phigrospp:number", label.font, { 0, 0 }, { 400, 60 }, 1, 6, { 0, 0 }) -- LowerLeft
    number.transform.anchorMin, number.transform.anchorMax = { 0.5, 0.5 }, { 0.5, 0.5 }
    number.color = { 1, 1, 1, 0.6 }
  end
  if stats then
    placeNumber(stats.playerName.textComponent)
  elseif il2cpp.alive(number) then
    UE.Object.Destroy(number.gameObject)
  end
  if stats and not il2cpp.alive(share) then
    local original = stats.editButton.transform
    share = UE.Object.Instantiate(original.gameObject, original.parent, false)
    share.name = "phigrospp:share"
    local t = share.transform
    t.anchoredPosition = { original.anchoredPosition.x - original.rect.m_Width - 30, original.anchoredPosition.y }
    local label = share:GetComponentInChildren(UE.UI.Text)
    label.text = "Share"
    local button = share:GetComponent(UE.UI.Button)
    button.onClick = UE.UI.Button.ButtonClickedEvent()
    phigrospp.click(button, function() phigrospp.share(link()) end)
  elseif not joined() and il2cpp.alive(share) then
    UE.Object.Destroy(share)
  end
end)
uploadSave = setting("Upload my save", false, TAB, function() return joined() and details() end)
uploadReplays = setting("Upload replays", true, TAB, joined)
uploadPlays = setting("Upload play stats", true, TAB, joined)
-- only on a device with a mobile network, a tablet on wi-fi has nothing to choose
local cellular = phigrospp.feature("android.hardware.telephony")
mobileData = setting("Upload over mobile data", true, TAB, function() return joined() and cellular end)
details = setting("Share my intro, avatar and background", true, TAB, joined)
unlisted = setting("Unlisted profile", false, TAB, joined)

-- turned on, the save goes right away
on("setting", function(label, value)
  if label == "Upload my save" and value then sendSave() end
end)
-- everything at once: the profile as the game has it, every record as the game says them (the site marks them
-- imported, only replays prove a score, so a kept replay of the exact score goes along and stands in for its record),
-- the save if the player uploads it, and what waits in the outbox. it runs once signed up or restored too
local forcing

function forceSync()
  if forcing then return end
  forcing = true
  -- the rest counts as never sent, so update sends it all (a name not renamed goes as the server has it)
  for _, field in ipairs(FIELDS) do
    if field ~= "name" then profile.sent[field] = nil end
  end
  update()
  local lines, replays = {}, 0
  for _, r in ipairs(records()) do
    lines[#lines + 1] = ("%s\t%s\t%d\t%.4f\t%d"):format(r.id, r.difficulty, r.score, r.accuracy, r.fc and 1 or 0)
    for _, replay in ipairs(uploadReplays() and phigrospp.replay.list(r.id, r.difficulty) or {}) do
      if replay.header.score == r.score then
        outbox[replay.path], replays = true, replays + 1
      end
    end
  end
  local status, body = call("PUT", "/api/records", table.concat(lines, "\n"))
  forcing = false
  if status ~= 200 then return toast(("Couldn't sync with phigros.tools (%d)"):format(status)) end
  local function count(n, thing) return ("%d %s%s"):format(n, thing, n == 1 and "" or "s") end
  toast(("Synced %s and %s with phigros.tools"):format(count(math.tointeger(json.decode(body).count), "record"),
    count(replays, "replay")))
  saveOutbox()
  saveChanged = true
  flush()
end

button("Force sync", forceSync, TAB, joined)
button("Show recovery phrase", function() showPhrase(false) end, TAB, joined)
button("Restore a profile", restore, TAB)
