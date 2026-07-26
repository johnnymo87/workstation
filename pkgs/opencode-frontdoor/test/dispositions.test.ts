import { describe, test, expect } from 'vitest';
import {
  getRouteDisposition,
  ROUTE_DISPOSITIONS,
  CLASS_DISPOSITIONS,
  type RouteDisposition,
} from '../src/routes.dispositions.js';

/**
 * Resolver coverage for `getRouteDisposition`.
 *
 * It has two callers with different input shapes, and they must agree:
 *   - the gate passes TEMPLATE paths straight out of `/doc` (`/auth/{providerID}`)
 *   - `proxy.ts` passes CONCRETE request paths (`/auth/anthropic`)
 * Before 2026-07-26 only the first worked, so the denial body silently fell back
 * to generic text for every templated route.
 */
describe('getRouteDisposition resolution', () => {
  test('template path (gate caller) resolves by exact key', () => {
    const d = getRouteDisposition('PUT', '/auth/{providerID}', 'global-sideeffect');
    expect(d?.kind).toBeTruthy();
    expect(d?.userMessage).toMatch(/pool-wide state/);
  });

  test('concrete path (proxy caller) resolves to the same row', () => {
    const viaTemplate = getRouteDisposition('PUT', '/auth/{providerID}', 'global-sideeffect');
    const viaConcrete = getRouteDisposition('PUT', '/auth/anthropic', 'global-sideeffect');
    expect(viaConcrete).toBe(viaTemplate);
  });

  test('a template segment does not match across a slash', () => {
    // `{providerID}` compiles to [^/]+, so a deeper path must NOT resolve here.
    expect(getRouteDisposition('PUT', '/auth/a/b', 'global-sideeffect')).toBeUndefined();
  });

  test('method is respected when matching templates', () => {
    // PATCH is not a dispositioned method on this path.
    expect(getRouteDisposition('PATCH', '/auth/anthropic', 'global-sideeffect')).toBeUndefined();
  });

  test('/api/-prefixed doc route falls back to its bare-form disposition key', () => {
    // `/doc` carries this route ONLY in /api/ form (routes.classification.ts:78),
    // while its disposition is keyed bare — the house convention R1 describes.
    // This also exercises the fallback against a TEMPLATE key, not just an exact one.
    const d = getRouteDisposition('DELETE', '/api/integration/attempt/att_123', 'global-sideeffect');
    expect(d).toBe(ROUTE_DISPOSITIONS['DELETE /integration/attempt/{attemptID}']);
  });

  test('class-level disposition wins over any route key', () => {
    const d = getRouteDisposition('POST', '/auth/anthropic', 'tui');
    expect(d).toBe(CLASS_DISPOSITIONS['tui']);
  });

  test('query strings and trailing slashes are normalized away', () => {
    const base = getRouteDisposition('PUT', '/auth/anthropic', 'global-sideeffect');
    expect(getRouteDisposition('PUT', '/auth/anthropic/', 'global-sideeffect')).toBe(base);
    expect(getRouteDisposition('PUT', '/auth/anthropic?x=1', 'global-sideeffect')).toBe(base);
  });

  test('unknown routes resolve to undefined rather than a wrong row', () => {
    expect(getRouteDisposition('POST', '/definitely/not/a/route', 'global-sideeffect')).toBeUndefined();
  });

  test('custom disposition maps are honoured and cached independently', () => {
    const custom: Record<string, RouteDisposition> = {
      'POST /thing/{id}': { kind: 'accepted-gap', constraint: 'needs-audit', rationale: 'test row' },
    };
    const first = getRouteDisposition('POST', '/thing/42', 'global-sideeffect', custom, {});
    const second = getRouteDisposition('POST', '/thing/43', 'global-sideeffect', custom, {});
    expect(first?.rationale).toBe('test row');
    expect(second).toBe(first);
    // The custom map must not leak into the default map's cache.
    expect(getRouteDisposition('POST', '/thing/42', 'global-sideeffect')).toBeUndefined();
  });
});

/**
 * The wire-facing fields are a safety property, not a cosmetic one: the four
 * credential-writing routes must never ship the generic "call a serve port
 * directly" hint, because following it produces a 200 plus three stale serves.
 */
describe('credential-writing rows carry a pool-correct remedy', () => {
  const credentialWriters = [
    'PUT /auth/{providerID}',
    'DELETE /auth/{providerID}',
    'POST /provider/{providerID}/oauth/authorize',
    'POST /provider/{providerID}/oauth/callback',
  ];

  test.each(credentialWriters)('%s has userMessage and remedy', (key) => {
    const d = ROUTE_DISPOSITIONS[key];
    expect(d).toBeDefined();
    expect(d.userMessage).toBeTruthy();
    expect(d.remedy).toBeTruthy();
    expect(d.userMessage).not.toMatch(/call a serve port directly/i);
  });

  test('every remedy in the table warns about the disruption it causes', () => {
    // A remedy that says "run /global/dispose" without saying what that costs is
    // how an operator learns about cancelled runs the hard way.
    for (const [key, d] of Object.entries(ROUTE_DISPOSITIONS)) {
      if (d.remedy?.includes('/global/dispose')) {
        expect(d.remedy, `${key} remedy must state the cost of /global/dispose`).toMatch(
          /cancels every in-flight run/
        );
      }
    }
  });

  test('no rationale leaks file:line citations onto the wire', () => {
    // `rationale` is repo-facing and full of citations; `userMessage` is not.
    for (const [key, d] of Object.entries(ROUTE_DISPOSITIONS)) {
      if (d.userMessage) {
        expect(d.userMessage, `${key} userMessage must not cite source locations`).not.toMatch(
          /\.(ts|tsx|nix|md):\d+/
        );
      }
    }
  });
});
