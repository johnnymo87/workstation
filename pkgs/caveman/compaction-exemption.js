#!/usr/bin/env node
// Rewrites caveman's opencode plugin.js so its system-prompt injection is
// EXEMPT FROM COMPACTION, and so the always-on ruleset travels through that
// same (exemptable) hook instead of opencode's global `instructions` key.
//
// WHY
// ---
// Requirement: caveman is always-on for normal turns, but must not touch
// compaction. Compaction is one-shot summarization — terse summaries are lossy
// summaries, and a terseness directive there fights our own
// compaction-context.ts, which asks the summarizer to preserve things verbatim.
// Both land in the same output.system array on the same request.
//
// Upstream gives us no direct seam: `experimental.chat.system.transform`
// receives only { sessionID?, model } — no agent name — so the hook cannot tell
// "this is the compaction/summary agent" by itself. Model-sniffing is not an
// option either: on macOS the primary model and the compaction model are BOTH
// gemini-3.8-flash, so there is nothing to discriminate on.
//
// THE SEAM
// --------
// `experimental.session.compacting` fires with the sessionID immediately before
// compaction's summarization request. We mark that session, and the transform
// hook skips injection while the mark is set.
//
// The mark is self-clearing: the suppressed transform call removes it. That is
// deliberate — compaction issues exactly one summarization request, so a mark
// can suppress at most one request and can never latch "caveman off" for a
// session. `session.compacted` / `experimental.compaction.autocontinue` also
// clear it as a belt-and-braces for the case where compaction aborts before
// issuing its request. Worst-case failure mode is one normal turn missing the
// caveman line, never a permanently-silenced session and never a caveman-ised
// summary.
//
// State is per-process and in-memory (a Set), NOT the on-disk flag file, so it
// cannot leak across the 4 serves the way .caveman-active does.
//
// WHY THE RULESET MOVES IN HERE TOO
// ---------------------------------
// opencode's `instructions` key is global: every agent gets it, including the
// summary/compaction agent, and there is no per-agent scoping. Wiring the
// ruleset that way would re-introduce exactly the leak this patch exists to
// prevent. So the ruleset is pushed through the gated hook instead, and
// opencode-config.nix deliberately does NOT set `instructions`.
//
// This script is intentionally assert-heavy: if an upstream bump moves any
// anchor, the build FAILS LOUDLY rather than silently shipping a caveman that
// injects into compaction (or one that injects nothing at all).

const fs = require('node:fs');

const [, , srcPath, rulesPath, dstPath] = process.argv;
if (!srcPath || !rulesPath || !dstPath) {
  console.error('usage: compaction-exemption.js <plugin.js> <caveman-activate.md> <out.js>');
  process.exit(1);
}

let s = fs.readFileSync(srcPath, 'utf8');
const rules = fs.readFileSync(rulesPath, 'utf8').trimEnd();

function must(cond, msg) {
  if (!cond) {
    console.error('FAIL: ' + msg);
    console.error('caveman upstream changed shape; refusing to emit a plugin whose compaction exemption is unverified.');
    process.exit(1);
  }
}

// --- anchor 1: the transform hook we are gating -----------------------------
const TRANSFORM = "  'experimental.chat.system.transform': async (_input, output) => {";
must(s.includes(TRANSFORM), 'transform hook anchor not found in plugin.js');

// --- anchor 2: the export we hang the compacting-set off --------------------
const FACTORY = 'export const CavemanPlugin = async (_ctx) => {';
must(s.includes(FACTORY), 'CavemanPlugin factory anchor not found in plugin.js');

// --- anchor 3: the event dispatcher (we add compaction-clearing to it) ------
const EVENT = "  event: async ({ event } = {}) => {\n    if (event && event.type === 'session.created') handleSessionCreated();";
must(s.includes(EVENT), 'event dispatcher anchor not found in plugin.js');

// 1. Module-level state + the ruleset text.
const preamble = `
// --- workstation patch: compaction exemption --------------------------------
// Sessions currently inside a compaction. See pkgs/caveman/compaction-exemption.js.
const __wsCompacting = new Set();
const __wsRuleset = ${JSON.stringify(rules)};
// ---------------------------------------------------------------------------

`;
s = s.replace(FACTORY, preamble + FACTORY);

// 2. Gate the transform hook and push the ruleset through it.
const gated = TRANSFORM + `
    // workstation patch: never shape the compaction/summary prompt.
    const __wsSid = _input && _input.sessionID;
    if (__wsSid && __wsCompacting.has(__wsSid)) {
      // Self-clearing: compaction makes exactly one request, so this mark can
      // suppress at most one and can never latch caveman off for the session.
      __wsCompacting.delete(__wsSid);
      return;
    }`;
s = s.replace(TRANSFORM, gated, 1);

// 3. Push the always-on ruleset alongside the reinforcement line, inside the
//    same gate (so it is exempt from compaction too).
const PUSH = '      output.system.push(reinforcementLine(active));';
must(s.includes(PUSH), 'reinforcement push anchor not found in plugin.js');
s = s.replace(PUSH, '      output.system.push(__wsRuleset);\n' + PUSH, 1);

// 4. Register/clear the compaction mark.
const compactHooks = `  // workstation patch: mark the session so the transform hook above skips the
  // summarization request that follows.
  'experimental.session.compacting': async (input) => {
    if (input && input.sessionID) __wsCompacting.add(input.sessionID);
  },
  // Belt-and-braces: clear the mark if compaction ends without ever reaching
  // the transform hook (e.g. it aborted), so nothing lingers.
  'experimental.compaction.autocontinue': async (input) => {
    if (input && input.sessionID) __wsCompacting.delete(input.sessionID);
  },

`;
s = s.replace('  event: async ({ event } = {}) => {', compactHooks + '  event: async ({ event } = {}) => {', 1);

// Also clear on the session.compacted event.
s = s.replace(
  "    if (event && event.type === 'session.created') handleSessionCreated();",
  "    if (event && event.type === 'session.created') handleSessionCreated();\n" +
  "    // workstation patch: compaction finished — drop any stale mark.\n" +
  "    if (event && event.type === 'session.compacted' && event.properties && event.properties.sessionID) {\n" +
  "      __wsCompacting.delete(event.properties.sessionID);\n" +
  "    }",
  1,
);

// --- post-conditions --------------------------------------------------------
must(s.includes('__wsCompacting.add('), 'patch did not register the compacting mark');
must(s.includes('__wsCompacting.delete('), 'patch did not register any mark clearing');
must(s.includes('output.system.push(__wsRuleset)'), 'patch did not route the ruleset through the gated hook');
must(s.includes('Respond terse like smart caveman'), 'ruleset text did not make it into the plugin');

fs.writeFileSync(dstPath, s);
console.log('compaction-exemption: patched ' + srcPath + ' -> ' + dstPath);
