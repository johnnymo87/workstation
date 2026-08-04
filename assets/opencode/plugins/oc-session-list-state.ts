import { Database } from "bun:sqlite";
import { existsSync, readdirSync, readFileSync, unlinkSync } from "node:fs";
import { join } from "node:path";
import type { SessionRow } from "./oc-session-list-base.js";
import { mergeOverlays, prepareFiles, type PreparedFile } from "./session-state-merge.js";
import type { OverlayData } from "./session-state-impl.js";

export interface SessionWithStateRow extends SessionRow {
  /**
   * `nodata` is a TRIPWIRE, not a status. It means no live writer was in a
   * position to report on this session, so `idle` would have been a claim the
   * reader cannot support. Consumers MUST render it at least as loudly as
   * `idle` -- folding it into a `default:` branch that draws a blank cell would
   * make this quieter than the bug it exists to catch.
   *
   * Distinct from `unknown` on a different axis: `unknown` is stale data from a
   * dead source (activity still carries a last-known value), `nodata` is the
   * absence of any source. They are mutually exclusive by construction.
   */
  activity: "working" | "idle" | "retry" | "nodata";
  error: boolean;
  pendingPermissions: string[];
  pendingQuestions: string[];
  retry?: { attempt: number; next: number };
  lastActivity: number;
  updatedAt: number;
  unknown?: boolean;
}

export interface QueryWithStateOptions {
  overlayDir?: string;
  routingDbPath?: string;
  now?: number;
  staleMs?: number;
  isAlive?: (pid: number) => boolean;
  owners?: Record<string, string>;
  /** Reports degraded-ownership paths; see buildOwnersMap. Default: silent. */
  onWarn?: (msg: string) => void;
  /**
   * Resolve overlay-reported sessions that fell outside the base list's recency
   * window, returning each one's FULL root tree with archived rows excluded.
   * Omitted => no union (the pre-S6 behaviour). See the union block below.
   */
  unionLookup?: (sessionIds: string[]) => SessionRow[];
}

/**
 * Build `owners[sid] = desired_serve_id_of(root_of(sid))` from pigeon's
 * session_assignment table.
 *
 * LOUDNESS IS LOAD-BEARING. mergeOverlays defaults `owners` to {}, and with an
 * empty map its Rule 1 (a live owner wins outright) never fires, so every
 * session silently falls back to bare wall-clock ordering. ~53% of sessions
 * here are children that depend on the root-keyed join, so a silent empty map
 * is a large, invisible correctness regression -- the same "quiet wrongness"
 * class as a writer whose overlay is simply absent. Every degraded path
 * therefore reports through `onWarn` instead of returning {} in silence.
 */
export function buildOwnersMap(
  routingDbPath: string,
  baseRows: SessionRow[],
  onWarn?: (msg: string) => void,
): Record<string, string> {
  const owners: Record<string, string> = {};
  if (!routingDbPath || !existsSync(routingDbPath)) {
    onWarn?.(
      `routing db not found at ${routingDbPath || "<unset>"} -- ownership unavailable, ` +
        `falling back to wall-clock ordering (set --routing-db or OPENCODE_ROUTING_DB)`,
    );
    return owners;
  }
  try {
    const db = new Database(routingDbPath, { readonly: true });
    const tableExists = db.query(`SELECT 1 FROM sqlite_master WHERE type='table' AND name='session_assignment'`).get();
    if (!tableExists) {
      db.close();
      onWarn?.(
        `routing db ${routingDbPath} has no session_assignment table -- ownership ` +
          `unavailable, falling back to wall-clock ordering`,
      );
      return owners;
    }
    const assignments = db.query<{ session_id: string; desired_serve_id: string }, []>(
      `SELECT session_id, desired_serve_id FROM session_assignment`
    ).all();
    db.close();

    const assignmentMap = new Map<string, string>();
    for (const a of assignments) {
      if (a.session_id && a.desired_serve_id) {
        assignmentMap.set(a.session_id, a.desired_serve_id);
      }
    }

    for (const row of baseRows) {
      // ROOT-KEYED ONLY, deliberately. Pigeon places by the root of the session
      // tree, so this is the plan's stated rule (owners[sid] = owner_of(root)).
      //
      // There is NO fallback to `assignmentMap.get(row.id)`. For a root row it
      // would be redundant (root_id === id), so it could only ever fire for a
      // CHILD carrying its own assignment row -- of which ~2 exist out of 4,668
      // children, i.e. anomalies, most likely stale. The downside is real: a
      // stale child row names the wrong serve as owner, and if that serve is
      // live with a file for the child's directory but no entry for it, merge
      // Rule 1's "absence is authoritative" pins the session to idle and
      // suppresses the true serve's working/blocked. Redundant upside, real
      // downside -- so the join stays root-only.
      const serveId = assignmentMap.get(row.root_id);
      if (serveId) {
        owners[row.id] = serveId;
      }
    }
  } catch (err) {
    onWarn?.(
      `failed to read ownership from ${routingDbPath} (${String(err)}) -- ` +
        `falling back to wall-clock ordering`,
    );
  }
  if (baseRows.length > 0 && Object.keys(owners).length === 0) {
    onWarn?.(
      `no ownership rows matched any of the ${baseRows.length} session(s) -- ` +
        `ordering is wall-clock only; check that session_assignment is populated`,
    );
  }
  return owners;
}

export function loadOverlayFiles(
  overlayDir: string,
  onWarn?: (msg: string) => void,
): OverlayData[] {
  const files: OverlayData[] = [];
  if (!overlayDir || !existsSync(overlayDir)) {
    // A typo'd or absent overlay dir otherwise yields confidently all-idle
    // output -- the same "absent overlay is indistinguishable from no sessions"
    // failure this reader exists to surface.
    onWarn?.(
      `overlay dir not found at ${overlayDir || "<unset>"} -- no live state available, ` +
        `every session will report idle`,
    );
    return files;
  }
  try {
    const entries = readdirSync(overlayDir);
    for (const entry of entries) {
      if (!entry.endsWith(".json")) continue;
      const fullPath = join(overlayDir, entry);
      try {
        const content = readFileSync(fullPath, "utf-8");
        const parsed = JSON.parse(content);
        if (parsed && typeof parsed === "object") {
          files.push(parsed);
        }
      } catch {
        // Tolerate unparseable or partial files
      }
    }
  } catch (err) {
    onWarn?.(`failed to read overlay dir ${overlayDir} (${String(err)}) -- reporting all idle`);
  }
  if (files.length === 0) {
    onWarn?.(`no overlay files loaded from ${overlayDir} -- every session will report idle`);
  }
  return files;
}

export function runOrphanGc(
  overlayDir: string,
  options?: { now?: number; isAlive?: (pid: number) => boolean }
): string[] {
  const unlinked: string[] = [];
  if (!overlayDir || !existsSync(overlayDir)) {
    return unlinked;
  }
  const now = options?.now ?? Date.now();
  const isAlive = options?.isAlive ?? ((pid: number) => {
    try {
      process.kill(pid, 0);
      return true;
    } catch (err: any) {
      // EPERM means the process EXISTS but belongs to another user -- alive.
      // Treating it as dead would make a live writer's overlay GC-eligible.
      return err?.code === "EPERM";
    }
  });

  try {
    const entries = readdirSync(overlayDir);
    for (const entry of entries) {
      if (!entry.endsWith(".json")) continue;
      const fullPath = join(overlayDir, entry);
      let content: string;
      try {
        content = readFileSync(fullPath, "utf-8");
      } catch {
        continue;
      }

      let parsed: any;
      try {
        parsed = JSON.parse(content);
      } catch {
        // REQUIREMENT: Never unlink a file you failed to parse (a torn write from a LIVE writer must not be collected)
        continue;
      }

      if (!parsed || typeof parsed !== "object") continue;
      const pid = parsed.pid;
      const heartbeat = parsed.heartbeat;

      if (typeof pid !== "number" || typeof heartbeat !== "number") continue;

      // REQUIREMENT: Never unlink a file whose pid is alive, regardless of heartbeat age
      if (isAlive(pid)) continue;

      // BOTH dead-pid AND heartbeat older than 10 minutes (600,000 ms)
      const ageMs = now - heartbeat;
      if (ageMs > 10 * 60 * 1000) {
        try {
          unlinkSync(fullPath);
          unlinked.push(fullPath);
        } catch {
          // Ignore unlink errors
        }
      }
    }
  } catch {
    // Ignore directory read errors
  }

  return unlinked;
}

/**
 * Session ids that a LIVE writer currently reports as needing attention.
 *
 * Live files only, deliberately. A stale file's entries merge as `unknown`
 * (session-state-merge.ts:210-216) -- last-known state from a dead source, which
 * is not evidence that anything is happening now. Unioning those in would let a
 * fleet-wide un-deploy, whose orphaned overlays age out but are never collected
 * while the serves keep running, drag an unbounded pile of dead sessions into
 * the picker.
 *
 * `idle` is likewise excluded: the whole point of the union is rows that demand
 * action, and merge already prunes plain idle entries anyway.
 *
 * KNOWN COST of the live-only rule: a session blocked on a serve that is alive
 * but WEDGED (heartbeat stops, pid does not -- the documented "alive but frozen"
 * mode) goes stale after staleMs, merges as `unknown`, and is therefore not a
 * union candidate. Inside the recency window it still renders, as `unknown`;
 * outside it, it is absent. Accepted: stale state is not evidence about now, and
 * the serve canary restarts wedged serves. Revisit if that stops being true.
 */
export function attentionCandidates(prepared: PreparedFile[]): string[] {
  const out = new Set<string>();
  for (const pf of prepared) {
    if (!pf.live) continue;
    for (const [sid, entry] of Object.entries(pf.file.sessions ?? {})) {
      const e = entry as any;
      if (!e) continue;
      const needsAttention =
        e.error === true ||
        (Array.isArray(e.pendingPermissions) && e.pendingPermissions.length > 0) ||
        (Array.isArray(e.pendingQuestions) && e.pendingQuestions.length > 0) ||
        e.activity === "working" ||
        e.activity === "retry";
      if (needsAttention) out.add(sid);
    }
  }
  return [...out].sort();
}

export function queryWithState(
  baseRowsIn: SessionRow[],
  options: QueryWithStateOptions = {}
): SessionWithStateRow[] {
  let baseRows = baseRowsIn;
  const now = options.now ?? Date.now();
  const staleMs = options.staleMs ?? 45000;
  const isAlive = options.isAlive ?? ((pid: number) => {
    try {
      process.kill(pid, 0);
      return true;
    } catch (err: any) {
      // EPERM means the process EXISTS but belongs to another user -- alive.
      // Treating it as dead would make a live writer's overlay GC-eligible.
      return err?.code === "EPERM";
    }
  });

  // Overlays are read ONCE, before anything else needs them. Reading them again
  // for the union below would open a window in which orphan GC ran between the
  // two reads, leaving the candidate set and the merge disagreeing about which
  // files exist.
  const overlayFiles = loadOverlayFiles(options.overlayDir ?? "", options.onWarn);
  const preparedFiles = prepareFiles(overlayFiles, { now, staleMs, isAlive });

  // OVERLAY-TRUTH UNION. The base list is capped by a recency LIMIT over root
  // trees, so a session that a live writer says is blocked or working can fall
  // outside the window and vanish from the picker -- the one place the list is
  // WORSE than useless, because the row it drops is the row the user is being
  // asked to act on.
  //
  // This must inject at the baseRows level, BEFORE ownership is resolved. Bolting
  // the extra rows on afterwards would give them no owner, no nodata predicate and
  // no warning coverage -- the quiet-wrongness class documented in buildOwnersMap.
  //
  // The lookup is the caller's job (it owns the DB handle) and is expected to
  // return each candidate's FULL root tree, archived rows excluded. Bounded by
  // construction: only LIVE files contribute candidates, so an un-deploy that
  // leaves stale overlays behind cannot flood the list.
  if (options.unionLookup) {
    const known = new Set(baseRows.map((r) => r.id));
    let candidates = attentionCandidates(preparedFiles).filter((sid) => !known.has(sid));
    // Bounded, and LOUDLY so. This repo's rule is that every degraded path
    // reports (see buildOwnersMap): a cap that silently drops candidate 201 goes
    // quiet in exactly the runaway-writer scenario it exists to contain.
    const UNION_CAP = 200;
    if (candidates.length > UNION_CAP) {
      options.onWarn?.(
        `${candidates.length} sessions outside the recency window need attention, ` +
          `which exceeds the union cap of ${UNION_CAP} -- ${candidates.length - UNION_CAP} ` +
          `are omitted from this list`,
      );
      candidates = candidates.slice(0, UNION_CAP);
    }
    if (candidates.length > 0) {
      let extra: SessionRow[] = [];
      try {
        extra = options.unionLookup(candidates) ?? [];
      } catch (err) {
        options.onWarn?.(
          `failed to resolve ${candidates.length} overlay-reported session(s) not in the ` +
            `recency window (${String(err)}) -- they are missing from this list`,
        );
      }
      const added: SessionRow[] = [];
      for (const row of extra) {
        if (!known.has(row.id)) {
          known.add(row.id);
          added.push(row);
        }
      }
      if (added.length > 0) {
        baseRows = [...baseRows, ...added];
      }
    }
  }

  // Call buildOwnersMap even when routingDbPath is "" (HOME unset and no env):
  // it warns on <unset>, whereas skipping it was the one degraded path that
  // stayed silent.
  const owners = options.owners ?? buildOwnersMap(options.routingDbPath ?? "", baseRows, options.onWarn);
  const mergedStateMap = mergeOverlays(overlayFiles, {
    now, staleMs, isAlive, owners, prepared: preparedFiles,
  });

  // Who is still REPORTING? Two granularities, because neither alone is right.
  //
  // SERVE-LEVEL catches a dead writer but is blind to per-INSTANCE blindness:
  // opencode binds plugins at instance creation, so instances that predate a
  // plugin deploy never write for the life of the serve while newer instances on
  // the SAME serve write normally (issue #234 / S0). Such a serve looks healthy.
  //
  // DIRECTORY-LEVEL catches that, but fires on 62% of real rows on a healthy
  // fleet, because instance eviction leaves dormant sessions with no file
  // forever. A tripwire that fires on the majority of rows is one nobody reads.
  //
  // So: directory-level for RECENTLY ACTIVE rows (a row touched within FRESH_MS
  // had an instance loaded that recently, so a missing file means "not watching",
  // not "evicted"), serve-level for dormant ones. Measured false-alarm rate of
  // the hybrid against the live fleet: 1m/5m/15m/60m all 0.00%, 240m 0.27%.
  const liveFiles = preparedFiles.filter((pf) => pf.live);
  const reportingServes = new Set(liveFiles.map((pf) => pf.serveId));
  const reportingPairs = new Set(
    liveFiles.filter((pf) => pf.file.directory !== undefined)
      .map((pf) => `${pf.serveId}\u0000${pf.file.directory}`),
  );
  // A live file with no `directory` (an older writer) covers ANY directory.
  // Treating it as matching nothing would flood one serve's every recent row
  // with false nodata, and a tripwire dies of distrust faster than of silence.
  const wildcardServes = new Set(
    liveFiles.filter((pf) => pf.file.directory === undefined).map((pf) => pf.serveId),
  );
  const fleetIsReporting = reportingServes.size > 0;
  const FRESH_MS = 15 * 60 * 1000;

  // Seam for Task 5: nvim-socket discovery join will annotate attached location here.

  let nodataCount = 0;
  const rows = baseRows.map((row): SessionWithStateRow => {
    const st = mergedStateMap[row.id];
    if (st) {
      return {
        ...row,
        activity: st.activity,
        error: st.error,
        pendingPermissions: st.pendingPermissions ?? [],
        pendingQuestions: st.pendingQuestions ?? [],
        lastActivity: st.lastActivity,
        updatedAt: st.updatedAt,
        ...(st.retry ? { retry: st.retry } : {}),
        ...(st.unknown ? { unknown: st.unknown } : {}),
      };
    } else {
      // No merged state. That is NOT automatically idle -- it is only idle if
      // somebody was actually watching. An owned session trusts its owning
      // serve; an unowned one (66.5% of real rows have no session_assignment
      // row) falls back to fleet-wide writer health rather than flooding, since
      // a missing routing db already warns three separate ways in buildOwnersMap.
      const ownerServeId = owners[row.id];
      let hasReporter: boolean;
      if (!ownerServeId) {
        hasReporter = fleetIsReporting;
      } else if (!reportingServes.has(ownerServeId)) {
        hasReporter = false;
      } else if (now - row.time_updated <= FRESH_MS) {
        hasReporter =
          reportingPairs.has(`${ownerServeId}\u0000${row.directory}`) ||
          wildcardServes.has(ownerServeId);
      } else {
        hasReporter = true;
      }
      if (!hasReporter) nodataCount++;
      return {
        ...row,
        activity: hasReporter ? "idle" : "nodata",
        error: false,
        pendingPermissions: [],
        pendingQuestions: [],
        // Preserved even for nodata so anything sorting by recency stays stable.
        lastActivity: row.time_updated,
        updatedAt: row.time_updated,
      };
    }
  });

  // Per-row nodata catches a partial outage. These aggregates catch an outage
  // even for a consumer that ignores the field entirely -- the 2026-08-01
  // failure, where 886 rows of confident idle went unremarked for ~9 hours.
  //
  // The trigger is "no live writer", NOT "every row is nodata". An un-deploy
  // removes the plugin, not the overlay files: the serves keep running, so orphan
  // GC (which requires a dead pid) never collects them and their heartbeats
  // merely age out. Sessions named in those stale files merge as `unknown`
  // rather than nodata, so a nodataCount === baseRows.length trigger would have
  // stayed SILENT through exactly the outage it was written for.
  if (baseRows.length > 0 && !fleetIsReporting) {
    options.onWarn?.(
      `no live writer is reporting for any of the ${baseRows.length} session(s) -- ` +
        `the writer fleet may be down; state below is not trustworthy`,
    );
  } else if (baseRows.length > 0) {
    // Partial outage: name the serves that own sessions but emit nothing, so the
    // signal is attributable without flooding rows.
    const expected = new Set<string>();
    for (const row of baseRows) {
      const o = owners[row.id];
      if (o) expected.add(o);
    }
    const silent = [...expected].filter((s) => !reportingServes.has(s)).sort();
    if (silent.length > 0) {
      options.onWarn?.(
        `${silent.join(", ")} own session(s) but are not writing any live state -- ` +
          `their writers may be down (${nodataCount} row(s) reported nodata)`,
      );
    }
  }

  return rows;
}
