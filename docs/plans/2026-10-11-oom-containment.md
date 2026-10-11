# OOM containment (kill, don't throttle) — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** a runaway in dev's user slice ends in a kill instead of a
multi-hour throttle, and the serves are not the preferred victim.

**Design:** `docs/plans/2026-10-11-oom-containment-design.md`. Read it first;
the rationale and the adversarial-review findings live there.

**Architecture:** NixOS slice and unit config only, plus one docs edit.
No new code.

**Branch/worktree:** `oom-containment` at
`~/Code/workstation/.worktrees/oom-containment` (Mac); edit and commit there.

**Deploy (devbox, before merge):** from a dedicated devbox worktree, never the
primary root. Not `work <slug>`, which branches off origin/main.

```bash
git -C ~/projects/workstation fetch origin oom-containment
git -C ~/projects/workstation worktree add --detach ~/projects/workstation/.worktrees/oom-containment origin/oom-containment
cd ~/projects/workstation/.worktrees/oom-containment
sudo nixos-rebuild switch --flake .#devbox
systemctl --user stop pull-workstation.timer   # else it re-applies MAIN's home-manager every 4 h, reverting Task 3
nix run home-manager -- switch --flake .#dev
systemctl --user restart opencode-serve-pool.target   # quiet moment (~10 s, interrupts in-flight turns); adj applies only at process start
```

After merge: `systemctl --user start pull-workstation.timer`, then remove the
deploy worktree. Say in the PR that the timer is stopped until merge.

One PR for everything. Deploy devbox from the PR branch before merge; deploy
cloudbox only after merge plus a day of devbox soak (the owner deploys
cloudbox, or a session on cloudbox).

---

### Task 1: devbox user slice MemoryHigh → MemoryMax

**File:** `hosts/devbox/configuration.nix` (~1377-1391, the "P4" block).

**Step 1:** Change `MemoryHigh = "20G";` to `MemoryMax = "20G";`. Keep
`MemorySwapMax = "6G"` and `TasksMax`.

**Step 2:** Rewrite the P4 comment. Keep the sizing rationale (30G host, K=2
x 6G serves). Replace the "Slice-level High is kept … earlyoom backstops"
justification with: the 2026-10-11 incident, one sentence on why High
throttled the whole slice for 12 h, and a pointer to the design doc. Also say
that a slow leak can still thrash at Max (design "Goal").

**Step 3:** `nix eval --raw .#nixosConfigurations.devbox.config.systemd.slices.user-1000.sliceConfig.MemoryMax`
→ `20G`; and `…MemoryHigh` → error or null (not set).

### Task 2: devbox earlyoom prefer

**File:** `hosts/devbox/configuration.nix:1339`.

**Step 1:** In `--prefer`, delete `\\.opencode-wrapp|` so the regex is
`"(^|/)(node|bun|headless_shell|nix-build)$"`. Do not add `beam.smp`.

**Step 2:** Add a comment above `extraArgs`, modelled on cloudbox's
(`hosts/cloudbox/configuration.nix` ~5826-5850): why the serves are not
preferred, the 2026-10-11 evidence (earlyoom chose serve :4096, oom_score
1309, which included the +300 preference, then failed with "kill failed:
Timer expired" every 10 s for an hour), and that no earlyoom option bounds
retries on a frozen victim.

### Task 3: devbox serve OOMScoreAdjust 500 → 200

**File:** `users/dev/home.devbox.nix:908` (serve unit). Also check that
`users/dev/serve-pool.nix` doesn't set it too: `grep -n OOMScoreAdjust users/dev/serve-pool.nix`.

**Step 1:** `OOMScoreAdjust = 500;` → `OOMScoreAdjust = 200;`

**Step 2:** Comment: an OOM at a cgroup limit sizes adj points against
`memory.max + swap` (26G here, so 1 point = 26 MB). At 500 the serves carried
a 7.8G handicap against an adj-200 `systemd-run --user` job. At 200 they tie,
and size decides. Going to 0 (cloudbox's shape) waits on porting
oc-scoped-shell (bead D).

**Step 3:** This is home-manager, not NixOS. The serve unit and the pool target
are `X-SwitchMethod=keep-old` (`home.devbox.nix:819,933`), so the switch never
restarts them, and devbox has no nightly reset. The deploy block in the header
restarts the pool explicitly. Agent children started before the restart
(e.g. the dev-daemons devenv scope) keep adj 500 until they restart.

### Task 4: devbox systemd-oomd in dry-run

**File:** `hosts/devbox/configuration.nix`, next to earlyoom.

**Step 1:**

```nix
  # systemd-oomd on user slices, DRY-RUN ONLY (2026-10-11 design, §2).
  # oomd logs "Would have killed …" but kills nothing. Kill mode is a
  # separate decision based on those logs: its pgscan-based victim choice
  # likely points at file-cache holders (the serves, tmux panes) once the
  # slice's swap is exhausted, and ManagedOOMPreference is ignored on the
  # /user.slice path (owner mismatch). See the design doc.
  systemd.oomd.enableUserSlices = true;
  systemd.services.systemd-oomd.serviceConfig.ExecStart = [
    ""  # clear the upstream ExecStart
    "${config.systemd.package}/lib/systemd/systemd-oomd --dry-run"
  ];
```

(Use `config.systemd.package` so the path follows the running systemd. The
upstream unit's ExecStart is `…/lib/systemd/systemd-oomd`, checked live.)

**Step 2:** Eval:
`nix eval --json .#nixosConfigurations.devbox.config.systemd.services.systemd-oomd.serviceConfig.ExecStart`
→ `["", "/nix/store/…-systemd-…/lib/systemd/systemd-oomd --dry-run"]`.
Also confirm that `systemd.oomd.enableUserSlices` didn't change the top-level
`systemd.oomd.enable` (it should already be true).

### Task 5: cloudbox user slice MemoryHigh → MemoryMax

**File:** `hosts/cloudbox/configuration.nix:5780-5787`.

**Step 1:** `MemoryHigh = "56G";` → `MemoryMax = "56G";`. Keep
`MemorySwapMax` and `TasksMax`.

**Step 2:** Comment: removes the throttle band. It buys no containment here,
because the serves are in a root-level `opencode.slice` and 56G plus the pool
exceeds the 62 GiB host, so earlyoom fires first. Note that `oc-agent.slice`
(20G Max) is the real agent cap on this host. Pointer to the design doc.

**Step 3:** Do NOT enable oomd on cloudbox. Eval the value as in Task 1.

### Task 6: AGENTS.md recipe

**File:** `assets/opencode/AGENTS.md` (~450-470, "Correct pattern: escape the
cgroup, then detach").

**Step 1:** Add `-p MemoryMax=8G -p MemorySwapMax=0` to the `systemd-run`
example, with an inline `# size this to the job` note.

**Step 2:** Add one sentence after the example: an uncapped `--user` unit lands
in `app.slice`, whose only limit is the whole user slice. On 2026-10-11 one
runaway test job froze devbox for 12 h that way. Cap every background job.

**Step 3:** AGENTS.md has only that one `--user --unit` example (line 461).
Grep `assets/opencode/skills/**` for others and add `-p MemoryMax` only where
a long-running payload is shown. Don't touch `--scope` probes or `true`
payloads. Keep this small.

### Task 7: checks, commit, PR

**Step 1:** `nix flake check --keep-going` (never `--no-build`). On the Mac
it skips `checks.x86_64-linux`/aarch64 builds (`flake.nix:234`), so run it on
devbox from the deploy worktree (or rely on the PR's CI). Expect a pass,
including the pipefail and front-door guards.

**Step 2:** Commit (bare `git commit`; one commit per task is fine), push,
load `shepherding-pull-requests`, open the PR. In the body, link the design
and say that devbox is deployed from the branch for verification before
merge.

### Task 8: deploy devbox + drills

**Prereq:** devbox healthy (`uptime` load reasonable, slice
`memory.pressure` some avg60 < 5).

**Step 1:** Deploy as described in the header, then
`nix run home-manager -- switch --flake .#dev` for Task 3.

**Step 2: config checks.**

```bash
cat /sys/fs/cgroup/user.slice/user-1000.slice/memory.{max,high,swap.max}   # 21474836480 / max / 6442450944
for u in opencode-serve@4096 opencode-serve@4097; do cat /proc/$(systemctl --user show -p MainPID --value $u)/oom_score_adj; done  # 200
systemctl cat systemd-oomd | grep ExecStart                               # ... --dry-run
oomctl | sed -n '/Monitored/,$p'                                          # user.slice + user-manager slices listed
```

If any check fails, stop. Do not run the drills.

**Step 3: drill script** (on devbox, `/tmp/oom-drill.py`):

```python
import sys, time
rate_mb = int(sys.argv[1])   # MB/s; 0 = as fast as possible
chunk = 64 * 1024 * 1024
hold = []
while True:
    hold.append(bytearray(chunk))
    for i in range(0, chunk, 4096):
        hold[-1][i] = 1          # touch every page: anon, never freed
    if rate_mb:
        time.sleep(64 / rate_mb)
```

**Step 4: observer, run as ROOT outside the slice.** It must not stall with
the thrash (an observer inside `user-1000.slice` silently skips samples), it
must be bounded (an agent can't run an infinite loop in its bash tool), and
it is the real second guard, because `RuntimeMaxSec` is enforced by
`systemd --user`, which sits inside the thrashing slice.

`/tmp/oom-observer.sh` (args: drill unit name, deadline seconds):

```bash
#!/usr/bin/env bash
set -u
unit=$1; deadline=$2
S=/sys/fs/cgroup/user.slice/user-1000.slice
D="$S/user@1000.service/app.slice/$unit"
log=/tmp/$unit-obs.log; : >"$log"
start=$(date +%s); last=$start
for _ in $(seq 1 $(( (deadline + 60) / 2 ))); do
  now=$(date +%s)
  [ $((now - last)) -le 5 ] || echo "GAP $((now - last))s" >>"$log"
  last=$now
  line="$(date +%T) swapev=$(grep max $S/memory.swap.events | cut -d' ' -f2) swappeak=$(cat $S/memory.swap.peak 2>/dev/null)"
  for p in 4096 4097; do line+=" $(curl -s -m3 -o /dev/null -w "$p:%{http_code}/%{time_total}" http://127.0.0.1:$p/global/health)"; done
  echo "$line" >>"$log"
  if [ $((now - start)) -ge $((deadline + 30)) ] && [ -e "$D/cgroup.kill" ]; then
    echo 1 >"$D/cgroup.kill"; echo "OBSERVER KILLED $unit" >>"$log"
  fi
  [ -d "$D" ] || [ $((now - start)) -lt 10 ] || { echo "unit gone" >>"$log"; break; }
  sleep 2
done
```

**Before/after snapshot** (`/tmp/oom-snap.sh <file>`), read from cgroupfs, root:

```bash
#!/usr/bin/env bash
out=$1; : >"$out"
n=0
for f in /sys/fs/cgroup/user.slice/user-1000.slice/user@1000.service/app.slice/app-opencode\x2dserve.slice/opencode-serve@*.service/memory.events; do
  [ -e "$f" ] || continue; n=$((n+1)); echo "$f $(grep oom_kill "$f")" >>"$out"
done
echo "matched=$n" >>"$out"       # MUST be 2; fix the glob from `systemctl --user status opencode-serve@4096 | grep CGroup` if not
for u in 4096 4097; do echo "pid$u=$(systemctl --user show -p MainPID --value opencode-serve@$u)" >>"$out"; done
```

**Step 5: drill (a), fast.**

```bash
sudo bash /tmp/oom-snap.sh /tmp/drill-a-before.txt; grep -q 'matched=2' /tmp/drill-a-before.txt || exit 1
sudo systemd-run --unit=oom-drill-obs-a --collect bash /tmp/oom-observer.sh oom-drill-a.service 300
t0=$(date '+%F %T')
systemd-run --user --unit=oom-drill-a --collect -p RuntimeMaxSec=300 /run/current-system/sw/bin/python3 /tmp/oom-drill.py 0
```

(No per-unit MemoryMax, on purpose: the slice cap must be what fires.) Wait
for `/tmp/oom-drill-a.service-obs.log` to show `unit gone`, then
`sudo bash /tmp/oom-snap.sh /tmp/drill-a-after.txt`.

**Step 6: drill (b), slow (50 MB/s).** Compute the deadline first:
`headroom_mb = (20480 + 6144) - (current slice anon MB)`, read from
`memory.stat` anon (+ swap.current) of the slice; `deadline = headroom_mb/50 + 300`.
Same commands as (a), with names `-b` and that deadline (unit
`-p RuntimeMaxSec=$deadline`, observer arg `$deadline`).

**Step 7: evaluate.**

Drill (a) passes only if ALL of the following hold:
- **no other kill:**
  - `diff` of before/after shows the same serve `oom_kill` counts and pids;
  - `journalctl -k --since "$t0" | grep -iE 'oom-kill|Killed process'` names only the drill;
  - `journalctl -u earlyoom --since "$t0" | grep -i sending` is empty;
- **swap exercised:** `swapev` rose during the drill (the slice's `memory.swap.events max` delta > 0);
- **serves stayed responsive:** no `GAP` line, and every probe is `200` with time < 3 s;
- **fast:** the drill unit died within 2 min (first `unit gone` line, relative to `t0`).

Drill (b) FAILS only if something other than the drill was killed (the
same three checks). Record without judging: how it ended (kernel kill with
the time taken, `RuntimeMaxSec`, or the observer's kill) and the worst
health latency.

For both drills, collect oomd's dry-run verdicts:
`journalctl -u systemd-oomd --since "$t0" | grep -i "would have"`.

**Step 8:** If a serve or any other unit was killed in either drill: STOP,
revert, and report to the owner. Revert = `nixos-rebuild switch` from
`origin/main` + `home-manager switch` from it +
`systemctl --user restart opencode-serve-pool.target` (adj only changes at
process start) + `systemctl --user start pull-workstation.timer`.

**Step 9:** Post the results (pass/fail per criterion, times, oomd would-kill
lines) as a PR comment, and record them in the design doc's Verification
section as "Measured 2026-10-xx". Commit and push.

### Task 9: beads for follow-ups

`bd create` in the workstation repo (load the `beads` skill):
1. D: port oc-scoped-shell to devbox, then serve `OOMScoreAdjust=0`.
2. oomd kill-mode decision: review a week of devbox dry-run logs
   (`journalctl -u systemd-oomd | grep -i would`); criteria in design §2.
3. healthchecks.io is blind to a starved-but-alive devbox.
4. cloudbox deploy of Task 5 after a day of devbox soak (if the owner wants an
   agent to do it).

Put the bead ids in the PR body.

---

## Don'ts
- Don't drill on cloudbox.
- Don't enable oomd kill mode.
- Don't run a drill unless Task 8 Step 2 passed (a missing `memory.max`
  recreates the 12 h wedge; `RuntimeMaxSec` is the only other guard).
- Never `gh pr merge`.
