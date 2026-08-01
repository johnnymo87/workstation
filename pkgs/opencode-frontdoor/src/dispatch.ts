import { ROUTE_CLASSIFICATION_TABLE, RouteClass } from './routes.classification.js';
import { normalizePath, compilePathTemplate } from './path-template.js';

export type RouteAction =
  | 'route-session'
  | 'create'
  | 'fork'
  | 'pty-501'
  | 'tui-501'
  | 'forward-anchor'
  | 'forward-pool'
  | 'deny-global-mutation'
  | 'deny-per-process-501'
  | 'gone-410'
  | 'not-found-404';

// Precompute structures at module load
interface PrecomputedRoute {
  class: RouteClass;
  poolSafe?: boolean;
}

const exactRoutes = new Map<string, PrecomputedRoute>();
const patternRoutes: Array<{ method: string; regex: RegExp; class: RouteClass; poolSafe?: boolean }> = [];
const globalRoMethodsMap = new Map<string, Set<string>>();

for (const entry of ROUTE_CLASSIFICATION_TABLE) {
  const normalizedPath = normalizePath(entry.path);
  const upperMethod = entry.method.toUpperCase();
  const key = `${upperMethod} ${normalizedPath}`;

  if (entry.class === 'global-ro') {
    if (!globalRoMethodsMap.has(normalizedPath)) {
      globalRoMethodsMap.set(normalizedPath, new Set<string>());
    }
    globalRoMethodsMap.get(normalizedPath)!.add(upperMethod);
  }

  const isPattern = normalizedPath.includes('{') || normalizedPath.includes('*');

  if (isPattern) {
    const regex = compilePathTemplate(normalizedPath);
    patternRoutes.push({
      method: upperMethod,
      regex,
      class: entry.class,
      poolSafe: entry.poolSafe,
    });
  } else {
    const existing = exactRoutes.get(key);
    if (existing && existing.class !== entry.class) {
      throw new Error(`Table bug: Duplicate route key "${key}" has conflicting classes "${existing.class}" and "${entry.class}"`);
    }
    exactRoutes.set(key, { class: entry.class, poolSafe: entry.poolSafe });
  }
}

const globalRoMethodsSorted = new Map<string, string[]>();
for (const [path, set] of globalRoMethodsMap.entries()) {
  globalRoMethodsSorted.set(path, Array.from(set).sort());
}

const globalRoPatternRoutes: Array<{ regex: RegExp; methods: string[] }> = [];
for (const [path, methods] of globalRoMethodsSorted.entries()) {
  const isPattern = path.includes('{') || path.includes('*');
  if (isPattern) {
    globalRoPatternRoutes.push({
      regex: compilePathTemplate(path),
      methods,
    });
  }
}

function findRouteEntry(method: string, pathname: string): PrecomputedRoute | null {
  const normalizedMethod = method.toUpperCase();
  const normalizedPath = normalizePath(pathname);

  // 1. Exact match first
  const key = `${normalizedMethod} ${normalizedPath}`;
  const exact = exactRoutes.get(key);
  if (exact) {
    return exact;
  }

  // 2. Pattern match next. First match wins, in ROUTE_CLASSIFICATION_TABLE order.
  for (const pattern of patternRoutes) {
    if (pattern.method === normalizedMethod && pattern.regex.test(normalizedPath)) {
      return pattern;
    }
  }

  // If HEAD, retry resolution as GET
  if (normalizedMethod === 'HEAD') {
    return findRouteEntry('GET', pathname);
  }

  return null;
}

export function classify(method: string, pathname: string): RouteClass {
  const entry = findRouteEntry(method, pathname);
  return entry ? entry.class : 'unrecognized';
}

export function isPoolSafe(method: string, pathname: string): boolean {
  const entry = findRouteEntry(method, pathname);
  return Boolean(entry?.poolSafe);
}

export function dispatch(method: string, pathname: string): {
  class: RouteClass;
  action: RouteAction;
  recognized: boolean;
  allowedMethods: string[];
} {
  const entry = findRouteEntry(method, pathname);
  const cls = entry ? entry.class : 'unrecognized';
  let action: RouteAction = 'not-found-404';

  switch (cls) {
    case 'session-path':
    case 'session-query':
      action = 'route-session';
      break;
    case 'create':
      action = 'create';
      break;
    case 'fork':
      action = 'fork';
      break;
    case 'pty':
      action = 'pty-501';
      break;
    case 'tui':
      action = 'tui-501';
      break;
    case 'global-ro':
      action = entry?.poolSafe ? 'forward-pool' : 'forward-anchor';
      break;
    case 'global-sideeffect':
      action = 'deny-global-mutation';
      break;
    case 'global-event':
      action = 'gone-410';
      break;
    case 'per-process-ro':
      action = 'deny-per-process-501';
      break;
    case 'web-ui':
    case 'unrecognized':
      action = 'not-found-404';
      break;
  }

  const normPath = normalizePath(pathname);
  let allowedMethods: string[] = [];

  if (action === 'deny-global-mutation') {
    const exact = globalRoMethodsSorted.get(normPath);
    if (exact) {
      allowedMethods = exact;
    } else {
      for (const pattern of globalRoPatternRoutes) {
        if (pattern.regex.test(normPath)) {
          allowedMethods = pattern.methods;
          break;
        }
      }
    }
  }

  return {
    class: cls,
    action,
    recognized: cls !== 'unrecognized',
    allowedMethods,
  };
}
