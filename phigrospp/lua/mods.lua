-- mods installed from GitHub releases (the wiki's Publishing a mod page). each lives in installed/<owner>/<name>/, away
-- from mods/ so the files watcher never reloads halfway through an install. a release holds mod.zip (init.lua at its
-- root or in one folder) or mod.lua, and <asset>.sig when signed: the author's public key, then their signature of
-- the repo, the tag and the asset's sha-512

local IO, crypto = CS.System.IO, phigrospp.crypto
local DIR = phigrospp.root .. "/installed"
-- no owner on github has a dot in their name
local INDEX, REGISTRY, STAGING = DIR .. "/.index", DIR .. "/.registry", DIR .. "/.new"
local LISTING, LATEST = DIR .. "/.listing", DIR .. "/.latest"
local FRESH = 300 -- seconds phigros.tools' answer is kept for before it's asked again
-- signs the registry of the catalog's mods and their authors' keys (scripts/registry.sh), never the release key
local CATALOG_KEY = phigrospp.unhex("98a336735cc2490bd43ac42080c0e360e6dc8ab23c6a189cae9c5c0f97e6b5d1")
local REGISTRY_DOMAIN, MOD_DOMAIN = "phigros++ mods v1\0", "phigros++ mod v1\0" -- a signature is only good for one use
local ASSET_CAP, UNPACKED_CAP, FILES_CAP = 32 << 20, 64 << 20, 512

-- installed[repo] ("owner/name" in lowercase) = { repo =, version = its tag, file = "mod.zip" or "mod.lua", size = on
-- the device, key = the hex key its release was signed with, enabled =, error = why it didn't load }.
-- registry: what the catalog lists, listed[repo] and authors[owner] = their key.
-- catalog: what phigros.tools says of the registry's mods, in its order and by repo, nothing until it's known
local mods = { installed = {}, registry = { time = 0, authors = {}, listed = {} } }
phigrospp.mods = mods

IO.Directory.CreateDirectory(DIR)

-- the lines of one of our files, made empty the first time
local function stored(path)
  if not IO.File.Exists(path) then phigrospp.write(path, "") end
  return phigrospp.read(path):gmatch("[^\n]+")
end

for line in stored(INDEX) do
  local repo, version, file, size, key, enabled = line:match("^(%S+) (%S+) (%S+) (%d+) (%S+) (%d)$")
  mods.installed[repo] = { repo = repo, version = version, file = file, size = tonumber(size), key = key ~= "-" and key or nil,
    enabled = enabled == "1" }
end

-- the latest release github gave for a repo and when: { time =, release = }, kept in a file as a reload forgets
local asked = {}
for line in stored(LATEST) do
  local repo, time, version, file, size = line:match("^(%S+) (%d+) (%S+) (%S+) (%d+)$")
  asked[repo] = { time = tonumber(time), release = { repo = repo, version = version, file = file, size = tonumber(size) } }
end

-- where a mod's files are
function mods.folder(repo) return ("%s/%s/"):format(DIR, repo) end

local function save()
  local lines = {}
  for repo, m in pairs(mods.installed) do
    lines[#lines + 1] = ("%s %s %s %d %s %d\n"):format(repo, m.version, m.file, m.size, m.key or "-", m.enabled and 1 or 0)
  end
  table.sort(lines)
  phigrospp.write(INDEX, table.concat(lines))
  lines = {}
  for repo, a in pairs(asked) do
    lines[#lines + 1] = ("%s %d %s %s %d\n"):format(repo, a.time, a.release.version, a.release.file, a.release.size)
  end
  table.sort(lines)
  phigrospp.write(LATEST, table.concat(lines))
end

-- the owner/name a link, a raw file's url or "owner/name" itself names, as github allows them and in lowercase: what
-- the folder, the signature and the registry go by. nil for anything else
function mods.repo(text)
  local path = text:match("^%s*(.-)%s*$"):gsub("^%a+://[^/]*/", "")
  local owner, name = path:match("^([%w-]+)/([%w._-]+)$")
  if not owner then owner, name = path:match("^([%w-]+)/([%w._-]+)[/?#]") end
  name = name and name:gsub("%.git$", "")
  if not owner or name == "" or name == "." or name == ".." then return nil end
  return (owner .. "/" .. name):lower()
end

-- the registry ---------------------------------------------------------------------------------------------------

-- its first line is when it was published: an older one than the one known is a replay
local function accept(text, signature)
  if #signature ~= 64 or not crypto.verify(CATALOG_KEY, REGISTRY_DOMAIN .. text, signature) then
    return print("mods: the registry isn't signed by the catalog key")
  end
  local r = { time = tonumber(text:match("^time (%d+)\n")), authors = {}, listed = {} }
  if r.time < mods.registry.time then return print("mods: the registry is older than the one known") end
  for author, key in text:gmatch("\n([%w-]+):(%x+)") do r.authors[author] = phigrospp.unhex(key) end
  for repo in text:gmatch("\n([%w-]+/[%w._-]+)") do r.listed[repo] = true end
  mods.registry = r
  return true
end

-- phigros.tools' listing isn't trusted: only what it says of the registry's repos is kept
local function list(body)
  mods.catalog = {}
  for _, mod in ipairs(phigrospp.json.decode(body).mods) do
    if mods.registry.listed[mod.repo] then mods.catalog[#mods.catalog + 1], mods.catalog[mod.repo] = mod, mod end
  end
end

-- both are kept, so the catalog shows offline and after a reload. the listing's file starts with when it was asked
local checked = 0
if IO.File.Exists(REGISTRY) then accept(phigrospp.read(REGISTRY), phigrospp.read(REGISTRY .. ".sig")) end
if IO.File.Exists(LISTING) then
  local time, body = phigrospp.read(LISTING):match("^(%d+)\n(.*)$")
  checked = tonumber(time)
  list(body)
end

-- asks phigros.tools for the registry and its listing, unless it answered less than FRESH seconds ago. done() runs
-- later either way, catalog.failed says it couldn't be reached and nothing was known
function mods.refresh(done)
  if os.time() - checked < FRESH then return after(0, done) end
  local function failed()
    mods.catalog = mods.catalog or { failed = true }
    done()
  end
  phigrospp.request("GET", "/catalog/registry.txt", nil, function(status, text)
    if status ~= 200 then return failed() end
    phigrospp.request("GET", "/catalog/registry.txt.sig", nil, function(code, signature)
      if code == 200 and accept(text, signature) then
        phigrospp.write(REGISTRY, text)
        phigrospp.write(REGISTRY .. ".sig", signature)
      end
      phigrospp.request("GET", "/catalog/index.json", nil, function(answered, body)
        if answered ~= 200 then return failed() end
        checked = os.time()
        list(body)
        phigrospp.write(LISTING, ("%d\n%s"):format(checked, body))
        done()
      end)
    end)
  end)
end

-- installing -----------------------------------------------------------------------------------------------------

-- whether a release may be installed and the hex key it's signed with, or nil and why not. a mod of the catalog must
-- be signed by its author's key of the registry. another may be unsigned, but once it came signed it keeps that key
local function trusted(repo, tag, data, signed, pinned)
  local wanted = mods.registry.authors[repo:match("^[^/]+")] or pinned and phigrospp.unhex(pinned)
  if not signed then
    if mods.registry.listed[repo] or pinned then return nil, "this release isn't signed" end
    return true
  end
  local key = signed:sub(1, 32)
  if #signed ~= 96 or not crypto.verify(key, MOD_DOMAIN .. repo .. "\0" .. tag .. "\0" .. crypto.sha512(data), signed:sub(33)) then
    return nil, "this release's signature is wrong"
  end
  if wanted and key ~= wanted then return nil, "this release is signed by another key than its author's" end
  return true, phigrospp.hex(key)
end

-- the files of a zip as { path = data }. we write each one ourselves, so a path leaving the mod's folder is refused
-- here, and what's read is counted: a zip unpacking to more than the caps is refused whatever its headers say
local function unzip(data)
  local archive = IO.Compression.ZipArchive(IO.MemoryStream(il2cpp.bytes(data)), 0, false, nil) -- ZipArchiveMode.Read
  local entries, files, total = archive.Entries, {}, 0
  if entries.Count > FILES_CAP then error("it has too many files", 0) end
  local buffer = il2cpp.bytes(("\0"):rep(65536))
  for i = 0, entries.Count - 1 do
    local entry = entries:get_Item(i)
    local path = entry.FullName
    if path:sub(-1) ~= "/" then -- not a folder's own entry
      -- an empty, "." or ".." part (an absolute path starts with an empty one), a drive or a windows separator
      if path:find("[%c\\:]") or ("/" .. path .. "/"):find("/%.?%.?/") then error("it holds the unsafe path " .. path, 0) end
      local stream, parts = entry:Open(), {}
      repeat
        local n = stream:Read(buffer, 0, 65536)
        total = total + n
        if total > UNPACKED_CAP then error("it unpacks to too much", 0) end
        parts[#parts + 1] = il2cpp.unbytes(buffer):sub(1, n)
      until n == 0
      stream:Dispose()
      files[path] = table.concat(parts)
    end
  end
  archive:Dispose()
  return files
end

-- a release's files with init.lua at their root: a zip made of one folder holding everything loses that folder
local function unpack(file, data)
  if file == "mod.lua" then return { ["init.lua"] = data } end
  local files = unzip(data)
  if files["init.lua"] then return files end
  local top, inside = nil, {}
  for path, content in pairs(files) do
    local folder, rest = path:match("^([^/]+)/(.+)$")
    if not folder or top and folder ~= top then error("it has no init.lua at its root", 0) end
    top, inside[rest] = folder, content
  end
  if not inside["init.lua"] then error("it has no init.lua", 0) end
  return inside
end

-- the mod's folder is replaced whole: what a mod writes there is gone with its next release
local function write(repo, files)
  local dir, size = DIR .. "/" .. repo, 0
  if IO.Directory.Exists(STAGING) then IO.Directory.Delete(STAGING, true) end
  for path, data in pairs(files) do
    local file = STAGING .. "/" .. path
    IO.Directory.CreateDirectory(file:match("^(.*)/"))
    phigrospp.write(file, data)
    size = size + #data
  end
  if IO.Directory.Exists(dir) then IO.Directory.Delete(dir, true) end
  IO.Directory.CreateDirectory(dir:match("^(.*)/"))
  IO.Directory.Move(STAGING, dir)
  return size
end

-- installs a release, { repo =, version =, file =, size = } as the catalog or mods.latest gives it, then done(why) with
-- why it couldn't be. the mod runs after the next phigrospp.reload(). returns its job: progress() from 0 to 1, and to
-- give up, cancelled = true then request:Abort()
function mods.install(release, done)
  local repo, job = release.repo, {}
  local url = ("https://github.com/%s/releases/download/%s/%s"):format(repo, release.version, release.file)
  function job.progress() return job.data and 1 or job.request.downloadedBytes / release.size end
  local function finish(signed)
    local old = mods.installed[repo]
    local ok, key = trusted(repo, release.version, job.data, signed, old and old.key)
    if not ok then return done(key) end
    -- an archive is someone else's data: what's wrong with it is told to the player, not thrown
    local unpacked, size = pcall(function() return write(repo, unpack(release.file, job.data)) end)
    if not unpacked then return done(size) end
    mods.installed[repo] = { repo = repo, version = release.version, file = release.file, size = size, key = key,
      enabled = true }
    save()
    done()
  end
  job.request = phigrospp.fetch("GET", url, nil, function(status, data)
    if job.cancelled then return end
    if status ~= 200 then return done(("GitHub answered %d"):format(status)) end
    if #data > ASSET_CAP then return done("it's too big") end
    job.data = data
    job.request = phigrospp.fetch("GET", url .. ".sig", nil, function(code, signed)
      if job.cancelled then return end
      if code ~= 200 and code ~= 404 then return done(("GitHub answered %d"):format(code)) end
      finish(code == 200 and signed or nil)
    end)
  end, 0)
  return job
end

function mods.uninstall(repo)
  IO.Directory.Delete(mods.folder(repo), true)
  mods.installed[repo], asked[repo] = nil, nil
  save()
end

function mods.enable(repo, enabled)
  mods.installed[repo].enabled = enabled
  save()
end

-- the latest release of any repo, asked to github itself: done(release), or done(nil, why), never at once. github
-- answers an address 60 times an hour: an answer younger than `age` seconds is given again instead of asking
function mods.latest(repo, done, age)
  local known = asked[repo]
  if known and age and os.time() - known.time < age then return after(0, function() done(known.release) end) end
  phigrospp.fetch("GET", ("https://api.github.com/repos/%s/releases/latest"):format(repo), nil, function(status, body)
    if status ~= 200 then return done(nil, status == 404 and "it has no release" or ("GitHub answered %d"):format(status)) end
    local answer, sizes = phigrospp.json.decode(body), {}
    for _, asset in ipairs(answer.assets) do sizes[asset.name] = asset.size end
    local file = sizes["mod.zip"] and "mod.zip" or sizes["mod.lua"] and "mod.lua"
    if not file then return done(nil, "its latest release has no mod.zip or mod.lua") end
    asked[repo] = { time = os.time(), release = { repo = repo, version = answer.tag_name, file = file, size = sizes[file] } }
    save()
    done(asked[repo].release)
  end)
end

-- for mods ---------------------------------------------------------------------------------------------------------

-- the folder of the mod the function `level` frames up is from, when it has one of its own. the loader's own
-- require of a mod comes from C, with no frame there
local function folder(level)
  local frame = debug.getinfo(level + 1, "S")
  local source = frame and frame.source or ""
  return source:match("^@(.*/installed/[^/]+/[^/]+/)") or source:match("^@(.*/mods/[^/]+/)"), source
end

-- the folder of the mod calling it, where its release's files are: installed/<owner>/<name>/, mods/<name>/ for a
-- folder of mods/, mods/ for a single file
function phigrospp.dir()
  local dir, source = folder(2)
  return dir or source:match("^@(.*/)")
end

-- require("util") is first util.lua (or util/init.lua) of the calling mod's own folder, run once: a mod is written
-- the same in mods/ and once installed, and two mods can each have their util
local anywhere, own = require, {}

function require(name)
  local dir = folder(2)
  local path = dir and dir .. name:gsub("%.", "/")
  for _, file in ipairs(dir and { path .. ".lua", path .. "/init.lua" } or {}) do
    if own[file] == nil and IO.File.Exists(file) then
      local result = assert(loadfile(file, "t"))(name, file)
      own[file] = result == nil or result
    end
    if own[file] ~= nil then return own[file] end
  end
  return anywhere(name)
end

tab("Mods") -- drawn by catalog.lua, named here to come before the tabs of the mods themselves

-- the installed mods, as text only: no bytecode. one that fails is told in the Mods tab, the others still load
local repos = {}
for repo, m in pairs(mods.installed) do
  if m.enabled then repos[#repos + 1] = repo end
end
table.sort(repos)
for _, repo in ipairs(repos) do
  local chunk, why = loadfile(mods.folder(repo) .. "init.lua", "t")
  local ok = chunk and xpcall(chunk, function(err)
    why = debug.traceback(err, 2)
  end)
  if ok then
    print("loaded " .. repo)
  else
    mods.installed[repo].error = why
    print(("%s failed: %s"):format(repo, why))
  end
end
