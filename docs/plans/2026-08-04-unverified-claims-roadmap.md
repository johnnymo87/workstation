# Unverified-Claims Roadmap — guards for things this repo asserts but never checks

**Beads:** ~~`workstation-pscu`~~ (done) · `workstation-oeyv` (P2) · `workstation-h0mp` (P1)
**Started:** 2026-08-04 · **Status:** step 1 shipped (PR #305)
**Spawned:** `workstation-dimz` (P2, mirror drift) · `workstation-om5r` (P3, NIX_BUILD_TOP heuristic)

These three items were discovered while executing *other* roadmaps and were
parked in the session-switcher plan's "spawned work" table, which recorded why
each was deferred but never who would do it or when. Forty PRs merged while they
sat. This file exists to give them a spine and an exit condition; the switcher
plan now points here instead of holding them.

---

## The pattern

Every item below is the same shape: **the repo asserts something is true, and
nothing checks the assertion.** The claim is load-bearing, the check is absent,
and the absence is invisible because a missing check looks exactly like a passing
one.

Four measured instances, all found by hand, none by machine:

| Instance | The claim | How long it was false | Found by |
|---|---|---|---|
| `frontdoor-opacity` guard | "no consumer addresses an individual serve" | Red on `main` from **#217 until 2026-08-01** — wired to no flake check, no CI step, no canary (`flake.nix:185-186`) | Someone reading the file |
| `dmat` — three TS harnesses | "the plugin package has 239 tests" | Unknown duration; `npm test` exited **green over a bun suite it never loaded** | S6 needing a place to put tests |
| `pscu` — `test-project-key.sh` | "oc-auto-attach is tested" | Since it was written until **2026-08-04** — no `doCheck`, and CI runs only `nix flake check`. When finally run it failed, and on a stripped PATH silently dropped 20 of 71 assertions | S4 needing the same |
| `h0mp` — home-manager switch | "the deploy shipped the config it declares" | ~32h of `shell-env.ts` silently un-deployed; also S0's actual root cause | Reading a generation by hand |

The lesson is already written in `flake.nix:226` — *a guard nothing runs is
documentation with a shebang* — and it has now been re-learned four times. The
point of this roadmap is to stop learning it.

---

## Ordering constraint (do not get this wrong)

**`pscu` must land before `oeyv`.** — *satisfied 2026-08-04 (PR #305); `oeyv` is now unblocked and lands on a repo that already satisfies it.*

`oeyv` is a repo-wide meta-guard that enumerates candidate test files
(`*test*.sh`, `*.test.ts`, `*.spec.ts`, `test-*.lua`, nix `checkPhase` scripts)
and asserts each is reachable from some flake check. `pscu`'s
`pkgs/oc-auto-attach/test-project-key.sh` is *precisely* such a file, and is
*precisely* unreachable.

So if `oeyv` goes first, its own first run flags `pscu`, and whoever is holding
it has two choices: fix `pscu` inside the `oeyv` PR (scope blowout, since nobody
knows what that script does when it finally runs), or **add the exact file the
guard exists to catch to the guard's allowlist**. The second is what actually
happens under deadline, and it ships a guard pre-loaded with an exemption for its
own motivating case.

Fix `pscu` first. Then `oeyv` lands green on a repo that already satisfies it.

---

## Step 1 — `pscu`: wire `test-project-key.sh`, then fix what it finds · **DONE** (PR #305)

**Bead:** `workstation-pscu` (P1, filed 2026-08-02) — closed 2026-08-04.

Registered as `checks.oc-auto-attach`. The step was never "wire it up", and the
prediction that it would not simply be green held.

**What running it for the first time found.** The `nvim -l` harness called
`loadfile()` on a **cwd-relative** path: the suite passed from the repo root and
failed from its own directory. Now absolute via `BASH_SOURCE`. The check
deliberately does *not* `cd ${self}` — it runs from `$TMPDIR` by absolute store
path, so cwd-independence is exercised rather than masked. The first draft *did*
`cd ${self}` and would have been green over the very bug it was added to catch.

**What would have made the fix fake.** On a stripped PATH the suite printed `all
oc-auto-attach helper tests passed` and **exited 0 having run 51 of its 71
assertions** — dropping every tmux, lua and production-artifact assertion it
has. A naive `runCommand` would have closed this bead while asserting nothing.
Two gates prevent it: `OC_AA_REQUIRE_ALL_TOOLS=1` makes a missing tool fatal,
and `EXPECTED_ASSERTIONS=71` plus a flake-side grep for the exact tally and for
the absence of `SKIP` means coverage cannot shrink quietly.

**One heuristic that looked obvious and was wrong.** The natural guard —
"`NIX_BUILD_TOP` is set, therefore we are inside a Nix build" — is false.
`nix-shell` exports `NIX_BUILD_TOP=/tmp/nix-shell-<pid>` and
`IN_NIX_SHELL=impure` (measured). Shipping it would have hard-failed any
developer in a nix-shell without tmux, with a message asserting their check was
mis-wired. The fix is positive control: the *runner* declares that it guarantees
the tools. Sniffing the ambient environment guesses; a variable the runner sets
states. `assets/nvim/test-session-switcher.sh` still carries the original
heuristic — `workstation-om5r`.

**Verified by mutation** (17, all caught), because a guard that cannot fail is
the bug being fixed. One was a **false positive worth recording**: mutating
`list-panes -a -f` in `default.nix` produced a bash syntax error, so the package
never built and the drift guard never ran — "caught" for the wrong reason. Redone
with syntactically valid mutations it fires correctly, and adding the fragile
scan form while *keeping* the good one proves the negative assertion is not
vacuous.

**Left open deliberately:** the suite exercises **mirrors** of the production
helpers rather than production itself — `workstation-dimz`, with
`classify_session_probe` named as the concrete hole (its grep pins only the
function's existence, and the companion `OC_AA_404_GRACE_SECS` grep matches the
*caller*, so a revert of the `workstation-ovqu` 30s-hang fix would pass every
check). Fixable by `eval`-ing the function bodies straight out of the built
artifact, which the test already reads.

---

## Step 2 — `oeyv`: the meta-guard · **NOT STARTED** (unblocked 2026-08-04)

**Bead:** `workstation-oeyv` (P2)

Converts the recurring human catch into a mechanical one. Enumerate candidate
test files repo-wide, assert each is referenced by a flake check, a derivation
`checkPhase`, or a runner include pattern. `dmat` shipped the within-package
version (`assets/opencode/plugins/test-runner-coverage.sh`); this is the repo-wide
sweep.

**Must check RUNNER COVERAGE, not file existence.** `dmat`'s failure was a
harness that existed and passed locally while silently skipping a whole suite,
because vitest's `test/**/*.test.ts` include did not match a bun `.spec.ts` file.
"Is there a harness?" would have answered yes.

**This step requires an adversarial review before implementation, not after.**
It is a guard that gates every future PR, and this repo has already shipped a
meta-guard whose exemption mechanism was wrong badly enough to be reverted (the
front-door opacity guard's borrowed-row exemption — see the repo `AGENTS.md`
section "Front-Door Opacity Guard", which now rejects citing a row that does not
describe your file). The failure mode is not a missed test; it is **false
positives that train everyone to reach for the allowlist**, which is strictly
worse than no guard. Copy the exemption-with-reason shape from
`users/dev/test-frontdoor-opacity.sh` (`EXPECTED_MANIFEST`) rather than inventing
a second convention.

**Exit:** the guard runs in CI, the allowlist has a reason string per entry, and
the guard is mutation-tested — including the vacuity case where its own
enumeration returns nothing.

---

## Step 3 — `h0mp`: detect a stale `home-manager switch` · **NOT STARTED**

**Bead:** `workstation-h0mp` (P1, filed 2026-08-01)

home-manager is **last-writer-wins across concurrent worktrees**. A switch run
from a checkout branched before a config landed silently reverts it fleet-wide —
this was S0's actual root cause, and it un-deployed the session-state writer
across the whole fleet while `main` still shipped the block that declares it.

Different family from steps 1-2 (a deploy claim, not a test claim) but the same
shape: *the artifact asserts a config is deployed; nothing verifies the generation
contains it.*

**Minimum viable version:** after a switch, verify the expected files exist in the
new generation and fail loudly if not. That alone would have caught the 32-hour
`shell-env.ts` outage. Anything more (branch-freshness checks, locking) is a
second step and should not block the first.

**Exit:** a switch from a deliberately stale worktree fails, or warns loudly
enough that nobody misses it — verified by actually doing it, not by reasoning
about it.

---

## Not in this roadmap

* **`workstation-5yox`** — the plugin-loader hardening work. It is NOT an
  unaddressed leftover: it has its own roadmap
  (`docs/plans/2026-08-01-plugin-loader-hardening-roadmap.md`), **steps 0-2
  shipped**, step 3 split into 3a/3b with a design doc, step 4 pending. Listed
  here only because a session handoff once flattened it into "open and
  unmeasured", which is wrong and should not be repeated.
* **`workstation-095u`**, **`workstation-9i5k`** — genuinely session-switcher
  domain; they stay in that plan. `9i5k`'s next action is a **measurement**
  (is there actually a morning `nodata` storm?), not a fix — it is explicitly
  *suspected, not measured*.
