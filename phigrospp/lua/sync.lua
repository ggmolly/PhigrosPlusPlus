-- phigros.tools: turning sync on makes the player's key and registers it under their Phigros name, which the server
-- gives a number (name#0042), then shows the 16 words that bring the key back to another device. while it's on, the
-- profile follows the game's, and with the player's toggles a play that beats or ties the chart's record sends its
-- replay and the whole save goes after each song. what the server didn't get waits (replays in phigros++/outbox, their
-- paths one per line) and goes again at every scene change

local UE, IO = CS.UnityEngine, CS.System.IO
local OUTBOX, PROFILE, SAVE = phigrospp.root .. "/outbox", phigrospp.root .. "/profile.lua", phigrospp.root .. "/save/"
local PENDING = phigrospp.root .. "/save-pending" -- while it exists, the save changed since it was last sent
local PLAYS = phigrospp.root .. "/plays" -- finished songs not sent yet, one json object per line
local TAB = "Profile" -- the game's Profile page, under its cloud save login
local identity, json, ui = phigrospp.identity, phigrospp.json, phigrospp.ui

local sync = setting("Sync to phigros.tools", false, TAB)
local uploadSave, uploadReplays, uploadPlays, mobileData, unlisted -- the player's toggles, made with the tab's rows
local chunk = loadfile(PROFILE, "t", {})
-- { id =, name =, number = (as the server has them), intro = the self-introduction the game last showed, linked = this
-- device joined with a code (its key isn't the recovery phrase's), sent = { name =, intro =, avatar =, background =,
-- unlisted = } as they were when last sent }
local profile = chunk and chunk()
local name, intro -- what the game shows, seen each time it reads them
-- the self-introduction of a player who never wrote one (GameInformation.GetSelfIntro), sent as none
local PLACEHOLDER = "There is a self-introduction, write something just like:\r\nTwitter: @Phigros_PGS\r\n"
    .. "YouTube: Pigeon Games\r\n\r\nHope you have fun in Phigros.\r\nBest regards,\r\nPigeon Games"
local outbox, sending = {}, {}
local plays, sendingPlays, started = {}, false, 0 -- the summaries waiting, and when the song being played started
local saveChanged = IO.File.Exists(PENDING) -- a song ended since the save was last sent, after a restart too

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

-- linked comes from /api/me (its phrase) or stays as it was
local function saveProfile(p, sent, linked)
  local known = intro or profile and profile.intro or ""
  if linked == nil then linked = profile and profile.linked or false end
  profile = { id = p.id, name = p.name, number = math.tointeger(p.number), intro = known, linked = linked, sent = sent }
  local fields = {}
  for _, field in ipairs(FIELDS) do fields[#fields + 1] = ("%s = %q"):format(field, sent[field]) end
  phigrospp.write(PROFILE, ("return { id = %q, name = %q, number = %d, intro = %q, linked = %s, sent = { %s } }\n")
    :format(profile.id, profile.name, profile.number, known, linked, table.concat(fields, ", ")))
end

-- the profile as it goes to phigros.tools now: the name and intro as last sent until the game reads them
local function current()
  local look = appearance()
  return { name = name or profile and profile.sent.name, unlisted = unlisted(),
    intro = intro or profile and profile.intro or "", avatar = look.avatar, background = look.background }
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
    return "Choose a name", "phigros.tools shows the name you have in Phigros. Choose one, Phigros shows it too.", true
  elseif code == "name-full" then
    return "This name is taken", ("Every number for %s is already used on phigros.tools. Choose another name, "
        .. "Phigros shows it too."):format(name), true
  end
  return "Couldn't reach phigros.tools", ("Check your connection, then turn sync on again (%d)."):format(status)
end

-- the game's name is kept outside the save (playerID), so a fresh install stays GUEST whatever save it loads: this
-- sets it as renaming on the profile tab does
local function rename(new)
  CS.GameInformation.SetUserName(new)
  name = new
end

local function askName(title, message)
  local ok, typed = ui.confirm({ title = title, message = message, input = "Name", yes = "Save", no = "Cancel" })
  typed = ok and typed:match("^%s*(.-)%s*$")
  if not typed or typed == "" or typed == "GUEST" then return false end
  rename(typed)
  return true
end

local forceSync -- sends everything, defined with its button below

-- signing up: a guest chooses a name first, then a new key's words come, and only once the player saved them is it
-- registered under the game's name and written to the device. cancelling drops it. a refused sign up keeps it in
-- memory, so a retry shows the same words, and a refused name asks for another
local function join()
  -- the game may not have read them since loading, the settings screen's profile tab shows them
  local stats = UE.Object.FindObjectOfType(CS.StatsFrameController)
  name = name or stats.playerName.text
  intro = intro or (stats.selfIntro.text == PLACEHOLDER and "" or stats.selfIntro.text)
  if name == "GUEST" and not askName(why(400, '{"code":"no-name"}')) then return sync(false) end
  local first = not profile
  if first then
    if not identity.public() then identity.create() end
    if not showPhrase(true) then
      identity.forget()
      return sync(false)
    end
  end
  while true do
    local now = current()
    local status, body = call("PUT", "/api/profile", json.encode(now))
    if status == 200 then
      if first then identity.save() end
      sync(true)
      saveProfile(json.decode(body), now)
      return forceSync()
    end
    local title, message, naming = why(status, body)
    if not naming then
      sync(false)
      return ui.confirm({ title = title, message = message, yes = "OK", no = false })
    end
    if not askName(title, message) then return sync(false) end
  end
end

-- sync turned on signs up, a changed toggle may change what phigros.tools has (update is defined below)
local update

on("setting", function(label, value)
  if label == "Sync to phigros.tools" and value then return coroutine.wrap(join)() end
  update()
end)

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

local MODULES = { "gameKey", "gameProgress", "gameRecord", "settings", "user" }
-- while this file exists, a restored profile's save on phigros.tools waits for the player to load it or keep this
-- device's, and this device's isn't uploaded: a fresh install never replaces it
local OFFER = phigrospp.root .. "/save-offer"

local function changeSave()
  saveChanged = true
  phigrospp.write(PENDING, "")
end

-- the save as the game's cloud save makes it (CloudSaveManager.SaveToFolder: each module read from the game and
-- written encrypted to its own file) and the game's summary of it, sent as the files one after the other
local function sendSave()
  if not uploadSave() or IO.File.Exists(OFFER) or not canUpload() then return end
  saveChanged = false
  IO.Directory.CreateDirectory(SAVE)
  CS.CloudSaveManager.SaveToFolder(SAVE)
  local parts = { string.pack("<s1s4", "summary", CS.CloudSaveSummary.FromLocalSave():Serialize()) }
  for _, module in ipairs(MODULES) do
    parts[#parts + 1] = string.pack("<s1s4", module, phigrospp.read(SAVE .. module))
  end
  phigrospp.signed("PUT", "/api/save", table.concat(parts), function(status, body)
    if status ~= 200 then
      saveChanged = true
      return print(("sync: the save waits, server answered %d %s"):format(status, body))
    end
    if not saveChanged then os.remove(PENDING) end
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

-- the device's records go to phigros.tools, which keeps the player's best of each chart whatever save comes after, and
-- the bests there that beat them (played on another device or a lost install) come back into the save, each of score,
-- accuracy and FC at its best like the game keeps them. the site names songs without the game's ".0", and a song this
-- game version lacks is skipped. returns the status and how many records were sent
local function exchangeRecords(list)
  local lines, mine = {}, {}
  for _, r in ipairs(list) do
    mine[r.id .. "\t" .. r.difficulty] = r
    lines[#lines + 1] = ("%s\t%s\t%d\t%.4f\t%d"):format(r.id, r.difficulty, r.score, r.accuracy, r.fc and 1 or 0)
  end
  local status, body = call("PUT", "/api/records", table.concat(lines, "\n"))
  if status ~= 200 then return status end
  local answer, ids, taken = json.decode(body), {}, false
  for _, s in ipairs(songs()) do ids[(s.id:gsub("%.0$", ""))] = s.id end
  for _, best in ipairs(answer.better) do
    local id = ids[best.song]
    if id then
      local had = mine[id .. "\t" .. best.level] or { score = 0, accuracy = 0, fc = false }
      local record = CS.LevelRecord()
      record.s = math.max(had.score, math.tointeger(best.score))
      record.a = math.max(had.accuracy, best.accuracy)
      record.c = (had.fc or best.fc == 1) and 1 or 0
      CS.GameInformation.main:SetSongRecord(id, best.level, record)
      taken = true
    end
  end
  if taken then changeSave() end
  return status, math.tointeger(answer.count)
end

on("best", function(path)
  if not sync() or not profile or not uploadReplays() then return end
  outbox[path] = true
  saveOutbox()
  flush()
end)

local function start() started = now() end
on("song", start)
on("restart", start)

-- a song played to its end: the save changes (records, progress) and goes at the next scene change, and a summary of
-- the play joins the ones waiting, for the player's stats on phigros.tools. with modifiers the save stays as it was
on("finish", function(result)
  if not phigrospp.counts() or phigrospp.charts.custom(playing().id) then return end
  local mods = phigrospp.modifiers.play()
  if mods == 0 then changeSave() end
  if not sync() or not profile or not uploadPlays() then return end
  local chart = playing()
  plays[#plays + 1] = json.encode({ song = chart.id, level = chart.difficulty, score = result.score,
    accuracy = result.accuracy, maxcombo = result.maxcombo, perfect = result.perfect, good = result.good,
    bad = result.bad, miss = result.miss, duration = now() - started, date = os.time(), mods = mods })
  savePlays()
end)

on("scene", flush)

-- the profile is gone from this device: a device removed on phigros.tools keeps nothing of it
local function leave()
  identity.forget()
  os.remove(PROFILE)
  profile = nil
  sync(false)
end

-- the first scene of a launch tells phigros.tools the player is online, even with nothing to send, and gets back the
-- profile as the server has it (a number changed there shows here), and whether a save sent from the site waits
local greeted, siteOffer
on("scene", function()
  if greeted or not sync() or not profile then return end
  greeted = true
  phigrospp.signed("POST", "/api/me", "", function(status, body)
    if status == 403 and json.decode(body).code == "removed" then
      leave()
      return toast("This device was removed from your phigros.tools profile")
    end
    if status ~= 200 then return end
    local me = json.decode(body)
    saveProfile(me, profile.sent, me.phrase == false)
    siteOffer = me.offer ~= nil
  end)
end)

local function describe(summary)
  local cleared = 0
  for i = 0, #summary.Cleared - 1 do cleared = cleared + summary.Cleared[i] end
  return ("RKS %.2f, %d charts cleared"):format(summary.RankingScore, cleared)
end

-- the save the player uploaded from another device, offered once their profile is restored, or (fromSite) the one they
-- sent from phigros.tools. loading it replaces this device's, so the player sees what goes before choosing. returns
-- whether it was loaded (the game then closes)
local function offerSave(fromSite)
  local status, body = call("POST", fromSite and "/api/offer" or "/api/save", "")
  if status == 0 or status >= 500 then return false end -- asked again at the next launch
  if status ~= 200 then
    if not fromSite then IO.File.Delete(OFFER) end
    return false
  end
  local files, at = {}, 1
  while at <= #body do
    local file, data
    file, data, at = string.unpack("<s1s4", body, at)
    files[file] = data
  end
  local here = CS.CloudSaveSummary.FromLocalSave()
  local there = files.summary and CS.CloudSaveSummary.Deserialize(files.summary)
  local incoming = ("the save you %s on %s"):format(fromSite and "sent from phigros.tools" or "uploaded",
    os.date("%Y-%m-%d", math.tointeger(tonumber(files.updated)) // 1000))
    .. (there and (" (%s)"):format(describe(there)) or "")
  -- declining the save of the profile lets this device's replace it there, declining one sent from the site drops it
  local declined = fromSite and "Keeping this device's drops it." or "Keeping this device's replaces the one on "
    .. "phigros.tools instead."
  local fresh = here.RankingScore == 0
  local load = ui.confirm(fresh and {
    title = "Bring your save over?", yes = "Bring it over", no = fromSite and "No" or "Not now",
    message = ("phigros.tools has %s. %s"):format(incoming, declined),
  } or {
    title = "Replace the save on this device?", danger = true, yes = "Replace my save", no = "Keep this one",
    message = ("This device's save (%s) is replaced by %s, records, unlocks and settings included. %s")
      :format(describe(here), incoming, declined),
  })
  if fromSite then call("DELETE", "/api/offer", "") else IO.File.Delete(OFFER) end
  if not load then return false end
  IO.Directory.CreateDirectory(SAVE)
  for _, module in ipairs(MODULES) do phigrospp.write(SAVE .. module, files[module]) end
  CS.CloudSaveManager.LoadFromFolder(SAVE, true, (there or here).SaveVersion)
  rename(profile.name)
  UE.PlayerPrefs.Save()
  ui.confirm({ title = "Save loaded", message = "Phigros++ closes to finish loading it, open it again.", yes = "OK",
    no = false })
  UE.Application.Quit()
  return true
end

-- an offer the player didn't answer (the game closed, or phigros.tools was out of reach) comes back on the chapter
-- screen. without one, the first time there each launch takes back the player's bests phigros.tools has
local offering, exchanged
on("scene", function(scene)
  if offering or scene ~= "ChapterSelector" or not sync() or not profile then return end
  local restored = IO.File.Exists(OFFER)
  if not restored and not siteOffer then
    if exchanged or not canUpload() then return end
    exchanged = true
    return coroutine.wrap(exchangeRecords)(records())
  end
  offering, siteOffer = true, false
  coroutine.wrap(function()
    if not offerSave(not restored) and restored then forceSync() end
    offering = false
  end)()
end)

-- the key just checked with the server is kept and its profile is this device's, then its uploaded save is offered
local function restored(body, linked)
  identity.save()
  -- nothing counts as sent, so this device's profile goes to phigros.tools as the game shows it
  saveProfile(json.decode(body), { name = "", intro = "", avatar = "", background = "", unlisted = false }, linked)
  if CS.GameInformation.GetUserName() == "GUEST" then rename(profile.name) end
  sync(true)
  toast("Welcome back, " .. tag())
  phigrospp.write(OFFER, "")
  offering = true
  if not offerSave() then forceSync() end
  offering = false
end

-- a profile made on another device, from the code a signed-in device shows (8 letters and digits: this device joins
-- with a key of its own, named after its model) or from the profile's 16 words. a refused one changes nothing
local function signIn()
  local ok, typed = ui.confirm({ title = "Sign in to my profile", yes = "Sign in", input = "Code or 16 words",
    message = "Type the code that Sign in another device shows, in Phigros++ or in Devices on phigros.tools, or the 16 "
      .. "words of your recovery phrase." })
  if not ok then return end
  local code = #typed:gsub("%W", "") == 8
  local entropy, problem
  if not code then
    entropy, problem = identity.fromWords(typed)
    if not entropy then
      return ui.confirm({ title = "These aren't your 16 words", message = ("Check the phrase and try again: %s.")
        :format(problem), yes = "OK", no = false })
    end
  end
  local previous = identity.entropy()
  local status, body
  if code then
    identity.create()
    status, body = call("PUT", "/api/devices", json.encode({ code = typed, name = UE.SystemInfo.deviceModel }))
  else
    identity.load(entropy)
    status, body = call("POST", "/api/me", "")
  end
  if status ~= 200 then
    if previous then identity.load(previous) else identity.forget() end
    local wrong = code and { "This code doesn't work", "It was already used or is older than 10 minutes. Ask for a new "
      .. "one." } or { "No profile has these words", "They are recovery words, but no phigros.tools profile was made "
      .. "with them. Check each word and their order." }
    return ui.confirm({ yes = "OK", no = false, title = status == 404 and wrong[1] or "Couldn't reach phigros.tools",
      message = status == 404 and wrong[2] or ("Check your connection and try again (%d)."):format(status) })
  end
  restored(body, code)
end

-- a code for another device to join this profile: a browser opens it right away, a phone types it
local function invite()
  local status, body = call("POST", "/api/invite", "")
  if status ~= 200 then return toast(("Couldn't reach phigros.tools (%d)"):format(status)) end
  local code = json.decode(body).code
  if ui.confirm({ title = "Sign in another device", yes = "Open in browser", no = "Done",
        message = "Type this code on phigros.tools, or in Sign in to my profile on another device. It works once, for 10 "
          .. "minutes.",
        grid = { cells = { code:sub(1, 4) .. "  " .. code:sub(5) }, columns = 1 } }) then
    UE.Application.OpenURL(("%s/in#%s"):format(phigrospp.site, code))
  end
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
uploadSave = setting("Upload my save", true, TAB, joined)
uploadReplays = setting("Upload replays", true, TAB, joined)
uploadPlays = setting("Upload play stats", true, TAB, joined)
-- only on a device with a mobile network, a tablet on wi-fi has nothing to choose
local cellular = phigrospp.platform == "ios" or phigrospp.feature("android.hardware.telephony")
mobileData = setting("Upload over mobile data", true, TAB, function() return joined() and cellular end)
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
  local list, replays = records(), 0
  for _, r in ipairs(list) do
    local kept = uploadReplays() and phigrospp.replay.list(r.id, r.difficulty) or {}
    for _, replay in ipairs(kept) do
      if replay.header.mods == 0 and replay.header.score == r.score then
        outbox[replay.path], replays = true, replays + 1
      end
    end
    -- the chart's best with each set of modifiers goes along, those are no records of the save's
    for _, modded in pairs(phigrospp.replay.bests(kept)) do outbox[modded.path], replays = true, replays + 1 end
  end
  local status, sent = exchangeRecords(list)
  forcing = false
  if status ~= 200 then return toast(("Couldn't sync with phigros.tools (%d)"):format(status)) end
  local function count(n, thing) return ("%d %s%s"):format(n, thing, n == 1 and "" or "s") end
  toast(("Synced %s and %s with phigros.tools"):format(count(sent, "record"), count(replays, "replay")))
  saveOutbox()
  changeSave()
  flush()
end

button("Force sync", forceSync, TAB, joined)
button("Sign in another device", invite, TAB, joined)
-- a device that joined with a code has its own key, not the profile's: its words wouldn't be the recovery phrase
button("Show recovery phrase", function() showPhrase(false) end, TAB, function() return joined() and not profile.linked end)
-- leaving forgets the key on this device: a device that joined with a code is removed from the profile too, the
-- profile's own key comes back only with its words
local function signOut()
  if not ui.confirm({ title = "Sign out of " .. tag() .. "?", danger = true, yes = "Sign out",
        message = profile.linked and "This device stops syncing and leaves your profile. Sign in again with a code "
          .. "from another device." or "This device stops syncing. Signing in again needs your 16 words, so make "
          .. "sure you saved them." }) then
    return
  end
  if profile.linked then
    call("DELETE", "/api/devices", (identity.public():gsub(".", function(c) return ("%02x"):format(c:byte()) end)))
  end
  leave()
  toast("Signed out of phigros.tools")
end
button("Sign out", signOut, TAB, joined, true)
button("Sign in to my profile", signIn, TAB, function() return not profile end)
