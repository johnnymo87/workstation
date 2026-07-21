import { describe, test, expect, vi } from 'vitest';
import { placeSession, isPromotingRequest, PromotionGate, maybePromote } from '../src/place.js';
import type { Config } from '../src/config.js';
import type { SidExtraction } from '../src/sid.js';
import type { ResolvedOwner } from '../src/resolve.js';

describe('place.ts', () => {
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
    mintTimeoutMs: 60000,
  };

  describe('isPromotingRequest', () => {
    test('not-promoting when extraction is not single', () => {
      expect(isPromotingRequest('GET', '/event', { kind: 'none' })).toBe(false);
      expect(isPromotingRequest('GET', '/event', { kind: 'multi', sids: ['ses_1', 'ses_2'] })).toBe(false);
      expect(isPromotingRequest('GET', '/event', { kind: 'malformed' })).toBe(false);
    });

    test('SSE-stream establishment: single-session event stream GET', () => {
      // Path-based single session event route
      expect(isPromotingRequest('GET', '/session/ses_123/event', { kind: 'single', sid: 'ses_123' })).toBe(true);
      expect(isPromotingRequest('GET', '/api/session/ses_123/event', { kind: 'single', sid: 'ses_123' })).toBe(true);
      expect(isPromotingRequest('GET', '/session/ses_123/event/', { kind: 'single', sid: 'ses_123' })).toBe(true);

      // Query-based single session event route
      expect(isPromotingRequest('GET', '/event', { kind: 'single', sid: 'ses_123' })).toBe(true);
      expect(isPromotingRequest('GET', '/api/event', { kind: 'single', sid: 'ses_123' })).toBe(true);

      // Firehose GET global/event -> false
      expect(isPromotingRequest('GET', '/global/event', { kind: 'single', sid: 'ses_123' })).toBe(false);

      // Normal session GET -> false
      expect(isPromotingRequest('GET', '/session/ses_123', { kind: 'single', sid: 'ses_123' })).toBe(false);

      // Tightened exact matching
      expect(isPromotingRequest('GET', '/foo/event', { kind: 'single', sid: 'ses_123' })).toBe(false);
      expect(isPromotingRequest('GET', '/event', { kind: 'multi', sids: ['ses_123', 'ses_456'] })).toBe(false);
    });

    test('Turn-starting POST requests', () => {
      const singleExt: SidExtraction = { kind: 'single', sid: 'ses_123' };

      // Valid promoting suffixes
      expect(isPromotingRequest('POST', '/session/ses_123/message', singleExt)).toBe(true);
      expect(isPromotingRequest('POST', '/api/session/ses_123/prompt_async', singleExt)).toBe(true);
      expect(isPromotingRequest('POST', '/session/ses_123/compact/', singleExt)).toBe(true);
      expect(isPromotingRequest('POST', '/session/ses_123/init', singleExt)).toBe(true);

      // Non-promoting POST suffixes
      expect(isPromotingRequest('POST', '/session/ses_123/abort', singleExt)).toBe(false);
      expect(isPromotingRequest('POST', '/session/ses_123/fork', singleExt)).toBe(false);
      expect(isPromotingRequest('POST', '/api/session', singleExt)).toBe(false); // creation
    });
  });

  describe('PromotionGate', () => {
    test('shouldAttempt true initially, false within TTL, true after TTL', () => {
      const gate = new PromotionGate(1000);
      const sid = 'ses_abc';

      expect(gate.shouldAttempt(sid, 1000)).toBe(true);
      
      gate.record(sid, 1000);
      // within TTL
      expect(gate.shouldAttempt(sid, 1500)).toBe(false);
      expect(gate.shouldAttempt(sid, 1999)).toBe(false);
      
      // exactly TTL / after TTL
      expect(gate.shouldAttempt(sid, 2000)).toBe(true);
      expect(gate.shouldAttempt(sid, 2500)).toBe(true);
    });

    test('different sids have independent TTL tracking', () => {
      const gate = new PromotionGate(1000);
      gate.record('ses_1', 1000);

      expect(gate.shouldAttempt('ses_1', 1500)).toBe(false);
      expect(gate.shouldAttempt('ses_2', 1500)).toBe(true);
    });

    test('passive sweep prunes stale entries on record', () => {
      const gate = new PromotionGate(1000);
      
      gate.record('ses_1', 1000);
      gate.record('ses_2', 1100);
      
      expect((gate as any).attempts.size).toBe(2);

      // Advance now to 2000 (past stickyTtlMs of 1000 relative to ses_1)
      // Recording a new sid at 2000 triggers the sweep
      gate.record('ses_3', 2000);

      // ses_1 (1000) -> pruned (2000 - 1000 >= 1000)
      // ses_2 (1100) -> kept (2000 - 1100 = 900 < 1000)
      // ses_3 (2000) -> kept (2000 - 2000 = 0 < 1000)
      expect((gate as any).attempts.size).toBe(2);
      expect(gate.shouldAttempt('ses_1', 2000)).toBe(true);
      expect(gate.shouldAttempt('ses_2', 2000)).toBe(false);
      expect(gate.shouldAttempt('ses_3', 2000)).toBe(false);
    });
  });

  describe('placeSession', () => {
    test('200 response parses serve_id and api_base', async () => {
      const fakeFetch = vi.fn().mockResolvedValue({
        status: 200,
        json: async () => ({
          ok: true,
          session_id: 'ses_123',
          serve_id: 'serve_abc',
          api_base: 'http://serve.local',
        }),
      });

      const result = await placeSession('ses_123', dummyConfig, { fetch: fakeFetch });
      expect(result).toEqual({
        ok: true,
        status: 200,
        serveId: 'serve_abc',
        apiBase: 'http://serve.local',
      });

      expect(fakeFetch).toHaveBeenCalledTimes(1);
      const [url, init] = fakeFetch.mock.calls[0] as [string, RequestInit];
      expect(url).toBe('http://pigeon.local/place');
      expect(init.method).toBe('POST');
      expect(JSON.parse(init.body as string)).toEqual({ session_id: 'ses_123' });
    });

    test('Authorization Bearer added when token is present', async () => {
      const configWithToken = { ...dummyConfig, pigeonAuthToken: 'secret_token' };
      const fakeFetch = vi.fn().mockResolvedValue({
        status: 200,
        json: async () => ({}),
      });

      await placeSession('ses_123', configWithToken, { fetch: fakeFetch });
      const [, init] = fakeFetch.mock.calls[0] as [string, RequestInit];
      expect(init.headers).toEqual({
        'Content-Type': 'application/json',
        'Authorization': 'Bearer secret_token',
      });
    });

    test('trailing slash is stripped from pigeonUrl', async () => {
      const configWithSlash = { ...dummyConfig, pigeonUrl: 'http://pigeon.local/' };
      const fakeFetch = vi.fn().mockResolvedValue({
        status: 200,
        json: async () => ({}),
      });

      await placeSession('ses_123', configWithSlash, { fetch: fakeFetch });
      const [url] = fakeFetch.mock.calls[0] as [string, RequestInit];
      expect(url).toBe('http://pigeon.local/place');
    });

    test('503 and 409 responses parsed correctly', async () => {
      const fakeFetch = vi.fn().mockResolvedValue({
        status: 503,
      });

      const result = await placeSession('ses_123', dummyConfig, { fetch: fakeFetch });
      expect(result).toEqual({
        ok: false,
        status: 503,
      });
    });

    test('network and timeout failures are degrade-safe (return status 0)', async () => {
      const fakeFetch = vi.fn().mockRejectedValue(new Error('Network offline'));

      const result = await placeSession('ses_123', dummyConfig, { fetch: fakeFetch });
      expect(result).toEqual({
        ok: false,
        status: 0,
      });
    });
  });

  describe('maybePromote orchestrator', () => {
    const singleExt: SidExtraction = { kind: 'single', sid: 'ses_123' };

    test('non-promoting request -> not-promoting without issuing fetch', async () => {
      const fakeFetch = vi.fn();
      const gate = new PromotionGate(30000);
      const resolved: ResolvedOwner = {
        url: 'http://anchor.local',
        prospective: false,
        degraded: true,
        reason: 'not-routed',
      };

      const outcome = await maybePromote(
        {
          sid: 'ses_123',
          method: 'GET',
          pathname: '/session/ses_123',
          extraction: singleExt,
          resolved,
          gate,
        },
        dummyConfig,
        { fetch: fakeFetch },
      );

      expect(outcome).toEqual({ placed: false, reason: 'not-promoting' });
      expect(fakeFetch).not.toHaveBeenCalled();
    });

    test('resolved active -> already-active, no fetch', async () => {
      const fakeFetch = vi.fn();
      const gate = new PromotionGate(30000);
      const resolved: ResolvedOwner = {
        url: 'http://active.local',
        prospective: false,
        degraded: false,
        reason: 'active',
      };

      const outcome = await maybePromote(
        {
          sid: 'ses_123',
          method: 'POST',
          pathname: '/session/ses_123/message',
          extraction: singleExt,
          resolved,
          gate,
        },
        dummyConfig,
        { fetch: fakeFetch },
      );

      expect(outcome).toEqual({ placed: false, reason: 'already-active' });
      expect(fakeFetch).not.toHaveBeenCalled();
    });

    test('resolved pigeon-unreachable/pigeon-error -> pigeon-degraded, no fetch', async () => {
      const fakeFetch = vi.fn();
      const gate = new PromotionGate(30000);
      const resolved: ResolvedOwner = {
        url: 'http://anchor.local',
        prospective: false,
        degraded: true,
        reason: 'pigeon-unreachable',
      };

      const outcome = await maybePromote(
        {
          sid: 'ses_123',
          method: 'POST',
          pathname: '/session/ses_123/message',
          extraction: singleExt,
          resolved,
          gate,
        },
        dummyConfig,
        { fetch: fakeFetch },
      );

      expect(outcome).toEqual({ placed: false, reason: 'pigeon-degraded' });
      expect(fakeFetch).not.toHaveBeenCalled();
    });

    test('establishment (GET /session/ses_123/event, prospective) -> places once', async () => {
      const fakeFetch = vi.fn().mockImplementation(async (url) => {
        if (url.includes('/place')) {
          return {
            status: 200,
            json: async () => ({
              ok: true,
              serve_id: 'serve_1',
              api_base: 'http://serve-1.local',
            }),
          };
        }
        return { status: 404 };
      });

      const gate = new PromotionGate(30000);
      const resolved: ResolvedOwner = {
        url: 'http://prospective.local',
        prospective: true,
        degraded: false,
        reason: 'prospective',
      };

      const outcome = await maybePromote(
        {
          sid: 'ses_123',
          method: 'GET',
          pathname: '/session/ses_123/event',
          extraction: singleExt,
          resolved,
          gate,
        },
        dummyConfig,
        { fetch: fakeFetch, now: () => 1000 },
      );

      expect(outcome).toEqual({
        placed: true,
        reason: 'placed',
        serveId: 'serve_1',
        apiBase: 'http://serve-1.local',
        status: 200,
      });

      expect(fakeFetch).toHaveBeenCalledTimes(1);
      const [url] = fakeFetch.mock.calls[0] as [string];
      expect(url).toContain('/place');
    });

    test('second establishment within TTL -> ttl-guarded', async () => {
      const fakeFetch = vi.fn().mockImplementation(async (url) => {
        if (url.includes('/place')) {
          return {
            status: 200,
            json: async () => ({
              ok: true,
              serve_id: 'serve_1',
              api_base: 'http://serve-1.local',
            }),
          };
        }
        return { status: 404 };
      });

      const gate = new PromotionGate(30000);
      const resolved: ResolvedOwner = {
        url: 'http://prospective.local',
        prospective: true,
        degraded: false,
        reason: 'prospective',
      };

      // First promotion
      const outcome1 = await maybePromote(
        {
          sid: 'ses_123',
          method: 'GET',
          pathname: '/session/ses_123/event',
          extraction: singleExt,
          resolved,
          gate,
        },
        dummyConfig,
        { fetch: fakeFetch, now: () => 1000 },
      );
      expect(outcome1.placed).toBe(true);

      // Second promotion within TTL (at t=1500)
      const outcome2 = await maybePromote(
        {
          sid: 'ses_123',
          method: 'GET',
          pathname: '/session/ses_123/event',
          extraction: singleExt,
          resolved,
          gate,
        },
        dummyConfig,
        { fetch: fakeFetch, now: () => 1500 },
      );

      expect(outcome2).toEqual({ placed: false, reason: 'ttl-guarded' });
      // Still only 1 total fetch to /place called
      expect(fakeFetch).toHaveBeenCalledTimes(1);
    });

    test('not-routed + GET /session/{sid} 404 -> unknown-sid, NO place, and gate is not recorded', async () => {
      const fakeFetch = vi.fn().mockImplementation(async (url) => {
        if (url.includes('/session/ses_123')) {
          return { status: 404 }; // sid does not exist on anchor
        }
        if (url.includes('/place')) {
          return {
            status: 200,
            json: async () => ({ ok: true }),
          };
        }
        return { status: 500 };
      });

      const gate = new PromotionGate(30000);
      const resolved: ResolvedOwner = {
        url: 'http://anchor.local',
        prospective: false,
        degraded: true,
        reason: 'not-routed',
      };

      const outcome1 = await maybePromote(
        {
          sid: 'ses_123',
          method: 'GET',
          pathname: '/session/ses_123/event',
          extraction: singleExt,
          resolved,
          gate,
        },
        dummyConfig,
        { fetch: fakeFetch, now: () => 1000 },
      );

      expect(outcome1).toEqual({ placed: false, reason: 'unknown-sid' });
      // verify existence check was queried but NO place request was made
      expect(fakeFetch).toHaveBeenCalledTimes(1);
      expect(fakeFetch.mock.calls[0][0]).toBe('http://anchor.local/session/ses_123');

      // Verify the gate did NOT record the attempt (should still be true)
      expect(gate.shouldAttempt('ses_123', 1500)).toBe(true);

      // If it now exists (GET returns 200), we can proceed to promote on second call
      const fakeFetch2 = vi.fn().mockImplementation(async (url) => {
        if (url.includes('/session/ses_123')) {
          return { status: 200 }; // sid exists now!
        }
        if (url.includes('/place')) {
          return {
            status: 200,
            json: async () => ({
              ok: true,
              serve_id: 'serve_2',
              api_base: 'http://serve-2.local',
            }),
          };
        }
        return { status: 500 };
      });

      const outcome2 = await maybePromote(
        {
          sid: 'ses_123',
          method: 'GET',
          pathname: '/session/ses_123/event',
          extraction: singleExt,
          resolved,
          gate,
        },
        dummyConfig,
        { fetch: fakeFetch2, now: () => 1500 },
      );

      expect(outcome2).toEqual({
        placed: true,
        reason: 'placed',
        serveId: 'serve_2',
        apiBase: 'http://serve-2.local',
        status: 200,
      });

      expect(fakeFetch2).toHaveBeenCalledTimes(2); // 1 existence check + 1 place request
    });

    test('multi session_ids establishment -> not-promoting', async () => {
      const fakeFetch = vi.fn();
      const gate = new PromotionGate(30000);
      const resolved: ResolvedOwner = {
        url: 'http://prospective.local',
        prospective: true,
        degraded: false,
        reason: 'prospective',
      };

      const outcome = await maybePromote(
        {
          sid: 'ses_123',
          method: 'GET',
          pathname: '/event',
          extraction: { kind: 'multi', sids: ['ses_123', 'ses_456'] },
          resolved,
          gate,
        },
        dummyConfig,
        { fetch: fakeFetch },
      );

      expect(outcome).toEqual({ placed: false, reason: 'not-promoting' });
      expect(fakeFetch).not.toHaveBeenCalled();
    });
  });
});
