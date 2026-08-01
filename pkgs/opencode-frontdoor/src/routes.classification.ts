/**
 * Route Classification Table for opencode-frontdoor.
 *
 * --- RECONCILIATION ---
 * DO NOT hand-reconcile route counts here again. The route gate (`src/route-gate.ts`)
 * supersedes `routes.snapshot.txt`'s reconciliation role: it boots the PINNED opencode,
 * reads its `/doc`, and mechanically verifies every declared path x method against
 * `classify()` (Check A) and every denial against `routes.dispositions.ts` (Check B).
 * The hand-maintained totals that used to live here are gone deliberately — they were
 * the artifact that required reconciling.
 *
 * Where it runs (be precise; there is NO CI job for this):
 *   - Authoritative: the nix check derivation `route-gate.nix`, wired into the
 *     home-manager closure at `users/dev/home.base.nix` (cloudbox only). It depends on
 *     BOTH the pinned opencode and this package, so a pin bump or a table edit re-runs
 *     it, and `home-manager switch` cannot succeed while it fails.
 *   - On demand: `./test.sh` (pre-deploy developer signal for the same check).
 * Design: docs/plans/2026-07-25-j6de-doc-classification-gate.md
 *
 * --- DUAL SURFACE ---
 * This API exposes a dual surface: a bare surface (e.g. /session/...) and its `/api/*` mirror.
 * Both paths are fully mapped and classified.
 *
 * --- PATCH SOURCE ---
 * - `session_ids` is patch-only:
 *   Source: ~/projects/opencode-patched/patches/event-session-scope.patch
 * - Session-scoped permission/question routes are patch-only:
 *   Source: ~/projects/opencode-patched/patches/session-door-routes.patch
 * - Session-scoped MCP routes are patch-only:
 *   Source: ~/projects/opencode-patched/patches/session-mcp-routes.patch
 */

/*
 * NEW-D Scope Statement (see the `web-ui` member below):
 * The web UI (`packages/app`, a PTY client served at `/`) is UNSUPPORTED through the front door;
 * `/` explicitly classifies as `web-ui` (rather than falling through to `unrecognized`), while
 * static assets remain `unrecognized` -> 404-loud
 * (and PTY -> 501, per Task 5.1). Use direct serve ports to access the web UI.
 */
export type RouteClass =
  | "session-path"
  | "session-query"
  | "create"
  | "fork"
  | "pty"
  | "global-ro"
  | "global-sideeffect"
  | "global-event"
  | "web-ui"
  | "tui"
  | "per-process-ro"
  | "unrecognized";

export interface RouteEntry {
  method: string;
  path: string;
  class: RouteClass;
  /**
   * Opt-in: this read is POOL-INVARIANT and may be served by any member of the
   * serve pool, not just the anchor (bead workstation-eon4).
   *
   * OPT-IN, NEVER CLASS-WIDE. `global-ro` is NOT uniformly pool-invariant —
   * several entries below read PER-PROCESS in-memory state and are marked
   * FABLE-P5-F2. Absent this flag a route forwards to the anchor exactly as
   * before, so a NEWLY ADDED route is anchor-pinned (safe) by construction and
   * spreading is always a deliberate, reviewed act.
   *
   * Standard for flagging: invariance must be MEASURED across live members,
   * not argued from configuration; per-process caches (not cwd) are the
   * divergence mechanism — see workstation-g8k9.
   * Note: the three templated routes (/api/provider/{providerID},
   * /api/integration/{integrationID}, /project/{projectID}/directories) were
   * not individually diffed (they need real IDs); they are flagged on the
   * strength of their collection endpoints agreeing.
   * When unsure, do not flag; the cost of a wrong flag (silent divergence by
   * member) far exceeds the cost of one route still on the anchor.
   */
  poolSafe?: boolean;
  note?: string;
}

export const ROUTE_CLASSIFICATION_TABLE: RouteEntry[] = [
  { method: "GET", path: "/", class: "web-ui" },
  { method: "GET", path: "/agent", class: "global-ro" },
  { method: "GET", path: "/api/agent", class: "global-ro", poolSafe: true, note: "POOL-SAFE (eon4): verified by cross-member diff on 2026-08-01" },
  { method: "GET", path: "/api/command", class: "global-ro", poolSafe: true, note: "POOL-SAFE (eon4): verified by cross-member diff on 2026-08-01" },
  { method: "DELETE", path: "/api/credential/{credentialID}", class: "global-sideeffect" },
  { method: "PATCH", path: "/api/credential/{credentialID}", class: "global-sideeffect" },
  { method: "GET", path: "/api/event", class: "session-query", note: "Can receive session_ids query param (source: event-session-scope.patch)" },
  { method: "GET", path: "/api/event?session_ids=", class: "session-query", note: "patch-only session-query (source: event-session-scope.patch)" },
  { method: "GET", path: "/api/fs/find", class: "global-ro" },
  { method: "GET", path: "/api/fs/list", class: "global-ro" },
  { method: "GET", path: "/api/fs/read/*", class: "global-ro" },
  { method: "GET", path: "/api/health", class: "global-ro" },
  { method: "GET", path: "/api/integration", class: "global-ro", poolSafe: true, note: "POOL-SAFE (eon4): verified by cross-member diff on 2026-08-01" },
  { method: "GET", path: "/api/integration/{integrationID}", class: "global-ro", poolSafe: true, note: "POOL-SAFE (eon4): verified by cross-member diff on 2026-08-01" },
  { method: "POST", path: "/api/integration/{integrationID}/connect/key", class: "global-sideeffect" },
  { method: "POST", path: "/api/integration/{integrationID}/connect/oauth", class: "global-sideeffect" },
  { method: "DELETE", path: "/api/integration/attempt/{attemptID}", class: "global-sideeffect" },
  { method: "GET", path: "/api/integration/attempt/{attemptID}", class: "global-ro" },
  { method: "POST", path: "/api/integration/attempt/{attemptID}/complete", class: "global-sideeffect" },
  { method: "GET", path: "/api/location", class: "global-ro", poolSafe: true, note: "POOL-SAFE (eon4): verified by cross-member diff on 2026-08-01" },
  { method: "GET", path: "/api/model", class: "global-ro", poolSafe: true, note: "POOL-SAFE (eon4): verified by cross-member diff on 2026-08-01" },
  { method: "GET", path: "/api/permission/request", class: "global-ro", note: "FABLE-P5-F2: reads PER-PROCESS in-memory pending requests; door->anchor returns only the anchor's view. Latent (no through-door consumer today); revisit before Phase 7/9." },
  { method: "GET", path: "/api/permission/saved", class: "global-ro" },
  { method: "DELETE", path: "/api/permission/saved/{id}", class: "global-sideeffect" },
  { method: "GET", path: "/api/provider", class: "global-ro", poolSafe: true, note: "POOL-SAFE (eon4): verified by cross-member diff on 2026-08-01" },
  { method: "GET", path: "/api/provider/{providerID}", class: "global-ro", poolSafe: true, note: "POOL-SAFE (eon4): verified by cross-member diff on 2026-08-01" },
  { method: "GET", path: "/api/pty", class: "pty" },
  { method: "POST", path: "/api/pty", class: "pty" },
  { method: "DELETE", path: "/api/pty/{ptyID}", class: "pty" },
  { method: "GET", path: "/api/pty/{ptyID}", class: "pty" },
  { method: "PUT", path: "/api/pty/{ptyID}", class: "pty" },
  { method: "GET", path: "/api/pty/{ptyID}/connect", class: "pty" },
  { method: "POST", path: "/api/pty/{ptyID}/connect-token", class: "pty" },
  { method: "GET", path: "/api/question/request", class: "global-ro", note: "FABLE-P5-F2: reads PER-PROCESS in-memory pending requests; door->anchor returns only the anchor's view. Latent; revisit before Phase 7/9." },
  { method: "GET", path: "/api/reference", class: "global-ro", poolSafe: true, note: "POOL-SAFE (eon4): verified by cross-member diff on 2026-08-01" },
  { method: "GET", path: "/api/session", class: "global-ro" },
  { method: "POST", path: "/api/session", class: "create" },
  { method: "GET", path: "/api/session/{sessionID}", class: "session-path" },
  { method: "POST", path: "/api/session/{sessionID}/agent", class: "session-path" },
  { method: "POST", path: "/api/session/{sessionID}/compact", class: "session-path" },
  { method: "GET", path: "/api/session/{sessionID}/context", class: "session-path" },
  { method: "GET", path: "/api/session/{sessionID}/event", class: "session-path" },
  { method: "GET", path: "/api/session/{sessionID}/history", class: "session-path" },
  { method: "POST", path: "/api/session/{sessionID}/interrupt", class: "session-path" },
  { method: "GET", path: "/api/session/{sessionID}/message", class: "session-path" },
  { method: "GET", path: "/api/session/{sessionID}/message/{messageID}", class: "session-path" },
  { method: "POST", path: "/api/session/{sessionID}/model", class: "session-path" },
  { method: "GET", path: "/api/session/{sessionID}/permission", class: "session-path" },
  { method: "POST", path: "/api/session/{sessionID}/permission", class: "session-path" },
  { method: "GET", path: "/api/session/{sessionID}/permission/{requestID}", class: "session-path" },
  { method: "POST", path: "/api/session/{sessionID}/permission/{requestID}/reply", class: "session-path" },
  { method: "POST", path: "/api/session/{sessionID}/prompt", class: "session-path" },
  { method: "GET", path: "/api/session/{sessionID}/question", class: "session-path" },
  { method: "POST", path: "/api/session/{sessionID}/question/{requestID}/reject", class: "session-path" },
  { method: "POST", path: "/api/session/{sessionID}/question/{requestID}/reply", class: "session-path" },
  { method: "POST", path: "/api/session/{sessionID}/revert/clear", class: "session-path" },
  { method: "POST", path: "/api/session/{sessionID}/revert/commit", class: "session-path" },
  { method: "POST", path: "/api/session/{sessionID}/revert/stage", class: "session-path" },
  { method: "POST", path: "/api/session/{sessionID}/wait", class: "session-path" },
  { method: "GET", path: "/api/session/active", class: "global-ro" },
  { method: "GET", path: "/api/skill", class: "global-ro", poolSafe: true, note: "POOL-SAFE (eon4): verified by cross-member diff on 2026-08-01" },
  { method: "DELETE", path: "/auth/{providerID}", class: "global-sideeffect" },
  { method: "PUT", path: "/auth/{providerID}", class: "global-sideeffect" },
  { method: "GET", path: "/command", class: "global-ro" },
  { method: "GET", path: "/config", class: "global-ro" },
  { method: "PATCH", path: "/config", class: "global-sideeffect" },
  { method: "GET", path: "/config/providers", class: "global-ro" },
  { method: "GET", path: "/doc", class: "global-ro", poolSafe: true, note: "POOL-SAFE (eon4): verified by cross-member diff on 2026-08-01 (FABLE-W6)" },
  { method: "GET", path: "/event", class: "session-query", note: "Can receive session_ids query param (source: event-session-scope.patch)" },
  { method: "GET", path: "/event?session_ids=", class: "session-query", note: "patch-only session-query (source: event-session-scope.patch)" },
  { method: "GET", path: "/experimental/capabilities", class: "global-ro", poolSafe: true, note: "POOL-SAFE (eon4): verified by cross-member diff on 2026-08-01" },
  { method: "GET", path: "/experimental/console", class: "global-ro" },
  { method: "GET", path: "/experimental/console/orgs", class: "global-ro" },
  { method: "POST", path: "/experimental/console/switch", class: "global-sideeffect" },
  { method: "POST", path: "/experimental/control-plane/move-session", class: "global-sideeffect" },
  { method: "DELETE", path: "/experimental/project/{projectID}/copy", class: "global-sideeffect" },
  { method: "POST", path: "/experimental/project/{projectID}/copy", class: "global-sideeffect" },
  { method: "POST", path: "/experimental/project/{projectID}/copy/generate-name", class: "global-sideeffect" },
  { method: "POST", path: "/experimental/project/{projectID}/copy/refresh", class: "global-sideeffect" },
  { method: "GET", path: "/experimental/resource", class: "global-ro" },
  { method: "GET", path: "/experimental/session", class: "global-ro" },
  { method: "POST", path: "/experimental/session/{sessionID}/background", class: "session-path" },
  { method: "GET", path: "/experimental/tool", class: "global-ro" },
  { method: "GET", path: "/experimental/tool/ids", class: "global-ro" },
  { method: "GET", path: "/experimental/workspace", class: "global-ro" },
  { method: "POST", path: "/experimental/workspace", class: "global-sideeffect" },
  { method: "DELETE", path: "/experimental/workspace/{id}", class: "global-sideeffect" },
  { method: "GET", path: "/experimental/workspace/adapter", class: "global-ro" },
  { method: "GET", path: "/experimental/workspace/status", class: "global-ro" },
  { method: "POST", path: "/experimental/workspace/sync-list", class: "global-sideeffect" },
  { method: "POST", path: "/experimental/workspace/warp", class: "global-sideeffect" },
  { method: "DELETE", path: "/experimental/worktree", class: "global-sideeffect" },
  { method: "GET", path: "/experimental/worktree", class: "global-ro" },
  { method: "POST", path: "/experimental/worktree", class: "global-sideeffect" },
  { method: "POST", path: "/experimental/worktree/reset", class: "global-sideeffect" },
  { method: "GET", path: "/file", class: "global-ro" },
  { method: "GET", path: "/file/content", class: "global-ro" },
  { method: "GET", path: "/file/status", class: "global-ro" },
  { method: "GET", path: "/find", class: "global-ro" },
  { method: "GET", path: "/find/file", class: "global-ro" },
  { method: "GET", path: "/find/symbol", class: "global-ro" },
  { method: "GET", path: "/formatter", class: "global-ro" },
  { method: "GET", path: "/global/config", class: "global-ro" },
  { method: "PATCH", path: "/global/config", class: "global-sideeffect" },
  { method: "POST", path: "/global/dispose", class: "global-sideeffect" },
  { method: "GET", path: "/global/event", class: "global-event" },
  { method: "GET", path: "/global/health", class: "global-ro" },
  { method: "POST", path: "/global/upgrade", class: "global-sideeffect" },
  { method: "POST", path: "/instance/dispose", class: "global-sideeffect" },
  { method: "POST", path: "/log", class: "global-sideeffect" },
  { method: "GET", path: "/lsp", class: "global-ro" },
  { method: "GET", path: "/mcp", class: "per-process-ro", note: "F3: reports PER-PROCESS MCP connection status. Unsupported/denied (501) through the front door." },
  { method: "POST", path: "/mcp", class: "global-sideeffect" },
  { method: "DELETE", path: "/mcp/{name}/auth", class: "global-sideeffect" },
  { method: "POST", path: "/mcp/{name}/auth", class: "global-sideeffect" },
  { method: "POST", path: "/mcp/{name}/auth/authenticate", class: "global-sideeffect" },
  { method: "POST", path: "/mcp/{name}/auth/callback", class: "global-sideeffect" },
  { method: "POST", path: "/mcp/{name}/connect", class: "global-sideeffect" },
  { method: "POST", path: "/mcp/{name}/disconnect", class: "global-sideeffect" },
  { method: "GET", path: "/path", class: "global-ro", poolSafe: true, note: "POOL-SAFE (eon4): verified by cross-member diff on 2026-08-01" },
  { method: "GET", path: "/permission", class: "global-ro", note: "FABLE-P5-F2: reads PER-PROCESS in-memory pending requests; door->anchor returns only the anchor's view. Latent; revisit before Phase 7/9." },
  { method: "POST", path: "/permission/{requestID}/reply", class: "global-sideeffect" },
  { method: "GET", path: "/project", class: "global-ro", poolSafe: true, note: "POOL-SAFE (eon4): verified by cross-member diff on 2026-08-01" },
  { method: "PATCH", path: "/project/{projectID}", class: "global-sideeffect" },
  { method: "GET", path: "/project/{projectID}/directories", class: "global-ro", poolSafe: true, note: "POOL-SAFE (eon4): verified by cross-member diff on 2026-08-01" },
  { method: "GET", path: "/project/current", class: "global-ro" },
  { method: "POST", path: "/project/git/init", class: "global-sideeffect" },
  { method: "GET", path: "/provider", class: "global-ro" },
  { method: "POST", path: "/provider/{providerID}/oauth/authorize", class: "global-sideeffect" },
  { method: "POST", path: "/provider/{providerID}/oauth/callback", class: "global-sideeffect" },
  { method: "GET", path: "/provider/auth", class: "global-ro", poolSafe: true, note: "POOL-SAFE (eon4): verified by cross-member diff on 2026-08-01" },
  { method: "GET", path: "/pty", class: "pty" },
  { method: "POST", path: "/pty", class: "pty" },
  { method: "DELETE", path: "/pty/{ptyID}", class: "pty" },
  { method: "GET", path: "/pty/{ptyID}", class: "pty" },
  { method: "PUT", path: "/pty/{ptyID}", class: "pty" },
  { method: "GET", path: "/pty/{ptyID}/connect", class: "pty" },
  { method: "POST", path: "/pty/{ptyID}/connect-token", class: "pty" },
  { method: "GET", path: "/pty/shells", class: "pty" },
  { method: "GET", path: "/question", class: "global-ro", note: "FABLE-P5-F2: reads PER-PROCESS in-memory pending requests; door->anchor returns only the anchor's view. Latent; revisit before Phase 7/9." },
  { method: "POST", path: "/question/{requestID}/reject", class: "global-sideeffect" },
  { method: "POST", path: "/question/{requestID}/reply", class: "global-sideeffect" },
  { method: "GET", path: "/session", class: "global-ro" },
  { method: "POST", path: "/session", class: "create" },
  { method: "DELETE", path: "/session/{sessionID}", class: "session-path" },
  { method: "GET", path: "/session/{sessionID}", class: "session-path" },
  { method: "PATCH", path: "/session/{sessionID}", class: "session-path" },
  { method: "POST", path: "/session/{sessionID}/abort", class: "session-path" },
  { method: "GET", path: "/session/{sessionID}/children", class: "session-path" },
  { method: "POST", path: "/session/{sessionID}/command", class: "session-path" },
  { method: "GET", path: "/session/{sessionID}/diff", class: "session-path" },
  { method: "POST", path: "/session/{sessionID}/fork", class: "fork" },
  { method: "POST", path: "/session/{sessionID}/init", class: "session-path" },
  { method: "GET", path: "/session/{sessionID}/mcp", class: "session-path", note: "Response is process-global; sessionID is purely a routing key (source: session-mcp-routes.patch)" },
  { method: "POST", path: "/session/{sessionID}/mcp/{name}/connect", class: "session-path" },
  { method: "POST", path: "/session/{sessionID}/mcp/{name}/disconnect", class: "session-path" },
  { method: "GET", path: "/session/{sessionID}/message", class: "session-path" },
  { method: "POST", path: "/session/{sessionID}/message", class: "session-path" },
  { method: "DELETE", path: "/session/{sessionID}/message/{messageID}", class: "session-path" },
  { method: "GET", path: "/session/{sessionID}/message/{messageID}", class: "session-path" },
  { method: "DELETE", path: "/session/{sessionID}/message/{messageID}/part/{partID}", class: "session-path" },
  { method: "PATCH", path: "/session/{sessionID}/message/{messageID}/part/{partID}", class: "session-path" },
  { method: "GET", path: "/session/{sessionID}/permissions", class: "session-path", note: "FABLE-P5-F2 (session-scoped variant): pending permissions live in PER-PROCESS memory on the owning serve. Correct while the lease resolves; but on the degrade-to-anchor path (resolve.ts, pigeon down / lease missing) this returns the ANCHOR's view of a session it does not own -- i.e. HTTP 200 [] rather than an error. The TUI's pending-reconcile cannot distinguish that from 'genuinely nothing pending' and will not retry. Suspected, not yet observed. Consider failing closed (503) for these four routes when degraded." },
  { method: "POST", path: "/session/{sessionID}/permissions/{permissionID}", class: "session-path" },
  { method: "POST", path: "/session/{sessionID}/prompt_async", class: "session-path" },
  { method: "GET", path: "/session/{sessionID}/questions", class: "session-path", note: "FABLE-P5-F2 (session-scoped variant): same per-process/degrade hazard as GET permissions above. A degraded 200 [] here silently hides a question the session is blocked on -- the 2026-07-30 incident's symptom, reached by a different route (there: these four routes were missing entirely from a stale door, so every probe and reply 404'd)." },
  { method: "POST", path: "/session/{sessionID}/questions/{questionID}/reject", class: "session-path" },
  { method: "POST", path: "/session/{sessionID}/questions/{questionID}/reply", class: "session-path" },
  { method: "POST", path: "/session/{sessionID}/revert", class: "session-path" },
  { method: "DELETE", path: "/session/{sessionID}/share", class: "session-path" },
  { method: "POST", path: "/session/{sessionID}/share", class: "session-path" },
  { method: "POST", path: "/session/{sessionID}/shell", class: "session-path" },
  { method: "POST", path: "/session/{sessionID}/summarize", class: "session-path" },
  { method: "GET", path: "/session/{sessionID}/todo", class: "session-path" },
  { method: "POST", path: "/session/{sessionID}/unrevert", class: "session-path" },
  { method: "GET", path: "/session/status", class: "global-ro", note: "FABLE-P5-F2: SessionStatus is a PER-PROCESS in-memory Map; door->anchor reports idle for a session mid-turn on another serve. Latent (no through-door consumer today); revisit before Phase 7/9." },
  { method: "GET", path: "/skill", class: "global-ro" },
  { method: "POST", path: "/sync/history", class: "global-sideeffect" },
  { method: "POST", path: "/sync/replay", class: "global-sideeffect" },
  { method: "POST", path: "/sync/start", class: "global-sideeffect" },
  { method: "POST", path: "/sync/steal", class: "global-sideeffect" },
  { method: "POST", path: "/tui/append-prompt", class: "tui" },
  { method: "POST", path: "/tui/clear-prompt", class: "tui" },
  { method: "GET", path: "/tui/control/next", class: "tui" },
  { method: "POST", path: "/tui/control/response", class: "tui" },
  { method: "POST", path: "/tui/execute-command", class: "tui" },
  { method: "POST", path: "/tui/open-help", class: "tui" },
  { method: "POST", path: "/tui/open-models", class: "tui" },
  { method: "POST", path: "/tui/open-sessions", class: "tui" },
  { method: "POST", path: "/tui/open-themes", class: "tui" },
  { method: "POST", path: "/tui/publish", class: "tui" },
  { method: "POST", path: "/tui/select-session", class: "tui" },
  { method: "POST", path: "/tui/show-toast", class: "tui" },
  { method: "POST", path: "/tui/submit-prompt", class: "tui" },
  { method: "GET", path: "/vcs", class: "global-ro" },
  { method: "POST", path: "/vcs/apply", class: "global-sideeffect" },
  { method: "GET", path: "/vcs/diff", class: "global-ro" },
  { method: "GET", path: "/vcs/diff/raw", class: "global-ro" },
  { method: "GET", path: "/vcs/status", class: "global-ro" }
];
