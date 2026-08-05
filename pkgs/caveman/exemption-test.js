#!/usr/bin/env node
// unwired-test(workstation-dad9): wirable as a hermetic check, not yet done
// Proves the compaction exemption on the ACTUAL artifact we ship, by importing
// the patched plugin.js and driving its hooks directly. Runs in the derivation's
// installCheckPhase, so the property is enforced on every build/bump — not
// asserted once in a commit message.
//
// This is deliberately a behavioural test of the real file rather than a grep:
// the failure mode we care about (caveman text reaching the summarizer) is
// invisible at runtime, so it has to be caught at build time.
//
// usage: exemption-test.js <path-to-patched-plugin.js>

const assert = require('node:assert');
const path = require('node:path');

const pluginPath = process.argv[2];
if (!pluginPath) {
  console.error('usage: exemption-test.js <plugin.js>');
  process.exit(1);
}

// caveman's plugin writes its mode flag under $XDG_CONFIG_HOME/opencode.
// Point that at a scratch dir so the test never touches a real config.
const scratch = process.env.TEST_SCRATCH || path.join(process.cwd(), 'exemption-scratch');
require('node:fs').mkdirSync(path.join(scratch, 'opencode'), { recursive: true });
process.env.XDG_CONFIG_HOME = scratch;
process.env.CAVEMAN_DEFAULT_MODE = 'full';

const CAVEMAN_MARKERS = ['CAVEMAN MODE ACTIVE', 'Respond terse like smart caveman'];
const hasCaveman = (systemArr) =>
  systemArr.some((entry) => CAVEMAN_MARKERS.some((m) => String(entry).includes(m)));

(async () => {
  const mod = await import('file://' + path.resolve(pluginPath));
  const factory = mod.default || mod.CavemanPlugin;
  assert.strictEqual(typeof factory, 'function', 'plugin must export a factory function');

  const hooks = await factory({});
  const transform = hooks['experimental.chat.system.transform'];
  const compacting = hooks['experimental.session.compacting'];
  assert.strictEqual(typeof transform, 'function', 'transform hook must be registered');
  assert.strictEqual(typeof compacting, 'function', 'session.compacting hook must be registered');

  const SID = 'ses_test_exemption';

  // 1. NORMAL TURN — caveman must be injected. If this regresses, caveman is
  //    silently doing nothing and the whole package is pointless.
  {
    const out = { system: ['base prompt'] };
    await transform({ sessionID: SID, model: {} }, out);
    assert.ok(hasCaveman(out.system), 'normal turn: expected caveman injection, got: ' + JSON.stringify(out.system));
  }

  // 2. COMPACTION TURN — caveman must NOT be injected. This is the requirement.
  {
    await compacting({ sessionID: SID });
    const out = { system: ['summarize this conversation'] };
    await transform({ sessionID: SID, model: {} }, out);
    assert.ok(!hasCaveman(out.system), 'COMPACTION LEAK: caveman text reached the summarizer: ' + JSON.stringify(out.system));
    assert.deepStrictEqual(out.system, ['summarize this conversation'], 'compaction prompt must be left byte-identical');
  }

  // 3. The mark is self-clearing — the turn AFTER compaction is terse again,
  //    so a compaction can never latch caveman off for the rest of the session.
  {
    const out = { system: ['base prompt'] };
    await transform({ sessionID: SID, model: {} }, out);
    assert.ok(hasCaveman(out.system), 'post-compaction turn: caveman should be back on, got: ' + JSON.stringify(out.system));
  }

  // 4. A compaction in session A must not suppress session B.
  {
    await compacting({ sessionID: 'ses_A' });
    const out = { system: ['base prompt'] };
    await transform({ sessionID: 'ses_B', model: {} }, out);
    assert.ok(hasCaveman(out.system), 'cross-session bleed: session B was wrongly suppressed');
  }

  // 5. Requests with no sessionID (the hook types it optional) must still be
  //    terse rather than accidentally falling into the suppressed branch.
  {
    const out = { system: ['base prompt'] };
    await transform({ model: {} }, out);
    assert.ok(hasCaveman(out.system), 'sessionID-less request should still get caveman');
  }

  console.log('OK: compaction exemption verified —');
  console.log('    normal turn injects, compaction turn is byte-identical,');
  console.log('    mark self-clears, no cross-session bleed.');
})().catch((e) => {
  console.error('EXEMPTION TEST FAILED: ' + (e && e.message || e));
  process.exit(1);
});
