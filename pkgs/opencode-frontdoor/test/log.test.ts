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
