// SvelteKit writes the app shell (index.html) with links from the site's
// root (/_app/...), but authmk mounts the dashboard wherever the app wants
// (/admin/auth/). This makes them relative to the page, then updates the
// Content-Security-Policy hash of the start-up script, which changed with
// them, so the browser still runs it and nothing else.

import { createHash } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";

const file = new URL("../../../priv/licensed/dashboard/index.html", import.meta.url);
let html = readFileSync(file, "utf8");

const before = scripts(html);
html = html.replaceAll('"/_app/', '"./_app/').replaceAll('"/favicon.svg"', '"./favicon.svg"');
const after = scripts(html);

for (const [index, script] of before.entries()) {
  html = html.replace(`'sha256-${hash(script)}'`, `'sha256-${hash(after[index])}'`);
}

if (html.includes('"/_app/')) throw new Error("index.html still has root-relative links");
writeFileSync(file, html);
console.log(`Made ${before.length} script(s) and their links relative in index.html`);

function scripts(text) {
  return [...text.matchAll(/<script>([\s\S]*?)<\/script>/g)].map((match) => match[1]);
}

function hash(text) {
  return createHash("sha256").update(text).digest("base64");
}
