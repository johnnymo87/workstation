import { describe, test, expect, beforeEach, afterEach } from 'vitest';
import { loadConfig } from '../src/config.js';

describe('loadConfig', () => {
  let originalEnv: NodeJS.ProcessEnv;

  beforeEach(() => {
    // Backup process.env to ensure isolation between tests
    originalEnv = { ...process.env };

    // Clear relevant environment variables so we start with defaults
    delete process.env.FRONTDOOR_PORT;
    delete process.env.PIGEON_DAEMON_URL;
    delete process.env.OPENCODE_ANCHOR_URL;
    delete process.env.PIGEON_DAEMON_AUTH_TOKEN;
    delete process.env.FRONTDOOR_ROUTE_TIMEOUT_MS;
    delete process.env.FRONTDOOR_CHEAP_FIRST_BYTE_MS;
    delete process.env.FRONTDOOR_STICKY_TTL_MS;
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
      pigeonUrl: 'http://127.0.0.1:4731',
      anchorUrl: 'http://127.0.0.1:4096',
      pigeonAuthToken: undefined,
      routeTimeoutMs: 3000,
      cheapFirstByteMs: 5000,
      stickyTtlMs: 30000,
    });
  });

  test('should override default values with valid environment variables', () => {
    process.env.FRONTDOOR_PORT = '4800';
    process.env.PIGEON_DAEMON_URL = 'http://10.0.0.1:4731';
    process.env.OPENCODE_ANCHOR_URL = 'http://10.0.0.1:4096';
    process.env.PIGEON_DAEMON_AUTH_TOKEN = 'secret-token';
    process.env.FRONTDOOR_ROUTE_TIMEOUT_MS = '1500';
    process.env.FRONTDOOR_CHEAP_FIRST_BYTE_MS = '2500';
    process.env.FRONTDOOR_STICKY_TTL_MS = '10000';

    const config = loadConfig();

    expect(config).toEqual({
      port: 4800,
      pigeonUrl: 'http://10.0.0.1:4731',
      anchorUrl: 'http://10.0.0.1:4096',
      pigeonAuthToken: 'secret-token',
      routeTimeoutMs: 1500,
      cheapFirstByteMs: 2500,
      stickyTtlMs: 10000,
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
});
