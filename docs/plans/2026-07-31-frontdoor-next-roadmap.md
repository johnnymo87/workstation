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

**Update 2026-08-01 — Step 3's blocking prerequisite is CLEARED.** `workstation-eon4`
was not accepted-with-rationale; it was **fixed door-side and closed** (PR #237,
`0ded471`), measured at **zero** `global-ro` 503s across a real 31-session reattach
burst. Step 3's text below is rewritten accordingly. **Step 1 (`mlve.4`) is next and is
unblocked.** Also closed since this file was written: `workstation-0dm8`
("0 MCP tools") — won't-fix, not a door bug, see *Explicitly NOT next*.

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

**STATUS 2026-08-01 — DONE.** 1a and 1b landed together. The table was the thing that was
wrong: rows C10/C11 added for the devbox door's own upstream and its canary cross-probe,
D1 retired as superseded by C1 (devbox pigeon's anchor is the same door->pigeon->door
startup cycle as cloudbox), and the devbox `OPENCODE_URL` marker repointed D1 -> C1. Guard
now green at 16 sites / 16 markers and ARMED in `checks.${devboxSystem}`.

All four hardening items shipped, plus two the adversarial review found and one I found by
hand-probing my own fix:
- `SITE_RE` tightened to `409[6-9]`; `fmarks>0 && fsites==0` is now a failure.
- Scalar `EXPECTED_SITES` replaced by a per-file `EXPECTED_MANIFEST` (only files WITH sites
  are listed, so unrelated new packages -- including the auto-merge bot's -- don't fail).
- Laundering closed: a marker must cite a row whose path column NAMES its file. My first
  version had a `dirname` fallback that let any sibling file in `users/dev/` satisfy it;
  caught by hand-probing, not by the tests.
- **The `:-http` blanket line-skip was a laundering kit** and would have shipped armed: a
  mutating `curl -X POST "${OPENCODE_URL:-http://127.0.0.1:4096}/session/$sid/kill"` passed
  green, defeating the marker check, the 1:1 count and the manifest at once. Found by
  adversarial review, reproduced directly, fixed.
- Two of the meta cases were theatre (passed without reaching the branch they claimed to
  prove). Both now pin their branch by message.

New `users/dev/test-frontdoor-opacity-guard.sh` (10 perturbation cases) exists because a
gate that cannot fail is the defect this step was written to remove.

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

**STATUS 2026-08-01 — DONE.** All five residuals dispositioned; (a) and (c) fixed together
on one door restart. Implementation record: `docs/plans/2026-08-01-step2-mlve4-residuals.md`.

| residual | disposition |
|---|---|
| (a) door instructs bypass | FIXED + ENFORCED (`u417` closed) |
| (b) out-of-repo consumers | BEADED `workstation-1puj` |
| (c) create→connect race | FIXED, `vjq0` SCOPE-REDUCED and left open |
| (d) migration strips MCP | FOLDED into `vjq0` |
| (e) structural opacity | `pcf3` stays P3, reaffirmed |

**The oracle call earned its keep by REFUTING the reason I wanted to fix (c).** I argued
the `prospective` path was a second, uncounted route to the same symptom and that 12/12
observed agreement was luck. It is structural: `placeAfterCreate` already places AND
records sticky at create, and a prospective connect resolves `degraded:false` so it records
sticky and the following turn short-circuits before promotion. Measured: 94 connects in 7
days, **0** degraded. Fixed anyway — one string, on a restart (a) already required, and the
failure mode is silent and gets misattributed to the model — but the bead now records the
honest reason instead of an inflated one.

**Two hazards the one-line fix needed and did not have,** both from adversarial review:
the `PromotionGate` **burn** (a connect sharing the turn-starting budget would ttl-guard a
following `prompt_async` onto the anchor — a mutating turn on a possibly-wrong process,
strictly worse than the tool loss being fixed), and **counter blinding** (the fix silences
`notRoutedMutationToAnchor`, this class's only signal). Both closed; the new
`promotedOnConnect` is scoped to `not-routed` so it cannot read nonzero-but-meaningless.

**Bookkeeping:** `m96n` folded into `a0zj` (one fix, one bead) and `a0zj` reclassed P1→P2
now that its tripwire half is deployed and live; the `ss -K` residual retired as OBSOLETE
(a gate on a redesign decision that production has since made); `workstation-b5yi` filed
for the runtime `err.message` address leak that no static guard can see.

**Two corrections to this document's own instructions, both found by measuring:**
- The "sweep stale comments" item is **itself stale** — both comments were already
  corrected and now narrate the old claim as history. No action taken; verified, recorded.
- I reported a "pre-existing failing route-classification gate" after seeing one `[FAIL]`
  line on both pristine `main` and my branch. The measurement was right, the reading was
  wrong: that line is **stderr from a PASSING negative test**. `./test.sh` exits 0 with
  495/495. There is no known-failing gate; do not inherit that as debt.

**THE EPIC IS NOT CLOSED HERE, deliberately.** Step 2's brief said "close Phase 9 and the
epic", but this document's own pre-registered exit criterion (Step 3) says `mlve` closes
only after the items land AND one full deploy cycle rides clean. Closing it now would be
exactly the "DONE is not 'the steps landed'" failure the criterion exists to prevent.
Phase 9's work is complete; the epic closes at Step 3.

---

## Step 3 — Ride the exit criterion (`eon4` is SETTLED — prerequisite cleared)

**DONE is not "the steps landed."** Per the adopted exit criterion: the items land AND
**one full deploy cycle rides clean** — at least one opencode pin bump plus one nightly
reset pass, with zero door-caused incidents and zero un-throttled drift alerts. Then
close `mlve`.

**This is nearly free.** `update-opencode-patched` runs every 8h and the nightly reset
runs daily, so an organic cycle happens roughly daily with no work — it is an
observation window, not a task.

> **CORRECTION 2026-08-01 — the "nearly free" premise is STALE, and Step 3 is blocked on an
> event that will not happen by itself.** Measured, not assumed: the newest
> `opencode-patched` release is `v1.17.13-patched.6`, published **2026-07-26**; the last
> update PR (#194) merged the same day; the workflow has run every 8h since (including
> 18:20Z on 08-01) and opened **nothing**, because we are already on the newest release.
> That is **6 days with zero pin bumps**, against the "~27 in 6 weeks" base rate this
> criterion was written on. No bump arrives until someone cuts a new release.
>
> **This makes Steps 3 and 4 circular as written.** Step 3 waits for a pin bump; the only
> bump on the horizon is the `patched.N` cut that **Step 4's fence fix** requires. Step 4
> was deliberately sequenced AFTER epic closure so the fence would get its own soak — but
> on current facts Step 4 is what *produces* Step 3's required event.
>
> Three resolutions, undecided, pick deliberately and record which:
> 1. **Do Step 4 first.** Cut `patched.7` carrying ONLY the fence edit (this document
>    already pre-registers that constraint), and let Step 3's window ride that deploy.
> 2. **Re-read the criterion against the 08-01 deploy.** NOTE THE WEAKNESS BEFORE
>    CHOOSING THIS: that deploy (`nixos-rebuild` + home-manager + door restart onto the
>    Step 2 build + full pool restart) was a real perturbation, but it ended
>    **converged** — the skew window was manually closed. A pin bump's distinctive
>    property is that it changes the serves' binary via the mutable profile symlink
>    WITHOUT restarting them (`a0zj`), leaving genuine skew. The 08-01 deploy never
>    exercised that. Choosing this option is a REINTERPRETATION of the criterion and must
>    be written down as one, not smuggled in.
> 3. Cut a no-op `patched.7` purely to trigger a bump — churn for a checkbox. Recorded
>    only so it is visibly rejected.
>
> **RESOLVED 2026-08-02: option 1, decided with the user and EXECUTED.** Step 4 was done
> first and its release cut IS Step 3's required pin bump. Sequence, all landed:
> `opencode-patched` **#33** (squash `284af48`) → release **`v1.17.13-patched.7`**
> (build green, all four platform assets) → workstation **#252** (squash `f7a01e7`) →
> pin-bump **#255** (`patchedRevision` 6 → 7, four hashes, auto-merge). Option 2 was
> rejected on the weakness recorded above — the 08-01 deploy ended converged and never
> exercised the skew window. The measurement window opens when #255 merges and the pin
> is deployed; that deploy is the user's to run (a switch that swaps the opencode binary
> must be done from a plain SSH shell, NOT from inside an opencode session — it kills
> the session mid-switch; grep `plain SSH shell` in `users/dev/home.base.nix`).
>
> **Do NOT count the window as open until the deployed serves are on `patched.7`.**
> Verify by mechanism, comparing the `/nix/store/<hash>` PREFIX of
> `/proc/<MainPID>/exe` against the profile — the exe resolves to `.opencode-wrapped`,
> not `bin/opencode`, and comparing full paths reports four healthy serves as stale
> (done by hand on 08-01, costing a needless pool restart).
>
> Related evidence for the `m96n` disposition the criterion was also meant to settle: the
> 08-01 deploy's restart sequencing was done BY HAND, which is exactly what `m96n`
> proposes to automate. That is weak evidence *for* `m96n`, not for its demotion — and one
> step of it (a serve-staleness comparison) was got WRONG by hand on the day. See the
> `a0zj`/`m96n` notes. A deploy inside the window is the *required event*, not
contamination; the criterion was designed to measure perturbation survival (~27 pin
bumps in 6 weeks is the steady state).

**The blocking prerequisite is CLEARED. `workstation-eon4` is CLOSED (2026-08-01).**
It was resolved by *fixing the door*, not by the accept-with-rationale path this document
originally pre-registered. Do not reopen it, and do not go looking for the parked user
decision — it was made and executed.

What shipped (PR **#237**, squash `0ded471`): the whole `global-ro` class forwarded to
the anchor, so every session-less read concentrated on `:4096`. Now a per-route opt-in
`poolSafe` flag routes measured-invariant reads to a new `forward-pool` action that
round-robins the pool, with connection-level failover. `FRONTDOOR_POOL_URLS` comes from
`serve-pool.nix`; unset ⇒ anchor-only ⇒ prior behaviour.

**Measured on the first post-deploy burst (31-session reattach):**

| `class=global-ro` 503s | count | basis |
|---|---|---|
| 07-30 (pre-everything) | 333 | full local day |
| 08-01 pre-fix | 22 | 00:53–01:56 UTC, pre-deploy |
| 08-01 post-fix burst | **0** | the 13:25–13:52 UTC burst window only |

Note the bases differ — these are **not** apples-to-apples, and this file documents a
timezone silent-zero as a lesson two paragraphs down, so it had better label its own
columns. Within the burst window: spread dead-even (169/169/169/169 across `:4096-4099`),
slowest pooled read 841 ms against the 5000 ms budget, `poolFailover` 0, peak 885 req/min
— a real burst, not a gentle ramp. The old 503s sat pinned at 4999–5002 ms; this never
approached the wall.

**That "0" is a window, not a steady state — and the same day disproved the broader
reading.** At 14:47–14:57 UTC, ~1h after deploy, serve `:4098` went alive-but-stalling and
the door logged **1069 × 503, all `target=:4098`**, all pinned at 4999–5003 ms: 979
`class=session-path` (sessions leased to that member — the anchor-degrade family
reproduced on a *non*-anchor member, not caused by this change) and **90
`class=global-ro action=forward-pool`** — pooled reads round-robined onto the stalling
member. `:4098` self-recovered (`NRestarts=0`); the canary ran during the window and took
no action. Tracked as **`workstation-nv5l`** (P1).

**Honest net accounting, because the trade is real:** those 90 reads would previously have
gone to the healthy anchor and succeeded. So this fix made 90 requests fail that otherwise
would not have, while removing the 333/22-per-burst concentration failures. A good trade —
but a trade, not a pure win.

**Still OUT OF SCOPE, do not read the closure as broader than it is:** ≥5s first-byte
stalls by *any* member, anchor or otherwise. Failover is `failoverIfUnreachable` —
connection-level only — so a member that accepts and then stalls eats the full budget with
no retry. `eon4`'s scope was global-ro *concentration on the anchor*, which is fixed and
measured. Member-stall is `workstation-nv5l`; do **not** reopen `eon4` for it, and do not
file a third bead for the same thing.

**Three lessons from that step, all of which cost real time — apply them in Steps 1, 2, 4:**

- **Invariance must be MEASURED, not argued.** The flag set was first justified from
  configuration ("all members share one templated unit and `WorkingDirectory`, so
  responses cannot differ"). That reasons about the wrong axis — the divergence mechanism
  is per-process caches. Curling all candidates against the live members found six that
  diverge *today*, including `GET /config/providers`, where the anchor exposes an entire
  provider the others lack. Set shrunk 22 → 16 before deploy.
- **`systemctl show -p Environment` reports the LOADED UNIT, not the running process.**
  With `restartIfChanged = false` it showed the new value while the old process still
  served — reproduced live. Read `/proc/$(systemctl show -p MainPID --value <unit>)/environ`.
- **A third journalctl silent-zero:** `--since` is interpreted in LOCAL time even when
  `--utc` is passed (`--utc` only formats output), so a UTC timestamp on an EDT host
  queries the future and returns zero lines. Relatives: bare `"today 00:00"` fails to
  parse; an immediate post-traffic query can return empty via write lag. All three render
  as "no traffic, no errors."

---

## Step 4 — DONE 2026-08-02 — `4b1q`: close the serve registry fence's interface hole

> **DONE.** `opencode-patched` #33 (`284af48`) + workstation #252 (`f7a01e7`), released as
> `v1.17.13-patched.7`. The fix is the `$$` PID fence below, exactly as pre-registered:
> unset ⇒ UNARMED (never fatal) on both fences, malformed ⇒ fatal, exit **21** (20 is the
> port fence), exiting before `registerSelf` AND before `setSelfIdentity`.
>
> The exec property is ASSERTED, not commented: `users/dev/test-serve-pid-fence.sh` runs
> under `nix flake check` and verifies, per wrapper, a LIVE export, an `exec`'d launch,
> their order, and — added after review — that the wrapper LIST itself is complete.
>
> **Three findings from adversarial review, all real, all fixed before merge:**
> 1. BLOCKER: the regenerated patch had silently swept in `bun.lock` hunks **deleting
>    sha512 integrity pins** (`@solidjs/start` from a mutable `pkg.pr.new` URL, plus
>    `ghostty-web`). That both violated "the cut carries ONLY the fence edit" and would
>    have let `bun install` accept whatever those hosts served, in a binary that runs
>    with GH/Cloudflare/Anthropic/GCP credentials. Removed — and the release then built
>    green WITHOUT them, proving they were churn, not a needed fix. Lesson: regenerating
>    a patch from `git diff` after `bun install` will capture lockfile churn; restrict
>    the diff to the paths the patch owns.
> 2. MAJOR: the first guard PASSED when the export was merely COMMENTED OUT — reproduced
>    live. It grepped raw text. Commenting a line out to debug is the likeliest edit
>    here, so it was the one case the guard most needed to survive, and its own comment
>    already said a green guard over a disarmed fence is worse than none. Now every
>    check reads a comment-stripped view.
> 3. MAJOR: no end-to-end test of the armed-MATCH path. Changing `process.pid` to
>    `process.ppid` passed the unit tests AND the E2E mismatch test while bricking all
>    four serves in production. An E2E test now spawns through the real wrapper shape
>    (`bash -c 'export ...=$$; exec ...'`) and was proven RED under that exact mutation.
>
> Mechanism checks, not inspection: `$$` survives Nix eval literally into the realised
> `opencode-serve-start`; the profile's `bin/opencode` is a wrapper but it `exec`s
> `.opencode-wrapped`, and a live pool member's MainPID was confirmed to both have PPID 1
> and own its port — so the whole chain execs and `$$ == process.pid` holds.
>
> Whole-pool crash-loop recovery is now written down BEFORE it is needed, in the
> `monitoring-serve-pool` skill: because unset ⇒ unarmed lives in the binary, recovery is
> a wrapper revert plus a rebuild, never a new binary.

## Step 4 (original text, retained)

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

## Scheduled, but not a numbered step (added 2026-08-01)

These were in LIMBO — cited in this document's prose, on no step, and absent from
"Explicitly NOT next". That section exists precisely to stop work drifting into that
state, and a P1 sitting in it is the failure mode it was written to prevent. Dispositioned:

- **`workstation-nv5l` (P1, OPEN) — SCHEDULED, next door change after the epic closes.**
  A live-but-stalling pool member still poisons pooled reads: `failoverIfUnreachable` is
  connection-level only (grep it in `pkgs/opencode-frontdoor/src/proxy.ts`), so a member
  that accepts and then stalls eats the full 5s budget with no retry. Measured 2026-08-01:
  1069 × 503 in a ten-minute window, of which 90 were `class=global-ro action=forward-pool`
  — pooled reads round-robined ONTO the stalling member. **This is P1 and it is partly
  self-inflicted:** those 90 would have gone to the healthy anchor before the `eon4` fix.
  It is not on the epic's critical path (the epic's objective is opacity, not member
  health), but it must not close as "mentioned somewhere".
- **`workstation-b5yi` (P2, OPEN) — DEFERRED, with reason.** The door still leaks a pool
  address at RUNTIME via upstream `err.message` on 502/500 (`connect ECONNREFUSED
  127.0.0.1:<port>`). Deferred because it is a DISCLOSURE, not an INSTRUCTION — it tells a
  caller where a serve is, it does not tell it to go there — and because no static guard
  can ever see it, so it does not weaken the Step 1/Step 2 enforcement story. Fix it on the
  next door change that already needs a restart; do not cut a deploy for it alone.
- **`workstation-1puj` (P2, OPEN) — DEFERRED to `pcf3`.** Out-of-repo consumers are
  unenumerated by construction. More grep cannot close it; structural enforcement can.
  Tracked so a green guard is not misread as coverage it does not have.

## Explicitly NOT next (recorded so it is not silently re-promoted)

- `workstation-km5f` (Spine Stage 2, serve auth token) — PARKED, measuring until
  ~2026-08-11, pre-registered decision rule. Do not restart early; do not bundle.
- The frontdoor global-ro cache — CLOSED on evidence (`#221`): measured ~2x not 30x,
  plus an unbounded `arrayBuffer()` stall. Do not redesign it.
- **"Reopened sessions have 0 MCP tools" (`workstation-0dm8`) — CLOSED won't-fix, and it
  is NOT a door bug.** Filed P1 on 2026-08-01 blaming the 31 × HTTP 501 on `GET /mcp`
  seen during the reattach burst; four probes falsified that in ~15 minutes. The serves
  report all 14 MCP servers `disabled` when hit **directly**, bypassing the door, and the
  session-scoped `/session/{id}/mcp` *is* allowed through the door and returns the same
  all-disabled list — so the door hides nothing and the 501 is inert w.r.t. tool
  availability. All 14 ship `enabled: false` by deliberate config
  (grep `enabled = false` in the `atlassian` block of `users/dev/opencode-config.nix`,
  plus 13 siblings — cited as a grep anchor, not a line number, per this file's own rule).
  **Standing user preference, stated 2026-08-01: never wants always-on MCP servers**;
  given always-on vs always-off he chooses off and accepts starting them on demand after
  the morning restore. So: do NOT flip `enabled = true` as a convenience fix, do NOT
  re-file the 501, and do NOT fold any of it into `vjq0` or Step 2 residual (d) — those
  are about MCP being *lost* by placement/migration mechanics, a different and still-open
  failure. This one never had tools to lose.
  *Method note worth carrying:* it was filed because a memorable event was mistaken for
  evidence without asking whether the suspect could even produce the symptom. The
  discriminating probe — hit the component's upstream directly, bypassing the suspect —
  should come first; it cost minutes once it finally ran.
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
| the eon4 fix (closed) | PR #237 `0ded471`; grep `poolSafe` in `pkgs/opencode-frontdoor/src/routes.classification.ts`, `forward-pool` in `src/dispatch.ts`, `poolOrder` in `src/proxy.ts`; `FRONTDOOR_POOL_URLS` wired in `hosts/cloudbox/configuration.nix` (grep it), derived from `endpointsCsv` in `users/dev/serve-pool.nix` |
| member-stall gap (open, P1) | `workstation-nv5l`; grep `failoverIfUnreachable` in `pkgs/opencode-frontdoor/src/proxy.ts` |
