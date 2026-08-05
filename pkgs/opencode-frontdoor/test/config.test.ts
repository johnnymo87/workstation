// unwired-test(workstation-5m47): unhermetic (npm ci + loopback sockets); belongs in a ci.yml step, not a nix check
import { describe, test, expect, beforeEach, afterEach } from 'vitest';
import { loadConfig } from '../src/config.js';

describe('loadConfig', () => {
  let originalEnv: NodeJS.ProcessEnv;

  beforeEach(() => {
    // Backup process.env to ensure isolation between tests
    originalEnv = { ...process.env };

    // Clear relevant environment variables so we start with defaults
    delete process.env.FRONTDOOR_PORT;
    delete process.env.FRONTDOOR_POOL_URLS;
    delete process.env.FRONTDOOR_VERSION;
    delete process.env.PIGEON_DAEMON_URL;
    delete process.env.OPENCODE_ANCHOR_URL;
    delete process.env.PIGEON_DAEMON_AUTH_TOKEN;
    delete process.env.OPENCODE_SERVER_PASSWORD;
    delete process.env.OPENCODE_SERVER_USERNAME;
    delete process.env.FRONTDOOR_ROUTE_TIMEOUT_MS;
    delete process.env.FRONTDOOR_CHEAP_FIRST_BYTE_MS;
    delete process.env.FRONTDOOR_STICKY_TTL_MS;
    delete process.env.FRONTDOOR_DRIFT_CHECK_MS;
    delete process.env.FRONTDOOR_WEDGE_PROBE_INTERVAL_MS;
    delete process.env.FRONTDOOR_MINT_TIMEOUT_MS;
  });

  afterEach(() => {
    // Restore process.env in place (keep the native proxy object; just delete
    // keys added during the test and reassign the originals).
    for (const key of Object.keys(process.env)) {
      if (!(key in originalEnv)) {
        delete process.env[key];
      }
    }
    Object.assign(process.env, originalEnv);
  });

  test('should load default configuration when no environment variables are set', () => {
    const config = loadConfig();

    expect(config).toEqual({
      port: 4700,
      version: 'unknown',
      pigeonUrl: 'http://127.0.0.1:4731',
      anchorUrl: 'http://127.0.0.1:4096',
      poolUrls: ['http://127.0.0.1:4096'],
      pigeonAuthToken: undefined,
      serveAuthHeader: undefined,
      routeTimeoutMs: 3000,
      cheapFirstByteMs: 5000,
      stickyTtlMs: 30000,
      driftCheckMs: 5000,
      wedgeProbeIntervalMs: 5000,
      mintTimeoutMs: 60000,
    });
  });

  test('should resolve serveAuthHeader correctly based on OPENCODE_SERVER_PASSWORD and OPENCODE_SERVER_USERNAME', () => {
    // Unset password => undefined
    delete process.env.OPENCODE_SERVER_PASSWORD;
    delete process.env.OPENCODE_SERVER_USERNAME;
    expect(loadConfig().serveAuthHeader).toBeUndefined();

    // Empty password => undefined
    process.env.OPENCODE_SERVER_PASSWORD = '';
    expect(loadConfig().serveAuthHeader).toBeUndefined();

    // Whitespace-only password => undefined (empty-after-trim)
    process.env.OPENCODE_SERVER_PASSWORD = '   \n\t  ';
    expect(loadConfig().serveAuthHeader).toBeUndefined();

    // Password set (with surrounding whitespace to trim), username unset => default username 'opencode'
    process.env.OPENCODE_SERVER_PASSWORD = '  mysecretpassword  \n';
    expect(loadConfig().serveAuthHeader).toBe(`Basic ${Buffer.from('opencode:mysecretpassword').toString('base64')}`);

    // Password set, username set (with surrounding whitespace)
    process.env.OPENCODE_SERVER_USERNAME = '  customuser  \t';
    expect(loadConfig().serveAuthHeader).toBe(`Basic ${Buffer.from('customuser:mysecretpassword').toString('base64')}`);

    // Password set, username set to all-whitespace => falls back to 'opencode'
    process.env.OPENCODE_SERVER_USERNAME = '   \n\t  ';
    expect(loadConfig().serveAuthHeader).toBe(`Basic ${Buffer.from('opencode:mysecretpassword').toString('base64')}`);
  });

  test('should override default values with valid environment variables', () => {
    process.env.FRONTDOOR_PORT = '4800';
    process.env.FRONTDOOR_VERSION = 'v1.2.3-test';
    process.env.PIGEON_DAEMON_URL = 'http://10.0.0.1:4731';
    process.env.OPENCODE_ANCHOR_URL = 'http://10.0.0.1:4096';
    process.env.PIGEON_DAEMON_AUTH_TOKEN = 'secret-token';
    process.env.FRONTDOOR_ROUTE_TIMEOUT_MS = '1500';
    process.env.FRONTDOOR_CHEAP_FIRST_BYTE_MS = '2500';
    process.env.FRONTDOOR_STICKY_TTL_MS = '10000';
    process.env.FRONTDOOR_DRIFT_CHECK_MS = '2000';
    process.env.FRONTDOOR_WEDGE_PROBE_INTERVAL_MS = '1000';
    process.env.FRONTDOOR_MINT_TIMEOUT_MS = '45000';

    const config = loadConfig();

    expect(config).toEqual({
      port: 4800,
      version: 'v1.2.3-test',
      pigeonUrl: 'http://10.0.0.1:4731',
      anchorUrl: 'http://10.0.0.1:4096',
      poolUrls: ['http://10.0.0.1:4096'],
      pigeonAuthToken: 'secret-token',
      serveAuthHeader: undefined,
      routeTimeoutMs: 1500,
      cheapFirstByteMs: 2500,
      stickyTtlMs: 10000,
      driftCheckMs: 2000,
      wedgeProbeIntervalMs: 1000,
      mintTimeoutMs: 45000,
    });
  });

  describe('FRONTDOOR_POOL_URLS', () => {
    test('defaults to [anchorUrl] when unset', () => {
      delete process.env.FRONTDOOR_POOL_URLS;
      process.env.OPENCODE_ANCHOR_URL = 'http://127.0.0.1:4096';
      expect(loadConfig().poolUrls).toEqual(['http://127.0.0.1:4096']);
    });

    test('parses a comma-separated list in order', () => {
      process.env.FRONTDOOR_POOL_URLS =
        'http://127.0.0.1:4096,http://127.0.0.1:4097,http://127.0.0.1:4098';
      expect(loadConfig().poolUrls).toEqual([
        'http://127.0.0.1:4096', 'http://127.0.0.1:4097', 'http://127.0.0.1:4098',
      ]);
    });

    test('trims whitespace and ignores empty entries', () => {
      process.env.FRONTDOOR_POOL_URLS = ' http://127.0.0.1:4096 , ,http://127.0.0.1:4097,';
      expect(loadConfig().poolUrls).toEqual(['http://127.0.0.1:4096', 'http://127.0.0.1:4097']);
    });

    test('falls back to [anchorUrl] when the value is empty or only separators', () => {
      process.env.FRONTDOOR_POOL_URLS = ' , , ';
      process.env.OPENCODE_ANCHOR_URL = 'http://127.0.0.1:4096';
      expect(loadConfig().poolUrls).toEqual(['http://127.0.0.1:4096']);
    });

    test('always includes anchorUrl, appending it if the list omits it', () => {
      process.env.FRONTDOOR_POOL_URLS = 'http://127.0.0.1:4097';
      process.env.OPENCODE_ANCHOR_URL = 'http://127.0.0.1:4096';
      expect(loadConfig().poolUrls).toContain('http://127.0.0.1:4096');
    });

    test('rejects a malformed URL loudly', () => {
      process.env.FRONTDOOR_POOL_URLS = 'http://127.0.0.1:4096,not-a-url';
      expect(() => loadConfig()).toThrow(/FRONTDOOR_POOL_URLS/);
    });

    test('rejects scheme-less entries like 127.0.0.1:4097', () => {
      process.env.FRONTDOOR_POOL_URLS = '127.0.0.1:4097';
      expect(() => loadConfig()).toThrow(/FRONTDOOR_POOL_URLS/);
    });

    test('de-duplicates repeated members, preserving first-seen order', () => {
      process.env.FRONTDOOR_POOL_URLS =
        'http://127.0.0.1:4096,http://127.0.0.1:4097,http://127.0.0.1:4096';
      expect(loadConfig().poolUrls).toEqual(['http://127.0.0.1:4096', 'http://127.0.0.1:4097']);
    });
  });

  test('should throw a descriptive error for invalid FRONTDOOR_PORT', () => {
    process.env.FRONTDOOR_PORT = 'invalid';
    expect(() => loadConfig()).toThrowError('Invalid FRONTDOOR_PORT: "invalid". Must be a positive integer.');

    process.env.FRONTDOOR_PORT = '-4700';
    expect(() => loadConfig()).toThrowError('Invalid FRONTDOOR_PORT: "-4700". Must be a positive integer.');

    process.env.FRONTDOOR_PORT = '3.5';
    expect(() => loadConfig()).toThrowError('Invalid FRONTDOOR_PORT: "3.5". Must be a positive integer.');
  });

  test('should throw for a FRONTDOOR_PORT above the valid TCP range', () => {
    process.env.FRONTDOOR_PORT = '70000';
    expect(() => loadConfig()).toThrowError('Invalid FRONTDOOR_PORT: "70000". Must be a valid TCP port (1-65535).');
  });

  test('should accept the maximum valid TCP port', () => {
    process.env.FRONTDOOR_PORT = '65535';
    expect(loadConfig().port).toBe(65535);
  });

  test('should throw a descriptive error for invalid FRONTDOOR_ROUTE_TIMEOUT_MS', () => {
    process.env.FRONTDOOR_ROUTE_TIMEOUT_MS = 'abc';
    expect(() => loadConfig()).toThrowError('Invalid FRONTDOOR_ROUTE_TIMEOUT_MS: "abc". Must be a positive integer.');

    process.env.FRONTDOOR_ROUTE_TIMEOUT_MS = '0';
    expect(() => loadConfig()).toThrowError('Invalid FRONTDOOR_ROUTE_TIMEOUT_MS: "0". Must be a positive integer.');
  });

  test('should throw a descriptive error for invalid FRONTDOOR_CHEAP_FIRST_BYTE_MS', () => {
    process.env.FRONTDOOR_CHEAP_FIRST_BYTE_MS = 'NaN';
    expect(() => loadConfig()).toThrowError('Invalid FRONTDOOR_CHEAP_FIRST_BYTE_MS: "NaN". Must be a positive integer.');
  });

  test('should throw a descriptive error for invalid FRONTDOOR_STICKY_TTL_MS', () => {
    process.env.FRONTDOOR_STICKY_TTL_MS = '';
    expect(() => loadConfig()).toThrowError('Invalid FRONTDOOR_STICKY_TTL_MS: "". Must be a positive integer.');
  });

  test('should throw a descriptive error for invalid FRONTDOOR_DRIFT_CHECK_MS', () => {
    process.env.FRONTDOOR_DRIFT_CHECK_MS = 'invalid';
    expect(() => loadConfig()).toThrowError('Invalid FRONTDOOR_DRIFT_CHECK_MS: "invalid". Must be a positive integer.');
  });

  test('should throw a descriptive error for invalid FRONTDOOR_WEDGE_PROBE_INTERVAL_MS', () => {
    process.env.FRONTDOOR_WEDGE_PROBE_INTERVAL_MS = 'invalid';
    expect(() => loadConfig()).toThrowError('Invalid FRONTDOOR_WEDGE_PROBE_INTERVAL_MS: "invalid". Must be a positive integer.');
  });

  test('should throw a descriptive error for invalid FRONTDOOR_MINT_TIMEOUT_MS', () => {
    process.env.FRONTDOOR_MINT_TIMEOUT_MS = 'invalid';
    expect(() => loadConfig()).toThrowError('Invalid FRONTDOOR_MINT_TIMEOUT_MS: "invalid". Must be a positive integer.');

    process.env.FRONTDOOR_MINT_TIMEOUT_MS = '0';
    expect(() => loadConfig()).toThrowError('Invalid FRONTDOOR_MINT_TIMEOUT_MS: "0". Must be a positive integer.');
  });
});
