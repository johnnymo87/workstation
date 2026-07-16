import { describe, test, expect } from 'vitest';
import { extractSids } from '../src/sid.js';

describe('extractSids', () => {
  // Helpers to construct standard WHATWG URLs for testing
  const makeUrl = (pathWithSearch: string) => {
    return new URL(pathWithSearch, 'http://127.0.0.1');
  };

  // --- PATH-BASED EXTRACTOR TESTS ---

  test('bare path single (GET /session/ses_123)', () => {
    const url = makeUrl('/session/ses_123');
    expect(extractSids(url)).toEqual({ kind: 'single', sid: 'ses_123' });
  });

  test('/api path single (GET /api/session/ses_123)', () => {
    const url = makeUrl('/api/session/ses_123');
    expect(extractSids(url)).toEqual({ kind: 'single', sid: 'ses_123' });
  });

  test('nested path (POST /session/ses_123/message)', () => {
    const url = makeUrl('/session/ses_123/message');
    expect(extractSids(url)).toEqual({ kind: 'single', sid: 'ses_123' });
  });

  test('/api nested path (POST /api/session/ses_123/message)', () => {
    const url = makeUrl('/api/session/ses_123/message');
    expect(extractSids(url)).toEqual({ kind: 'single', sid: 'ses_123' });
  });

  test('deeply nested path (GET /session/ses_x/message/msg_y/part/p_z)', () => {
    const url = makeUrl('/session/ses_x/message/msg_y/part/p_z');
    expect(extractSids(url)).toEqual({ kind: 'single', sid: 'ses_x' });
  });

  test('experimental background path (POST /experimental/session/ses_x/background)', () => {
    const url = makeUrl('/experimental/session/ses_x/background');
    expect(extractSids(url)).toEqual({ kind: 'single', sid: 'ses_x' });
  });

  test('/api experimental background path (POST /api/experimental/session/ses_x/background)', () => {
    const url = makeUrl('/api/experimental/session/ses_x/background');
    expect(extractSids(url)).toEqual({ kind: 'single', sid: 'ses_x' });
  });

  // --- SPECIAL / NO SID PATHS ---

  test('/session/status should return none', () => {
    const url = makeUrl('/session/status');
    expect(extractSids(url)).toEqual({ kind: 'none' });
  });

  test('/api/session/status should return none', () => {
    const url = makeUrl('/api/session/status');
    expect(extractSids(url)).toEqual({ kind: 'none' });
  });

  test('/api/session/active should return none', () => {
    const url = makeUrl('/api/session/active');
    expect(extractSids(url)).toEqual({ kind: 'none' });
  });

  test('/session/active should return none', () => {
    const url = makeUrl('/session/active');
    expect(extractSids(url)).toEqual({ kind: 'none' });
  });

  test('non-ses path literal /session/whatever should return none', () => {
    const url = makeUrl('/session/whatever');
    expect(extractSids(url)).toEqual({ kind: 'none' });
  });

  test('malformed attempted path sid /session/ses_bad!/message should return malformed', () => {
    const url = makeUrl('/session/ses_bad!/message');
    expect(extractSids(url)).toEqual({ kind: 'malformed' });
  });

  test('POST /session (create) should return none', () => {
    const url = makeUrl('/session');
    expect(extractSids(url)).toEqual({ kind: 'none' });
  });

  test('POST /api/session (create) should return none', () => {
    const url = makeUrl('/api/session');
    expect(extractSids(url)).toEqual({ kind: 'none' });
  });

  test('globals (/global/health) should return none', () => {
    const url = makeUrl('/global/health');
    expect(extractSids(url)).toEqual({ kind: 'none' });
  });

  test('/api/global/health should return none', () => {
    const url = makeUrl('/api/global/health');
    expect(extractSids(url)).toEqual({ kind: 'none' });
  });

  // --- QUERY PARAMETER TESTS ---

  test('GET /api/event?session=ses_x should return single', () => {
    const url = makeUrl('/api/event?session=ses_x');
    expect(extractSids(url)).toEqual({ kind: 'single', sid: 'ses_x' });
  });

  test('GET /api/event?session=garbage should return malformed', () => {
    const url = makeUrl('/api/event?session=garbage');
    expect(extractSids(url)).toEqual({ kind: 'malformed' });
  });

  test('GET /api/event?session= (empty) should return none', () => {
    const url = makeUrl('/api/event?session=');
    expect(extractSids(url)).toEqual({ kind: 'none' });
  });

  test('GET /api/event?session_ids=ses_x should return single', () => {
    const url = makeUrl('/api/event?session_ids=ses_x');
    expect(extractSids(url)).toEqual({ kind: 'single', sid: 'ses_x' });
  });

  test('GET /api/event?session_ids=ses_a,ses_b should return multi', () => {
    const url = makeUrl('/api/event?session_ids=ses_a,ses_b');
    expect(extractSids(url)).toEqual({ kind: 'multi', sids: ['ses_a', 'ses_b'] });
  });

  test('GET /api/event?session_ids=ses_a,,ses_b should drop empty elements and return multi', () => {
    const url = makeUrl('/api/event?session_ids=ses_a,,ses_b');
    expect(extractSids(url)).toEqual({ kind: 'multi', sids: ['ses_a', 'ses_b'] });
  });

  test('GET /api/event?session_ids=ses_a,, should drop empty elements and return single', () => {
    const url = makeUrl('/api/event?session_ids=ses_a,,');
    expect(extractSids(url)).toEqual({ kind: 'single', sid: 'ses_a' });
  });

  test('GET /api/event?session_ids= (empty) should return none', () => {
    const url = makeUrl('/api/event?session_ids=');
    expect(extractSids(url)).toEqual({ kind: 'none' });
  });

  test('GET /api/event?session_ids=, (empty elements only) should return none', () => {
    const url = makeUrl('/api/event?session_ids=,');
    expect(extractSids(url)).toEqual({ kind: 'none' });
  });

  test('GET /api/event?session_ids=ses_a,garbage should return malformed', () => {
    const url = makeUrl('/api/event?session_ids=ses_a,garbage');
    expect(extractSids(url)).toEqual({ kind: 'malformed' });
  });

  test('GET /api/event?session_ids=garbage,ses_a should return malformed', () => {
    const url = makeUrl('/api/event?session_ids=garbage,ses_a');
    expect(extractSids(url)).toEqual({ kind: 'malformed' });
  });

  // --- PATH REGEX & CHARACTER VALIDATION ---

  test('malformed path sid (/session/not-a-sid) should return none because it is treated as a literal', () => {
    const url = makeUrl('/session/not-a-sid');
    expect(extractSids(url)).toEqual({ kind: 'none' });
  });

  test('sid with allowed characters (ses_09abcXYZ_-) should return single', () => {
    const url = makeUrl('/session/ses_09abcXYZ_-');
    expect(extractSids(url)).toEqual({ kind: 'single', sid: 'ses_09abcXYZ_-' });
  });

  test('sid with disallowed characters in path (ses_a.b) should return malformed', () => {
    const url = makeUrl('/session/ses_a.b');
    expect(extractSids(url)).toEqual({ kind: 'malformed' });
  });

  test('sid with disallowed characters in query (ses_a/b) should return malformed', () => {
    const url = makeUrl('/api/event?session=ses_a/b');
    expect(extractSids(url)).toEqual({ kind: 'malformed' });
  });

  // --- PRECEDENCE TESTS ---

  test('path takes precedence over session_ids query parameter (valid path, valid query)', () => {
    const url = makeUrl('/session/ses_a?session_ids=ses_b,ses_c');
    expect(extractSids(url)).toEqual({ kind: 'single', sid: 'ses_a' });
  });

  test('path takes precedence over session_ids query parameter (literal path, valid query)', () => {
    const url = makeUrl('/session/garbage?session_ids=ses_b,ses_c');
    expect(extractSids(url)).toEqual({ kind: 'none' });
  });
});
