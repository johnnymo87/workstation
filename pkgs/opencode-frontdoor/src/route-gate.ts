import fs from 'node:fs';
import { classify, dispatch, RouteAction } from './dispatch.js';
import {
  RouteDisposition,
  getRouteDisposition,
  ROUTE_DISPOSITIONS,
  CLASS_DISPOSITIONS,
} from './routes.dispositions.js';
import { ROUTE_CLASSIFICATION_TABLE, RouteEntry } from './routes.classification.js';

export interface GateCheckOptions {
  minRoutes?: number;
  routeDispositions?: Record<string, RouteDisposition>;
  classDispositions?: Record<string, RouteDisposition>;
  routeClassificationTable?: RouteEntry[];
}

export interface UnrecognizedRoute {
  method: string;
  path: string;
}

export interface ShadowedRoute {
  method: string;
  path: string;
  shadowedBy: string;
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
  shadowed: ShadowedRoute[];
  denialCount: number;
  invalidDispositions: InvalidDispositionRoute[];
  orphanedDispositions: string[];
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

// Allowlist for legitimately table-only dispositions (routes deliberately not declared in /doc).
// Currently zero entries are required; all 49 disposition keys match live /doc denial routes.
const ALLOWED_ORPHAN_DISPOSITIONS = new Set<string>([
  // e.g. 'METHOD /path' if ever needed in the future
]);

function normalizeTemplatePath(p: string): string {
  let path = p.split('?')[0];
  path = path.replace(/\{[^}]*\}/g, '{}');
  if (path.endsWith('/') && path !== '/') {
    path = path.slice(0, -1);
  }
  return path;
}

function normalizeSimplePath(p: string): string {
  let path = p.split('?')[0];
  if (path.endsWith('/') && path !== '/') {
    path = path.slice(0, -1);
  }
  return path;
}

function compilePathTemplateRegex(normalizedPath: string): RegExp {
  let escaped = normalizedPath.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  escaped = escaped.replace(/\\\{.*?\\\}/g, '[^/]+');
  escaped = escaped.replace(/\\\*/g, '.*');
  return new RegExp(`^${escaped}$`);
}

function findShadowingTemplate(
  method: string,
  pathname: string,
  table: RouteEntry[]
): string | undefined {
  const normMethod = method.toUpperCase();
  const normPath = normalizeSimplePath(pathname);

  for (const entry of table) {
    const entryNormPath = normalizeSimplePath(entry.path);
    if (entryNormPath.includes('{') || entryNormPath.includes('*')) {
      if (entry.method.toUpperCase() === normMethod) {
        const regex = compilePathTemplateRegex(entryNormPath);
        if (regex.test(normPath)) {
          return `${entry.method.toUpperCase()} ${entry.path}`;
        }
      }
    }
  }
  return undefined;
}

export function checkDocRoutes(
  docJson: unknown,
  options: GateCheckOptions = {}
): GateCheckResult {
  const minRoutes = options.minRoutes ?? 100;
  const classificationTable = options.routeClassificationTable ?? ROUTE_CLASSIFICATION_TABLE;
  const routeDispositions = options.routeDispositions ?? ROUTE_DISPOSITIONS;
  const classDispositions = options.classDispositions ?? CLASS_DISPOSITIONS;

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
      shadowed: [],
      denialCount: 0,
      invalidDispositions: [],
      orphanedDispositions: [],
      passed: false,
      error: 'Invalid /doc format: "paths" object is missing or invalid',
    };
  }

  const exactNormalizedTableKeys = new Set<string>();
  for (const entry of classificationTable) {
    const method = entry.method.toUpperCase();
    const normPath = normalizeTemplatePath(entry.path);
    exactNormalizedTableKeys.add(`${method} ${normPath}`);
  }

  const pathsObj = docJson.paths as Record<string, Record<string, unknown>>;
  let totalChecked = 0;
  let denialCount = 0;
  const unrecognized: UnrecognizedRoute[] = [];
  const shadowed: ShadowedRoute[] = [];
  const invalidDispositions: InvalidDispositionRoute[] = [];
  const matchedDispositionKeys = new Set<string>();

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

      // Check A: strict template-shape matching
      const docNormKey = `${method} ${normalizeTemplatePath(path)}`;
      if (!exactNormalizedTableKeys.has(docNormKey)) {
        const shadowingTemplate = findShadowingTemplate(method, path, classificationTable);
        if (shadowingTemplate) {
          shadowed.push({
            method,
            path,
            shadowedBy: shadowingTemplate,
          });
        } else {
          unrecognized.push({ method, path });
        }
      }

      // Check B: denial dispositions
      if (DENIAL_ACTIONS.has(action)) {
        denialCount++;
        const disp = getRouteDisposition(
          method,
          path,
          routeClass,
          routeDispositions,
          classDispositions
        );

        let normPath = path.split('?')[0];
        if (normPath.endsWith('/') && normPath !== '/') {
          normPath = normPath.slice(0, -1);
        }
        const exactDispKey = `${method} ${normPath}`;
        if (routeDispositions[exactDispKey]) {
          matchedDispositionKeys.add(exactDispKey);
        } else if (normPath.startsWith('/api/')) {
          const bareDispKey = `${method} ${normPath.slice(4)}`;
          if (routeDispositions[bareDispKey]) {
            matchedDispositionKeys.add(bareDispKey);
          }
        }

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

          if (disp.kind === 'not-session-scopable') {
            if (!disp.tuiSurface) {
              invalidDispositions.push({
                method,
                path,
                action,
                reason: 'Kind "not-session-scopable" requires a tuiSurface field (\'absent\' | \'degrades\' | \'unverified\')',
              });
            } else if (!['absent', 'degrades', 'unverified'].includes(disp.tuiSurface)) {
              invalidDispositions.push({
                method,
                path,
                action,
                reason: `Invalid tuiSurface value "${disp.tuiSurface}" for kind "not-session-scopable" (expected 'absent' | 'degrades' | 'unverified')`,
              });
            }
          }
        }
      }
    }
  }

  // Check B (Inverse): Orphaned dispositions check
  const orphanedDispositions: string[] = [];
  for (const dispKey of Object.keys(routeDispositions)) {
    if (!matchedDispositionKeys.has(dispKey) && !ALLOWED_ORPHAN_DISPOSITIONS.has(dispKey)) {
      orphanedDispositions.push(dispKey);
    }
  }

  if (totalChecked < minRoutes) {
    return {
      totalChecked,
      unrecognized,
      shadowed,
      denialCount,
      invalidDispositions,
      orphanedDispositions,
      passed: false,
      error: `Sanity floor failed: checked ${totalChecked} route(s), expected at least ${minRoutes}`,
    };
  }

  const errors: string[] = [];
  if (unrecognized.length > 0) {
    errors.push(`Route classification gate (Check A) failed: ${unrecognized.length} unrecognized route(s) found`);
  }
  if (shadowed.length > 0) {
    errors.push(`Route classification gate (Check A) failed: ${shadowed.length} template-shadowed route(s) found`);
  }
  if (invalidDispositions.length > 0) {
    errors.push(`Denial disposition gate (Check B) failed: ${invalidDispositions.length} denial route(s) missing or with invalid dispositions`);
  }
  if (orphanedDispositions.length > 0) {
    errors.push(`Denial disposition gate (Check B) failed: ${orphanedDispositions.length} orphaned disposition(s) found: ${orphanedDispositions.join(', ')}`);
  }

  if (errors.length > 0) {
    return {
      totalChecked,
      unrecognized,
      shadowed,
      denialCount,
      invalidDispositions,
      orphanedDispositions,
      passed: false,
      error: errors.join('; '),
    };
  }

  return {
    totalChecked,
    unrecognized: [],
    shadowed: [],
    denialCount,
    invalidDispositions: [],
    orphanedDispositions: [],
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
      `[PASS] Route classification and disposition gate passed: checked ${result.totalChecked} route(s) across /doc (0 unrecognized, 0 shadowed, ${result.denialCount} denials properly dispositioned, 0 orphaned dispositions).`
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
    if (result.shadowed.length > 0) {
      console.error('Template-shadowed routes (Check A):');
      for (const offender of result.shadowed) {
        console.error(`  ${offender.method} ${offender.path}: no exact table row; matched only via template ${offender.shadowedBy}`);
      }
    }
    if (result.invalidDispositions.length > 0) {
      console.error('Invalid or missing dispositions (Check B):');
      for (const offender of result.invalidDispositions) {
        console.error(`  ${offender.method} ${offender.path} [${offender.action}]: ${offender.reason}`);
      }
    }
    if (result.orphanedDispositions.length > 0) {
      console.error('Orphaned dispositions (Check B):');
      for (const offender of result.orphanedDispositions) {
        console.error(`  ${offender}: disposition exists but route is not present in /doc or is not denied`);
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
