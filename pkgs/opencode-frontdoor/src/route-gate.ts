import fs from 'node:fs';
import { classify, dispatch, RouteAction } from './dispatch.js';
import {
  RouteDisposition,
  getRouteDisposition,
  ROUTE_DISPOSITIONS,
  CLASS_DISPOSITIONS,
} from './routes.dispositions.js';
import { ROUTE_CLASSIFICATION_TABLE, RouteEntry } from './routes.classification.js';
import { isHtmlResponse, HTML_GUARD_EXEMPT_ROUTES } from './poison.js';

export interface GateCheckOptions {
  minRoutes?: number;
  routeDispositions?: Record<string, RouteDisposition>;
  classDispositions?: Record<string, RouteDisposition>;
  routeClassificationTable?: RouteEntry[];
  expectedKindCensus?: Record<string, number>;
  expectedNeedsMechanismKeys?: string[];
  expectedMediaTypeCensus?: Record<string, number>;
  htmlGuardExemptRoutes?: string[];
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

export interface HtmlDeclaringRoute {
  method: string;
  path: string;
  status: string;
  mediaType: string;
}

export interface GateCheckResult {
  totalChecked: number;
  unrecognized: UnrecognizedRoute[];
  shadowed: ShadowedRoute[];
  denialCount: number;
  invalidDispositions: InvalidDispositionRoute[];
  orphanedDispositions: string[];
  kindCensus: Record<string, number>;
  dedupedDenialCount: number;
  needsMechanismKeys: string[];
  mediaTypeCensus: Record<string, number>;
  htmlDeclaringRoutes: HtmlDeclaringRoute[];
  octetStreamRoutes: string[];
  passed: boolean;
  error?: string;
}

/**
 * Expected disposition kind census on the pinned /doc fixture.
 * A pin bump or table edit changing these is supposed to fail the gate and force a written decision — that is the mechanism, not a nuisance.
 */
export const EXPECTED_KIND_CENSUS: Record<string, number> = {
  'by-design-501': 21,
  'not-session-scopable-absent': 21,
  'not-session-scopable-degrades': 6,
  'not-session-scopable-unverified': 5,
  superseded: 7,
  'needs-mechanism': 9,
  'accepted-gap': 1,
};

/**
 * Expected set of needs-mechanism disposition keys on the pinned /doc fixture.
 * A pin bump or table edit changing these is supposed to fail the gate and force a written decision — that is the mechanism, not a nuisance.
 * Shrinking EXPECTED_NEEDS_MECHANISM_KEYS to empty is how D4 completion becomes provable (bead workstation-mlve.11).
 */
export const EXPECTED_NEEDS_MECHANISM_KEYS: string[] = [
  'DELETE /auth/{providerID}',
  'DELETE /mcp/{name}/auth',
  'POST /instance/dispose',
  'POST /mcp/{name}/auth',
  'POST /mcp/{name}/auth/authenticate',
  'POST /mcp/{name}/auth/callback',
  'POST /provider/{providerID}/oauth/authorize',
  'POST /provider/{providerID}/oauth/callback',
  'PUT /auth/{providerID}',
];

/**
 * Expected media-type census on the pinned /doc fixture.
 * A pin bump or schema restructuring changing these (e.g. moving responses to $ref) is supposed to fail the gate and force a written decision — that is the mechanism, not a nuisance.
 */
export const EXPECTED_MEDIA_TYPE_CENSUS: Record<string, number> = {
  'application/json': 512,
  'text/event-stream': 4,
  'text/x-diff; charset=utf-8': 1,
  'application/octet-stream': 1,
};

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

  const defaultKindCensus: Record<string, number> = {
    'by-design-501': 0,
    'not-session-scopable-absent': 0,
    'not-session-scopable-degrades': 0,
    'not-session-scopable-unverified': 0,
    superseded: 0,
    'needs-mechanism': 0,
    'accepted-gap': 0,
  };

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
      kindCensus: defaultKindCensus,
      dedupedDenialCount: 0,
      needsMechanismKeys: [],
      mediaTypeCensus: {},
      htmlDeclaringRoutes: [],
      octetStreamRoutes: [],
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
  const deduplicatedDenials = new Map<string, { method: string; path: string }>();
  const mediaTypeCensus: Record<string, number> = {};
  const htmlDeclaringRoutes: HtmlDeclaringRoute[] = [];
  const octetStreamSet = new Set<string>();

  for (const [path, pathItem] of Object.entries(pathsObj)) {
    if (!pathItem || typeof pathItem !== 'object') continue;

    for (const [key, methodObj] of Object.entries(pathItem)) {
      const lowerKey = key.toLowerCase();
      if (!HTTP_METHODS.has(lowerKey)) {
        continue;
      }

      const method = lowerKey.toUpperCase();
      const routeClass = classify(method, path);
      const dispatched = dispatch(method, path);
      const action = dispatched.action;
      totalChecked++;

      // Check C: media-type walk
      if (methodObj && typeof methodObj === 'object' && 'responses' in methodObj && methodObj.responses && typeof methodObj.responses === 'object') {
        const responsesObj = methodObj.responses as Record<string, unknown>;
        for (const [status, responseItem] of Object.entries(responsesObj)) {
          if (!responseItem || typeof responseItem !== 'object') continue;
          if ('content' in responseItem && responseItem.content && typeof responseItem.content === 'object') {
            const contentObj = responseItem.content as Record<string, unknown>;
            for (const mediaType of Object.keys(contentObj)) {
              mediaTypeCensus[mediaType] = (mediaTypeCensus[mediaType] || 0) + 1;
              const normMediaType = mediaType.split(';')[0].trim().toLowerCase();
              if (normMediaType === 'application/octet-stream') {
                octetStreamSet.add(`${method} ${path}`);
              }
              if (isHtmlResponse(mediaType)) {
                htmlDeclaringRoutes.push({
                  method,
                  path,
                  status,
                  mediaType,
                });
              }
            }
          }
        }
      }

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

      // Check B: denial dispositions & dedup collection
      if (DENIAL_ACTIONS.has(action)) {
        denialCount++;

        let barePath = path.split('?')[0];
        if (barePath.endsWith('/') && barePath !== '/') {
          barePath = barePath.slice(0, -1);
        }
        if (barePath.startsWith('/api/')) {
          barePath = barePath.slice(4);
        }
        const bareKey = `${method} ${barePath}`;
        if (!deduplicatedDenials.has(bareKey)) {
          deduplicatedDenials.set(bareKey, { method, path });
        }

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

  // Compute kind census, deduped denial count, and needs-mechanism keys
  const kindCensus: Record<string, number> = {
    'by-design-501': 0,
    'not-session-scopable-absent': 0,
    'not-session-scopable-degrades': 0,
    'not-session-scopable-unverified': 0,
    superseded: 0,
    'needs-mechanism': 0,
    'accepted-gap': 0,
  };
  const needsMechanismKeySet = new Set<string>();

  for (const [bareKey, { method, path }] of deduplicatedDenials.entries()) {
    const routeClass = classify(method, path);
    const disp = getRouteDisposition(
      method,
      path,
      routeClass,
      routeDispositions,
      classDispositions
    );
    if (disp) {
      if (disp.kind === 'by-design-501') {
        kindCensus['by-design-501']++;
      } else if (disp.kind === 'superseded') {
        kindCensus['superseded']++;
      } else if (disp.kind === 'needs-mechanism') {
        kindCensus['needs-mechanism']++;
        needsMechanismKeySet.add(bareKey);
      } else if (disp.kind === 'accepted-gap') {
        kindCensus['accepted-gap']++;
      } else if (disp.kind === 'not-session-scopable') {
        if (disp.tuiSurface === 'degrades') {
          kindCensus['not-session-scopable-degrades']++;
        } else if (disp.tuiSurface === 'unverified') {
          kindCensus['not-session-scopable-unverified']++;
        } else if (disp.tuiSurface === 'absent') {
          kindCensus['not-session-scopable-absent']++;
        }
      }
    }
  }

  const dedupedDenialCount = deduplicatedDenials.size;
  const needsMechanismKeys = Array.from(needsMechanismKeySet).sort();
  const octetStreamRoutes = Array.from(octetStreamSet).sort();

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
      kindCensus,
      dedupedDenialCount,
      needsMechanismKeys,
      mediaTypeCensus,
      htmlDeclaringRoutes,
      octetStreamRoutes,
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

  // Enforce the kind census + needs-mechanism key set ONLY when checking the REAL
  // table triple. The census is an assertion about the production tables; against a
  // synthetic table it is meaningless, and asserting a census computed from injected
  // data would be circular.
  //
  // All THREE overrides must be absent, not just routeDispositions: overriding
  // `routeClassificationTable` changes which routes are denials at all, and
  // `classDispositions` changes how a denial resolves — either one invalidates the
  // census just as thoroughly. Gating on only one of them made synthetic-table tests
  // (e.g. the F1 shadowing test) emit a spurious all-zeros census mismatch, which
  // turned their `expect(result.passed).toBe(false)` into a tautology that would
  // still hold if the behavior under test broke.
  //
  // NOTE this is a condition on EXPLICITLY INJECTED test tables, not a
  // skip-on-missing-input: the authoritative CLI path passes no overrides, so the
  // census is always enforced there.
  const usingRealTables =
    options.routeDispositions === undefined &&
    options.classDispositions === undefined &&
    options.routeClassificationTable === undefined;
  if (usingRealTables) {
    const expectedKindCensus = options.expectedKindCensus ?? EXPECTED_KIND_CENSUS;
    const censusDiffs: string[] = [];
    const allCensusKeys = new Set([
      ...Object.keys(expectedKindCensus),
      ...Object.keys(kindCensus),
    ]);
    for (const censusKey of allCensusKeys) {
      const expected = expectedKindCensus[censusKey] ?? 0;
      const actual = kindCensus[censusKey] ?? 0;
      if (expected !== actual) {
        censusDiffs.push(`${censusKey}: expected ${expected}, got ${actual}`);
      }
    }
    if (censusDiffs.length > 0) {
      errors.push(`Kind census mismatch: ${censusDiffs.join('; ')}`);
    }

    const expectedNeedsMechKeys = options.expectedNeedsMechanismKeys ?? EXPECTED_NEEDS_MECHANISM_KEYS;
    const expectedSet = new Set(expectedNeedsMechKeys);
    const actualSet = new Set(needsMechanismKeys);
    const addedKeys = needsMechanismKeys.filter((k) => !expectedSet.has(k));
    const removedKeys = expectedNeedsMechKeys.filter((k) => !actualSet.has(k));

    if (addedKeys.length > 0 || removedKeys.length > 0) {
      const keyDiffs: string[] = [];
      if (addedKeys.length > 0) keyDiffs.push(`added [${addedKeys.join(', ')}]`);
      if (removedKeys.length > 0) keyDiffs.push(`removed [${removedKeys.join(', ')}]`);
      errors.push(`Needs-mechanism keys mismatch: ${keyDiffs.join('; ')}`);
    }

    const expectedMediaTypeCensus = options.expectedMediaTypeCensus ?? EXPECTED_MEDIA_TYPE_CENSUS;
    const mediaTypeDiffs: string[] = [];
    const allMediaTypeKeys = new Set([
      ...Object.keys(expectedMediaTypeCensus),
      ...Object.keys(mediaTypeCensus),
    ]);
    for (const mtKey of allMediaTypeKeys) {
      const expected = expectedMediaTypeCensus[mtKey] ?? 0;
      const actual = mediaTypeCensus[mtKey] ?? 0;
      if (expected !== actual) {
        mediaTypeDiffs.push(`${mtKey}: expected ${expected}, got ${actual}`);
      }
    }
    if (mediaTypeDiffs.length > 0) {
      errors.push(`Media-type census mismatch: ${mediaTypeDiffs.join('; ')}`);
    }
  }

  // Check C enforcement (always runs)
  if (htmlDeclaringRoutes.length > 0) {
    errors.push(
      `Check C failed: ${htmlDeclaringRoutes.length} route(s) declare text/html responses (${htmlDeclaringRoutes.map((r) => `${r.method} ${r.path} [${r.status} ${r.mediaType}]`).join(', ')}). The runtime poison guard would 502 a legitimate response, so either the guard needs an exemption or the route needs a different disposition.`
    );
  }

  // Check D: The set of routes declaring an application/octet-stream response must equal HTML_GUARD_EXEMPT_ROUTES.
  // Rationale: application/octet-stream means "arbitrary bytes", which is exactly the marker for a route
  // whose runtime content type is data-dependent and therefore may legitimately be text/html.
  // Contrast GET /vcs/diff/raw, which declares the specific type text/x-diff; charset=utf-8 and cannot be HTML.
  // Today there is exactly one octet-stream route and it is the one exemption.
  const exemptRoutes = options.htmlGuardExemptRoutes ?? HTML_GUARD_EXEMPT_ROUTES;
  const exemptSet = new Set(exemptRoutes);
  const declaredOctetSet = new Set(octetStreamRoutes);

  const declaredNotExempt = octetStreamRoutes.filter((r) => !exemptSet.has(r));
  const exemptNotDeclared = exemptRoutes.filter((r) => !declaredOctetSet.has(r));

  if (declaredNotExempt.length > 0 || exemptNotDeclared.length > 0) {
    const diffs: string[] = [];
    if (declaredNotExempt.length > 0) {
      diffs.push(`declared application/octet-stream in /doc but not in HTML_GUARD_EXEMPT_ROUTES: [${declaredNotExempt.join(', ')}]`);
    }
    if (exemptNotDeclared.length > 0) {
      diffs.push(`present in HTML_GUARD_EXEMPT_ROUTES but does not declare application/octet-stream in /doc: [${exemptNotDeclared.join(', ')}]`);
    }
    errors.push(`Check D failed: octet-stream exemption mismatch (${diffs.join('; ')})`);
  }

  if (errors.length > 0) {
    return {
      totalChecked,
      unrecognized,
      shadowed,
      denialCount,
      invalidDispositions,
      orphanedDispositions,
      kindCensus,
      dedupedDenialCount,
      needsMechanismKeys,
      mediaTypeCensus,
      htmlDeclaringRoutes,
      octetStreamRoutes,
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
    kindCensus,
    dedupedDenialCount,
    needsMechanismKeys,
    mediaTypeCensus,
    htmlDeclaringRoutes: [],
    octetStreamRoutes,
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
    const kindCensusStr = Object.entries(result.kindCensus)
      .map(([k, v]) => `${k}=${v}`)
      .join(', ');
    const mediaTypeStr = Object.entries(result.mediaTypeCensus)
      .map(([k, v]) => `${k}=${v}`)
      .join(', ');
    const checkDStr = result.octetStreamRoutes.join(', ');
    console.log(
      `[PASS] Route classification and disposition gate passed: checked ${result.totalChecked} route(s) across /doc (0 unrecognized, 0 shadowed, ${result.denialCount} denials properly dispositioned, 0 orphaned dispositions). Kind census: ${kindCensusStr}. Media-type census: ${mediaTypeStr}. Check D (octet-stream exemption match): ${checkDStr}.`
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
    if (result.htmlDeclaringRoutes.length > 0) {
      console.error('HTML declaring routes (Check C):');
      for (const offender of result.htmlDeclaringRoutes) {
        console.error(`  ${offender.method} ${offender.path} [${offender.status}]: declared media type "${offender.mediaType}"`);
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
