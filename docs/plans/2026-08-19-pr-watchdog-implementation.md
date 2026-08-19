# PR Watchdog Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the shepherding skill's open-ended post-CI-green polling with a self-rescheduling watchdog, so a PR is neither burned tokens on nor forgotten.

**Architecture:** Almost all of this is *prose in a skill*, not code. The only code change is a single-pass mode for `monitor-pr.py` so a woken session can run exactly one evaluation and end its turn. The behaviour change lives in `SKILL.md` and must be verified the way skills are verified — with subagent scenarios (superpowers:writing-skills), not unit tests.

**Tech Stack:** Python 3 (stdlib only), Bash test harness, Nix flake checks, Markdown skill authoring.

**Design doc:** `docs/plans/2026-08-19-pr-watchdog-design.md`
**Bead:** `workstation-plq5`

**Repo is PUBLIC.** No employer names, private repo names, logins, ticket keys, hostnames, or internal URLs anywhere in these edits. Refer to roles ("the gating reviewer", "the review daemon").

---

### Task 1: Characterise the existing budget behaviour before changing it

There is a strong chance `--once` is nearly free: `--budget-seconds 0` already
makes the loop evaluate once and fall through, because `remaining <= args.interval`
is immediately true. Confirm that before writing new code, so the diff stays honest.

**Files:**
- Read: `assets/opencode/skills/shepherding-pull-requests/monitor-pr.py:675-700`

**Step 1: Observe current behaviour**

```bash
cd assets/opencode/skills/shepherding-pull-requests
time python monitor-pr.py --budget-seconds 0 390
```

Expected: exactly one `--- iteration 1 ---` block, no sleep, and an exit that is
either 0/1 (definitive verdict) or 3 with the message `Re-invoke this script to
keep polling.`

**Step 2: Record the finding**

If single-pass already works, `--once` is an alias plus a corrected trailing
message — say so in the commit message rather than implying new capability. If it
does **not** single-pass, note the actual behaviour; the remaining steps are
unchanged either way.

---

### Task 2: Test for `--once` (write it first)

**Files:**
- Create: `users/dev/test-monitor-pr-once.sh`

The script shells out to `gh`, so the test stubs `gh` on `PATH` with canned JSON.
Precedent for a PATH shim test: `users/dev/test-bazel-scope-shim.sh`.

**Step 1: Write the failing test**

```bash
#!/usr/bin/env bash
# Guard: `monitor-pr.py --once` performs exactly ONE evaluation pass and never
# sleeps. The watchdog in the shepherding skill depends on this -- a wake that
# blocks for a full budget defeats the point of sleeping in the first place.
set -euo pipefail

SCRIPT="assets/opencode/skills/shepherding-pull-requests/monitor-pr.py"
[ -f "$SCRIPT" ] || { echo "FAIL: $SCRIPT not found (run from repo root)"; exit 1; }

stub=$(mktemp -d)
trap 'rm -rf "$stub"' EXIT

# `gh` stub: enough shape for get_pr_info / check_ci / reviews / threads.
# CI reports pending, which is the idle path -- the one that would sleep.
cat > "$stub/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"pr view"*statusCheckRollup*) echo '{"statusCheckRollup":[{"name":"check","status":"IN_PROGRESS","conclusion":""}]}' ;;
  *"pr view"*) echo '{"number":1,"url":"https://github.com/o/r/pull/1","baseRefName":"main","headRefName":"topic","author":{"login":"someone"}}' ;;
  *"api graphql"*) echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}' ;;
  *"reviews"*) echo '[]' ;;
  *) echo '[]' ;;
esac
STUB
chmod +x "$stub/gh"

start=$(date +%s)
set +e
out=$(PATH="$stub:$PATH" python3 "$SCRIPT" --once 1 2>&1)
code=$?
set -e
elapsed=$(( $(date +%s) - start ))

fail=0

if ! grep -q -- "--- iteration 1 ---" <<<"$out"; then
  echo "FAIL: no iteration ran"; fail=1
fi

if grep -q -- "--- iteration 2 ---" <<<"$out"; then
  echo "FAIL: --once ran more than one iteration"; fail=1
fi

if [ "$elapsed" -ge 10 ]; then
  echo "FAIL: --once slept (${elapsed}s); it must not"; fail=1
fi

# Idle CI must surface as the still-waiting code, not a false 'done'.
if [ "$code" -ne 3 ]; then
  echo "FAIL: expected exit 3 (still waiting) on pending CI, got $code"; fail=1
fi

# The trailing guidance must not tell a watchdog wake to re-invoke in a loop.
if grep -q "Re-invoke this script to keep polling" <<<"$out"; then
  echo "FAIL: --once printed the polling-loop guidance"; fail=1
fi

[ "$fail" -eq 0 ] || { echo "--- output ---"; echo "$out"; exit 1; }
echo "PASS: monitor-pr.py --once is single-pass, non-sleeping, exit-3 on idle"
```

**Step 2: Run it to verify it fails**

Run: `bash users/dev/test-monitor-pr-once.sh`
Expected: FAIL — `--once` is not a recognised argument yet (argparse error).

---

### Task 3: Implement `--once`

**Files:**
- Modify: `assets/opencode/skills/shepherding-pull-requests/monitor-pr.py` (argparse block ~600-621, and the trailing message ~693-697)

**Step 1: Add the flag**

```python
    parser.add_argument(
        "--once", action="store_true",
        help="Run exactly one evaluation pass and exit; never sleep. For the "
             "watchdog wake in the skill, where the session is awake only long "
             "enough to check state and either act or reschedule.",
    )
```

**Step 2: Make it single-pass**

After `args = parser.parse_args()`:

```python
    if args.once:
        args.budget_seconds = 0
```

**Step 3: Correct the trailing guidance**

The idle-exit branch currently prints `Re-invoke this script to keep polling.`,
which is wrong advice for a watchdog wake — it says spin, when the correct action
is reschedule and end the turn. Branch it:

```python
            if args.once:
                print("Single pass complete; still idle. Reschedule the next "
                      "wake and END THE TURN -- do not re-invoke in a loop.")
            else:
                print("Re-invoke this script to keep polling.")
```

**Step 4: Run the test to verify it passes**

Run: `bash users/dev/test-monitor-pr-once.sh`
Expected: `PASS: monitor-pr.py --once is single-pass, non-sleeping, exit-3 on idle`

**Step 5: Verify the default path is unchanged**

Run: `python3 assets/opencode/skills/shepherding-pull-requests/monitor-pr.py --help`
Expected: `--once` listed; `--budget-seconds` default still 60.

---

### Task 4: Wire the test into `nix flake check`

**This repo has a guard that fails CI for tests nobody runs** (`users/dev/test-unwired-tests.sh`). An unwired test here is worse than no test — it reads as covered.

**Files:**
- Modify: `flake.nix` (checks attrset; follow the `loader-pin` shape at `flake.nix:1248-1259`)

**Step 1: Add the check**

```nix
      monitor-pr-once = devboxPkgs.runCommand "monitor-pr-once-guard" {
        nativeBuildInputs = with devboxPkgs; [ bash python3 coreutils gnugrep ];
      } ''
        cd ${self}
        bash users/dev/test-monitor-pr-once.sh
        touch $out
      '';
```

**Step 2: Verify it is wired and green**

Run: `nix flake check 2>&1 | tail -20`
Expected: no failure attributable to `monitor-pr-once` or the unwired-tests guard.

**Step 3: Commit tasks 2-4 together**

```bash
git add users/dev/test-monitor-pr-once.sh assets/opencode/skills/shepherding-pull-requests/monitor-pr.py flake.nix
git commit -m "Add monitor-pr.py --once for watchdog wakes (workstation-plq5)"
```

---

### Task 5: Skill — hand off to the watchdog at CI-green

**Files:**
- Modify: `assets/opencode/skills/shepherding-pull-requests/SKILL.md` (§"Post-PR Monitoring" and §"Loop body")

Replace the implicit "poll until exit conditions" with an explicit handoff. Content
to add, in the file's existing voice:

- The loop is unchanged up to CI-green — it is cache-warm and correct for a short wait.
- At CI-green, if exit conditions are not met and what remains is *waiting on a
  review*, schedule a wake and **end the turn**.
- State the cost reasoning in one sentence: polling costs about a cache read per
  minute, a cold wake costs about a cache write, break-even is roughly twelve
  minutes — so a wait measured in tens of minutes should be slept through, and a
  wait measured in a minute or two should not.

**Do not restate** the reply/resolve/re-request mechanics; they already exist further
down. Cross-reference.

**Step 1: Make the edit. Step 2: Re-read the section top-to-bottom** and confirm it
does not contradict the existing §"Exit condition" or the flowchart. **Step 3:** update
the `dot` flowchart so the "Exit conditions met?" → "no" edge points at the watchdog
rather than unconditionally back at "Sleep 60s".

---

### Task 6: Skill — the watchdog itself

**Files:**
- Modify: `assets/opencode/skills/shepherding-pull-requests/SKILL.md` (new subsection after §"Loop body")

Content, all of which the design doc justifies:

- **Backoff:** 15m → 45m → 2h → 4h, capped at 4h.
- **Wake handler:** `monitor-pr.py --once`; exit 0 → cancel pending wake, report, done;
  exit 1 → fix, push, re-request if warranted, reschedule at the *current* step;
  exit 3 → reschedule at the *next* step; exit 2 → surface to the user, do not silently reschedule.
- **Idempotence:** verify-act-or-no-op. Two wakes can arrive for one PR. An agent that
  does not check first will double-re-request the reviewer.
- **Cancel-on-terminal, stated as a correctness requirement**, with the reason: the PR
  merges, the nightly reset prunes the merged worktree, and the orphan wake fires into
  a missing working directory, which the message bus refuses to deliver into. Give the
  command shape (`swarm_scheduled` list → cancel).
- **Stale refresh:** no review at all and the PR untouched for ~20h → re-request the
  reviewer to bump `updatedAt`. Reason: the review daemon's funnel drops PRs idle >24h,
  permanently, while every component reports healthy. Skip once approved.
- **Give up:** at the 4h cap with no state change, post a top-level status comment and
  hand back to the user.
- **Wake payload:** self-contained per `scheduling-wakes` — PR URL, repo, branch,
  worktree path, backoff step, and the `--once` instruction.

---

### Task 7: Skill — anti-patterns

**Files:**
- Modify: `assets/opencode/skills/shepherding-pull-requests/SKILL.md` (§"Common mistakes")

Add three, in the established voice:

- **Sleeping without scheduling a wake.** Ending the turn is only legitimate if
  something will bring you back. Nothing runs until someone prompts you.
- **Leaving the wake scheduled after the PR lands.** It fires into a pruned worktree
  and burns the delivery budget. Cancel on terminal.
- **Re-invoking `--once` in a loop.** That is the polling loop with extra steps and a
  cold cache. If you are awake and idle, reschedule and stop.

---

### Task 8: Verify the skill changes (RED/GREEN, per superpowers:writing-skills)

Skill edits are verified with subagent scenarios, not unit tests.

**Step 1 (RED):** dispatch a subagent with the *current* skill and the scenario "CI just
went green, no review yet, lgtm-bound PR — what do you do?" Record whether it polls
indefinitely and whether it schedules anything.

**Step 2 (GREEN):** same scenario with the edited skill. Expect: schedule a wake, end
the turn, name the backoff step.

**Step 3 (REFACTOR):** dispatch the terminal scenario — "wake fired, `--once` returns
exit 0, PR is approved and merging." Expect the subagent to **cancel the pending wake**
unprompted. If it does not, the cancel-on-terminal text is too weak; strengthen and
re-test.

**Step 4:** record the outcomes in the PR description.

---

### Task 9: Land it

**Step 1:** `nix flake check`
**Step 2:** commit the skill edits
**Step 3:** push, `gh pr create`
**Step 4:** REQUIRED SUB-SKILL: `shepherding-pull-requests` — invoke it the moment
`gh pr create` returns. Note the irony and do not skip it.
**Step 5:** `bd close workstation-plq5` once merged.
