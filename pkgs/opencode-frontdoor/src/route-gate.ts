import fs from 'node:fs';
import { classify } from './dispatch.js';

export interface GateCheckOptions {
  minRoutes?: number;
}

export interface UnrecognizedRoute {
  method: string;
  path: string;
}

export interface GateCheckResult {
  totalChecked: number;
  unrecognized: UnrecognizedRoute[];
  passed: boolean;
  error?: string;
}

const HTTP_METHODS = new Set(['get', 'put', 'post', 'delete', 'patch']);

export function checkDocRoutes(
  docJson: unknown,
  options: GateCheckOptions = {}
): GateCheckResult {
  const minRoutes = options.minRoutes ?? 100;

  if (
    !docJson ||
    typeof docJson !== 'object' ||
    !('paths' in docJson) ||
    !docJson.paths ||
    typeof docJson.paths !== 'object'
  ) {
    return {
      totalChecked: 0,
      unrecognized: [],
      passed: false,
      error: 'Invalid /doc format: "paths" object is missing or invalid',
    };
  }

  const pathsObj = docJson.paths as Record<string, Record<string, unknown>>;
  let totalChecked = 0;
  const unrecognized: UnrecognizedRoute[] = [];

  for (const [path, pathItem] of Object.entries(pathsObj)) {
    if (!pathItem || typeof pathItem !== 'object') continue;

    for (const [key] of Object.entries(pathItem)) {
      const lowerKey = key.toLowerCase();
      if (!HTTP_METHODS.has(lowerKey)) {
        continue;
      }

      const method = lowerKey.toUpperCase();
      const routeClass = classify(method, path);
      totalChecked++;

      if (routeClass === 'unrecognized') {
        unrecognized.push({ method, path });
      }
    }
  }

  if (totalChecked < minRoutes) {
    return {
      totalChecked,
      unrecognized,
      passed: false,
      error: `Sanity floor failed: checked ${totalChecked} route(s), expected at least ${minRoutes}`,
    };
  }

  if (unrecognized.length > 0) {
    return {
      totalChecked,
      unrecognized,
      passed: false,
      error: `Route classification gate failed: ${unrecognized.length} unrecognized route(s) found`,
    };
  }

  return {
    totalChecked,
    unrecognized: [],
    passed: true,
  };
}

export function runRouteGateCli(args: string[]): number {
  let docPath = '';
  let minRoutes = 100;

  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    if (arg === '--min-routes' && i + 1 < args.length) {
      minRoutes = parseInt(args[++i], 10);
    } else if (!arg.startsWith('-') && !docPath) {
      docPath = arg;
    }
  }

  if (!docPath) {
    console.error('Usage: route-gate <doc.json> [--min-routes N]');
    return 1;
  }

  if (!fs.existsSync(docPath)) {
    console.error(`Error: File not found: ${docPath}`);
    return 1;
  }

  let docJson: unknown;
  try {
    const content = fs.readFileSync(docPath, 'utf8');
    docJson = JSON.parse(content);
  } catch (err) {
    console.error(`Error: Failed to parse JSON from ${docPath}:`, err);
    return 1;
  }

  const result = checkDocRoutes(docJson, { minRoutes });

  if (result.passed) {
    console.log(
      `[PASS] Route classification gate passed: checked ${result.totalChecked} route(s) across /doc, 0 unrecognized.`
    );
    return 0;
  } else {
    console.error(`[FAIL] ${result.error}`);
    if (result.unrecognized.length > 0) {
      console.error('Unrecognized routes:');
      for (const offender of result.unrecognized) {
        console.error(`  ${offender.method} ${offender.path}`);
      }
    }
    return 1;
  }
}

// ESM main check when run as CLI
if (process.argv[1] && (process.argv[1].endsWith('route-gate.js') || process.argv[1].endsWith('route-gate.ts'))) {
  const exitCode = runRouteGateCli(process.argv.slice(2));
  process.exit(exitCode);
}
