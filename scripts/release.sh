#!/usr/bin/env bash
# usage: release.sh [--keygen], signs a release into out/ with the release key's seed (PHIGROSPP_SIGNING_KEY, or the
# file KEY below), or makes a new key: its seed to KEY, its public half to phigrospp/release.pub
set -euo pipefail
MOD=$(dirname "$(dirname "$(realpath "$0")")")
KEY=${XDG_CONFIG_HOME:-$HOME/.config}/phigrospp/release.key

if [ "${1:-}" = --keygen ]; then
  [ ! -e "$KEY" ] || { echo "$KEY exists, move it away first" >&2; exit 1; }
  mkdir -p "$(dirname "$KEY")"
  (umask 077 && node -e '
    const crypto = require("crypto"), fs = require("fs");
    const { publicKey, privateKey } = crypto.generateKeyPairSync("ed25519");
    fs.writeFileSync(process.argv[1], publicKey.export({ format: "der", type: "spki" }).subarray(-32).toString("hex") + "\n");
    fs.writeFileSync(process.argv[2], privateKey.export({ format: "der", type: "pkcs8" }).subarray(-32).toString("hex") + "\n");
  ' "$MOD/phigrospp/release.pub" "$KEY")
  echo "new key: seed in $KEY (back it up offline), public half in phigrospp/release.pub"
  exit
fi

[ -n "${PHIGROSPP_SIGNING_KEY:-}" ] || PHIGROSPP_SIGNING_KEY=$(cat "$KEY")
export PHIGROSPP_SIGNING_KEY
[ -f "$MOD/build/libphigrospp.so" ] || { echo "build/libphigrospp.so is missing, run make lib" >&2; exit 1; }
"$MOD/scripts/bundle.sh"
mkdir -p "$MOD/out"
cp "$MOD/build/libphigrospp.so" "$MOD/out/libphigrospp.so"
# the bundle, its first line, and for the installer (patcher/) a manifest of what it patches the game with:
# "phigros++ installer 1", then "version", "native", "games" and "lib <sha256> <size>" lines
node -e '
  const crypto = require("crypto"), fs = require("fs");
  const [bundle, trusted, out] = process.argv.slice(1);
  const seed = Buffer.from(process.env.PHIGROSPP_SIGNING_KEY.trim(), "hex");
  const pkcs8 = Buffer.concat([Buffer.from("302e020100300506032b657004220420", "hex"), seed]);
  const key = crypto.createPrivateKey({ key: pkcs8, format: "der", type: "pkcs8" });
  const pub = crypto.createPublicKey(key).export({ format: "der", type: "spki" }).subarray(-32).toString("hex");
  if (pub !== fs.readFileSync(trusted, "ascii").trim()) throw new Error("the signing key isnt the key of phigrospp/release.pub");
  const sign = (message) => Buffer.concat([crypto.sign(null, message, key), message]);
  const message = fs.readFileSync(bundle);
  const [, native, version, ...games] = message.subarray(0, message.indexOf(10)).toString().split(" ");
  const lib = fs.readFileSync(`${out}/libphigrospp.so`);
  const manifest = ["phigros++ installer 1", `version ${version}`, `native ${native}`, `games ${games.join(" ")}`,
    `lib ${crypto.createHash("sha256").update(lib).digest("hex")} ${lib.length}`, ""].join("\n");
  fs.writeFileSync(`${out}/phigrospp.bundle`, sign(message));
  fs.writeFileSync(`${out}/phigrospp.version`, message.subarray(0, message.indexOf(10) + 1));
  fs.writeFileSync(`${out}/phigrospp.installer`, sign(Buffer.from(manifest)));
' "$MOD/build/phigrospp.bundle" "$MOD/phigrospp/release.pub" "$MOD/out"
echo "signed: $MOD/out/ ($(head -1 "$MOD/out/phigrospp.version"))"
