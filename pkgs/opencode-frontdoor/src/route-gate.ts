import fs from 'node:fs';
import { classify, dispatch, RouteAction } from './dispatch.js';
import {
  RouteDisposition,
  getRouteDisposition,
} from './routes.dispositions.js';

export interface GateCheckOptions {
  minRoutes?: number;
  routeDispositions?: Record<string, RouteDisposition>;
  classDispositions?: Record<string, RouteDisposition>;
}

export interface UnrecognizedRoute {
  method: string;
  path: string;
}

export interface InvalidDispositionRoute {
  method: string;
  path: string;
  action: RouteAction;
  reason: string;
}

export interface GateCheckResult {
  totalChecked: number;
  unrecognized: UnrecognizedRoute[];
  denialCount: number;
  invalidDispositions: InvalidDispositionRoute[];
  passed: boolean;
  error?: string;
}

const HTTP_METHODS = new Set(['get', 'put', 'post', 'delete', 'patch']);

const DENIAL_ACTIONS = new Set<RouteAction>([
  'deny-global-mutation',
  'deny-per-process-501',
  'pty-501',
  'tui-501',
  'gone-410',
  'not-found-404',
]);

const NON_DENYING_ACTIONS = new Set<RouteAction>([
  'route-session',
  'create',
  'fork',
  'forward-anchor',
]);

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
      denialCount: 0,
      invalidDispositions: [],
      passed: false,
      error: 'Invalid /doc format: "paths" object is missing or invalid',
    };
  }

  const pathsObj = docJson.paths as Record<string, Record<string, unknown>>;
  let totalChecked = 0;
  let denialCount = 0;
  const unrecognized: UnrecognizedRoute[] = [];
  const invalidDispositions: InvalidDispositionRoute[] = [];

  for (const [path, pathItem] of Object.entries(pathsObj)) {
    if (!pathItem || typeof pathItem !== 'object') continue;

    for (const [key] of Object.entries(pathItem)) {
      const lowerKey = key.toLowerCase();
      if (!HTTP_METHODS.has(lowerKey)) {
        continue;
      }

      const method = lowerKey.toUpperCase();
      const routeClass = classify(method, path);
      const dispatched = dispatch(method, path);
      const action = dispatched.action;
      totalChecked++;

      // Check A: unrecognized
      if (routeClass === 'unrecognized') {
        unrecognized.push({ method, path });
      }

      // Check B: denial dispositions
      if (DENIAL_ACTIONS.has(action)) {
        denialCount++;
        const disp = getRouteDisposition(
          method,
          path,
          routeClass,
          options.routeDispositions,
          options.classDispositions
        );

        if (!disp) {
          invalidDispositions.push({
            method,
            path,
            action,
            reason: 'Missing disposition for denial route',
          });
        } else {
          // Validate disposition fields
          if (!disp.rationale || typeof disp.rationale !== 'string' || disp.rationale.trim() === '') {
            invalidDispositions.push({
              method,
              path,
              action,
              reason: 'Disposition has empty or missing rationale',
            });
          }

          if (disp.kind === 'superseded') {
            if (!disp.supersededBy || typeof disp.supersededBy !== 'string' || disp.supersededBy.trim() === '') {
              invalidDispositions.push({
                method,
                path,
                action,
                reason: 'Kind "superseded" requires a non-empty supersededBy route',
              });
            } else {
              const parts = disp.supersededBy.trim().split(/\s+/);
              if (parts.length < 2) {
                invalidDispositions.push({
                  method,
                  path,
                  action,
                  reason: `supersededBy "${disp.supersededBy}" is invalid (expected "METHOD /path")`,
                });
              } else {
                const sMethod = parts[0].toUpperCase();
                const sPath = parts.slice(1).join(' ');
                const sDispatch = dispatch(sMethod, sPath);
                if (!NON_DENYING_ACTIONS.has(sDispatch.action)) {
                  invalidDispositions.push({
                    method,
                    path,
                    action,
                    reason: `supersededBy "${disp.supersededBy}" points to a non-existent or denying route (action: "${sDispatch.action}")`,
                  });
                }
              }
            }
          }

          if (disp.kind === 'needs-mechanism' || disp.kind === 'accepted-gap') {
            if (!disp.bead || typeof disp.bead !== 'string' || disp.bead.trim() === '') {
              invalidDispositions.push({
                method,
                path,
                action,
                reason: `Kind "${disp.kind}" requires a non-empty bead reference`,
              });
            }
          }
        }
      }
    }
  }

  if (totalChecked < minRoutes) {
    return {
      totalChecked,
      unrecognized,
      denialCount,
      invalidDispositions,
      passed: false,
      error: `Sanity floor failed: checked ${totalChecked} route(s), expected at least ${minRoutes}`,
    };
  }

  const errors: string[] = [];
  if (unrecognized.length > 0) {
    errors.push(`Route classification gate (Check A) failed: ${unrecognized.length} unrecognized route(s) found`);
  }
  if (invalidDispositions.length > 0) {
    errors.push(`Denial disposition gate (Check B) failed: ${invalidDispositions.length} denial route(s) missing or with invalid dispositions`);
  }

  if (errors.length > 0) {
    return {
      totalChecked,
      unrecognized,
      denialCount,
      invalidDispositions,
      passed: false,
      error: errors.join('; '),
    };
  }

  return {
    totalChecked,
    unrecognized: [],
    denialCount,
    invalidDispositions: [],
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
      `[PASS] Route classification and disposition gate passed: checked ${result.totalChecked} route(s) across /doc (0 unrecognized, ${result.denialCount} denials properly dispositioned).`
    );
    return 0;
  } else {
    console.error(`[FAIL] ${result.error}`);
    if (result.unrecognized.length > 0) {
      console.error('Unrecognized routes (Check A):');
      for (const offender of result.unrecognized) {
        console.error(`  ${offender.method} ${offender.path}`);
      }
    }
    if (result.invalidDispositions.length > 0) {
      console.error('Invalid or missing dispositions (Check B):');
      for (const offender of result.invalidDispositions) {
        console.error(`  ${offender.method} ${offender.path} [${offender.action}]: ${offender.reason}`);
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
