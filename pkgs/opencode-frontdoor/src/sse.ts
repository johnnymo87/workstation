import type http from "node:http";

export interface SSEHooks {
  onDone: () => void;
}

/**
 * Returns true if the Content-Type header starts with text/event-stream (case-insensitively).
 * Relies on Node's lowercased header keys and performs case-insensitive value matching.
 */
export function isEventStreamResponse(headers: http.IncomingHttpHeaders): boolean {
  // Node types (and delivers) `content-type` as a single `string | undefined` on
  // an IncomingMessage — it's a singleton header, never an array — so a direct
  // lookup is sufficient. Case-insensitivity that matters is on the value.
  const contentType = headers["content-type"];
  return typeof contentType === "string"
    && contentType.trim().toLowerCase().startsWith("text/event-stream");
}

/**
 * Streams the upstream SSE response body to the client unbuffered.
 * Monitors connection teardown cleanly, releasing sockets and coordinating completion.
 */
export function pipeEventStream(
  upstreamRes: http.IncomingMessage,
  clientRes: http.ServerResponse,
  hooks: SSEHooks
): void {
  // P2-W1: Check if client vanished before upstream responded
  if (clientRes.writableEnded || clientRes.destroyed) {
    upstreamRes.destroy();
    hooks.onDone();
    return;
  }

  // The owner-drift monitor needs access to:
  // - clientRes (to close/end the client stream if drift is detected)
  // - upstreamRes (to destroy and release the socket if drift is detected)
  // (Activity tracking was removed; Phase 3.4 uses forwarded-request stickiness).

  let finished = false;

  const safeDone = () => {
    if (finished) return;
    finished = true;

    // Remove listeners to avoid memory leaks or duplicate done calls
    upstreamRes.off("error", onUpstreamError);
    upstreamRes.off("end", onUpstreamEnd);
    clientRes.off("close", onClientClose);

    hooks.onDone();
  };

  const onUpstreamError = (_err: any) => {
    clientRes.destroy();
    safeDone();
  };

  const onUpstreamEnd = () => {
    safeDone();
  };

  const onClientClose = () => {
    if (!clientRes.writableEnded) {
      upstreamRes.destroy();
    }
    safeDone();
  };

  upstreamRes.on("error", onUpstreamError);
  upstreamRes.on("end", onUpstreamEnd);
  clientRes.on("close", onClientClose);

  // We choose upstreamRes.pipe(clientRes) because:
  // 1. Node's native .pipe() is highly optimized and naturally unbuffered (each chunk is immediately written).
  // 2. It handles backpressure correctly out of the box (pausing and resuming upstreamRes as clientRes drains),
  //    which is much more robust and safer than a manual 'data' -> 'write' loop without backpressure checks.
  upstreamRes.pipe(clientRes);
}
