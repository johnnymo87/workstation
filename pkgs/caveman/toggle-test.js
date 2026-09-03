#!/usr/bin/env node
// Proves the prompt-toggle strictness on the ACTUAL artifact we ship, by
// importing the patched plugin.js, driving its `chat.message` hook with real
// prompt text, and observing the flag file it writes. Runs in the derivation's
// installCheckPhase and as a flake check, so the property is enforced on every
// build/bump rather than asserted once in a commit message.
//
// The property, in one sentence: a DELIBERATE COMMAND toggles the mode; PROSE
// THAT MENTIONS THE COMMAND DOES NOT.
//
// This has to be behavioural rather than a grep. The flag caveman toggles is
// host-global (one path, `$XDG_CONFIG_HOME/opencode/.caveman-active`, read by
// every session's system-prompt hook) and the toggle is unlogged, so a
// regression here silently changes the output style of every concurrent
// session on the machine and leaves no trace to debug from.
//
// usage: toggle-test.js <path-to-patched-plugin.js>

const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');

const pluginPath = process.argv[2];
if (!pluginPath) {
  console.error('usage: toggle-test.js <plugin.js>');
  process.exit(1);
}

// Point the plugin's config dir at a scratch dir so the test never touches the
// real ~/.config/opencode/.caveman-active — which, being host-global, is live
// state for every other session on this machine.
const scratch = process.env.TEST_SCRATCH || path.join(process.cwd(), 'toggle-scratch');
fs.rmSync(scratch, { recursive: true, force: true });
fs.mkdirSync(path.join(scratch, 'opencode'), { recursive: true });
process.env.XDG_CONFIG_HOME = scratch;
process.env.CAVEMAN_DEFAULT_MODE = 'full';
const flagPath = path.join(scratch, 'opencode', '.caveman-active');

const readState = () => (fs.existsSync(flagPath) ? fs.readFileSync(flagPath, 'utf8').trim() : 'off');

// The body opencode substitutes for a typed `/caveman <level>`: it expands the
// command FILE, and that file's prose quotes the deactivation phrases. Kept
// here verbatim (with $ARGUMENTS filled in) because it is the single most
// important input — upstream's ordering made this string self-defeating.
const expandedCommand = (level) => [
  'Activate caveman mode: ' + level,
  '',
  'If no level given, use full. If "off", deactivate.',
  '',
  'Respond terse like smart caveman. Drop articles, filler, pleasantries, hedging.',
  'Fragments OK. Technical terms exact. Code unchanged.',
  'Pattern: [thing] [action] [reason]. [next step].',
  '',
  'Behavior persists until session ends or user says "stop caveman" / "normal mode".',
  'Code, commits, security warnings: write normal English.',
].join('\n');

(async () => {
  const mod = await import('file://' + path.resolve(pluginPath));
  const factory = mod.default || mod.CavemanPlugin;
  assert.strictEqual(typeof factory, 'function', 'plugin must export a factory function');

  const hooks = await factory({});
  const chat = hooks['chat.message'];
  assert.strictEqual(typeof chat, 'function', 'chat.message hook must be registered');

  // Send `text` as a user prompt with the flag pre-set to `from`, return the
  // resulting flag state.
  const send = async (from, text) => {
    if (from === 'off') fs.rmSync(flagPath, { force: true });
    else fs.writeFileSync(flagPath, from);
    await chat({}, { parts: [{ type: 'text', text }] });
    return readState();
  };

  const disables = async (text, why) =>
    assert.strictEqual(await send('full', text), 'off', 'should DISABLE (' + why + '): ' + JSON.stringify(text));
  const keepsOn = async (text, why) =>
    assert.notStrictEqual(await send('full', text), 'off', 'must NOT disable (' + why + '): ' + JSON.stringify(text));
  const enables = async (text, why) =>
    assert.notStrictEqual(await send('off', text), 'off', 'should ENABLE (' + why + '): ' + JSON.stringify(text));
  const keepsOff = async (text, why) =>
    assert.strictEqual(await send('off', text), 'off', 'must NOT enable (' + why + '): ' + JSON.stringify(text));

  // 1. DELIBERATE COMMANDS STILL WORK. If this regresses the feature is
  //    unusable and the fix has overshot into "nothing toggles anything".
  for (const cmd of [
    '/caveman off',
    '/caveman stop',
    '/caveman disable',
    'stop caveman',
    'Stop caveman.',
    '  disable caveman mode  ',
    'turn off caveman',
    'normal mode',
    'caveman off',
    'stop talking like a caveman',
    '"/caveman off"',            // the `opencode run` quote-wrapped form
  ]) {
    await disables(cmd, 'bare deliberate off-command');
  }

  for (const cmd of [
    '/caveman',
    '/caveman ultra',
    'talk like a caveman',
    'enable caveman mode',
    'caveman mode',
    'use caveman',
  ]) {
    await enables(cmd, 'bare deliberate on-command');
  }

  // 2. PROSE MUST NOT TOGGLE. This is the bug. Each of these is real text that
  //    was, or plausibly would be, typed while working ON caveman — and each
  //    one silently reconfigured every session on the host.
  const offProse = [
    'The plugin unlinks the host-global flag whenever a prompt matches the regex that is supposed to detect a request to disable caveman. Fix that.',
    'fix(caveman): stop caveman being disabled by ordinary prose',
    'Document that the user can say "stop caveman" to turn off caveman mode.',
    'When the flag is absent the assistant just answers in normal mode, which is why the review session saw no ruleset.',
    'Should we turn off caveman for subagents? I am not asking you to do it, just asking.',
    'grep -n "stop|disable|deactivate|turn off" pkgs/caveman/default.nix',
  ];
  for (const p of offProse) await keepsOn(p, 'prose about disabling');

  const onProse = [
    'The activation regex matches any paragraph containing the words caveman mode, which is how the flag oscillates.',
    'I want to enable caveman mode later, but first explain what the plugin does on session start.',
    'Why does it talk like a caveman in some sessions and not others?',
  ];
  for (const p of onProse) await keepsOff(p, 'prose about enabling');

  // 3. THE EXPANDED SLASH COMMAND. opencode replaces `/caveman <level>` with
  //    the command file's body BEFORE chat.message fires, and that body quotes
  //    "stop caveman" / "normal mode" as documentation. Upstream checked the
  //    deactivation branch first, so the documented ACTIVATION command
  //    deactivated and the level was never applied. Both halves asserted.
  for (const level of ['full', 'ultra', 'lite']) {
    const got = await send('off', expandedCommand(level));
    assert.notStrictEqual(got, 'off',
      '/caveman ' + level + ' must ACTIVATE, not deactivate (its expanded body quotes "stop caveman")');
    assert.strictEqual(got, level, '/caveman ' + level + ' must apply the requested level, got ' + got);
  }
  assert.strictEqual(await send('full', expandedCommand('off')), 'off',
    '/caveman off must still deactivate via the expanded-template branch');

  // 4. A prompt with no text parts, or empty text, must be inert.
  fs.writeFileSync(flagPath, 'full');
  await chat({}, { parts: [] });
  await chat({}, { parts: [{ type: 'text', text: '   ' }] });
  assert.strictEqual(readState(), 'full', 'empty prompts must not change state');

  console.log('OK: prompt-toggle strictness verified —');
  console.log('    bare commands still toggle, prose about them does not,');
  console.log('    and an expanded /caveman <level> activates at that level.');
})().catch((e) => {
  console.error('TOGGLE TEST FAILED: ' + (e && e.message || e));
  process.exit(1);
});
