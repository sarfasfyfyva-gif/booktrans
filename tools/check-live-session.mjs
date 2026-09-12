#!/usr/bin/env node
/**
 * Fetches the live gemini.google.com/app page and runs the app's own
 * session-parameter extraction against it.
 *
 * Why this exists: the extraction only ever runs on a device, against a page that
 * Google changes without notice. That is how the app came to tell a signed-in user
 * they were signed out — the page stopped carrying `SNlM0e` in early 2026 and
 * nothing noticed. This runs the same script the app runs, pulled from the Swift
 * source so it cannot drift, against the real page, so the next change is a
 * one-command answer instead of a device round trip.
 *
 * It cannot check the part of the decision that needs a real session — the cookie
 * store and the account RPC — so it reports the page side only, and says so.
 *
 *     node tools/check-live-session.mjs
 *
 * Exit code 1 means the page no longer carries what a request needs.
 */
import { readFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
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

// The UA the app sends. Google serves a different shell to a desktop UA, so the
// check is only meaningful with the same one.
const UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) "
  + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1";

// curl rather than fetch(): Google sends more header bytes than Node's HTTP client
// accepts by default (HeadersOverflowError), and curl does not care.
let html;
try {
  html = execFileSync("curl", [
    "-sL", "--compressed", "-m", "45",
    "-A", UA, "-H", "Accept-Language: en-US,en;q=0.9",
    "https://gemini.google.com/app",
  ], { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });
} catch (error) {
  console.error(`fetch failed: ${error.message}`);
  process.exit(2);
}
if (!html || html.length < 10_000) {
  console.error(`fetch failed: got ${html ? html.length : 0} chars`);
  process.exit(2);
}

// Rebuild what the browser would have: the global the page assigns for itself, the
// inline scripts, and the markup. The extraction reads all three.
let global = {};
const assignment = html.match(/window\.WIZ_global_data\s*=\s*(\{[\s\S]*?\});?\s*<\/script>/);
if (assignment) {
  try {
    global = JSON.parse(assignment[1]);
  } catch (error) {
    console.error(`WIZ_global_data did not parse as JSON: ${error.message}`);
    process.exit(2);
  }
} else {
  console.error("warning: no window.WIZ_global_data assignment in the page");
}

const scripts = [...html.matchAll(/<script[^>]*>([\s\S]*?)<\/script>/g)].map((m) => m[1]);
const environment = {
  window: { WIZ_global_data: global },
  document: {
    scripts: scripts.map((textContent) => ({ textContent })),
    documentElement: { innerHTML: html },
    title: "Gemini",
  },
  location: { href: "https://gemini.google.com/app", origin: "https://gemini.google.com" },
  fetch: async () => ({ text: async () => html }),
};

const call = new Function("window", "document", "location", "fetch",
  `return (async () => { ${script} })();`);
const parsed = JSON.parse(await call(environment.window, environment.document,
  environment.location, environment.fetch));

console.log(`page: ${html.length} chars, `
  + `${Object.keys(global).length} global keys, ${scripts.length} inline scripts`);
console.log(`extracted: source=${parsed.source || "-"} bl=${parsed.bl || "-"} `
  + `sid=${parsed.sid || "-"} at=${parsed.at || "-"} mentionsAt=${parsed.mentionsAt ? "yes" : "no"}`);

// A request needs bl and f.sid, and nothing else. The token is deliberately not
// part of this: since 2026 Google often does not serve it, and the sign-in page
// carries one of its own, so it is evidence in neither direction.
const ok = Boolean(parsed.bl && parsed.sid);
if (!ok) {
  console.error("FAIL: the page no longer carries what a request needs — the app "
    + "cannot translate and the extraction or the page has changed.");
}

const tokenNote = parsed.mentionsAt
  ? "the page carries SNlM0e (optional, and not consulted)"
  : "the page does not carry SNlM0e, which has been normal since early 2026";
console.log(`token: ${tokenNote}`);
console.log("note: the cookie store and the account RPC cannot be checked from here.");
process.exit(ok ? 0 : 1);
