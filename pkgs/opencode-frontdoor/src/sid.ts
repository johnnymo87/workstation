/**
 * Pure, dependency-free URL-parsing module.
 * Extracts session ID(s) targeted by a request and validates them against the pigeon sid regex.
 */

export type SidExtraction =
  | { kind: "none" }                       // no sid in this request (create, globals, /session/status)
  | { kind: "single"; sid: string }        // exactly one valid sid (path, ?session=, or 1-element session_ids)
  | { kind: "multi"; sids: string[] }      // >1 valid sids from session_ids (owner-agreement decided downstream)
  | { kind: "malformed" };                 // a sid candidate was present but failed ^ses_...$ (or session_ids had a bad member)

// Pigeon's /route and /place verified-solid session ID validation regex.
const SID_REGEX = /^ses_[A-Za-z0-9_-]+$/;

/**
 * Extracts and validates session IDs from the request method and URL.
 *
 * Path extraction has strict precedence over query parameter extraction.
 *
 * @param method - The HTTP request method (e.g. 'GET', 'POST').
 * @param url - The WHATWG URL object for the incoming request.
 */
export function extractSids(method: string, url: URL): SidExtraction {
  const pathname = url.pathname;

  // 1. Explicitly bypass routes that do not contain a session ID target
  if (pathname === '/session/status' || pathname === '/api/session/status') {
    return { kind: 'none' };
  }

  // 2. Extract from Path (Bare, /api mirror, nested paths, or experimental)
  // Match bare and /api mirror: /session/{sessionID} or /api/session/{sessionID}
  // The first capture group extracts the session ID segment.
  const sessionPathMatch = pathname.match(/^\/(?:api\/)?session\/([^/]+)(?:\/|$)/);

  // Match experimental background path: /experimental/session/{sessionID}/background
  const experimentalMatch = pathname.match(/^\/(?:api\/)?experimental\/session\/([^/]+)\/background$/);

  const pathCandidate = sessionPathMatch?.[1] || experimentalMatch?.[1];

  if (pathCandidate !== undefined) {
    if (SID_REGEX.test(pathCandidate)) {
      return { kind: 'single', sid: pathCandidate };
    } else {
      return { kind: 'malformed' };
    }
  }

  // 3. Fallback to Query Parameters (session_ids or session) if no path-based candidate exists
  const sessionIdsParam = url.searchParams.get('session_ids');
  if (sessionIdsParam !== null) {
    // Split by comma, trim spaces, and drop empty elements
    const parts = sessionIdsParam.split(',')
      .map(part => part.trim())
      .filter(part => part.length > 0);

    if (parts.length === 0) {
      return { kind: 'none' };
    }

    const validSids: string[] = [];
    for (const part of parts) {
      if (SID_REGEX.test(part)) {
        validSids.push(part);
      } else {
        // Any single malformed member makes the entire request malformed (fail-safe)
        return { kind: 'malformed' };
      }
    }

    if (validSids.length === 1) {
      return { kind: 'single', sid: validSids[0] };
    } else {
      return { kind: 'multi', sids: validSids };
    }
  }

  const sessionParam = url.searchParams.get('session');
  if (sessionParam !== null) {
    const trimmed = sessionParam.trim();
    if (trimmed.length === 0) {
      return { kind: 'none' };
    }

    if (SID_REGEX.test(trimmed)) {
      return { kind: 'single', sid: trimmed };
    } else {
      return { kind: 'malformed' };
    }
  }

  return { kind: 'none' };
}
