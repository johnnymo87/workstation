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
}

export function buildOwnersMap(routingDbPath: string, baseRows: SessionRow[]): Record<string, string> {
  const owners: Record<string, string> = {};
  if (!routingDbPath || !existsSync(routingDbPath)) {
    return owners;
  }
  try {
    const db = new Database(routingDbPath, { readonly: true });
    const tableExists = db.query(`SELECT 1 FROM sqlite_master WHERE type='table' AND name='session_assignment'`).get();
    if (!tableExists) {
      db.close();
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
      const serveId = assignmentMap.get(row.root_id) ?? assignmentMap.get(row.id);
      if (serveId) {
        owners[row.id] = serveId;
      }
    }
  } catch {
    // Return empty map on error
  }
  return owners;
}

export function loadOverlayFiles(overlayDir: string): OverlayData[] {
  const files: OverlayData[] = [];
  if (!overlayDir || !existsSync(overlayDir)) {
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
  } catch {
    // Ignore readdir errors
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
    } catch {
      return false;
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
    } catch {
      return false;
    }
  });

  let owners = options.owners;
  if (!owners && options.routingDbPath) {
    owners = buildOwnersMap(options.routingDbPath, baseRows);
  }
  owners = owners ?? {};

  const overlayFiles = options.overlayDir ? loadOverlayFiles(options.overlayDir) : [];
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
