// usage: hooks.ts <ipa> <phigrospp.ios> <signed phigrospp.ios of an older release>, prints the game's methods the
// first pack may hook that a game patched with the older one can't (scripts/ipa.ts), one per line
import { openAsBlob, readFileSync } from "node:fs";
import { hookable } from "./ipa.ts";

const [ipa, pack, older] = process.argv.slice(2);
const game = await openAsBlob(ipa);
const had = new Set(await hookable(game, new Uint8Array(readFileSync(older).subarray(64))));
for (const method of await hookable(game, new Uint8Array(readFileSync(pack))))
  if (!had.has(method)) console.log(method);
