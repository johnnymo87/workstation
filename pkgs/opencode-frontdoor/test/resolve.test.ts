import { describe, test, expect, vi } from 'vitest';
import { resolveOwner } from '../src/resolve.js';
import type { Config } from '../src/config.js';

describe('resolveOwner', () => {
  const dummyConfig: Config = {
    port: 4700,
    pigeonUrl: 'http://pigeon.local',
    anchorUrl: 'http://anchor.local',
    pigeonAuthToken: undefined,
    routeTimeoutMs: 3000,
    cheapFirstByteMs: 5000,
    stickyTtlMs: 30000,
  };

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
    const headers = requestInit?.headers as Record<string, string>;
    expect(headers).toBeDefined();
    expect(headers['Authorization']).toBe('Bearer my-secret-token');
  });

  test('404 from pigeon -> anchor + reason "not-routed", degraded true', async () => {
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
    });
  });

  test('500/503 from pigeon -> anchor + reason "pigeon-error", degraded true', async () => {
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
    });
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
    });
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
});
