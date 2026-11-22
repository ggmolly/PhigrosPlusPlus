// usage: patch_ipa.ts <in.ipa> <out.ipa> <phigrospp.ios>, copies the game's decrypted ipa with phigros++ in it
// (scripts/ipa.ts), from what scripts/build-ios.ts packed
import { execFileSync } from "node:child_process";
import { createWriteStream, openAsBlob, readFileSync } from "node:fs";
import { Readable } from "node:stream";
import { pipeline } from "node:stream/promises";
import { patch } from "./ipa.ts";

const [src, dst, pack] = process.argv.slice(2);
// pillow draws the icons, as it draws android's (scripts/patch_apk.py)
const icon = async (artwork: Uint8Array, size: number) =>
  new Uint8Array(execFileSync("python3", ["-I", `${import.meta.dirname}/icon.py`, `${size}`], { input: artwork }));
const parts = await patch(await openAsBlob(src), new Uint8Array(readFileSync(pack)), icon, (line) => console.log(line));
await pipeline(Readable.fromWeb(new Blob(parts).stream()), createWriteStream(dst));
