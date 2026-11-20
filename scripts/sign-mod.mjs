#!/usr/bin/env node
// for mod authors (the wiki's Publishing a mod page), needs only node:
//   sign-mod.mjs --keygen                                      a new key: the seed is kept secret (MOD_KEY), the public
//                                                              half goes in registry.txt
//   MOD_KEY=<seed> sign-mod.mjs <owner>/<repo> <tag> <asset>   writes <asset>.sig for mod.zip or mod.lua
// the .sig is the public key then the signature of the repo, the tag and the asset's sha-512, so it's only good for
// this release of this mod
import crypto from "node:crypto";
import fs from "node:fs";

const PKCS8 = Buffer.from("302e020100300506032b657004220420", "hex"); // an ed25519 seed's der prefix
const raw = (key) => key.export({ format: "der", type: "spki" }).subarray(-32);
const [repo, tag, asset] = process.argv.slice(2);

if (repo === "--keygen") {
  const { publicKey, privateKey } = crypto.generateKeyPairSync("ed25519");
  console.log(`MOD_KEY, keep it secret: ${privateKey.export({ format: "der", type: "pkcs8" }).subarray(-32).toString("hex")}`);
  console.log(`public key, for registry.txt: ${raw(publicKey).toString("hex")}`);
  process.exit();
}
if (!asset || !process.env.MOD_KEY) {
  console.error("usage: MOD_KEY=<seed> sign-mod.mjs <owner>/<repo> <tag> <mod.zip or mod.lua>\n       sign-mod.mjs --keygen");
  process.exit(1);
}
const key = crypto.createPrivateKey({
  key: Buffer.concat([PKCS8, Buffer.from(process.env.MOD_KEY.trim(), "hex")]),
  format: "der",
  type: "pkcs8",
});
const hash = crypto.createHash("sha512").update(fs.readFileSync(asset)).digest();
const message = Buffer.concat([Buffer.from(`phigros++ mod v1\0${repo.toLowerCase()}\0${tag}\0`), hash]);
fs.writeFileSync(`${asset}.sig`, Buffer.concat([raw(crypto.createPublicKey(key)), crypto.sign(null, message, key)]));
console.log(`${asset}.sig: ${repo.toLowerCase()} ${tag}, signed by ${raw(crypto.createPublicKey(key)).toString("hex")}`);
