import { Database } from "bun:sqlite";
import { queryBaseList } from "./oc-session-list-base.js";
import { queryWithState, runOrphanGc } from "./oc-session-list-state.js";

export interface CliOptions {
  limit: number;
  dbPath: string;
  routingDbPath: string;
  overlayDir: string;
  withState: boolean;
  gc: boolean;
  help: boolean;
}

export function parseCliArgs(args: string[]): CliOptions {
  let limit = 50;
  let dbPath = process.env.HOME ? `${process.env.HOME}/.local/share/opencode/opencode.db` : "";
  let routingDbPath = process.env.OPENCODE_ROUTING_DB || "/home/dev/projects/pigeon/packages/daemon/data/pigeon-daemon.db";
  let overlayDir = process.env.HOME ? `${process.env.HOME}/.local/share/opencode/session-state.d` : "";
  let withState = false;
  let gc = false;
  let help = false;

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
    }
  }

  return { limit, dbPath, routingDbPath, overlayDir, withState, gc, help };
}

export function printHelp(): void {
  console.log(`Usage: oc-session-list [options]

Options:
  --limit <N>          Maximum number of recent root session trees to return (default: 50)
  --db <path>          Path to opencode.db (default: $HOME/.local/share/opencode/opencode.db)
  --with-state         Merge base session list with live overlay state
  --routing-db <path>   Path to pigeon-daemon.db (default: $OPENCODE_ROUTING_DB or /home/dev/projects/pigeon/packages/daemon/data/pigeon-daemon.db)
  --overlay-dir <path> Directory containing session-state overlays (default: $HOME/.local/share/opencode/session-state.d)
  --gc                 Perform orphan GC on dead overlay files older than 10 minutes
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
    const baseRows = queryBaseList(db, { limit: options.limit });

    if (options.withState) {
      const rowsWithState = queryWithState(baseRows, {
        routingDbPath: options.routingDbPath,
        overlayDir: options.overlayDir,
      });
      console.log(JSON.stringify(rowsWithState, null, 2));
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
