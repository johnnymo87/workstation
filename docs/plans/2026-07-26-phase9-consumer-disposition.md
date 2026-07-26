# Phase 9.0 — `OPENCODE_URL` consumer disposition table

**Status: COMMITTED ARTIFACT.** This is the door's permanent exemption record.
Task 9.0 of `docs/plans/2026-07-12-serve-reverse-proxy-plan.md` says *"commit the
audit"*; until this file existed, the claim "9.0 done" rested on a bead note that
predated Phases 8/10 and therefore never revisited these sites. That is precisely
how two direct-to-serve call sites survived three audits.

Bead: `workstation-mlve.4`. Objective: **network opacity** — nothing on this box
addresses an individual serve except the door.

## How to use this table

Every consumer that could address a serve is listed with a disposition. If you
add a consumer, add a row. The 9.2 grep-guard enforces the `door` rows; the
`exempt` rows are the guard's allowlist and each one states *why* it cannot ride
the door. **An exemption without a stated mechanism is a bug, not an exemption.**

| Disposition | Meaning |
|---|---|
| `door` | Rides `$FRONTDOOR_URL` (`:4700`). The default. |
| `exempt-control` | Control plane. Routing it through the data plane it feeds is a cycle. |
| `exempt-infra` | Must diagnose/act on an individual serve; the door hides exactly what it needs. |
| `exempt-degrade` | Anchor is a *fallback* when the door or pigeon fails. Never the primary. |
| `host-scoped` | Host has no door. Not a violation; a deployment boundary. |

---

## Ground truth as measured, 2026-07-26 (cloudbox)

Measured, not assumed — this table's whole purpose is to stop the assuming.

- **20 of 20 live `opencode attach` TUIs are on `http://127.0.0.1:4700`.** Zero on
  any serve port. (`/proc/<pid>/cmdline` for every `opencode attach` pid.)
- **Every process holding a connection to a pool port is either the door
  (pid 3910932, the `:4700` listener) or a serve itself.** No external consumer
  reaches a serve at runtime.
- **Pigeon is fully token-gated**: `GET /route` → 401, `POST /place` → 401,
  `GET /sessions` → 401 (unauthenticated). The roadmap's "`GET /sessions` is
  unauthenticated, so a `/route` token does not deliver opacity" finding is
  **superseded** — it is gated now.

**Therefore Phase 9.1 (the repoint) is DONE**, landed in `f878865`
("Phase 9 attach-through-door (co-land)"), and the runtime objective is
substantially met. What remains is latent code paths and the missing artifact.

### Correction to `docs/plans/2026-07-26-frontdoor-spine.md`

That file states *"The objective is NOT met… The TUI does not go through the
front door,"* citing `hosts/cloudbox/configuration.nix:576,631`. **Both claims are
wrong**, and acting on them would cause an outage:

- The TUI *does* ride the door (20/20, measured above).
- `:576` and `:631` are not the TUI and not violations. They are **deliberate,
  commented, test-enforced exemptions** (rows C1, C2 below). Repointing `:576` to
  `:4700` creates the pigeon⇄door startup cycle its own comment forbids and trips
  `users/dev/test-pool-route-clients.sh:97-98`.

The spine doc's *framing* (opacity is the objective; don't let fast-follows
capture the work) stands. Its *status claim* does not. Corrected there in the
same commit as this file.

---

## A. Data plane — through the door (`door`)

| # | Site | What | Evidence |
|---|---|---|---|
| A1 | `pkgs/oc-pool-attach/default.nix:67,86,92,97,108,136` | Interactive attach: health, create, session read, `attach $FRONTDOOR_URL` | guarded by `pkgs/oc-pool-attach/test.sh:193-208,235` |
| A2 | `pkgs/oc-auto-attach/default.nix:29,327,331,521` | Auto-attach: session probe + attach URL handed to nvim | guarded by `pkgs/oc-auto-attach/test-project-key.sh:488-497` |
| A3 | `pkgs/opencode-launch/default.nix:235,253,342,410,448` | health, `/config/providers`, create, `prompt_async`, kill hint | guarded by `pkgs/opencode-launch/test.sh:179-228` |
| A4 | `pkgs/reset-workspace/default.nix:478,493` | `CAPTURE_URL="$FRONTDOOR_URL"` — manifest capture | guarded by `pkgs/reset-workspace/test.sh:396,409` |
| A5 | `users/dev/home.base.nix:1199,1250` | `lgtm-sessions` health check + session list | guarded by `users/dev/test-pool-route-clients.sh:80-84` |

## B. Data plane — STILL DIRECT TO SERVE (the remaining work)

These are the only real violations. All three are in `mlve.4`'s scope.

| # | Site | What | Disposition | Why it is fixable now |
|---|---|---|---|---|
| B1 | `pkgs/opencode-launch/default.nix:374` | `POST $serve_url/mcp/$srv/connect` | **repoint → door** | Comment says *"the front door denies MCP connect with 405"* — **doubly stale**. Phase 10 added `POST /session/{sessionID}/mcp/{name}/connect`, class `session-path` (`routes.classification.ts:216`), and the TUI itself migrated. `opencode-launch` has the sid in hand. |
| B2 | `pkgs/opencode-launch/default.nix:447` | `echo "Attach: opencode attach $serve_url"` | **repoint → door** | Hint contradicts A1/A2, which attach to the door. Emitting a serve URL teaches the human the internals. |
| B3 | `users/dev/home.base.nix:1306-1307` | `attach_hints+=( "opencode attach $serve_url" )` | **repoint → door** | Justified by a now-false comment at `:1163-1167` (*"the interactive TUI can't ride the door until Phase 8/9"*). Phase 8/9 landed. Drops the per-session `/route` call entirely. |

**`users/dev/test-pool-route-clients.sh:74-75` pins B3's stale behaviour as
correct.** It must be *rewritten*, not deleted — it is the guard that keeps B3
fixed once fixed.

## C. Control plane / infra — anchor by design (`exempt-*`)

Each row states the mechanism that makes the door wrong. None may be "cleaned up".

| # | Site | Disposition | Mechanism |
|---|---|---|---|
| C1 | `hosts/cloudbox/configuration.nix:576` (pigeon-daemon `OPENCODE_URL=:4096`) | `exempt-control` | **Pigeon is the router the door depends on.** Door→pigeon→door is a startup cycle. Comment `:570-575`; enforced by `test-pool-route-clients.sh:97-98` (which also *denies* the `:4700` string). |
| C2 | `hosts/cloudbox/configuration.nix:631` (`lgtm-run`) | `exempt-degrade` | Children (`opencode-launch`) read `$OPENCODE_URL` as their **raw-anchor degrade fallback**. Pointing it at the door poisons the fallback: a pigeon hiccup would degrade *to the door*, where MCP-connect is denied. Unit is also `enableLgtm=false`. |
| C3 | `hosts/cloudbox/configuration.nix:1682`, `pkgs/opencode-frontdoor/src/config.ts:65` | `exempt-infra` | The door's **own** upstream. Tautologically not through itself. |
| C4 | `hosts/cloudbox/configuration.nix:1879` (frontdoor canary) | `exempt-infra` | Probes the anchor directly to distinguish *door down* from *pool down*. Through the door it could not tell them apart. |
| C5 | `pkgs/reset-workspace/default.nix:131,806` (`discover_pool_urls`) | `exempt-infra` | Verifies **per-serve** readiness after restart. Comment `:807`: *"per-serve liveness can't be verified through the opaque door."* Exactly right — the door's job is to hide which member answered. |
| C6 | `pkgs/oc-auto-attach/default.nix:358-371` (`/route`→`/place` pre-place) | `exempt-infra` | Resolves `serve_url` but **never attaches to it** (attach target is `$FRONTDOOR_URL`, `:521`). Pre-placement exists so the door's first `/event?session_ids=` resolve lands on the real owner instead of drift-reconnecting. Comment `:354-357` already says Phase 9 keeps this. |
| C7 | `pkgs/opencode-launch/default.nix:415` (`prompt_async` retry) | `exempt-degrade` | Fires **only** after the door path fails (`:410`). Explicit never-worse degrade, announced on stderr `:414`. |

## D. Other hosts (`host-scoped`)

`opencode-frontdoor` is deployed on **cloudbox only** (`rg -l opencode-frontdoor`
→ `hosts/cloudbox/configuration.nix`, `users/dev/home.cloudbox.nix`,
`users/dev/home.base.nix`).

| # | Site | Disposition |
|---|---|---|
| D1 | `hosts/devbox/configuration.nix:290` | `host-scoped` — no door on devbox; `:4096` is the only endpoint. |
| D2 | `users/dev/home.darwin.nix:124` | `host-scoped` — no door on darwin. |

The shared defaults in `home.base.nix:1163,1169` (`OPENCODE_URL:-:4096`,
`FRONTDOOR_URL:-:4700`) are cross-host and must stay parameterised. Convergence
is a named successor decision, not an omission.

---

## What "Phase 9 complete" means, given the above

1. ~~9.0 commit the table~~ — **this file**.
2. B1, B2, B3 repointed; `test-pool-route-clients.sh:74-75` rewritten to pin the
   *new* behaviour.
3. 9.2 grep-guard: no non-exempt caller addresses a serve. This table is its
   allowlist.
4. 9.2 token: **already satisfied** — pigeon `/route`, `/place`, `/sessions` all
   401. Was carried as "deferred"; measurement says otherwise.

Note the sequencing rule from `mlve.4` no longer gates anything here: it said
*"do not repoint `OPENCODE_URL` until `vkv2` lands"*, but the repoint already
happened in `f878865`. `PUT /auth`'s *"Saved credential"* lie is therefore
**live today**, not a future risk — which raises `vkv2`/`u417`'s priority rather
than lowering it, and is now the honest argument for doing them.
