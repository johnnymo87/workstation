import { Database } from "bun:sqlite";
import { queryBaseList, queryTreesForIds, queryTreesForSessions } from "./oc-session-list-base.js";
import { queryWithState, runOrphanGc } from "./oc-session-list-state.js";
import { foldRows } from "./oc-session-list-fold.js";

export interface CliOptions {
  limit: number;
  dbPath: string;
  routingDbPath: string;
  overlayDir: string;
  withState: boolean;
  fold: boolean;
  gc: boolean;
  help: boolean;
  /**
   * `--ids a,b,c`: resolve exactly these sessions' root trees instead of the
   * recency window. null = flag absent (normal listing). An empty array means
   * the flag was given with nothing in it, and yields an empty list -- never a
   * fall back to the recency window, which would answer a different question.
   */
  ids: string[] | null;
}

export function parseCliArgs(args: string[]): CliOptions {
  let limit = 50;
  let dbPath = process.env.HOME ? `${process.env.HOME}/.local/share/opencode/opencode.db` : "";
  // Derived from $HOME -- never hardcode an absolute user path, this package
  // ships to devbox, cloudbox and macOS. pigeon's unified daemon DB is the same
  // file the serves open as OPENCODE_ROUTING_DB, so prefer that when it is set.
  let routingDbPath =
    process.env.OPENCODE_ROUTING_DB ||
    (process.env.HOME ? `${process.env.HOME}/projects/pigeon/packages/daemon/data/pigeon-daemon.db` : "");
  let overlayDir = process.env.HOME ? `${process.env.HOME}/.local/share/opencode/session-state.d` : "";
  let withState = false;
  let fold = false;
  let gc = false;
  let help = false;
  let ids: string[] | null = null;
  const splitIds = (v: string): string[] =>
    v.split(",").map((s) => s.trim()).filter((s) => s !== "");

  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    if (arg === "--help" || arg === "-h") {
      help = true;
    } else if (arg === "--limit") {
      const val = args[++i];
      if (val) limit = parseInt(val, 10);
    } else if (arg.startsWith("--limit=")) {
      limit = parseInt(arg.slice(8), 10);
    } else if (arg === "--db") {
      const val = args[++i];
      if (val) dbPath = val;
    } else if (arg.startsWith("--db=")) {
      dbPath = arg.slice(5);
    } else if (arg === "--with-state") {
      withState = true;
    } else if (arg === "--fold") {
      // Implies --with-state: the row model is a function of merged state, and
      // folding an unmerged list would emit child_state: null for every root --
      // green, empty, and wrong.
      fold = true;
      withState = true;
    } else if (arg === "--routing-db") {
      const val = args[++i];
      if (val) routingDbPath = val;
    } else if (arg.startsWith("--routing-db=")) {
      routingDbPath = arg.slice(13);
    } else if (arg === "--overlay-dir") {
      const val = args[++i];
      if (val) overlayDir = val;
    } else if (arg.startsWith("--overlay-dir=")) {
      overlayDir = arg.slice(14);
    } else if (arg === "--gc") {
      gc = true;
    } else if (arg === "--ids") {
      ids = splitIds(args[++i] ?? "");
    } else if (arg.startsWith("--ids=")) {
      ids = splitIds(arg.slice(6));
    }
  }

  // Clamp: SQLite treats a NEGATIVE LIMIT as UNBOUNDED, so `--limit -5` would
  // dump all 8,771 sessions off a 13 GB DB, and `--limit abc` (NaN) is equally
  // meaningless. Fall back to the default rather than surprising the caller.
  if (!Number.isFinite(limit) || limit <= 0) limit = 50;

  return { limit, dbPath, routingDbPath, overlayDir, withState, fold, gc, help, ids };
}

export function printHelp(): void {
  console.log(`Usage: oc-session-list [options]

Options:
  --limit <N>          Maximum number of recent root session trees to return (default: 50)
  --db <path>          Path to opencode.db (default: $HOME/.local/share/opencode/opencode.db)
  --with-state         Merge base session list with live overlay state
  --fold               Roots only, children folded into child_state, sorted by attention (implies --with-state).
                       Also UNIONS IN attention-worthy sessions that fall outside --limit's recency
                       window, so this changes which sessions appear, not just their shape.
  --routing-db <path>   Path to pigeon-daemon.db (default: $OPENCODE_ROUTING_DB, else $HOME/projects/pigeon/packages/daemon/data/pigeon-daemon.db)
  --overlay-dir <path> Directory containing session-state overlays (default: $HOME/.local/share/opencode/session-state.d)
  --gc                 Perform orphan GC on dead overlay files older than 10 minutes
  --ids <id,...>       Resolve exactly these sessions (a child id brings its whole root tree;
                       archived and unknown ids are dropped). Replaces the recency window:
                       --limit is ignored and --fold adds no overlay union.
  --help, -h           Show this help message
`);
}

export function main(args: string[] = process.argv.slice(2)): void {
  const options = parseCliArgs(args);

  if (options.help) {
    printHelp();
    return;
  }

  if (!options.dbPath) {
    console.error("Error: --db path is required or $HOME must be set");
    process.exit(1);
  }

  if (options.gc) {
    runOrphanGc(options.overlayDir);
  }

  try {
    const db = new Database(options.dbPath, { readonly: true });
    const warn = (msg: string) => console.error(`oc-session-list: ${msg}`);
    // --ids REPLACES the recency window rather than filtering it: the caller
    // (the stall-watch picker) names sessions precisely because most of them
    // fall outside any window, so applying --limit would drop the rows it came
    // for. For the same reason the --fold overlay union is off in ids mode --
    // the answer is the set that was asked for, not that set plus whatever
    // else is attention-worthy right now.
    const idsMode = options.ids !== null;
    const baseRows = idsMode
      ? queryTreesForIds(db, options.ids ?? [], warn)
      : queryBaseList(db, { limit: options.limit });

    if (options.withState) {
      const rowsWithState = queryWithState(baseRows, {
        routingDbPath: options.routingDbPath,
        onWarn: warn,
        overlayDir: options.overlayDir,
        // The union only makes sense when we are folding to roots: it exists so
        // an attention-worthy row outside the recency window still reaches the
        // picker. Wiring it here (not inside queryWithState) keeps the DB handle
        // where it belongs and leaves the plain --with-state shape untouched.
        ...(options.fold && !idsMode ? { unionLookup: (sids: string[]) => queryTreesForSessions(db, sids) } : {}),
      });
      const out = options.fold ? foldRows(rowsWithState) : rowsWithState;
      console.log(JSON.stringify(out, null, 2));
    } else {
      console.log(JSON.stringify(baseRows, null, 2));
    }
  } catch (err: any) {
    console.error(`Error querying database at ${options.dbPath}:`, err?.message || err);
    process.exit(1);
  }
}

if (import.meta.main) {
  main();
}
