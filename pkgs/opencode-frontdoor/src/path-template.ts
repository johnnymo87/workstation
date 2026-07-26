/**
 * Shared path-template primitives.
 *
 * These two functions were previously copy-pasted in three places (`dispatch.ts`,
 * `route-gate.ts`, and `test/dispatch.test.ts`). They were byte-identical, but
 * three copies of the rule that decides "does this concrete request path match
 * this `/doc` template?" is exactly the drift generator this project keeps
 * getting bitten by: a fix applied to one copy silently leaves the classifier
 * and the gate disagreeing, and the gate is what proves the classifier honest.
 *
 * Consolidated 2026-07-26 while adding a fourth caller (runtime disposition
 * lookup in `routes.dispositions.ts`, which needs to resolve a CONCRETE request
 * path against TEMPLATE-keyed dispositions).
 */

/** Strip any query string and one trailing slash (but never reduce "/" to ""). */
export function normalizePath(p: string): string {
  let path = p.split('?')[0];
  if (path.endsWith('/') && path !== '/') {
    path = path.slice(0, -1);
  }
  return path;
}

/**
 * Compile a normalized `/doc`-style template into an anchored matcher.
 *
 * `{token}` matches exactly one path segment (`[^/]+`, so it cannot span `/`),
 * and `*` matches greedily across segments (`.*`, used by `/api/fs/read/*`).
 * Everything else is escaped literally.
 */
export function compilePathTemplate(normalizedPath: string): RegExp {
  // 1. Escape regex special characters
  let escaped = normalizedPath.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  // 2. Replace escaped `{token}` with `[^/]+`
  escaped = escaped.replace(/\\\{.*?\\\}/g, '[^/]+');
  // 3. Replace escaped `*` with `.*`
  escaped = escaped.replace(/\\\*/g, '.*');

  return new RegExp(`^${escaped}$`);
}

/** True when a normalized path contains template syntax rather than being concrete. */
export function isTemplatePath(normalizedPath: string): boolean {
  return normalizedPath.includes('{') || normalizedPath.includes('*');
}
