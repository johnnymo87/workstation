import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import { createWedgeProbe } from '../src/wedge.js';
import type { Config } from '../src/config.js';

describe('Wedge Health Probe', () => {
  const dummyConfig: Config = {
    port: 4700,
    pigeonUrl: 'http://pigeon.local',
    anchorUrl: 'http://anchor.local',
    pigeonAuthToken: undefined,
    routeTimeoutMs: 3000,
    cheapFirstByteMs: 5000,
    stickyTtlMs: 30000,
    driftCheckMs: 5000,
    wedgeProbeIntervalMs: 50, // fast for testing
  };

  beforeEach(() => {
    vi.useFakeTimers();
  });

  afterEach(() => {
    vi.useRealTimers();
    vi.restoreAllMocks();
  });

  test('probe returns 200 repeatedly -> onWedged never called', async () => {
    let onWedgedCalled = 0;
    const fakeFetch = vi.fn().mockResolvedValue({
      ok: true,
      status: 200,
    });

    const probe = createWedgeProbe({
      target: 'http://127.0.0.1:4096',
      config: dummyConfig,
      deps: { fetch: fakeFetch },
      onWedged: () => { onWedgedCalled++; }
    });

    probe.start();

    // Advance by interval multiple times
    for (let i = 0; i < 5; i++) {
      await vi.advanceTimersByTimeAsync(50);
    }

    expect(onWedgedCalled).toBe(0);
    expect(fakeFetch).toHaveBeenCalledTimes(5);
    probe.stop();
  });

  test('probe times out twice consecutive -> onWedged called once and only once', async () => {
    let onWedgedCalled = 0;
    const fakeFetch = vi.fn().mockRejectedValue(new Error('timeout')); // or network error

    const probe = createWedgeProbe({
      target: 'http://127.0.0.1:4096',
      config: dummyConfig,
      deps: { fetch: fakeFetch },
      onWedged: () => { onWedgedCalled++; }
    });

    probe.start();

    // 1st failure
    await vi.advanceTimersByTimeAsync(50);
    expect(onWedgedCalled).toBe(0);

    // 2nd failure -> wedged declared
    await vi.advanceTimersByTimeAsync(50);
    expect(onWedgedCalled).toBe(1);

    // 3rd interval -> should have stopped, so no more fetch calls
    await vi.advanceTimersByTimeAsync(50);
    expect(onWedgedCalled).toBe(1);
    expect(fakeFetch).toHaveBeenCalledTimes(2);

    probe.stop();
  });

  test('one failure then a success resets the counter (no wedge)', async () => {
    let onWedgedCalled = 0;
    let shouldFail = true;
    const fakeFetch = vi.fn().mockImplementation(() => {
      if (shouldFail) {
        shouldFail = false;
        return Promise.reject(new Error('fail'));
      }
      return Promise.resolve({
        ok: true,
        status: 200,
      });
    });

    const probe = createWedgeProbe({
      target: 'http://127.0.0.1:4096',
      config: dummyConfig,
      deps: { fetch: fakeFetch },
      onWedged: () => { onWedgedCalled++; }
    });

    probe.start();

    // 1st interval -> fails
    await vi.advanceTimersByTimeAsync(50);
    expect(onWedgedCalled).toBe(0);

    // 2nd interval -> succeeds
    await vi.advanceTimersByTimeAsync(50);
    expect(onWedgedCalled).toBe(0);

    // 3rd interval -> fails again (first failure after reset)
    shouldFail = true;
    await vi.advanceTimersByTimeAsync(50);
    expect(onWedgedCalled).toBe(0);

    // 4th interval -> fails again -> consecutive 2nd failure -> wedged!
    shouldFail = true;
    await vi.advanceTimersByTimeAsync(50);
    expect(onWedgedCalled).toBe(1);

    probe.stop();
  });

  test('stop() before a probe resolves -> onWedged not called', async () => {
    let onWedgedCalled = 0;
    let resolveProbe: any;
    const probePromise = new Promise((resolve) => {
      resolveProbe = resolve;
    });

    const fakeFetch = vi.fn().mockImplementation(() => probePromise);

    const probe = createWedgeProbe({
      target: 'http://127.0.0.1:4096',
      config: dummyConfig,
      deps: { fetch: fakeFetch },
      onWedged: () => { onWedgedCalled++; }
    });

    probe.start();

    // Trigger the first probe
    await vi.advanceTimersByTimeAsync(50);
    expect(fakeFetch).toHaveBeenCalledTimes(1);

    // Stop before it resolves
    probe.stop();

    // Now resolve it to non-200 (a failure)
    resolveProbe({ ok: false, status: 500 });
    await Promise.resolve(); // flush microtasks

    expect(onWedgedCalled).toBe(0);
  });
});
