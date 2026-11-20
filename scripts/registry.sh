#!/usr/bin/env bash
# usage: registry.sh [--keygen | --local], publishes registry.txt (the catalog's mods and their authors' keys) to
# phigros.tools, signed with the catalog key's seed (PHIGROSPP_CATALOG_KEY, or the file KEY below). --local only
# writes build/registry.txt and its .sig, --keygen makes the key and prints its public half for phigrospp/lua/mods.lua
set -euo pipefail
MOD=$(dirname "$(dirname "$(realpath "$0")")")
KEY=${XDG_CONFIG_HOME:-$HOME/.config}/phigrospp/catalog.key
SERVER=illustrious:services/phigros-tools/data/catalog/

if [ "${1:-}" = --keygen ]; then
  [ ! -e "$KEY" ] || { echo "$KEY exists, move it away first" >&2; exit 1; }
  mkdir -p "$(dirname "$KEY")"
  (umask 077 && node -e '
    const crypto = require("crypto"), fs = require("fs");
    const { publicKey, privateKey } = crypto.generateKeyPairSync("ed25519");
    fs.writeFileSync(process.argv[1], privateKey.export({ format: "der", type: "pkcs8" }).subarray(-32).toString("hex") + "\n");
    console.log(publicKey.export({ format: "der", type: "spki" }).subarray(-32).toString("hex"));
  ' "$KEY")
  echo "new key: seed in $KEY (back it up offline), its public half above goes in phigrospp/lua/mods.lua"
  exit
fi

[ -n "${PHIGROSPP_CATALOG_KEY:-}" ] || PHIGROSPP_CATALOG_KEY=$(cat "$KEY")
export PHIGROSPP_CATALOG_KEY
mkdir -p "$MOD/build"
# what's published is the lines alone under the publish time, which the game only lets go forward
node -e '
  const crypto = require("crypto"), fs = require("fs");
  const [source, out] = process.argv.slice(1);
  const lines = fs.readFileSync(source, "utf8").split("\n").map((line) => line.trim()).filter((line) => line && !line.startsWith("#"));
  const authors = new Set();
  for (const line of lines) {
    if (/^[a-z0-9-]+:[0-9a-f]{64}$/.test(line)) authors.add(line.split(":")[0]);
    else if (!/^[a-z0-9-]+\/[a-z0-9._-]+$/.test(line)) throw new Error(`registry.txt: ${line} is neither author:key nor author/repo, in lowercase`);
  }
  for (const line of lines) {
    if (line.includes("/") && !authors.has(line.split("/")[0])) throw new Error(`registry.txt: ${line} has no author key`);
  }
  const seed = Buffer.from(process.env.PHIGROSPP_CATALOG_KEY.trim(), "hex");
  const pkcs8 = Buffer.concat([Buffer.from("302e020100300506032b657004220420", "hex"), seed]);
  const key = crypto.createPrivateKey({ key: pkcs8, format: "der", type: "pkcs8" });
  const registry = Buffer.from([`time ${Date.now()}`, ...lines, ""].join("\n"));
  fs.writeFileSync(out, registry);
  fs.writeFileSync(`${out}.sig`, crypto.sign(null, Buffer.concat([Buffer.from("phigros++ mods v1\0"), registry]), key));
  const pub = crypto.createPublicKey(key).export({ format: "der", type: "spki" }).subarray(-32).toString("hex");
  console.log(`${lines.filter((line) => line.includes("/")).length} mods of ${authors.size} authors, signed by ${pub}`);
' "$MOD/registry.txt" "$MOD/build/registry.txt"
[ "${1:-}" = --local ] || rsync -az "$MOD/build/registry.txt" "$MOD/build/registry.txt.sig" "$SERVER"
