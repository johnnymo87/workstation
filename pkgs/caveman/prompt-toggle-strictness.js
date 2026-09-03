#!/usr/bin/env node
// Rewrites caveman's opencode plugin.js so its NATURAL-LANGUAGE mode toggles
// fire only on a DELIBERATE COMMAND — a prompt whose entire text is the
// instruction — instead of on any prose that happens to mention caveman.
//
// WHY
// ---
// The flag caveman toggles is host-global. plugin.js builds it as
//
//   const flagPath = path.join(opencodeConfigDir(), '.caveman-active');
//
// with no session component, and `experimental.chat.system.transform` reads
// that one path on every request from every session. So a single toggle
// changes behaviour for EVERY opencode session on the host, silently and
// without a log line.
//
// Upstream then drives that global toggle from unanchored substring regexes
// applied to the whole user prompt:
//
//   /\b(stop|disable|deactivate|turn off)\b.*\bcaveman\b/i
//   /\bcaveman\b.*\b(stop|disable|deactivate|turn off)\b/i
//   /\bnormal mode\b/i
//
// `.*` spans the entire message, so ANY sentence containing both halves is a
// match. Writing *about* the feature performs it. Observed consequences:
//
//   - A session that merely discussed the disable phrase in prose turned
//     caveman off for a concurrently-running review session on the same host,
//     which then reported (correctly, for itself) that it had no caveman
//     ruleset. Any before/after comparison of output style across sessions is
//     contaminated by this.
//   - A commit message like "fix: stop caveman from being disabled by prose"
//     disables caveman.
//   - Worst: opencode expands `/caveman <level>` into the command file's BODY
//     before chat.message fires, and that body reads
//       Behavior persists until session ends or user says "stop caveman" / "normal mode".
//     The deactivation branch is checked first, so it matches the body and the
//     documented ACTIVATION command deactivates. The `^activate caveman mode:`
//     template branch below it is unreachable for every level.
//
// The activation regexes have the same shape and the same bug in the other
// direction (`/\bcaveman\b.*\b(mode|...)\b/i` matches the phrase "caveman
// mode" in any paragraph), which is what makes the flag oscillate rather than
// simply stay off. Both directions are fixed here; fixing only one would leave
// prose able to re-enable caveman in a session where the user turned it off.
//
// THE FIX
// -------
// Replace the substring regexes with an anchored WHITELIST matched against the
// whole prompt. A prompt toggles only if, after trimming and stripping
// trailing sentence punctuation, it IS one of the known commands. Prose can
// contain the phrase; prose is not the phrase.
//
// Deliberately NOT changed:
//   - the `/caveman ...` slash-command branch: already exact-match on the
//     first token.
//   - the `^activate caveman mode:` template branch: already anchored to the
//     start of the prompt, and it is the branch that expanded slash commands
//     are supposed to reach. This patch is what lets them reach it.
//
// NOT FIXED HERE (deliberately, and larger): the flag remains host-global.
// Making it per-session means keying the flag file by sessionID, and
// `chat.message` is the hook that would have to supply that id — it receives
// (input, output) where the session id is not part of the documented hook
// contract we can rely on across opencode versions, and the file would then
// need garbage collection. That is a design change, not a bug fix. This patch
// removes the accidental triggering; a deliberate `/caveman off` still, by
// design, affects the whole host as it does upstream.
//
// Assert-heavy on purpose: if an upstream bump moves an anchor the build FAILS
// rather than silently shipping the old permissive matcher.

const fs = require('node:fs');

const [, , srcPath, dstPath] = process.argv;
if (!srcPath || !dstPath) {
  console.error('usage: prompt-toggle-strictness.js <plugin.js> <out.js>');
  process.exit(1);
}

let s = fs.readFileSync(srcPath, 'utf8');

function must(cond, msg) {
  if (!cond) {
    console.error('FAIL: ' + msg);
    console.error('caveman upstream changed shape; refusing to emit a plugin whose toggle strictness is unverified.');
    process.exit(1);
  }
}

// --- anchor 1: the natural-language DEACTIVATION branch ---------------------
const OFF_BRANCH =
  "  if (/\\b(stop|disable|deactivate|turn off)\\b.*\\bcaveman\\b/i.test(prompt) ||\n" +
  "      /\\bcaveman\\b.*\\b(stop|disable|deactivate|turn off)\\b/i.test(prompt) ||\n" +
  "      /\\bnormal mode\\b/i.test(prompt)) {\n" +
  "    return 'off';\n" +
  "  }";
must(s.includes(OFF_BRANCH), 'natural-language deactivation branch not found in plugin.js');

// --- anchor 2: the natural-language ACTIVATION branch -----------------------
const ON_BRANCH =
  "  if (/\\b(activate|enable|turn on|start|talk like)\\b.*\\bcaveman\\b/i.test(prompt) ||\n" +
  "      /\\bcaveman\\b.*\\b(mode|activate|enable|turn on|start)\\b/i.test(prompt)) {";
must(s.includes(ON_BRANCH), 'natural-language activation branch not found in plugin.js');

// --- anchor 3: somewhere to hang the helper ---------------------------------
const PARSE_FN = 'function parseModeChange(promptRaw) {';
must(s.includes(PARSE_FN), 'parseModeChange anchor not found in plugin.js');

// 1. The whole-prompt command matcher.
//
// `prompt` reaching these branches is already trimmed, quote-unwrapped and
// lowercased by parseModeChange, so these patterns need neither /i nor their
// own trimming — only the trailing-punctuation strip.
const helper = `// --- workstation patch: prompt-toggle strictness ----------------------------
// A natural-language toggle must be the WHOLE prompt, not a phrase inside it.
// See pkgs/caveman/prompt-toggle-strictness.js for why (a host-global flag
// driven by substring matches means writing about the feature performs it).
const __WS_OFF_COMMANDS = [
  /^(?:please )?(?:stop|disable|deactivate|turn off)(?: the)? caveman(?: mode)?$/,
  /^(?:please )?(?:stop|quit) (?:talking|speaking|writing|responding) like (?:a |the )?caveman$/,
  /^caveman (?:off|stop|disable|deactivate)$/,
  /^normal mode$/,
];
const __WS_ON_COMMANDS = [
  /^(?:please )?(?:activate|enable|turn on|start|use)(?: the)? caveman(?: mode)?$/,
  /^(?:please )?(?:talk|speak|write|respond) like (?:a |the )?caveman$/,
  /^caveman (?:mode|on)$/,
];

// Strip trailing sentence punctuation so "stop caveman." still counts, then
// require an exact whole-string match against one of the patterns above.
function __wsIsCommand(prompt, patterns) {
  const t = String(prompt).replace(/[.!?\\s]+$/, '');
  return patterns.some((re) => re.test(t));
}
// ---------------------------------------------------------------------------

`;
s = s.replace(PARSE_FN, helper + PARSE_FN, 1);

// 2. Deactivation: whole-prompt commands only.
s = s.replace(
  OFF_BRANCH,
  "  // workstation patch: whole-prompt commands only — prose that merely\n" +
  "  // mentions the phrase must not flip a host-global flag.\n" +
  "  if (__wsIsCommand(prompt, __WS_OFF_COMMANDS)) {\n" +
  "    return 'off';\n" +
  "  }",
  1,
);

// 3. Activation: same treatment, so prose cannot switch it back on either.
s = s.replace(
  ON_BRANCH,
  "  // workstation patch: whole-prompt commands only (see above).\n" +
  "  if (__wsIsCommand(prompt, __WS_ON_COMMANDS)) {",
  1,
);

// --- post-conditions --------------------------------------------------------
must(!s.includes('/\\b(stop|disable|deactivate|turn off)\\b.*\\bcaveman\\b/i'),
  'permissive deactivation regex survived the patch');
must(!s.includes('/\\bcaveman\\b.*\\b(mode|activate|enable|turn on|start)\\b/i'),
  'permissive activation regex survived the patch');
must(!/\/\\bnormal mode\\b\/i\.test\(prompt\)/.test(s),
  'permissive "normal mode" regex survived the patch');
must(s.includes('__wsIsCommand(prompt, __WS_OFF_COMMANDS)'), 'patch did not install the strict off matcher');
must(s.includes('__wsIsCommand(prompt, __WS_ON_COMMANDS)'), 'patch did not install the strict on matcher');
// The template branch must survive: it is what expanded /caveman <level>
// prompts land on once the off-branch stops swallowing them.
must(s.includes("/^activate caveman mode:[ \\t]*(\\S*)/"), 'expanded-command template branch went missing');

fs.writeFileSync(dstPath, s);
console.log('prompt-toggle-strictness: patched ' + srcPath + ' -> ' + dstPath);
