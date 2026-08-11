/**
 * Query-string parameters whose VALUES may be written to the log.
 *
 * Default-deny: anything not listed here is logged as `name=<elided>`, so the
 * key is still visible for forensics but the value never lands on disk. A new
 * parameter added upstream is elided automatically rather than leaking by
 * omission.
 *
 * `auth_token` is deliberately absent. Note it cannot be assumed pre-stripped:
 * buildForwardSearch only removes it when a serve credential is configured
 * (proxy.ts), and the door currently runs WITHOUT one -- so a client-supplied
 * auth_token reaches this log path intact. Redaction here must not depend on
 * that config.
 *
 * The listed values are local filesystem paths and small scalars already
 * present elsewhere in this log or in session metadata, and their cardinality
 * is bounded by the number of open project directories.
 */
export const QUERY_VALUE_ALLOWLIST: ReadonlySet<string> = new Set([
  "directory",
  "location[directory]",
  "workspace",
  "path",
  "limit",
  "start",
]);

/**
 * Render a query string for logging, eliding every non-allowlisted value.
 *
 * Exists because `logResponse` logged only `url.pathname`, so the door's own
 * log could not distinguish `/config` from `/config?directory=<x>`. That gap
 * actively misled an investigation: a query for '?' across 2283 global-ro rows
 * returned zero, which was read as "clients send no query strings" when it was
 * guaranteed by the field's definition. A real client sends `?directory=` on
 * every request. See workstation-eon4.
 */
export function redactQuery(search: string | undefined): string | undefined {
  if (!search) return undefined;
  const raw = search.startsWith("?") ? search.slice(1) : search;
  if (!raw) return undefined;
  const parts: string[] = [];
  for (const [k, v] of new URLSearchParams(raw)) {
    parts.push(QUERY_VALUE_ALLOWLIST.has(k) ? `${k}=${v}` : `${k}=<elided>`);
  }
  return parts.length ? parts.join("&") : undefined;
}

export interface RequestLogEntry {
  class: string;
  sid: string | null;
  target: string;
  prospective: boolean;
  degraded: boolean;
  status: number;
  durationMs: number;
  method?: string;
  path?: string;
  /** Redacted query string; see redactQuery. Absent when there was no query. */
  query?: string;
  action?: string;
  /** sq1v: the owner was resolved via an ancestor's route (child/subagent session). */
  viaParent?: boolean;
  /** sq1v: the sid pigeon lease ops used (the root). Differs from `sid` for children. */
  routingSid?: string | null;
}

export interface MetricsSnapshot {
  degradedToAnchor: number;
  totalRequests: number;
}

/**
 * Route classes whose plain 200 GETs are eligible for sampling.
 *
 * Deliberately an ALLOWLIST. A denylist would silently start sampling any route
 * class added upstream later, which is how a new class of interesting traffic
 * would go quiet without anyone editing this file. Measured (6h, workstation-9f7a):
 * session-path 96,129 and global-ro 3,449 requests, against 99 + 46 + 37 for
 * every other class combined -- so these two ARE the volume, and nothing is
 * gained by sampling the rest.
 */
export const SAMPLEABLE_CLASSES: ReadonlySet<string> = new Set([
  "session-path",
  "global-ro",
]);

export const DEFAULT_LOG_SAMPLE_N = 50;
export const DEFAULT_LOG_SUMMARY_INTERVAL_MS = 300_000;

export interface LoggerDeps {
  sink?: (line: string) => void;
  now?: () => number;
  /**
   * Log 1 in every N otherwise-uninteresting requests. 1 disables sampling
   * entirely, which is the mid-incident escape hatch (FRONTDOOR_LOG_SAMPLE_N=1
   * plus a restart, no rebuild).
   */
  sampleN?: number;
  /** How often the aggregate summary line is emitted. */
  summaryIntervalMs?: number;
}

interface Window {
  startedAt: number;
  total: number;
  emitted: number;
  degraded: number;
  byStatus: Map<number, number>;
}

export class RequestLogger {
  private sink: (line: string) => void;
  private now: () => number;
  private sampleN: number;
  private summaryIntervalMs: number;
  private degradedToAnchor = 0;
  private totalRequests = 0;
  /**
   * Counts only SAMPLEABLE requests. Always-logged requests (errors, mutations,
   * degradations) must not advance it, or a burst of 404s would shift which plain
   * GETs get kept and make the 1-in-N stride depend on unrelated traffic.
   */
  private sampleableSeen = 0;
  private window: Window;

  constructor(deps?: LoggerDeps) {
    this.sink = deps?.sink ?? console.log;
    this.now = deps?.now ?? Date.now;
    this.sampleN = deps?.sampleN ?? DEFAULT_LOG_SAMPLE_N;
    this.summaryIntervalMs = deps?.summaryIntervalMs ?? DEFAULT_LOG_SUMMARY_INTERVAL_MS;
    this.window = this.newWindow(this.now());
  }

  private newWindow(startedAt: number): Window {
    return { startedAt, total: 0, emitted: 0, degraded: 0, byStatus: new Map() };
  }

  /**
   * True for everything except the one case measured to be 90.2% of the volume:
   * a successful, non-degraded GET on a high-traffic read class.
   *
   * Every predicate here fails TOWARDS logging -- an absent method, an unknown
   * class, any non-200 status. A sampler that drops evidence is worse than the
   * disk pressure it was written to relieve.
   */
  private mustLog(entry: RequestLogEntry): boolean {
    return (
      entry.status !== 200 ||
      entry.degraded === true ||
      entry.method !== "GET" ||
      !SAMPLEABLE_CLASSES.has(entry.class)
    );
  }

  private flushSummaryIfDue(at: number): void {
    const elapsed = at - this.window.startedAt;
    if (elapsed < this.summaryIntervalMs) return;
    if (this.window.total > 0) {
      const byStatus: Record<string, number> = {};
      for (const [status, count] of this.window.byStatus) byStatus[String(status)] = count;
      // Aggregates only. No sid, path, query or target may appear here: the summary
      // is emitted on a schedule rather than per-request, so anything leaked into it
      // would be leaked without the per-request allowlist above having any say.
      this.sink(
        JSON.stringify({
          ts: new Date(at).toISOString(),
          type: "request_summary",
          // The TRUE elapsed window, not the nominal interval. The summary is
          // flushed lazily by the next request, so after an idle gap the window is
          // longer than the interval, and a nominal value would misstate the rate.
          windowMs: elapsed,
          total: this.window.total,
          emitted: this.window.emitted,
          suppressed: this.window.total - this.window.emitted,
          degraded: this.window.degraded,
          byStatus,
        }),
      );
    }
    this.window = this.newWindow(at);
  }

  log(entry: RequestLogEntry): void {
    const at = this.now();
    this.flushSummaryIfDue(at);

    // Accounting happens for EVERY request, before and independently of the
    // decision to emit a line. Sampling is a logging decision, never a
    // measurement one: snapshot() and the summary must both still see the
    // requests that were sampled away.
    this.totalRequests++;
    this.window.total++;
    this.window.byStatus.set(entry.status, (this.window.byStatus.get(entry.status) ?? 0) + 1);
    if (entry.degraded === true) {
      this.degradedToAnchor++;
      this.window.degraded++;
    }

    if (!this.mustLog(entry)) {
      const nth = this.sampleableSeen++;
      // `sampleN <= 1` means "log everything", and also fences off a modulo by
      // zero, which would evaluate to NaN and silently suppress EVERY sampleable
      // request -- a config typo turning into total blindness.
      if (this.sampleN > 1 && nth % this.sampleN !== 0) return;
    }
    this.window.emitted++;

    // SECURITY NOTE: NEVER log secrets. Do not include pigeon auth tokens,
    // Authorization headers, or any sensitive credentials in the logged entry.
    // The entry schema is designed strictly to avoid capturing any request
    // headers or request bodies that might contain credentials.
    const ts = new Date(this.now()).toISOString();
    // Explicitly enumerate the fields rather than spreading `...entry`: this is
    // a hard allowlist so that a caller who (accidentally) passes an
    // over-shaped object cast as `any` cannot leak extra properties
    // (e.g. Authorization headers, tokens, cookies) into the log line.
    // JSON.stringify drops `undefined`, so absent optionals are omitted cleanly.
    const logLine = JSON.stringify({
      ts,
      type: "request",
      class: entry.class,
      sid: entry.sid,
      target: entry.target,
      prospective: entry.prospective,
      degraded: entry.degraded,
      status: entry.status,
      durationMs: entry.durationMs,
      method: entry.method,
      path: entry.path,
      query: entry.query,
      action: entry.action,
      viaParent: entry.viaParent,
      routingSid: entry.routingSid,
    });
    this.sink(logLine);
  }

  snapshot(): MetricsSnapshot {
    return {
      degradedToAnchor: this.degradedToAnchor,
      totalRequests: this.totalRequests,
    };
  }
}
