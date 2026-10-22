import { extractSessionIdFromPath, type SidExtraction } from "./sid.js";

const EXEMPT_SUFFIXES = new Set([
  "message",
  "prompt",
  "prompt_async",
  "compact",
  "shell",
  "command",
  "summarize",
  "init",
  "wait"
]);

/**
 * Pure function to classify if an incoming request is exempt from the cheap first-byte timeout.
 * Rationale:
 * - Turn-starting/streaming session POSTs (e.g. message, prompt, prompt_async, compact, shell, command, summarize, init)
 *   can legitimately block before sending response headers because they stream AI responses.
 * - POST /session/{id}/wait (and its /api/ mirror) blocks until the agent loop goes idle, returning 204 only at turn end.
 * - POST /session/{id}/mcp/{name}/connect blocks until the MCP server has started and listed its tools.
 *
 * NOTE on /tui/control/next: This is a long-poll route, but all /tui/* endpoints are reclassified
 * as a deny (501 Not Implemented) in routes.classification.ts. Since they are never forwarded, they
 * do not need to be in the exempt set here.
 */
export function isExemptFromFirstByteTimeout(
  method: string,
  pathname: string,
  extraction: SidExtraction | null
): boolean {
  if (!extraction || extraction.kind !== "single") {
    return false;
  }

  const upperMethod = method.toUpperCase();
  if (upperMethod !== "POST") {
    return false;
  }

  const pathCandidate = extractSessionIdFromPath(pathname);
  if (!pathCandidate || pathCandidate !== extraction.sid) {
    return false;
  }

  const normalizedPath = pathname.replace(/\/$/, "");
  const segments = normalizedPath.split("/").filter(Boolean);
  const lastSegment = segments[segments.length - 1];

  if (lastSegment && EXEMPT_SUFFIXES.has(lastSegment)) {
    return true;
  }

  // POST /session/{id}/mcp/{name}/connect (and its /api/ mirror). The serve
  // answers only after it has spawned the MCP server and finished initialize
  // + tools/list, which for a remote-backed server (atlassian: npx mcp-remote
  // -> mcp.atlassian.com) is bounded by the upstream, not by the serve. Healthy
  // atlassian connects measured 1.2-4.5 s over 30 days, so the 5 s cheap
  // timeout turned every slow-upstream day into a 503 that callers read as
  // "pigeon down", and (POST is not detachable) destroyed the in-flight
  // connect so the serve never recorded the real error. The wedge probe still
  // covers a frozen serve; the caller's own deadline bounds the rest.
  const n = segments.length;
  if (
    n >= 4 &&
    lastSegment === "connect" &&
    segments[n - 3] === "mcp" &&
    segments[n - 4] === extraction.sid
  ) {
    return true;
  }

  return false;
}
