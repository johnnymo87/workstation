import { ROUTE_CLASSIFICATION_TABLE, RouteClass } from './routes.classification.js';

export type RouteAction =
  | 'route-session'
  | 'create'
  | 'fork'
  | 'pty-501'
  | 'tui-501'
  | 'forward-anchor'
  | 'deny-405'
  | 'gone-410'
  | 'not-found-404';

function normalizePath(p: string): string {
  let path = p.split('?')[0];
  if (path.endsWith('/') && path !== '/') {
    path = path.slice(0, -1);
  }
  return path;
}

// Precompute structures at module load
const exactRoutes = new Map<string, RouteClass>();
const patternRoutes: Array<{ method: string; regex: RegExp; class: RouteClass }> = [];

for (const entry of ROUTE_CLASSIFICATION_TABLE) {
  const normalizedPath = normalizePath(entry.path);
  const upperMethod = entry.method.toUpperCase();
  const key = `${upperMethod} ${normalizedPath}`;

  const isPattern = normalizedPath.includes('{') || normalizedPath.includes('*');

  if (isPattern) {
    // Compile regex
    // 1. Escape regex special characters
    let escaped = normalizedPath.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    // 2. Replace escaped `{token}` with `[^/]+`
    escaped = escaped.replace(/\\\{.*?\\\}/g, '[^/]+');
    // 3. Replace escaped `*` with `.*`
    escaped = escaped.replace(/\\\*/g, '.*');

    const regex = new RegExp(`^${escaped}$`);
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
      action = 'deny-405';
      break;
    case 'global-event':
      action = 'gone-410';
      break;
    case 'web-ui':
    case 'unrecognized':
      action = 'not-found-404';
      break;
  }

  return {
    class: cls,
    action,
    recognized: cls !== 'unrecognized',
  };
}
