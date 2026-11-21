-- a performance monitor over the game: frame times and their graph, what Phigros++ and each mod costs a frame, memory,
-- threads, clocks and heat, to tell a slow game from a slow mod

local UE = CS.UnityEngine
local GC = CS.System.GC

-- made once every mod has loaded, so they're the last rows of the Phigros++ tab
local enabled, corner
on("load", function()
  enabled = setting("Performance monitor", false)
  corner = setting("Monitor corner", "bottom left", { "bottom left", "bottom right", "top left", "top right" }, nil,
    function() return enabled() end)
end)

-- frames in the graph, frames a hitch is longer than, frames between two thread reads
local BARS, HITCH, EVERY = 240, 4, 4
-- utime and stime, fields 14 and 15 of a /proc stat file, counted after the name since it can hold spaces
local TIMES = "%((.*)%) " .. ("%S+ "):rep(11) .. "(%d+) (%d+)"
local CORNERS = { ["bottom left"] = { 0, 0 }, ["bottom right"] = { 1, 0 }, ["top left"] = { 0, 1 }, ["top right"] = { 1, 1 } }
local THERMAL = { [0] = "none", "light", "moderate", "severe", "critical", "emergency", "shutdown" }
-- good, late, bad
local HEX = { "#7fe08a", "#ffd27f", "#ff7f8a" }
local RGB = { { 0.5, 0.88, 0.54, 1 }, { 1, 0.82, 0.5, 1 }, { 1, 0.5, 0.54, 1 } }
local CLEAR = { 0, 0, 0, 0 }

local ui -- the overlay while it's shown, with what it measured since
local window -- a sample of the counters at the start of the second the text shows

local function line(path)
  local file = io.open(path)
  if not file then return nil end
  local text = file:read("l")
  file:close()
  return text
end

local function folders(path)
  local list, found = {}, CS.System.IO.DirectoryInfo(path):GetDirectories()
  for i = 0, #found - 1 do list[i + 1] = found[i].FullName end
  return list
end

-- cpu time a thread or process used so far (seconds) and its name, nil for a thread that just ended
local function cpu(path)
  local stat = line(path)
  if not stat then return nil end
  local name, user, system = stat:match(TIMES)
  return (user + system) / 100, name
end

local function grade(value, budget) return value <= budget * 1.25 and 1 or value <= budget * 2 and 2 or 3 end
local function paint(level, s) return ("<color=%s>%s</color>"):format(HEX[level], s) end

local function build()
  local scale = UE.Screen.height / 1080
  local go = UE.GameObject("phigrospp-monitor")
  UE.Object.DontDestroyOnLoad(go)
  local canvas = go:AddComponent(UE.Canvas)
  canvas.renderMode, canvas.sortingOrder = 0, 32767 -- ScreenSpaceOverlay
  local at = CORNERS[corner()]
  local panel = phigrospp.ui.rect(go.transform, "phigrospp-monitor-panel", { 0, 0 }, { 0, 0 }, { 0, 0, 0, 0.7 }, at)
  panel.transform.anchorMin, panel.transform.anchorMax = at, at
  local pad, width, height = math.floor(12 * scale), math.max(1, math.floor(2 * scale)), math.floor(60 * scale)
  local font = UE.Resources.GetBuiltinResource(UE.Font, "LegacyRuntime.ttf")
  ui = { go = go, panel = panel, pad = pad, width = width, height = height, bars = {}, rects = {}, levels = {}, bar = 0, last = now(),
    frames = 0, worst = 0, dropped = 0, hitches = 0, busy = phigrospp.busy(), tasks = {}, task = 0, listed = 0, threads = {},
    clocks = folders("/sys/devices/system/cpu/cpufreq") }
  ui.text = phigrospp.ui.text(panel.transform, "phigrospp-monitor-text", font, { pad, 2 * pad + height }, { 0, 0 },
    18 * scale, 6, { 0, 0 }) -- LowerLeft
  -- the graph sweeps from left to right, one bar per frame, 3 frame budgets high, with the budget as a line
  for i = 1, BARS do
    ui.bars[i] = phigrospp.ui.rect(panel.transform, "phigrospp-monitor-bar", { pad + (i - 1) * width, pad }, { width, 0 },
      CLEAR, { 0, 0 })
    ui.rects[i] = ui.bars[i].transform
  end
  phigrospp.ui.rect(panel.transform, "phigrospp-monitor-budget", { pad, pad + height / 3 }, { BARS * width, math.ceil(scale) },
    { 1, 1, 1, 0.6 }, { 0, 0.5 })
end

-- one thread every few frames, its use measured between two of its reads, since reading the ~90 of the game at once
-- would make a frame late. the list of threads is made again every 10 seconds
local function readThread(t)
  if ui.task >= #ui.tasks and t - ui.listed > 10 then ui.tasks, ui.task, ui.listed = folders("/proc/self/task"), 0, t end
  ui.task = ui.task % #ui.tasks + 1
  local path = ui.tasks[ui.task]
  local time, name = cpu(path .. "/stat")
  local old = ui.threads[path]
  ui.threads[path] = time and { name = name, time = time, at = t, use = old and (time - old.time) / (t - old.at) * 100 or 0 }
end

local function sample()
  local clocks = {}
  for i, policy in ipairs(ui.clocks) do clocks[i] = ("%.1f"):format(line(policy .. "/scaling_cur_freq") / 1e6) end
  -- adreno gpus count busy cycles over the last moment
  local busy, total = (line("/sys/class/kgsl/kgsl-3d0/gpubusy") or ""):match("(%d+)%s+(%d+)")
  local spent = {}
  for name, seconds in pairs(phigrospp.spent) do spent[name] = seconds end
  return { at = now(), hz = phigrospp.refreshRate(), busy = phigrospp.busy(), spent = spent, cpu = cpu("/proc/self/stat"),
    clocks = clocks, gpu = busy and tonumber(total) > 0 and busy / total,
    collections = GC.CollectionCount(0), frames = ui.frames, dropped = ui.dropped }
end

-- the top entries of a { name = value } table as "name value", formatted by fmt
local function top(values, count, fmt)
  local list = {}
  for name, value in pairs(values) do list[#list + 1] = { name = name, value = value } end
  table.sort(list, function(a, b) return a.value > b.value end)
  local parts = {}
  for i = 1, math.min(count, #list) do parts[i] = (fmt):format(list[i].name, list[i].value) end
  return table.concat(parts, ", ")
end

local function report(from, to)
  local seconds, frames, budget = to.at - from.at, to.frames - from.frames, 1000 / to.hz
  local frame = seconds * 1000 / frames
  local mods, threads = {}, {}
  for name, s in pairs(to.spent) do mods[name] = (s - (from.spent[name] or 0)) * 1000 / frames end
  for _, t in pairs(ui.threads) do threads[t.name] = math.max(threads[t.name] or 0, t.use) end
  local cost = (to.busy - from.busy) * 1000 / frames
  local statm = line("/proc/self/statm")
  local thermal = phigrospp.thermal()
  local hitch = ui.hitch
  local il2cpp = UE.Profiling.Profiler.GetMonoUsedSizeLong() / 2 ^ 20
  -- a line a second in the log, read back with the profile (make profile)
  print(("monitor: %.0f fps, worst %.1f ms, %d dropped, Phigros++ %.2f ms, il2cpp %.1f MB, %d collections, %s"):format(
    frames / seconds, ui.worst * 1000, to.dropped - from.dropped, cost, il2cpp, to.collections - from.collections, scene()))
  ui.text.text = table.concat({
    ("%s at %.0f Hz, %s a frame, %s at worst, %d dropped"):format(paint(grade(frame, budget), ("%.0f fps"):format(frames / seconds)),
      to.hz, paint(grade(frame, budget), ("%.1f ms"):format(frame)),
      paint(grade(ui.worst * 1000, budget), ("%.1f ms"):format(ui.worst * 1000)), to.dropped - from.dropped),
    ("%d %s since shown%s"):format(ui.hitches, ui.hitches == 1 and "hitch" or "hitches", hitch and (", the last %.0f ms long %.0f s ago%s"):format(hitch.ms,
      to.at - hitch.at, hitch.why) or ""),
    ("Phigros++ %s a frame (%.0f%%): %s"):format(paint(grade(cost, budget / 10), ("%.2f ms"):format(cost)),
      cost / budget * 100, top(mods, 4, "%s %.2f")),
    ("memory %.0f MB, il2cpp %.1f MB, lua %.1f MB, %d il2cpp collections"):format(statm:match("^%d+ (%d+)") * 4096 / 2 ^ 20,
      il2cpp, collectgarbage("count") / 1024, to.collections - from.collections),
    ("cpu %.0f%%: %s"):format((to.cpu - from.cpu) / seconds * 100, top(threads, 4, "%s %.0f%%")),
    ("%sclocks %s GHz, heat %s"):format(to.gpu and ("gpu %s, "):format(paint(grade(to.gpu, 0.7), ("%.0f%%"):format(to.gpu * 100)))
      or "", table.concat(to.clocks, " / "), paint(thermal == 0 and 1 or thermal < 3 and 2 or 3, THERMAL[thermal])),
    ("scene %s, target %d fps, time scale %g"):format(scene(), UE.Application.targetFrameRate, UE.Time.timeScale),
  }, "\n")
  ui.panel.transform.sizeDelta = { math.max(ui.text.preferredWidth, BARS * ui.width) + 2 * ui.pad,
    ui.text.preferredHeight + ui.height + 3 * ui.pad }
end

on("update", function()
  if not enabled() then
    if il2cpp.alive(ui and ui.go) then UE.Object.Destroy(ui.go) end
    ui = nil
    return
  end
  if not il2cpp.alive(ui and ui.go) then
    build()
    window = sample()
  end
  local t, busy = now(), phigrospp.busy()
  local dt = t - ui.last
  ui.frames, ui.worst = ui.frames + 1, math.max(ui.worst, dt)
  if dt > 1.5 / window.hz then ui.dropped = ui.dropped + 1 end
  if dt > HITCH / window.hz then
    ui.hitches = ui.hitches + 1
    ui.hitch = { ms = dt * 1000, at = t, why = (", Phigros++ %.0f ms%s"):format((busy - ui.busy) * 1000,
      GC.CollectionCount(0) > window.collections and ", il2cpp collected" or "") }
    print(("monitor: hitch from %.6f to %.6f%s"):format(ui.last, t, ui.hitch.why))
  end
  ui.last, ui.busy = t, busy
  if ui.frames % EVERY == 0 then readThread(t) end
  -- colours are only set when they change, which is rarely
  local level, next = grade(dt, 1 / window.hz), ui.bar % BARS + 1
  ui.bar = next
  ui.rects[next].sizeDelta = { ui.width, math.min(dt * window.hz / 3, 1) * ui.height }
  if ui.levels[next] ~= level then ui.bars[next].color, ui.levels[next] = RGB[level], level end
  next = next % BARS + 1
  if ui.levels[next] then ui.bars[next].color, ui.levels[next] = CLEAR, nil end
  if t - window.at >= 1 then
    local current = sample()
    report(window, current)
    window, ui.worst = current, 0
  end
end)

on("setting", function(label)
  if label == "Monitor corner" and il2cpp.alive(ui and ui.go) then UE.Object.Destroy(ui.go) end
end)
