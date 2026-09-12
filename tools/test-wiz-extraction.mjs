#!/usr/bin/env node
/**
 * Runs the session-parameter extraction from
 * App/Translation/GeminiWebTransport.swift against a stubbed DOM.
 *
 * This exists because that script is the single thing that decides whether the app
 * can translate at all, it only ever runs on a device, and it has already failed
 * once in a way no compiler could catch: written literally in the Swift source, the
 * regex that un-escapes inline JSON lost one level of backslash and silently
 * matched nothing.
 *
 * Run with any JS runtime that can read files, e.g.
 *     node tools/test-wiz-extraction.mjs
 *     bun  tools/test-wiz-extraction.mjs
 */
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const source = readFileSync(join(here, "..", "App/Translation/GeminiWebTransport.swift"), "utf8");

const marker = 'let script = """';
const start = source.indexOf(marker);
if (start < 0) throw new Error("readWizParameters script not found");
const body = source.slice(start + marker.length, source.indexOf('"""', start + marker.length));

const substitutions = [
  [String.raw`\(config.wizAt)`, "SNlM0e"],
  [String.raw`\(config.wizBuild)`, "cfb2h"],
  [String.raw`\(config.wizSession)`, "FdrFJe"],
  [String.raw`\(config.wizLang)`, "TuX5cc"],
];
let script = body;
for (const [from, to] of substitutions) script = script.split(`"${from}"`).join(`"${to}"`);
const leftover = script.match(/\\\([^)]*\)/g);
if (leftover) throw new Error(`unsubstituted interpolations: ${leftover.join(", ")}`);

function environment({ global, scripts = [], html = "", fetched = null }) {
  return {
    window: { WIZ_global_data: global },
    document: {
      scripts: scripts.map((textContent) => ({ textContent })),
      documentElement: { innerHTML: html },
      title: "Gemini",
    },
    location: { href: "https://gemini.google.com/app", origin: "https://gemini.google.com" },
    fetch: async () => {
      if (fetched === null) throw new Error("offline");
      return { text: async () => fetched };
    },
  };
}

async function extract(name, env) {
  const call = new Function("window", "document", "location", "fetch",
    `return (async () => { ${script} })();`);
  const parsed = JSON.parse(await call(env.window, env.document, env.location, env.fetch));
  console.log(`${name.padEnd(12)} at=${parsed.at || "-"} bl=${parsed.bl || "-"} `
    + `sid=${parsed.sid || "-"} source=${parsed.source || "-"}`);
  return parsed;
}

// Exactly what gemini.google.com/app serves as of September 2026: the build and
// session ids a request needs, and no SNlM0e at all. This fixture is the regression
// — every other one here carries the token, which is why requiring it went unnoticed.
const WIZ_NO_TOKEN = 'window.WIZ_global_data = {"cfb2h":"boq_build_20260910","FdrFJe":"8378702705255365122","TuX5cc":"en-US"};';

const WIZ = 'window.WIZ_global_data = {"SNlM0e":"ATTOKEN123","cfb2h":"boq_build_1",'
  + '"FdrFJe":"1234567890","TuX5cc":"ru"};';

const results = [
  ["global", await extract("global", environment({
    global: { SNlM0e: "ATTOKEN123", cfb2h: "boq_build_1", FdrFJe: "1234567890", TuX5cc: "ru" } }))],
  ["inline script", await extract("inline", environment({ scripts: [WIZ] }))],
  ["escaped json", await extract("escaped", environment({
    scripts: ['var x = "{\\"SNlM0e\\":\\"ATTOKEN123\\",\\"cfb2h\\":\\"boq_build_1\\",\\"FdrFJe\\":\\"1234567890\\"}"'] }))],
  ["refetch", await extract("refetch", environment({
    html: "<html>signed out</html>", fetched: `<script>${WIZ}</script>` }))],
  ["no token", await extract("no-token", environment({ global: {
    cfb2h: "boq_build_20260910", FdrFJe: "8378702705255365122", TuX5cc: "en-US" } }))],
  ["no token on page", await extract("no-tok-html", environment({ html: WIZ_NO_TOKEN }))],
  ["token only", await extract("token-only", environment({ global: { SNlM0e: "ATTOKEN123" } }))],
  ["signed out", await extract("signedout", environment({ html: "<html>no tokens</html>" }))],
];

const expectations = {
  global: (r) => r.source === "WIZ_global_data" && r.at === "ATTOKEN123",
  "inline script": (r) => r.source === "inline-script" && r.bl === "boq_build_1",
  "escaped json": (r) => r.source === "inline-script" && r.at === "ATTOKEN123",
  // The regression: a page with no token must still yield a usable session.
  "no token": (r) => r.source === "WIZ_global_data" && r.bl === "boq_build_20260910"
    && r.sid === "8378702705255365122" && r.at === "",
  "no token on page": (r) => r.bl === "boq_build_20260910" && r.at === "",
  // And the inverse: a token with nothing to build a request from is not a session.
  "token only": (r) => r.bl === "" && r.sid === "",
  refetch: (r) => r.source === "refetch" && r.sid === "1234567890",
  "signed out": (r) => r.at === "" && r.mentionsAt === false,
};

let failed = 0;
for (const [label, result] of results) {
  const pass = expectations[label](result);
  if (!pass) failed += 1;
  console.log(`${pass ? "PASS" : "FAIL"}  ${label}`);
}
if (failed > 0) {
  console.error(`${failed} scenario(s) failed`);
  process.exit(1);
}
console.log("\nall scenarios passed");
