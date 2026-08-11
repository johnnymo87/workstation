# Unverified-Claims Roadmap — guards for things this repo asserts but never checks

**Beads:** ~~`workstation-pscu`~~ (done) · ~~`workstation-oeyv`~~ (done) · `workstation-h0mp` (P1)
**Started:** 2026-08-04 · **Status:** step 1 shipped (PR #305)
**Also owned here:** `workstation-dimz` (P2, step 4) · `workstation-om5r` (P3, step 5) — spawned by step 1
**Spawned by step 2:** `workstation-5m47` (P1) · `workstation-k7t4` (P2) · `workstation-dad9` (P2) · `workstation-m98t` (P3) — the 50 unwired test files the guard found, now each carrying a marker

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
| `dimz` — the oc-auto-attach suite | "oc-auto-attach's helpers are tested" | Since written — the assertions exercise *copies* of the helpers, not the helpers | Adversarial review of step 1 |
| `om5r` — `NIX_BUILD_TOP` guard | "this is running inside a Nix build" | Since written — `nix-shell` sets it too | Step 1 needing the same guard |

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

## Step 2 — `oeyv`: the meta-guard · **DONE** (PR #310)

**Bead:** `workstation-oeyv` (P2)

Shipped as `checks.test-reachability` (`users/dev/test-unwired-tests.sh` plus its
meta-test). Every test file must be executed by CI — via a `checks.*` entry
(transitively) or an explicit workflow step. `checkPhase` is deliberately **not**
accepted, because that is exactly where this repo has been fooled: oc-session-list
set `doCheck = true` while its checkPhase ran `--help`, and its 700-line suite ran
for months. Accepting checkPhase would make the guard certify a known instance of
its own motivating defect as covered.

### What running it found: the step's own premise was wrong

This step was sequenced after `pscu` on the reasoning that the guard should land
on a repo that already satisfies it, or you end up allowlisting the very files it
exists to catch. Sound reasoning, wrong arithmetic. **`pscu` fixed 1 of 51.**

Measured on `main`: **76 candidate test files, 24 executed by CI, 50 not.** Not a
handful of stragglers — two thirds of the repo's test files, including
`pkgs/opencode-frontdoor`'s entire 25-file suite covering the routing layer.
The plan asserted a state of the world it had never counted.

A strict guard would therefore have shipped with a 50-entry allowlist on day one.
So the debt is declared **in each unwired file's own header** —
`unwired-test(<bead>): <reason>` — not in a central list. That shape is not a
preference: `test-frontdoor-opacity.sh` documents, from two prior failures here,
why a central allowlist rots (nothing forces it to be revisited when code moves)
and the roadmap's own history is a table of items nobody looked at again. A marker
appears in the diff that creates it, self-deletes when the file is wired, and
`git grep -c 'unwired-test('` is the census. The guard fails in **both**
directions: an unwired file without a marker, and a wired file that still has one.

The 50 are owned by four beads: `workstation-5m47` (the frontdoor suite — needs a
CI step, not a nix check: `npm ci` and loopback sockets cannot be hermetic),
`workstation-k7t4` (suites probing live host state), `workstation-dad9` (7 that
look cheaply wirable — start here), `workstation-m98t` (the plugin-bundle family,
which runs `nix build` on itself).

### Mutation-tested, and it found two defects in the guard

Six mutations, all syntactically valid so the guard actually ran. Four were caught
immediately. Two were not, and both were the dangerous kind:

* A broken checks-block seed **failed for the wrong reason** — it reported "14
  test files nothing executes", naming correctly-wired files. Failing loudly is
  not enough when the message tells people to add markers to covered files. It now
  detects its own extraction failure and says *do not add markers*.
* The runner-glob tripwire **did not fire at all**: it grepped for the bare string
  `plugin-vitest`, which survived in prose after the attribute was renamed. It now
  matches attribute definitions. That is dmat's defect — trusting an include
  pattern that stopped including — rebuilt inside the guard meant to prevent it.

Both are now meta-test cases. The meta-test runs in the same derivation, because a
guard that cannot fail is the defect it exists to detect, and this repo has already
shipped one that sat inert.

**Exit:** met. Guard in CI, reason per entry, mutation-tested including vacuity.

---

## Step 3 — `h0mp`: detect a stale `home-manager switch` · **DONE**

**Bead:** `workstation-h0mp` (P1, filed 2026-08-01) · shipped as
`home.activation.assertFreshDeploy` (`users/dev/hm-deploy-gate.nix`), logic in
`pkgs/hm-deploy-gate-sh/`, checks `hm-deploy-gate` + `hm-deploy-gate-behaviour`.

home-manager is **last-writer-wins across concurrent worktrees**. A switch run
from a checkout branched before a config landed silently reverts it fleet-wide —
this was S0's actual root cause, and it un-deployed the session-state writer
across the whole fleet while `main` still shipped the block that declares it.

### The step's own MVP was vacuous — measured, not argued

The bead and this roadmap both claimed that verifying "the expected files exist in
the new generation" would alone have caught the 32-hour outage. It would not have
caught **either half**:

* `git show 84900bd~1:users/dev/opencode-config.nix | grep -c session-state` is
  **0**. The stale worktree predated #230, so its config declared the plugin zero
  times and its generation *correctly* lacked the file. An existence check passes.
* The same command for `shell-env` is **1** — declared before and after, so the
  file existed in both generations and only its *content* reverted. An existence
  check passes.

home-manager already guarantees declared→linked (activation fails otherwise), so
that check largely re-tests home-manager. Detecting this class **requires a
reference from outside the config being deployed** — which the bead had
deprioritised as a "SECOND step [that] must not block the first". The
decomposition was inverted: the deferred half was the only half that works.

### What shipped, and why not the canary the bead leaned toward

Each switch records the revision it deployed in a beacon
(`~/.local/state/hm-deploy-rev`). The gate runs `entryBefore writeBoundary`,
reads the *previous* switch's beacon, and refuses when the incoming revision does
not contain it — i.e. when activating would drop commits that are live right now.
No network, no plugin inventory, no `.nix` parser to rot: any regression is caught
regardless of which file changed. `merge-base --is-ancestor` also catches the
*diverged* case, which a "is HEAD behind main" check misses entirely.

A periodic canary lets the bad switch land and pages someone later, if the alert
path happens to be up. The gate aborts in the terminal of the agent making the
mistake. The bead's own tiebreaker — "fails LOUDLY and cannot be silently
skipped" — picks the gate.

The pre-implementation review overturned a claim of mine: I asserted there was no
hook point, since AGENTS.md documents a raw `nix run home-manager -- switch` with
no wrapper. `home.activation.assertPlatform` (`users/dev/home.cloudbox.nix:232`)
already aborts activation for the sibling "wrong config silently deployed" class.
Same shape, no wrapper needed, no human compliance required.

### Fail-closed on proof, fail-open on doubt — but never silent

This gate can block every agent on a shared box (four switches landed on
2026-08-04 alone), so a false refusal is worse than the incident. It aborts only
on a *proven* regression and warns on every form of doubt.

The behavioural suite caught the defect that shape invites: with its library
absent, every `hm_gate_*` call became "command not found", `VERDICT` was empty,
the `case` matched nothing and **the gate allowed every deploy in silence** —
fail-green, inside the guard family built to kill fail-green. The library suite
could not have found it; everything it exercises returns a string. Only running
the real activation script does. There is now an explicit library-load check, a
catch-all branch, and a regression test.

Also caught, in my own tests: the dispatch was inlined in the module and
*mirrored* in the test file, so the suite tested its own copy. That is precisely
step 4's defect, one step early. It is now one shared `hm_gate_classify`.

**Exit: met, with a stated limit.** Verified by running the *real* activation
script from the evaluated cloudbox config against the *real* repo and the *real*
incident commits: deploying `84900bd~1` over today's `main` aborts with exit 1 and
names the 85 commits it would drop. Forward deploys and the no-beacon bootstrap
case do not block. What was **not** done: a literal end-to-end `home-manager
switch`. Making one refuse requires a beacon in the live profile, and installing
one means deploying an unmerged branch to the box every other agent is working on.
The seams run the same script on the same code path with scratch inputs; that is
the honest substitute, and the gap is stated rather than papered over.

### Follow-up: v1 shipped a structural false positive (fixed same day)

The first real deploy exposed one. An agent had deployed from a PR branch —
normal, you test a config change before merging — and that PR was then merged
with `gh pr merge --squash`, which rewrites the commit to a new sha. The branch
commit was no longer reachable from `main`, so the ancestry test called the next
switch-from-main a regression and refused it. Measured on cloudbox 2026-08-05:
deployed `1c11c82` (`docs/s8-shim-verified`), squash-merged as `58c7310`; the
gate blocked a switch that dropped nothing. This repo merges exclusively with
`--squash`, so the false refusal was structural, and it blocked *every* agent.

The fix asks what would actually be **lost** rather than whether the shas line
up: the newest published ancestor of the deployed rev is
`merge-base(deployed, origin/main)`, and if the incoming tree already contains
it, everything being dropped is unpublished. Exact in both directions — a branch
cut from a *newer* main than the incoming tree does lose published commits and
still refuses, where a naive "is the deployed tip published?" test would fail
open.

**The same trap caught a later status check of mine.** On 2026-08-11, asked
whether the fix was deployed, I ran `merge-base --is-ancestor` against the fix's
*branch* commit and reported "still v1" — while the fix was plainly present in
the live activation script. That branch commit had been squash-merged to a
different sha, exactly as above. Sha ancestry is not content identity in a
squash-merge repo, and having just fixed that bug did not stop me reaching for
the wrong instrument again. Check deployed *content*, or the merge commit on
`main` — never the branch sha.

Worth recording as its own lesson: the blast-radius reasoning in this step was
right in the abstract and still under-imagined the *shape* of the false
positive. A gate on a shared deploy path needs its benign cases enumerated from
the repo's actual workflow, not from the incident alone.

**Spawned:** `workstation-4ze8` (P1) — the drift canary as a *second layer*, in a
different deploy channel (a NixOS system unit cannot be removed by a home-manager
switch). It owns every `warn:` path the gate cannot close itself: the bootstrap
window, absent objects, the escape hatch, and drift with no switch at all
(hand-deleted files, dangling `mkOutOfStoreSymlink` targets — which, note, do
*not* fail activation). It should also serve `workstation-5yox` step 3, which
needs an expected-set reference and would otherwise grow a second list that rots.

---

## Step 3.5 — `5m47`: the biggest untested surface · **DONE** (PR #346)

Not a numbered step when this roadmap was written — it was spawned by the step-2
census as the largest single block of debt: **25 test files, 496 assertions**
covering the routing layer every consumer is required to go through, executed by
nothing.

### The bead prescribed the wrong fix, for a reason that was already refuted in-tree

`workstation-5m47` said the suite was "genuinely un-runnable AS A NIX CHECK"
because it binds loopback sockets "which the hermetic nix sandbox forbids", and
prescribed a `.github/workflows/ci.yml` step. `default.nix` carried the same
claim as the justification for `doCheck = false`, and `test.sh`'s header stated
it a third time.

The claim is false, and **the counter-example was six lines below it in the same
comment**: `route-gate.nix` boots a real `opencode serve` on `127.0.0.1` inside
the sandbox and *depends* on the sandbox's private network namespace to make a
fixed port safe. The header said so explicitly while the sentence above it said
the opposite. Only `npm ci` was a real obstacle, and `importNpmLock` — already
used by the plugin suites — removes it.

Measured, in order: the suite is **green, not red** as the bead warned (496/496,
4 seconds). First sandbox attempt **495/496** — the one failure was
`wire-text.test.ts` resolving `../../..` to the repo root, exactly the hazard
`plugin-vitest` documents and solves by copying all of `${self}`. Then an EACCES
writing vitest's cache into the read-only store, which fired *after* all 496
tests passed. Final: **496/496 in the sandbox**.

The lesson is not "the bead was wrong". It is that a false claim had been copied
into three files, and each copy made the other two look corroborated. Nobody had
run the experiment; the refutation was sitting in the tree the whole time.

### A guard cannot see a suite it does not name

`checks.frontdoor-vitest` invokes `vitest run` against a directory, naming no
file. The reachability guard's matcher is deliberately execution-shaped, so it
saw none of the 25 files. Measured rather than assumed: deleting the markers
made the guard report all 25 as executed by nothing — a false positive on code
that now runs on every PR, which is precisely how a guard trains people to
ignore it.

The fix follows the existing runner-glob channel: honour the directory, but only
while a tripwire confirms the check behind it still exists.

**The rejected alternative is the interesting one.** A `.glob-covered-by`
dotfile in the test directory would have travelled with the files and generalised
the channel — marker-shaped, which is what this repo chose over central lists.
It was rejected because that doctrine turns on **decay direction**, which the
marker-vs-list framing hides:

- An `unwired-test(...)` marker claims *"I am NOT covered"*. A false one fails
  **loudly** — the guard checks it in both directions.
- A `.glob-covered-by` file claims *"I AM covered"*, and the guard cannot
  evaluate nix to falsify it. A false one fails **silently**, and it is a
  self-service channel: any directory could launder itself into "covered" by
  naming any attribute that happens to exist.

A hardcoded entry decays in the safe direction instead — rename the directory
and its files report unwired; delete it and the entry goes inert. The cost, that
claiming coverage requires editing the guard itself, is the feature: a coverage
claim should be reviewed in the most sceptical file in the repo.

### What the adversarial review caught that I had not

Pre-implementation review found a defect in the design as specified: the existing
glob entry covers `*.test.ts` **and** `*.spec.ts`, because two runners there
split on that suffix. `checks.frontdoor-vitest` runs no `.spec` glob, so copying
that entry verbatim would have certified a stray `test/foo.spec.ts` as covered
while nothing executed it — rebuilding the `dmat` defect *inside the fix for it*.
The new entry covers `*.test.ts` only, mirroring exactly what the check's own
set-diff enforces, and meta-test case 15 exists to make the verbatim copy fail.

Three mutations, all caught: widening the glob to `.spec.ts` (case 15), removing
the tripwire (case 14), removing the channel (case 13).

Census: **31 → 56 files executed by CI, 52 → 27 declared unwired.**

## Step 4 — `dimz`: stop testing mirrors of the production helpers · **NOT STARTED**

**Bead:** `workstation-dimz` (P2, spawned by step 1, 2026-08-04)

`pkgs/oc-auto-attach/test-project-key.sh` defines its own copies of
`project_key`, `window_name`, `parse_serve_url`, `classify_session_probe` and
`list_session_panes`, and asserts against the copies. Production lives in
`pkgs/oc-auto-attach/default.nix`. Step 1 made those assertions *run*, which is
strictly better than inert — but running a test against a copy still cannot see
production drift.

About 35 greps pin the production source's *shape*, and they are uneven:
`project_key`/`window_name` are pinned to their exact derivation lines and
`list_session_panes` has both a positive and a negative anchor, but
`parse_serve_url`, `resolve_nvims` and `classify_session_probe` are pinned **by
name only**.

**The concrete hole is `classify_session_probe`.** Its grep asserts only that the
function exists; the companion `OC_AA_404_GRACE_SECS` grep matches the *caller*,
not the classifier. So a revert of `workstation-ovqu` — the fix for a definitive
404 hanging a terminal for 30s — passes every grep and every mirror assertion,
because the mirror in the test file still holds the corrected logic.

**Next action:** the built artifact is plain text and the suite already reads it
as `$oc_aa`. Extract the production function bodies and run the *existing*
behavioural assertions against them:
`eval "$(sed -n '/^classify_session_probe()/,/^}$/p' "$oc_aa")"`. Nix `''`
string indent-stripping puts them at column 0, so extraction works. Do it for
the four pure functions, then delete the mirrors (or keep them and byte-diff
extracted-vs-mirror).

**Exit:** a mutation that changes production's 404 handling in `default.nix`,
without touching the test file, fails `nix flake check`. Verify by actually
applying that mutation — and make it a *syntactically valid* one, because step 1
already produced a false positive where a mutation broke the package build and
the guard never ran.

---

## Step 5 — `om5r`: the `NIX_BUILD_TOP` heuristic is false · **NOT STARTED**

**Bead:** `workstation-om5r` (P3, spawned by step 1, 2026-08-04)

`assets/nvim/test-session-switcher.sh:19-30` hard-fails when `nvim` is missing
*if* `NIX_BUILD_TOP` is set, reasoning that "inside a Nix build the derivation
guarantees nvim". The inference is false, measured on cloudbox:

```
$ nix-shell -E 'derivation {...}' --run 'echo $NIX_BUILD_TOP $IN_NIX_SHELL'
NIX_BUILD_TOP=/tmp/nix-shell-466095-579280698   IN_NIX_SHELL=impure
```

A developer in any nix-shell without `nvim` gets
`FAIL nvim missing inside the Nix build (check is mis-wired)` — a message that
is simply a lie about their situation. The failure is loud rather than silent,
so this is a papercut, not an outage, which is why it is P3 and was not fixed
inside PR #305.

**Next action:** port step 1's positive control. `checks.nvim-lua` sets the
guarantee explicitly in the derivation env and the script trusts *that* rather
than sniffing ambient state — which also covers `nix develop` and any future
runner without having to know how each one sets its environment.

**Exit:** running `assets/nvim/test-session-switcher.sh` inside a nix-shell
without `nvim` SKIPs honestly; removing `neovim` from the `nvim-lua` check's
`nativeBuildInputs` still hard-fails. Both verified by doing them.

---

## Debt registry — every bead this roadmap spawned or adopted

Kept here so nothing is loose. Counts are `unwired-test(<bead>)` markers on
`main` as of 2026-08-11, and they are the guard's own bookkeeping: wiring a file
and leaving its marker behind FAILS the build, so these only go down by real work.

| Bead | P | Marked files | Owns |
|---|---|---|---|
| `workstation-5m47` | P1 | 0 | ~~The opencode-frontdoor vitest suite.~~ **DONE, PR #346** — wired as `checks.frontdoor-vitest`. Both premises in the row it replaces were wrong: see below. |
| `workstation-k7t4` | P2 | 13 | Suites that probe live host state (systemd/tmux/sockets); need fixture injection to become hermetic. |
| `workstation-dad9` | P2 | 7 | Suites that look cheaply wirable — "add a checks entry and grep the final PASS line". The best starting point. |
| `workstation-dimz` | P2 | 1 | Step 4's bead, which now also owns `pkgs/opencode-frontdoor/test.sh` — what is left of it after the vitest half moved into CI is a developer mirror of `route-gate.nix` needing the pinned opencode binary. |
| `workstation-3g4j` | P2 | 3 | `reset-workspace/test.sh`, plus `nvims` and `opencode-launch`. **Adopted, not spawned** — it predates the census. |
| `workstation-m98t` | P3 | 3 | The plugin-bundle family, which runs `nix build` on itself. |
| `workstation-4ze8` | P1 | — | Step 3's second layer: a drift canary in a different deploy channel. Owns every `warn:` path the gate cannot close itself. |

### The audit that produced this table found a real defect

`workstation-3g4j` was filed 2026-08-03, one day *before* the census, and already
owned `pkgs/reset-workspace/test.sh` — with a better diagnosis than the marker I
later put on it. Mine said "probes live host state; needs fixture injection".
3g4j records that registering it was **tried and backed out**: two SIGPIPE
assertions pass outside the nix sandbox and fail inside, and a `trap - PIPE` in
the derivation did **not** fix it. Anyone working from my reason would have
repeated an experiment already known to fail. Those three markers now point at
3g4j and carry its finding.

**This is the guard's known blind spot, now demonstrated rather than theorised.**
A marker's bead id is not mechanically verified — there is no `bd` in the build
sandbox — so a marker can cite a bead that is wrong, superseded, or nonexistent
and still pass. Splitting one file's ownership across two beads is precisely what
that permits. Options if it recurs: cross-check marker ids against this table in
the guard (cheap, needs no `bd`, but reintroduces a central list), or accept it
and re-audit periodically. Deliberately undecided — the case for the central
list strengthens each time an id drifts.

### Adjacent spines that touch these files but do NOT own the wiring

Recorded so a later reader does not mistake a mention for a claim.
`workstation-km5f` and `workstation-q1tu` both touch
`pkgs/opencode-frontdoor/test.sh`; `workstation-yvxh.10` and `workstation-yvxh.11`
both touch the phantom-busy-sweeper tests. None of them claims responsibility for
getting those suites into CI — that stays with `5m47` and `k7t4`.

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
