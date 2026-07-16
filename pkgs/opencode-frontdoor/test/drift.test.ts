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
    pigeonUrl: 'http://pigeon.local',
    anchorUrl: 'http://anchor.local',
    pigeonAuthToken: undefined,
    routeTimeoutMs: 3000,
    cheapFirstByteMs: 5000,
    stickyTtlMs: 30000,
    driftCheckMs: 5000,
    quiesceMs: 10000,
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

  test('different owner two consecutive checks, quiescent -> drops exactly once', async () => {
    let dropped = 0;
    let currentTime = 100000;
    const fakeNow = () => currentTime;

    const fakeFetch = vi.fn().mockResolvedValue({
      ok: true,
      status: 200,
      json: async () => ({ apiBase: 'http://127.0.0.1:4097' }),
    });

    const monitor = createDriftMonitor({
      extraction: { kind: 'single', sid: 'ses_a' },
      currentOwner: 'http://127.0.0.1:4096',
      config: dummyConfig,
      deps: { fetch: fakeFetch, now: fakeNow },
      onDrop: () => { dropped++; },
    });

    monitor.start();
    await monitor.runCheckOnce();
    expect(dropped).toBe(0);

    currentTime += 15000; // past quiesceMs
    await monitor.runCheckOnce();
    expect(dropped).toBe(1);

    // Call check once more to ensure it doesn't trigger onDrop again
    currentTime += 15000;
    await monitor.runCheckOnce();
    expect(dropped).toBe(1);
    monitor.stop();
  });

  test('BLIP: pigeon network error / 500 / 404 repeatedly -> degraded -> NEVER drops', async () => {
    let dropped = 0;
    let currentTime = 100000;
    const fakeNow = () => currentTime;
    const fakeFetch = vi.fn().mockRejectedValue(new Error('Pigeon is dead'));

    const monitor = createDriftMonitor({
      extraction: { kind: 'single', sid: 'ses_a' },
      currentOwner: 'http://127.0.0.1:4096',
      config: dummyConfig,
      deps: { fetch: fakeFetch, now: fakeNow },
      onDrop: () => { dropped++; },
    });

    monitor.start();
    await monitor.runCheckOnce();
    currentTime += 15000;
    await monitor.runCheckOnce();
    currentTime += 15000;
    await monitor.runCheckOnce();
    expect(dropped).toBe(0);
    monitor.stop();
  });

  test('drift-observed, then a blip, then drift again -> the blip breaks consecutive -> no drop', async () => {
    let dropped = 0;
    let failFetch = false;
    let currentTime = 100000;
    const fakeNow = () => currentTime;
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
      deps: { fetch: fakeFetch, now: fakeNow },
      onDrop: () => { dropped++; },
    });

    monitor.start();
    // 1. First drift check -> candidate B, count 1
    await monitor.runCheckOnce();
    expect(dropped).toBe(0);

    // 2. Next check is a blip -> resets count to 0
    failFetch = true;
    currentTime += 15000;
    await monitor.runCheckOnce();
    expect(dropped).toBe(0);

    // 3. Next check resolves to B again -> candidate B, count 1 (needs one more check to confirm)
    failFetch = false;
    currentTime += 15000;
    await monitor.runCheckOnce();
    expect(dropped).toBe(0);

    // 4. Next check resolves to B again -> count 2 -> drops!
    currentTime += 15000;
    await monitor.runCheckOnce();
    expect(dropped).toBe(1);
    monitor.stop();
  });

  test('active-guard: two consecutive different-owner checks but markActivity called -> NO drop, then drops when quiescent', async () => {
    let dropped = 0;
    let currentTime = 100000;
    const fakeNow = () => currentTime;

    const fakeFetch = vi.fn().mockResolvedValue({
      ok: true,
      status: 200,
      json: async () => ({ apiBase: 'http://127.0.0.1:4097' }),
    });

    const monitor = createDriftMonitor({
      extraction: { kind: 'single', sid: 'ses_a' },
      currentOwner: 'http://127.0.0.1:4096',
      config: dummyConfig,
      deps: { fetch: fakeFetch, now: fakeNow },
      onDrop: () => { dropped++; },
    });

    monitor.start(); // lastActivityAt = 100000
    
    // First different owner check
    await monitor.runCheckOnce();
    expect(dropped).toBe(0);

    // Call markActivity to keep it active
    currentTime += 8000; // 108000
    monitor.markActivity(); // lastActivityAt = 108000

    // Second different owner check at 109000 (1000ms after activity)
    currentTime += 1000; // 109000
    await monitor.runCheckOnce(); // different again, but isActive is true (1000ms < 10000ms)
    expect(dropped).toBe(0); // active guard prevents drop, state is re-armed to count 1

    // Let's do another check after some time, but still active
    currentTime += 5000; // 114000
    monitor.markActivity(); // lastActivityAt = 114000
    currentTime += 2000; // 116000
    await monitor.runCheckOnce(); // different again, but still active (2000ms < 10000ms)
    expect(dropped).toBe(0);

    // Now let's let it run past quiesceMs (10000ms)
    currentTime += 12000; // 128000 (14000ms since last activity)
    await monitor.runCheckOnce(); // third check (consecutive), quiescent -> drops!
    expect(dropped).toBe(1);
    monitor.stop();
  });

  test('multi-sid: parent moved + child 404 -> union yields parent new url -> drifts', async () => {
    let dropped = 0;
    let currentTime = 100000;
    const fakeNow = () => currentTime;
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
      deps: { fetch: fakeFetch, now: fakeNow },
      onDrop: () => { dropped++; },
    });

    monitor.start();
    await monitor.runCheckOnce();
    expect(dropped).toBe(0);

    currentTime += 15000;
    await monitor.runCheckOnce();
    expect(dropped).toBe(1);
    monitor.stop();
  });

  test('multi-sid: parent+child both stable -> no drift', async () => {
    let dropped = 0;
    let currentTime = 100000;
    const fakeNow = () => currentTime;
    const fakeFetch = vi.fn().mockResolvedValue({
      ok: true,
      status: 200,
      json: async () => ({ apiBase: 'http://127.0.0.1:4096' }),
    });

    const monitor = createDriftMonitor({
      extraction: { kind: 'multi', sids: ['ses_parent', 'ses_child'] },
      currentOwner: 'http://127.0.0.1:4096',
      config: dummyConfig,
      deps: { fetch: fakeFetch, now: fakeNow },
      onDrop: () => { dropped++; },
    });

    monitor.start();
    await monitor.runCheckOnce();
    currentTime += 15000;
    await monitor.runCheckOnce();
    expect(dropped).toBe(0);
    monitor.stop();
  });

  test('multi-sid: diverging two real owners -> effectiveResolved is currentOwner -> no drop', async () => {
    let dropped = 0;
    let currentTime = 100000;
    const fakeNow = () => currentTime;
    const fakeFetch = vi.fn().mockImplementation((urlStr) => {
      if (urlStr.includes('session_id=ses_parent')) {
        return Promise.resolve({
          ok: true,
          status: 200,
          json: async () => ({ apiBase: 'http://127.0.0.1:4097' }),
        });
      } else {
        return Promise.resolve({
          ok: true,
          status: 200,
          json: async () => ({ apiBase: 'http://127.0.0.1:4098' }),
        });
      }
    });

    const monitor = createDriftMonitor({
      extraction: { kind: 'multi', sids: ['ses_parent', 'ses_child'] },
      currentOwner: 'http://127.0.0.1:4096',
      config: dummyConfig,
      deps: { fetch: fakeFetch, now: fakeNow },
      onDrop: () => { dropped++; },
    });

    monitor.start();
    await monitor.runCheckOnce();
    currentTime += 15000;
    await monitor.runCheckOnce();
    expect(dropped).toBe(0);
    monitor.stop();
  });

  test('stop() before/after -> no further checks, no onDrop', async () => {
    let dropped = 0;
    let currentTime = 100000;
    const fakeNow = () => currentTime;
    const fakeFetch = vi.fn().mockResolvedValue({
      ok: true,
      status: 200,
      json: async () => ({ apiBase: 'http://127.0.0.1:4097' }),
    });

    const monitor = createDriftMonitor({
      extraction: { kind: 'single', sid: 'ses_a' },
      currentOwner: 'http://127.0.0.1:4096',
      config: dummyConfig,
      deps: { fetch: fakeFetch, now: fakeNow },
      onDrop: () => { dropped++; },
    });

    monitor.start();
    await monitor.runCheckOnce();
    monitor.stop();
    currentTime += 15000;
    await monitor.runCheckOnce();
    expect(dropped).toBe(0);
  });
});
