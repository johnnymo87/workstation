import { describe, test, expect } from 'vitest';
import { RequestLogger, type RequestLogEntry } from '../src/log.js';

describe('RequestLogger', () => {
  test('log emits exactly one JSON line via injected sink with correct fields and ts', () => {
    const lines: string[] = [];
    const sink = (line: string) => {
      lines.push(line);
    };
    const testNow = 1710000000000; // ISO: 2024-03-09T16:00:00.000Z
    const now = () => testNow;

    const logger = new RequestLogger({ sink, now });
    const entry: RequestLogEntry = {
      class: 'route-class',
      sid: 'session-123',
      target: 'http://upstream-url',
      prospective: false,
      degraded: false,
      status: 200,
      durationMs: 45,
      method: 'GET',
      path: '/foo',
      action: 'action-abc',
    };

    logger.log(entry);

    expect(lines).toHaveLength(1);
    const parsed = JSON.parse(lines[0]);
    expect(parsed).toEqual({
      ts: new Date(testNow).toISOString(),
      type: 'request',
      class: 'route-class',
      sid: 'session-123',
      target: 'http://upstream-url',
      prospective: false,
      degraded: false,
      status: 200,
      durationMs: 45,
      method: 'GET',
      path: '/foo',
      action: 'action-abc',
    });
  });

  test('increments totalRequests and degradedToAnchor appropriately', () => {
    const logger = new RequestLogger({ sink: () => {} });

    // Initial state
    expect(logger.snapshot()).toEqual({
      degradedToAnchor: 0,
      totalRequests: 0,
    });

    const baseEntry: RequestLogEntry = {
      class: 'chat',
      sid: 'session-1',
      target: 'http://localhost:3000',
      prospective: false,
      degraded: false,
      status: 200,
      durationMs: 10,
    };

    // Log degraded = false
    logger.log(baseEntry);
    expect(logger.snapshot()).toEqual({
      degradedToAnchor: 0,
      totalRequests: 1,
    });

    // Log degraded = true
    logger.log({ ...baseEntry, degraded: true });
    expect(logger.snapshot()).toEqual({
      degradedToAnchor: 1,
      totalRequests: 2,
    });

    // Log degraded = false again
    logger.log(baseEntry);
    expect(logger.snapshot()).toEqual({
      degradedToAnchor: 1,
      totalRequests: 3,
    });
  });

  test('snapshot returns a fresh copy of counters', () => {
    const logger = new RequestLogger({ sink: () => {} });
    logger.log({
      class: 'chat',
      sid: null,
      target: 'http://localhost:3000',
      prospective: false,
      degraded: true,
      status: 200,
      durationMs: 10,
    });

    const snap1 = logger.snapshot();
    const snap2 = logger.snapshot();

    expect(snap1).toEqual({
      degradedToAnchor: 1,
      totalRequests: 1,
    });
    expect(snap1).not.toBe(snap2); // must be distinct object references

    // Mutating snap1 should not affect snapshot() or snap2
    snap1.totalRequests = 999;
    snap1.degradedToAnchor = 999;

    expect(logger.snapshot()).toEqual({
      degradedToAnchor: 1,
      totalRequests: 1,
    });
  });

  test('multiple logger instances have independent counters', () => {
    const logger1 = new RequestLogger({ sink: () => {} });
    const logger2 = new RequestLogger({ sink: () => {} });

    const entry: RequestLogEntry = {
      class: 'chat',
      sid: null,
      target: 'http://localhost:3000',
      prospective: false,
      degraded: true,
      status: 200,
      durationMs: 10,
    };

    logger1.log(entry);

    expect(logger1.snapshot()).toEqual({
      degradedToAnchor: 1,
      totalRequests: 1,
    });
    expect(logger2.snapshot()).toEqual({
      degradedToAnchor: 0,
      totalRequests: 0,
    });
  });

  test('sink receives exactly one call per log call', () => {
    let callCount = 0;
    const logger = new RequestLogger({
      sink: () => {
        callCount++;
      },
    });

    const entry: RequestLogEntry = {
      class: 'chat',
      sid: null,
      target: 'http://localhost:3000',
      prospective: false,
      degraded: true,
      status: 200,
      durationMs: 10,
    };

    logger.log(entry);
    expect(callCount).toBe(1);

    logger.log(entry);
    expect(callCount).toBe(2);
  });

  test('sid: null and numeric status: 0 serialize correctly', () => {
    const lines: string[] = [];
    const logger = new RequestLogger({
      sink: (line) => {
        lines.push(line);
      },
    });

    const entry: RequestLogEntry = {
      class: 'chat',
      sid: null,
      target: 'http://localhost:3000',
      prospective: false,
      degraded: true,
      status: 0,
      durationMs: 10,
    };

    logger.log(entry);

    expect(lines).toHaveLength(1);
    const parsed = JSON.parse(lines[0]);
    expect(parsed.sid).toBeNull();
    expect(parsed.status).toBe(0);
  });
});

/*
 * Sampling (workstation-9f7a).
 *
 * The door emitted ~400k lines/day, 57% of ALL journal volume on cloudbox, and
 * evicted every other unit's history down to a ~6 day window. Measured over 6
 * hours (99,760 lines): 90.2% were plain 200 GETs that said nothing, against 19
 * degradations and 167 5xx in the same window.
 *
 * So the boring case is sampled and EVERYTHING ELSE is kept. The tests below pin
 * both halves; the "always" half is the one that matters, because a sampler that
 * drops a 5xx is worse than no sampler at all.
 */
describe('RequestLogger sampling', () => {
  const base: RequestLogEntry = {
    class: 'session-path',
    sid: 'session-1',
    target: 'http://localhost:4096',
    prospective: false,
    degraded: false,
    status: 200,
    durationMs: 10,
    method: 'GET',
    path: '/session/abc/children',
  };

  function collect(deps: { sampleN?: number; summaryIntervalMs?: number; now?: () => number }) {
    const lines: string[] = [];
    const logger = new RequestLogger({ sink: (l) => lines.push(l), ...deps });
    const requests = () => lines.map((l) => JSON.parse(l)).filter((p) => p.type === 'request');
    const summaries = () => lines.map((l) => JSON.parse(l)).filter((p) => p.type === 'request_summary');
    return { logger, lines, requests, summaries };
  }

  test('samples plain 200 GETs on session-path at exactly 1-in-N, keeping the first', () => {
    const { logger, requests } = collect({ sampleN: 50 });

    for (let i = 0; i < 100; i++) logger.log({ ...base, durationMs: i });

    // 1st and 51st, i.e. durationMs 0 and 50.
    expect(requests().map((r) => r.durationMs)).toEqual([0, 50]);
  });

  test('samples global-ro the same way', () => {
    const { logger, requests } = collect({ sampleN: 10 });

    for (let i = 0; i < 30; i++) logger.log({ ...base, class: 'global-ro', durationMs: i });

    expect(requests().map((r) => r.durationMs)).toEqual([0, 10, 20]);
  });

  test.each([
    ['404', { status: 404 }],
    ['500', { status: 500 }],
    ['503', { status: 503 }],
    ['204', { status: 204 }],
    ['degraded', { degraded: true }],
    ['POST', { method: 'POST' }],
    ['DELETE', { method: 'DELETE' }],
    ['absent method', { method: undefined }],
    ['class create', { class: 'create' }],
    ['class session-query', { class: 'session-query' }],
    ['class per-process-ro', { class: 'per-process-ro' }],
    ['class unrecognized', { class: 'unrecognized' }],
  ])('never samples away: %s', (_label, override) => {
    const { logger, requests } = collect({ sampleN: 50 });

    for (let i = 0; i < 20; i++) logger.log({ ...base, ...override });

    expect(requests()).toHaveLength(20);
  });

  test('an always-logged entry does not consume or reset the sampling counter', () => {
    const { logger, requests } = collect({ sampleN: 5 });

    // Interleave a 500 before every sampleable request. If the 500s advanced the
    // counter, the sampled set would drift; if they reset it, everything would be
    // logged. Neither may happen.
    for (let i = 0; i < 10; i++) {
      logger.log({ ...base, status: 500, durationMs: 900 + i });
      logger.log({ ...base, durationMs: i });
    }

    const sampled = requests().filter((r) => r.status === 200).map((r) => r.durationMs);
    expect(sampled).toEqual([0, 5]);
    expect(requests().filter((r) => r.status === 500)).toHaveLength(10);
  });

  test('sampleN=1 logs every request (the mid-incident escape hatch)', () => {
    const { logger, requests } = collect({ sampleN: 1 });

    for (let i = 0; i < 20; i++) logger.log({ ...base, durationMs: i });

    expect(requests()).toHaveLength(20);
  });

  test.each([
    ['exactly at the threshold', 1000, true],
    ['above the threshold', 30000, true],
    ['just below the threshold', 999, false],
  ])('slow 200 GETs escape sampling: %s', (_label, durationMs, expectAlwaysLogged) => {
    // A GET that succeeded in 30s is not a boring request. Without this fence a
    // serve drifting from 5ms to 900ms produces no signal in EITHER channel --
    // sampled away from the per-request log, and the summary carries no latency.
    // Cheap: only 179 of ~98k sampleable requests in 6h were >=1s (0.18%).
    const { logger, requests } = collect({ sampleN: 50 });

    // One sid throughout, so the first-touch rule below cannot confound this.
    for (let i = 0; i < 20; i++) logger.log({ ...base, durationMs });

    expect(requests()).toHaveLength(expectAlwaysLogged ? 20 : 1);
  });

  test('sampleN=0 logs everything rather than modulo-by-zero into total silence', () => {
    // loadConfig rejects 0 (see config.test.ts), so this is the second line of
    // defence for a logger constructed directly. `nth % 0` is NaN, and NaN !== 0,
    // so without the fence EVERY sampleable request would be suppressed -- the
    // door would go quiet on 90% of its traffic and nothing would say so.
    const { logger, requests } = collect({ sampleN: 0 });

    for (let i = 0; i < 20; i++) logger.log({ ...base, durationMs: i });

    expect(requests()).toHaveLength(20);
  });

  test('defaults to 1-in-50 when no sampleN is supplied', () => {
    const { logger, requests } = collect({});

    for (let i = 0; i < 150; i++) logger.log({ ...base, durationMs: i });

    expect(requests().map((r) => r.durationMs)).toEqual([0, 50, 100]);
  });

  test('always logs the first request of each session in a window', () => {
    // Measured against 6h of real traffic: with a plain 1-in-50 global stride,
    // 184 of 276 sessions (67%) emit NO door line at all -- "did session X reach
    // the door, and via which serve?" becomes unanswerable for two thirds of
    // them, and the summary cannot restore it because it is aggregates only.
    // First-touch costs ~0.3% of volume.
    const { logger, requests } = collect({ sampleN: 50 });

    for (const sid of ['a', 'b', 'c']) {
      for (let i = 0; i < 10; i++) logger.log({ ...base, sid, durationMs: i });
    }

    expect(requests().map((r) => [r.sid, r.durationMs])).toEqual([
      ['a', 0],
      ['b', 0],
      ['c', 0],
    ]);
  });

  test('first-touch does not disturb the 1-in-N stride', () => {
    const { logger, requests } = collect({ sampleN: 5 });

    // 'a' is first-touched at nth=0; 'b' at nth=1. The stride must keep counting
    // every sampleable request, so nth=5 still lands regardless of which sid it
    // belongs to -- otherwise first-touch would silently re-phase the sampling.
    logger.log({ ...base, sid: 'a', durationMs: 0 });
    for (let i = 1; i < 10; i++) logger.log({ ...base, sid: 'b', durationMs: i });

    expect(requests().map((r) => [r.sid, r.durationMs])).toEqual([
      ['a', 0],
      ['b', 1],
      ['b', 5],
    ]);
  });

  test('first-touch re-arms each window, so a long-lived session reappears', () => {
    const lines: string[] = [];
    let t = 1710000000000;
    const logger = new RequestLogger({
      sink: (l) => lines.push(l),
      now: () => t,
      sampleN: 50,
      summaryIntervalMs: 1000,
    });

    for (let i = 0; i < 10; i++) logger.log({ ...base, sid: 'a', durationMs: i });
    t += 1000;
    for (let i = 100; i < 110; i++) logger.log({ ...base, sid: 'a', durationMs: i });

    const seen = lines
      .map((l) => JSON.parse(l))
      .filter((p) => p.type === 'request')
      .map((r) => r.durationMs);
    // Bounded memory: the sid set is per-window, not for the process lifetime.
    expect(seen).toEqual([0, 100]);
  });

  test('a null sid does not first-touch, and does not crash', () => {
    const { logger, requests } = collect({ sampleN: 50 });

    for (let i = 0; i < 20; i++) logger.log({ ...base, class: 'global-ro', sid: null, durationMs: i });

    expect(requests().map((r) => r.durationMs)).toEqual([0]);
  });

  test('counters count every request, including the ones sampled away', () => {
    const { logger, requests } = collect({ sampleN: 50 });

    for (let i = 0; i < 100; i++) logger.log({ ...base });
    for (let i = 0; i < 3; i++) logger.log({ ...base, degraded: true });

    // Only 2 of the 100 reached the sink, but /healthz-style accounting must see all
    // 103. Sampling is a LOGGING decision, never a measurement one.
    expect(requests()).toHaveLength(2 + 3);
    expect(logger.snapshot()).toEqual({ degradedToAnchor: 3, totalRequests: 103 });
  });
});

/*
 * The periodic summary is what stops sampling from destroying the ability to
 * answer "how much traffic was there?". Without it, a sampled-away request leaves
 * no trace anywhere in the journal.
 */
describe('RequestLogger summary line', () => {
  const base: RequestLogEntry = {
    class: 'session-path',
    sid: 'session-1',
    target: 'http://localhost:4096',
    prospective: false,
    degraded: false,
    status: 200,
    durationMs: 10,
    method: 'GET',
    path: '/session/abc/children',
    query: 'directory=/home/dev/projects/pigeon',
  };

  function makeClock(start: number) {
    let t = start;
    return { now: () => t, advance: (ms: number) => { t += ms; } };
  }

  test('emits a summary once the interval has elapsed, accounting for suppressed lines', () => {
    const clock = makeClock(1710000000000);
    const lines: string[] = [];
    const logger = new RequestLogger({
      sink: (l) => lines.push(l),
      now: clock.now,
      sampleN: 50,
      summaryIntervalMs: 300000,
    });

    for (let i = 0; i < 100; i++) logger.log({ ...base });
    logger.log({ ...base, status: 404 });
    logger.log({ ...base, status: 503, degraded: true });

    expect(lines.filter((l) => l.includes('request_summary'))).toHaveLength(0);

    clock.advance(300000);
    logger.log({ ...base });

    const summaries = lines.map((l) => JSON.parse(l)).filter((p) => p.type === 'request_summary');
    expect(summaries).toHaveLength(1);
    expect(summaries[0]).toMatchObject({
      type: 'request_summary',
      total: 102,
      emitted: 4, // 2 sampled + the 404 + the 503
      suppressed: 98,
      degraded: 1,
      windowMs: 300000,
      byStatus: { '200': 100, '404': 1, '503': 1 },
    });
  });

  test('the window resets, so a second summary covers only the second window', () => {
    const clock = makeClock(1710000000000);
    const lines: string[] = [];
    const logger = new RequestLogger({
      sink: (l) => lines.push(l),
      now: clock.now,
      sampleN: 50,
      summaryIntervalMs: 1000,
    });

    for (let i = 0; i < 10; i++) logger.log({ ...base });
    clock.advance(1000);
    for (let i = 0; i < 4; i++) logger.log({ ...base, status: 404 });
    clock.advance(1000);
    logger.log({ ...base, status: 503 });
    clock.advance(1000);
    logger.log({ ...base, status: 500 });

    const summaries = lines.map((l) => JSON.parse(l)).filter((p) => p.type === 'request_summary');
    expect(summaries).toHaveLength(3);
    expect(summaries[0]).toMatchObject({ total: 10, byStatus: { '200': 10 } });
    // Windows do not bleed: the 404s are not re-counted here.
    expect(summaries[1]).toMatchObject({ total: 4, byStatus: { '404': 4 } });
    // The flush is lazy, so the request that TRIGGERS a flush is accounted to the
    // window it opens, not the one it closes. The 503 lands here, not above.
    expect(summaries[2]).toMatchObject({ total: 1, byStatus: { '503': 1 } });
  });

  test('reports the true elapsed window, not the nominal interval, after an idle gap', () => {
    const clock = makeClock(1710000000000);
    const lines: string[] = [];
    const logger = new RequestLogger({
      sink: (l) => lines.push(l),
      now: clock.now,
      summaryIntervalMs: 1000,
    });

    logger.log({ ...base, class: 'create', method: 'POST' });
    clock.advance(3600000); // an hour of silence
    logger.log({ ...base, class: 'create', method: 'POST' });

    const summary = lines.map((l) => JSON.parse(l)).find((p) => p.type === 'request_summary');
    // A summary claiming windowMs=1000 for an hour-long window would misstate the
    // rate by 3600x, which is exactly the question the summary exists to answer.
    expect(summary.windowMs).toBe(3600000);
  });

  test('the summary carries no request-identifying fields', () => {
    const clock = makeClock(1710000000000);
    const lines: string[] = [];
    const logger = new RequestLogger({
      sink: (l) => lines.push(l),
      now: clock.now,
      summaryIntervalMs: 1000,
    });

    logger.log({ ...base, sid: 'session-secret', path: '/session/secret/children' });
    clock.advance(1000);
    logger.log({ ...base });

    const raw = lines.find((l) => l.includes('request_summary'))!;
    expect(raw).not.toContain('session-secret');
    expect(raw).not.toContain('/session/secret');
    expect(raw).not.toContain('directory');
    const summary = JSON.parse(raw);
    expect(Object.keys(summary).sort()).toEqual(
      [
        'byClass',
        'byStatus',
        'byTarget',
        'degraded',
        'emitted',
        'firstTs',
        'lastTs',
        'suppressed',
        'total',
        'ts',
        'type',
        'windowMs',
      ].sort(),
    );
  });

  test('breaks the window down by class and target, so the per-target join survives', () => {
    // Sampling makes a per-minute count of requests-per-target unreliable (a
    // target gets ~1.4 samples/min). These aggregates are exact and cost nothing:
    // cardinality is a handful of classes and pool members.
    const clock = makeClock(1710000000000);
    const lines: string[] = [];
    const logger = new RequestLogger({
      sink: (l) => lines.push(l),
      now: clock.now,
      sampleN: 50,
      summaryIntervalMs: 1000,
    });

    for (let i = 0; i < 30; i++) logger.log({ ...base, target: 'http://127.0.0.1:4096' });
    for (let i = 0; i < 7; i++) {
      logger.log({ ...base, class: 'global-ro', target: 'http://127.0.0.1:4097' });
    }
    clock.advance(1000);
    logger.log({ ...base });

    const summary = lines.map((l) => JSON.parse(l)).find((p) => p.type === 'request_summary');
    expect(summary.byClass).toEqual({ 'session-path': 30, 'global-ro': 7 });
    expect(summary.byTarget).toEqual({
      'http://127.0.0.1:4096': 30,
      'http://127.0.0.1:4097': 7,
    });
  });

  test('reports when the window\'s traffic actually happened, not just how long the window was', () => {
    // windowMs alone cannot give a rate. After an idle gap the requests all
    // happened at one end of the window, so total/windowMs UNDERSTATES the burst
    // just as badly as a nominal interval would overstate a quiet stretch.
    // Emitting the first and last event timestamps lets the reader compute either.
    const clock = makeClock(1710000000000);
    const lines: string[] = [];
    const logger = new RequestLogger({
      sink: (l) => lines.push(l),
      now: clock.now,
      summaryIntervalMs: 1000,
    });

    logger.log({ ...base, status: 500 });
    clock.advance(50);
    logger.log({ ...base, status: 500 });
    clock.advance(3600000); // an hour of silence, then the flushing request
    logger.log({ ...base, status: 500 });

    const summary = lines.map((l) => JSON.parse(l)).find((p) => p.type === 'request_summary');
    expect(summary.windowMs).toBe(3600050);
    expect(summary.firstTs).toBe(new Date(1710000000000).toISOString());
    expect(summary.lastTs).toBe(new Date(1710000000050).toISOString());
  });

  test('an idle window produces no summary at all', () => {
    const clock = makeClock(1710000000000);
    const lines: string[] = [];
    const logger = new RequestLogger({
      sink: (l) => lines.push(l),
      now: clock.now,
      summaryIntervalMs: 1000,
    });

    // A door that served nothing overnight must not wake up and report a window of
    // zeroes; an all-zero summary reads like a measurement, not like silence.
    clock.advance(86400000);
    logger.log({ ...base, status: 500 });

    expect(lines.filter((l) => l.includes('request_summary'))).toHaveLength(0);
  });

  test('no summary is emitted while a single window is still open', () => {
    const clock = makeClock(1710000000000);
    const lines: string[] = [];
    const logger = new RequestLogger({
      sink: (l) => lines.push(l),
      now: clock.now,
      summaryIntervalMs: 300000,
    });

    clock.advance(299999);
    for (let i = 0; i < 500; i++) logger.log({ ...base });

    expect(lines.filter((l) => l.includes('request_summary'))).toHaveLength(0);
  });
});
