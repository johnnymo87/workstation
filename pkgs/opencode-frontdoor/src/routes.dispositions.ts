/**
 * Route Denial Dispositions for opencode-frontdoor.
 *
 * Check B invariant: Every route in `/doc` that frontdoor denies MUST carry
 * an explicit, structured disposition explaining why the denial is architecturally
 * correct, superseded by a session-scoped route, or a known gap.
 */

import { normalizePath, compilePathTemplate, isTemplatePath } from './path-template.js';

export type DispositionKind =
  | 'by-design-501'         // class-level blanket: pty / tui / per-process-ro
  | 'not-session-scopable'  // global mutation with no session context; denial is architecturally correct
  | 'superseded'            // a forwarded session-scoped route serves this need
  | 'needs-mechanism'       // D4: needs anchor-pin or broadcast that the door lacks
  | 'accepted-gap';         // known gap, consciously accepted

/**
 * WHAT actually stops this route from working through the front door.
 *
 * `kind` records the DECISION (denied by design / superseded / gap); this records
 * the MECHANISM. They are independent, and conflating them is how a row gets a
 * plausible label for the wrong reason: `/integration/attempt/*` sat under
 * "no session context" for months when the real blocker is a per-instance RAM
 * Map (`core/src/integration.ts:227`), so it was invisible to a search for
 * process-pinned routes. See docs/plans/2026-07-26-mlve11-d4-mechanisms.md (F8, R5).
 *
 * The census over these values is pinned in `route-gate.ts`, so adding a row
 * forces an explicit answer and changing the distribution fails the gate.
 *
 * - `class-level-501`: denied by class, not by route (pty / tui).
 * - `superseded-by-session-route`: not blocked at all — a session-scoped route
 *   does the same job and the door forwards that one instead.
 * - `process-pinned-ram`: the operation needs a live object in ONE process's
 *   heap (a pending-OAuth Map, a PKCE closure, a cached instance). Delivering it
 *   to any other process fails or silently does nothing.
 * - `shared-disk-plus-stale-cache`: the state IS shared on disk, but every
 *   process caches it in memory with no invalidation, so a successful write does
 *   not become visible to the rest of the pool.
 * - `process-local-side-effect`: the effect targets the receiving process's own
 *   resources (its stdout, its binary, its config, its instance cache). Any
 *   serve can do it; which one did it is arbitrary, which makes it meaningless
 *   through a load-balancing door.
 * - `needs-audit`: NOT yet traced to a mechanism. An honest placeholder, not a
 *   free pass — it is pinned and meant to be burned down, the same way
 *   `tuiSurface: 'unverified'` was driven to zero on 2026-07-26.
 */
export type DispositionConstraint =
  | 'class-level-501'
  | 'superseded-by-session-route'
  | 'process-pinned-ram'
  | 'shared-disk-plus-stale-cache'
  | 'process-local-side-effect'
  | 'needs-audit';

export type TuiSurface = 'absent' | 'degrades' | 'unverified';

/**
 * The remedy for provider-credential mutation, shared by the four routes whose
 * success path writes `auth.json` (`PUT|DELETE /auth/{providerID}` and both
 * `POST /provider/{providerID}/oauth/*` routes — the latter because
 * `provider/auth.ts:203-220` calls `auth.set()` on success).
 *
 * This exists as a constant because the generic denial hint ("call a serve port
 * directly") is ACTIVELY WRONG for these routes: writing one serve returns 200
 * while the other three — and the writer's own already-booted instances — keep
 * the old credential indefinitely. See docs/plans/2026-07-26-mlve11-d4-mechanisms.md
 * (Group A, and F3 for why the OAuth pair inherits it).
 *
 * Step 6 of that plan replaces the hand-rolled procedure below with a CLI; when
 * it lands, this constant is the single place to update.
 */
export const POOL_CREDENTIAL_REMEDY =
  'Write the credential once, then force every serve to re-read it: ' +
  '(1) send the write to exactly ONE port, e.g. `curl -X PUT http://127.0.0.1:4096/auth/<providerID> -H "Content-Type: application/json" -d @creds.json`; ' +
  '(2) then `for p in 4096 4097 4098 4099; do curl -sS -X POST http://127.0.0.1:$p/global/dispose; done`. ' +
  'Do NOT send the write to all four ports: auth.json is shared and has no lock, so concurrent whole-document writes can silently lose an update. ' +
  'Be aware step (2) is disruptive — /global/dispose cancels every in-flight run on that serve, for every directory, and SIGTERMs its stdio MCP children; expect a cold-boot latency spike afterwards.';

/**
 * Membership in the TUI's documented SDK surface list at
 * `docs/plans/2026-07-24-phase9-door-route-allowlist.md:17`.
 *
 * - `absent`: corresponding SDK call is NOT in that documented list.
 * - `degrades`: in the list AND Phase 9 audit at `2026-07-24-phase9-door-route-allowlist.md:35`
 *   recorded it as denied-by-design with graceful degradation.
 * - `unverified`: in the list, but through-door consequence was never audited.
 */
export interface RouteDisposition {
  kind: DispositionKind;
  /**
   * REQUIRED. The mechanism that blocks this route (see `DispositionConstraint`).
   * Required so that adding a row cannot skip the question.
   */
  constraint: DispositionConstraint;
  /**
   * Repo-facing. May cite file:line and may be long. NOT sent on the wire —
   * see `userMessage` for the caller-facing half.
   */
  rationale: string;
  /**
   * Wire-facing, optional. One sentence naming the REAL constraint, with no
   * file:line citations. When present, `proxy.ts` puts it in the denial body in
   * place of the generic "mutates per-process state" text.
   *
   * Set this whenever the generic denial text would mislead the caller.
   */
  userMessage?: string;
  /**
   * Wire-facing, optional. What the caller should actually DO. When absent,
   * `proxy.ts` falls back to "call a serve port directly", which is safe for
   * most process-global rows and wrong for anything sharing pool-wide state.
   */
  remedy?: string;
  supersededBy?: string;
  bead?: string;
  tuiSurface?: TuiSurface;
}

export const CLASS_DISPOSITIONS: Record<string, RouteDisposition> = {
  pty: {
    kind: 'by-design-501',
    constraint: 'class-level-501',
    rationale: 'PTY routes require stateful local terminal streams (Task 5.1); frontdoor returns 501 by design.',
  },
  tui: {
    kind: 'by-design-501',
    constraint: 'class-level-501',
    rationale: 'TUI control routes require process-local UI state (Task 5.1); frontdoor returns 501 by design.',
  },
};

export const ROUTE_DISPOSITIONS: Record<string, RouteDisposition> = {
  // D4 rows (workstation-mlve.11 / needs-mechanism):
  'PUT /auth/{providerID}': {
    kind: 'needs-mechanism',
    constraint: 'shared-disk-plus-stale-cache',
    bead: 'workstation-mlve.11',
    rationale: 'Provider auth state mutation requires anchor-pinning or broadcast mechanism not yet implemented in door.',
    userMessage:
      'Provider credentials are shared pool-wide state that each serve caches in memory until its instance is disposed, so a write delivered to one serve would report success while the rest of the pool keeps using the previous credential.',
    remedy: POOL_CREDENTIAL_REMEDY,
  },
  'DELETE /auth/{providerID}': {
    kind: 'needs-mechanism',
    constraint: 'shared-disk-plus-stale-cache',
    bead: 'workstation-mlve.11',
    rationale: 'Provider auth removal requires anchor-pinning or broadcast mechanism not yet implemented in door.',
    userMessage:
      'Provider credentials are shared pool-wide state that each serve caches in memory until its instance is disposed, so a removal delivered to one serve would report success while the rest of the pool keeps authenticating with the deleted credential.',
    remedy: POOL_CREDENTIAL_REMEDY,
  },
  'POST /provider/{providerID}/oauth/authorize': {
    kind: 'needs-mechanism',
    constraint: 'process-pinned-ram',
    bead: 'workstation-mlve.11',
    rationale: 'Provider OAuth authorization flow requires anchor-pinning or broadcast mechanism not yet implemented in door.',
    userMessage:
      'This OAuth flow keeps its PKCE verifier in one serve process\'s memory, so the matching callback must reach that same process; and the flow completes by writing a provider credential, which is shared pool-wide state the other serves would not pick up.',
    remedy: POOL_CREDENTIAL_REMEDY,
  },
  'POST /provider/{providerID}/oauth/callback': {
    kind: 'needs-mechanism',
    constraint: 'process-pinned-ram',
    bead: 'workstation-mlve.11',
    rationale: 'Provider OAuth callback flow requires anchor-pinning or broadcast mechanism not yet implemented in door.',
    userMessage:
      'This callback can only be completed by the same serve process that issued the matching authorize request, because the PKCE verifier is held in that process\'s memory and is never written down; and its success path writes a provider credential, which is shared pool-wide state the other serves would not pick up.',
    remedy: POOL_CREDENTIAL_REMEDY,
  },
  'POST /mcp/{name}/auth': {
    kind: 'needs-mechanism',
    constraint: 'process-pinned-ram',
    bead: 'workstation-mlve.11',
    rationale: 'MCP authentication flow requires anchor-pinning or broadcast mechanism not yet implemented in door.',
  },
  'DELETE /mcp/{name}/auth': {
    kind: 'needs-mechanism',
    constraint: 'process-pinned-ram',
    bead: 'workstation-mlve.11',
    rationale: 'MCP authentication removal requires anchor-pinning or broadcast mechanism not yet implemented in door.',
  },
  'POST /mcp/{name}/auth/authenticate': {
    kind: 'needs-mechanism',
    constraint: 'process-pinned-ram',
    bead: 'workstation-mlve.11',
    rationale: 'MCP authentication execution requires anchor-pinning or broadcast mechanism not yet implemented in door.',
  },
  'POST /mcp/{name}/auth/callback': {
    kind: 'needs-mechanism',
    constraint: 'process-pinned-ram',
    bead: 'workstation-mlve.11',
    rationale: 'MCP authentication callback requires anchor-pinning or broadcast mechanism not yet implemented in door.',
  },
  'POST /instance/dispose': {
    kind: 'needs-mechanism',
    constraint: 'process-pinned-ram',
    bead: 'workstation-mlve.11',
    rationale: 'Process instance disposal requires broadcast across all active serve processes.',
  },

  // Superseded rows:
  'POST /permission/{requestID}/reply': {
    kind: 'superseded',
    constraint: 'superseded-by-session-route',
    supersededBy: 'POST /api/session/{sessionID}/permission/{requestID}/reply',
    rationale: 'Permission request replies are session-scoped and routed via POST /api/session/{sessionID}/permission/{requestID}/reply.',
  },
  'POST /question/{requestID}/reply': {
    kind: 'superseded',
    constraint: 'superseded-by-session-route',
    supersededBy: 'POST /api/session/{sessionID}/question/{requestID}/reply',
    rationale: 'Question replies are session-scoped and routed via POST /api/session/{sessionID}/question/{requestID}/reply.',
  },
  'POST /question/{requestID}/reject': {
    kind: 'superseded',
    constraint: 'superseded-by-session-route',
    supersededBy: 'POST /api/session/{sessionID}/question/{requestID}/reject',
    rationale: 'Question rejections are session-scoped and routed via POST /api/session/{sessionID}/question/{requestID}/reject.',
  },
  'GET /global/event': {
    kind: 'superseded',
    constraint: 'superseded-by-session-route',
    supersededBy: 'GET /event',
    rationale: 'Deprecated global event stream (410 Gone); clients must use session-scoped event stream GET /event?session_ids=.',
  },
  'GET /mcp': {
    kind: 'superseded',
    constraint: 'superseded-by-session-route',
    supersededBy: 'GET /session/{sessionID}/mcp',
    rationale: 'Per-process MCP status stream cannot represent multi-serve pool state (F3); superseded by session-scoped status GET /session/{sessionID}/mcp.',
  },
  // Solved in Phase 10 via session-scoped route POST /session/{sessionID}/mcp/{name}/connect; deliberately excluded from D4.
  'POST /mcp/{name}/connect': {
    kind: 'superseded',
    constraint: 'superseded-by-session-route',
    supersededBy: 'POST /session/{sessionID}/mcp/{name}/connect',
    rationale: 'MCP connection management is superseded by session-scoped POST /session/{sessionID}/mcp/{name}/connect. Phase 10 solved this via session-scoped routes; deliberately excluded from D4.',
  },
  // Solved in Phase 10 via session-scoped route POST /session/{sessionID}/mcp/{name}/disconnect; deliberately excluded from D4.
  'POST /mcp/{name}/disconnect': {
    kind: 'superseded',
    constraint: 'superseded-by-session-route',
    supersededBy: 'POST /session/{sessionID}/mcp/{name}/disconnect',
    rationale: 'MCP disconnection management is superseded by session-scoped POST /session/{sessionID}/mcp/{name}/disconnect. Phase 10 solved this via session-scoped routes; deliberately excluded from D4.',
  },

  // Corrected 2026-07-25; AUDITED and resolved 2026-07-26 (workstation-mlve.11).
  'POST /sync/start': {
    kind: 'not-session-scopable',
    constraint: 'needs-audit',
    tuiSurface: 'degrades',
    rationale:
      'Process-global workspace sync engine start; the door cannot session-scope it. D4 audit: the only callers are tui/src/context/sdk.tsx:99 (SSE) and :127 (RPC), BOTH gated on Flag.OPENCODE_EXPERIMENTAL_WORKSPACES (sdk.tsx:96/:124) and BOTH written `await sdk.sync.start().catch(() => {})`, so the door 403 is swallowed. The flag is off here: enabledByExperimental falls back to the EXACT var OPENCODE_EXPERIMENTAL (core/src/flag/flag.ts:11-13), and neither it nor OPENCODE_EXPERIMENTAL_WORKSPACES is set anywhere in the workstation repo. Consequence: workspace sync loops never start; nothing else is affected. Resolved by verification, not mechanism.',
  },

  // Individual global mutation / non-session-scopable rows (32 total: 11 degrades, 21 absent; plus POST /sync/start above = 12 degrades overall).
  // The 5 formerly-'unverified' rows were audited 2026-07-26 under workstation-mlve.11 and are now 'degrades' with the evidence inline.
  'POST /log': {
    kind: 'not-session-scopable',
    constraint: 'process-local-side-effect',
    tuiSurface: 'absent',
    rationale: 'Process-global logging endpoint targets single process stdout/file, not a session.',
  },
  'POST /experimental/control-plane/move-session': {
    kind: 'not-session-scopable',
    constraint: 'needs-audit',
    tuiSurface: 'degrades',
    rationale: 'Internal control-plane session migration mutation operates across processes without session-scoped door route wrapper. In TUI SDK surface list and recorded as denied-by-design with graceful degradation (2026-07-24-phase9-door-route-allowlist.md:35).',
  },
  'PATCH /global/config': {
    kind: 'not-session-scopable',
    constraint: 'process-local-side-effect',
    tuiSurface: 'absent',
    rationale:
      'Modifies process-level global configuration; no session context. It is also a HIDDEN MASS DISPOSE: on any actual change, handlers/global.ts:88 forks disposeAllInstancesAndEmitGlobalDisposed(), tearing down EVERY instance in the receiving process — cancelling in-flight runs and SIGTERMing stdio MCP children for every directory it was serving. Forwarding this to an arbitrary pool member would therefore be an arbitrary partial outage, and the config change would still be invisible to the other three.',
  },
  'POST /global/dispose': {
    kind: 'not-session-scopable',
    constraint: 'process-local-side-effect',
    tuiSurface: 'absent',
    rationale: 'Disposes global process runtime state; no session context.',
  },
  'POST /global/upgrade': {
    kind: 'not-session-scopable',
    constraint: 'process-local-side-effect',
    tuiSurface: 'degrades',
    rationale: 'Triggers process-global application binary upgrade; no session context. In TUI SDK surface list and recorded as denied-by-design with graceful degradation (2026-07-24-phase9-door-route-allowlist.md:35).',
  },
  'PATCH /config': {
    kind: 'not-session-scopable',
    constraint: 'process-local-side-effect',
    tuiSurface: 'absent',
    rationale:
      'Mutates global server configuration settings; no session context. It is also a HIDDEN DISPOSE: handlers/config.ts:20 calls markInstanceForDisposal() on the current instance, so the write tears down the instance that served it. The previous rationale omitted this, which is what F8 flagged — a row can be denied for a true reason and still describe itself wrongly.',
  },
  'POST /experimental/console/switch': {
    kind: 'not-session-scopable',
    constraint: 'needs-audit',
    tuiSurface: 'degrades',
    bead: 'workstation-85ui',
    rationale:
      'Switches global console organization context for process; no session context. D4 audit (workstation-mlve.11): called from tui/src/component/dialog-console-org.tsx:98. Degrades SILENTLY, not gracefully — the call passes `{ throwOnError: true }` with no try/catch, and DialogSelect discards the returned promise (ui/dialog-select.tsx:34/71), so the door 403 becomes an UNHANDLED REJECTION. It does not crash today only because @opentui/core registers a process-level unhandledRejection handler and opencode sets openConsoleOnError:false (tui/src/app.tsx:196), so the error lands in an invisible console buffer and the dialog silently does nothing. Bun exits 1 on an unhandled rejection with no handler, so this is one dependency bump from a TUI crash. NOTE this is the ONLY row of the six D4-audited rows that is NOT gated by the experimental flag — it needs only a Console login with 2+ switchable orgs. Door behaviour is correct; the hazard is client-side and tracked as workstation-85ui.',
  },
  'POST /experimental/worktree': {
    kind: 'not-session-scopable',
    constraint: 'needs-audit',
    tuiSurface: 'absent',
    rationale: 'Creates process-global git worktree; no session context.',
  },
  'DELETE /experimental/worktree': {
    kind: 'not-session-scopable',
    constraint: 'needs-audit',
    tuiSurface: 'absent',
    rationale: 'Deletes process-global git worktree; no session context.',
  },
  'POST /experimental/worktree/reset': {
    kind: 'not-session-scopable',
    constraint: 'needs-audit',
    tuiSurface: 'absent',
    rationale: 'Resets process-global git worktree state; no session context.',
  },
  'POST /vcs/apply': {
    kind: 'not-session-scopable',
    constraint: 'needs-audit',
    tuiSurface: 'absent',
    rationale: 'Applies VCS patch to process working directory; no session context.',
  },
  'POST /mcp': {
    kind: 'not-session-scopable',
    constraint: 'needs-audit',
    tuiSurface: 'absent',
    rationale: 'Adds server to process-global MCP configuration; no session context.',
  },
  'POST /project/git/init': {
    kind: 'not-session-scopable',
    constraint: 'needs-audit',
    tuiSurface: 'absent',
    rationale: 'Initializes git repository in process working directory; no session context.',
  },
  'PATCH /project/{projectID}': {
    kind: 'not-session-scopable',
    constraint: 'needs-audit',
    tuiSurface: 'absent',
    rationale: 'Modifies process project settings; no session context.',
  },
  'POST /experimental/project/{projectID}/copy/generate-name': {
    kind: 'not-session-scopable',
    constraint: 'needs-audit',
    tuiSurface: 'degrades',
    rationale: 'Generates project copy name globally; no session context. In TUI SDK surface list and recorded as denied-by-design with graceful degradation (2026-07-24-phase9-door-route-allowlist.md:35).',
  },
  'POST /sync/replay': {
    kind: 'not-session-scopable',
    constraint: 'needs-audit',
    tuiSurface: 'absent',
    rationale: 'Replays sync engine operations process-globally; no session context.',
  },
  'POST /sync/steal': {
    kind: 'not-session-scopable',
    constraint: 'needs-audit',
    tuiSurface: 'absent',
    rationale: 'Steals sync engine lease process-globally; no session context.',
  },
  'POST /sync/history': {
    kind: 'not-session-scopable',
    constraint: 'needs-audit',
    tuiSurface: 'absent',
    rationale: 'Fetches sync history for process; no session context.',
  },
  'POST /experimental/workspace': {
    kind: 'not-session-scopable',
    constraint: 'needs-audit',
    tuiSurface: 'degrades',
    rationale:
      'Creates experimental workspace in process directory; no session context. D4 audit: callers are tui/src/component/prompt/workspace.tsx:31 and dialog-session-list.tsx:110, both behind Flag.OPENCODE_EXPERIMENTAL_WORKSPACES (prompt/index.tsx:535), which is OFF here. Both call sites try/catch AND check result.error, surfacing a toast ("Creating workspace failed") carrying the door message. This is the one row of the six that yields 405 + Allow: GET rather than 403, because GET /experimental/workspace is a sibling global-ro (routes.classification.ts:146). Graceful; resolved by verification, not mechanism.',
  },
  'POST /experimental/workspace/sync-list': {
    kind: 'not-session-scopable',
    constraint: 'needs-audit',
    tuiSurface: 'degrades',
    rationale:
      'Syncs workspace list for process; no session context. D4 audit: callers are dialog-workspace-create.tsx:81 and dialog-workspace-list.tsx:91, both behind Flag.OPENCODE_EXPERIMENTAL_WORKSPACES (OFF here), both written `.catch(() => undefined)` with the return value discarded — fire-and-forget. Consequence of the door 403: adapter-discovered workspaces are silently not registered. Graceful; resolved by verification, not mechanism.',
  },
  'DELETE /experimental/workspace/{id}': {
    kind: 'not-session-scopable',
    constraint: 'needs-audit',
    tuiSurface: 'degrades',
    rationale:
      'Deletes experimental workspace; no session context. D4 audit: callers are dialog-workspace-list.tsx:67 (.catch -> result.error -> toast) and dialog-session-list.tsx:153 (no try/catch, checks result.error only — safe because the generated SDK defaults throwOnError to false, v2/gen/client/client.gen.ts:222-232). Both behind Flag.OPENCODE_EXPERIMENTAL_WORKSPACES (OFF here; the list command is hidden without it, app.tsx:609). Toast "Failed to delete workspace". Graceful; resolved by verification, not mechanism.',
  },
  'POST /experimental/workspace/warp': {
    kind: 'not-session-scopable',
    constraint: 'needs-audit',
    tuiSurface: 'degrades',
    rationale:
      'Warps workspace state process-globally; no session context. D4 audit: caller is dialog-workspace-create.tsx:102 (warpWorkspaceSession), behind Flag.OPENCODE_EXPERIMENTAL_WORKSPACES (OFF here, prompt/index.tsx:535). try/catch -> toast "Failed to warp session", returns false. Graceful; resolved by verification, not mechanism.',
  },
  'POST /integration/{integrationID}/connect/key': {
    kind: 'not-session-scopable',
    constraint: 'needs-audit',
    tuiSurface: 'absent',
    rationale: 'Connects integration key globally for process; no session context.',
  },
  'POST /integration/{integrationID}/connect/oauth': {
    kind: 'not-session-scopable',
    constraint: 'needs-audit',
    tuiSurface: 'absent',
    rationale: 'Initiates integration OAuth connection process-globally; no session context.',
  },
  'DELETE /integration/attempt/{attemptID}': {
    kind: 'not-session-scopable',
    constraint: 'process-pinned-ram',
    tuiSurface: 'absent',
    rationale:
      'RE-DISPOSITIONED 2026-07-26 (F8). The old reason ("no session context") was true but not the CONSTRAINT, which hid this route from any search for process-pinned state. Verified: attempts live in `SynchronizedRef.makeUnsafe(new Map<AttemptID, AttemptEntry>())` created inside integration locationLayer (core/src/integration.ts:227), i.e. per (process, location) RAM keyed by the attemptID in this very path. This is a THIRD OAuth family with the same shape as provider OAuth and MCP OAuth; it sits outside D4 only because of the old label.',
  },
  'POST /integration/attempt/{attemptID}/complete': {
    kind: 'not-session-scopable',
    constraint: 'process-pinned-ram',
    tuiSurface: 'absent',
    rationale:
      'RE-DISPOSITIONED 2026-07-26 (F8). Completing an attempt requires the entry created by the matching connect/oauth call, which lives in the per-(process, location) attempts Map at core/src/integration.ts:227. Delivering this to any other pool member finds no entry. Same family as DELETE /integration/attempt/{attemptID}; see that row.',
  },
  'PATCH /credential/{credentialID}': {
    kind: 'not-session-scopable',
    constraint: 'needs-audit',
    tuiSurface: 'absent',
    rationale:
      'CONSTRAINT UNVERIFIED — and the previous rationale ("process credential store") is FALSE. Traced 2026-07-26: credential.update routes to Integration.Service.connection.update (server/src/handlers/credential.ts:9-14), which is backed by Credential.Service over the shared SQL Database (core/src/credential.ts:7,54), not by process memory. A write is therefore durable and pool-visible, so process-pinning is NOT the blocker and this row may not need denying at all. It stays denied pending an audit of whether any process caches the credential list in RAM (the Group A failure mode) — deliberately NOT relabelled to a confident-sounding value, which is the mistake F8 documented.',
  },
  'DELETE /credential/{credentialID}': {
    kind: 'not-session-scopable',
    constraint: 'needs-audit',
    tuiSurface: 'absent',
    rationale:
      'CONSTRAINT UNVERIFIED — the previous rationale ("process credential store") is FALSE for the same reason as PATCH /credential/{credentialID}: it routes to Integration.Service.connection.remove over the shared SQL Database. See that row.',
  },
  'DELETE /permission/saved/{id}': {
    kind: 'not-session-scopable',
    constraint: 'needs-audit',
    tuiSurface: 'absent',
    rationale: 'Deletes process-global saved permission entry; no session context.',
  },
  'POST /experimental/project/{projectID}/copy': {
    kind: 'not-session-scopable',
    constraint: 'needs-audit',
    tuiSurface: 'degrades',
    rationale: 'Initiates project copy process-globally; no session context. In TUI SDK surface list and recorded as denied-by-design with graceful degradation (2026-07-24-phase9-door-route-allowlist.md:35).',
  },
  'DELETE /experimental/project/{projectID}/copy': {
    kind: 'not-session-scopable',
    constraint: 'needs-audit',
    tuiSurface: 'degrades',
    rationale: 'Cancels project copy process-globally; no session context. In TUI SDK surface list and recorded as denied-by-design with graceful degradation (2026-07-24-phase9-door-route-allowlist.md:35).',
  },
  'POST /experimental/project/{projectID}/copy/refresh': {
    kind: 'not-session-scopable',
    constraint: 'needs-audit',
    tuiSurface: 'degrades',
    rationale: 'Refreshes project copy status process-globally; no session context. In TUI SDK surface list and recorded as denied-by-design with graceful degradation (2026-07-24-phase9-door-route-allowlist.md:35).',
  },
};

/**
 * Compiled template matchers per disposition map, built lazily and cached.
 *
 * The gate calls `getRouteDisposition` with TEMPLATE paths straight out of
 * `/doc` (`/auth/{providerID}`), which hit the exact-match step. The proxy calls
 * it with CONCRETE request paths (`/auth/anthropic`), which do not — hence the
 * template step below. Both callers must resolve to the same row or the wire
 * message and the gate's rationale would describe different routes.
 */
const templateMatcherCache = new WeakMap<
  Record<string, RouteDisposition>,
  Array<{ method: string; regex: RegExp; disposition: RouteDisposition }>
>();

function templateMatchers(map: Record<string, RouteDisposition>) {
  let compiled = templateMatcherCache.get(map);
  if (!compiled) {
    compiled = [];
    for (const [key, disposition] of Object.entries(map)) {
      const sep = key.indexOf(' ');
      if (sep < 0) continue;
      const keyMethod = key.slice(0, sep).toUpperCase();
      const keyPath = normalizePath(key.slice(sep + 1));
      if (!isTemplatePath(keyPath)) continue;
      compiled.push({ method: keyMethod, regex: compilePathTemplate(keyPath), disposition });
    }
    templateMatcherCache.set(map, compiled);
  }
  return compiled;
}

function matchTemplate(
  map: Record<string, RouteDisposition>,
  upperMethod: string,
  normPath: string
): RouteDisposition | undefined {
  // First match wins, in declaration order. The gate's Check B independently
  // proves every denial resolves to exactly one disposition, so an ambiguous
  // overlap here would be caught there rather than silently picking a row.
  for (const candidate of templateMatchers(map)) {
    if (candidate.method === upperMethod && candidate.regex.test(normPath)) {
      return candidate.disposition;
    }
  }
  return undefined;
}

export function getRouteDisposition(
  method: string,
  pathname: string,
  routeClass: string,
  customRouteDispositions?: Record<string, RouteDisposition>,
  customClassDispositions?: Record<string, RouteDisposition>
): RouteDisposition | undefined {
  const routeDispMap = customRouteDispositions ?? ROUTE_DISPOSITIONS;
  const classDispMap = customClassDispositions ?? CLASS_DISPOSITIONS;

  // 1. Class-level disposition
  if (classDispMap[routeClass]) {
    return classDispMap[routeClass];
  }

  const upperMethod = method.toUpperCase();
  const normPath = normalizePath(pathname);

  // 2. Exact match in ROUTE_DISPOSITIONS
  const exactKey = `${upperMethod} ${normPath}`;
  if (routeDispMap[exactKey]) {
    return routeDispMap[exactKey];
  }

  // 3. `/api/*` mirror fallback to bare route.
  //    NOTE the house convention: disposition keys are written in BARE form and
  //    this fallback is what makes them cover the `/api/` mirror too. One key
  //    therefore speaks for BOTH forms — if upstream ever gives them different
  //    behaviour, one disposition would silently cover two routes.
  const barePath = normPath.startsWith('/api/') ? normPath.slice(4) : undefined;
  if (barePath !== undefined) {
    const bareKey = `${upperMethod} ${barePath}`;
    if (routeDispMap[bareKey]) {
      return routeDispMap[bareKey];
    }
  }

  // 4. Template match, for concrete request paths (proxy callers).
  const templated = matchTemplate(routeDispMap, upperMethod, normPath);
  if (templated) {
    return templated;
  }

  // 5. Template match against the `/api/`-stripped path, same convention as (3).
  if (barePath !== undefined) {
    return matchTemplate(routeDispMap, upperMethod, barePath);
  }

  return undefined;
}
