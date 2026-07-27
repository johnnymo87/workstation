export interface Config {
  port: number;
  /*
   * The version marker. Phase 6's Nix wrapper will inject the store path/hash here
   * so the canary can diff the running binary against the just-built store path.
   */
  version: string;
  pigeonUrl: string;
  anchorUrl: string;
  pigeonAuthToken?: string;
  serveAuthHeader?: string;
  routeTimeoutMs: number;
  cheapFirstByteMs: number;
  /*
   * INVARIANT (LOW-2): stickyTtlMs <= pigeon PIGEON_LEASE_TTL_MS (both default 30s).
   * HIGH-2 renewal at 1/2 TTL re-places a sticky-pinned session in pigeon.
   *
   * CORRECTION (2026-07-25, sq1v T5): this comment used to claim the renewal "keeps
   * the lease alive so the session never outlives its active lease". That is FALSE.
   * `POST /place` is pigeon's `ensureRouted` = `resolveRoute ?? placeSession`, which
   * returns a still-valid lease UNCHANGED — it never extends one. The only renewer,
   * `touch()`/`renewCAS`, has no HTTP route and no callers. So a lease lapses at its
   * TTL and is only re-created by the NEXT renewal tick, and renewal only fires on
   * MUTATING sticky hits — so a long turn (one POST, then minutes of SSE/GETs) holds
   * no lease for most of its duration. That matters because the lease is what stops
   * `reassignFromDeadServe` migrating a heartbeat-stale (CPU-blocked) owner mid-run.
   * Tracked for the pigeon side; the door cannot fix it alone.
   */
  stickyTtlMs: number;
  driftCheckMs: number; // owner-drift re-resolve interval (mirrors the deployed TUI's 5s)
  wedgeProbeIntervalMs: number;
  mintTimeoutMs: number;
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
  const wedgeProbeIntervalMs = parsePositiveInteger('FRONTDOOR_WEDGE_PROBE_INTERVAL_MS', process.env.FRONTDOOR_WEDGE_PROBE_INTERVAL_MS, 5000);
  const mintTimeoutMs = parsePositiveInteger('FRONTDOOR_MINT_TIMEOUT_MS', process.env.FRONTDOOR_MINT_TIMEOUT_MS, 60000);

  const pigeonUrl = process.env.PIGEON_DAEMON_URL || 'http://127.0.0.1:4731';
  const anchorUrl = process.env.OPENCODE_ANCHOR_URL || 'http://127.0.0.1:4096';
  const pigeonAuthToken = process.env.PIGEON_DAEMON_AUTH_TOKEN || undefined;
  const version = process.env.FRONTDOOR_VERSION || 'unknown';

  const serverPassword = process.env.OPENCODE_SERVER_PASSWORD;
  let serveAuthHeader: string | undefined = undefined;
  if (serverPassword) {
    const serverUsername = process.env.OPENCODE_SERVER_USERNAME || 'opencode';
    const credentials = Buffer.from(`${serverUsername}:${serverPassword}`).toString('base64');
    serveAuthHeader = `Basic ${credentials}`;
  }

  return {
    port,
    version,
    pigeonUrl,
    anchorUrl,
    pigeonAuthToken,
    serveAuthHeader,
    routeTimeoutMs,
    cheapFirstByteMs,
    stickyTtlMs,
    driftCheckMs,
    wedgeProbeIntervalMs,
    mintTimeoutMs,
  };
}
