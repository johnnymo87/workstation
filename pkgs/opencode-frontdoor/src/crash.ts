/**
 * Policy: process-level crash backstop.
 *
 * - uncaughtException:
 *   After an uncaught exception, the process state is undefined (Node guidance).
 *   We log the error loudly with [FRONTDOOR FATAL] and exit(1) to let systemd
 *   Restart=always bring the service back up cleanly. In-flight streams/connections
 *   are already lost or in undefined state anyway; fast recovery is preferred over
 *   preservation of corrupted state.
 *
 * - unhandledRejection:
 *   A stray background Promise rejection should not nuke all active client sessions on
 *   the frontdoor (which is a SPOF). We log the reason loudly with [FRONTDOOR WARN]
 *   and continue execution.
 *
 * Note: Per-stream errors (e.g. proxying or SSE client disconnected) are already handled
 * cleanly in proxy.ts and sse.ts. This is a global process-level safety backstop.
 */
export function installCrashHandlers(deps?: {
  proc?: any;
  log?: (message?: any, ...optionalParams: any[]) => void;
  exit?: (code?: number) => never | void;
}): void {
  const proc = deps?.proc || process;
  const log = deps?.log || console.error;
  const exit = deps?.exit || process.exit;

  proc.on("uncaughtException", (err: any) => {
    log("[FRONTDOOR FATAL] Uncaught Exception:", err);
    exit(1);
  });

  proc.on("unhandledRejection", (reason: any) => {
    log("[FRONTDOOR WARN] Unhandled Promise Rejection:", reason);
  });
}
