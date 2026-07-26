# dx8p Stage 1 — pigeon bearer token

**Bead:** `workstation-dx8p` (P1). **Status: PLAN v2, pre-SDD.**
**Strategy context (read first):** `docs/plans/2026-07-26-frontdoor-spine.md` §3.

> **v2 (2026-07-26, after reading the code).** v1 called this "small; mostly
> already built". **That was wrong** and is corrected below. Merely *setting the
> token* — before any `auth.ts` edit — breaks four callers of routes that are
> **already protected today**. The `auth.ts` inversion then breaks a fifth. The
> env plumbing is not the easy half; the **caller sweep** is the work.

## Goal

Every anonymous request to pigeon (`:4731`) returns 401, except a liveness probe.

This is Stage 1 of 4. It does **not** deliver opacity as a property (`ss -tlnp`
still reveals the pool; serve ports stay open — Stages 2/4). It delivers "drift
becomes a loud 401 at the moment of writing", matching the real threat model:
*our own agents taking shortcuts*, not an attacker.

## Measured route surface (`packages/daemon/src/app.ts`, read 2026-07-26)

`checkAuth` protects `POST` + `DELETE` + `GET /route` (`auth.ts:5-8`). So:

| Route | Method | line | Today |
|---|---|---|---|
| `/health` | GET | 122 | anon — **keep anon** (verified to exist; not invented) |
| `/sessions` | GET | 325 | **anon — 166 KB inventory leak** |
| `/swarm/inbox` | GET | 203 | **anon — leaks message bodies** (not in the bead) |
| `/sessions/<id>` | GET | 567 | **anon — per-session detail** (not in the bead) |
| `/route` | GET | 618 | protected |
| `/alert`, `/swarm/send`, `/session-start`, `/sessions/enable-notify`, `/cleanup`, `/stop`, `/question-asked`, `/question-answered`, `/place` | POST | — | protected |
| `/sessions/<id>` | DELETE | 575 | protected |

Two leaks here (`/swarm/inbox`, `/sessions/<id>`) were **not** in `dx8p`'s
description. Deny-by-default catches them for free; an enumerated deny list would
have missed both again. That is the argument for the inversion, restated in
evidence rather than in principle.

## THE TRAP (unchanged, still first)

Turning the token on leaves `GET /sessions` wide open while *feeling* closed.

## THE SECOND TRAP — this is deliberate, not an oversight

`packages/daemon/src/routing/README.md:99` states:

> `GET` reads (`/health`, `/sessions`, `/swarm/inbox`) are intentionally unprotected.

And `packages/daemon/test/auth.test.ts:79` **enshrines it as a passing test**:

> `7. Read route open: GET /sessions with token set + no header -> not 401`

So this is a **documented, tested design decision being reversed** — not a bug
being fixed. Consequences for execution:

- Test 7 **must be inverted**, not extended. Left alone, the suite fails and the
  obvious "fix" is to revert the security change.
- `routing/README.md:99` must be updated in the same commit, or the next reader
  restores the hole on the doc's authority.

## THE THIRD TRAP — the spine doc's "refuted oracle claim" is only half right

Spine §3 says the oracle's warning that Stage 1 might break swarm messaging was
refuted, citing `daemon-client.ts:105-106` and `swarm-send-tool.ts:268`. Both do
send the bearer — **for `swarm_send`**.

**`swarm_read` does not.** `packages/opencode-plugin/src/swarm-tool.ts` contains
no `Authorization` header at all, and `docs/plans/2026-06-23-swarm-send-tool-design.md:67`
says so on purpose:

> "This is why `swarm_read` (a GET on `/swarm/inbox`, not auth-protected) gets
> away without the header."

The oracle was right about a tool we did not check. Protecting `/swarm/inbox`
without Task 2 **breaks `swarm_read` for every session in the swarm.** This is
falsification #3 of the pattern in spine §7: checked one member, generalised to
the family. Spine §3 must be corrected, not just this plan.

## Consumer inventory — every caller that 401s, measured

**Group A — breaks the moment the token is set, independent of any `auth.ts` edit**
(these call routes that are *already* protected):

| # | Caller | Route | Failure mode |
|---|---|---|---|
| A1 | `hosts/cloudbox/configuration.nix:137` | `POST /alert` | **SILENT.** Non-2xx is swallowed; visible only as a journal WARNING. |
| A2 | `pkgs/opencode-launch/default.nix:362` | `GET /route` | soft-degrades to `$OPENCODE_URL` |
| A3 | `pkgs/oc-pool-attach/default.nix:127` | `GET /route` | soft-degrades (it adds auth for `/place` at :131 but **not** for `/route`) |
| A4 | `pkgs/oc-auto-attach/default.nix:359` | `GET /route` | soft-degrades to anchor; forces door drift-reconnect |

A1 was **predicted in-tree**. `configuration.nix:130-134` already warns:

> "If pigeon auth token (checkAuth) is ever enabled on /alert … silently swallowed
> … Any future auth-enablement for roadmap item 9.2 MUST include and update these
> canary callers."

A past session left us the warning; v1 of this plan did not carry it. Honour it.

A2–A4 fail *soft*, which is worse for detection than a hard failure: routing
quietly degrades to the anchor and nothing alarms.

**Group B — breaks only because of the `auth.ts` inversion:**

| # | Caller | Route | Failure mode |
|---|---|---|---|
| B1 | `pigeon/packages/opencode-plugin/src/swarm-tool.ts` | `GET /swarm/inbox` | **HARD.** `swarm_read` throws for every session. |

**Verified NOT affected:** no shell consumer in workstation calls `GET /sessions`
(Phase 9 removed the last one); `parity-harness.ts` talks to the worker, not the
daemon. The door already sends the bearer (`config.ts:66` → `resolve.ts`,
`place.ts`, `healthz.ts`).

## Tasks

Order matters: **every caller must be able to send a token before any token is
set.** Tasks 1–3 are safe to land while the token is unset (all are no-ops then).

### Task 1 — pigeon: fix the callers FIRST (repo `~/projects/pigeon`)

Add the bearer to `swarm-tool.ts` (B1), mirroring `swarm-send-tool.ts:135`
(`if (opts.authToken) headers["Authorization"] = ...`, sourced from
`process.env.PIGEON_DAEMON_AUTH_TOKEN?.trim() || undefined`). Harmless no-op when
unset.

*Done test:* a `swarm-tool` test asserting the header is present when the env var
is set and absent when it is not.

### Task 2 — workstation: fix the four Group-A callers

Add `PIGEON_DAEMON_AUTH_TOKEN` bearer (when set) to A1–A4. A3/A4 already have the
`place_auth=()` idiom a few lines away — reuse it verbatim rather than inventing a
second style.

For **A1**, also make the failure loud: a 401 from `/alert` must not be swallowed
into a WARNING, per the in-tree comment's own instruction.

*Done test:* each package's `test.sh` asserts the header is sent when the env var
is set. These are shell — check `pkgs/*/test.sh` conventions before adding.

### Task 3 — pigeon: invert `checkAuth` (repo `~/projects/pigeon`)

`packages/daemon/src/auth.ts`: deny by default, with an explicit anonymous
allowlist of exactly **`GET /health`** (app.ts:122 — verified). Comment the
allowlist entry with its justification. Keep the falsy-token back-compat branch
(`auth.ts:4`) — devbox/darwin and Stage 2 both rely on it.

Also in this commit:
- **invert `test/auth.test.ts:79`** (test 7) to assert 401, and rename it;
- **update `routing/README.md:99`**, which currently documents the opposite.

*Done test:* with a token — `/sessions`, `/sessions/<id>`, `/swarm/inbox`,
`/route`, `POST /place` → 401 bare, non-401 with bearer; `/health` → 200 bare.
Without a token — all non-401. Run the full daemon suite (`vitest run`), not just
`auth.test.ts`.

### Task 4 — workstation: sops secret

Add `pigeon_daemon_auth_token` to `secrets/cloudbox.yaml` + `sops.secrets` in
`hosts/cloudbox/configuration.nix`, following `ccr_api_key` / `telegram_bot_token`.
See `.opencode/skills/managing-secrets/SKILL.md`. Value: `openssl rand -hex 32`.

*Done test:* `/run/secrets/pigeon_daemon_auth_token` exists, readable by `dev`.

### Task 5 — workstation: plumb into ALL units in ONE activation

**Ordering is load-bearing.** Pigeon, the door, **and every Group-A caller's unit**
must see the token in the same activation.

- pigeon unit — `configuration.nix:564+`, beside the `export CCR_*` lines
- door unit — `opencode-frontdoor` (`configuration.nix:1724+`, beside
  `PIGEON_DAEMON_URL`); client code already exists, it needs only the env var
- the journal-alert canary (A1) and any timer unit invoking A2–A4
- **interactive sessions** need it too, or `swarm_read`/`opencode-launch` 401 in
  every TUI — check how `PIGEON_DAEMON_URL` reaches them today and mirror it
  (`shell-env.ts` injects `/run/secrets/*`; confirm rather than assume)

*Done test:* `systemctl show <unit>` for each references the secret; door
`/healthz` reports pigeon reachable.

### Task 6 — delete the phantom route

`ses_0000000000000000000000000 -> serve-0`, written by an adversarial-reviewer
probe demonstrating `POST /place` is an unauthenticated write. Verify read-only
first: `curl -s ':4731/route?session_id=ses_0000000000000000000000000'`.

### Task 7 — regression guard

A **runtime** assertion (canary, not source grep — the property is live-service,
not source-string) that anonymous `:4731/sessions` returning 200 fails loudly.
Cover `/swarm/inbox` too, since it was missed by an enumerated list once already.

## Verification (all must hold)

1. Anonymous → 401: `/sessions`, `/sessions/<id>`, `/swarm/inbox`, `/route`,
   `POST /place`. Anonymous `/health` → 200.
2. With bearer → non-401 for all of the above.
3. `opencode attach` TUIs still work; `:4700` connection count unchanged.
4. **`swarm_send` AND `swarm_read`** both work end-to-end between two live
   sessions. Test `swarm_read` explicitly — it is the one with no header today.
5. `opencode-launch` still launches (degrade path talks to pigeon).
6. The journal-alert canary still delivers (A1) — assert a 2xx, not absence of noise.
7. Nightly `reset-workspace` completes.
8. `bash users/dev/test-frontdoor-opacity.sh` still green.

## Deploy

`nixos-rebuild switch --flake .#cloudbox`, then restart pigeon **and** the door.
Door is `restartIfChanged = false` deliberately — an explicit `systemctl restart
opencode-frontdoor` **drops live SSE legs**, so do it knowingly, not mid-turn.

**Confirm by generation timestamp, not by the command appearing to run:**
`ls -lat ~/.local/state/nix/profiles/`.

**The user deploys. Do not auto-deploy.**

## Out of scope

Stage 2 (serve token), Stage 3 (degrade into the door), Stage 4 (netns —
escalation only), `workstation-vjq0`, `workstation-u417`.

**Next work after this lands: `workstation-y8m`** — the only open P0, a
measurement gate blocking the `b4p` epic.
