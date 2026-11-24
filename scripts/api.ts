// usage: api.ts [page], renders the wiki's Mod API page from api.lua: `-- # Title` lines are its headings, --[=[md blocks
// are copied, each function, value and class gets its signature, description and the params or fields that say
// something (after a #). also tells the .luacheckrc globals api.lua doesn't declare
import { readFileSync, writeFileSync } from "node:fs";

const mod = `${import.meta.dirname}/..`;
const [page = `${mod}/../PhigrosPlusPlus.wiki/Mod-API.md`] = process.argv.slice(2);
const source = readFileSync(`${mod}/api.lua`, "utf8");

// the names of a parameter list, at depth 0 only: "a: fun(b: T), c?: U" gives a, c?
function names(list: string) {
  const parts: string[] = [];
  let depth = 0, start = 0;
  for (let i = 0; i <= list.length; i++) {
    const c = list[i];
    if (c === "(" || c === "{" || c === "<") depth++;
    else if (c === ")" || c === "}" || c === ">") depth--;
    else if ((c === "," && depth === 0) || i === list.length) {
      parts.push(list.slice(start, i).split(":")[0].trim());
      start = i + 1;
    }
  }
  return parts.filter(Boolean).join(", ");
}

const out = ["# Mod API", ""];
let text: string[] = [], items: string[] = [], signatures: string[] = [], optional = new Set<string>(), type = "";

function flush(name: string, args?: string) {
  if (args !== undefined) {
    const own = `${name}(${args.split(", ").filter(Boolean).map((a) => (optional.has(a) ? `${a}?` : a)).join(", ")})`;
    signatures.unshift(own);
  }
  const heads = [...new Set(signatures.length ? signatures : [name])];
  if (text.length || items.length || args !== undefined || type) {
    out.push(`### ${heads.map((h) => `\`${h}\``).join(" ")}`, "");
    if (type) out.push(`\`${type}\``, "");
    if (text.length) out.push(...text, "");
    if (items.length) out.push(...items, "");
  }
  text = [], items = [], signatures = [], optional = new Set(), type = "";
}

let md = false, cls = "";
for (const line of source.split("\n")) {
  if (md) {
    if (line === "]=]") md = false;
    out.push(md ? line : "");
    continue;
  }
  let m;
  if (line === "--[=[md") md = true;
  else if ((m = line.match(/^-- # (.*)/))) out.push(`## ${m[1]}`, "");
  else if ((m = line.match(/^---@class (\S+)/))) cls = m[1];
  else if ((m = line.match(/^---@(param|field|return) (.*?)(?: # (.*))?$/))) {
    const [, tag, spec, description] = m;
    if (tag === "param" && spec.split(" ")[0].endsWith("?")) optional.add(spec.split(" ")[0].slice(0, -1));
    // a param or field is "name type", a return "type name"
    const [first, ...rest] = spec.split(" ");
    const [name, kind] = tag === "return" ? ["returns", first] : [`\`${first}\``, rest.join(" ")];
    if (description || tag === "field") items.push(`- ${name} \`${kind}\`${description ? `: ${description}` : ""}`);
  } else if ((m = line.match(/^---@overload fun\((.*)\)/))) {
    const call = m[1].replace(/\):.*$/, "");
    signatures.push(`NAME(${names(call)})`);
  } else if ((m = line.match(/^---@type (.*)/))) type = m[1];
  else if (line.startsWith("---@alias")) text = [];
  else if (line.startsWith("---@") || line.startsWith("---|")) continue;
  else if (line.startsWith("---")) text.push(line.slice(3));
  else if ((m = line.match(/^function ([\w.:]+)\((.*)\)/))) {
    signatures = signatures.map((s) => s.replace("NAME", m[1]));
    flush(m[1], names(m[2]));
  } else if (cls) {
    flush(cls);
    cls = "";
  } else if ((m = line.match(/^([\w.]+) = /)) && (text.length || type)) flush(m[1]);
  else text = [], items = [], type = "";
}
writeFileSync(page, out.join("\n").replace(/\n{3,}/g, "\n\n").trimEnd() + "\n");

const globals = readFileSync(`${mod}/.luacheckrc`, "utf8").match(/globals = \{([^}]*)\}/)![1].match(/"(\w+)"/g)!;
for (const g of globals.map((q) => q.slice(1, -1))) {
  if (!g.startsWith("__") && g !== "require" && !new RegExp(`^(function ${g}\\(|${g} = )`, "m").test(source)) {
    console.error(`api.lua doesn't declare ${g}`);
  }
}
