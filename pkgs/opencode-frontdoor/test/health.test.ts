import { describe, test, expect, vi } from 'vitest';
import { probeServeHealth } from '../src/health.js';
import type { Config } from '../src/config.js';

describe('probeServeHealth', () => {
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

  test('returns true for 200 response', async () => {
    const fakeFetch = vi.fn().mockResolvedValue({
      ok: true,
      status: 200,
    });

    const result = await probeServeHealth('http://127.0.0.1:4096/', dummyConfig, { fetch: fakeFetch });
    expect(result).toBe(true);

    expect(fakeFetch).toHaveBeenCalledTimes(1);
    const [url] = fakeFetch.mock.calls[0] as [string];
    expect(url).toBe('http://127.0.0.1:4096/global/health'); // Trailing slash stripped and /global/health appended
  });

  test('returns false for 500 response', async () => {
    const fakeFetch = vi.fn().mockResolvedValue({
      ok: true,
      status: 500,
    });

    const result = await probeServeHealth('http://127.0.0.1:4096', dummyConfig, { fetch: fakeFetch });
    expect(result).toBe(false);
  });

  test('returns false for 404 response', async () => {
    const fakeFetch = vi.fn().mockResolvedValue({
      ok: true,
      status: 404,
    });

    const result = await probeServeHealth('http://127.0.0.1:4096', dummyConfig, { fetch: fakeFetch });
    expect(result).toBe(false);
  });

  test('returns false when fetch rejects with network or timeout error', async () => {
    const fakeFetch = vi.fn().mockRejectedValue(new Error('timeout'));

    const result = await probeServeHealth('http://127.0.0.1:4096', dummyConfig, { fetch: fakeFetch });
    expect(result).toBe(false);
  });
});
