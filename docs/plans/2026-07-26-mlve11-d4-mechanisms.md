# D4 mechanisms: door-side handling of the 9 denied mutating routes

Bead: `workstation-mlve.11`. Closing-plan item 3. Written 2026-07-26, before implementation.

Status: **DESIGN — not implemented.** Part 1 of the bead (the 5 `unverified` rows + the
`accepted-gap` row) is already done and committed (`c231061`); those resolved by audit and
needed no mechanism. This document covers only the remaining 9 `needs-mechanism` rows.

## Why this document exists

The bead warns that D4 "is NOT row transcription". That is correct, and the state-model audit
below makes it more pointed: **for one of the three groups, the mechanism the original plan
specifies would ship a false success.** That deserves a written decision before code.

## Verified state model

All citations are `git show v1.17.13:<path>` (the deployed pin; the working tree of
`~/projects/opencode` is 13,436 commits away — do not read it). Patch set checked: of 27
patches in `~/projects/opencode-patched/patches/`, only `globalbus-maxlisteners.patch` touches
any file cited here, and it only appends `GlobalBus.setMaxListeners(0)`.

### Cross-process propagation: confident absence

There is **no** mechanism by which one serve's write becomes visible to another:

- `bus/global.ts:11-22` `GlobalBus` is a plain Node `EventEmitter` singleton — in-process only.
- No file watcher on `auth.json` or `mcp-auth.json`. `core/src/config/watcher.ts` is a 7-line
  schema, not a watcher.
- `auth.set`/`auth.remove` (`auth/index.ts:73-89`) emit no event.
- No IPC, cluster, unix socket, `BroadcastChannel`, or `process.send` between serves.
- The one genuine cross-process primitive is `Flock` (`core/src/util/flock.ts`), an mkdir-based
  advisory lock. It gives **mutual exclusion, not notification**.

Cross-process visibility is therefore exclusively "whenever the other process next reads from
disk" — which for the path that matters is *never* (see Group A).

### Group A — `PUT|DELETE /auth/{providerID}`

| Property | Finding |
|---|---|
| Handler | `groups/control.ts:39,51` → `handlers/control.ts:13-26` → `auth/index.ts:73-89` |
| State | **BOTH**: shared `$XDG_DATA_HOME/opencode/auth.json` *and* an in-memory Provider cache |
| Write safety | **No lock, not atomic, whole-document RMW** (`auth/index.ts:73-81`, `fs-util.ts:100-104`: `writeFileString` in place — no temp file, no rename, no fsync) |
| Reader cache | `provider/provider.ts:1502-1512` bakes `auth.all()` into `InstanceState`; the key is copied into the constructed SDK at `:1686` and memoized at `:1700`/`:1801-1823` |
| Invalidation | **NEVER**, except instance disposal. `effect/instance-state.ts:26-45`: `ScopedCache` with `capacity: POSITIVE_INFINITY`, no TTL, single invalidation path via `registerDisposer` |

Two consequences, both load-bearing:

1. **Lost update / torn read.** Two processes writing different providers concurrently: the
   second silently drops the first. A concurrent reader can parse a half-written file, and
   `all()` swallows it — `Effect.orElseSucceed(() => ({}))` at `:65` turns a torn read into
   "no credentials at all", indistinguishable from a fresh install. Note `mcp/auth.ts:72-82`
   does take a flock for both read and write; `auth/index.ts` conspicuously does not. The
   asymmetry looks like an upstream oversight.

2. **The stale-cache problem, which is the real blocker.** After `PUT /auth/anthropic`, every
   already-booted instance — *including the writer's own* — keeps the old key wired into its
   memoized SDK, and `GET /provider` keeps reporting the stale `connected` list. Indefinitely.
   This is not a pool bug; the pool multiplies it by 4.

### Group B — the six OAuth routes

Split into two sub-groups with *different* pinning mechanisms. The original plan calls both
"ANCHOR-PIN"; only one of them is pinned for the reason the plan states.

**B1 — provider OAuth (`POST /provider/{providerID}/oauth/{authorize,callback}`).**
`provider/auth.ts:100-103` holds `pending: Map<ProviderID, AuthOAuthResult>` inside
`InstanceState` ⇒ keyed by **(process, directory)**. The PKCE verifier lives in a JavaScript
**closure** (`match.callback`) and is never serialized anywhere. Cross-process callback fails
clean: `:191-193` → `400 ProviderAuthOauthMissing`. Entries are `set` but never `delete`d and
have no TTL, so a pending authorization survives until instance disposal.

Correlating identifiers in the *callback* request:

| Source | Identifier | Usable? |
|---|---|---|
| Path | `providerID` | **Yes** — it is literally the Map key |
| Query | `?directory=`, `?workspace=` | **Yes, and required** — `pending` is per-directory |
| Header | `x-opencode-directory` | **Yes** — fallback at `middleware/workspace-routing.ts:86-88` |
| Body | `{ method, code }` | No — `method` is an array index; `code` is opaque |
| — | a `state` param / nonce | **Does not exist on this route** |

So the deterministic key is `(providerID, resolvedDirectory)` where `resolvedDirectory` =
`?directory=` ∥ `x-opencode-directory` ∥ *that serve's* `process.cwd()`. **Consistent hashing
works; no sticky table is needed.** The `process.cwd()` fallback is the hole — it is per-serve
and invisible to the door.

**B2 — MCP OAuth (`POST|DELETE /mcp/{name}/auth`, `/auth/authenticate`, `/auth/callback`).**
The verifier and state token are on **shared disk under a real flock** (`mcp/auth.ts:37-38,72-82`),
so the plan's stated rationale ("per-process PKCE") is wrong here. What actually pins these to
one process is `mcp/index.ts:112` `pendingOAuthTransports: Map<string, {transport, provider}>`
— **module-level, process-global, keyed by mcpName** — plus, for dynamically-registered
clients, `client_id`/`client_secret` held in RAM only until `commit()`
(`oauth-provider.ts:195-197,212-237`).

`:name` is in the callback URL and *is* the Map key, so hashing on it pins all four routes to
one serve. **This is the cleanest group.** Cross-process failure here is ugly though: a bare
`throw` (`mcp/index.ts:928-929`), not a typed error ⇒ **500**, not a 4xx.

### Group C — `POST /instance/dispose`

- Disposes **per-directory, not per-process** (`lifecycle.ts:23-54` → `instance-store.ts:147-155`
  → `instance-registry.ts:10-12`, running the disposers registered by all 22 `InstanceState.make`
  call sites).
- **It harms active work**: `session/run-state.ts:39-47` cancels every in-flight run for that
  directory; `mcp/index.ts:523-548` closes MCP clients and SIGTERMs the whole descendant tree of
  every stdio MCP child.
- `mcp/index.ts:546` `pendingOAuthTransports.clear()` is **process-global**, so disposing
  instance `/a` wipes a pending MCP OAuth flow belonging to instance `/b`. That is an upstream
  cross-instance bug and it interacts with B2.
- **The fan-out trap**: `middleware/instance-context.ts:29` *loads* (cold-boots) the instance
  before the handler runs. So dispatching dispose to a process that has never seen directory `X`
  boots a full instance for `X` — plugins, config, MCP connect with stdio child spawn, LSP,
  snapshot — and immediately tears it down.
- Always returns `200 true` with no error type (`groups/instance.ts:62-64`,
  `handlers/instance.ts:24-27`), even when nothing was cached. **The response carries no signal
  about which process actually held the instance**, so it cannot drive targeting or early exit.

## Proposed design

### C — `POST /instance/dispose`: route by directory, do NOT broadcast

The original plan says BROADCAST because "per-process cache invalidation is the point". The
audit says the operation is *already* directory-keyed server-side, and the fan-out trap means
broadcasting to the 3 processes that don't hold the instance cold-boots them first. Fan-out
buys nothing that keyed routing doesn't, and costs 3 spurious boot/teardown cycles plus MCP
child churn plus clobbering unrelated pending MCP OAuth on all 4.

**Proposal: route on `resolvedDirectory`, single target, no fan-out.** This deletes the
BROADCAST mechanism from the work entirely — one of the two "genuinely new mechanisms" the bead
warns about disappears.

**Counter-argument that must be answered before accepting** (this is the crux for the review):
if `dispose` is the *only* way to invalidate a stale Provider auth cache (Group A finding), then
"invalidate everywhere" is a real requirement and single-target routing does not deliver it.
Note this is a requirement generated by Group A, not by dispose's own semantics.

### B2 — MCP OAuth: consistent hash on `:name`

Add a route class that hashes a captured path segment to a pool member. Key = `mcpName`. All
four routes forward to the same target, deterministically, with no state in the door. No sticky
table, no TTL, no eviction. Deterministic hashing survives a door restart, which a sticky table
would not.

**Hazard to handle:** hashing to a *dead or draining* member. The door must resolve the hash
against the healthy set; but any change in the healthy set re-shuffles the mapping, which can
strand a pending flow (authorize on member 2, member 1 dies, callback now hashes elsewhere ⇒
500 from a bare throw). Mitigation options for the review: rendezvous hashing (minimises
reshuffle), or accept the stranding and convert the 500 into a clean door-level 409.

### B1 — provider OAuth: consistent hash on `(providerID, resolvedDirectory)`

Same mechanism as B2 with a two-part key. The door must resolve `resolvedDirectory` exactly the
way `workspace-routing.ts:86-88` does — `?directory=` ∥ `x-opencode-directory` ∥ *unknowable*.
If both are absent the door cannot compute the server's key.

**Open hazard, unresolved:** built-in `method: "auto"` auth plugins bind fixed loopback ports
(`plugin/openai/codex.ts:13` = 1455, `plugin/digitalocean.ts:13` = 1456, `plugin/xai.ts:37` =
56121). Only one serve can own each port; the loser's `authorize` rejects loudly
(`codex.ts:223`). The installed Anthropic plugin is `method: "code"` and binds nothing, but
`opencode-gemini-auth@1.3.11` is installed and has one `"auto"` path that was **not traced**.
Gemini/Vertex is in active use here. **Verify before implementing B1.**

### A — provider auth mutation: the honest options

Anchor-routing the write fixes the inter-process lost-update race but leaves every other
serve's Provider cache stale forever. The user would get `200 OK` and a pool that still uses
the old credential. Options:

1. **Anchor + accept staleness.** Cheapest. Ships a false success. Rejected unless the review
   argues otherwise.
2. **Anchor the write, then dispose the same directory on all 4 members** to force cache
   rebuild. Correct, but inherits every cost in Group C — cancels in-flight runs pool-wide for
   that directory, SIGTERMs MCP children, cold-boots absent instances. Using a sledgehammer as
   a cache-invalidation primitive.
3. **Keep denying, but fix the error.** Replace the generic 403 with a specific message naming
   the real constraint ("provider auth mutation is not safe through the door because each serve
   memoizes credentials until instance disposal; run `opencode auth login` against a serve port
   directly"). Honest, cheap, and leaves the row dispositioned rather than forwarded.
4. **Fix upstream** — add a flock to `auth/index.ts` mirroring `mcp/auth.ts`, and invalidate the
   Provider cache on auth write. Correct fix, wrong repo, another fork patch.

**Recommendation: option 3 for now, with option 4 filed as the real fix.** That converts two of
the nine rows from `needs-mechanism` to a *dispositioned* denial with a verified rationale,
rather than pretending the door can make them work. This is a scope reduction and it needs
explicit sign-off, because it means `EXPECTED_NEEDS_MECHANISM_KEYS` reaches empty **without**
`PUT|DELETE /auth/{providerID}` ever being forwarded.

## What this does to the estimate

| Group | Plan said | Audit says |
|---|---|---|
| C `/instance/dispose` | BROADCAST fan-out (new mechanism) | Directory-keyed routing; **mechanism deleted** |
| B2 MCP ×4 | ANCHOR-PIN "per-process PKCE" | Hash on `:name`; rationale was wrong, conclusion right |
| B1 provider ×2 | ANCHOR-PIN | Hash on `(providerID, directory)`; blocked on the gemini-plugin port question |
| A auth ×2 | ANCHOR | **Cannot be made correct at the door**; propose dispositioned denial |

Net: one new mechanism (keyed hashing to a pool member), not two, plus a scope reduction of two
rows and one deleted fan-out.

## Open questions for review

1. Does the Group A stale-cache finding justify *not* forwarding those rows (option 3)? Or is a
   false success acceptable because the alternative is a worse user experience?
2. If dispose is the only cache-invalidation primitive, does that resurrect the case for
   broadcasting dispose after all?
3. Rendezvous hashing vs. accept-and-convert-500 for pending-flow stranding on pool change.
4. Does the gemini auth plugin bind a fixed loopback port? If yes, B1 has a port-contention
   failure mode independent of routing.
5. Do the 4 serves share `process.cwd()`? Determines whether the `resolvedDirectory` fallback
   collapses to one key when clients omit both `?directory=` and the header. Not yet inspected.
6. Is `200` from dispose flushed before or after teardown? `lifecycle.ts:43-54` structurally
   says after; the comment at `:29-31` says before. Unresolved; do not build sequencing on it.

---

# REVIEW OUTCOME (2026-07-26) — the proposal above is SUPERSEDED

`adversarial-reviewer-opus` pressure-tested the design. It confirmed Group A's write-safety and
cache findings, the B1 pinning model, the B2 `pendingOAuthTransports` correction, and the dispose
cold-boot trap. It then falsified the part I had marked "cleanest" and found five things the
document did not consider at all. I re-verified the four load-bearing findings myself; all four
hold. The proposal above is kept, not deleted, because the reasoning error is the useful part.

## What was falsified

**F1 — hashing on `:name` is a REGRESSION versus anchoring, not a preservation of the plan.**
`mcp/index.ts:815` `startAuth` calls `McpOAuthCallback.ensureRunning`, which binds a **fixed port
19876**. Verified verbatim at `mcp/oauth-callback.ts:114-120`:
```ts
if (server) return
const running = await isPortInUse(port)
if (running) {
  return            // <-- returns SUCCESS without binding
}
```
The browser redirect goes to `127.0.0.1:19876` and lands in whichever process owns the port; the
other process's `pendingAuths` has no entry, so it answers `400 "potential CSRF attack"` while the
calling process blocks the full 5-minute `CALLBACK_TIMEOUT_MS`. Hashing deliberately spreads names
across 4 processes, so ¾ of names would land on a process that does not own 19876. ANCHOR and
hash-on-name differ **exactly** at the process-global singleton, and hashing is the wrong side.

**F2 — the door's 5s first-byte timeout kills these routes. Not considered anywhere.** Verified:
`config.ts:58` `cheapFirstByteMs` defaults to `5000`, and `timeouts.ts:26-53`
`isExemptFromFirstByteTimeout` returns true only when a session ID appears in the path. **None of
the nine D4 routes has a session ID, so none is exempt.** `POST /mcp/{name}/auth/authenticate`
blocks on a 5-minute browser callback ⇒ 503 every single time. Worse, for dispose to a cold serve:
`instance-store.ts:117-120` forks `completeLoad` into the *server* scope, so destroying the request
does not stop the boot — the caller gets 503, MCP stdio children get spawned, the instance is
permanently cached, and **nothing is disposed.** The route is inverted into its opposite.

**F3 — B1's success path IS a Group A write.** `provider/auth.ts:203-220` calls `auth.set(...)` on
success. So a forwarded OAuth callback produces exactly the "200 OK plus a pool still using the old
credential" that I used to reject Group A. Denying A while forwarding B1 is not a defensible line.

**F4 — open question 2's premise was false, and this one is decisive.** Dispose is not the only
invalidation primitive (`InstanceStore.reload` at `instance-store.ts:126-145`; `POST /global/dispose`
at `handlers/global.ts:92-95`; and `PATCH /config` at `handlers/config.ts:18-22` is a *hidden*
dispose whose disposition text omits that entirely). And upstream's own client chains the two —
verified at `tui/src/component/dialog-provider.tsx:281` and `:332`:
```tsx
await sdk.client.instance.dispose()
await sync.bootstrap()
```
So **forwarding B1 without C ships a 200 on the callback and a 403 on the very next call in the
same user action.** My "sledgehammer used as a cache-invalidation primitive" framing was wrong: it
is the upstream-designed primitive, invoked by upstream at exactly the point I claimed none existed.

**F5 — the estimate omitted the substrate.** The door has **no pool membership list and no pool
health view**: its entire `Config` is `pigeonUrl` + `anchorUrl` (`config.ts:1-32,49-81`), session
traffic is resolved by asking pigeon, and everything else goes to the anchor. "Hash a key to a pool
member" is therefore five mechanisms (membership discovery, health/drain tracking, the hash, key
replication, timeout exemption), of which the document counted one. Meanwhile **`forward-anchor`
already exists** (`dispatch.ts:142-144`), already sits in the gate's `NON_DENYING_ACTIONS`, is
restart-durable, and co-locates port 19876 with `pendingOAuthTransports` by construction.

**F6 — `resolvedDirectory` is both easier and harder than stated.** Easier: `process.cwd()` is a
build-time constant (`hosts/cloudbox/configuration.nix:738` sets `WorkingDirectory = "/home/dev"`),
so open question 5 is answered — compute it, don't guess. Harder: `?directory=` is not the top of
the precedence chain. `?workspace=` resolves through the workspace adapter and **overrides** it
(`middleware/workspace-routing.ts:154-157`), `OPENCODE_WORKSPACE_ID` short-circuits both, and then
`decodeURIComponent` + `FSUtil.resolve` normalise. A door hashing on raw `?directory=` computes a
deterministically wrong key whenever `?workspace=` is present — silent and 100% reproducible.
A mechanism that must replicate four layers of someone else's resolution logic is a drift generator,
and drift is this project's documented failure mode.

**F8 — and this is the real honesty problem, bigger than the Group A scope reduction.**
`EXPECTED_NEEDS_MECHANISM_KEYS == empty` proves *label consistency*, not *coverage*. It answers "is
every row labelled `needs-mechanism` gone?", and I control that answer by editing labels.
`/api/integration/*` is a **third OAuth family with the identical shape** — a process-global
`Map<AttemptID, AttemptEntry>` (`core/src/integration.ts:227`) keyed by a path segment — but it is
labelled `not-session-scopable` ("no session context"), which is the wrong *reason*: the constraint
is process-pinning. Because of that label it sits outside the pinned list, so **when the list
empties, that family still has no mechanism.** Two smaller drifts confirm the pattern:
`PATCH|DELETE /credential/{credentialID}` dispositions key on paths that **do not exist** in the
pinned `/doc` (only the `/api/` form does; Check B's `/api/`→bare fallback hides it), and the
`PATCH /config` rationale omits that it disposes instances.

## Verified-negative worth keeping

`auth/index.ts:59-63`: if `OPENCODE_AUTH_CONTENT` were set, `all()` would ignore `auth.json` while
`set()` still wrote it, making `PUT /auth/{id}` a permanent silent no-op. Grepped: **not set
anywhere** in the workstation repo today. Recording the negative so a future addition is a conscious act.

## Revised plan, in order

1. **`OPENCODE_HEADLESS=1` in the `opencode-serve@` unit.** One line, no door change, no SSE drop.
   Verified: `opencode-gemini-auth@1.3.11` is installed and gates its `method: "auto"` path on
   `SSH_CONNECTION || SSH_CLIENT || SSH_TTY || OPENCODE_HEADLESS` (`src/plugin/oauth-authorize.ts:64-69`);
   **none of the four is set in the serve unit** (grepped `hosts/cloudbox/configuration.nix` and
   `users/dev/*.nix`: zero hits). So every serve takes the non-headless branch and binds `localhost:8085`
   for a redirect that resolves in the *user's laptop browser* — it can never complete, blocks 5
   minutes, and fails. This is a real latent bug independent of the door, and the cheapest fix here.
2. **Relabel four rows** — `PUT|DELETE /auth/{providerID}` and both provider-OAuth routes — to
   `not-session-scopable`, with the verified rationale. Extra fact that makes this the *correct*
   label rather than a convenient one: `groups/control.ts:36-75` applies neither
   `InstanceContextMiddleware` nor `WorkspaceRoutingMiddleware`, and `AuthParams` (`:8-10`) carries
   no `directory`/`workspace` field, so these routes have **no directory context at all** — which
   also means option 2 above was never implementable as written ("dispose the same directory" has no
   referent for an auth write).
3. **Fix what the gate MEANS (F8).** Add a second pinned list so a row leaving `needs-mechanism`
   must land in another pinned list, and retire the claim that an empty list proves D4 complete.
   Re-disposition `/api/integration/*` with the process-pinning reason. Delete the phantom
   `/credential` keys. Correct the `PATCH /config` and `PATCH /global/config` rationales.
4. **Ship the escape hatch as a CLI**, not a door feature: loop `PUT /auth/{id}` over all four serve
   ports, then `POST /global/dispose` on each. Correct, zero door changes, no directory key, no SSE
   drop, and no 5s timeout problem because a CLI can block for minutes.
5. **Leave B2 and C denied.** If C is ever wanted, forward it to the **anchor** with a first-byte
   timeout exemption — never by computed key — and state that it invalidates the anchor only.
6. **File the upstream fix**: flock `auth/index.ts` the way `mcp/auth.ts:72-82` already does, and
   invalidate the Provider cache on auth write. Still the only thing that makes any of this correct.

Net: the door change count drops from "six routes plus a new routing class" to **at most one**, and
D4 completes by *honest relabelling plus a gate that counts relabellings*, not by forwarding.

---

# FABLE REVIEW OF THE REVISED PLAN (2026-07-26) — final direction

The user asked for a fable pass before choosing a direction, since fable authored the original
per-route table this plan overturns. Fable **accepted the re-scoping for Group A, B1 and
C-as-broadcast**, in its own words: its original table answered "which process should receive this
request" and assumed delivery to the right process equals a correct operation; F1-F4 falsify that
assumption. "That is falsification, not goalpost-moving: the goal is unchanged; what changed is the
discovery that forwarding cannot reach it."

It then found five things wrong with the revised plan. Three change what gets built.

## Corrections to the revised plan

**R1 — opus overreached on the phantom `/credential` keys; DO NOT delete them.** Every key in
`ROUTE_DISPOSITIONS` is bare-form *by convention*: dedup strips `/api/` (`route-gate.ts:304-306`),
disposition lookup falls back `/api/`→bare (`routes.dispositions.ts:339-345`), and orphan matching
does the same (`route-gate.ts:327-331`). The `/credential` keys are matched by exactly the same
fallback as the six `/integration` keys. Deleting them would leave two real denials
(`routes.classification.ts:66-67`) undispositioned and **fail the gate**. So F8's "two smaller
drifts" is one drift: the `PATCH /config` omission is real, the `/credential` one is a misreading.
Residual worth a gate-header note: one bare key silently speaks for both the bare and `/api/` forms,
so if those ever diverge upstream, one disposition covers two behaviours.

**R2 — the live 403 body recommends the exact footgun this plan exists to prevent.** Verified at
`proxy.ts:563-573`: the wire message says *"Call a serve port directly."* For
`PUT /auth/{providerID}` that instructs the user to create the false success we are refusing to
ship — write one serve, leave three plus the writer's own booted instances on a stale credential
indefinitely. The `rationale` field is gate-side data; **nothing puts it on the wire**. The
superseded option 3 had this right ("replace the generic 403 with a specific message naming the real
constraint") and the revised plan silently dropped that half. This is the one thing the second
review wrongly discarded, and it is now the highest-value item in the plan.

**R3 — step 2's single rationale is false for B1, recommitting F8's own sin one generation later.**
"No directory context at all" is true only for the `/auth/{providerID}` pair
(`groups/control.ts:36-75`, `AuthParams:8-10`). The B1 provider-OAuth routes *do* have directory
context — the whole B1 analysis depends on it. Their real constraint is process-pinned RAM plus F3.
Also `not-session-scopable` **requires** a `tuiSurface` value (`route-gate.ts:396-411`), and the TUI
demonstrably calls both B1 routes, so `absent` is wrong and `degrades` requires a real
through-door-consequence audit — the same audit that found the console/switch crash risk. "Relabel
four rows" therefore contains an uncosted TUI failure-mode audit.

**R4 — "leave it denied" as drafted is not stable; it decays.** Stranding B2+C as
`needs-mechanism` means: the pinned list never empties, so the completion criterion becomes
permanently unmet rather than retired; the `needs-mechanism` kind *requires* a bead
(`route-gate.ts:385-394`), so five live rows would cite a **closed** bead; and the next agent reading
`route-gate.ts:82` plus a `needs-mechanism` label will conclude the mechanism is still wanted and
implement the falsified hash design, whose failure mode is documented only in this file.

**R5 — the second pinned list is a tripwire, not a fix.** It closes the compensating-swap hole
between the two big buckets, but no list can catch the wrong-at-birth classification — which is
exactly how `/api/integration/*` got its wrong label. Structurally better: add a required,
machine-visible `constraint` enum to `RouteDisposition` (`'no-session-context' |
'process-pinned-ram' | 'shared-disk-plus-stale-cache' | …`) and pin the census over *constraints*,
forcing every future author to answer the F8 question at write time for every row. And rewrite the
gate's self-description honestly: **the gate proves the tables agree with themselves and with
/doc's shape; it cannot prove any label is true; truth comes from audit on pin-bump.**

**R6 — B2 denial is a choice, not a consequence.** F1 falsifies *hashing* and thereby confirms
ANCHOR, which already exists as `forward-anchor`. The defensible reason to deny anyway is that the
**19876 squat is live on this box**: `ensureRunning` returns success-without-binding if anything
owns the port, and tonight's incident class (accidental `opencode` spawns) is exactly what binds it
first and silently breaks every anchored MCP OAuth flow with no error at bind time. Either way,
that paragraph must exist in the disposition — "right now it gets neither, and that silence is where
the next incident lives."

**R7 — CLI sharp edges.** `PUT ×4` is *worse* than `PUT ×1`: the file is shared and unlocked, so
four redundant whole-document writes quadruple the lost-update window against a concurrent token
refresh for zero benefit. Write once, dispose everywhere. And `POST /global/dispose` is a
**pool-wide outage** (every directory, every in-flight run cancelled, every stdio MCP child
SIGTERMed, on each serve in turn) — acceptable for rare manual rotation only if the CLI says so
loudly and ideally checks pigeon for in-flight runs first. Expect a cold-boot 503 wave afterwards.

**R8 — step 6 oversells.** Flock + writer-cache invalidation fixes the torn write and the *writer's*
staleness; the other three members have no watcher and no read path, so the cross-process staleness
that is the actual Group A blocker survives. Either the upstream ask includes mtime-check-on-read in
the provider SDK path, or the CLI is the **permanent** pool-invalidation mechanism, not a stopgap.

## Step 1 is safer than assumed — verified, and already applied

Fable independently confirmed and sharpened this. `hosts/cloudbox/configuration.nix:709` sets
`restartIfChanged = false` on `opencode-serve@`, so `nixos-rebuild switch` deploys the env change
**without bouncing the pool** — the "no SSE drop" claim is true *because of that line*. Blast radius
is exactly one plugin (`git grep OPENCODE_HEADLESS` in v1.17.13 core: zero hits; no other plugin in
the cache reads it). Two caveats now written into the unit comment: it is **not live until each
serve restarts** (the nightly reset absorbs it — do not verify same-day and conclude it failed), and
all four units are currently `active`, so "one member down" is a *routing-slot* condition invisible
to `systemctl` — verify via pigeon, not systemd.

## Final plan

1. **`OPENCODE_HEADLESS=1`** in the serve unit. **DONE** (committed; user deploys).
2. **Wire the constraint to the user (R2).** Make the denial handler consult the disposition table
   and emit the real rationale plus the CLI invocation in the 403/405 body, replacing "call a serve
   port directly" for these rows. Highest value in the plan; the only part of "honest denial" that is
   honest to the *user* rather than to the repo.
3. **Add the `constraint` enum (R5)** and pin its census; rewrite the gate's self-description; add
   the bare-key note (R1). Do **not** delete the `/credential` keys.
4. **Introduce a terminal disposition kind (R4)** for rows where denial is the decision, not a gap,
   so the pinned list empties truthfully and the bead can close without orphaning five rows against
   it. Move B2 and C there, each with the F1/F2 evidence and the 19876-squat paragraph (R6) inline.
5. **Relabel A and B1 separately (R3)**, with their two *different* real constraints, and do the
   through-door-consequence audit that `tuiSurface: 'degrades'` requires.
6. **CLI escape hatch** with R7's corrections: write auth once, dispose everywhere, announce the
   outage, expect the 503 wave.
7. **Upstream fix**, described honestly per R8.
