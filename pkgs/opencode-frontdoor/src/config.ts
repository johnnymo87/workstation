export interface Config {
  port: number;
  pigeonUrl: string;
  anchorUrl: string;
  pigeonAuthToken?: string;
  routeTimeoutMs: number;
  cheapFirstByteMs: number;
  stickyTtlMs: number;
  driftCheckMs: number; // owner-drift re-resolve interval (mirrors the deployed TUI's 5s)
}

function parsePositiveInteger(envName: string, value: string | undefined, defaultValue: number): number {
  if (value === undefined) {
    return defaultValue;
  }
  // Ensure it's a non-empty string of digits
  if (!/^\d+$/.test(value)) {
    throw new Error(`Invalid ${envName}: "${value}". Must be a positive integer.`);
  }
  const parsed = parseInt(value, 10);
  if (parsed <= 0) {
    throw new Error(`Invalid ${envName}: "${value}". Must be a positive integer.`);
  }
  return parsed;
}

export function loadConfig(): Config {
  const port = parsePositiveInteger('FRONTDOOR_PORT', process.env.FRONTDOOR_PORT, 4700);
  // Fail fast at the config boundary with a clear message rather than letting
  // an out-of-range port surface later as an opaque ERR_SOCKET_BAD_PORT from
  // server.listen().
  if (port > 65535) {
    throw new Error(`Invalid FRONTDOOR_PORT: "${port}". Must be a valid TCP port (1-65535).`);
  }
  const routeTimeoutMs = parsePositiveInteger('FRONTDOOR_ROUTE_TIMEOUT_MS', process.env.FRONTDOOR_ROUTE_TIMEOUT_MS, 3000);
  const cheapFirstByteMs = parsePositiveInteger('FRONTDOOR_CHEAP_FIRST_BYTE_MS', process.env.FRONTDOOR_CHEAP_FIRST_BYTE_MS, 5000);
  const stickyTtlMs = parsePositiveInteger('FRONTDOOR_STICKY_TTL_MS', process.env.FRONTDOOR_STICKY_TTL_MS, 30000);
  const driftCheckMs = parsePositiveInteger('FRONTDOOR_DRIFT_CHECK_MS', process.env.FRONTDOOR_DRIFT_CHECK_MS, 5000);

  const pigeonUrl = process.env.PIGEON_DAEMON_URL || 'http://127.0.0.1:4731';
  const anchorUrl = process.env.OPENCODE_ANCHOR_URL || 'http://127.0.0.1:4096';
  const pigeonAuthToken = process.env.PIGEON_DAEMON_AUTH_TOKEN || undefined;

  return {
    port,
    pigeonUrl,
    anchorUrl,
    pigeonAuthToken,
    routeTimeoutMs,
    cheapFirstByteMs,
    stickyTtlMs,
    driftCheckMs,
  };
}
