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

  return false;
}
