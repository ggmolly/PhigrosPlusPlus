#!/usr/bin/env node
// for mod authors (the wiki's Your first mod and Publishing a mod pages), needs only node, and adb for the device.
// a .sig is the public key then the signature of the repo, the tag and the asset's sha-512, so it's only good for this
// release of this mod
import { spawn, spawnSync } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const ROOT = "/sdcard/Android/data/sh.molly.phigrosplusplus/files/phigros++";
const API = "https://github.com/ggmolly/PhigrosPlusPlus/releases/latest/download/api.lua";
const SCRIPT = "https://raw.githubusercontent.com/ggmolly/PhigrosPlusPlus/main/scripts/mod.mjs";
const USAGE = `usage:
  mod.mjs new <name>                         a mod's folder, ready for git, its editor and its releases
  mod.mjs types                              the latest release's api.lua, for the editor
  mod.mjs push [folder or file] [--watch]    copies the mod to the device, again on each change with --watch
  mod.mjs logs                               follows the log
  mod.mjs eval <lua or ->                    runs lua in the game as it is (- reads it from stdin)
  mod.mjs keygen                             a new key: the seed is kept secret (MOD_KEY), the public half goes
                                             in registry.txt
  MOD_KEY=<seed> mod.mjs sign <owner>/<repo> <tag> <mod.zip or mod.lua>   writes the asset's .sig`;
const [command, ...args] = process.argv.slice(2);

function fail(message) {
  console.error(message);
  process.exit(1);
}

function adb(...words) {
  const { status } = spawnSync("adb", words, { stdio: "inherit" });
  if (status !== 0) fail(`adb ${words.join(" ")} failed`);
}

// adb makes what it pushes the shell's, which the app can't open
const own = (target) => adb("shell", `find '${target}' -user shell -exec chmod a+rwX {} +`);

async function types(dir) {
  const response = await fetch(API);
  if (!response.ok) fail(`${API}: ${response.status}`);
  fs.mkdirSync(path.join(dir, ".phigrospp"), { recursive: true });
  fs.writeFileSync(path.join(dir, ".phigrospp/api.lua"), await response.text());
}

function scaffold(name) {
  if (!name) fail(USAGE);
  if (fs.existsSync(name)) fail(`${name} already exists`);
  const files = {
    "init.lua": `local loud = setting("Say hello", true, "${name}")

on("song", function(chart)
  if loud() then toast("Good luck on " .. chart.name) end
end)
`,
    "README.md": `# ${name}

What your mod does, in a sentence or two: the catalog shows this as its description.

![](preview.gif)
`,
    ".luarc.json": `{ "runtime.version": "Lua 5.4", "workspace.library": [".phigrospp"] }\n`,
    ".gitignore": ".phigrospp/\nmod.zip*\n",
    ".github/workflows/release.yml": `# a release of the mod for each tag pushed, signed with the MOD_KEY secret (node mod.mjs keygen)
on:
  push:
    tags: ["*"]
permissions:
  contents: write
jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: zip -r mod.zip . -x '.*' README.md
      - run: curl -fsSLO ${SCRIPT}
      - run: node mod.mjs sign "$GITHUB_REPOSITORY" "$GITHUB_REF_NAME" mod.zip
        env:
          MOD_KEY: \${{ secrets.MOD_KEY }}
      - run: gh release create "$GITHUB_REF_NAME" mod.zip mod.zip.sig --generate-notes
        env:
          GH_TOKEN: \${{ github.token }}
      # the catalog shows the release at once instead of within a quarter of an hour
      - run: curl -sS -X POST https://phigros.tools/api/catalog
`,
  };
  for (const [file, text] of Object.entries(files)) {
    fs.mkdirSync(path.dirname(path.join(name, file)), { recursive: true });
    fs.writeFileSync(path.join(name, file), text);
  }
  return types(name);
}

// a folder goes to mods/<its name>/ without its dot files and README, as its release's zip does, a file to mods/
function push(source = ".", watch) {
  source = path.resolve(source);
  if (!fs.statSync(source).isDirectory()) {
    adb("push", "-q", source, `${ROOT}/mods/`);
    return own(`${ROOT}/mods/${path.basename(source)}`);
  }
  const target = `${ROOT}/mods/${path.basename(source)}`;
  const send = () => {
    const entries = fs.readdirSync(source).filter((e) => !e.startsWith(".") && e !== "README.md");
    adb("push", "-q", ...entries.map((e) => path.join(source, e)), `${target}/`);
    own(target);
    console.log(`pushed ${path.basename(source)}`);
  };
  adb("shell", `rm -rf '${target}' && mkdir -p '${target}'`);
  send();
  if (!watch) return;
  let timer;
  fs.watch(source, { recursive: true }, (_, file) => {
    if (file && file.split(path.sep).some((part) => part.startsWith("."))) return;
    clearTimeout(timer);
    timer = setTimeout(send, 200);
  });
}

// the core runs eval.lua within a second and prints its results then "eval done"
function evaluate(code) {
  if (!code) fail(USAGE);
  const file = path.join(fs.mkdtempSync(path.join(os.tmpdir(), "phigrospp-")), "eval.lua");
  fs.writeFileSync(file, code === "-" ? fs.readFileSync(0) : code);
  adb("logcat", "-c");
  adb("push", "-q", file, `${ROOT}/eval.lua`);
  own(`${ROOT}/eval.lua`);
  const log = spawn("adb", ["logcat", "-s", "phigros++", "-v", "raw"]);
  let rest = "";
  log.stdout.on("data", (chunk) => {
    const lines = (rest + chunk).split("\n");
    rest = lines.pop();
    for (const line of lines) {
      if (line.startsWith("--------- beginning of")) continue;
      if (line.trimEnd() === "eval done") return log.kill();
      console.log(line.trimEnd());
    }
  });
}

const PKCS8 = Buffer.from("302e020100300506032b657004220420", "hex"); // an ed25519 seed's der prefix
const raw = (key) => key.export({ format: "der", type: "spki" }).subarray(-32);

function keygen() {
  const { publicKey, privateKey } = crypto.generateKeyPairSync("ed25519");
  console.log(`MOD_KEY, keep it secret: ${privateKey.export({ format: "der", type: "pkcs8" }).subarray(-32).toString("hex")}`);
  console.log(`public key, for registry.txt: ${raw(publicKey).toString("hex")}`);
}

function sign(repo, tag, asset) {
  if (!asset || !process.env.MOD_KEY) fail(USAGE);
  const key = crypto.createPrivateKey({
    key: Buffer.concat([PKCS8, Buffer.from(process.env.MOD_KEY.trim(), "hex")]),
    format: "der",
    type: "pkcs8",
  });
  const hash = crypto.createHash("sha512").update(fs.readFileSync(asset)).digest();
  const message = Buffer.concat([Buffer.from(`phigros++ mod v1\0${repo.toLowerCase()}\0${tag}\0`), hash]);
  fs.writeFileSync(`${asset}.sig`, Buffer.concat([raw(crypto.createPublicKey(key)), crypto.sign(null, message, key)]));
  console.log(`${asset}.sig: ${repo.toLowerCase()} ${tag}, signed by ${raw(crypto.createPublicKey(key)).toString("hex")}`);
}

const commands = {
  new: () => scaffold(args[0]),
  types: () => types("."),
  push: () => push(args.find((a) => a !== "--watch"), args.includes("--watch")),
  logs: () => adb("logcat", "-s", "phigros++"),
  eval: () => evaluate(args[0]),
  keygen,
  sign: () => sign(...args),
};
if (!commands[command]) fail(USAGE);
await commands[command]();
