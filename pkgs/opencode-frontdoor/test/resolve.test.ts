// unwired-test(workstation-5m47): unhermetic (npm ci + loopback sockets); belongs in a ci.yml step, not a nix check
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import { resolveOwner } from '../src/resolve.js';
import { clearRootCache } from '../src/parent.js';
import { invalidateDaemonToken } from '../src/http.js';
import type { Config } from '../src/config.js';

describe('resolveOwner', () => {
  let originalEnv: NodeJS.ProcessEnv;

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
  };

  beforeEach(() => {
    originalEnv = { ...process.env };
    clearRootCache();
    delete process.env.PIGEON_DAEMON_AUTH_TOKEN;
    process.env.PIGEON_DAEMON_AUTH_TOKEN_FILE = '/nonexistent';
    invalidateDaemonToken();
  });

  afterEach(() => {
    for (const key of Object.keys(process.env)) {
      if (!(key in originalEnv)) {
        delete process.env[key];
      }
    }
    Object.assign(process.env, originalEnv);
    invalidateDaemonToken();
  });

  test('active route (200, apiBase) -> url + reason "active", degraded false', async () => {
    const fakeFetch = vi.fn().mockResolvedValue({
      ok: true,
      status: 200,
      json: async () => ({ apiBase: 'http://active-serve.local' }),
    });

    const result = await resolveOwner('sid_123', dummyConfig, { fetch: fakeFetch });

    expect(result).toEqual({
      url: 'http://active-serve.local',
      prospective: false,
      degraded: false,
      reason: 'active',
      routingSid: 'sid_123',
    });

    expect(fakeFetch).toHaveBeenCalledTimes(1);
    const [requestUrl, requestInit] = fakeFetch.mock.calls[0] as [string, RequestInit];
    expect(requestUrl).toBe('http://pigeon.local/route?session_id=sid_123');
    expect(requestInit.method).toBe('GET');
    const headers = requestInit?.headers as Record<string, string> | undefined;
    expect(headers?.['Authorization'] || headers?.['authorization']).toBeUndefined();
  });

  test('prospective route (200, prospective:true, apiBase) -> url + reason "prospective", degraded false', async () => {
    const fakeFetch = vi.fn().mockResolvedValue({
      ok: true,
      status: 200,
      json: async () => ({ apiBase: 'http://prospective-serve.local', prospective: true }),
    });

    const result = await resolveOwner('sid_123', dummyConfig, { fetch: fakeFetch });

    expect(result).toEqual({
      url: 'http://prospective-serve.local',
      prospective: true,
      degraded: false,
      reason: 'prospective',
      routingSid: 'sid_123',
    });
  });

  test('api_base (snake_case) accepted as well as apiBase', async () => {
    const fakeFetch = vi.fn().mockResolvedValue({
      ok: true,
      status: 200,
      json: async () => ({ api_base: 'http://snake-serve.local' }),
    });

    const result = await resolveOwner('sid_123', dummyConfig, { fetch: fakeFetch });

    expect(result).toEqual({
      url: 'http://snake-serve.local',
      prospective: false,
      degraded: false,
      reason: 'active',
      routingSid: 'sid_123',
    });
  });

  test('Bearer token header present when pigeonAuthToken is configured', async () => {
    const tokenConfig: Config = { ...dummyConfig, pigeonAuthToken: 'my-secret-token' };
    const fakeFetch = vi.fn().mockResolvedValue({
      ok: true,
      status: 200,
      json: async () => ({ apiBase: 'http://active-serve.local' }),
    });

    await resolveOwner('sid_123', tokenConfig, { fetch: fakeFetch });

    expect(fakeFetch).toHaveBeenCalledTimes(1);
    const [, requestInit] = fakeFetch.mock.calls[0] as [string, RequestInit];
    const headers = requestInit?.headers as Record<string, string> | undefined;
    expect(headers?.['Authorization'] || headers?.['authorization']).toBe('Bearer my-secret-token');
  });

  test('404 from pigeon + anchor walk fails -> anchor + reason "not-routed", degraded true, routingSid: null', async () => {
    const fakeFetch = vi.fn().mockResolvedValue({
      ok: false,
      status: 404,
      json: async () => ({ error: 'session not routed' }),
    });

    const result = await resolveOwner('sid_123', dummyConfig, { fetch: fakeFetch });

    expect(result).toEqual({
      url: 'http://anchor.local',
      prospective: false,
      degraded: true,
      reason: 'not-routed',
      routingSid: null,
    });
  });

  test('500/503 from pigeon -> anchor + reason "pigeon-error", degraded true, routingSid: sid', async () => {
    const fakeFetch = vi.fn().mockResolvedValue({
      ok: false,
      status: 503,
      json: async () => ({ error: 'routing not configured' }),
    });

    const result = await resolveOwner('sid_123', dummyConfig, { fetch: fakeFetch });

    expect(result).toEqual({
      url: 'http://anchor.local',
      prospective: false,
      degraded: true,
      reason: 'pigeon-error',
      routingSid: 'sid_123',
    });
    expect(fakeFetch).toHaveBeenCalledTimes(1);
  });

  test('200 with missing apiBase/api_base -> anchor + reason "pigeon-error", degraded true', async () => {
    const fakeFetch = vi.fn().mockResolvedValue({
      ok: true,
      status: 200,
      json: async () => ({ otherField: 'some-value' }),
    });

    const result = await resolveOwner('sid_123', dummyConfig, { fetch: fakeFetch });

    expect(result).toEqual({
      url: 'http://anchor.local',
      prospective: false,
      degraded: true,
      reason: 'pigeon-error',
      routingSid: 'sid_123',
    });
  });

  test('200 with bad JSON -> anchor + reason "pigeon-error", degraded true', async () => {
    const fakeFetch = vi.fn().mockResolvedValue({
      ok: true,
      status: 200,
      json: async () => {
        throw new Error('JSON parse error');
      },
    });

    const result = await resolveOwner('sid_123', dummyConfig, { fetch: fakeFetch });

    expect(result).toEqual({
      url: 'http://anchor.local',
      prospective: false,
      degraded: true,
      reason: 'pigeon-error',
      routingSid: 'sid_123',
    });
  });

  test('network error (fetch rejects) -> anchor + reason "pigeon-unreachable", degraded true', async () => {
    const fakeFetch = vi.fn().mockRejectedValue(new Error('Network connection failed'));

    const result = await resolveOwner('sid_123', dummyConfig, { fetch: fakeFetch });

    expect(result).toEqual({
      url: 'http://anchor.local',
      prospective: false,
      degraded: true,
      reason: 'pigeon-unreachable',
      routingSid: 'sid_123',
    });
    expect(fakeFetch).toHaveBeenCalledTimes(1);
  });

  test('timeout (fetch takes too long) -> anchor + reason "pigeon-unreachable", degraded true', async () => {
    const timeoutConfig: Config = { ...dummyConfig, routeTimeoutMs: 20 };
    
    let timerId: NodeJS.Timeout | undefined;
    const fakeFetch = vi.fn().mockImplementation((_url, options) => {
      return new Promise((resolve, reject) => {
        const signal = options?.signal as AbortSignal | undefined;
        const onAbort = () => {
          if (timerId) clearTimeout(timerId);
          reject(new DOMException('The user aborted a request.', 'AbortError'));
        };
        if (signal?.aborted) {
          onAbort();
          return;
        }
        signal?.addEventListener('abort', onAbort);
        
        timerId = setTimeout(() => {
          signal?.removeEventListener('abort', onAbort);
          resolve({
            ok: true,
            status: 200,
            json: async () => ({ apiBase: 'http://too-late.local' }),
          });
        }, 100);
      });
    });

    const result = await resolveOwner('sid_123', timeoutConfig, { fetch: fakeFetch });

    expect(result).toEqual({
      url: 'http://anchor.local',
      prospective: false,
      degraded: true,
      reason: 'pigeon-unreachable',
      routingSid: 'sid_123',
    });

    expect(fakeFetch).toHaveBeenCalledTimes(1);
    const [, requestInit] = fakeFetch.mock.calls[0] as [string, RequestInit];
    expect(requestInit.signal).toBeDefined();
    expect(requestInit.signal?.aborted).toBe(true);
  });

  test('200 with a non-absolute apiBase -> degrade to anchor, reason "pigeon-error"', async () => {
    const fakeFetch = vi.fn().mockResolvedValue({
      ok: true,
      status: 200,
      json: async () => ({ apiBase: '/relative/path' }),
    });

    const result = await resolveOwner('sid_123', dummyConfig, { fetch: fakeFetch });

    expect(result).toEqual({
      url: 'http://anchor.local',
      prospective: false,
      degraded: true,
      reason: 'pigeon-error',
      routingSid: 'sid_123',
    });
  });

  test('200 with a non-http (e.g. javascript:) apiBase -> degrade to anchor, reason "pigeon-error"', async () => {
    const fakeFetch = vi.fn().mockResolvedValue({
      ok: true,
      status: 200,
      json: async () => ({ apiBase: 'javascript:alert(1)' }),
    });

    const result = await resolveOwner('sid_123', dummyConfig, { fetch: fakeFetch });

    expect(result.degraded).toBe(true);
    expect(result.reason).toBe('pigeon-error');
    expect(result.url).toBe('http://anchor.local');
    expect(result.routingSid).toBe('sid_123');
  });

  test('trailing slash on pigeonUrl does not produce a double slash in the request URL', async () => {
    const fakeFetch = vi.fn().mockResolvedValue({
      ok: true,
      status: 200,
      json: async () => ({ apiBase: 'http://active-serve.local' }),
    });

    const config: Config = { ...dummyConfig, pigeonUrl: 'http://pigeon.local/' };
    await resolveOwner('sid_123', config, { fetch: fakeFetch });

    const [requestUrl] = fakeFetch.mock.calls[0] as [string, RequestInit];
    expect(requestUrl).toBe('http://pigeon.local/route?session_id=sid_123');
  });

  test('404 + sid is a confirmed ROOT (anchor 200, no parentID) -> anchor/degraded/not-routed, routingSid: sid, rootExists: true', async () => {
    const fakeFetch = vi.fn().mockImplementation(async (url: string) => {
      if (url.includes('/route?session_id=root_sid')) {
        return { ok: true, status: 404, json: async () => ({ error: 'not routed' }) };
      }
      if (url.includes('/session/root_sid')) {
        return { ok: true, status: 200, json: async () => ({ parentID: null }) };
      }
      return { ok: false, status: 500 };
    });

    const result = await resolveOwner('root_sid', dummyConfig, { fetch: fakeFetch });

    expect(result).toEqual({
      url: 'http://anchor.local',
      prospective: false,
      degraded: true,
      reason: 'not-routed',
      routingSid: 'root_sid',
      rootExists: true,
    });
    expect(fakeFetch).toHaveBeenCalledTimes(2);
  });

  test('404 + sid is a CHILD whose root is ROUTED -> url = root apiBase, degraded: false, reason: active, routingSid: root, viaParent: true, rootExists: true', async () => {
    const fakeFetch = vi.fn().mockImplementation(async (url: string) => {
      if (url.includes('/route?session_id=child_sid')) {
        return { ok: true, status: 404, json: async () => ({ error: 'not routed' }) };
      }
      if (url.includes('/session/child_sid')) {
        return { ok: true, status: 200, json: async () => ({ parentID: 'root_sid' }) };
      }
      if (url.includes('/session/root_sid')) {
        return { ok: true, status: 200, json: async () => ({ parentID: null }) };
      }
      if (url.includes('/route?session_id=root_sid')) {
        return { ok: true, status: 200, json: async () => ({ apiBase: 'http://root-serve.local' }) };
      }
      return { ok: false, status: 500 };
    });

    const result = await resolveOwner('child_sid', dummyConfig, { fetch: fakeFetch });

    expect(result).toEqual({
      url: 'http://root-serve.local',
      prospective: false,
      degraded: false,
      reason: 'active',
      routingSid: 'root_sid',
      viaParent: true,
      rootExists: true,
    });
  });

  test('M1: a SECOND resolve served from the parentage cache reports rootExists: FALSE', async () => {
    // rootExists means "confirmed to exist by a live 200 in THIS resolution", and
    // maybePromote skips checkSidExists when it is true. Parentage caches forever,
    // but existence does not -- a root can be deleted. So a cache-served walk must
    // NOT claim existence, or the door can place an already-deleted root. Without
    // this assertion, hardcoding `rootExists: true` in resolve.ts passes the suite.
    const responder = async (url: string) => {
      if (url.includes('/route?session_id=child_sid')) {
        return { ok: true, status: 404, json: async () => ({ error: 'not routed' }) };
      }
      if (url.includes('/session/child_sid')) {
        return { ok: true, status: 200, json: async () => ({ parentID: 'root_sid' }) };
      }
      if (url.includes('/session/root_sid')) {
        return { ok: true, status: 200, json: async () => ({ parentID: null }) };
      }
      if (url.includes('/route?session_id=root_sid')) {
        return { ok: true, status: 200, json: async () => ({ apiBase: 'http://root-serve.local' }) };
      }
      return { ok: false, status: 500 };
    };

    const first = await resolveOwner('child_sid', dummyConfig, { fetch: vi.fn().mockImplementation(responder) });
    expect(first.rootExists).toBe(true);   // walked live

    const second = await resolveOwner('child_sid', dummyConfig, { fetch: vi.fn().mockImplementation(responder) });
    expect(second.rootExists).toBe(false); // parentage from cache -> NOT an existence proof
    expect(second.routingSid).toBe('root_sid');
    expect(second.url).toBe('http://root-serve.local');
  });

  test('404 + child whose root is ALSO 404 -> anchor, degraded, reason: not-routed, routingSid: root, viaParent: true, rootExists: true', async () => {
    const fakeFetch = vi.fn().mockImplementation(async (url: string) => {
      if (url.includes('/route?session_id=child_sid')) {
        return { ok: true, status: 404, json: async () => ({ error: 'not routed' }) };
      }
      if (url.includes('/session/child_sid')) {
        return { ok: true, status: 200, json: async () => ({ parentID: 'root_sid' }) };
      }
      if (url.includes('/session/root_sid')) {
        return { ok: true, status: 200, json: async () => ({ parentID: null }) };
      }
      if (url.includes('/route?session_id=root_sid')) {
        return { ok: true, status: 404, json: async () => ({ error: 'not routed' }) };
      }
      return { ok: false, status: 500 };
    });

    const result = await resolveOwner('child_sid', dummyConfig, { fetch: fakeFetch });

    expect(result).toEqual({
      url: 'http://anchor.local',
      prospective: false,
      degraded: true,
      reason: 'not-routed',
      routingSid: 'root_sid',
      viaParent: true,
      rootExists: true,
    });
  });

  test('404 + child whose root lookup hits a pigeon ERROR -> reason: pigeon-error (NOT flattened), degraded true', async () => {
    const fakeFetch = vi.fn().mockImplementation(async (url: string) => {
      if (url.includes('/route?session_id=child_sid')) {
        return { ok: true, status: 404, json: async () => ({ error: 'not routed' }) };
      }
      if (url.includes('/session/child_sid')) {
        return { ok: true, status: 200, json: async () => ({ parentID: 'root_sid' }) };
      }
      if (url.includes('/session/root_sid')) {
        return { ok: true, status: 200, json: async () => ({ parentID: null }) };
      }
      if (url.includes('/route?session_id=root_sid')) {
        return { ok: true, status: 503, json: async () => ({ error: 'pigeon error' }) };
      }
      return { ok: false, status: 500 };
    });

    const result = await resolveOwner('child_sid', dummyConfig, { fetch: fakeFetch });

    expect(result).toEqual({
      url: 'http://anchor.local',
      prospective: false,
      degraded: true,
      reason: 'pigeon-error',
      routingSid: 'root_sid',
      viaParent: true,
      rootExists: true,
    });
  });

  test('404 + child whose root lookup hits pigeon UNREACHABLE -> reason: pigeon-unreachable, degraded true', async () => {
    const fakeFetch = vi.fn().mockImplementation(async (url: string) => {
      if (url.includes('/route?session_id=child_sid')) {
        return { ok: true, status: 404, json: async () => ({ error: 'not routed' }) };
      }
      if (url.includes('/session/child_sid')) {
        return { ok: true, status: 200, json: async () => ({ parentID: 'root_sid' }) };
      }
      if (url.includes('/session/root_sid')) {
        return { ok: true, status: 200, json: async () => ({ parentID: null }) };
      }
      if (url.includes('/route?session_id=root_sid')) {
        throw new Error('Network error');
      }
      return { ok: false, status: 500 };
    });

    const result = await resolveOwner('child_sid', dummyConfig, { fetch: fakeFetch });

    expect(result).toEqual({
      url: 'http://anchor.local',
      prospective: false,
      degraded: true,
      reason: 'pigeon-unreachable',
      routingSid: 'root_sid',
      viaParent: true,
      rootExists: true,
    });
  });

  test('404 + anchor walk fails -> routingSid: null, reason: not-routed, degraded true', async () => {
    const fakeFetch = vi.fn().mockImplementation(async (url: string) => {
      if (url.includes('/route?session_id=unknown_sid')) {
        return { ok: true, status: 404, json: async () => ({ error: 'not routed' }) };
      }
      if (url.includes('/session/unknown_sid')) {
        return { ok: true, status: 404, json: async () => ({ error: 'session not found on anchor' }) };
      }
      return { ok: false, status: 500 };
    });

    const result = await resolveOwner('unknown_sid', dummyConfig, { fetch: fakeFetch });

    expect(result).toEqual({
      url: 'http://anchor.local',
      prospective: false,
      degraded: true,
      reason: 'not-routed',
      routingSid: null,
    });
  });

  test('404 + child, root routed as PROSPECTIVE -> prospective: true propagates', async () => {
    const fakeFetch = vi.fn().mockImplementation(async (url: string) => {
      if (url.includes('/route?session_id=child_sid')) {
        return { ok: true, status: 404, json: async () => ({ error: 'not routed' }) };
      }
      if (url.includes('/session/child_sid')) {
        return { ok: true, status: 200, json: async () => ({ parentID: 'root_sid' }) };
      }
      if (url.includes('/session/root_sid')) {
        return { ok: true, status: 200, json: async () => ({ parentID: null }) };
      }
      if (url.includes('/route?session_id=root_sid')) {
        return { ok: true, status: 200, json: async () => ({ apiBase: 'http://prospective-serve.local', prospective: true }) };
      }
      return { ok: false, status: 500 };
    });

    const result = await resolveOwner('child_sid', dummyConfig, { fetch: fakeFetch });

    expect(result).toEqual({
      url: 'http://prospective-serve.local',
      prospective: true,
      degraded: false,
      reason: 'prospective',
      routingSid: 'root_sid',
      viaParent: true,
      rootExists: true,
    });
  });

  test('multi-level: grandchild -> child -> root routed; resolves to root owner with routingSid: root', async () => {
    const fakeFetch = vi.fn().mockImplementation(async (url: string) => {
      if (url.includes('/route?session_id=grandchild_sid')) {
        return { ok: true, status: 404, json: async () => ({ error: 'not routed' }) };
      }
      if (url.includes('/session/grandchild_sid')) {
        return { ok: true, status: 200, json: async () => ({ parentID: 'child_sid' }) };
      }
      if (url.includes('/session/child_sid')) {
        return { ok: true, status: 200, json: async () => ({ parentID: 'root_sid' }) };
      }
      if (url.includes('/session/root_sid')) {
        return { ok: true, status: 200, json: async () => ({ parentID: null }) };
      }
      if (url.includes('/route?session_id=root_sid')) {
        return { ok: true, status: 200, json: async () => ({ apiBase: 'http://root-serve.local' }) };
      }
      return { ok: false, status: 500 };
    });

    const result = await resolveOwner('grandchild_sid', dummyConfig, { fetch: fakeFetch });

    expect(result).toEqual({
      url: 'http://root-serve.local',
      prospective: false,
      degraded: false,
      reason: 'active',
      routingSid: 'root_sid',
      viaParent: true,
      rootExists: true,
    });
  });

  test('assert call ORDER and counts on fake fetch for child case', async () => {
    const calls: string[] = [];
    const fakeFetch = vi.fn().mockImplementation(async (url: string) => {
      calls.push(url);
      if (url.includes('/route?session_id=child')) {
        return { ok: true, status: 404, json: async () => ({ error: 'not routed' }) };
      }
      if (url.includes('/session/child')) {
        return { ok: true, status: 200, json: async () => ({ parentID: 'parent' }) };
      }
      if (url.includes('/session/parent')) {
        return { ok: true, status: 200, json: async () => ({ parentID: null }) };
      }
      if (url.includes('/route?session_id=parent')) {
        return { ok: true, status: 200, json: async () => ({ apiBase: 'http://parent-serve.local' }) };
      }
      return { ok: false, status: 500 };
    });

    const result = await resolveOwner('child', dummyConfig, { fetch: fakeFetch });

    expect(result).toEqual({
      url: 'http://parent-serve.local',
      prospective: false,
      degraded: false,
      reason: 'active',
      routingSid: 'parent',
      viaParent: true,
      rootExists: true,
    });

    expect(calls).toEqual([
      'http://pigeon.local/route?session_id=child',
      'http://anchor.local/session/child',
      'http://anchor.local/session/parent',
      'http://pigeon.local/route?session_id=parent',
    ]);
    expect(fakeFetch).toHaveBeenCalledTimes(4);
  });
});
