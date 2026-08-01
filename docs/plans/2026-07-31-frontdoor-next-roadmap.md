# Front door — next roadmap (post-CI-side-quest), 2026-07-31

> **For the next session:** this file is the SPINE. Read it before acting. It survives
> compaction; conversation does not. Every step names its beads, its grep anchors, and
> its verification command.
>
> **Cite grep-able anchors, never line numbers.** This document already shipped one
> round of drifted cites (`cloudbox:961` → actually `:1001`; `proxy.ts:547,566` →
> actually `:599,606`), caught in adversarial review. The guard's own design philosophy
> — markers travel with the code, never line lists — applies to this file too.

**Goal:** close the `workstation-mlve` epic honestly — Phase 9's last item and its named
residuals — then ride the exit criterion. The fence bug (`4b1q`) is deliberately NOT on
that critical path; see Step 4.

**Position (measured 2026-07-31, not inferred):** four of five closing-plan items in
`docs/plans/2026-07-24-frontdoor-remaining-roadmap.md` are CLOSED (`sq1v`, `j6de`,
`mlve.11`, `m3z2`). `workstation-mlve.4` (Phase 9) is the last, and it is **not merely
deploy-gated** as its older notes claim — see Step 1.

**Live state is good; re-measure, don't assume:** door `:4700` up, pool `:4096-4099`,
pigeon `:4731`; 76 distinct pids on the door; the only processes whose PEER is a serve
port are `opencode-frontdoor.service` (row C3) and the four serves connecting to
themselves. No third-party bypass.

---

## Per-step cadence (the user's requested discipline)

Run this for EVERY step, in order. Do not skip the review because a step feels small.

1. **Compact** before starting (`preparing-for-compaction`), so the step begins with a
   clean context and a resumption prompt pointing at this file.
2. **Optional `oracle-fable` consult** — take it when the step has a design choice with
   more than one defensible answer. Skip for mechanical steps, and say why.
3. **SDD if applicable** — `writing-plans` then `subagent-driven-development` for
   anything with >~3 edit sites or any test-bearing change. Skip for one-line or
   docs-only steps, and say why.
4. **`adversarial-reviewer-fable`** — mandatory, before the PR, on the real diff or the
   real plan. This gate has caught every substantive defect in this project, including
   two factual errors in the first draft of this very file.
5. **PR if applicable** — one per step. Repo **forbids merge commits**; use
   `gh pr merge --squash` (`--merge` fails with a GraphQL error).

**Verification discipline, learned expensively:** verify by MECHANISM, never by a green
check or a duration. Three CI "fixes" this week reported healthy while doing nothing.
Anchor regexes (`127.0.0.1:409[6-9]$`; the unanchored form matches ephemeral ports like
`40961` and manufactures phantom findings — it briefly did). Capture output to a file
and grep it; `cmd | grep -q FAIL` under `set -o pipefail` inverts its own result.

---

## Step 1 — Finish Phase 9.2: make the opacity guard TRUE, then ENFORCED

**Bead:** `workstation-mlve.4` (P1, last closing-plan item). See its 2026-07-31 note.

**1a. The guard currently FAILS.** `bash users/dev/test-frontdoor-opacity.sh` → exit 1:
16 serve-addressing sites vs `EXPECTED_SITES=14`. Both new sites are in
`users/dev/home.devbox.nix` — the devbox door's own `OPENCODE_ANCHOR_URL` and the devbox
frontdoor canary's `:4096/global/health` cross-probe. They arrived in `55a3757` (#217,
devbox convergence).

They are **legitimate**: devbox analogues of rows C3 (door's own upstream) and C4
(canary must distinguish *door down* from *pool down*). The bug is in the TABLE — row
D1 in `docs/plans/2026-07-26-phase9-consumer-disposition.md` still reads *"host-scoped —
no door on devbox"*, which #217 falsified by putting a door on devbox. Fix: add devbox
C3/C4-equivalent rows, add the two `frontdoor-exempt(...)` markers, bump the expected
count, correct D1's rationale.

**1b. The guard is enforced NOWHERE** — no flake check, no CI step, no canary. Phase
9.2's "grep-guard" has never gated a PR, which is why #217's drift sat unnoticed. Wire
it into `nix flake check` (`flake.nix`, `checks.${devboxSystem}`). Cheap now: the ARM CI
leg runs ~3 min after `#227`, so a bash-only check adds seconds.

**Land 1a before 1b in the SAME PR.** The guard is red on `origin/main` today; arming
first would instantly block every PR, including the daily auto-merge bot PRs.

**Hardening to do while in there** (all verified 2026-07-31):
- `SITE_RE` ends `:409[0-9]`, matching non-pool ports 4090-4095. A peer adding an
  unrelated `:4091` harness gets blocked with no legitimate row to cite. Tighten to
  `409[6-9]`.
- The per-file 1:1 check is gated on `fsites -gt 0`, so a file that keeps its markers
  while all its sites rot out of the pattern is invisible. Make `fmarks>0 && fsites==0`
  a failure.
- **The scalar `EXPECTED_SITES` merges wrong rather than conflicting.** Two concurrent
  PRs each adding one site both bump 14→15; identical edit ⇒ clean merge ⇒ both green ⇒
  main red at 16≠15, blocking everyone after the fact. Prefer per-file expected counts
  (a sorted manifest): different-file additions merge clean *and correct*, same-file
  additions conflict *textually* and force resolution. Keep some count-shaped invariant
  either way — per-site markers alone are insufficient, because a new site citing an
  *existing* row passes every per-site check silently.
- **A marker may cite a row that does not describe its file.** `row_exists()` checks
  only that the row ID is in the table and `row_is_exemption()` that it is C*/D* class;
  **nothing checks that the cited row's path list contains the citing file.** So
  `frontdoor-exempt(C3)` on a `home.devbox.nix` site passes, even though C3 describes
  the *cloudbox* door. Require the cited row to name the file (or a glob covering it).
  **This is not hypothetical:** on 2026-07-31 a peer session's implementer subagent
  "fixed" the red guard by adding exactly those two markers citing C3/C4 for devbox
  paths those rows do not describe, plus the count bump. The peer caught it and
  reverted. Once the gate is armed, that becomes the path of least resistance for
  anyone it blocks — the guard would bless the wrong fix. Fix this in the SAME PR that
  arms it, or the gate teaches laundering.
- **Document the peer protocol** (marker + table row + count bump, in their own PR) in
  the PR description and `AGENTS.md`. Today it exists only in the guard's stderr.

**Verification:** `bash users/dev/test-frontdoor-opacity.sh; echo $?` → `0`; then
perturb (add an unmarked site), confirm the CI check goes RED, revert. Capture to a
file; do not pipe into `grep -q`.

**Cadence:** oracle optional (mechanical); SDD yes (multi-site + a CI gate);
adversarial review mandatory; one PR.

---

## Step 2 — Dispose of `mlve.4`'s named residuals, then close Phase 9

**Beads:** `workstation-mlve.4`, `workstation-u417`, `workstation-vjq0`, `workstation-pcf3`.

The fable review of Phase 9 left five residuals explicitly "STILL OPEN, NOT actioned".
Decide each *deliberately* — action, existing bead, or documented won't-fix — so Phase 9
closes on a record rather than on fatigue.

- **(a) The door's own error text instructs bypass.** Grep anchors:
  `POOL_CREDENTIAL_REMEDY` and the string `call a serve port directly` in
  `pkgs/opencode-frontdoor/src/proxy.ts` and `src/routes.dispositions.ts`. The door is
  manufacturing the violations its guard then catches. Overlaps `workstation-u417`.
  **Fix in this step.** Note the cost the first draft omitted: this needs a door rebuild
  **and an explicit restart** (`restartIfChanged=false`), which drops all SSE legs —
  batch it into a natural window, before the Step 3 measurement window opens.
- **(b) Out-of-repo consumers unenumerated** (`~/projects/pigeon` workers, the lgtm
  daemon). The census covers 27 shipped files in THIS repo by construction. **Bead it**
  with that limitation stated honestly.
- **(c) create→connect ownership race — ALREADY BEADED as `workstation-vjq0`** (P2,
  open, created 2026-07-26; also listed in `docs/plans/2026-07-26-frontdoor-spine.md`).
  **Do NOT file a new bead.** `connect` is not in `PROMOTING_SUFFIXES` but `prompt_async`
  is, so an unrouted session connects MCP on the anchor and the prompt then HRW-places
  elsewhere: silent tool loss, no error.
  **Do not prejudge the disposition — this is the step's oracle question.** The
  mechanical fix is one string in a Set in **this repo's** door code (grep
  `PROMOTING_SUFFIXES` in `pkgs/opencode-frontdoor/src/place.ts`) — not a fork patch, not
  cross-repo, no pool restart — and it could ride the SAME door deploy as (a) for near-zero
  marginal deploy cost. What is genuinely large is vjq0's four-MCP-test matrix and the
  promotion side effects. Live options: fix-with-(a), or leave beaded.
- **(d) post-launch migration strips MCP, nothing replays connects** — fold into `vjq0`,
  which already records it as related and unfixed.
- **(e) structural opacity** (`workstation-pcf3`, P3) — unix sockets or a netns, with the
  grep as defense-in-depth; `ss -tlnp` still reveals the pool. **Leave at P3 and say so**;
  Step 1 buys the enforcement that makes the convention real enough.

**Close-out bookkeeping still owed** (from the 07-24 roadmap, re-checked today): reclass
`a0zj` or re-promote `m96n` — pick one deliberately; retire the `ss -K` residual
explicitly; sweep stale comments (grep `home.base.nix` for the Phase-8/9 comment at the
lgtm-sessions attach hint, and `pkgs/opencode-launch/default.nix` for the "door denies
MCP connect with 405" comment, untrue since Phase 10).
**Do NOT "close `mlve.3` naming its deferrals"** — that instruction was copied from the
07-24 roadmap and is stale: `mlve.3` is already CLOSED. (Prose-drift, inside the
document that cites prose-drift as finding #23.)

**If the epic closes with `vjq0` open, say why in the close-out note:** the epic's
objective is network opacity, not MCP placement correctness, and `vjq0` predates this
roadmap as explicitly not-the-spine — but it is door-architecture-caused silent
breakage, the same "anchor-degrade silent-failure" class the epic's architecture note
names as the recurring generator.

**Cadence:** oracle YES (the (c) disposition is a real design call); SDD if (a)+(c) land
together; adversarial review mandatory; PR for (a) [+ (c)] + bookkeeping.

---

## Step 3 — Ride the exit criterion (and settle `eon4` FIRST)

**DONE is not "the steps landed."** Per the adopted exit criterion: the items land AND
**one full deploy cycle rides clean** — at least one opencode pin bump plus one nightly
reset pass, with zero door-caused incidents and zero un-throttled drift alerts. Then
close `mlve`.

**This is nearly free.** `update-opencode-patched` runs every 8h and the nightly reset
runs daily, so an organic cycle happens roughly daily with no work — it is an
observation window, not a task. A deploy inside the window is the *required event*, not
contamination; the criterion was designed to measure perturbation survival (~27 pin
bumps in 6 weeks is the steady state).

**Blocking prerequisite — pre-register the `eon4` rule BEFORE the window opens.**
`workstation-eon4` (2026-07-30 burst attach 503s: 196 × 503, all `class=global-ro`, all
`target=:4096`, all `durationMs` 4999-5002 inside one 7-second window) is parked on a
user decision. Without a rule, a fresh session reaches this step, sees eon4 open, and
stalls forever — a wait state, not a step.

The cycle IS the eon4 experiment: the mandatory nightly reset followed by the morning
mass-reattach is precisely the reproduction scenario (33 sequential `oc-auto-attach`),
and the caller-side fix (`#220`, home gen 521) is already deployed. So pre-register, in
the shape already used for `m96n` and `km5f`:

> **Rule:** if the cycle's post-reset morning reattach produces ZERO eon4-signature
> 503s (`class=global-ro`, `target=http://127.0.0.1:4096`, `durationMs`≈5000), the
> door-side concentration is accepted as mitigated by `#220` and `eon4` closes
> accepted-with-rationale. ANY recurrence re-promotes door-side work and the cycle is
> NOT clean.

**Get the user's accept-or-fix call on that rule before opening the window.**

---

## Step 4 — `4b1q`: close the serve registry fence's interface hole

**Bead:** `workstation-4b1q` (P2, related `workstation-necw`). Reported by a peer session
2026-07-31; they hit the identical shape in the overlay writer (PR #232).

**Deliberately sequenced AFTER epic closure, and the earlier justification is retracted.**
The first draft claimed the fence "must land before the cycle or it perturbs the
measurement." That is wrong — deploys are the criterion's required event. The real
trade-off: landing it before the cycle would give the fork change a free validation ride
(its `patched.N` cut doubling as the cycle's pin bump), at the cost of putting a
dual-repo SDD cycle on the epic's critical path and contradicting `4b1q`'s own
pre-registered deferral condition (*"sequence behind the mlve.4 / 9.2 work unless the
lease-invalidation churn is actually being observed"* — it is not being observed).
**Chosen: close the epic first; the fence gets its own soak.**

The fence compares `OPENCODE_SERVE_EXPECTED_PORT` against the bound PORT only, no
interface check. A nested `opencode serve --hostname ::1 --port 4098` binds alongside the
real serve on `127.0.0.1:4098`, passes the fence, and reaches `registerSelf`. Traffic
still lands on the real serve (registered endpoint is hardcoded `127.0.0.1:${port}`), so
the harm is a `registerSelf` under a different `instance_uuid` — which the fence's own
FATAL text says invalidates the real serve's session leases — plus self-heal churn.

**Fix: `export OPENCODE_SERVE_EXPECTED_PID=$$`** in each wrapper, compared against
`process.pid` in the fork. Children inherit the var but never the pid, closing
port/host/socket variants at once. Verified safe: all three wrappers `exec` the serve
(grep `exec .*opencode serve` in `hosts/cloudbox/configuration.nix`,
`users/dev/home.devbox.nix`, `users/dev/home.darwin.nix`), so `$$ == process.pid`.

> **MANDATORY, and the single most dangerous omission of the first draft:**
> **unset ⇒ fence UNARMED (fall back to port-only), never FATAL.** The existing port
> fence documents this precedent verbatim (grep `Unset = fence unarmed`). The binary
> rides the 8-hourly pin bump; the wrapper export rides `nixos-rebuild` /
> `darwin-rebuild` — different deploy surfaces. If unset ⇒ FATAL ships, the new binary
> reaches a pool before its export does and that pool bricks at the next nightly
> restart. This is the project's bootstrap-order error, third occurrence.

Note the corollary flips with that choice: under unset⇒unarmed, a wrapper that stops
`exec`ing silently DISARMS the fence rather than failing closed. So assert the exec
property explicitly (a test or a startup log line), don't leave it as a comment.

If fix (a) (require a loopback bind) is taken instead, use loopback *equivalence*, not
exact host match — an exact match breaks the day the bound host is reported as
`localhost` or `::1`.

**Step 3's `patched.N` cut, if one happens, carries ONLY this fence edit.** Do not
bundle the parked `km5f` Stage-2 auth patch because "we're cutting anyway" — km5f has a
pre-registered decision rule running to ~2026-08-11.

**Cadence:** oracle optional; SDD yes (cross-repo, test-bearing); adversarial review
mandatory; PR in both repos.

---

## Explicitly NOT next (recorded so it is not silently re-promoted)

- `workstation-km5f` (Spine Stage 2, serve auth token) — PARKED, measuring until
  ~2026-08-11, pre-registered decision rule. Do not restart early; do not bundle.
- The frontdoor global-ro cache — CLOSED on evidence (`#221`): measured ~2x not 30x,
  plus an unbounded `arrayBuffer()` stall. Do not redesign it.
- `mlve.5`-`mlve.10` backlog, `workstation-sktk` (variable-port guard blind spot) —
  after the spine closes.

## Durable anchors

| what | where |
|---|---|
| this spine | `docs/plans/2026-07-31-frontdoor-next-roadmap.md` |
| prior roadmap (5 items + exit criterion) | `docs/plans/2026-07-24-frontdoor-remaining-roadmap.md` |
| epic spine | `docs/plans/2026-07-26-frontdoor-spine.md` |
| disposition table (the exemption record) | `docs/plans/2026-07-26-phase9-consumer-disposition.md` |
| the guard | `users/dev/test-frontdoor-opacity.sh` |
| epic / last item / MCP race / fence bug | `workstation-mlve` / `workstation-mlve.4` / `workstation-vjq0` / `workstation-4b1q` |
