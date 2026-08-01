import { Database } from "bun:sqlite";
import { queryBaseList } from "./oc-session-list-base.js";

export interface CliOptions {
  limit: number;
  dbPath: string;
  help: boolean;
}

export function parseCliArgs(args: string[]): CliOptions {
  let limit = 50;
  let dbPath = process.env.HOME ? `${process.env.HOME}/.local/share/opencode/opencode.db` : "";
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
    }
  }

  return { limit, dbPath, help };
}

export function printHelp(): void {
  console.log(`Usage: oc-session-list [options]

Options:
  --limit <N>     Maximum number of recent root session trees to return (default: 50)
  --db <path>     Path to opencode.db (default: $HOME/.local/share/opencode/opencode.db)
  --help, -h      Show this help message
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

  try {
    const db = new Database(options.dbPath, { readonly: true });
    const rows = queryBaseList(db, { limit: options.limit });
    console.log(JSON.stringify(rows, null, 2));
  } catch (err: any) {
    console.error(`Error querying database at ${options.dbPath}:`, err?.message || err);
    process.exit(1);
  }
}

if (import.meta.main) {
  main();
}
