import { describe, test, expect, vi } from 'vitest';
import { evaluateOwnerDrift, INITIAL_OWNER_DRIFT_STATE, createDriftMonitor } from '../src/drift.js';
import type { Config } from '../src/config.js';

describe('evaluateOwnerDrift pure', () => {
  const A = 'http://127.0.0.1:4096';
  const B = 'http://127.0.0.1:4097';
  const C = 'http://127.0.0.1:4098';

  test('resolved === current resets the tracker and does not reconnect', () => {
    const res = evaluateOwnerDrift({ candidate: B, count: 1 }, A, A);
    expect(res.reconnect).toBe(false);
    expect(res.state).toEqual(INITIAL_OWNER_DRIFT_STATE);
  });

  test('empty resolved never reconnects', () => {
    const res = evaluateOwnerDrift(INITIAL_OWNER_DRIFT_STATE, A, '');
    expect(res.reconnect).toBe(false);
    expect(res.state).toEqual(INITIAL_OWNER_DRIFT_STATE);
  });

  test('different url does not reconnect on first occurrence (needs confirmation)', () => {
    const res = evaluateOwnerDrift(INITIAL_OWNER_DRIFT_STATE, A, B);
    expect(res.reconnect).toBe(false);
    expect(res.state).toEqual({ candidate: B, count: 1 });
  });

  test('same different url twice consecutive reconnects and resets state', () => {
    const step1 = evaluateOwnerDrift(INITIAL_OWNER_DRIFT_STATE, A, B);
    expect(step1.reconnect).toBe(false);
    const step2 = evaluateOwnerDrift(step1.state, A, B);
    expect(step2.reconnect).toBe(true);
    expect(step2.state).toEqual(INITIAL_OWNER_DRIFT_STATE);
  });

  test('flap back to current resets count', () => {
    const step1 = evaluateOwnerDrift(INITIAL_OWNER_DRIFT_STATE, A, B);
    const step2 = evaluateOwnerDrift(step1.state, A, A);
    expect(step2.reconnect).toBe(false);
    expect(step2.state).toEqual(INITIAL_OWNER_DRIFT_STATE);

    const step3 = evaluateOwnerDrift(step2.state, A, B);
    expect(step3.reconnect).toBe(false);
    expect(step3.state).toEqual({ candidate: B, count: 1 });
  });

  test('two different candidates in a row do not confirm each other', () => {
    const step1 = evaluateOwnerDrift(INITIAL_OWNER_DRIFT_STATE, A, B);
    const step2 = evaluateOwnerDrift(step1.state, A, C);
    expect(step2.reconnect).toBe(false);
    expect(step2.state).toEqual({ candidate: C, count: 1 });
  });

  test('custom confirmations threshold', () => {
    const step1 = evaluateOwnerDrift(INITIAL_OWNER_DRIFT_STATE, A, B, 1);
    expect(step1.reconnect).toBe(true);
    expect(step1.state).toEqual(INITIAL_OWNER_DRIFT_STATE);
  });
});

describe('DriftMonitor', () => {
  const dummyConfig: Config = {
    port: 4700,
    version: 'unknown',
    pigeonUrl: 'http://pigeon.local',
    anchorUrl: 'http://anchor.local',
    pigeonAuthToken: undefined,
    routeTimeoutMs: 3000,
    cheapFirstByteMs: 5000,
    stickyTtlMs: 30000,
    driftCheckMs: 5000,
    wedgeProbeIntervalMs: 5000,
  };

  test('same owner -> never drops', async () => {
    let dropped = 0;
    const fakeFetch = vi.fn().mockResolvedValue({
      ok: true,
      status: 200,
      json: async () => ({ apiBase: 'http://127.0.0.1:4096' }),
    });

    const monitor = createDriftMonitor({
      extraction: { kind: 'single', sid: 'ses_a' },
      currentOwner: 'http://127.0.0.1:4096',
      config: dummyConfig,
      deps: { fetch: fakeFetch },
      onDrop: () => { dropped++; },
    });

    monitor.start();
    await monitor.runCheckOnce();
    await monitor.runCheckOnce();
    expect(dropped).toBe(0);
    monitor.stop();
  });

  test('different owner two consecutive checks -> drops exactly once', async () => {
    let dropped = 0;

    const fakeFetch = vi.fn().mockResolvedValue({
      ok: true,
      status: 200,
      json: async () => ({ apiBase: 'http://127.0.0.1:4097' }),
    });

    const monitor = createDriftMonitor({
      extraction: { kind: 'single', sid: 'ses_a' },
      currentOwner: 'http://127.0.0.1:4096',
      config: dummyConfig,
      deps: { fetch: fakeFetch },
      onDrop: () => { dropped++; },
    });

    monitor.start();
    await monitor.runCheckOnce();
    expect(dropped).toBe(0);

    await monitor.runCheckOnce();
    expect(dropped).toBe(1);

    // Call check once more to ensure it doesn't trigger onDrop again
    await monitor.runCheckOnce();
    expect(dropped).toBe(1);
    monitor.stop();
  });

  test('different owner with isMidTurn returning true -> does NOT drop', async () => {
    let dropped = 0;

    const fakeFetch = vi.fn().mockResolvedValue({
      ok: true,
      status: 200,
      json: async () => ({ apiBase: 'http://127.0.0.1:4097' }),
    });

    const monitor = createDriftMonitor({
      extraction: { kind: 'single', sid: 'ses_a' },
      currentOwner: 'http://127.0.0.1:4096',
      config: dummyConfig,
      isMidTurn: () => true,
      deps: { fetch: fakeFetch },
      onDrop: () => { dropped++; },
    });

    monitor.start();
    await monitor.runCheckOnce();
    expect(dropped).toBe(0);

    await monitor.runCheckOnce();
    expect(dropped).toBe(0); // suppressed!
    monitor.stop();
  });

  test('different owner with isMidTurn returning false -> drops', async () => {
    let dropped = 0;

    const fakeFetch = vi.fn().mockResolvedValue({
      ok: true,
      status: 200,
      json: async () => ({ apiBase: 'http://127.0.0.1:4097' }),
    });

    const monitor = createDriftMonitor({
      extraction: { kind: 'single', sid: 'ses_a' },
      currentOwner: 'http://127.0.0.1:4096',
      config: dummyConfig,
      isMidTurn: () => false,
      deps: { fetch: fakeFetch },
      onDrop: () => { dropped++; },
    });

    monitor.start();
    await monitor.runCheckOnce();
    expect(dropped).toBe(0);

    await monitor.runCheckOnce();
    expect(dropped).toBe(1); // drops!
    monitor.stop();
  });

  test('BLIP: pigeon network error / 500 / 404 repeatedly -> degraded -> NEVER drops', async () => {
    let dropped = 0;
    const fakeFetch = vi.fn().mockRejectedValue(new Error('Pigeon is dead'));

    const monitor = createDriftMonitor({
      extraction: { kind: 'single', sid: 'ses_a' },
      currentOwner: 'http://127.0.0.1:4096',
      config: dummyConfig,
      deps: { fetch: fakeFetch },
      onDrop: () => { dropped++; },
    });

    monitor.start();
    await monitor.runCheckOnce();
    await monitor.runCheckOnce();
    await monitor.runCheckOnce();
    expect(dropped).toBe(0);
    monitor.stop();
  });

  test('drift-observed, then a blip, then drift again -> the blip breaks consecutive -> no drop', async () => {
    let dropped = 0;
    let failFetch = false;
    const fakeFetch = vi.fn().mockImplementation(() => {
      if (failFetch) {
        return Promise.reject(new Error('Pigeon blip'));
      }
      return Promise.resolve({
        ok: true,
        status: 200,
        json: async () => ({ apiBase: 'http://127.0.0.1:4097' }),
      });
    });

    const monitor = createDriftMonitor({
      extraction: { kind: 'single', sid: 'ses_a' },
      currentOwner: 'http://127.0.0.1:4096',
      config: dummyConfig,
      deps: { fetch: fakeFetch },
      onDrop: () => { dropped++; },
    });

    monitor.start();
    // 1. First drift check -> candidate B, count 1
    await monitor.runCheckOnce();
    expect(dropped).toBe(0);

    // 2. Next check is a blip -> resets count to 0
    failFetch = true;
    await monitor.runCheckOnce();
    expect(dropped).toBe(0);

    // 3. Next check resolves to B again -> candidate B, count 1 (needs one more check to confirm)
    failFetch = false;
    await monitor.runCheckOnce();
    expect(dropped).toBe(0);

    // 4. Next check resolves to B again -> count 2 -> drops!
    await monitor.runCheckOnce();
    expect(dropped).toBe(1);
    monitor.stop();
  });

  test('multi-sid: parent moved + child 404 -> union yields parent new url -> drifts', async () => {
    let dropped = 0;
    const fakeFetch = vi.fn().mockImplementation((urlStr) => {
      if (urlStr.includes('session_id=ses_parent')) {
        return Promise.resolve({
          ok: true,
          status: 200,
          json: async () => ({ apiBase: 'http://127.0.0.1:4097' }),
        });
      } else {
        return Promise.resolve({
          ok: false,
          status: 404,
          json: async () => ({ error: 'not found' }),
        });
      }
    });

    const monitor = createDriftMonitor({
      extraction: { kind: 'multi', sids: ['ses_parent', 'ses_child'] },
      currentOwner: 'http://127.0.0.1:4096',
      config: dummyConfig,
      deps: { fetch: fakeFetch },
      onDrop: () => { dropped++; },
    });

    monitor.start();
    await monitor.runCheckOnce();
    expect(dropped).toBe(0);

    await monitor.runCheckOnce();
    expect(dropped).toBe(1);
    monitor.stop();
  });

  test('multi-sid: parent+child both stable -> no drift', async () => {
    let dropped = 0;
    const fakeFetch = vi.fn().mockResolvedValue({
      ok: true,
      status: 200,
      json: async () => ({ apiBase: 'http://127.0.0.1:4096' }),
    });

    const monitor = createDriftMonitor({
      extraction: { kind: 'multi', sids: ['ses_parent', 'ses_child'] },
      currentOwner: 'http://127.0.0.1:4096',
      config: dummyConfig,
      deps: { fetch: fakeFetch },
      onDrop: () => { dropped++; },
    });

    monitor.start();
    await monitor.runCheckOnce();
    await monitor.runCheckOnce();
    expect(dropped).toBe(0);
    monitor.stop();
  });

  test('multi-sid: diverging two real owners (child-moves-parent-stays) -> divergence: union size 2 -> console.warn fired once and NO drop', async () => {
    let dropped = 0;
    const fakeFetch = vi.fn().mockImplementation((urlStr) => {
      if (urlStr.includes('session_id=ses_parent')) {
        return Promise.resolve({
          ok: true,
          status: 200,
          json: async () => ({ apiBase: 'http://127.0.0.1:4096' }), // parent stays on currentOwner
        });
      } else {
        return Promise.resolve({
          ok: true,
          status: 200,
          json: async () => ({ apiBase: 'http://127.0.0.1:4097' }), // child moves to new lease
        });
      }
    });

    const consoleSpy = vi.spyOn(console, 'warn').mockImplementation(() => {});

    const monitor = createDriftMonitor({
      extraction: { kind: 'multi', sids: ['ses_parent', 'ses_child'] },
      currentOwner: 'http://127.0.0.1:4096',
      config: dummyConfig,
      deps: { fetch: fakeFetch },
      onDrop: () => { dropped++; },
    });

    monitor.start();
    await monitor.runCheckOnce();
    expect(dropped).toBe(0);
    expect(consoleSpy).toHaveBeenCalledTimes(1);
    expect(consoleSpy.mock.calls[0][0]).toContain("multi-session stream has diverging owners; leg cannot follow all sessions");

    // run check again, shouldn't log again (loggedDivergence logic)
    await monitor.runCheckOnce();
    expect(dropped).toBe(0);
    expect(consoleSpy).toHaveBeenCalledTimes(1);

    consoleSpy.mockRestore();
    monitor.stop();
  });

  test('FABLE2-S1 divergence logs once then resets when returning to size <= 1', async () => {
    let dropped = 0;
    let parentUrl = 'http://127.0.0.1:4096';
    let childUrl = 'http://127.0.0.1:4097';

    const fakeFetch = vi.fn().mockImplementation((urlStr) => {
      if (urlStr.includes('session_id=ses_parent')) {
        return Promise.resolve({
          ok: true,
          status: 200,
          json: async () => ({ apiBase: parentUrl }),
        });
      } else {
        return Promise.resolve({
          ok: true,
          status: 200,
          json: async () => ({ apiBase: childUrl }),
        });
      }
    });

    const consoleSpy = vi.spyOn(console, 'warn').mockImplementation(() => {});

    const monitor = createDriftMonitor({
      extraction: { kind: 'multi', sids: ['ses_parent', 'ses_child'] },
      currentOwner: 'http://127.0.0.1:4096',
      config: dummyConfig,
      deps: { fetch: fakeFetch },
      onDrop: () => { dropped++; },
    });

    monitor.start();

    // Episode 1: Divergence
    await monitor.runCheckOnce();
    expect(consoleSpy).toHaveBeenCalledTimes(1);

    // Run again during Episode 1: no new log
    await monitor.runCheckOnce();
    expect(consoleSpy).toHaveBeenCalledTimes(1);

    // Return to stability (size <= 1)
    childUrl = 'http://127.0.0.1:4096';
    await monitor.runCheckOnce();
    expect(consoleSpy).toHaveBeenCalledTimes(1); // Still 1

    // Episode 2: Divergence again -> resets and logs once more
    childUrl = 'http://127.0.0.1:4098';
    await monitor.runCheckOnce();
    expect(consoleSpy).toHaveBeenCalledTimes(2); // Logged again!

    // Run again during Episode 2: no new log
    await monitor.runCheckOnce();
    expect(consoleSpy).toHaveBeenCalledTimes(2);

    consoleSpy.mockRestore();
    monitor.stop();
  });

  test('stop() before/after -> no further checks, no onDrop', async () => {
    let dropped = 0;
    const fakeFetch = vi.fn().mockResolvedValue({
      ok: true,
      status: 200,
      json: async () => ({ apiBase: 'http://127.0.0.1:4097' }),
    });

    const monitor = createDriftMonitor({
      extraction: { kind: 'single', sid: 'ses_a' },
      currentOwner: 'http://127.0.0.1:4096',
      config: dummyConfig,
      deps: { fetch: fakeFetch },
      onDrop: () => { dropped++; },
    });

    monitor.start();
    await monitor.runCheckOnce();
    monitor.stop();
    await monitor.runCheckOnce();
    expect(dropped).toBe(0);
  });
});
