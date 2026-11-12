#!/usr/bin/env bash
# writes build/phigrospp.bundle (see bundle.c): the core lua in load order, the recovery words and the built-in mods,
# behind a "phigros++ <native> <version> <games>" line. build-lib.sh and release.sh run this
set -euo pipefail
MOD=$(dirname "$(dirname "$(realpath "$0")")")
SRC=$MOD/phigrospp
CORE="prelude settings net engine identity pages game replayfile replay sync player picker skin update"
mkdir -p "$MOD/build"

node -e '
  const fs = require("fs");
  const [here, mods, out, ...core] = process.argv.slice(1);
  const words = (file) => fs.readFileSync(`${here}/${file}`, "utf8").trim().split(/\s+/).join(" ");
  const files = core.map((name) => [`core/${name}.lua`, `${here}/lua/${name}.lua`]);
  files.push(["words.txt", `${here}/words.txt`]);
  const walk = (dir, prefix) => fs.readdirSync(dir).sort().filter((name) => !/^[._]/.test(name)).forEach((name) => {
    if (fs.statSync(`${dir}/${name}`).isDirectory()) walk(`${dir}/${name}`, `${prefix}${name}/`);
    else files.push([`${prefix}${name}`, `${dir}/${name}`]);
  });
  walk(mods, "mods/");
  const parts = [Buffer.from(`phigros++ ${words("NATIVE")} ${words("VERSION")} ${words("GAMES")}\n`)];
  for (const [name, file] of files) {
    const data = fs.readFileSync(file);
    parts.push(Buffer.from(`${name}\n${data.length}\n`), data);
  }
  fs.writeFileSync(out, Buffer.concat(parts));
' "$SRC" "$MOD/mods" "$MOD/build/phigrospp.bundle" $CORE
