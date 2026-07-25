/**
 * Routes exempt from the HTML-poison guard because they serve raw file bytes.
 *
 * WHY: `GET /api/fs/read/*` serves arbitrary file bytes and sets `Content-Type` from the file extension
 * at runtime. Therefore, `text/html` from it is legitimate user data, not an SPA fallback.
 * Verified live curl result:
 * `GET http://127.0.0.1:4700/api/fs/read/<repo-relative-path>.html?location%5Bdirectory%5D=/home/dev/projects/workstation` -> 200 Content-Type: text/html, 2884 bytes.
 * Note explicitly that `/doc`'s declared `application/octet-stream` is what makes this route identifiable,
 * and that Check C cannot catch this class because the declaration is octet-stream forever.
 */
export const HTML_GUARD_EXEMPT_ROUTES: string[] = ['GET /api/fs/read/*'];

/**
 * Returns true if the (method, pathname) matches any route in HTML_GUARD_EXEMPT_ROUTES.
 *
 * Compares method case-insensitively.
 * A trailing '*' in an exemption entry is treated as a path-prefix wildcard requiring a trailing slash.
 * E.g., 'GET /api/fs/read/*' matches 'GET /api/fs/read/foo.html', but NOT 'GET /api/fs/readsomething'.
 */
export function isHtmlGuardExempt(method: string, pathname: string): boolean {
  const normMethod = method.toUpperCase();
  const normPath = pathname.split('?')[0];

  for (const entry of HTML_GUARD_EXEMPT_ROUTES) {
    const spaceIdx = entry.indexOf(' ');
    if (spaceIdx === -1) continue;
    const entryMethod = entry.slice(0, spaceIdx).toUpperCase();
    const entryPath = entry.slice(spaceIdx + 1);

    if (normMethod !== entryMethod) {
      continue;
    }

    if (entryPath.endsWith('*')) {
      const prefix = entryPath.slice(0, -1);
      if (normPath.startsWith(prefix)) {
        return true;
      }
    } else if (normPath === entryPath || normPath === entryPath + '/') {
      return true;
    }
  }

  return false;
}

/**
 * Returns true if the Content-Type header represents an HTML response (`text/html`).
 *
 * Performs exact media-type matching (case-insensitive, ignoring parameters such as `charset`).
 *
 * NOTE: Unlike `isEventStreamResponse`, this function MUST NOT use prefix matching (`startsWith`),
 * because `text/htmlx` or other media types starting with `text/html` must not false-positive.
 */
export function isHtmlResponse(contentType: string | string[] | undefined): boolean {
  if (!contentType) {
    return false;
  }
  const rawValue = Array.isArray(contentType) ? contentType[0] : contentType;
  if (typeof rawValue !== "string") {
    return false;
  }
  const mediaType = rawValue.split(";")[0].trim().toLowerCase();
  return mediaType === "text/html";
}
