---@meta
-- the mod api for editors (lua-language-server) and the source of the wiki's Mod API page (scripts/api.ts):
-- `-- #` lines are its headings, --[=[md blocks are copied as they are, the rest is rendered from the annotations

--[=[md
A mod is `mods/<name>.lua` or `mods/<name>/init.lua`, run in name order. Names starting with `_` are skipped. Mods
are loaded with `require`, so a mod can `require("other")` and get what it returns. A mod installed from GitHub
([[Publishing a mod]]) is a folder too, in `installed/<owner>/<name>/`, and runs before them. In a folder mod,
`require("util")` runs the `util.lua` (or `util/init.lua`) of its own folder first, once.

Your editor knows all of this: `node mod.mjs new` sets it up ([[Your first mod]]), and `node mod.mjs types` brings
the latest `api.lua` into a mod made before.
]=]

---@alias Difficulty "EZ"|"HD"|"IN"|"AT"|"SP"
---@alias Judgement "perfect"|"good"|"bad"|"miss"
---`{ r, g, b, a }` from 0 to 1
---@alias Colour number[]
---`{ x, y }`
---@alias Vector number[]
---@alias Icon "arrow-left"|"badge-check"|"check"|"clock"|"crown"|"eye"|"fast-forward"|"lock"|"pause"|"pencil"|"play"|"rewind"|"send"|"skip-back"|"square"|"square-check"|"star"|"trash-2"|"trophy"|"user-plus"|"users"|"x"|string
---A Unity or game object, used with its C# fields and methods.
---@alias Unity any
---@alias Sprite Unity
---@alias Texture2D Unity
---@alias GameObject Unity
---@alias Transform Unity
---@alias RectTransform Unity
---@alias Image Unity
---@alias RawImage Unity
---@alias Text Unity
---@alias LeanPolygon Unity
---@alias UnityWebRequest Unity
---@alias Class Unity
---@alias System.Type Unity
---@alias System.String Unity
---@alias byte integer

---@class phigrospp
phigrospp = {}
phigrospp.json = {}

-- # The game's classes

--[=[md
```lua
local UE = CS.UnityEngine                        -- any class by full name
local go = UE.GameObject("name")                 -- calling a class runs its constructor
local image = go:AddComponent(UE.UI.Image)       -- a class passed for a System.Type becomes that type
image.color = { 1, 1, 1, 0.5 }                   -- structs are tables, by field name or in order
print(image.transform.anchoredPosition.x)        -- fields, properties and methods by name
```

- Overloads are picked from the arguments. To hook an overloaded method, pass its parameter count or type names:
  `hook(Class, "Name", 2, callbacks)` or `hook(Class, "Name", { "System.Single", "*" }, callbacks)`.
- Numbers, booleans and strings convert both ways, enums are integers, arrays index from 0 like in C#.
- Unity calls are only safe on the main thread: in `on("update")`, in hooks on game methods, and at load.
- Unity objects a mod creates (constructors, `Object.Instantiate`) are destroyed before every reload. `on("unload")`
  is only needed for anything else.
]=]

---Every class of the game and of Unity, by full name: `CS.UnityEngine.GameObject`, `CS.ScoreControl`.
---@type table<string, any>
CS = {}

---@class HookCallbacks
---@field before? fun(self: Unity, ...)
---@field after? fun(self: Unity, ...): any # returning a value replaces the result

---Runs functions around a game method: `before` gets its arguments, `after` its arguments then its result.
---```lua
---hook(CS.ScoreControl, "Perfect", {
---  before = function(self, noteCode, judgeTime) end,
---  after = function(self, noteCode, judgeTime, pos, flag, result) end,
---})
---```
---@param class Unity
---@param name string
---@param callbacks HookCallbacks
---@return integer id # for `unhook`
---@overload fun(class: Unity, name: string, params: integer|string[], callbacks: HookCallbacks): integer
function hook(class, name, callbacks) end

---```lua
---local id = hook(CS.ScoreControl, "Perfect", { after = function() print("perfect") end })
---unhook(id) -- the method runs as the game wrote it again
---```
---@param id integer # what `hook` returned
function unhook(id) end

-- # Events

--[=[md
`on(event, function)` runs the function each time the event happens. [[Reacting to the game]] walks through the ones
used most.

| Event | When | The function gets |
|---|---|---|
| `update` | every frame | |
| `load`, `unload` | the mods loaded, they're about to reload | |
| `scene` | the game changes screen, and once after load | its name: `"ChapterSelector"`, `"SongSelector"`, `"Level"`... |
| `setting` | the player changed a setting | its label and value |
| `song` | a song starts | the `Chart` |
| `chart` | a song's Chart as the game loaded and mirrored it, before it's laid out: what it's given then is what plays | the game's Chart |
| `hit` | a note is judged | a `Hit` |
| `pause`, `resume` | the player pauses or comes back | |
| `leave` | the song is quit, retried or finished | |
| `finish` | the song ended | its `Stats` |
| `jump` | the song jumped (`phigrospp.jump`) | the time jumped to |
| `restart` | the song was put back at its start (`phigrospp.restart`) | |
| `replays` | a replay was recorded or deleted | |
| `best` | a recorded play beat or tied the chart's record (with modifiers: the best of the player's replays with the same ones) | its replay's path |
| `link` | the app was opened or brought back by a `phigrospp://` link | the url |
| `room` | the room the player is in changed ([[Rooms]]) | the room, nil once out of it |
| anything else | `phigrospp.emit` was called with it, for mods talking to each other | what it was given |
]=]

---@alias Event "update"|"load"|"unload"|"scene"|"setting"|"song"|"chart"|"hit"|"pause"|"resume"|"leave"|"finish"|"jump"|"restart"|"replays"|"best"|"link"|"room"|string

---Runs the function each time the event happens.
---```lua
---on("hit", function(hit)
---  if hit.judgement == "miss" then print("missed a " .. hit.note) end --> missed a flick
---end)
---on("finish", function(result)
---  toast(("%d, %.2f%%"):format(result.score, result.accuracy)) --> 996761, 99.68%
---end)
---```
---@param event Event
---@param fn function
---@overload fun(event: "scene", fn: fun(name: string))
---@overload fun(event: "setting", fn: fun(label: string, value: any))
---@overload fun(event: "song", fn: fun(chart: Chart))
---@overload fun(event: "hit", fn: fun(hit: Hit))
---@overload fun(event: "finish", fn: fun(result: Stats))
---@overload fun(event: "jump", fn: fun(t: number))
---@overload fun(event: "best", fn: fun(path: string))
---@overload fun(event: "link", fn: fun(url: string))
function on(event, fn) end

---Runs the `on(event)` handlers with these arguments.
---```lua
----- in one mod
---phigrospp.emit("section", 42.5, 60)
----- in another
---on("section", function(from, to) print(from, to) end) --> 42.5	60
---```
---@param event string
---@param ... any
function phigrospp.emit(event, ...) end

-- # Settings

--[=[md
Settings are rows of the Phigros++ settings tab, or of a tab of the mod's own, saved for it ([[Settings]]). Each
function takes the tab's name and a function saying whether the row shows as its last arguments.
]=]

---A toggle, a slider or a choice, saved. Returns its getter, which sets it when given a value (as if the player had).
---```lua
---local enabled = setting("Show the thing", true)                 -- a toggle in the Phigros++ tab
---local other = setting("Other thing", false, "My mod")           -- or in a tab of its own
---local size = setting("Size", 1.0, { 0.5, 2 })                   -- a slider, whole numbers when the default is one
---local offset = setting("Offset", 0, { -100, 100, step = 5, unit = "ms", hint = "*Shown under it" })
---                                                                -- with a step: - and + buttons, the value on the right
---local style = setting("Style", "osu", { "osu", "classic" })     -- a choice, tapping it picks the next one
---if enabled() then end
---enabled(false)
---```
---@generic T
---@param label string
---@param default T
---@param options? table # `{ min, max, step =, unit =, hint = }` for a slider, the values for a choice
---@param tab? string
---@param shown? fun(): boolean
---@return fun(value?: T): T
---@overload fun(label: string, default: boolean, tab?: string, shown?: fun(): boolean): fun(value?: boolean): boolean
function setting(label, default, options, tab, shown) end

---A button running a function. A label can be a function, the button follows what it returns. `danger` makes the
---label red, for what can't be undone.
---```lua
---button("Say hello", function() toast("Hello") end)
---local taps = 0
---button(function() return ("Tapped %d times"):format(taps) end, function() taps = taps + 1 end, "My mod")
---button("Forget my records", forget, "My mod", nil, true) -- red, for what can't be undone
---```
---@param label string|fun(): string
---@param fn fun()
---@param tab? string
---@param shown? fun(): boolean
---@param danger? boolean
function button(label, fn, tab, shown, danger) end

---A label with the game's arrow button, as on its Misc page.
---```lua
---link("Open the docs", function() CS.UnityEngine.Application.OpenURL("https://docs.phigros.tools") end)
---```
---@param label string|fun(): string
---@param fn fun()
---@param tab? string
---@param shown? fun(): boolean
function link(label, fn, tab, shown) end

---A bar filled from 0 to 1, redrawn every frame: `fn` returns how far along it is and a text for its middle, or
---`{ left =, center =, right = }`.
---```lua
---progress(function()
---  local done = now() % 5 / 5
---  return done, ("Downloading, %d%%"):format(math.floor(done * 100))
---end, "My mod")
---progress(function() return 0.25, { left = "song.zip", right = "10 / 40 MB" } end, "My mod")
---```
---@param fn fun(): number, (string|table)?
---@param tab? string
---@param shown? fun(): boolean
function progress(fn, tab, shown) end

---An empty row `height` high that `draw` fills each time the settings are built, for a preview: `area` is its
---RectTransform, as wide as the tab's rows.
---```lua
---row(190, function(area)
---  phigrospp.ui.cover(area, "my-preview", { 40, 170 }, { 300, 150 }, "Glaciaxion.SunsetRay.0")
---end, "My mod")
---```
---@param height number
---@param draw fun(area: Unity)
---@param tab? string
---@param shown? fun(): boolean
function row(height, draw, tab, shown) end

---A tab shown only while `shown` returns true. The tab "Profile" puts rows on the game's Profile page. Given `draw`,
---the tab draws its page itself each time the settings are built: `view` is a RectTransform as high as the list,
---centred on screen, and `font` the game's.
---```lua
---local debug = setting("Debug", false)
---tab("Debug tools", function() return debug() end) -- the tab shows while Debug is on
---button("Dump the scene", function() print(scene()) end, "Debug tools")
---setting("Show my RKS", true, "Profile")             -- a row on the game's Profile page
---```
---@param name string
---@param shown? fun(): boolean
---@param draw? fun(view: Unity, font: Unity)
function tab(name, shown, draw) end

-- # Timers, toasts and files

--[=[md
Everything below hands out plain Lua copies: mods watch the game, they never steer it. Custom charts add songs to it
([[Custom charts]]), they don't change how the game's own play.
]=]

---The current scene's name: "ChapterSelector", "SongSelector", "Level"...
---```lua
---print(scene()) --> SongSelector
---if scene() == "Level" then toast("Later") end
---```
---@return string
function scene() end

---Runs `fn` once in `seconds`.
---```lua
---after(2, function() toast("Two seconds later") end)
---```
---@param seconds number
---@param fn fun()
---@return fun() cancel
function after(seconds, fn) end

---Runs `fn` every `seconds`.
---```lua
---local stop = every(0.5, function() print(stats().combo) end)
---stop() -- it doesn't run again
---```
---@param seconds number
---@param fn fun()
---@return fun() cancel
function every(seconds, fn) end

---Seconds since the game started.
---```lua
---local start = now()
---local list = records()
---print(("%d records in %.3f s"):format(#list, now() - start)) --> 84 records in 0.012 s
---```
---@return number
function now() end

---@class ToastOptions
---@field seconds? number # at most 10
---@field icon? Icon # one of `ui.icon`'s icons
---@field avatar? string # a player's avatar, the game's key of it
---@field tap? fun() # runs when tapped, as a button's function does

---A message at the bottom left of the screen, for 4 seconds unless told: three show at once, the next ones wait their
---turn. Never over a song: one made meanwhile shows once it's left. One saying what another on screen or waiting says
---isn't made, whatever its icon. A tap dismisses a toast, and so does the function it returns.
---```lua
---toast("Saved")
---toast("Saved", 8)
---local dismiss = toast("Update ready", { seconds = 10, icon = "star", tap = function() end })
---```
---@param message any
---@param options? number|ToastOptions # seconds, 10 at most, a negative time is an error
---@return fun() dismiss
function toast(message, options) end

---A Sprite from a png or jpg next to the mod's file.
---```lua
---local logo = image("logo.png") -- logo.png next to init.lua
---phigrospp.ui.rect(parent, "my-logo", { 40, 40 }, { 128, 128 }, { 1, 1, 1, 1 }).sprite = logo
---```
---@param path string
---@return Sprite
function image(path) end

---The mod's folder: `installed/<owner>/<name>/`, `mods/<name>/`, or `mods/` for a single file.
---```lua
---print(phigrospp.dir()) --> /sdcard/Android/data/sh.molly.phigrosplusplus/files/phigros++/mods/hello/
---local notes = phigrospp.read(phigrospp.dir() .. "notes.txt")
---```
---@return string
function phigrospp.dir() end

---A whole file. `bundle/<path>` reads a file of the bundle.
---```lua
---local text = phigrospp.read(phigrospp.root .. "/my-mod.json")
---local words = phigrospp.read("bundle/words.txt") -- a file of the bundle
---```
---@param path string
---@return string
function phigrospp.read(path) end

---A table as json, and back. The table is flat: its values are strings, numbers and booleans.
---```lua
---print(phigrospp.json.encode({ plays = 3, name = "hi" })) --> {"plays":3,"name":"hi"}
---print(phigrospp.json.decode('{"version":"0.3.0"}').version) --> 0.3.0
---```
---@param object table
---@return string
function phigrospp.json.encode(object) end

---@param json string
---@return any
function phigrospp.json.decode(json) end

---Writes a whole file, through a temporary one so a crash never leaves half of it.
---```lua
---phigrospp.write(phigrospp.root .. "/my-mod.json", phigrospp.json.encode({ plays = 3 }))
---```
---@param path string
---@param data string
function phigrospp.write(path, data) end

---The phigros++ folder, where mods keep their files.
---@type string
phigrospp.root = ""

---The app's own folder, which no other app can read.
---```lua
---print(phigrospp.private()) --> /data/user/0/sh.molly.phigrosplusplus/files
---phigrospp.write(phigrospp.private() .. "/token", token) -- for a secret
---```
---@return string
function phigrospp.private() end

---A child by path, the error naming what's missing after a game update.
---```lua
---local canvas = phigrospp.find(go.transform, "ContentCanvas") -- an error naming what's missing if the game moved it
---```
---@param transform Unity
---@param path string # "A/B"
---@return Transform
function phigrospp.find(transform, path) end

-- # Screens

--[=[md
Pages over the song list are made of copies of its own parts, so they look and move like the game.
`local ui = phigrospp.ui` first.
]=]

---@class ConfirmTile
---@field icon? Unity # a Sprite
---@field label string
---@field colour? Colour
---@field tap? fun()
---@field on? fun(): boolean # lit while it returns true
---@field note? fun(): string

---@class ConfirmOptions
---@field title string
---@field message? string
---@field yes? string|false # false leaves only no
---@field no? string|false # false leaves only yes
---@field danger? boolean # makes yes red
---@field grid? { cells: (string|ConfirmTile)[], columns: integer, height: number } # aligned columns, one is centered
---@field input? string # a text box's placeholder: its text is returned second
---@field progress? fun(): number, string # a bar from 0 to 1 and its message, redrawn

---@class ChooseTile
---@field icon Icon
---@field label string
---@field colour? Colour
---@field value any

---@class PageList
---@field count integer
---@field row fun(row: Unity, i: integer) # sets a SongListItem
---@field selected? fun(row: Unity, i: integer) # sets the middle one's songName, artist, level and levelText
---@field select? fun(i: integer) # runs when it changes

---A page sliding over the song list.
---@class Page
local Page = {}

---A copy of a song list part where it is: topbar, shadows, background (the list's dimming), info (record panel),
---cover, selected, up, down, back, play.
---```lua
---local page = phigrospp.ui.page()
---page:part("topbar")
---local cover = page:part("cover").transform
---```
---@param name "topbar"|"shadows"|"background"|"info"|"cover"|"selected"|"up"|"down"|"back"|"play"
---@return GameObject
function Page:part(name) end

---The back button closes the page.
---```lua
---local page = phigrospp.ui.page()
---page:back() -- the back arrow slides it out
---```
function Page:back() end

---The play button runs `fn`.
---```lua
---local play = page:play(function() toast("Play!") end) -- the copy of the play button
---play:SetActive(false)
---```
---@param fn fun()
---@return GameObject
function Page:play(fn) end

---The song list's list.
---```lua
---page:list({
---  count = #replays,
---  row = function(row, i) row.songName.text, row.difficulty.text = replays[i].date, "" end,
---  selected = function(row, i) row.songName.text = replays[i].date end,
---  select = function(i) shown = replays[i] end,
---})
---```
---@param options PageList
function Page:list(options) end

---Slides back.
---```lua
---page:play(function()
---  page:close()
---  phigrospp.play(id, "IN")
---end)
---```
function Page:close() end

---A screen of its own over the menus, like the rooms. The song list under it takes no touch meanwhile. Its pieces are
---placed in units from its bottom left.
---@class View
---@field height number # 1080
---@field width number
---@field left number # where the columns start
---@field top number # the middle of the top bar
local View = {}

---Slides a panel in, another one's out.
---```lua
---local view = phigrospp.ui.view("my-mod")
---view.show("list")
---```
---@param screen string
function View.show(screen) end

---Slides it out.
---```lua
---view.part("all", "", function(root) view.back(root, view.hide) end)
---```
function View.hide() end

---The panel showing.
---```lua
---print(view.shown()) --> list
---```
---@return string?
function View.shown() end

---Draws a part again only when its key changed.
---```lua
---view.show("scores")
---view.part("all", #scores, function(root) -- drawn again only when #scores changes
---  view.text(root, { view.left, view.top }, 44, ("%d scores"):format(#scores))
---end)
---```
---@param name string
---@param key any
---@param draw fun(root: Unity)
function View.part(name, key, draw) end

---A text from the middle of its left side.
---```lua
---local title = view.text(root, { view.left, view.top }, 44, "Scores")
---view.text(root, { view.width - view.left, view.top }, 30, "11.3288", ui.colours.dim, 5, { 1, 0.5 }) -- MiddleRight
---view.text(row, { 300, 66 }, 34, "A very long song name", ui.colours.white, 3, nil, 400) -- cut at 400 with ...
---local after = title.preferredWidth + 20 -- a UnityEngine.UI.Text
---```
---@param parent Unity
---@param pos Vector
---@param size number
---@param text string
---@param colour? Colour
---@param alignment? integer # a TextAnchor, MiddleLeft when left out
---@param pivot? Vector
---@param box? number # a width: what goes past it is cut and ends with "..."
---@return Text
function View.text(parent, pos, size, text, colour, alignment, pivot, box) end

---One of `ui.icon`'s icons.
---```lua
---view.icon(root, { 60, 60 }, 48, "trophy", ui.colours.gold)
---```
---@param parent Unity
---@param pos Vector
---@param size number
---@param icon Icon
---@param colour? Colour
---@return Image
function View.icon(parent, pos, size, icon, colour) end

---A slanted bar with a centred text.
---```lua
---view.plate(row, { 300, 44 }, { 116, 34 }, ui.colours.IN, 22, "IN 15.8")
---```
---@param parent Unity
---@param pos Vector
---@param size Vector
---@param colour Colour
---@param fontSize number
---@param label string
---@param ink? Colour
---@return LeanPolygon
function View.plate(parent, pos, size, colour, fontSize, label, ink) end

---A button, lit in a colour when given one. Without `fn` it's only a label.
---```lua
---view.action(root, { 1500, 120 }, 300, "Start", function() toast("Go") end, ui.colours.green)
---view.action(root, { 1500, 30 }, 300, "Waiting") -- only a label
---```
---@param parent Unity
---@param pos Vector
---@param width number
---@param label string
---@param fn? fun()|false
---@param lit? Colour|false
---@return LeanPolygon
function View.action(parent, pos, width, label, fn, lit) end

---The back arrow.
---```lua
---view.part("all", "", function(root) view.back(root, view.hide) end)
---```
---@param root Unity
---@param fn fun()
function View.back(root, fn) end

---Makes anything a button.
---```lua
---local box = ui.rect(parent, "my-tap", { 0, 0 }, { 200, 80 }, { 0, 0, 0, 0 })
---view.tappable(box, function() toast("Tapped") end)
---```
---@param shape Unity
---@param fn fun()
function View.tappable(shape, fn) end

---A checkbox ending at `pos`.
---```lua
---view.checkbox(root, { 1800, 120 }, "Spectators", allowed, function() allowed = not allowed end)
---```
---@param parent Unity
---@param pos Vector
---@param label string
---@param checked boolean
---@param fn fun()
function View.checkbox(parent, pos, label, checked, fn) end

---The top bar's titles for screens that go together: `pick(title)` runs when another one's is tapped.
---```lua
---local shown = "Rooms"
---view.titles(root, { "Rooms", "Friends" }, shown, function(title)
---  shown = title
---  draw()
---end)
---```
---@param root Unity
---@param titles string[]
---@param own string
---@param pick fun(title: string)
function View.titles(root, titles, own, pick) end

---A screen sliding in over a canvas and its shade.
---@class Panel
---@field transform Unity # to fill
---@field close fun() # slides it out, then `closed()` runs

---@class phigrospp.ui
local ui = {}
phigrospp.ui = ui

---What they're drawn in, and a level's plate.
---@type { white: Colour, dim: Colour, faint: Colour, dark: Colour, gold: Colour, green: Colour, red: Colour, EZ: Colour, HD: Colour, IN: Colour, AT: Colour }
ui.colours = {}

---A Lucide icon (lucide.dev) as a white Sprite tinted by its Image: one of the names listed, or another icon's svg.
---```lua
---local star = ui.icon("star")
---image.sprite, image.color = star, ui.colours.gold
---```
---@param name Icon
---@return Sprite
function ui.icon(name) end

---A copy of a game button moved by an offset, running `fn` instead.
---```lua
---local copy = ui.clone(original, { -150, 0 }, function() toast("Mine") end)
---```
---@param button Unity
---@param offset Vector
---@param fn fun()
---@return GameObject
function ui.clone(button, offset, fn) end

---A copy of a play button `slot` slots left of it, showing a sprite.
---```lua
---local selector = CS.UnityEngine.Object.FindObjectOfType(CS.SongSelectorControl)
---local bot = ui.sideButton(selector.startButton, 2, ui.icon("eye"), function() toast("Autoplay") end)
---bot:SetActive(false) -- a GameObject
---```
---@param play Unity
---@param slot integer
---@param sprite Unity
---@param fn fun()
---@return GameObject
function ui.sideButton(play, slot, sprite, fn) end

---A switch like the song list's Mirror one, after it and those already there: lit while `lit` says so, `fn` runs on
---a tap.
---```lua
---local practice = setting("Practice", false)
---on("scene", function(name)
---  if name == "SongSelector" then ui.switch("Practice", practice, function() practice(not practice()) end) end
---end)
---```
---@param label string
---@param lit fun(): boolean
---@param fn fun()
function ui.switch(label, lit, fn) end

---A tab left of the chapter screen's settings and of those already there, showing an icon: asked for at each
---"ChapterSelector" scene.
---```lua
---on("scene", function(name)
---  if name == "ChapterSelector" then ui.shortcut("users", open) end
---end)
---```
---@param icon Icon
---@param fn fun()
function ui.shortcut(icon, fn) end

---Slides the song list out to the left and an empty page in.
---```lua
---local page = ui.page()
---page:part("topbar")
---page:part("background")
---page:back()
---```
---@return Page
function ui.page() end

---The game's popup, from a button's function or a coroutine: waits for the choice and returns true for yes.
---```lua
---if ui.confirm({ title = "Delete replay", message = "...", yes = "Delete", danger = true }) then end
---```
---@param options ConfirmOptions
---@return boolean yes
---@return string? text
function ui.confirm(options) end

---Closes the open popup, its confirm returning what's given.
---```lua
---button("Ask", function()
---  after(5, function() ui.close(false) end) -- no answer in 5 seconds is a no
---  if ui.confirm({ title = "Still there?" }) then toast("Yes") end
---end)
---```
---@param ... any
function ui.close(...) end

---A popup of tiles to pick one of, called like confirm: returns the value of the one tapped, nothing when the player
---backs out.
---```lua
---local value = ui.choose("ggmolly#0042", { { icon = "eye", label = "Watch", colour = ui.colours.green, value = "watch" } })
---```
---@param title string
---@param choices ChooseTile[]
---@return any
function ui.choose(title, choices) end

---A bar slanted like the game's, from its top left corner.
---```lua
---local bar = ui.bar(parent, "my-bar", { 0, 96 }, { 600, 96 }, ui.colours.faint)
---view.text(bar.transform, { 40, 48 }, 34, "In the bar")
---```
---@param parent Unity
---@param name string
---@param pos Vector
---@param size Vector
---@param colour Colour
---@return LeanPolygon
function ui.bar(parent, name, pos, size, colour) end

---A song's illustration cut to fill such a bar, what's put in it is cut to its shape too. It's the level's own when
---the level has one. A few songs have one per
---level: given a level, it's that level's.
---```lua
---ui.cover(row, "my-cover", { 0, 96 }, { 170, 96 }, "Glaciaxion.SunsetRay.0", "IN")
---```
---@param parent Unity
---@param name string
---@param pos Vector
---@param size Vector
---@param id string # the song's id
---@param level? Difficulty
---@return LeanPolygon
function ui.cover(parent, name, pos, size, id, level) end

---A screen sliding in over a canvas and its shade.
---```lua
---local canvas = ui.screen("my-mod", 50)
---local panel = ui.panel(canvas, "my-panel", function() print("gone") end)
---ui.rect(panel.transform, "my-box", { 100, 100 }, { 400, 300 }, ui.colours.dark)
---after(3, panel.close)
---```
---@param canvas Unity
---@param name string
---@param closed? function
---@param shade? number # how dark it is (0.85), for a screen whose texts go over what's under
---@return Panel
function ui.panel(canvas, name, closed, shade) end

---A component on a new object under `parent`, placed from its bottom left corner: what `ui.rect` and `ui.text` make
---theirs with.
---```lua
---local raw = ui.place(parent, "my-picture", CS.UnityEngine.UI.RawImage, { 0, 0 }, { 400, 400 })
---```
---@param parent Unity
---@param name string
---@param kind Unity # a component's class
---@param pos Vector
---@param size Vector
---@param pivot? Vector # `{ 0, 0.5 }` when left out
---@return Unity component
function ui.place(parent, name, kind, pos, size, pivot) end

---A plain Image in a colour, placed like `ui.place`.
---```lua
---local box = ui.rect(parent, "my-box", { 100, 100 }, { 400, 300 }, ui.colours.dark)
---box.sprite = image("logo.png")
---```
---@param parent Unity
---@param name string
---@param pos Vector
---@param size Vector
---@param colour Colour
---@param pivot? Vector
---@return Image image
function ui.rect(parent, name, pos, size, colour, pivot) end

---A Text in white, placed like `ui.place`, its text overflowing its box. `alignment` is a TextAnchor.
---```lua
---local label = ui.text(parent, "my-label", font, { 40, 40 }, { 0, 0 }, 32, 3) -- MiddleLeft
---label.text = "Hello"
---```
---@param parent Unity
---@param name string
---@param font Unity
---@param pos Vector
---@param size Vector
---@param fontSize number
---@param alignment integer
---@param pivot? Vector
---@return Text text
function ui.text(parent, name, font, pos, size, fontSize, alignment, pivot) end

---A canvas over everything in any scene, 1080 units high like the game's menus and `width` wide, whose buttons take
---taps.
---```lua
---local canvas, width = ui.screen("my-mod", 50)
---print(width) --> 1617.98 on a 3200x2136 screen
---ui.rect(canvas, "my-corner", { width - 120, 1080 - 120 }, { 100, 100 }, ui.colours.red)
---```
---@param name string
---@param order integer
---@return RectTransform canvas
---@return number width
function ui.screen(name, order) end

---A screen of its own over the menus.
---```lua
---local view = ui.view("my-mod")
---button("Open", function()
---  view.show("main")
---  view.part("all", "", function(root)
---    view.back(root, view.hide)
---    view.text(root, { view.left, view.top }, 44, "My mod")
---  end)
---end)
---```
---@param name string
---@return View
function ui.view(name) end

---Whether a point of the screen (pixels) is on a toast, for what reads the touches itself.
---```lua
---for _, touch in ipairs(touches()) do
---  if not ui.toasted(touch.x, touch.y) then press(touch) end
---end
---```
---@param x number
---@param y number
---@return boolean
function ui.toasted(x, y) end

---A player's avatar in a square, from the game's key of it.
---```lua
---ui.avatar(row, "my-avatar", { 40, 48 }, 64, appearance().avatar)
---```
---@param parent Unity
---@param name string
---@param pos Vector
---@param size number
---@param key string
---@return Image
function ui.avatar(parent, name, pos, size, key) end

---A list scrolling like the game's: bars `width` wide go in `list.rows` at `{ -y * slope, -y }`,
---`list.content.sizeDelta`'s y is their height. Without a width it's upright: what's put in rows scrolls straight
---up and down, with a thin bar on its right.
---```lua
---local list = ui.list(root, "my-list", { 200, 30 }, { 1200, 900 }, 1000)
---local slope = CS.SettingItemsManager.InverseSlope
---for i, name in ipairs(names) do
---  local y = (i - 1) * 108
---  view.plate(list.rows, { -y * slope, -y }, { list.width, 96 }, ui.colours.faint, 34, name)
---end
---list.content.sizeDelta = { 0, #names * 108 }
---```
---@param parent Unity
---@param name string
---@param pos Vector
---@param size Vector
---@param width? number
---@return { transform: Unity, content: Unity, rows: Unity, width: number? }
function ui.list(parent, name, pos, size, width) end

---A RawImage looping a video of a url or a file without sound, showing `poster` (a Texture) until it plays.
---```lua
---ui.video(parent, "my-clip", { 0, 0 }, { 640, 360 }, "https://phigros.tools/catalog/clip.mp4")
---```
---@param parent Unity
---@param name string
---@param pos Vector
---@param size Vector
---@param url string
---@param poster? Unity
---@param pivot? Vector
---@return RawImage
function ui.video(parent, name, pos, size, url, poster, pivot) end

---Shows a texture, the image shrinking to its shape.
---```lua
---local shown = ui.place(parent, "my-picture", CS.UnityEngine.UI.RawImage, { 0, 0 }, { 400, 400 })
---ui.fit(shown, phigrospp.texture(phigrospp.read(phigrospp.dir() .. "art.png")))
---```
---@param rawImage Unity
---@param texture Unity
function ui.fit(rawImage, texture) end

---A checkbox.
---```lua
---ui.checkbox(parent, "my-check", font, { 600, 40 }, 32, "Mirror", mirrored, function() mirrored = not mirrored end)
---```
---@param parent Unity
---@param name string
---@param font Unity
---@param pos Vector
---@param size number
---@param label string
---@param checked boolean
---@param fn fun()
function ui.checkbox(parent, name, font, pos, size, label, checked, fn) end

-- # The device

---A Texture2D of a png's or jpg's bytes.
---```lua
---local texture = phigrospp.texture(phigrospp.read(phigrospp.dir() .. "art.png"))
---print(texture.width, texture.height) --> 1024	512
---```
---@param bytes string
---@return Texture2D
function phigrospp.texture(bytes) end

---Android's share sheet for a text, the clipboard on iOS.
---```lua
---button("Share my RKS", function() phigrospp.share(("My RKS is %.2f"):format(rks())) end)
---```
---@param text string
function phigrospp.share(text) end

---Android's file picker for mime types, from a button's function or a coroutine: waits and returns the file's bytes
---(32 MB at most) and name, nothing when the player backs out, nil and why when it can't be read.
---```lua
---button("Import a skin", function()
---  local data, name = phigrospp.pick("application/zip", "application/octet-stream")
---  if not data then return toast(name or "Nothing picked") end -- name is why it couldn't be read
---  print(name, #data) --> skin.zip	2306842
---end)
---```
---@param ... string # mime types
---@return string? data
---@return string name
function phigrospp.pick(...) end

---Whether the device has an Android hardware feature, false on iOS.
---```lua
---print(phigrospp.feature("android.hardware.telephony")) --> false on a tablet
---```
---@param name string # "android.hardware.telephony"
---@return boolean
function phigrospp.feature(name) end

---Asks Android to keep the screen at this rate when idle, none for the fastest.
---```lua
---phigrospp.frameRate(120)
---phigrospp.frameRate() -- the fastest the screen goes
---```
---@param hz? number
function phigrospp.frameRate(hz) end

---The screen's rate now (Hz).
---```lua
---print(phigrospp.refreshRate()) --> 60.000003814697
---```
---@return number
function phigrospp.refreshRate() end

---Android's thermal status, 0 (none) to 6.
---```lua
---if phigrospp.thermal() >= 3 then toast("The device is hot") end
---```
---@return integer
function phigrospp.thermal() end

---The frame rate Unity aims for (`Application.targetFrameRate` can't be read on iOS).
---```lua
---print(phigrospp.targetFrameRate()) --> 240
---```
---@return number
function phigrospp.targetFrameRate() end

---The system and its version, "Android 14" or "iOS 17.5".
---```lua
---print(phigrospp.system()) --> Android 15
---```
---@return string
function phigrospp.system() end

---@type "android"|"ios"
phigrospp.platform = "android"

---Seconds Phigros++ ran on the game's thread since it started.
---```lua
---print(("%.1f s"):format(phigrospp.busy())) --> 147.7 s
---```
---@return number
function phigrospp.busy() end

---Seconds each mod's handlers and hooks took since load, by mod name.
---@type table<string, number>
phigrospp.spent = {}

---Runs `fn` once a finger stayed `seconds` where `on` says a point of the screen (pixels) is.
---```lua
----- holding the pause button for half a second restarts the song
---phigrospp.hold(function(x, y) return playing() and phigrospp.pauseButton(x, y) end, 0.5, phigrospp.restart)
---```
---@param on fun(x: number, y: number): boolean
---@param seconds number
---@param fn fun()
function phigrospp.hold(on, seconds, fn) end

-- # Network

---An HTTP request, `timeout` in seconds (30, 0 for none).
---```lua
---phigrospp.fetch("GET", "https://phigros.tools/api/releases", nil, function(status, body)
---  if status ~= 200 then return toast("Offline") end
---  print(phigrospp.json.decode(body).version) --> 0.3.0-beta.17
---end)
---```
---@param method string
---@param url string
---@param body? string
---@param done fun(status: integer, body: string)
---@param timeout? number
---@return UnityWebRequest # the request, `:Abort()` cancels it
function phigrospp.fetch(method, url, body, done, timeout) end

---@class SocketHandlers
---@field open? fun()
---@field message? fun(text: string)
---@field close? fun() # it ended or never opened

---A WebSocket carrying texts.
---```lua
---local socket
---socket = phigrospp.socket("wss://example.com/live", {
---  open = function() socket.send("hello") end,
---  message = function(text) print(text) end,
---  close = function() print("closed") end,
---})
---```
---@param url string
---@param handlers SocketHandlers
---@return { send: fun(text: string), close: fun() }
function phigrospp.socket(url, handlers) end

---A socket of phigros.tools signed in with the player's key (`domain` goes before what's signed): `heard[t](message)`
---runs for each json object by its `t`, "welcome" first, `closed()` once it ended.
---```lua
---local channel = phigrospp.channel("/api/room", "phigros.tools rooms v1\0", {
---  welcome = function(message) print(message.t) end, --> welcome
---}, function() print("gone") end)
---channel.send({ t = "join", room = "ABCD" })
---```
---@param path string # "/api/room"
---@param domain string
---@param heard table<string, fun(message: table)>
---@param closed function
---@return { send: fun(message: table), close: fun() }
function phigrospp.channel(path, domain, heard, closed) end

-- # Replays

phigrospp.replay = {}

---The replays of a chart on the device, in no particular order: each one's file and header (score, date...).
---```lua
---for _, replay in ipairs(phigrospp.replay.list("Glaciaxion.SunsetRay.0", "IN")) do
---  print(replay.path, replay.header.score)
---end
---```
---@param id string
---@param difficulty Difficulty
---@return { path: string, header: table }[]
function phigrospp.replay.list(id, difficulty) end

---Of a chart's replays, the best for each set of modifiers, by its bits.
---```lua
---local best = phigrospp.replay.bests(phigrospp.replay.list(id, "IN"))
---print(best[0] and best[0].header.score) -- the best without modifiers
---```
---@param list table
---@return table
function phigrospp.replay.bests(list) end

---The frames of the song being played after the first `from`, as a replay of their own, and how many there are now
---(nil, from when none is new): a play streams with it, Rooms sends one twice a second.
---```lua
---local sent = 0
---every(0.5, function()
---  local chunk, count = phigrospp.replay.chunk(sent)
---  if chunk then send(chunk) sent = count end
---end)
---```
---@param from integer
---@return string? chunk
---@return integer count
function phigrospp.replay.chunk(from) end

---Plays another player's stream in game as it comes, nil stops.
---```lua
---phigrospp.replay.follow("ggmolly#4141")
---on("leave", function() phigrospp.replay.follow(nil) end)
---```
---@param tag? string # "name#0042"
function phigrospp.replay.follow(tag) end

---Gives what `follow` plays each `chunk()`: the first starts its chart, `feed()` with nothing says the stream is over.
---```lua
---phigrospp.replay.follow("ggmolly#4141")
---socket = phigrospp.socket(url, {
---  message = function(text) phigrospp.replay.feed(phigrospp.unbase64(text)) end,
---  close = function() phigrospp.replay.feed() end, -- the stream is over
---})
---```
---@param data? string
function phigrospp.replay.feed(data) end

---One more button in the replay player's row, with one of `ui.icon`'s icons, running the function when tapped.
---```lua
---phigrospp.replay.button("skip-back", function()
---  phigrospp.jump(math.max(0, phigrospp.replay.state().frames[phigrospp.replay.state().cursor].t - 5))
---end)
---```
---@param icon Icon
---@param fn fun()
function phigrospp.replay.button(icon, fn) end

---The goods, bads and misses of the replay being watched, in order, `t` in seconds into the chart.
---```lua
---for _, mark in ipairs(phigrospp.replay.marks()) do
---  print(mark.t, mark.judgement) --> 42.5	miss
---end
---```
---@return { t: number, judgement: Judgement }[]
function phigrospp.replay.marks() end

---The replay being watched, nil when none is: `frames` (each one's `t` is its song time) and `cursor`, the frame
---it's at.
---```lua
---local state = phigrospp.replay.state()
---if state then print(state.frames[state.cursor].t) end --> 61.25
---```
---@return { frames: { t: number }[], cursor: integer }?
function phigrospp.replay.state() end

---Stops watching: the song starts again for the player to play.
---```lua
---phigrospp.replay.button("play", phigrospp.replay.takeover) -- play on from where the replay is
---```
function phigrospp.replay.takeover() end

-- # Playing

---A song's chart as it starts.
---@class Chart
---@field id string
---@field name string
---@field difficulty Difficulty
---@field level string # "15"
---@field composer string
---@field charter string
---@field illustrator string
---@field mirror boolean
---@field notes integer

---A judged note.
---@class Hit
---@field judgement Judgement
---@field offset number? # in ms, nil for a miss
---@field combo integer
---@field note "tap"|"drag"|"hold"|"flick"
---@field x number? # screen pixels, nil while a replay is sought
---@field y number?

---The play so far.
---@class Stats
---@field score integer
---@field accuracy number # over the notes judged so far
---@field combo integer
---@field maxcombo integer
---@field fc boolean
---@field ap boolean
---@field perfect integer
---@field good integer
---@field bad integer
---@field miss integer
---@field early integer
---@field late integer

---@class Touch
---@field id integer
---@field phase integer
---@field x number # screen pixels
---@field y number

---The chart being played, or nil.
---```lua
---local chart = playing()
---if chart then print(chart.name, chart.difficulty, chart.level) end --> Glaciaxion	IN	12
---```
---@return Chart?
function playing() end

---The play so far, nil outside of a song.
---```lua
---on("hit", function()
---  local s = stats()
---  print(s.combo, s.score, ("%.2f"):format(s.accuracy)) --> 412	874120	99.31
---end)
---```
---@return Stats?
function stats() end

---This frame's fingers, replayed ones while watching (none while paused).
---```lua
---on("update", function()
---  for _, touch in ipairs(touches()) do print(touch.id, touch.x, touch.y) end --> 0	1520	860
---end)
---```
---@return Touch[]
function touches() end

---True while a replay plays.
---```lua
---on("hit", function(hit)
---  if replaying() then return end -- only the player's own plays
---  count(hit)
---end)
---```
---@return boolean
function replaying() end

---Puts the song being played `t` seconds into its chart, with its music: going forward the game misses the notes
---jumped over, going back the notes from there on come back unjudged, the score stays as it is. The one way to steer a
---song, a replay makes the same jumps. Given `to`, leaves only the notes from `t` to `to` on the field, whichever way
---it goes and with none missed: a section to practise. Given `from`, the music starts there: a lead-in before the
---notes.
---```lua
---phigrospp.jump(42.5)
---phigrospp.jump(42.5, 60)
---phigrospp.jump(40.5, 60, 42.5)
---```
---@param t number
---@param to? number
---@param from? number
function phigrospp.jump(t, to, from) end

---Puts the song being played back at its start in place, every note unjudged and nothing scored, the music waiting
---like a fresh start. In Challenge Mode the run starts again from its first song instead. Returns whether it could:
---not while `phigrospp.pausing()` is false nor in the chapter 9 secret challenge, which the game never retries.
---```lua
---button("Restart", phigrospp.restart)
---on("restart", function() print("again") end)
---```
---@return boolean
function phigrospp.restart() end

---Given false, the song being played can't be paused from its button nor started again until it's left, for a play
---others wait on. Returns whether it can.
---```lua
---on("song", function() phigrospp.pausing(false) end)
---print(phigrospp.pausing()) --> false
---```
---@param allowed? boolean
---@return boolean
function phigrospp.pausing(allowed) end

---How fast the song being played runs until it's left: its music, whose pitch follows, and its notes. Returns it.
---```lua
---phigrospp.speed(0.75)
---print(phigrospp.speed()) --> 0.75
---```
---@param x? number
---@return number
function phigrospp.speed(x) end

---Whether a point of the screen (pixels) is on the pause button.
---```lua
---for _, touch in ipairs(touches()) do
---  if phigrospp.pauseButton(touch.x, touch.y) then print("on pause") end
---end
---```
---@param x number
---@param y number
---@return boolean
function phigrospp.pauseButton(x, y) end

---Whether the song being played counts, false for a replay. A play with modifiers counts: it's recorded, and saves
---nothing either. Given false, it doesn't: not recorded, its result shows without saving.
---```lua
---on("song", function() phigrospp.counts(false) end) -- a practice play saves nothing
---print(phigrospp.counts()) --> false
---```
---@param value? false
---@return boolean
function phigrospp.counts(value) end

---@class Modifier
---@field id string # "HR"
---@field bit integer
---@field name string
---@field percent number
---@field colour Colour
---@field icon string # its picture, an svg's paths: `<path d="M9 7 4 12l5 5..."/>`

phigrospp.modifiers = {}

---The modifiers of the song being played as their bits, 0 for none ([[Modifiers]]), and the seed Random shuffled its
---chart from.
---```lua
---local mods, seed = phigrospp.modifiers.play()
---print(mods, seed) --> 16	83612
---```
---@return integer mods
---@return integer seed
function phigrospp.modifiers.play() end

---The ones the player picked for the next song, sets them when given.
---```lua
---print(phigrospp.modifiers.pick()) --> 0
---phigrospp.modifiers.pick(16 | 8) -- HR and HD for the next song
---```
---@param mask? integer
---@return integer
function phigrospp.modifiers.pick(mask) end

---Every modifier.
---@type Modifier[]
phigrospp.modifiers.list = {}

---The score a play counts for with its modifiers.
---```lua
---print(phigrospp.modifiers.total(1000000, 16)) --> 1060000
---```
---@param score integer
---@param mods integer
---@return integer
function phigrospp.modifiers.total(score, mods) end

---Whether a chart plays with modifiers: one with effects of its own doesn't.
---```lua
---print(phigrospp.modifiers.fits("Glaciaxion.SunsetRay.0", "IN")) --> true
---```
---@param id string
---@param difficulty Difficulty
---@return boolean
function phigrospp.modifiers.fits(id, difficulty) end

---Their plates in a row under parent, each `width` wide.
---```lua
---phigrospp.modifiers.strip(row, 16 | 8, { 20, 30 }, 48)
---```
---@param parent Unity
---@param mods integer
---@param pos Vector
---@param width number
function phigrospp.modifiers.strip(parent, mods, pos, width) end

-- # Songs and the player

---@class Song
---@field id string
---@field name string
---@field composer string
---@field illustrator string
---@field charts table<Difficulty, { constant: number, charter: string, cover: boolean }> # cover: the level has its own illustration
---@field cover Difficulty? # the level whose illustration stands for the song, when each level has its own

---@class Record
---@field id string
---@field difficulty Difficulty
---@field score integer
---@field accuracy number
---@field fc boolean

---Every song of the game.
---```lua
---print(#songs()) --> 329
---for _, s in ipairs(songs()) do
---  if s.charts.AT then print(s.name, s.charts.AT.constant) end
---end
---```
---@return Song[]
function songs() end

---A song of the game, nil for none.
---```lua
---local s = song("Glaciaxion.SunsetRay.0")
---print(s.name, s.composer, s.charts.IN.constant) --> Glaciaxion	SunsetRay	12.6
---```
---@param id string # "Glaciaxion.SunsetRay.0"
---@return Song?
function song(id) end

---Whether the player can play a chart of the game: they have it unlocked.
---```lua
---print(phigrospp.unlocked("Glaciaxion.SunsetRay.0", "IN")) --> true
---```
---@param id string
---@param difficulty Difficulty
---@return boolean
function phigrospp.unlocked(id, difficulty) end

---Starts a chart of the game from any screen as its song list does, with these modifiers (none when left out) instead
---of the player's picks.
---```lua
---button("Play a random IN", function()
---  local list = songs()
---  local s = list[math.random(#list)]
---  if phigrospp.unlocked(s.id, "IN") then phigrospp.play(s.id, "IN") end
---end)
---```
---@param id string
---@param difficulty Difficulty
---@param mods? integer
---@param seed? integer
function phigrospp.play(id, difficulty, mods, seed) end

---The player's RKS, 0 until the game computes it.
---```lua
---print(rks()) --> 11.32875919342
---```
---@return number
function rks() end

---"english"...
---```lua
---print(language()) --> english
---```
---@return string
function language() end

---The player's "name#0042" on phigros.tools, nil without a profile.
---```lua
---print(phigrospp.tag()) --> ggmolly#4141
---```
---@return string?
function phigrospp.tag() end

---Every chart the player has a record on, read from the save.
---```lua
---local r = records()[1]
---print(r.id, r.difficulty, r.score, r.accuracy, r.fc) --> Glaciaxion.SunsetRay.0	EZ	1000000	100.0	true
---```
---@return Record[]
function records() end

---The avatar and background the player picked, "" for the game's.
---```lua
---local look = appearance()
---print(look.avatar, look.background) -->  	ClassMemories.AntistarfeatCtymax.0
---```
---@return { avatar: string, background: string }
function appearance() end

---The game's letter for a score: "φ", "V", "S"... "F".
---```lua
---print(grade(996761, true))   --> V
---print(grade(935000, false))  --> S
---print(grade(1000000, true))  --> φ
---```
---@param score integer
---@param fc boolean
---@return string
function grade(score, fc) end

-- # Cosmetics

--[=[md
Cosmetics take files next to the mod's file. They change how the chart looks, never what it tells the player
([[Skins and hit sounds]]).
]=]

---A chapter of new songs ([[Custom charts]]): `{ code =, title =, cover =, songs = {...} }`, or one described by a
---manifest at a url, signed by the key: `{ url =, key = }`.
---```lua
---chapter{
---  code = "MyPack", title = "My pack", cover = "cover.jpg",
---  songs = {
---    { folder = "song", title = "Song", artist = "Composer", illustrator = "Cover artist",
---      levels = { IN = { difficulty = 13.8, charter = "Me" } } },
---  },
---}
---chapter{ url = "https://example.com/mypack/index.json", key = "<hex ed25519 public key>" }
---```
---@param def table
function chapter(def) end

---Any sound Android plays, for tap (also holds), drag or flick.
---```lua
---hitsound("tap", "tap.ogg")
---hitsound("flick", "flick.wav")
---```
---@param kind "tap"|"drag"|"flick"
---@param file string
function hitsound(kind, file) end

skin = {}

---A note's picture, scaled to fit inside the game's note (a hold's body is as wide and stretched over the hold), or
---the Sprite itself, made from the game's. `tap_multi`... is for notes hit together.
---```lua
---skin.note("tap", "tap.png")
---skin.note("tap_multi", "tap-gold.png")
---skin.note("drag", function(game) return image("drag.png") end)
---```
---@param kind "tap"|"drag"|"flick"|"hold_head"|"hold"|"hold_tail"|"tap_multi"|"drag_multi"|"flick_multi"|"hold_head_multi"|"hold_multi"|"hold_tail_multi"
---@param source string|fun(game: Unity): Unity
function skin.note(kind, source) end

---A texture of `rows` rows from the `height` rows over row `y` of another, for a hold's body as high as the game's.
---```lua
---local body = skin.stretch(phigrospp.texture(phigrospp.read(phigrospp.dir() .. "hold.png")), 40, 8, 512)
---```
---@param texture Unity
---@param y integer
---@param height integer
---@param rows integer
---@return Texture2D
function skin.stretch(texture, y, height, rows) end

---The hit effect: frames from the top left, each `scale` times as wide as the game's, tinted, with or without the
---game's sparks.
---```lua
---skin.effect("hit.png", { columns = 8, rows = 4, seconds = 0.5, scale = 1, perfect = "#ffec9f", good = "#b4e1ff", sparks = false })
---```
---@param file string
---@param options { columns: integer, rows: integer, seconds: number, scale?: number, perfect?: string, good?: string, sparks?: boolean }
function skin.effect(file, options) end

---Judge line colours, the chart keeps its alpha.
---```lua
---skin.line({ ap = "#ffd27f", fc = "#7fd4ff", normal = "#ffffff" })
---```
---@param colours { ap?: string, fc?: string, normal?: string }
function skin.line(colours) end

-- # Helpers

il2cpp = {}

---Sorted class names matching a Lua pattern.
---```lua
---print(table.concat(il2cpp.find("^Score"), ", ")) --> ScoreControl
---```
---@param pattern string
---@return string[]
function il2cpp.find(pattern) end

---Every field and method of a class and its parents, for `print`.
---```lua
---print(il2cpp.describe(CS.ScoreControl))
-----> ScoreControl
----->   UnityEngine.GameObject perfectJudge @0x20
----->   UnityEngine.GameObject goodJudge @0x28
----->   ...
---```
---@param class Unity
---@return string
function il2cpp.describe(class) end

---A class whose name isn't a Lua identifier (`List`1`).
---```lua
---local List = il2cpp.class("System.Collections.Generic.List`1")
---```
---@param name string
---@return Class
function il2cpp.class(name) end

---An object's class.
---```lua
---print(il2cpp.classof(CS.UnityEngine.GameObject("x"))) --> class UnityEngine.GameObject
---local copy = il2cpp.classof(list)() -- a new object of the same class
---```
---@param obj Unity
---@return Class
function il2cpp.classof(obj) end

---Whether an object is of a class or one deriving from it.
---```lua
---if il2cpp.is(loader, CS.AddressableImageLoader) then loader.Code = id end
---```
---@param obj Unity
---@param class Unity
---@return boolean
function il2cpp.is(obj, class) end

---False for nil and for destroyed Unity objects.
---```lua
---on("update", function()
---  if not il2cpp.alive(label) then return end -- its scene is gone
---  label.text = tostring(stats().combo)
---end)
---```
---@param obj Unity?
---@return boolean
function il2cpp.alive(obj) end

---A `System.Type`.
---```lua
---local images = go:GetComponentsInChildren(il2cpp.typeof(CS.UnityEngine.UI.Image), true)
---print(images.Length)
---```
---@param class Unity
---@return System.Type
function il2cpp.typeof(class) end

---A `System.String` object.
---```lua
---local s = il2cpp.string("hello") -- for a method taking an object, where a Lua string wouldn't do
---```
---@param s string
---@return System.String
function il2cpp.string(s) end

---A `byte[]` of a Lua string.
---```lua
---local array = il2cpp.bytes("hi!")
---print(array.Length) --> 3
---```
---@param s string
---@return byte[]
function il2cpp.bytes(s) end

---A Lua string of a `byte[]`.
---```lua
---print(il2cpp.unbytes(CS.System.Text.Encoding.UTF8:GetBytes("hi!"))) --> hi!
---```
---@param array Unity
---@return string
function il2cpp.unbytes(array) end

---Stops the game's garbage collector, or starts it again with a collection (the core stops it during songs).
---```lua
---il2cpp.gc(false) -- no hitch while this runs
---build()
---il2cpp.gc(true)
---```
---@param on boolean
function il2cpp.gc(on) end

---Bytes as lowercase hex.
---```lua
---print(phigrospp.hex("hi!")) --> 686921
---```
---@param s string
---@return string
function phigrospp.hex(s) end

---Hex as bytes.
---```lua
---print(phigrospp.unhex("686921")) --> hi!
---```
---@param s string
---@return string
function phigrospp.unhex(s) end

---Bytes as base64.
---```lua
---print(phigrospp.base64("hi!")) --> aGkh
---```
---@param s string
---@return string
function phigrospp.base64(s) end

---Base64 as bytes.
---```lua
---print(phigrospp.unbase64("aGkh")) --> hi!
---```
---@param s string
---@return string
function phigrospp.unbase64(s) end

phigrospp.crypto = {}

---Whether an Ed25519 signature is the key's (raw bytes).
---```lua
---local ok = phigrospp.crypto.verify(phigrospp.unhex(KEY), data, phigrospp.read(path .. ".sig"))
---if not ok then return toast("Not signed by its author") end
---```
---@param pub string
---@param msg string
---@param sig string
---@return boolean
function phigrospp.crypto.verify(pub, msg, sig) end

---The chart json of a `.phc` file.
---```lua
---local chart = phigrospp.json.decode(phigrospp.phc(phigrospp.read(phigrospp.dir() .. "IN.phc")))
---print(#chart.judgeLineList)
---```
---@param data string
---@return string
function phigrospp.phc(data) end

---The files of a zip, an error for the player when a path leaves the folder or it unpacks to too much.
---```lua
---local files = phigrospp.unzip(data)
---for path, bytes in pairs(files) do print(path, #bytes) end --> skin/tap.png	20431
---```
---@param data string
---@return table<string, string>
function phigrospp.unzip(data) end

---Decodes audio on a thread: `job:poll()` gives nothing until a `float[]`, channels and rate.
---```lua
---local job = phigrospp.decode(phigrospp.dir() .. "tap.ogg")
---local stop
---stop = every(0.1, function()
---  local samples, channels, rate = job:poll()
---  if not samples then return end
---  print(samples.Length, channels, rate) --> 22050	2	44100
---  stop()
---end)
---```
---@param path string
---@return { poll: fun(self): (Unity?, integer, integer) }
function phigrospp.decode(path) end

---The Phigros++ running.
---@type string
phigrospp.version = ""

---The Phigros++ the app came with.
---@type string
phigrospp.app = ""

---The native version the app was built for.
---@type integer
phigrospp.native = 0

---The game version the app was built for.
---@type string
phigrospp.game = ""
