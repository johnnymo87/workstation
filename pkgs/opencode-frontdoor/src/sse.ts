import type http from "node:http";

export interface SSEHooks {
  onActivity: () => void;
  onDone: () => void;
}

/**
 * Returns true if the Content-Type header starts with text/event-stream (case-insensitively).
 * Relies on Node's lowercased header keys and performs case-insensitive value matching.
 */
export function isEventStreamResponse(headers: http.IncomingHttpHeaders): boolean {
  const contentType = headers["content-type"] as unknown;
  if (typeof contentType === "string") {
    return contentType.trim().toLowerCase().startsWith("text/event-stream");
  }
  if (Array.isArray(contentType)) {
    return contentType.some((v) => typeof v === "string" && v.trim().toLowerCase().startsWith("text/event-stream"));
  }
  return false;
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
  // Task 2.2 will start an owner-drift monitor here. The monitor needs access to:
  // - clientRes (to close/end the client stream if drift is detected)
  // - upstreamRes (to destroy and release the socket if drift is detected)
  // - activity state (via hooks.onActivity callback or a local tracker)

  let finished = false;

  const safeDone = () => {
    if (finished) return;
    finished = true;

    // Remove listeners to avoid memory leaks or duplicate done calls
    upstreamRes.off("data", onData);
    upstreamRes.off("error", onUpstreamError);
    upstreamRes.off("end", onUpstreamEnd);
    clientRes.off("close", onClientClose);

    hooks.onDone();
  };

  const onData = (_chunk: Buffer) => {
    hooks.onActivity();
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

  upstreamRes.on("data", onData);
  upstreamRes.on("error", onUpstreamError);
  upstreamRes.on("end", onUpstreamEnd);
  clientRes.on("close", onClientClose);

  // We choose upstreamRes.pipe(clientRes) because:
  // 1. Node's native .pipe() is highly optimized and naturally unbuffered (each chunk is immediately written).
  // 2. It handles backpressure correctly out of the box (pausing and resuming upstreamRes as clientRes drains),
  //    which is much more robust and safer than a manual 'data' -> 'write' loop without backpressure checks.
  // 3. We can easily and cleanly observe activity by registering a parallel 'data' listener on upstreamRes.
  upstreamRes.pipe(clientRes);
}
