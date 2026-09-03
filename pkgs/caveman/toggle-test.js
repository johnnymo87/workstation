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
// command FILE, and that file's prose quotes the deactivation phrases, which is
// what made upstream's ordering self-defeating.
//
// Read from the SHIPPED command file rather than hardcoded, because the file
// and the plugin ship together out of one derivation and must agree. A
// hardcoded copy would keep passing after an upstream bump changed the
// template's first line, while the real `/caveman ultra` silently stopped
// selecting a level — the patcher's anchors guard the plugin's regex, not this
// file's prose. Resolved relative to the plugin because that is the only path
// the caller passes in; $out/plugin/plugin.js -> $out/commands/caveman.md.
const commandPath = path.resolve(path.dirname(path.resolve(pluginPath)), '..', 'commands', 'caveman.md');
if (!fs.existsSync(commandPath)) {
  console.error('TOGGLE TEST FAILED: expected the shipped command file at ' + commandPath +
    ' — refusing to fall back to a hardcoded copy, which is how this test would go vacuously green.');
  process.exit(1);
}
const commandTemplate = fs.readFileSync(commandPath, 'utf8').replace(/^---\n[\s\S]*?\n---\n/, '');
// Guard the read itself: if the front-matter strip or the file shape changes,
// the substitution below could silently produce something that is not a
// command at all, and every assertion built on it would prove nothing.
assert.ok(/^Activate caveman mode: \$ARGUMENTS\b/.test(commandTemplate.trim()),
  'shipped commands/caveman.md no longer starts with the expected template line: ' +
  JSON.stringify(commandTemplate.slice(0, 80)));
assert.ok(/stop caveman|normal mode/i.test(commandTemplate),
  'shipped commands/caveman.md no longer quotes the deactivation phrases — the ' +
  'self-disable case this test exists for cannot be exercised, so the green is meaningless');
const expandedCommand = (level) => commandTemplate.replace('$ARGUMENTS', level);

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
  const offCommands = [
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
    // Politeness and temporal tags. These are the commonest forms people
    // actually type, and an earlier draft of this patch silently dropped every
    // one of them.
    'stop caveman please',
    'please stop caveman now',
    'ok stop caveman',
    'stop caveman, thanks',
    'can you turn off caveman',
    'back to normal mode',
    'switch to normal mode',
    'normal mode please',
    'talk normally',
    // Double space: the plugin does not collapse whitespace at this rev, so
    // the matcher has to.
    'stop  caveman',
  ];
  for (const cmd of offCommands) await disables(cmd, 'bare deliberate off-command');

  const onCommands = [
    '/caveman',
    '/caveman ultra',
    'talk like a caveman',
    'enable caveman mode',
    'caveman mode',
    'use caveman',
    'please turn on caveman',
    'can you enable caveman mode',
    'activate caveman now',
  ];
  for (const cmd of onCommands) await enables(cmd, 'bare deliberate on-command');

  // 1b. A QUESTION IS NOT A COMMAND. Answering a question by silently
  //     performing it is the same class of bug as the one under test.
  await keepsOn('normal mode?', 'question, not a command');
  await keepsOff('caveman mode?', 'question, not a command');

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

  // 2b. THE GENERAL PROPERTY, not just the handful of sentences above.
  //
  //     Every command this test asserts DOES toggle must be inert when it is
  //     embedded in a longer prompt. Without this, a whitelist entry that is
  //     accidentally left unanchored stays invisible: the bare-command
  //     assertions still pass, the prose fixtures happen to exercise only the
  //     other entries, and the gate goes green with the bug restored. That is
  //     not hypothetical — an adversarial review of this test found exactly
  //     that mutation surviving an earlier draft, via the two whitelist
  //     entries the prose fixtures did not happen to cover.
  //
  //     Slash commands are excluded from the carriers, and deliberately so:
  //     the slash branch matches on the FIRST TOKEN, so a prompt that opens
  //     "/caveman off is the phrase..." is a slash-command invocation with
  //     trailing text and upstream treats it as one. That is unchanged by this
  //     patch, out of its scope, and not a host-global-prose hazard — prose
  //     about the command does not begin with the command.
  const carriers = [
    (c) => 'Note: typing ' + c + ' would toggle the mode, per the docs.',
    (c) => 'The documented escape hatch is ' + c,
    (c) => c + ' is the phrase the plugin looks for, which is the bug.',
    (c) => 'Add a test asserting that ' + c + ' still works after the patch.',
  ];
  const naturalLanguageOnly = (cmds) =>
    cmds.map((c) => c.trim().replace(/^"|"$/g, '')).filter((c) => !c.startsWith('/'));
  const embeddable = {
    off: naturalLanguageOnly(offCommands),
    on: naturalLanguageOnly(onCommands),
  };
  // Guard against the filter silently emptying either list, which would make
  // this whole section a no-op that still reports success.
  assert.ok(embeddable.off.length >= 10 && embeddable.on.length >= 5,
    'embedded-prose property has too few commands to be meaningful: ' + JSON.stringify(embeddable));
  for (const c of embeddable.off) {
    for (const carry of carriers) await keepsOn(carry(c), 'off-command embedded in prose');
  }
  for (const c of embeddable.on) {
    for (const carry of carriers) await keepsOff(carry(c), 'on-command embedded in prose');
  }

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
