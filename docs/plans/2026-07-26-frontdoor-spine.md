# The front-door spine — what we are actually trying to finish

Orientation artifact. If you read one file before touching anything front-door
shaped, read this one. Rewritten 2026-07-26 after a day in which **two of its own
status claims were falsified by measurement**; see §7, which is the most useful
part of this file.

## 1. The objective, in the user's words

> "keeping /route for discovery basically lets the rest of the machine know about
> the internals of the serve pool, right? I want that to be entirely opaque."
>
> "i want network opacity, why are we giving up on this"
>
> "no other door than the front door"
>
> (2026-07-26, on how far to take it) "you know me, i want front door only, no
> other door. but i can make short/medium term compromises as we work out the kinks."

## 2. Where we actually stand — measured, not assumed

**Achieved and enforced:** no shipped consumer in this repo addresses an
individual serve on a non-degrade path.

- 20/20 live `opencode attach` TUIs run against `:4700` (`/proc/<pid>/cmdline`).
- Every process connected to a pool port is the door or a serve.
- Enforced mechanically by `users/dev/test-frontdoor-opacity.sh` against the
  committed table `docs/plans/2026-07-26-phase9-consumer-disposition.md`.

**NOT achieved: the objective as worded.** Pigeon (`:4731`) answers *anyone*:

| endpoint | auth | result |
|---|---|---|
| `GET /sessions` | none | **200, 166 KB** — sids, cwds, pids, endpoints |
| `GET /route` | none | **200** — resolves a session to its serve |
| `POST /place` | none | **200, a WRITE** — any local process can re-place any session |

And `ss -tlnp` reveals `4096-4099` regardless. Bead: **`workstation-dx8p` (P1)**.

| Phase | State |
|---|---|
| 7 (door exists, session routing) | done |
| 8 (attach → session-scoped `/event`) | done, live gate verified |
| 10 (session-scoped MCP routes) | done |
| D4 (`mlve.11`, disposition the denied mutating routes) | done, on the wire |
| 9.0 (consumer disposition table) | **done** — the table above |
| 9.1 (repoint → door) | **done** in `f878865` |
| 9.2 grep-guard | **done**, rebuilt after review |
| **9.2 token** | **OPEN — `dx8p`. This is the objective.** |

## 3. The opacity roadmap (oracle-fable, 2026-07-26)

**The central constraint: every process is uid 1000.** Door, serves, pigeon, and
every ad-hoc session/subagent/bash call. Therefore unix-socket permissions,
`iptables --uid-owner`, and `SO_PEERCRED` **all buy nothing** — the door is not
distinguishable from an attacker by OS credentials. Verified live.

Two further facts that close off whole branches:

- **`opencode serve` is TCP-only.** No unix-socket flag, no such patch in the
  overlay. The "unix socket + mount namespace" branch is dead without writing one.
- **No passwordless sudo** (`sudo -n true` fails), which makes systemd
  `LoadCredential=` a genuinely meaningful boundary even at shared uid.

**The reframing that drives the recommendation:** the threat model is *not* a
malicious attacker. It is **our own agents and scripts taking a shortcut and
creating drift** — which is what has actually happened, repeatedly. Against drift,
the winning mechanism is not isolation but **loud, cheap 401s**: they convert
silent drift into an immediate, attributable error at the moment of writing.

### Stage 1 — pigeon token (small; mostly already built)

- **TRAP, verified in source:** `pigeon/packages/daemon/src/auth.ts:5-9` protects
  only `POST`/`DELETE` + `GET /route`. Enabling the token **leaves the 166 KB
  `GET /sessions` leak wide open** while feeling closed. Extend the protected set
  *first*.
- Door client side already exists: `opencode-frontdoor/src/config.ts:66`, sent at
  `resolve.ts:46`, `place.ts:37`, `healthz.ts:27`.
- **Order matters:** set the token on the pigeon unit and the door unit in the
  *same* rebuild, or the door 503s and degrade traffic hammers the anchor.
- *Done test:* anonymous `curl :4731/sessions` → 401 and `POST /place` → 401;
  attach still works; `dx8p` closes.

### Stage 2 — serve token on cloudbox (medium)

One patch in the overlay (which already carries ~25): require
`Authorization: Bearer` on all routes **except `/global/health`**, keyed on
`OPENCODE_SERVE_AUTH_TOKEN`; **unset ⇒ auth off**, so devbox/darwin (D1/D2) are
automatically unaffected and a pin bump can't brick their pools.

`/global/health` stays anonymous **by design** — it preserves C4 (canary must tell
door-down from pool-down) and C5 (per-member readiness) unchanged, and leaks
almost nothing. *Write this down or a future you will "fix" it and break both.*

*Done test:* anonymous `curl 127.0.0.1:4096/session` → 401 on all four ports;
canary asserts the 401s nightly; nightly reset still completes.

### Stage 3 — shrink the exemption list (medium)

(a) Move the degrade **into** the door: when pigeon is down the door places on the
anchor itself (it already holds the anchor per C3) instead of 503ing — then delete
the client-side degrade in `opencode-launch` (C7/C8) and revoke its token.
(b) Add an *authenticated per-member* health surface to `healthz.ts` so
`reset-workspace`'s C5 probes ride the door.

*Done test:* kill pigeon → `opencode-launch` still works **through `:4700`**;
token holders = {door, pigeon, canary}; exemption rows ≤ 3.

### Stage 4 — network namespace (large; ESCALATION ONLY)

The only mechanism giving true *reachability* opacity. Sketch: named netns; serve/
pigeon/door units get `NetworkNamespacePath=`; the door's `:4700` arrives as an fd
from a systemd **socket unit** in the root ns.

**Build only if the canary catches token-copying drift more than once.** Costs:
`sudo ip netns exec` for 3am debugging, C4/C5 canaries must join the ns, darwin can
*never* match (permanent platform asymmetry), nightly-reset rework. It defends
against an agent that deliberately copies a bearer token — that agent is not
drifting, it is misbehaving, and a namespace maze won't fix that either.

Stages 1-3 are not throwaway if 4 ever happens; tokens remain defense-in-depth
inside the ns.

### Killed as traps (do not revisit without new information)

| Idea | Why it's dead |
|---|---|
| `iptables`/`nftables` | Cannot distinguish uid-1000 clients; serves are already loopback-only. |
| Port randomisation | `ss -tlnp` re-reveals in one command; breaks the index↔port↔serve-id invariant `serve-pool.nix:10-27` exists to protect. |
| Dummy-interface binding | Any local process reaches any local address. Zero isolation. |
| Serves under a different uid | Only thing that restores OS credentials, but shatters shared state: routing sqlite (WAL, multi-uid), `~/.local/share/opencode`, `auth.json`. Cost ≫ benefit. |
| Pigeon token *alone* as the end state | Incomplete twice: the `auth.ts` `/sessions` gap, and open serve ports bypass pigeon entirely. It's Stage 1, not done. |

**Refuted oracle claim (checked, don't re-worry):** it warned Stage 1 might break
`swarm_send` because the plugin client may not send the bearer. It does —
`pigeon/packages/opencode-plugin/src/daemon-client.ts:105-106` and
`swarm-send-tool.ts:268` both read `PIGEON_DAEMON_AUTH_TOKEN`.

## 4. Explicitly NOT the spine

Real, filed, and none should precede `dx8p`:
`workstation-g8k9`, `ix8w`, `yc2g`, `yf3i`, `memk`, `r9hu`, `hrfn`.

Two that grew out of the 2026-07-26 review and *are* genuine, but are still not
the spine:

- **`workstation-vjq0` (P2)** — silent MCP tool loss: `connect` is not in
  `PROMOTING_SUFFIXES` (`place.ts:74-83`) but `prompt_async` is, so an unrouted
  session connects MCP on the anchor and the turn runs elsewhere. Tools silently
  absent, no error. Carries the four MCP tests that should have existed.
- **`workstation-u417`** — scope enlarged: **the door instructs its own bypass.**
  `routes.dispositions.ts:95-96`, `proxy.ts:547,566` tell callers to "call a serve
  port directly". The door manufactures the violations the guard exists to catch,
  and the guard does not scan `.ts`.

**And a P0 outside this spine entirely: `workstation-y8m`** — "Measure cost after
context-usage removal (BEFORE adding more patches)", a measurement gate blocking
the `b4p` epic. It is the only open P0 and nothing has moved toward it while this
spine consumed sessions. **The user chose it as the next work after Stage 1.**

## 5. Deploy discipline

- `home-manager switch --flake .#cloudbox` for `opencode-launch` / `lgtm-sessions`.
- `nixos-rebuild switch --flake .#cloudbox` for units and exemption markers.
- Door and serves are `restartIfChanged = false` **deliberately** — a restart drops
  every SSE leg. Door changes need an explicit `systemctl restart
  opencode-frontdoor`. Per `workstation-hrfn`, do **not** "fix" this with
  `restartIfChanged = true`.
- **Confirm a deploy by generation timestamp, not by the switch appearing to run.**
  On 2026-07-26 a switch failed on shellcheck, was believed to have succeeded, and
  the profile stayed four hours stale: `ls -lat ~/.local/state/nix/profiles/`.

## 6. Process discipline earned the hard way

- **Configured ≠ running.** `systemctl show -p ExecStart` reports *intent*. Read
  `/proc/<pid>/cmdline` or probe the wire.
- **Never use pool ports 4096-4099 for test harnesses.** Use high random ports.
- **Never put backticks in double-quoted bash strings** — command substitution once
  hijacked a pool slot and stranded 75 sessions.
- **`pkill -f <pat>` matches its own command line.** Bracket a char: `'fak[e]\.py'`.
- **Tests can stop testing the moment the guarded condition succeeds.** Prefer
  perturbation-derived assertions over hardcoded counts.
- **A source-grep guard must be perturbation-tested**, or it is theater. Ours
  missed 7 of 9 realistic violation shapes on first write.

## 7. The two falsifications of 2026-07-26 — read this before asserting anything

Both were *this file's own claims*. Both took seconds to disprove.

**(a) "The TUI does not go through the front door."** Inherited from a bead note
and restated confidently. One `pgrep` + `/proc` read refuted it: 20/20 on `:4700`.
Worse, the two lines it cited as violations (`configuration.nix:576,631`) are
deliberate, test-enforced exemptions — **acting on the claim would have created the
door⇄pigeon startup cycle and broken routing for the whole box.**

**(b) "Pigeon is fully token-gated."** This one shipped *with a measurement
attached*, which made it read as settled and harder to dislodge — strictly worse
than (a). I probed `:8789`, a different process, and generalised. Pigeon is
`:4731`. It overturned a *correct* prior finding in the roadmap. Root cause:
`ss -tlnp | grep '878[0-9]'` — a pattern that could only confirm a port already
guessed — while the line `PIGEON_DAEMON_URL:-…:4731` was read and deleted as dead
code in the same session.

**The rules that follow:**

1. *Configured ≠ running* applies to **prose asserting system state**, not just
   `systemctl`. A doc claiming system state without a citation is a rumour with a
   filename.
2. **Derive the target from the code that uses it**, never from a guess that a
   matching grep then "confirms".
3. **Measuring the wrong thing confidently is worse than not measuring**, because
   the evidence defeats future scrutiny.
4. **Re-verify after the last edit.** A built artifact was inspected, *then*
   modified, and shipped broken — the evidence had been invalidated by the next
   commit.
5. **Check your harness before believing its verdict.** A perturbation run reported
   all 9 bypasses as MISSED; with `set -o pipefail`, `bash guard | grep -q FAIL`
   inherits the guard's exit 1, so every result printed **inverted**.
6. **Run `adversarial-reviewer-fable` BEFORE deploying, not after.** Running it
   after found a live regression and a guard that was theater. The project's own
   cadence is SDD + fable per phase; skipping it cost a production regression.
