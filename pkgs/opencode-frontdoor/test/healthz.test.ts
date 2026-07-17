import { describe, test, expect, vi } from 'vitest';
import { isHealthzRequest, handleHealthz } from '../src/healthz.js';
import type { Config } from '../src/config.js';
import type { Metrics } from '../src/metrics.js';

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
      pigeonAuthToken: 'token123',
      routeTimeoutMs: 1500,
      cheapFirstByteMs: 5000,
      stickyTtlMs: 30000,
      driftCheckMs: 5000,
      wedgeProbeIntervalMs: 5000,
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
      const metrics: Metrics = { degradedRequests: 5 };

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
        version: 'v1.2.3-test',
      });
    });

    test('pigeon unreachable, anchor 200 -> 200, degraded: true, pigeon: false, anchor: true', async () => {
      const res = createMockResponse();
      const metrics: Metrics = { degradedRequests: 10 };

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
        version: 'v1.2.3-test',
      });
    });

    test('pigeon 404 (reachable), anchor times out -> 200, degraded: true, pigeon: true, anchor: false', async () => {
      const res = createMockResponse();
      const metrics: Metrics = { degradedRequests: 0 };

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
        version: 'v1.2.3-test',
      });
    });

    test('both unreachable -> 503, degraded: false, pigeon: false, anchor: false', async () => {
      const res = createMockResponse();
      const metrics: Metrics = { degradedRequests: 2 };

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
        version: 'v1.2.3-test',
      });
    });

    test('HEAD request with both reachable -> 200, no body written', async () => {
      const res = createMockResponse('HEAD');
      const metrics: Metrics = { degradedRequests: 0 };

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
  });
});
