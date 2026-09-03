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
// WHY WHOLE-PROMPT AND NOT "FIRST CLAUSE"
// ---------------------------------------
// Clause-splitting (match the whitelist against the text before the first
// `.`/`,`/` and `) would additionally catch "turn off caveman and write the
// release notes", which upstream's caveman-parse.js comments call out as a
// real thing people type. It is rejected here because it destroys the exact
// property this patch exists to provide, and which toggle-test.js asserts:
//
//   a whitelisted command EMBEDDED IN A LONGER PROMPT must not toggle.
//
// "turn off caveman and write the release notes" and "stop caveman is the
// phrase the plugin looks for, which is the bug" are the same shape; no
// splitter separates them without re-opening the hole. Whole-prompt is the
// only rule that makes the guarantee checkable, so the compound instruction
// loses. `/caveman off` covers it in one extra keystroke.
//
// NOT FIXED HERE (deliberately, and larger): the flag remains host-global, so
// a deliberate toggle still affects every session, as upstream intends.
//
// To be accurate about the cost of the alternative rather than overstate it:
// `chat.message` DOES receive a session id — it is required in the hook's
// input type (@opencode-ai/plugin, "chat.message"?: (input: { sessionID:
// string; ... })), and the compaction patch beside this one already depends on
// the transform hook's optional one. So per-session state is buildable, and the
// cheap version needs no file at all: an in-memory Map keyed by sessionID, the
// same shape as `__wsCompacting`. What makes it out of scope here is not
// feasibility but blast radius — it changes what the mode IS (per-session, lost
// on serve restart, invisible to the other three serves in the pool) rather
// than fixing a misfiring matcher, and a separate track is evaluating whether
// to keep caveman at all. Tracked separately; this patch removes the
// ACCIDENTAL triggering only.
//
// Note the corollary, which is upstream's bug and not addressed here either:
// `handleSessionCreated` re-asserts the default mode on every `session.created`
// event, so even a deliberate `/caveman off` is undone by the next session
// (including a subagent) starting anywhere on the host.
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
//
// \`prompt\` is already trimmed, quote-unwrapped and lowercased by
// parseModeChange, so these need no /i. They are anchored at BOTH ends: the
// closing \$ is the load-bearing half.
const __WS_LEAD = '(?:(?:ok|okay|alright|hey) )?(?:(?:can|could|would|will) you )?(?:please )?';
const __wsCmd = (body) => new RegExp('^' + __WS_LEAD + body + '\$');

const __WS_OFF_COMMANDS = [
  __wsCmd('(?:stop|disable|deactivate|turn off|quit|exit)(?: the)? caveman(?: mode)?'),
  __wsCmd('(?:stop|quit) (?:talking|speaking|writing|responding) like (?:a |the )?caveman'),
  __wsCmd('caveman (?:off|stop|disable|deactivate)'),
  // "normal mode" needs no caveman context (the ruleset advertises it as the
  // escape phrase), but it must still be the whole prompt — otherwise vim's
  // normal mode disables caveman, which is upstream #778.
  __wsCmd('(?:(?:go |switch |get )?back to |switch to |return to |go )?normal mode'),
  __wsCmd('(?:talk|speak|write|respond|answer) normal(?:ly)?'),
];
const __WS_ON_COMMANDS = [
  __wsCmd('(?:activate|enable|turn on|start|use)(?: the)? caveman(?: mode)?'),
  __wsCmd('(?:talk|speak|write|respond) like (?:a |the )?caveman'),
  __wsCmd('caveman (?:mode|on)'),
];

// Normalise, then require an exact whole-string match.
function __wsIsCommand(prompt, patterns) {
  // Collapse whitespace runs first: this rev of the plugin does not fold
  // newlines, and "stop  caveman" with a stray double space is a command the
  // user meant. Every pattern above is written with single spaces.
  let t = String(prompt).replace(/\\s+/g, ' ').trim();
  // Trailing sentence punctuation, then a trailing politeness/temporal tag
  // ("stop caveman please" is the commonest form of all), then whatever
  // punctuation separated that tag.
  //
  // '?' is deliberately NOT stripped. "caveman mode?" and "normal mode?" are
  // questions — plausible one-word replies to a clarifying question — and
  // answering a question by silently performing it is the same class of bug
  // as the one being fixed.
  t = t.replace(/[.!,;\\s]+\$/, '');
  t = t.replace(/[,;:\\-\\s]*\\b(?:please|now|thanks|thank you)\$/, '');
  t = t.replace(/[.!,;\\s]+\$/, '');
  return patterns.some((re) => re.test(t));
}
// ---------------------------------------------------------------------------

`;
// Replacements are passed as FUNCTIONS, never as strings. A string replacement
// interpolates $&, $\', $` and $1 out of the replacement text, so a future edit
// that puts a `$\'` inside `helper` would corrupt the emitted plugin silently.
// The regexes above already contain `$`, which is exactly the hazard.
const sub = (haystack, find, replacement) => haystack.replace(find, () => replacement);

s = sub(s, PARSE_FN, helper + PARSE_FN);

// 2. Deactivation: whole-prompt commands only.
s = sub(s, OFF_BRANCH,
  "  // workstation patch: whole-prompt commands only — prose that merely\n" +
  "  // mentions the phrase must not flip a host-global flag.\n" +
  "  if (__wsIsCommand(prompt, __WS_OFF_COMMANDS)) {\n" +
  "    return 'off';\n" +
  "  }");

// 3. Activation: same treatment, so prose cannot switch it back on either.
s = sub(s, ON_BRANCH,
  "  // workstation patch: whole-prompt commands only (see above).\n" +
  "  if (__wsIsCommand(prompt, __WS_ON_COMMANDS)) {");

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

// EVERY whitelist entry must be anchored at both ends. The checks above only
// prove the OLD permissive regexes are gone, which says nothing about the new
// ones — an unanchored entry here reintroduces the exact bug while leaving the
// rest of the patch, and the greps, looking correct. `__wsCmd` is the only
// constructor and it hardcodes '^'...'$', so the property is enforced by
// requiring that no entry bypasses it.
must(/const __wsCmd = \(body\) => new RegExp\('\^' \+ __WS_LEAD \+ body \+ '\$'\);/.test(s),
  '__wsCmd is no longer the anchoring constructor');
for (const list of ['__WS_OFF_COMMANDS', '__WS_ON_COMMANDS']) {
  const block = new RegExp('const ' + list + ' = \\[([\\s\\S]*?)\\n\\];').exec(s);
  must(block, list + ' not found in the emitted plugin');
  const entries = block[1]
    .split('\n')
    .map((l) => l.replace(/\/\/.*$/, '').trim())
    .filter((l) => l.length);
  must(entries.length > 0, list + ' is empty');
  for (const e of entries) {
    must(e.startsWith('__wsCmd('),
      list + ' has an entry not built by __wsCmd, so its anchoring is unverified: ' + e);
  }
}

fs.writeFileSync(dstPath, s);
console.log('prompt-toggle-strictness: patched ' + srcPath + ' -> ' + dstPath);
