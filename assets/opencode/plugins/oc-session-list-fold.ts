import { statSync } from "node:fs";
import type { SessionWithStateRow } from "./oc-session-list-state.js";

/**
 * The row model for the session switcher (S6 / plan Task 8).
 *
 * Pure, apart from an injectable directory stat. Everything here is a function
 * of rows the caller already has -- no DB, no overlay files, no clock beyond an
 * injected `now`. The Lua side (session_switcher/model.lua) deliberately does
 * NOT recompute any of it; it annotates attachment and filters, nothing else.
 */

export type EffectiveState =
  | "error"
  | "blocked"
  | "retry"
  | "working"
  | "nodata"
  | "unknown"
  | "idle";

/**
 * Attention order, most urgent first. SEVERITY now governs the child-fold
 * worst-of aggregation and rendering, not the primary sort order (which is
 * two-group: attention set on top, then purely by recency).
 *
 * The "render nodata at least as loudly as idle" contract from
 * oc-session-list-state.ts is still honoured: (i) ordering now treats `nodata`
 * and `idle` symmetrically by recency rather than ranking one below the other,
 * (ii) `nodata` keeps its own distinct glyph, and (iii) a fleet-level warning
 * fires when nodata rows are present.
 *
 * A permanent ordering pin for `nodata` was rejected: a stale `nodata` row
 * pinned above every idle row forever is a chronic pin, which trains the eye
 * to ignore it. During an actual outage the affected sessions were recently
 * active, so their tree-max `lastActivity` is fresh and they float to the top
 * of the recency group on their own, exactly when it matters.
 */
const SEVERITY: Record<EffectiveState, number> = {
  error: 0,
  blocked: 1,
  retry: 2,
  working: 3,
  nodata: 4,
  unknown: 5,
  idle: 6,
};

export const IDLE_RANK = SEVERITY.idle;

export function severityOf(state: EffectiveState | null | undefined): number {
  if (state == null) return Number.POSITIVE_INFINITY;
  const rank = SEVERITY[state];
  return rank === undefined ? Number.POSITIVE_INFINITY : rank;
}

/**
 * Collapse a row's several independent state fields into the single value the
 * picker renders.
 *
 * PRECEDENCE, and why `unknown` comes first: an `unknown` row's state came from
 * a writer that is dead or stale, so every other field on it is last-known
 * rather than current. Claiming `error` or `working` from such a row asserts
 * something about the present that the data cannot support. Note the merge
 * already blanks pendingPermissions/pendingQuestions when it flags `unknown`
 * (session-state-merge.ts:210-216), so `unknown` vs `blocked` cannot actually
 * collide today; the ordering is stated anyway so a future writer change cannot
 * silently pick the answer for us.
 */
export function effectiveStateOf(row: SessionWithStateRow): EffectiveState {
  if (row.unknown) return "unknown";
  if (row.error) return "error";
  if ((row.pendingPermissions?.length ?? 0) > 0 || (row.pendingQuestions?.length ?? 0) > 0) {
    return "blocked";
  }
  if (row.activity === "retry") return "retry";
  if (row.activity === "working") return "working";
  if (row.activity === "nodata") return "nodata";
  return "idle";
}

export interface FoldedRow extends SessionWithStateRow {
  effective_state: EffectiveState;
  /**
   * The session's directory no longer exists. Kept as its own field rather than
   * folded into `effective_state` because it is a different question: the state
   * is still true (the session really is `working`), it simply can never make
   * progress. The picker renders it distinctly and Task 10 opens it read-only.
   */
  dir_missing: boolean;
  /** Worst-of over ALL descendants' effective_state; null when childless. */
  child_state: EffectiveState | null;
  child_count: number;
  /** Attention tier actually used for ordering; 0 is most urgent. */
  sort_rank: number;
  /**
   * Render-only boolean indicating whether the row belongs to the pinned
   * attention group (sort_rank <= SEVERITY.blocked).
   */
  attention: boolean;
}

export interface FoldOptions {
  /** Injection seam for tests. Default: real fs. */
  statDir?: (dir: string) => boolean;
}

/**
 * Fold a flat row list (roots AND descendants) into one row per root.
 *
 * ORDER OF OPERATIONS IS LOAD-BEARING. State is merged by the caller, then this
 * function derives effective_state and dir_missing PER ROW, and only then folds.
 * Folding first would leave children with no state to contribute, so
 * `child_state` would be null for every root and every negative test about
 * child folding would pass vacuously.
 */
export function foldRows(rows: SessionWithStateRow[], options: FoldOptions = {}): FoldedRow[] {
  const dirCache = new Map<string, boolean>();
  const statDir =
    options.statDir ??
    ((dir: string) => {
      try {
        return statSync(dir).isDirectory();
      } catch {
        return false;
      }
    });
  const dirExists = (dir: string): boolean => {
    if (!dir) return true; // no directory recorded: nothing to disprove
    let hit = dirCache.get(dir);
    if (hit === undefined) {
      hit = statDir(dir);
      dirCache.set(dir, hit);
    }
    return hit;
  };

  interface Annotated {
    row: SessionWithStateRow;
    state: EffectiveState;
    dirMissing: boolean;
    /**
     * Severity used for ORDERING, which is not always the severity of the true
     * state: a directory-gone row can never make progress, so it must not be
     * allowed to hold a working/blocked tier and pin itself to the top of the
     * list forever (plan Task 0 finding). The displayed state stays truthful.
     */
    rank: number;
  }

  const annotated: Annotated[] = rows.map((row) => {
    const state = effectiveStateOf(row);
    const dirMissing = !dirExists(row.directory);
    return {
      row,
      state,
      dirMissing,
      rank: dirMissing ? Math.max(severityOf(state), IDLE_RANK) : severityOf(state),
    };
  });

  const byId = new Map<string, Annotated>();
  for (const a of annotated) byId.set(a.row.id, a);

  interface Agg {
    childState: EffectiveState | null;
    childSeverity: number;
    childRank: number;
    childCount: number;
    maxActivity: number;
  }
  const aggByRoot = new Map<string, Agg>();

  for (const a of annotated) {
    const rootId = a.row.root_id;
    let agg = aggByRoot.get(rootId);
    if (!agg) {
      agg = {
        childState: null,
        childSeverity: Number.POSITIVE_INFINITY,
        childRank: Number.POSITIVE_INFINITY,
        childCount: 0,
        maxActivity: Number.NEGATIVE_INFINITY,
      };
      aggByRoot.set(rootId, agg);
    }
    // Recency is a property of the TREE, not of the root row: a root that has
    // been silent for a day while its subagent worked five seconds ago is a
    // recently-active tree, and sorting it by the root's own clock would sink it.
    const activity = a.row.lastActivity ?? a.row.time_updated;
    if (activity > agg.maxActivity) agg.maxActivity = activity;

    // Descendants only. `root_id === id` identifies the root itself, at any
    // depth of tree, because the base query resolves root_id by walking all the
    // way up rather than lifting one level.
    if (a.row.id !== rootId) {
      agg.childCount++;
      const sev = severityOf(a.state);
      if (sev < agg.childSeverity) {
        agg.childSeverity = sev;
        agg.childState = a.state;
      }
      if (a.rank < agg.childRank) agg.childRank = a.rank;
    }
  }

  const folded: FoldedRow[] = [];
  for (const a of annotated) {
    if (a.row.id !== a.row.root_id) continue; // children are folded away
    const agg = aggByRoot.get(a.row.root_id);
    const childRank = agg?.childRank ?? Number.POSITIVE_INFINITY;

    // A blocked CHILD lifts the parent into the blocked tier. The glyph still
    // distinguishes the two (child_state vs effective_state) so the parent never
    // masquerades as blocked itself -- but if the fold did not also lift the
    // SORT, the single most attention-worthy row in the list would be buried
    // under whatever its parent happened to be doing. Hiding it is what the fold
    // must not do.
    const rank = Math.min(a.rank, childRank);
    const sortRank = Number.isFinite(rank) ? rank : IDLE_RANK;
    const attention = sortRank <= SEVERITY.blocked;

    folded.push({
      ...a.row,
      effective_state: a.state,
      dir_missing: a.dirMissing,
      child_state: agg?.childState ?? null,
      child_count: agg?.childCount ?? 0,
      sort_rank: sortRank,
      attention,
      lastActivity: agg && Number.isFinite(agg.maxActivity) ? agg.maxActivity : a.row.lastActivity,
    });
  }

  folded.sort((x, y) => {
    // Two-group sort: attention group (error or blocked) pinned on top.
    if (x.attention !== y.attention) return x.attention ? -1 : 1;
    // Within each group, sort by descending tree-max lastActivity (most recently active first).
    if (y.lastActivity !== x.lastActivity) return y.lastActivity - x.lastActivity;
    // Total order, so the output is reproducible rather than readdir-dependent.
    return x.id < y.id ? -1 : x.id > y.id ? 1 : 0;
  });

  return folded;
}
