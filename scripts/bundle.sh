#!/usr/bin/env bash
# writes build/phigrospp.bundle (see bundle.c): the core lua in load order, the recovery words, the file picker's dex
# (make builds it) and the built-in mods, behind a "phigros++ <native> <version> <platform>:<game>... hooks:<version>" line.
# build-lib.sh and release.sh run this
set -euo pipefail
MOD=$(dirname "$(dirname "$(realpath "$0")")")
SRC=$MOD/phigrospp
CORE="prelude ios settings net engine android icons toast screens identity pages game modifiers replayfile replay charts sync player picker leaderboard skin update mods catalog"
mkdir -p "$MOD/build"

node -e '
  const fs = require("fs");
  const [here, mods, out, ...core] = process.argv.slice(1);
  const words = (file) => fs.readFileSync(`${here}/${file}`, "utf8").trim().split(/\s+/).join(" ");
  const files = core.map((name) => [`core/${name}.lua`, `${here}/lua/${name}.lua`]);
  files.push(["HOOKS", `${here}/HOOKS`], ["words.txt", `${here}/words.txt`],
    ["picker.dex", `${here}/../build/picker.dex`]);
  const walk = (dir, prefix) => fs.readdirSync(dir).sort().filter((name) => !/^[._]/.test(name)).forEach((name) => {
    if (fs.statSync(`${dir}/${name}`).isDirectory()) walk(`${dir}/${name}`, `${prefix}${name}/`);
    else files.push([`${prefix}${name}`, `${dir}/${name}`]);
  });
  walk(mods, "mods/");
  const header = `phigros++ ${words("NATIVE")} ${words("VERSION")} ${words("GAMES")} hooks:${words("HOOKS")}\n`;
  const parts = [Buffer.from(header)];
  for (const [name, file] of files) {
    const data = fs.readFileSync(file);
    parts.push(Buffer.from(`${name}\n${data.length}\n`), data);
  }
  fs.writeFileSync(out, Buffer.concat(parts));
' "$SRC" "$MOD/mods" "$MOD/build/phigrospp.bundle" $CORE
