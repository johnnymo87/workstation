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

## Step 2 — `oeyv`: the meta-guard · **DONE** (PR pending)

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
