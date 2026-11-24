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

---@alias Difficulty "EZ"|"HD"|"IN"|"AT"
---@alias Judgement "perfect"|"good"|"bad"|"miss"
---`{ r, g, b, a }` from 0 to 1
---@alias Colour number[]
---`{ x, y }`
---@alias Vector number[]
---@alias Icon "arrow-left"|"badge-check"|"check"|"clock"|"crown"|"eye"|"fast-forward"|"lock"|"pause"|"pencil"|"play"|"rewind"|"send"|"skip-back"|"square"|"square-check"|"star"|"trash-2"|"trophy"|"user-plus"|"users"|"x"|string
---A Unity or game object, used with its C# fields and methods.
---@alias Unity any

---@class phigrospp
phigrospp = {}

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
---@param label string|fun(): string
---@param fn fun()
---@param tab? string
---@param shown? fun(): boolean
---@param danger? boolean
function button(label, fn, tab, shown, danger) end

---A label with the game's arrow button, as on its Misc page.
---@param label string|fun(): string
---@param fn fun()
---@param tab? string
---@param shown? fun(): boolean
function link(label, fn, tab, shown) end

---A bar filled from 0 to 1, redrawn every frame: `fn` returns how far along it is and a text for its middle, or
---`{ left =, center =, right = }`.
---@param fn fun(): number, (string|table)?
---@param tab? string
---@param shown? fun(): boolean
function progress(fn, tab, shown) end

---An empty row `height` high that `draw` fills each time the settings are built, for a preview: `area` is its
---RectTransform, as wide as the tab's rows.
---@param height number
---@param draw fun(area: Unity)
---@param tab? string
---@param shown? fun(): boolean
function row(height, draw, tab, shown) end

---A tab shown only while `shown` returns true. The tab "Profile" puts rows on the game's Profile page. Given `draw`,
---the tab draws its page itself each time the settings are built: `view` is a RectTransform as high as the list,
---centred on screen, and `font` the game's.
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
---@return string
function scene() end

---Runs `fn` once in `seconds`.
---@param seconds number
---@param fn fun()
---@return fun() cancel
function after(seconds, fn) end

---Runs `fn` every `seconds`.
---@param seconds number
---@param fn fun()
---@return fun() cancel
function every(seconds, fn) end

---Seconds since the game started.
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
---@param path string
---@return Unity
function image(path) end

---The mod's folder: `installed/<owner>/<name>/`, `mods/<name>/`, or `mods/` for a single file.
---@return string
function phigrospp.dir() end

---A whole file. `bundle/<path>` reads a file of the bundle.
---@param path string
---@return string
function phigrospp.read(path) end

---Writes a whole file, through a temporary one so a crash never leaves half of it.
---@param path string
---@param data string
function phigrospp.write(path, data) end

---The phigros++ folder, where mods keep their files.
---@type string
phigrospp.root = ""

---The app's own folder, which no other app can read.
---@return string
function phigrospp.private() end

---A child by path, the error naming what's missing after a game update.
---@param transform Unity
---@param path string # "A/B"
---@return Unity
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
---@param name "topbar"|"shadows"|"background"|"info"|"cover"|"selected"|"up"|"down"|"back"|"play"
---@return Unity
function Page:part(name) end

---The back button closes the page.
function Page:back() end

---The play button runs `fn`.
---@param fn fun()
function Page:play(fn) end

---The song list's list.
---@param options PageList
function Page:list(options) end

---Slides back.
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
---@param screen string
function View.show(screen) end

---Slides it out.
function View.hide() end

---The panel showing.
---@return string?
function View.shown() end

---Draws a part again only when its key changed.
---@param name string
---@param key any
---@param draw fun(root: Unity)
function View.part(name, key, draw) end

---A text from the middle of its left side.
---@param parent Unity
---@param pos Vector
---@param size number
---@param text string
---@param colour? Colour
---@param alignment? integer # a TextAnchor, MiddleLeft when left out
---@param pivot? Vector
---@param box? number # a width: what goes past it is cut and ends with "..."
---@return Unity
function View.text(parent, pos, size, text, colour, alignment, pivot, box) end

---One of `ui.icon`'s icons.
---@param parent Unity
---@param pos Vector
---@param size number
---@param icon Icon
---@param colour? Colour
---@return Unity
function View.icon(parent, pos, size, icon, colour) end

---A slanted bar with a centred text.
---@param parent Unity
---@param pos Vector
---@param size Vector
---@param colour Colour
---@param fontSize number
---@param label string
---@param ink? Colour
---@return Unity
function View.plate(parent, pos, size, colour, fontSize, label, ink) end

---A button, lit in a colour when given one. Without `fn` it's only a label.
---@param parent Unity
---@param pos Vector
---@param width number
---@param label string
---@param fn? fun()|false
---@param lit? Colour|false
---@return Unity
function View.action(parent, pos, width, label, fn, lit) end

---The back arrow.
---@param root Unity
---@param fn fun()
function View.back(root, fn) end

---Makes anything a button.
---@param shape Unity
---@param fn fun()
function View.tappable(shape, fn) end

---A checkbox ending at `pos`.
---@param parent Unity
---@param pos Vector
---@param label string
---@param checked boolean
---@param fn fun()
function View.checkbox(parent, pos, label, checked, fn) end

---The top bar's titles for screens that go together: `pick(title)` runs when another one's is tapped.
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
---@param name Icon
---@return Unity
function ui.icon(name) end

---A copy of a game button moved by an offset, running `fn` instead.
---@param button Unity
---@param offset Vector
---@param fn fun()
---@return Unity
function ui.clone(button, offset, fn) end

---A copy of a play button `slot` slots left of it, showing a sprite.
---@param play Unity
---@param slot integer
---@param sprite Unity
---@param fn fun()
---@return Unity
function ui.sideButton(play, slot, sprite, fn) end

---A switch like the song list's Mirror one, after it and those already there: lit while `lit` says so, `fn` runs on
---a tap.
---@param label string
---@param lit fun(): boolean
---@param fn fun()
function ui.switch(label, lit, fn) end

---A tab left of the chapter screen's settings and of those already there, showing an icon: asked for at each
---"ChapterSelector" scene.
---@param icon Icon
---@param fn fun()
function ui.shortcut(icon, fn) end

---Slides the song list out to the left and an empty page in.
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
---@param parent Unity
---@param name string
---@param pos Vector
---@param size Vector
---@param colour Colour
---@return Unity
function ui.bar(parent, name, pos, size, colour) end

---A song's illustration cut to fill such a bar, what's put in it is cut to its shape too. It's the level's own when
---the level has one. A few songs have one per
---level: given a level, it's that level's.
---@param parent Unity
---@param name string
---@param pos Vector
---@param size Vector
---@param id string # the song's id
---@param level? Difficulty
---@return Unity
function ui.cover(parent, name, pos, size, id, level) end

---A screen sliding in over a canvas and its shade.
---@param canvas Unity
---@param name string
---@param closed? function
---@param shade? number # how dark it is (0.85), for a screen whose texts go over what's under
---@return Panel
function ui.panel(canvas, name, closed, shade) end

---A canvas over everything in any scene, 1080 units high like the game's menus and `width` wide, whose buttons take
---taps.
---@param name string
---@param order integer
---@return Unity canvas
---@return number width
function ui.screen(name, order) end

---A screen of its own over the menus.
---@param name string
---@return View
function ui.view(name) end

---Whether a point of the screen (pixels) is on a toast, for what reads the touches itself.
---@param x number
---@param y number
---@return boolean
function ui.toasted(x, y) end

---A player's avatar in a square, from the game's key of it.
---@param parent Unity
---@param name string
---@param pos Vector
---@param size number
---@param key string
---@return Unity
function ui.avatar(parent, name, pos, size, key) end

---A list scrolling like the game's: bars `width` wide go in `list.rows` at `{ -y * slope, -y }`,
---`list.content.sizeDelta`'s y is their height. Without a width it's upright: what's put in rows scrolls straight
---up and down, with a thin bar on its right.
---@param parent Unity
---@param name string
---@param pos Vector
---@param size Vector
---@param width? number
---@return { transform: Unity, content: Unity, rows: Unity, width: number? }
function ui.list(parent, name, pos, size, width) end

---A RawImage looping a video of a url or a file without sound, showing `poster` (a Texture) until it plays.
---@param parent Unity
---@param name string
---@param pos Vector
---@param size Vector
---@param url string
---@param poster? Unity
---@param pivot? Vector
---@return Unity
function ui.video(parent, name, pos, size, url, poster, pivot) end

---Shows a texture, the image shrinking to its shape.
---@param rawImage Unity
---@param texture Unity
function ui.fit(rawImage, texture) end

---A checkbox.
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
---@param bytes string
---@return Unity
function phigrospp.texture(bytes) end

---Android's share sheet for a text, the clipboard on iOS.
---@param text string
function phigrospp.share(text) end

---Android's file picker for mime types, from a button's function or a coroutine: waits and returns the file's bytes
---(32 MB at most) and name, nothing when the player backs out, nil and why when it can't be read.
---@param ... string # mime types
---@return string? data
---@return string name
function phigrospp.pick(...) end

---Whether the device has an Android hardware feature, false on iOS.
---@param name string # "android.hardware.telephony"
---@return boolean
function phigrospp.feature(name) end

---Asks Android to keep the screen at this rate when idle, none for the fastest.
---@param hz? number
function phigrospp.frameRate(hz) end

---The screen's rate now (Hz).
---@return number
function phigrospp.refreshRate() end

---Android's thermal status, 0 (none) to 6.
---@return integer
function phigrospp.thermal() end

---The frame rate Unity aims for (`Application.targetFrameRate` can't be read on iOS).
---@return number
function phigrospp.targetFrameRate() end

---The system and its version, "Android 14" or "iOS 17.5".
---@return string
function phigrospp.system() end

---@type "android"|"ios"
phigrospp.platform = "android"

---Seconds Phigros++ ran on the game's thread since it started.
---@return number
function phigrospp.busy() end

---Seconds each mod's handlers and hooks took since load, by mod name.
---@type table<string, number>
phigrospp.spent = {}

---Runs `fn` once a finger stayed `seconds` where `on` says a point of the screen (pixels) is.
---@param on fun(x: number, y: number): boolean
---@param seconds number
---@param fn fun()
function phigrospp.hold(on, seconds, fn) end

-- # Network

---An HTTP request, `timeout` in seconds (30, 0 for none).
---@param method string
---@param url string
---@param body? string
---@param done fun(status: integer, body: string)
---@param timeout? number
---@return Unity # the UnityWebRequest
function phigrospp.fetch(method, url, body, done, timeout) end

---@class SocketHandlers
---@field open? fun()
---@field message? fun(text: string)
---@field close? fun() # it ended or never opened

---A WebSocket carrying texts.
---@param url string
---@param handlers SocketHandlers
---@return { send: fun(text: string), close: fun() }
function phigrospp.socket(url, handlers) end

---A socket of phigros.tools signed in with the player's key (`domain` goes before what's signed): `heard[t](message)`
---runs for each json object by its `t`, "welcome" first, `closed()` once it ended.
---@param path string # "/api/room"
---@param domain string
---@param heard table<string, fun(message: table)>
---@param closed function
---@return { send: fun(message: table), close: fun() }
function phigrospp.channel(path, domain, heard, closed) end

-- # Replays

phigrospp.replay = {}

---Of a chart's replays, the best for each set of modifiers, by its bits.
---@param list table
---@return table
function phigrospp.replay.bests(list) end

---The frames of the song being played after the first `from`, as a replay of their own, and how many there are now
---(nil, from when none is new): a play streams with it, Rooms sends one twice a second.
---@param from integer
---@return string? chunk
---@return integer count
function phigrospp.replay.chunk(from) end

---Plays another player's stream in game as it comes, nil stops.
---@param tag? string # "name#0042"
function phigrospp.replay.follow(tag) end

---Gives what `follow` plays each `chunk()`: the first starts its chart, `feed()` with nothing says the stream is over.
---@param data? string
function phigrospp.replay.feed(data) end

---One more button in the replay player's row, with one of `ui.icon`'s icons, running the function when tapped.
---@param icon Icon
---@param fn fun()
function phigrospp.replay.button(icon, fn) end

---The goods, bads and misses of the replay being watched, in order, `t` in seconds into the chart.
---@return { t: number, judgement: Judgement }[]
function phigrospp.replay.marks() end

---The replay being watched, nil when none is: `frames` (each one's `t` is its song time) and `cursor`, the frame
---it's at.
---@return { frames: { t: number }[], cursor: integer }?
function phigrospp.replay.state() end

---Stops watching: the song starts again for the player to play.
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
---@return Chart?
function playing() end

---The play so far, nil outside of a song.
---@return Stats?
function stats() end

---This frame's fingers, replayed ones while watching (none while paused).
---@return Touch[]
function touches() end

---True while a replay plays.
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
---like a fresh start.
function phigrospp.restart() end

---Given false, the song being played can't be paused from its button nor started again until it's left, for a play
---others wait on. Returns whether it can.
---@param allowed? boolean
---@return boolean
function phigrospp.pausing(allowed) end

---How fast the song being played runs until it's left: its music, whose pitch follows, and its notes. Returns it.
---@param x? number
---@return number
function phigrospp.speed(x) end

---Whether a point of the screen (pixels) is on the pause button.
---@param x number
---@param y number
---@return boolean
function phigrospp.pauseButton(x, y) end

---Whether the song being played counts, false for a replay. A play with modifiers counts: it's recorded, and saves
---nothing either. Given false, it doesn't: not recorded, its result shows without saving.
---@param value? false
---@return boolean
function phigrospp.counts(value) end

---@class Modifier
---@field id string # "HR"
---@field bit integer
---@field name string
---@field percent number
---@field colour Colour
---@field icon Icon

phigrospp.modifiers = {}

---The modifiers of the song being played as their bits, 0 for none ([[Modifiers]]), and the seed Random shuffled its
---chart from.
---@return integer mods
---@return integer seed
function phigrospp.modifiers.play() end

---The ones the player picked for the next song, sets them when given.
---@param mask? integer
---@return integer
function phigrospp.modifiers.pick(mask) end

---Every modifier.
---@type Modifier[]
phigrospp.modifiers.list = {}

---The score a play counts for with its modifiers.
---@param score integer
---@param mods integer
---@return integer
function phigrospp.modifiers.total(score, mods) end

---Whether a chart plays with modifiers: one with effects of its own doesn't.
---@param id string
---@param difficulty Difficulty
---@return boolean
function phigrospp.modifiers.fits(id, difficulty) end

---Their plates in a row under parent, each `width` wide.
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
---@return Song[]
function songs() end

---A song of the game, nil for none.
---@param id string # "Glaciaxion.SunsetRay.0"
---@return Song?
function song(id) end

---Whether the player can play a chart of the game: they have it unlocked.
---@param id string
---@param difficulty Difficulty
---@return boolean
function phigrospp.unlocked(id, difficulty) end

---Starts a chart of the game from any screen as its song list does, with these modifiers (none when left out) instead
---of the player's picks.
---@param id string
---@param difficulty Difficulty
---@param mods? integer
---@param seed? integer
function phigrospp.play(id, difficulty, mods, seed) end

---The player's RKS, 0 until the game computes it.
---@return number
function rks() end

---"english"...
---@return string
function language() end

---The player's "name#0042" on phigros.tools, nil without a profile.
---@return string?
function phigrospp.tag() end

---Every chart the player has a record on, read from the save.
---@return Record[]
function records() end

---The avatar and background the player picked, "" for the game's.
---@return { avatar: string, background: string }
function appearance() end

---The game's letter for a score: "φ", "V", "S"... "F".
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
---@param def table
function chapter(def) end

---Any sound Android plays, for tap (also holds), drag or flick.
---@param kind "tap"|"drag"|"flick"
---@param file string
function hitsound(kind, file) end

skin = {}

---A note's picture, scaled to fit inside the game's note (a hold's body is as wide and stretched over the hold), or
---the Sprite itself, made from the game's. `tap_multi`... is for notes hit together.
---@param kind "tap"|"drag"|"flick"|"hold_head"|"hold"|"hold_tail"|"tap_multi"|"drag_multi"|"flick_multi"|"hold_head_multi"|"hold_multi"|"hold_tail_multi"
---@param source string|fun(game: Unity): Unity
function skin.note(kind, source) end

---A texture of `rows` rows from the `height` rows over row `y` of another, for a hold's body as high as the game's.
---@param texture Unity
---@param y integer
---@param height integer
---@param rows integer
---@return Unity
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
---@param colours { ap?: string, fc?: string, normal?: string }
function skin.line(colours) end

-- # Helpers

il2cpp = {}

---Sorted class names matching a Lua pattern.
---@param pattern string
---@return string[]
function il2cpp.find(pattern) end

---Every field and method of a class and its parents, for `print`.
---@param class Unity
---@return string
function il2cpp.describe(class) end

---A class whose name isn't a Lua identifier (`List`1`).
---@param name string
---@return Unity
function il2cpp.class(name) end

---An object's class.
---@param obj Unity
---@return Unity
function il2cpp.classof(obj) end

---Whether an object is of a class or one deriving from it.
---@param obj Unity
---@param class Unity
---@return boolean
function il2cpp.is(obj, class) end

---False for nil and for destroyed Unity objects.
---@param obj Unity?
---@return boolean
function il2cpp.alive(obj) end

---A `System.Type`.
---@param class Unity
---@return Unity
function il2cpp.typeof(class) end

---A `System.String` object.
---@param s string
---@return Unity
function il2cpp.string(s) end

---A `byte[]` of a Lua string.
---@param s string
---@return Unity
function il2cpp.bytes(s) end

---A Lua string of a `byte[]`.
---@param array Unity
---@return string
function il2cpp.unbytes(array) end

---Stops the game's garbage collector, or starts it again with a collection (the core stops it during songs).
---@param on boolean
function il2cpp.gc(on) end

---Bytes as lowercase hex.
---@param s string
---@return string
function phigrospp.hex(s) end

---Hex as bytes.
---@param s string
---@return string
function phigrospp.unhex(s) end

---Bytes as base64.
---@param s string
---@return string
function phigrospp.base64(s) end

---Base64 as bytes.
---@param s string
---@return string
function phigrospp.unbase64(s) end

phigrospp.crypto = {}

---Whether an Ed25519 signature is the key's (raw bytes).
---@param pub string
---@param msg string
---@param sig string
---@return boolean
function phigrospp.crypto.verify(pub, msg, sig) end

---The chart json of a `.phc` file.
---@param data string
---@return string
function phigrospp.phc(data) end

---The files of a zip, an error for the player when a path leaves the folder or it unpacks to too much.
---@param data string
---@return table<string, string>
function phigrospp.unzip(data) end

---Decodes audio on a thread: `job:poll()` gives nothing until a `float[]`, channels and rate.
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
