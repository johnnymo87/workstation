# Design: shared `StickyRouter<Key, Target>` package (bead `workstation-bkdw`)

Date: 2026-06-19
Status: Approved (brainstorming complete; implementation plan to follow)
Parent design: `2026-06-19-pool-replace-design.md` §6 (composability) + §11 (open items)

## Problem

Two proxies at different layers both key on the opencode session id and both do
**sticky + idle-migration** routing, but they answer different questions:

| Ingress router (pigeon, `zao4`) | Egress proxy (`claude-failover-proxy`) |
|---|---|
| "where does this session **run**?" (session → serve) | "which LLM **backend/account**?" (session → backend) |

The pin/migrate/sweep state machine is identical; only the *desired-target*
computation differs (ingress: rendezvous-hash over healthy serves; egress:
budget + backend availability). Today that state machine lives, specialized to
`Backend = 'vertex' | 'max'`, in `claude-failover-proxy/src/router.ts`
(`SessionRouter`, 94 lines, pure, fully branch-tested).

`zao4` needs the same machine. Rather than copy it, extract a **pure,
deterministic, generic** library that both repos depend on, without sharing any
state table or merging the proxies (merging would re-centralize both client SSE
and upstream SSE on one event loop — the exact failure the pool replace avoids).

## Decisions (resolved during brainstorming)

1. **Packaging:** standalone **private** repo `johnnymo87/sticky-router`,
   consumed as a **git dependency** pinned to a tag. Added to `projects.nix`
   for development. Chosen over npm-publish (overkill for a personal,
   2-consumer lib) and over vendoring (the logic will grow with the lease
   layer; divergent copies would be a bug farm). Symmetric ownership per
   pool-replace §6.
2. **API shape:** the **caller passes `desired`**; the router does pin / migrate
   / sweep only. All consumer-specific logic (budget calc, rendezvous-hash,
   target-health filtering, in-flight tracking) stays in each consumer. Chosen
   over a constructor-injected `desiredTarget` strategy (needless 3rd generic +
   indirection) and over building the full §6 surface now (speculative; YAGNI).

## Package & repo

- Private repo `johnnymo87/sticky-router`; entry added to `projects.nix`.
  Consumers fetch the lib via git dep regardless of the local clone; the clone
  is for development convenience.
- Pure TS, **zero runtime dependencies**.
- Dev tooling mirrors the seed's origin: `bun test` + `biome`. Build via `tsc`
  in a `prepare` script so `install` produces `dist/index.js` + `index.d.ts`
  (so type resolution works through `node_modules` in both consumers).

## Public API (entire surface)

```ts
export class StickyRouter<Key, Target> {
  /** @param idleMigrateMs minimum idle gap before a pinned key migrates. */
  constructor(idleMigrateMs: number)

  /**
   * @param key      stickiness key; `undefined` => return `desired`, store nothing.
   * @param nowMs    current epoch ms (injected for determinism).
   * @param desired  the target the caller wants this key on right now.
   * @returns        the target to actually use (sticky unless idle long enough).
   */
  route(key: Key | undefined, nowMs: number, desired: Target): Target

  /** Evict entries idle longer than `ttlMs` so the map doesn't grow unbounded. */
  sweep(nowMs: number, ttlMs: number): void
}
```

- `Key` must be a valid `Map` key (primitive). Both consumers use the session-id
  string.
- `Target` is compared with `===`; use a stable primitive (backend name, serve
  id). An `equals` hook is a deliberate non-goal until a consumer needs it.

## Behavior (seed logic, verbatim, with `desired` supplied by caller)

- `key === undefined` → return `desired`, persist nothing.
- new key → pin to `desired`, record `lastActivity = nowMs`, return `desired`.
- existing key:
  - `entry.target === desired` → keep (return stored target);
  - else `nowMs - entry.lastActivity >= idleMigrateMs` → migrate (`entry.target = desired`);
  - else → stay (return stored target, preserve warm cache).
- **Always** advance `lastActivity = nowMs` after the decision (single write, so
  the "continuously-active key never cold-flips mid-conversation" invariant is
  structurally impossible to half-apply).
- `sweep(now, ttl)` deletes entries with `now - lastActivity > ttl`.

## `claude-failover-proxy` refactor

- Add the git dependency.
- Reduce `src/router.ts`'s `SessionRouter` to a thin wrapper that keeps its
  current `route(sessionId, nowMs, inputs: RouteInputs)` signature, computes
  `desired = inputs.overBudget && inputs.maxAvailable ? 'max' : 'vertex'`, and
  delegates to a `StickyRouter<string, Backend>`. `sweep` forwards.
- Everything downstream (`server.ts`, etc.) is untouched. The existing
  `src/router.test.ts` stays as-is and is the regression net proving behavior is
  preserved.

## Testing

- Port the seed's full branch-coverage suite into the lib's own test file
  (rename `backend`→`target`, pass `desired` explicitly): new/warm/idle/boundary
  (`>=`), `undefined` key, independence of two keys, sweep semantics.
- Add genericity tests: a `Target` distinct from backends (e.g. serve-id strings
  `"serve-a"`/`"serve-b"`) to prove the lib is not backend-specific.
- Keep `claude-failover-proxy/src/router.test.ts` green unchanged.

## Consumption mechanism

Both repos add to `package.json` dependencies:

```json
"sticky-router": "git+ssh://git@github.com/johnnymo87/sticky-router.git#v0.1.0"
```

Pinned to a tag. Bumping = tag a new version, update both specs + lockfiles.
SSH form is required because the repo is private (the https tarball path is
auth-gated); the dev hosts already have SSH access to GitHub.

## Scope / non-goals (YAGNI)

- **In:** the pure pin/migrate/sweep state machine + its tests; the
  `claude-failover-proxy` refactor to consume it.
- **Out (deferred to `zao4` / the lease layer):** target-health registry,
  in-flight tracking, rendezvous-hash placement, any DB/IO. pigeon's actual
  consumption is **not** part of `bkdw`; `zao4` wires the lib in later.

## Push policy

- `sticky-router` and `claude-failover-proxy` are real repos → normal push rules
  (confirm remotes, push on green). `claude-failover-proxy` origin is currently
  **https**; resolve credentials at push time.
- `workstation` (this design doc + the `projects.nix` edit) stays **user-pushed**
  per the standing rule.
