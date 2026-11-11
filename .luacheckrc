-- nix-shell -p lua54Packages.luacheck --run 'luacheck phigrospp/lua mods'
std = "lua54"
max_line_length = false
-- the bridge and the core api
globals = {
  "__il2cpp", "__phigrospp_emit", "CS", "il2cpp", "hook", "unhook", "on", "now", "phigrospp", "setting",
  "after", "every", "scene", "toast", "image", "songs", "song", "playing", "stats", "rks", "language", "button",
  "skin", "hitsound", "touches", "replaying", "grade", "tab", "records", "appearance", "progress", "link",
}
