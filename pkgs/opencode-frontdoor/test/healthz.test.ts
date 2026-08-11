import { describe, test, expect, vi } from 'vitest';
import { isHealthzRequest, handleHealthz } from '../src/healthz.js';
import type { Config } from '../src/config.js';
import { createMetrics, type Metrics } from '../src/metrics.js';

describe('healthz', () => {
  describe('isHealthzRequest', () => {
    test('matches GET /healthz and /healthz/', () => {
      expect(isHealthzRequest('GET', '/healthz')).toBe(true);
      expect(isHealthzRequest('GET', '/healthz/')).toBe(true);
    });

    test('matches HEAD /healthz and /healthz/', () => {
      expect(isHealthzRequest('HEAD', '/healthz')).toBe(true);
      expect(isHealthzRequest('HEAD', '/healthz/')).toBe(true);
    });

    test('rejects other methods', () => {
      expect(isHealthzRequest('POST', '/healthz')).toBe(false);
      expect(isHealthzRequest('PUT', '/healthz')).toBe(false);
      expect(isHealthzRequest('DELETE', '/healthz')).toBe(false);
    });

    test('rejects other paths', () => {
      expect(isHealthzRequest('GET', '/')).toBe(false);
      expect(isHealthzRequest('GET', '/health')).toBe(false);
      expect(isHealthzRequest('GET', '/healthz/extra')).toBe(false);
    });
  });

  describe('handleHealthz', () => {
    const dummyConfig: Config = {
      port: 4700,
      version: 'v1.2.3-test',
      pigeonUrl: 'http://pigeon.local',
      anchorUrl: 'http://anchor.local/',
      poolUrls: ['http://anchor.local/'],
      pigeonAuthToken: 'token123',
      routeTimeoutMs: 1500,
      cheapFirstByteMs: 5000,
      stickyTtlMs: 30000,
      driftCheckMs: 5000,
      wedgeProbeIntervalMs: 5000,
      mintTimeoutMs: 60000,
      logSampleN: 1,
      logSummaryIntervalMs: 300000,
    };

    const createMockResponse = (method: string = 'GET') => {
      const res: any = {
        writeHead: vi.fn(),
        end: vi.fn(),
        req: { method },
      };
      return res;
    };

    test('both reachable -> 200, degraded: false, pigeon: true, anchor: true', async () => {
      const res = createMockResponse();
      const metrics: Metrics = { degradedRequests: 5, notRoutedMutationToAnchor: 0, promotedOnConnect: 0, htmlPoisonBlocked: 0, poolFailover: 0 };

      const fetchImpl = vi.fn().mockImplementation(async (url: string) => {
        if (url.startsWith('http://pigeon.local/route')) {
          return {
            ok: true,
            status: 200,
            body: { cancel: async () => {} },
          };
        }
        if (url.startsWith('http://anchor.local/global/health')) {
          return {
            ok: true,
            status: 200,
            body: { cancel: async () => {} },
          };
        }
        throw new Error('Unexpected fetch call');
      });

      await handleHealthz(res, { config: dummyConfig, method: res.req.method, deps: { fetch: fetchImpl }, metrics });

      expect(res.writeHead).toHaveBeenCalledWith(200, { 'Content-Type': 'application/json' });
      expect(res.end).toHaveBeenCalledTimes(1);
      const body = JSON.parse(res.end.mock.calls[0][0]);
      expect(body).toEqual({
        status: 'ok',
        degraded: false,
        pigeon: true,
        anchor: true,
        degradedRequests: 5,
        notRoutedMutationToAnchor: 0, promotedOnConnect: 0,
        htmlPoisonBlocked: 0,
        poolFailover: 0,
        version: 'v1.2.3-test',
      });
    });

    test('pigeon unreachable, anchor 200 -> 200, degraded: true, pigeon: false, anchor: true', async () => {
      const res = createMockResponse();
      const metrics: Metrics = { degradedRequests: 10, notRoutedMutationToAnchor: 0, promotedOnConnect: 0, htmlPoisonBlocked: 0, poolFailover: 0 };

      const fetchImpl = vi.fn().mockImplementation(async (url: string) => {
        if (url.startsWith('http://pigeon.local/route')) {
          throw new Error('Connection refused');
        }
        if (url.startsWith('http://anchor.local/global/health')) {
          return {
            ok: true,
            status: 200,
            body: { cancel: async () => {} },
          };
        }
        throw new Error('Unexpected fetch call');
      });

      await handleHealthz(res, { config: dummyConfig, method: res.req.method, deps: { fetch: fetchImpl }, metrics });

      expect(res.writeHead).toHaveBeenCalledWith(200, { 'Content-Type': 'application/json' });
      expect(res.end).toHaveBeenCalledTimes(1);
      const body = JSON.parse(res.end.mock.calls[0][0]);
      expect(body).toEqual({
        status: 'ok',
        degraded: true,
        pigeon: false,
        anchor: true,
        degradedRequests: 10,
        notRoutedMutationToAnchor: 0, promotedOnConnect: 0,
        htmlPoisonBlocked: 0,
        poolFailover: 0,
        version: 'v1.2.3-test',
      });
    });

    test('pigeon 404 (reachable), anchor times out -> 200, degraded: true, pigeon: true, anchor: false', async () => {
      const res = createMockResponse();
      const metrics: Metrics = { degradedRequests: 0, notRoutedMutationToAnchor: 0, promotedOnConnect: 0, htmlPoisonBlocked: 0, poolFailover: 0 };

      const fetchImpl = vi.fn().mockImplementation(async (url: string) => {
        if (url.startsWith('http://pigeon.local/route')) {
          return {
            ok: true,
            status: 404,
            body: { cancel: async () => {} },
          };
        }
        if (url.startsWith('http://anchor.local/global/health')) {
          // Timeout is simulated by throwing AbortError or standard timeout
          const err = new Error('The operation was aborted.');
          err.name = 'AbortError';
          throw err;
        }
        throw new Error('Unexpected fetch call');
      });

      await handleHealthz(res, { config: dummyConfig, method: res.req.method, deps: { fetch: fetchImpl }, metrics });

      expect(res.writeHead).toHaveBeenCalledWith(200, { 'Content-Type': 'application/json' });
      const body = JSON.parse(res.end.mock.calls[0][0]);
      expect(body).toEqual({
        status: 'ok',
        degraded: true,
        pigeon: true,
        anchor: false,
        degradedRequests: 0,
        notRoutedMutationToAnchor: 0, promotedOnConnect: 0,
        htmlPoisonBlocked: 0,
        poolFailover: 0,
        version: 'v1.2.3-test',
      });
    });

    test('both unreachable -> 503, degraded: false, pigeon: false, anchor: false', async () => {
      const res = createMockResponse();
      const metrics: Metrics = { degradedRequests: 2, notRoutedMutationToAnchor: 0, promotedOnConnect: 0, htmlPoisonBlocked: 0, poolFailover: 0 };

      const fetchImpl = vi.fn().mockImplementation(async (url: string) => {
        throw new Error('Network offline');
      });

      await handleHealthz(res, { config: dummyConfig, method: res.req.method, deps: { fetch: fetchImpl }, metrics });

      expect(res.writeHead).toHaveBeenCalledWith(503, { 'Content-Type': 'application/json' });
      const body = JSON.parse(res.end.mock.calls[0][0]);
      expect(body).toEqual({
        status: 'unavailable',
        degraded: false,
        pigeon: false,
        anchor: false,
        degradedRequests: 2,
        notRoutedMutationToAnchor: 0, promotedOnConnect: 0,
        htmlPoisonBlocked: 0,
        poolFailover: 0,
        version: 'v1.2.3-test',
      });
    });

    test('HEAD request with both reachable -> 200, no body written', async () => {
      const res = createMockResponse('HEAD');
      const metrics: Metrics = { degradedRequests: 0, notRoutedMutationToAnchor: 0, promotedOnConnect: 0, htmlPoisonBlocked: 0, poolFailover: 0 };

      const fetchImpl = vi.fn().mockImplementation(async (url: string) => {
        return {
          ok: true,
          status: 200,
          body: { cancel: async () => {} },
        };
      });

      await handleHealthz(res, { config: dummyConfig, method: res.req.method, deps: { fetch: fetchImpl }, metrics });

      expect(res.writeHead).toHaveBeenCalledWith(200, { 'Content-Type': 'application/json' });
      expect(res.end).toHaveBeenCalledTimes(1);
      expect(res.end.mock.calls[0][0]).toBeUndefined(); // no body written
    });

  describe('metrics exposure (no write-only counters)', () => {
    // STRUCTURAL GUARD. htmlPoisonBlocked shipped in the m3z2 deploy incremented in two
    // places in proxy.ts and exposed NOWHERE -- /healthz is the only reader of metrics
    // that exists, so the counter was unobservable and the post-deploy check
    // "htmlPoisonBlocked present and 0" was vacuous by construction. This test fails if
    // any FUTURE counter is added to Metrics without being surfaced, so the next one
    // cannot repeat it. Enumerating createMetrics() is what makes that automatic;
    // asserting field-by-field would not.
    const okFetch = () =>
      vi.fn().mockImplementation(async () => ({ ok: true, status: 200, body: { cancel: async () => {} } }));

    test('every key in Metrics appears in the /healthz body', async () => {
      const res = createMockResponse();
      const metrics = createMetrics();
      await handleHealthz(res, { config: dummyConfig, method: 'GET', deps: { fetch: okFetch() }, metrics });
      const body = JSON.parse(res.end.mock.calls[0][0]);
      for (const key of Object.keys(metrics)) {
        expect(body, `Metrics key "${key}" is not exposed in /healthz (write-only counter)`).toHaveProperty(key);
      }
    });

    test('a non-zero htmlPoisonBlocked actually surfaces (not hardcoded)', async () => {
      const res = createMockResponse();
      const metrics: Metrics = { degradedRequests: 0, notRoutedMutationToAnchor: 0, promotedOnConnect: 0, htmlPoisonBlocked: 7, poolFailover: 0 };
      await handleHealthz(res, { config: dummyConfig, method: 'GET', deps: { fetch: okFetch() }, metrics });
      const body = JSON.parse(res.end.mock.calls[0][0]);
      expect(body.htmlPoisonBlocked).toBe(7);
    });

    test('a non-zero poolFailover actually surfaces (not hardcoded)', async () => {
      const res = createMockResponse();
      const metrics: Metrics = { degradedRequests: 0, notRoutedMutationToAnchor: 0, promotedOnConnect: 0, htmlPoisonBlocked: 0, poolFailover: 3 };
      await handleHealthz(res, { config: dummyConfig, method: 'GET', deps: { fetch: okFetch() }, metrics });
      const body = JSON.parse(res.end.mock.calls[0][0]);
      expect(body.poolFailover).toBe(3);
    });
  });
  });
});
