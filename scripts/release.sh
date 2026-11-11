#!/usr/bin/env bash
# usage: release.sh [--keygen], signs the bundle into out/ for a github release with the seed in PHIGROSPP_SIGNING_KEY,
# or makes a new key: its seed to stdout, its public half to phigrospp/release.pub
set -euo pipefail
MOD=$(dirname "$(dirname "$(realpath "$0")")")

if [ "${1:-}" = --keygen ]; then
  node -e '
    const crypto = require("crypto"), fs = require("fs");
    const { publicKey, privateKey } = crypto.generateKeyPairSync("ed25519");
    fs.writeFileSync(process.argv[1], publicKey.export({ format: "der", type: "spki" }).subarray(-32).toString("hex") + "\n");
    process.stdout.write(privateKey.export({ format: "der", type: "pkcs8" }).subarray(-32).toString("hex") + "\n");
  ' "$MOD/phigrospp/release.pub"
  exit
fi

: "${PHIGROSPP_SIGNING_KEY:?set it to the hex seed of the release key}"
"$MOD/scripts/bundle.sh"
mkdir -p "$MOD/out"
node -e '
  const crypto = require("crypto"), fs = require("fs");
  const [bundle, trusted, out] = process.argv.slice(1);
  const pkcs8 = Buffer.concat([Buffer.from("302e020100300506032b657004220420", "hex"), Buffer.from(process.env.PHIGROSPP_SIGNING_KEY, "hex")]);
  const key = crypto.createPrivateKey({ key: pkcs8, format: "der", type: "pkcs8" });
  const pub = crypto.createPublicKey(key).export({ format: "der", type: "spki" }).subarray(-32).toString("hex");
  if (pub !== fs.readFileSync(trusted, "ascii").trim()) throw new Error("PHIGROSPP_SIGNING_KEY isnt the key of phigrospp/release.pub");
  const message = fs.readFileSync(bundle);
  fs.writeFileSync(`${out}/phigrospp.bundle`, Buffer.concat([crypto.sign(null, message, key), message]));
  fs.writeFileSync(`${out}/phigrospp.version`, message.subarray(0, message.indexOf(10) + 1));
' "$MOD/build/phigrospp.bundle" "$MOD/phigrospp/release.pub" "$MOD/out"
echo "signed: $MOD/out/phigrospp.bundle ($(head -1 "$MOD/out/phigrospp.version"))"
