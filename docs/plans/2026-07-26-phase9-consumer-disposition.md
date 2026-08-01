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
- ~~**Pigeon is fully token-gated**: `GET /route` → 401, `POST /place` → 401,
  `GET /sessions` → 401. The roadmap's "`GET /sessions` is unauthenticated"
  finding is **superseded** — it is gated now.~~
  **RETRACTED 2026-07-26, same day, by adversarial review. THIS WAS FALSE AND I
  MEASURED THE WRONG PORT.** Pigeon — the router every consumer in this repo
  actually addresses — listens on **`:4731`**, not `:4731`'s neighbour `:8789`.
  I probed `:8789`, which is a *different process* (pid 432262), got 401 on
  everything, and generalised. Re-measured on `:4731` (pid 743412, node):

  | endpoint | auth | result |
  |---|---|---|
  | `GET /sessions` | none | **200, 166 KB** — full inventory: sids, cwds, pids, labels |
  | `GET /route?session_id=…` | none | **200** — resolves a real session to its serve `apiBase` |
  | `POST /place` | none | **200** — *mutates routing*; the reviewer's probe wrote a phantom route for `ses_0000…0` → serve-0, still resolvable |

  Consumers use `:4731` everywhere: `pkgs/opencode-launch/default.nix:25`,
  `pkgs/oc-pool-attach/default.nix:68`, `pkgs/oc-auto-attach/default.nix:36`,
  `pkgs/opencode-frontdoor/src/config.ts:64`.

  **The roadmap's original finding stands and was correct.** So does its
  conclusion: a `/route` token would not have delivered opacity anyway, because
  `/sessions` hands out the same endpoints. And unauthenticated `POST /place` is
  worse than a disclosure leak — it is a **routing-integrity** hole: any local
  process can re-place any session.

  **Why this error is worse than the one it replaced.** The spine doc's earlier
  false claim was an unverified assertion inherited from a note. This one came
  with a measurement attached, which makes it *harder* to dislodge — it reads as
  settled. The root cause is banal and worth naming: I searched for the listener
  with `ss -tlnp | grep -E '878[0-9]|pigeon'`, a pattern that could only find the
  port I had already guessed. I had read `PIGEON_DAEMON_URL:-http://127.0.0.1:4731`
  earlier in the same session — and deleted that very line as dead code — without
  connecting it. **Measuring the wrong thing confidently is not better than not
  measuring; derive the target from the code that uses it, never from a guess
  confirmed by a matching grep.**

**Therefore Phase 9.1 (the repoint) is DONE**, landed in `f878865`
("Phase 9 attach-through-door (co-land)").

**But the opacity objective is NOT met, via pigeon.** The door hides which serve
owns a session; `GET :4731/sessions` then hands that inventory to any local
process unauthenticated, and `POST :4731/place` lets it rewrite routing. Phase 9
is therefore **not** complete: its 9.2 token half is genuinely outstanding, not
"already satisfied". Tracked as `workstation-dx8p`.

Scope of what *is* achieved: **no shipped consumer in this repo addresses an
individual serve on a non-degrade path** (rows A/B/C below), and no external
process was observed doing so at runtime. That is a real and enforceable
property — it is just narrower than "network opacity".

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

## B. Data plane — was direct-to-serve; **all three repointed 2026-07-26** (`e270598`)

These were the only real violations. All are now through the door; the rows are
retained because the *reasoning* is what stops them regressing, and because the
9.2 guard's `deny` assertions are derived from them.

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
| C7 | `pkgs/opencode-launch/default.nix` (`prompt_async` retry) | `exempt-degrade` | Fires **only** after the door path fails. Announced on stderr. **Caveat (adversarial review):** "never worse" is an overclaim. If the door's sticky is lost *and* pigeon is down, `serve_url` has degraded to the anchor, so the retry can execute the turn on a **non-owner** — mechanically fine (shared `opencode.db`) but MCP tools are absent and the turn is invisible to a door-attached TUI, inviting a duplicate turn. Load-bearing unstated invariant: launcher `$OPENCODE_URL` == door `OPENCODE_ANCHOR_URL` (two independent defaults, `opencode-launch:16` vs `config.ts:65`; coincide today, enforced nowhere). Tracked: `workstation-dx8p` sibling. |
| C8 | `pkgs/opencode-launch/default.nix` (MCP connect 503 degrade) | `exempt-degrade` | Fires **only** on a door `503`, which means "pigeon unavailable, refusing to route a mutating request to a non-owner" (`proxy.ts:741-745`). Without it a pigeon outage **hard-kills every `--mcp` launch**: create can't place → no sticky → 503 → `exit 1`, where the pre-Phase-9 code degraded and survived. Added after adversarial review caught the regression **post-deploy**. |
| C9 | `hosts/cloudbox/configuration.nix:529`, `hosts/devbox/configuration.nix:269` (`PIGEON_SERVE_ENDPOINTS=${servePool.endpointsCsv}`) | `exempt-control` | Pigeon's own data-plane fan-out: it must address **every** serve to route, health-check and reconcile them. Same control-plane rationale as C1, of which this is the other half — C1 covered only pigeon's `OPENCODE_URL`. **Was omitted from the first version of this table and invisible to the first guard**; found by adversarial review. |
| C10 | `users/dev/home.devbox.nix` (devbox door `OPENCODE_ANCHOR_URL`) | `exempt-infra` | Devbox analogue of C3: the door's **own** upstream, tautologically not through itself. Arrived with the devbox door in #217, which is also what falsified D1's "no door on devbox". |
| C11 | `users/dev/home.devbox.nix` (devbox frontdoor canary anchor cross-probe) | `exempt-infra` | Devbox analogue of C4: probes `:4096/global/health` directly so a door `503` can be told apart from a genuinely sick pool. Through the door the canary could not distinguish *door down* from *pool down*, which is the one thing it exists to do. |

## D. Other hosts (`host-scoped`)

`opencode-frontdoor` is deployed on **cloudbox only** (`rg -l opencode-frontdoor`
→ `hosts/cloudbox/configuration.nix`, `users/dev/home.cloudbox.nix`,
`users/dev/home.base.nix`).

| # | Site | Disposition |
|---|---|---|
| D1 | `hosts/devbox/configuration.nix` | `host-scoped` — devbox now runs its own door and pigeon; this row covers pigeon's fan-out on devbox, and the devbox door's own two sites are C10/C11. |
| D2 | `users/dev/home.darwin.nix:124` | `host-scoped` — no door on darwin. |

The shared defaults in `home.base.nix:1163,1169` (`OPENCODE_URL:-:4096`,
`FRONTDOOR_URL:-:4700`) are cross-host and must stay parameterised. Convergence
is a named successor decision, not an omission.

---

## How this table is enforced

`users/dev/test-frontdoor-opacity.sh` is the 9.2 grep-guard. It scans shipped
consumer code for serve-addressing call sites and requires each to carry an
inline marker naming a row **of this file**:

```
# frontdoor-exempt(C5): per-serve liveness; the door deliberately hides WHICH member answered
```

The marker lives in the code, not in a list inside the guard, and the row id is
validated against this file — so an exemption cannot outlive its call site, and
the table cannot drift from the code. A new direct-to-serve call fails closed.

Current state: **11 sites, 11 with a valid row.** The guard is perturbation-
tested (new unmarked call → fail; bogus row id → fail; table deleted → refuse to
run; pattern matching nothing → fail on vacuity).

> A guard bug worth remembering: the first draft used `[^\n]*`, which in a POSIX
> bracket expression means "neither a backslash nor the letter **n**" — so it
> silently skipped `reset-workspace:490` (`curl … --con**n**ect-timeout …`) while
> matching its identical siblings. It reported ALL PASS over an under-scan. Hence
> the explicit non-vacuity assertion.

## Phase 9 status

1. ~~9.0 commit the table~~ — **this file**.
2. ~~B1, B2, B3 repointed; the two tests that pinned the stale behaviour
   rewritten~~ — `e270598`.
3. ~~9.2 grep-guard~~ — `users/dev/test-frontdoor-opacity.sh`.
4. **9.2 token: OUTSTANDING.** Previously recorded here as "already satisfied";
   that was a wrong-port measurement, retracted above. `:4731/sessions` and
   `:4731/place` are unauthenticated today. `workstation-dx8p`.

**So Phase 9 is NOT complete.** Items 1-3 are done; item 4 is open and is the
part that actually delivers the user's stated objective.

**Remaining: deploy.** `home-manager switch --flake .#cloudbox` (picks up
`lgtm-sessions` + `opencode-launch`) and `nixos-rebuild switch --flake .#cloudbox`
(the exemption-marker comments only). No door code changed, so **no door restart
is required** — and per `workstation-hrfn`, do not "fix" that by setting
`restartIfChanged = true`.

Note the sequencing rule from `mlve.4` no longer gates anything here: it said
*"do not repoint `OPENCODE_URL` until `vkv2` lands"*, but the repoint already
happened in `f878865`. `PUT /auth`'s *"Saved credential"* lie is therefore
**live today**, not a future risk — which raises `vkv2`/`u417`'s priority rather
than lowering it, and is now the honest argument for doing them.
