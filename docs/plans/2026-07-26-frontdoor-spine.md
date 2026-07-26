# The front-door spine — what we are actually trying to finish

Written 2026-07-26, immediately before a compaction, specifically so that the
next session can tell the spine apart from a side quest. If you read one file
before picking up work in this area, read this one.

## The objective, in the user's words

> "keeping /route for discovery basically lets the rest of the machine know
> about the internals of the serve pool, right? I want that to be entirely
> opaque."
>
> "i want network opacity, why are we giving up on this"
>
> "no other door than the front door"

That is the whole point. Not the disposition table, not the gate, not the CLI —
**network opacity**: nothing on this box addresses an individual serve.

## Where we actually stand

> **CORRECTED 2026-07-26 by measurement.** This section previously claimed the
> objective was NOT met and that "the TUI does not go through the front door,"
> citing `hosts/cloudbox/configuration.nix:576,631`. **Both claims were false**,
> and acting on them would have caused an outage. Superseded by the measured
> audit in `docs/plans/2026-07-26-phase9-consumer-disposition.md`. The original
> text is preserved below, struck, because *how* a status claim went unchecked
> through three audits is the more useful lesson.

~~"The objective is NOT met. `OPENCODE_URL=http://127.0.0.1:4096` — the anchor,
not the door (`hosts/cloudbox/configuration.nix:576,631`). The TUI does not go
through the front door."~~

**What is actually true**, measured on cloudbox 2026-07-26:

- **20 of 20 live `opencode attach` TUIs run against `http://127.0.0.1:4700`.**
  Zero against any serve port. The TUI rides the door.
- **Every process connected to a pool port is the door or a serve.** No external
  consumer addresses a serve at runtime.
- **Pigeon is fully token-gated**: `/route`, `/place`, `/sessions` all 401.

The repoint landed in `f878865` ("Phase 9 attach-through-door (co-land)"). The
runtime objective is **substantially met**.

And the two cited lines are not violations at all — they are deliberate,
commented, **test-enforced** exemptions. `:576` is the pigeon control plane;
repointing it at `:4700` creates the door⇄pigeon startup cycle its own comment
forbids and trips `users/dev/test-pool-route-clients.sh:97-98`. Following this
file literally would have broken routing for the whole box.

**The lesson worth keeping:** the false claim was inherited from a bead note and
restated confidently without probing a single process. One `pgrep`/`/proc` read
refuted it in seconds. This repo's own rule — *configured ≠ running* — applies to
**status claims in prose**, not just to `systemctl`. A doc asserting system state
must cite a measurement or it is a rumour with a filename.

What genuinely remains is small and enumerated in the disposition table: three
direct-to-serve call sites (`opencode-launch` MCP-connect + attach hint,
`lgtm-sessions` attach hint), the test that pins one of them, and the 9.2
grep-guard.

Everything else in the epic is either done or subordinate:

| Phase | State |
|---|---|
| 7 (door exists, session routing) | done |
| 8 (attach → session-scoped `/event`) | **closed 2026-07-26**; live gate verified: `/global/event`→410, bare `/event`→400, `/event?session_ids=`→200 |
| 10 (session-scoped MCP routes) | done |
| D4 (disposition the 9 denied mutating routes) | **closed 2026-07-26**, deployed and verified on the wire |
| 9.1 (repoint → door) | **done** in `f878865`; verified 2026-07-26 — 20/20 TUIs on `:4700` |
| 9.2 (pigeon token) | **done**; `/route`, `/place`, `/sessions` all 401 (was carried as "deferred") |
| **9.0 + 9.2 grep-guard + 3 call sites** | **THE REMAINING WORK — `workstation-mlve.4`** |

`workstation-mlve.4` is the sole remaining P1 in the epic. It is the spine.

## The uncomfortable fact that keeps the spine honest

**D4's operational value today is zero.** The nine routes it dispositioned are
unreachable by the TUI, because the TUI talks to `:4096` directly. Every denial
body shipped on 2026-07-26 is insurance against a state we have not entered.

D4 was a genuine prerequisite — repointing without it would 405 the TUI's
dialogs — but if Phase 9 never lands, D4 bought nothing operationally. The same
will be true of every further refinement to the disposition tables.

**Corollary, and the reason this file exists:** freshly-completed work generates
its own gravity. On 2026-07-26, six fast-follow beads were filed within twenty
minutes of finishing D4. None of them is the spine. If you find yourself
polishing the disposition table, the constraint enum, or the gate, stop and ask
whether `mlve.4` moved.

## The gate that was blocking Phase 9 is now open

`NEW-P5-F1` asked: does the pinned release's TUI still drive mid-turn permission
replies through the door-denied **bare** routes? If yes, repointing wedges turns
on unanswerable prompts.

**Verified satisfied** in `v1.17.13-patched.5` (the deployed pin) on 2026-07-26.
Full evidence is on the `workstation-mlve.4` bead. Summary: the auto-approve path
(`context/sync.tsx`), all five interactive permission sites, question
reply/reject, and MCP connect/disconnect/status are all migrated to
session-scoped SDK calls, and every migrated target is class `session-path` in
`pkgs/opencode-frontdoor/src/routes.classification.ts`.

So the blocker is not the gate. The remaining scope is ordinary work.

## Remaining scope of `mlve.4` (from the bead, still accurate)

1. **9.0** — produce and **commit** the `OPENCODE_URL` consumer disposition table
   (`repoint` / `anchor` / `exempt` / `host-scoped`). No committed artifact
   exists; the "audit done" claim rested on a bead note predating Phases 8/10.
   This table is the door's permanent exemption record and it governs items 2-4.
2. Two live opacity violations, both verified 2026-07-25:
   - `users/dev/home.base.nix:1258-1261` — `lgtm-sessions` emits
     `opencode attach $serve_url`, justified by a now-false comment at `:1121`.
   - `pkgs/opencode-launch/default.nix:372-375` — POSTs
     `$serve_url/mcp/$srv/connect`. Its comment ("the front door denies MCP
     connect with 405") is **doubly stale**: Phase 10 added the session-scoped
     route, and the TUI itself migrated to it.
3. `users/dev/test-pool-route-clients.sh:74` **pins the stale direct-to-serve
   behaviour as correct.** The 9.2 grep-guard collides with it head-on; that test
   must be rewritten, not deleted.
4. **9.1** repoint `OPENCODE_URL`→`FRONTDOOR_URL` per the table (cloudbox first),
   keeping `OPENCODE_ANCHOR_URL` for degrade/infra.
5. **9.2** internalize pigeon `/route`/`/place`: require `PIGEON_DAEMON_AUTH_TOKEN`
   (the door carries it) + the grep-guard test.

## What the repoint activates — sequence this deliberately

Phase 9 turns D4's documented degradations into live behaviour. Most are
harmless or visible. One is not:

**`PUT /auth/{providerID}`** — `dialog-provider.tsx:396-405` calls `auth.set()`
with **no error check**, then `instance.dispose()` also unchecked, then can show
*"Saved credential for `<id>`"*. Post-repoint the user is told a write succeeded
when it 403'd. Not a wedge — a lie, on the credential path.

**`mlve.4` deliberately has NO hard blockers in beads.** Three related items are
linked `relates_to`: `workstation-vkv2` (make `opencode-pool-auth` the
documented, verified remedy for credential rotation), `workstation-u417` (five
rows still ship the wrong wire hint), `workstation-85ui` (TUI
`console.switchOrg` unhandled rejection).

Two reasons they are links and not blockers, both learned by getting it wrong on
2026-07-26:

1. **A blocked bead disappears from `bd ready`.** Blocking `mlve.4` made the
   spine invisible to the one command an agent runs to find work — the exact
   opposite of what this file is for.
2. **The constraint is wrong-grained as a bead dependency.** It does not apply to
   `mlve.4` as a whole. Step 9.0 (the consumer audit table) is the first work and
   has nothing to do with any of them. The real rule is narrower:

> **Do not perform the 9.1 `OPENCODE_URL` repoint until `vkv2` has landed.**
> Everything before 9.1 — the audit table, the two violations, the test rewrite —
> is safe to do first, and should be.

`u417` and `85ui` should land with the repoint but need not precede it.

Others, for completeness: provider OAuth degrades **visibly** (error toast /
inline error); `/instance/dispose` degrades **silently** (error discarded at four
call sites); `experimental.*` / `move-session` / `sync.start` are flag-gated off
here or swallowed by design.

## Explicitly NOT the spine

These are real and filed. None should precede `mlve.4`:

- `workstation-g8k9` (F1) — `PATCH /config` + `/global/config` mislabelled
  `process-local-side-effect`; they are `shared-disk-plus-stale-cache`.
- `workstation-ix8w` (F2) — promote `/integration/attempt/*` to `terminal-denial`.
- `workstation-yc2g` (F3) — "audit at pin-bump" has no enforcement hook.
- `workstation-yf3i` (F5) — the 26 `needs-audit` rows have no owner.
- `workstation-memk` — audit those 26, starting with `/credential/*`.
- `workstation-r9hu` — upstream `auth.json` lock **and** cross-process re-read path.
- `workstation-hrfn` — frontdoor deploy is a two-step act. **Do not "fix" this by
  setting `restartIfChanged = true`**; the reasoning is on the bead.

## A separate cluster worth naming (not this spine)

`a0zj`, `hrfn`, `utnw`, `xci9`, `94g8`, `t2b8` are one theme: *the pool's
lifecycle is under-observed and under-controlled*. `a0zj` (serves don't restart
on a pin bump) and `hrfn` (door doesn't restart on rebuild) share a root cause —
activation does not restart the thing whose content changed — and are probably
one fix, not two.

And there is a **P0 outside this spine entirely**: `workstation-y8m`, "Measure
cost after context-usage removal (BEFORE adding more patches)", a measurement
gate blocking the `b4p` epic. It is the only P0 open and nothing is moving toward
it. If cost matters more than opacity right now, that is the honest reprioritization.

## Process discipline earned the hard way (2026-07-25/26)

- **Configured ≠ running.** `systemctl show -p ExecStart` reports *intent*. To
  know what code is executing, read `/proc/<pid>/cmdline` or probe the wire. This
  mistake was made three times in one session; only a live `curl` caught it.
- **Consult the canary before asserting deploy state.** The frontdoor canary had
  the correct answer logged 98 times while the opposite was being reported.
- **Never use the live pool's ports (4096-4099) for test harnesses.** Use high
  random ports.
- **Never put backticks inside double-quoted bash strings** — command
  substitution hijacked a pool slot and stranded 75 sessions.
- **`pkill -f <pattern>` matches its own command line.** Bracket a character:
  `pkill -f 'fak[e]\.py'`.
- **Tests can stop testing the moment the guarded condition succeeds.** Three
  negative census tests became vacuous passes exactly when D4 completed. Prefer
  perturbation-derived assertions over hardcoded counts.
