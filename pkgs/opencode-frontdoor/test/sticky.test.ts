import { describe, test, expect } from 'vitest';
import { StickyMap, isMutatingSessionRequest } from '../src/sticky.js';

describe('StickyMap', () => {
  test('record and get returns the serve', () => {
    const map = new StickyMap(1000);
    map.record('ses_1', 'serve_a', 100);
    expect(map.get('ses_1', 100)).toBe('serve_a');
    expect(map.get('ses_1', 500)).toBe('serve_a');
    expect(map.get('ses_1', 1099)).toBe('serve_a');
  });

  test('expired entry (now past/at expiry) returns undefined and removes it', () => {
    const map = new StickyMap(1000);
    map.record('ses_1', 'serve_a', 100);

    // exactly at expiry (100 + 1000 = 1100) -> should be expired
    expect(map.get('ses_1', 1100)).toBeUndefined();
    // should have been removed
    expect(map.has('ses_1', 1100)).toBe(false);
    expect(map.get('ses_1', 500)).toBeUndefined(); // map entry is deleted completely
  });

  test('record refreshes expiry', () => {
    const map = new StickyMap(1000);
    map.record('ses_1', 'serve_a', 100);
    expect(map.get('ses_1', 500)).toBe('serve_a');

    // record again to refresh expiry
    map.record('ses_1', 'serve_a', 500); // expiry becomes 500 + 1000 = 1500
    expect(map.get('ses_1', 1200)).toBe('serve_a'); // would have been expired under old expiry (1100)
    expect(map.get('ses_1', 1500)).toBeUndefined(); // now expired at 1500
  });

  test('delete removes', () => {
    const map = new StickyMap(1000);
    map.record('ses_1', 'serve_a', 100);
    expect(map.get('ses_1', 500)).toBe('serve_a');

    map.delete('ses_1');
    expect(map.get('ses_1', 500)).toBeUndefined();
  });

  test('has reflects presence and freshness', () => {
    const map = new StickyMap(1000);
    map.record('ses_1', 'serve_a', 100);

    expect(map.has('ses_1', 500)).toBe(true);
    expect(map.has('ses_1', 1100)).toBe(false); // expired
    expect(map.has('ses_1', 500)).toBe(false); // has should also clean it or reflect that it is deleted
  });

  test('opportunistic sweep runs on record when now - lastSweep >= ttlMs', () => {
    const map = new StickyMap(1000);
    map.record('ses_1', 'serve_a', 100);
    map.record('ses_2', 'serve_b', 200);

    // Initial state: 2 entries, lastSweep starts at 0.
    // At now = 100, now - lastSweep = 100 < 1000, so sweep doesn't run during map.record('ses_1', ..., 100)
    // At now = 200, now - lastSweep = 200 < 1000, so sweep doesn't run.
    expect((map as any).entries.size).toBe(2);

    // Record a 3rd entry at now = 1100. now - lastSweep = 1100 >= 1000. Sweep runs!
    // Expiries:
    // ses_1: 100 + 1000 = 1100 -> Expired at 1100.
    // ses_2: 200 + 1000 = 1200 -> Not expired yet (expires at 1200).
    // ses_3: 1100 + 1000 = 2100 -> Fresh.
    map.record('ses_3', 'serve_c', 1100);

    // ses_1 should be swept. ses_2 and ses_3 should remain.
    expect((map as any).entries.size).toBe(2);
    expect(map.get('ses_1', 1100)).toBeUndefined();
    expect(map.get('ses_2', 1100)).toBe('serve_b');
    expect(map.get('ses_3', 1100)).toBe('serve_c');
    expect((map as any).lastSweep).toBe(1100);
  });

  test('lease renewal tracking on record and update', () => {
    const map = new StickyMap(1000); // ttlMs = 1000, half is 500
    map.record('ses_1', 'serve_a', 100);

    // 1) Initial record defaults leaseRenewedAt to now (100)
    expect((map as any).entries.get('ses_1')?.leaseRenewedAt).toBe(100);
    // At now = 100, age = 0 -> needsLeaseRenewal is false (0 < 500)
    expect(map.needsLeaseRenewal('ses_1', 100)).toBe(false);
    // At now = 599, age = 499 -> needsLeaseRenewal is false (499 < 500)
    expect(map.needsLeaseRenewal('ses_1', 599)).toBe(false);
    // At now = 600, age = 500 -> needsLeaseRenewal is true (500 >= 500)
    expect(map.needsLeaseRenewal('ses_1', 600)).toBe(true);

    // 2) Record updates expiry (refresh TTL) but preserves existing leaseRenewedAt
    map.record('ses_1', 'serve_a', 300); // expiry becomes 300 + 1000 = 1300
    expect((map as any).entries.get('ses_1')?.leaseRenewedAt).toBe(100); // still 100!
    expect(map.needsLeaseRenewal('ses_1', 600)).toBe(true);

    // 3) Record allows overriding leaseRenewedAt explicitly (e.g. seeding unknown age)
    map.record('ses_2', 'serve_b', 300, 0); // explicitly set leaseRenewedAt = 0
    expect((map as any).entries.get('ses_2')?.leaseRenewedAt).toBe(0);
    expect(map.needsLeaseRenewal('ses_2', 500)).toBe(true); // age = 500 >= 500 -> true

    // 4) setLeaseRenewedAt updates leaseRenewedAt
    map.setLeaseRenewedAt('ses_1', 400);
    expect((map as any).entries.get('ses_1')?.leaseRenewedAt).toBe(400);
    expect(map.needsLeaseRenewal('ses_1', 600)).toBe(false); // age = 200 < 500 -> false
  });
});

describe('isMutatingSessionRequest', () => {
  test('POST/PATCH/DELETE session-path (bare + /api) -> true', () => {
    expect(isMutatingSessionRequest('POST', '/session/ses_a', { kind: 'single', sid: 'ses_a' })).toBe(true);
    expect(isMutatingSessionRequest('PATCH', '/api/session/ses_a', { kind: 'single', sid: 'ses_a' })).toBe(true);
    expect(isMutatingSessionRequest('DELETE', '/session/ses_a/message', { kind: 'single', sid: 'ses_a' })).toBe(true);
  });

  test('GET session-path -> false', () => {
    expect(isMutatingSessionRequest('GET', '/session/ses_a', { kind: 'single', sid: 'ses_a' })).toBe(false);
  });

  test('POST /event?session_ids= single (query, not path) -> false', () => {
    expect(isMutatingSessionRequest('POST', '/event', { kind: 'single', sid: 'ses_a' })).toBe(false);
  });

  test('multi/none -> false', () => {
    expect(isMutatingSessionRequest('POST', '/session/ses_a', { kind: 'multi', sids: ['ses_a', 'ses_b'] })).toBe(false);
    expect(isMutatingSessionRequest('POST', '/session/ses_a', { kind: 'none' })).toBe(false);
    expect(isMutatingSessionRequest('POST', '/session/ses_a', { kind: 'malformed' })).toBe(false);
  });
});
