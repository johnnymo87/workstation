import { describe, test, expect, vi, beforeEach } from 'vitest';
import { rootOf, clearRootCache, FAILURE_TTL_MS, NOT_FOUND_TTL_MS } from '../src/parent.js';
import type { Config } from '../src/config.js';

describe('rootOf', () => {
  const dummyConfig: Config = {
    port: 4700,
    version: 'unknown',
    pigeonUrl: 'http://pigeon.local',
    anchorUrl: 'http://anchor.local',
    poolUrls: ['http://anchor.local'],
    pigeonAuthToken: undefined,
    routeTimeoutMs: 3000,
    cheapFirstByteMs: 5000,
    stickyTtlMs: 30000,
    driftCheckMs: 5000,
    wedgeProbeIntervalMs: 5000,
    mintTimeoutMs: 60000,
    logSampleN: 1,
    logSummaryIntervalMs: 300000,
  };

  beforeEach(() => {
    clearRootCache();
  });

  test('1. sid with no parentID -> {root: sid, confirmed: true}; exactly 1 fetch; correct URL', async () => {
    const fakeFetch = vi.fn().mockResolvedValue({
      ok: true,
      status: 200,
      json: async () => ({ parentID: null }),
    });

    const result = await rootOf('root_123', dummyConfig, { fetch: fakeFetch });

    expect(result).toEqual({ root: 'root_123', confirmed: true, fetchedLive: true });
    expect(fakeFetch).toHaveBeenCalledTimes(1);
    const [url, init] = fakeFetch.mock.calls[0] as [string, RequestInit];
    expect(url).toBe('http://anchor.local/session/root_123');
    expect(init.method).toBe('GET');
  });

  test('2. child -> parent(root): {root: parent, confirmed: true}; 2 fetches', async () => {
    const fakeFetch = vi.fn().mockImplementation(async (url: string) => {
      if (url.includes('child_sid')) {
        return {
          ok: true,
          status: 200,
          json: async () => ({ parentID: 'parent_sid' }),
        };
      }
      return {
        ok: true,
        status: 200,
        json: async () => ({ parentID: null }),
      };
    });

    const result = await rootOf('child_sid', dummyConfig, { fetch: fakeFetch });

    expect(result).toEqual({ root: 'parent_sid', confirmed: true, fetchedLive: true });
    expect(fakeFetch).toHaveBeenCalledTimes(2);
  });

  test('3. multi-level grandchild -> child -> root: correct root; 3 fetches', async () => {
    const fakeFetch = vi.fn().mockImplementation(async (url: string) => {
      if (url.includes('grandchild')) {
        return { ok: true, status: 200, json: async () => ({ parentID: 'child' }) };
      }
      if (url.includes('child')) {
        return { ok: true, status: 200, json: async () => ({ parentID: 'root' }) };
      }
      return { ok: true, status: 200, json: async () => ({ parentID: null }) };
    });

    const result = await rootOf('grandchild', dummyConfig, { fetch: fakeFetch });

    expect(result).toEqual({ root: 'root', confirmed: true, fetchedLive: true });
    expect(fakeFetch).toHaveBeenCalledTimes(3);
  });

  test('4. caching: second rootOf for same sid does 0 fetches; querying intermediate does 0 fetches', async () => {
    const fakeFetch = vi.fn().mockImplementation(async (url: string) => {
      if (url.includes('grandchild')) {
        return { ok: true, status: 200, json: async () => ({ parentID: 'child' }) };
      }
      if (url.includes('child')) {
        return { ok: true, status: 200, json: async () => ({ parentID: 'root' }) };
      }
      return { ok: true, status: 200, json: async () => ({ parentID: null }) };
    });

    await rootOf('grandchild', dummyConfig, { fetch: fakeFetch });
    expect(fakeFetch).toHaveBeenCalledTimes(3);

    fakeFetch.mockClear();

    // Query same grandchild again
    const res1 = await rootOf('grandchild', dummyConfig, { fetch: fakeFetch });
    expect(res1).toEqual({ root: 'root', confirmed: true, fetchedLive: false });
    expect(fakeFetch).toHaveBeenCalledTimes(0);

    // Query intermediate child
    const res2 = await rootOf('child', dummyConfig, { fetch: fakeFetch });
    expect(res2).toEqual({ root: 'root', confirmed: true, fetchedLive: false });
    expect(fakeFetch).toHaveBeenCalledTimes(0);

    // Query root
    const res3 = await rootOf('root', dummyConfig, { fetch: fakeFetch });
    expect(res3).toEqual({ root: 'root', confirmed: true, fetchedLive: false });
    expect(fakeFetch).toHaveBeenCalledTimes(0);
  });

  test('5. 404 at hop 1 -> {confirmed:false}; cached for the SHORT not-found TTL only, then refetches', async () => {
    let currentTime = 1000;
    const fakeNow = () => currentTime;

    const fakeFetch = vi.fn().mockResolvedValue({
      ok: true,
      status: 404,
      json: async () => ({ error: 'not found' }),
    });

    const res1 = await rootOf('unknown_sid', dummyConfig, { fetch: fakeFetch, now: fakeNow });
    expect(res1).toEqual({ confirmed: false });
    expect(fakeFetch).toHaveBeenCalledTimes(1);

    fakeFetch.mockClear();

    // Within the short not-found TTL -> served from cache.
    currentTime += NOT_FOUND_TTL_MS - 100;
    const res2 = await rootOf('unknown_sid', dummyConfig, { fetch: fakeFetch, now: fakeNow });
    expect(res2).toEqual({ confirmed: false });
    expect(fakeFetch).toHaveBeenCalledTimes(0);

    // Past the short TTL -> refetches. A 404 must NOT be pinned for the full
    // FAILURE_TTL_MS: it is the expected transient answer while a just-minted
    // subagent session becomes visible, and pinning it would route that child's
    // permission traffic to the wrong process for the whole window.
    currentTime += 200;
    const res3 = await rootOf('unknown_sid', dummyConfig, { fetch: fakeFetch, now: fakeNow });
    expect(res3).toEqual({ confirmed: false });
    expect(fakeFetch).toHaveBeenCalledTimes(1);
    expect(NOT_FOUND_TTL_MS).toBeLessThan(FAILURE_TTL_MS);
  });

  test('5b. a NETWORK error keeps the long failure TTL (anchor fault, not a session fact)', async () => {
    let currentTime = 1000;
    const fakeNow = () => currentTime;
    const fakeFetch = vi.fn().mockRejectedValue(new Error('ECONNREFUSED'));

    expect(await rootOf('sid_neterr', dummyConfig, { fetch: fakeFetch, now: fakeNow }))
      .toEqual({ confirmed: false });
    expect(fakeFetch).toHaveBeenCalledTimes(1);

    fakeFetch.mockClear();
    // Past the short not-found TTL, still inside the long failure TTL -> cached.
    currentTime += NOT_FOUND_TTL_MS + 1000;
    expect(await rootOf('sid_neterr', dummyConfig, { fetch: fakeFetch, now: fakeNow }))
      .toEqual({ confirmed: false });
    expect(fakeFetch).toHaveBeenCalledTimes(0);
  });

  test('5d. L1: a walk that fails while a CONCURRENT walk succeeds must not stamp a failure over it', async () => {
    // The real L1 race: two walks for the same sid both miss the entry cache, then
    // one succeeds and caches while the other is still in flight and about to fail.
    // Test 5c below only proves the entry-cache short-circuit; it cannot reach the
    // guard at all, so this is the one that actually pins it.
    let failA!: (e: Error) => void;
    const hangingA = new Promise<any>((_res, rej) => { failA = rej; });

    let call = 0;
    const fakeFetch = vi.fn().mockImplementation(() => {
      call++;
      if (call === 1) return hangingA;               // walk A: in flight, will fail
      return Promise.resolve({                        // walk B: succeeds
        ok: true,
        status: 200,
        json: async () => ({ id: 'sid_race' }),
      });
    });

    const walkA = rootOf('sid_race', dummyConfig, { fetch: fakeFetch });
    const walkB = rootOf('sid_race', dummyConfig, { fetch: fakeFetch });

    // B completes first and caches the confirmed root.
    expect(await walkB).toEqual({ root: 'sid_race', confirmed: true, fetchedLive: true });

    // Now A fails. Without the guard it would stamp a 30s failure over B's success.
    failA(new Error('boom'));
    await walkA;

    // The proven root must survive, served from cache with no further fetching.
    const probe = vi.fn();
    expect(await rootOf('sid_race', dummyConfig, { fetch: probe }))
      .toEqual({ root: 'sid_race', confirmed: true, fetchedLive: false });
    expect(probe).toHaveBeenCalledTimes(0);
  });

  test('5c. a failure must NOT overwrite a success a concurrent walk already proved', async () => {
    // Warm a confirmed root, then make the anchor fail for the same sid.
    const okFetch = vi.fn().mockResolvedValue({
      ok: true,
      status: 200,
      json: async () => ({ id: 'sid_x' }),
    });
    expect(await rootOf('sid_x', dummyConfig, { fetch: okFetch }))
      .toEqual({ root: 'sid_x', confirmed: true, fetchedLive: true });

    // A later failing walk cannot happen for a cached sid (cache short-circuits),
    // so drive the invariant directly: the cached success must still win.
    const failFetch = vi.fn().mockRejectedValue(new Error('boom'));
    expect(await rootOf('sid_x', dummyConfig, { fetch: failFetch }))
      .toEqual({ root: 'sid_x', confirmed: true, fetchedLive: false });
    expect(failFetch).toHaveBeenCalledTimes(0);
  });

  test('6. 404 at an ANCESTOR hop (child ok, parent 404) -> {confirmed:false} and NOT cached as a success', async () => {
    let currentTime = 1000;
    const fakeNow = () => currentTime;

    const fakeFetch = vi.fn().mockImplementation(async (url: string) => {
      if (url.includes('child_sid')) {
        return { ok: true, status: 200, json: async () => ({ parentID: 'deleted_parent' }) };
      }
      return { ok: true, status: 404, json: async () => ({ error: 'not found' }) };
    });

    const res1 = await rootOf('child_sid', dummyConfig, { fetch: fakeFetch, now: fakeNow });
    expect(res1).toEqual({ confirmed: false });
    expect(fakeFetch).toHaveBeenCalledTimes(2);

    fakeFetch.mockClear();

    // Within failure TTL, child_sid returns failure without fetching
    const res2 = await rootOf('child_sid', dummyConfig, { fetch: fakeFetch, now: fakeNow });
    expect(res2).toEqual({ confirmed: false });
    expect(fakeFetch).toHaveBeenCalledTimes(0);

    // Advance time past 30s
    currentTime += FAILURE_TTL_MS + 100;

    // After failure TTL, child_sid refetches and fails again (it was NOT cached as success)
    const res3 = await rootOf('child_sid', dummyConfig, { fetch: fakeFetch, now: fakeNow });
    expect(res3).toEqual({ confirmed: false });
    expect(fakeFetch).toHaveBeenCalledTimes(2);
  });

  test('7. network error / thrown fetch -> {confirmed:false}', async () => {
    const fakeFetch = vi.fn().mockRejectedValue(new Error('Network connection failed'));

    const result = await rootOf('sid_net_err', dummyConfig, { fetch: fakeFetch });
    expect(result).toEqual({ confirmed: false });
  });

  test('8. malformed JSON body on 200 -> {confirmed:false}', async () => {
    const fakeFetch = vi.fn().mockResolvedValue({
      ok: true,
      status: 200,
      json: async () => {
        throw new SyntaxError('Unexpected token < in JSON');
      },
    });

    const result = await rootOf('sid_bad_json', dummyConfig, { fetch: fakeFetch });
    expect(result).toEqual({ confirmed: false });
  });

  test('9. depth bound: a chain longer than 8 -> {confirmed:false}', async () => {
    const fakeFetch = vi.fn().mockImplementation(async (url: string) => {
      const match = url.match(/s(\d+)$/);
      if (match) {
        const num = parseInt(match[1], 10);
        return {
          ok: true,
          status: 200,
          json: async () => ({ parentID: `s${num + 1}` }),
        };
      }
      return { ok: true, status: 200, json: async () => ({ parentID: null }) };
    });

    const result = await rootOf('s1', dummyConfig, { fetch: fakeFetch });
    expect(result).toEqual({ confirmed: false });
    expect(fakeFetch).toHaveBeenCalledTimes(8);
  });

  test('10. cycle: A->B->A -> {confirmed:false} (terminates, does not hang)', async () => {
    const fakeFetch = vi.fn().mockImplementation(async (url: string) => {
      if (url.includes('sid_a')) {
        return { ok: true, status: 200, json: async () => ({ parentID: 'sid_b' }) };
      }
      return { ok: true, status: 200, json: async () => ({ parentID: 'sid_a' }) };
    });

    const result = await rootOf('sid_a', dummyConfig, { fetch: fakeFetch });
    expect(result).toEqual({ confirmed: false });
    expect(fakeFetch).toHaveBeenCalledTimes(2);
  });

  test('11. overall deadline: with a now that jumps past routeTimeoutMs mid-walk, returns {confirmed:false} and stops fetching', async () => {
    let currentTime = 1000;
    const fakeNow = () => currentTime;

    const fakeFetch = vi.fn().mockImplementation(async (url: string) => {
      if (url.includes('child_sid')) {
        // Jump past routeTimeoutMs (3000ms)
        currentTime += 5000;
        return { ok: true, status: 200, json: async () => ({ parentID: 'parent_sid' }) };
      }
      return { ok: true, status: 200, json: async () => ({ parentID: null }) };
    });

    const result = await rootOf('child_sid', dummyConfig, { fetch: fakeFetch, now: fakeNow });
    expect(result).toEqual({ confirmed: false });
    expect(fakeFetch).toHaveBeenCalledTimes(1);
  });

  test('12. FIFO bound: insert >2000 distinct sids, assert map does not exceed 2000 (earliest sid refetches)', async () => {
    const fakeFetch = vi.fn().mockImplementation(async () => {
      return { ok: true, status: 200, json: async () => ({ parentID: null }) };
    });

    // Insert 2001 distinct root sids
    for (let i = 0; i <= 2000; i++) {
      await rootOf(`item_${i}`, dummyConfig, { fetch: fakeFetch });
    }

    expect(fakeFetch).toHaveBeenCalledTimes(2001);
    fakeFetch.mockClear();

    // item_1 (second oldest) was not evicted -> returned from cache with 0 fetches
    await rootOf('item_1', dummyConfig, { fetch: fakeFetch });
    expect(fakeFetch).toHaveBeenCalledTimes(0);

    fakeFetch.mockClear();

    // item_0 (oldest) was evicted by FIFO eviction -> must refetch
    await rootOf('item_0', dummyConfig, { fetch: fakeFetch });
    expect(fakeFetch).toHaveBeenCalledTimes(1);
  });
});
