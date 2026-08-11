# dx8p Stage 1 — pigeon bearer token

**Bead:** `workstation-dx8p` (P1). **Status: PLAN v3, cleared for SDD.**
**Strategy context:** `docs/plans/2026-07-26-frontdoor-spine.md` §3.

> **v3 (2026-07-26)** — after `adversarial-reviewer-fable`, which returned *"not
> safe to execute as written"* against v2 and was right on both counts (each
> independently verified before acceptance, below). Two user decisions are baked
> in: **call-time secret reads** (not staged arming) and **fix lgtm in scope**.
>
> Version history, because the size estimate moved twice and that is the story:
> v1 "small, mostly already built" → v2 "the caller sweep is the work, 4 callers"
> → **v3 "9 callers across THREE repos, and the ordering problem is designed away
> rather than sequenced around."**

## Goal

Every anonymous request to pigeon (`:4731`) returns 401, except `GET /health`.

Stage 1 of 4. It does **not** deliver opacity as a property (`ss -tlnp` still
reveals the pool; serve ports stay open — Stages 2/4). It converts silent drift
into a loud, attributable 401 at the moment of writing, which is what the real
threat model — *our own agents taking shortcuts* — actually calls for.

## Measured route surface (`packages/daemon/src/app.ts`)

`checkAuth` protects `POST` + `DELETE` + `GET /route` (`auth.ts:5-8`).

| Route | Method | line | Today |
|---|---|---|---|
| `/health` | GET | 122 | anon — **stays anon** (verified to exist; leak-free) |
| `/sessions` | GET | 325 | **anon — 166 KB inventory** |
| `/swarm/inbox` | GET | 203 | **anon — message bodies** (not in the bead) |
| `/sessions/<id>` | GET | 567 | **anon — per-session detail** (not in the bead) |
| `/route` | GET | 618 | protected |
| `/alert` `/swarm/send` `/session-start` `/sessions/enable-notify` `/cleanup` `/stop` `/question-asked` `/question-answered` `/place` | POST | — | protected |
| `/sessions/<id>` | DELETE | 575 | protected |

Two of the three leaks were absent from `dx8p`'s description and were found only
by enumerating `app.ts`. An enumerated deny list would have missed both again —
the argument for deny-by-default, in evidence rather than in principle.

## Traps

**T1 — the original.** Setting the token leaves `GET /sessions` wide open while
*feeling* closed.

**T2 — this reverses a documented, tested decision.**
`packages/daemon/src/routing/README.md:99` says *"`GET` reads (`/health`,
`/sessions`, `/swarm/inbox`) are intentionally unprotected"*, and
`packages/daemon/test/auth.test.ts:79` enshrines it as a **passing test**
(*"7. Read route open: GET /sessions … -> not 401"*). Both must move in the same
commit as the inversion, or the suite goes red and the obvious "fix" is to revert
the security change.

**T3 — the spine doc's "refuted oracle claim" is half wrong.** Spine §3 cites
`daemon-client.ts:105` and `swarm-send-tool.ts:268` to dismiss the oracle's
warning about swarm breakage. Both send the bearer — **for `swarm_send`**.
`swarm_read` (`swarm-tool.ts`) has no `Authorization` header at all, on purpose
(`docs/plans/2026-06-23-swarm-send-tool-design.md:67`). Falsification #3 of
spine §7's pattern: *check one member, generalise to the family.* Fix spine §3 too.

**T4 — I made that same error again while writing v2.** I quoted
`routing/README.md:99` without reading `:94-98`, three lines above, which says:
*"EVERY daemon client must send the bearer … any other daemon callers … must be
updated in the SAME change, or their requests will 401."* That warning names the
exact failure v2 then shipped. **Read the paragraph, not the line.**

## Consumer inventory — 9 callers, THREE repos (fable-corrected, verified)

`~/projects/lgtm` is a third repo. v2's sweep covered two and therefore found
**zero of two** live lgtm callers.

**Group A — 401 the instant the token is set, regardless of any `auth.ts` edit**
(they call already-protected routes):

| # | Caller | Route | Failure |
|---|---|---|---|
| A1 | `hosts/cloudbox/configuration.nix:137` | `POST /alert` | **SILENT** — swallowed to a journal WARNING |
| A2 | `pkgs/opencode-launch/default.nix:362` | `GET /route` | soft-degrade → `$OPENCODE_URL` |
| A3 | `pkgs/oc-pool-attach/default.nix:127` | `GET /route` | soft-degrade (has auth for `/place` at :131, **not** `/route`) |
| A4 | `pkgs/oc-auto-attach/default.nix:359` | `GET /route` | soft-degrade → anchor; forces door drift-reconnect |
| A5 | `~/projects/lgtm/src/dispatch.ts:174-189` | `POST /swarm/send` | **HARD, every 10 min** — throws on non-202 |
| A6 | `~/projects/lgtm/src/alert.ts:36-44` | `POST /alert` | **SILENT** |
| A7 | opencode-serve pool (plugin: `daemon-client.ts:105`) | `POST /session-start`, `/stop`, `/question-asked` | **SILENT** — circuit breaker opens, Telegram notifications die |

A1's failure was **predicted in-tree** at `configuration.nix:130-134`, which
instructs that any 9.2 auth-enablement must update these callers. Honour it: make
A1 loud.

A7 is the one v2 missed structurally — the plugin runs *inside* the serve
processes, and the serve unit env (`configuration.nix:743+`) contains no `PIGEON_*`
variable at all; the plugin self-defaults to `:4731` (`daemon-client.ts:74-79`).

**Group B — 401 only because of the inversion:**

| # | Caller | Route | Failure |
|---|---|---|---|
| B1 | `pigeon/packages/opencode-plugin/src/swarm-tool.ts` | `GET /swarm/inbox` | **HARD** — `swarm_read` throws in every session |

**Verified NOT affected:** no consumer anywhere calls `GET /sessions` (Phase 9
removed the last one; fable re-swept `~/projects` and `~/.local/bin`).
`pigeon-send` CLI no longer exists. `reset-workspace` makes no pigeon HTTP call.
The door already sends the bearer (`config.ts:64-66` → `resolve.ts:46`,
`place.ts:37`, `healthz.ts:27`).

## The ordering problem, and why we are not sequencing around it

Restart semantics make "one atomic activation" **impossible**: `pigeon-daemon`
has no `restartIfChanged`, so a rebuild restarts it **armed**, while the door
(`configuration.nix:1718`) and all four serves (`:713`) are
`restartIfChanged = false` and keep their stale, tokenless env. Fable walked the
window: door `/route` → 401 → `resolve.ts:75-84` marks `pigeon-error` → reads
degrade to the anchor and `proxy.ts:740-745` **503s every mutating request**
without a sticky. Typed prompts fail in ~20 live TUIs. Serves silently lose
notifications until the nightly reset — up to 24h.

**Decision (user): dissolve it instead.** Every client resolves the token
**at call time**:

> `PIGEON_DAEMON_AUTH_TOKEN` if set, **else** read
> `/run/secrets/pigeon_daemon_auth_token` if readable, else no header.

Consequences: a process started before the secret existed still authenticates on
its next call. **No pool bounce. No staged rebuild. No dropped SSE legs. No
stranded sessions.** Future units get it free. On devbox/darwin `/run/secrets`
is absent, so it is an automatic no-op — same back-compat property as the falsy
token branch.

**Caching rule:** short-lived shell processes read per call (a tmpfs read; do not
optimise). Long-lived TS processes (door, plugin) cache lazily and **invalidate on
any 401, then retry once** — which also makes token rotation work without a
restart. Do not build an mtime cache; the 401-invalidate path is strictly simpler
and self-correcting.

## Tasks

Tasks 1–4 are no-ops while the secret is absent, so they can land in any order,
before the secret exists. **Task 6 is the only irreversible-feeling step, and it
is one rebuild.**

### Task 1 — pigeon plugin: token resolution + the missing header
Repo `~/projects/pigeon`. Add a small `resolveDaemonToken()` helper (env → file →
undefined) and use it in:
- `swarm-tool.ts` — **B1**, currently sends no header at all; add one
- `daemon-client.ts:105` — **A7**, replace env-only read
- `swarm-send-tool.ts:268` — same

Mirror the existing `if (token) headers["Authorization"] = \`Bearer ${token}\``
idiom (`swarm-send-tool.ts:135`) rather than inventing a second style.

*Done test:* unit tests — header present when env set; present when env unset but
file readable; absent when neither; 401 invalidates the cache and retries once.

### Task 2 — workstation shell callers (A1–A4)
Add a shared bash idiom resolving the token per call, applied to A1–A4. A3/A4
already have the `place_auth=()` pattern for `/place` a few lines away — extend it
to the `/route` call and re-point it at the resolver.

**A1 must become loud**: a 401 from `/alert` must not be swallowed into a WARNING,
per the in-tree instruction at `configuration.nix:130-134`.

*Done test:* each `pkgs/*/test.sh` asserts the header is sent for both sources
(env set; env unset + file present). Follow existing `test.sh` conventions.

### Task 3 — workstation door
`pkgs/opencode-frontdoor/src/config.ts:66` — env-only today. Add the file
fallback + 401-invalidate-and-retry. **This is what lets us skip the manual door
restart** that would otherwise drop every live SSE leg.

### Task 4 — lgtm (A5, A6)
Repo `~/projects/lgtm`. Add the bearer (same env→file resolution) to
`dispatch.ts:174-189` and `alert.ts:36-44`.

*Note:* lgtm's timer fires **every 10 minutes**, so a regression here is loud and
fast — good. Verify against a real cycle, not just unit tests.

### Task 5 — pigeon: invert `checkAuth`
`packages/daemon/src/auth.ts` → deny by default; anonymous allowlist is exactly
**`GET /health`** (`app.ts:122`, verified leak-free), commented with its
justification. Keep the falsy-token back-compat branch (`auth.ts:4`).

Same commit: **invert `test/auth.test.ts:79`** (test 7) to assert 401 and rename
it; **update `routing/README.md:94-99`**. Add a daemon boot log line
(`auth: enabled|disabled`) so "configured ≠ running" is checkable.

Confirm the deny-by-default path handles unmatched routes (404s), and `OPTIONS`/
`HEAD`, without changing existing 400/404 semantics a caller depends on.

*Done test:* with a token — `/sessions`, `/sessions/<id>`, `/swarm/inbox`,
`/route`, `POST /place` → 401 bare, non-401 with bearer; `/health` → 200 bare.
Without a token — all non-401. Full daemon suite (`vitest run`), not just
`auth.test.ts`.

### Task 6 — sops secret + arm pigeon (the flip)
`pigeon_daemon_auth_token` in `secrets/cloudbox.yaml` + `sops.secrets` with
**`owner = "dev"`** (default is root:0400; pigeon/serves/door run as `dev`).
Value `openssl rand -hex 32`. Export it on the pigeon unit
(`configuration.nix:564+`, beside `CCR_*`).

*Done test:* `/run/secrets/pigeon_daemon_auth_token` exists, readable by `dev`;
pigeon logs `auth: enabled`.

### Task 7 — delete the phantom route
`ses_0000000000000000000000000 -> serve-0`, written by an adversarial-reviewer
probe proving `POST /place` is an unauthenticated write. Read-only verify first.
**No admin endpoint exists**, so this is a sqlite write against pigeon's live WAL
DB — state the exact command and take care, or stop pigeon for the deletion.

### Task 8 — regression guard (runtime, not source grep)
Canary assertions: anonymous `:4731/sessions` **and** `/swarm/inbox` → 401 (an
enumerated list missed `/swarm/inbox` once already); `/health` → 200.

Plus **aggregate-degrade detection**, which the v2 guard could not see: assert
door `/healthz` reports pigeon reachable and the degrade counters
(`proxy.ts:752-754` `notRoutedMutationToAnchor`, resolve `degraded` rate) stay
~0. Under a token misconfiguration everything degrades to serve-0 at once and —
because all serves share one `opencode.db` — **it still looks like it works.**
That is the pool-collapse-disguised-as-success failure this guard exists for.

## Verification

1. Anonymous → 401: `/sessions`, `/sessions/<id>`, `/swarm/inbox`, `/route`,
   `POST /place`. Anonymous `/health` → 200.
2. With bearer → non-401 for all of the above.
3. `opencode attach` TUIs still work; `:4700` connection count unchanged; **no
   door or serve restart was required**.
4. **`swarm_send` AND `swarm_read`** work end-to-end between two live sessions —
   test `swarm_read` explicitly, it is the one with no header today.
5. `opencode-launch` still launches.
6. lgtm completes a full 10-minute cycle: dispatch 202, alert 2xx. Assert a
   positive, not the absence of noise.
7. Journal-alert canary (A1) delivers, asserting 2xx.
8. Nightly `reset-workspace` completes.
9. `bash users/dev/test-frontdoor-opacity.sh` green.

Fable checked for retry storms explicitly and found **none**: swarm-send treats
401 as non-retryable (`swarm-send-tool.ts:97-114`), daemon-client has a capped
circuit breaker (`:95-101`), door resolve degrades without retrying.

## Rollback

Cheap and worth writing down: sshd is untouched, so the box is always reachable.
The falsy-token branch (`auth.ts:4`) means **removing the export from pigeon's
unit and restarting pigeon restores anonymous service immediately** — no revert
of the client changes needed, since every client's header is a harmless no-op
when unauthenticated service resumes.

## Deploy — runbook

**Step 1 (mint the secret) is DONE.** `pigeon_daemon_auth_token` is a 64-hex-char
value, encrypted at rest in `secrets/cloudbox.yaml`, committed.

> **Correction.** An earlier version of this section claimed the agent could not
> do this because "sudo is unusable from an opencode session". That was wrong —
> see spine §3/§7(c). `sudo` on `$PATH` is the non-setuid copy in `system-path`;
> `/run/wrappers/bin/sudo` is the setuid wrapper and works passwordlessly. The
> error message describes the *binary*, not a policy.
>
> **And a near-miss worth keeping:** the first attempt used
> `openssl rand -hex 32`, but `openssl` is not on this box's PATH. `$TOKEN`
> expanded to empty, `sops set` stored an empty string without complaint, and an
> **empty token disables auth via `checkAuth`'s falsy branch while everything
> looks configured.** Caught only because verification decrypted the value and
> checked its length instead of trusting the exit code. Generate with
> `head -c 32 /dev/urandom | od -An -tx1 | tr -d " \n"` and **always verify the
> decrypted length is 64.**

**Step 2 — deploy** (operator; the standing rule is that the user deploys):

```bash
sudo nixos-rebuild switch --flake .#cloudbox
ls -lat ~/.local/state/nix/profiles/ | head -3   # confirm by TIMESTAMP, not by the command appearing to run
```

**CORRECTED 2026-07-26 after this broke in production.** The line that used to
sit here — *"the door and the four serves deliberately do NOT need restarting"* —
was **wrong**, and following it caused an incident. See spine §7(e).

Call-time resolution only helps a process **already running the call-time code**,
and that code ships in this same rebuild. The door and the serves are
`restartIfChanged = false`, so they keep running the OLD build, send no bearer,
and get 401ed by a freshly-armed pigeon. For the door that means
`resolveOwner` → `pigeon-error` → **503 on every mutating request**, i.e. typed
prompts failing across live TUIs.

The correct sequence is therefore:

```bash
sudo nixos-rebuild switch --flake .#cloudbox     # units, secret, door + pigeon packages
nix run home-manager -- switch --flake .#cloudbox # REQUIRED: opencode-launch and
                                                  # oc-auto-attach are home-manager
                                                  # packages, NOT NixOS ones
sudo systemctl restart opencode-frontdoor.service # REQUIRED: restartIfChanged=false
                                                  # means it is still on the old build
ls -lat ~/.local/state/nix/profiles/ | head -3    # confirm by TIMESTAMP
```

**The serve pool also needs a restart** (`opencode-serve-pool.target`) before
`swarm_send`/`swarm_read` and the daemon-client notifications work — opencode
`import`s the plugin once per process with no cache-bust, so a serve started
before the plugin commit runs pre-token code no matter what the file says.
That bounce kills in-flight turns, so it is a deliberate choice: do it, or let
the 03:00 nightly reset absorb it. **Until then, swarm messaging and Telegram
question/stop notifications are silently dead.**

Only the door restart is *urgent* — that one is a live 503.

**Step 3 — verify:**

```bash
bash users/dev/test-pigeon-auth-canary.sh              # must go GREEN; RED today by design
# CORRECTION (2026-08-11, workstation-9f7a): --namespace=pigeon is now REQUIRED.
# Without it this prints nothing, which looks exactly like "auth is not enabled".
journalctl --namespace=pigeon -u pigeon-daemon -n 20 | grep 'auth:'   # expect "auth: enabled"
```

Then walk the Verification list below, with particular attention to #4
(`swarm_read` — no header at all until today) and #6 (lgtm, whose timer fires
every 10 minutes, so a regression surfaces fast).

**Step 4 — Task 7, the phantom route.** Last, once `POST /place` is authenticated
and the phantom cannot be recreated. Use the daemon's own authenticated
`DELETE /sessions/<id>` (`app.ts:575`) rather than a sqlite write against
pigeon's live WAL.

**Rollback** is step 2 of the Rollback section: delete the one `export` line from
pigeon's unit, rebuild, restart pigeon.

**Confirm by generation timestamp, not by the command appearing to run:**
`ls -lat ~/.local/state/nix/profiles/`.

Pigeon on cloudbox runs from the **live worktree via tsx**
(`configuration.nix:579`) and the plugin loads from worktree source
(`opencode-config.nix:461-465`). So landing Tasks 1/5 means a git pull into a
**shared worktree with live peer work** — never `git stash/checkout/reset/clean`
there. It also means the inversion goes live on any pigeon crash-restart after
the pull; safe only because of the falsy-token branch. Keep auth test 1.

**The user deploys. Do not auto-deploy.**

## Out of scope

Stage 2 (serve token), Stage 3 (degrade into the door), Stage 4 (netns —
escalation only), `workstation-vjq0`, `workstation-u417`.

Optional, non-blocking: add the secret to `shell-env.ts`'s hardcoded
`loadSecretEnv` list (`:32-63`) so bash tools get the env var directly. Nice, but
**not depended upon** — it only takes effect after a serve restart, and Task 2's
call-time read already covers the case.

**Next work after this lands: `workstation-y8m`** — the only open P0.
