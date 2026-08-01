import { Database } from "bun:sqlite";
import { existsSync, readdirSync, readFileSync, unlinkSync } from "node:fs";
import { join } from "node:path";
import type { SessionRow } from "./oc-session-list-base.js";
import { mergeOverlays } from "./session-state-merge.js";
import type { OverlayData } from "./session-state-impl.js";

export interface SessionWithStateRow extends SessionRow {
  activity: "working" | "idle" | "retry";
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

export function queryWithState(
  baseRows: SessionRow[],
  options: QueryWithStateOptions = {}
): SessionWithStateRow[] {
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

  // Call buildOwnersMap even when routingDbPath is "" (HOME unset and no env):
  // it warns on <unset>, whereas skipping it was the one degraded path that
  // stayed silent.
  const owners = options.owners ?? buildOwnersMap(options.routingDbPath ?? "", baseRows, options.onWarn);

  const overlayFiles = loadOverlayFiles(options.overlayDir ?? "", options.onWarn);
  const mergedStateMap = mergeOverlays(overlayFiles, { now, staleMs, isAlive, owners });

  // Seam for Task 5: nvim-socket discovery join will annotate attached location here.

  return baseRows.map((row) => {
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
      return {
        ...row,
        activity: "idle",
        error: false,
        pendingPermissions: [],
        pendingQuestions: [],
        lastActivity: row.time_updated,
        updatedAt: row.time_updated,
      };
    }
  });
}
