// usage: build-ios.ts <out> <sources...>, packs what scripts/ipa.ts patches the game's ipa with, none of it from the
// game: behind a "phigros++ ios 1 <version>" line, "<name>\n<size>\n<bytes>" per file as in a bundle. "hooks" is the
// strings and the names of the sources, which say the methods they may hook, then comes the library for each ios
// game of phigrospp/GAMES, named by its version. the 1 is what the pack needs of the patcher
import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";

const [out, ...sources] = process.argv.slice(2);
const mod = `${import.meta.dirname}/..`;
// the strings of a lua or c file, skipping comments (the other groups are delimiters)
const LUA = /--\[(=*)\[.*?\]\1\]|--[^\n]*|"((?:[^"\\\n]|\\.)*)"|'((?:[^'\\\n]|\\.)*)'|\[(=*)\[(.*?)\]\4\]/gsu;
const C = /\/\/[^\n]*|\/\*.*?\*\/|'(?:[^'\\\n]|\\.)*'|"((?:[^"\\\n]|\\.)*)"/gsu;
const NAME = "[A-Za-z_][\\p{L}\\p{N}_]*";

const strings = new Set<string>();
const names = new Set<string>();
for (const path of sources) {
  const text = readFileSync(path, "utf8");
  const lua = path.endsWith(".lua");
  for (const [name] of text.matchAll(new RegExp(NAME, "gu"))) names.add(name);
  for (const match of text.matchAll(lua ? LUA : C))
    for (const group of lua ? [2, 3, 5] : [1]) if (match[group]) strings.add(match[group]);
  // table keys name methods too ({ get_width = "width" })
  for (const [, key] of lua ? text.matchAll(new RegExp(`(${NAME})\\s*=(?!=)`, "gu")) : []) strings.add(key);
}

const files: [string, Uint8Array][] = [
  ["hooks", Buffer.from(JSON.stringify({ strings: [...strings].sort(), names: [...names].sort() }))],
];
for (const game of readFileSync(`${mod}/phigrospp/GAMES`, "utf8").match(/^ios:.+$/gm) ?? []) {
  execFileSync(`${mod}/scripts/build-lib.sh`, [game], { stdio: "inherit" });
  files.push([game.slice(4), readFileSync(`${mod}/build/libphigrospp.dylib`)]);
}
const version = readFileSync(`${mod}/phigrospp/VERSION`, "utf8").trim();
writeFileSync(
  out,
  Buffer.concat([
    Buffer.from(`phigros++ ios 1 ${version}\n`),
    ...files.flatMap(([name, data]) => [Buffer.from(`${name}\n${data.length}\n`), data]),
  ]),
);
console.log(`packed: ${out} (${files.map(([name]) => name).join(", ")})`);
