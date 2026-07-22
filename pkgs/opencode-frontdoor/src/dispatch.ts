import { ROUTE_CLASSIFICATION_TABLE, RouteClass } from './routes.classification.js';

export type RouteAction =
  | 'route-session'
  | 'create'
  | 'fork'
  | 'pty-501'
  | 'tui-501'
  | 'forward-anchor'
  | 'deny-global-mutation'
  | 'gone-410'
  | 'not-found-404';

function normalizePath(p: string): string {
  let path = p.split('?')[0];
  if (path.endsWith('/') && path !== '/') {
    path = path.slice(0, -1);
  }
  return path;
}

function compilePathTemplate(normalizedPath: string): RegExp {
  // 1. Escape regex special characters
  let escaped = normalizedPath.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  // 2. Replace escaped `{token}` with `[^/]+`
  escaped = escaped.replace(/\\\{.*?\\\}/g, '[^/]+');
  // 3. Replace escaped `*` with `.*`
  escaped = escaped.replace(/\\\*/g, '.*');

  return new RegExp(`^${escaped}$`);
}

// Precompute structures at module load
const exactRoutes = new Map<string, RouteClass>();
const patternRoutes: Array<{ method: string; regex: RegExp; class: RouteClass }> = [];
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
    });
  } else {
    const existing = exactRoutes.get(key);
    if (existing && existing !== entry.class) {
      throw new Error(`Table bug: Duplicate route key "${key}" has conflicting classes "${existing}" and "${entry.class}"`);
    }
    exactRoutes.set(key, entry.class);
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

export function classify(method: string, pathname: string): RouteClass {
  const normalizedMethod = method.toUpperCase();
  const normalizedPath = normalizePath(pathname);

  // 1. Exact match first
  const key = `${normalizedMethod} ${normalizedPath}`;
  const exactClass = exactRoutes.get(key);
  if (exactClass) {
    return exactClass;
  }

  // 2. Pattern match next. First match wins, in ROUTE_CLASSIFICATION_TABLE
  // order. Today the templated routes are non-overlapping so order is
  // immaterial; if an overlapping pattern is ever added (e.g. a broad
  // catch-all), its placement in the table decides precedence — keep the more
  // specific pattern earlier.
  for (const pattern of patternRoutes) {
    if (pattern.method === normalizedMethod && pattern.regex.test(normalizedPath)) {
      return pattern.class;
    }
  }

  // If HEAD, retry classification as GET
  if (normalizedMethod === "HEAD") {
    return classify("GET", pathname);
  }

  // 3. Fallback to unrecognized
  return 'unrecognized';
}

export function dispatch(method: string, pathname: string): {
  class: RouteClass;
  action: RouteAction;
  recognized: boolean;
  allowedMethods: string[];
} {
  const cls = classify(method, pathname);
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
      action = 'forward-anchor';
      break;
    case 'global-sideeffect':
      action = 'deny-global-mutation';
      break;
    case 'global-event':
      action = 'gone-410';
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
