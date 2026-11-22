# goose-cutover (L3a, bead workstation-6w7i.27.3) — plan v2

The only path by which a goose pin PR (workstation, label `goose-upgrade`)
reaches the running goose on cloudbox. Runbook: epic workstation-6w7i.27 design
section 6. Researched facts with file:line evidence: bead .27.3 notes ("W3
research for L3a"). v1 was reviewed by adversarial-reviewer-opus 2026-11-22;
this v2 folds in its fixes (summary in the bead notes).

Depends on L6 (merged, #902: `/var/lib/goose/current`, `goose-link`,
`/etc/goose/pinned`) and L2 (`goose-upgrade-probe <bin> [--old-bin <bin>]`,
exit 0 iff all pass; bead .27.1).

## Shape: two phases, one state file

    goose-cutover prepare <pr> [--dry-run] [--allow-noop]
    goose-cutover deploy  [--dry-run]
    goose-cutover status
    goose-cutover --run <phase>-<instance>      # inside the unit only

- **prepare** (no lock, no restart): preconditions, build candidate from the
  PR's merge ref, probe, merge, build candidate + system toplevel + HM activation
  package from `origin/main`, verify candidate matches probed path, persist. Afterwards
  the pin is merged but NOT deployed: on cloudbox nothing moved (L6), which is the
  same state a rollback leaves.
- **deploy** (idempotent, resumable from the state file): quiet window, locks,
  pause stall-watch (timer + path), dry-activate gate, activate the PREBUILT system and HM,
  `goose-link set <cand>`, restart, post-checks, restore. Failures before D5
  (lock busy, quiet timeout, D4 gate refusal, backup failure) exit 0 with a warning
  and leave `phase=prepared` (no rollback); failures from D5 on run rollback while
  holding the lock.
- State: `/var/lib/goose-cutover/state.json` =
  `{phase: prepared|deploying|deployed|rolled-back|failed, pr, head_sha,
  merge_sha, built_from, old_target, candidate, toplevel, hm_package, old_system,
  started_at, step}`.
  `merge_sha` is the PR's squash commit SHA from GitHub (`mergeCommit.oid`), never
  overwritten. `built_from` is the `origin/main` SHA the system and candidate paths
  were built at (updated by D3 reconcile when main moves). Revert and `deployed.json`
  always use `merge_sha`. deploy refuses to start if `phase=deploying` from an
  earlier run (crashed mid-deploy) unless `--recover`, which runs the rollback.
  P1 and D1 refuse if `phase=failed` (requires `--recover`, `--resume-merged` or human).
- Global `flock -n /var/lib/goose-cutover/run.lock` for both phases: one
  cutover at a time. The launcher verifies this with `flock -n run.lock true`
  before calling `systemctl start`, refusing with exit 2 if busy.
- Notifications: `pkgs/opencode-drift-alert/default.nix` accepts 5 positional arguments
  (`STATE_FILE SIGNATURE TEXT [TTL_SECONDS [MAX_INTERVAL]]`) and derives severity
  internally (warning -> error after 3 alerts); it does not accept a severity flag.
  Notification severity levels (info, warning, error) are therefore embedded in the
  alert text (`[LEVEL] ...`) and signature.
- Exit codes:
  - 0: success, dry-run, or clean "not now" refusal (quiet-window 2h give-up, pre-D5 refusal);
  - 1: failure during deploy post-D5 (rolled back), merged-mismatch in D3, or fatal execution error;
  - 2: invocation/cgroup guard refusal, run.lock busy at launch, or CLI usage error;
  - 3: rollback failure (goose-serve in unknown state).

Implementation: `pkgs/goose-cutover/goose_cutover.py`, Python 3 stdlib; every
side effect through one injectable `Runner` (run, read_file, write_file, now,
sleep, flock) with `cwd` parameter so `test_goose_cutover.py` (strict unittest)
drives every path with fakes. `default.nix` wraps it with runtime inputs
(python3, gh, git, nix, curl, jq, util-linux, systemd, sqlite, openssh, goose-link)
and `GOOSE_CUTOVER_ALERT=${driftAlert}`. `goose-upgrade-probe` and `honk` by absolute
path from env (`GOOSE_UPGRADE_PROBE`, `HONK_BIN`; defaults in
`/home/dev/.nix-profile/bin`); missing = hard fail at P1. Every nix build uses an
explicit flake ref `<worktree-path>#...`, every git command uses `git -C <path>`,
and gh commands use `-R johnnymo87/workstation`. Hostname is read from
`/proc/sys/kernel/hostname`.

Unit (`modules/goose-cutover.nix`, cloudbox only):
`systemd.services."goose-cutover@"`: root oneshot, `ExecStart=goose-cutover
--run %i`, **`restartIfChanged=false`, `stopIfChanged=false`** (deploy activates
a system config itself), `PrivateTmp=false`, `TimeoutStartSec=5h`,
`TimeoutStopSec=15min`, `MemoryMax=16G` (the probe builds/runs things; it peaked above 8G),
`WorkingDirectory=/var/lib/goose-cutover`, `StateDirectory=goose-cutover`,
`ExecStopPost=runuser -u dev -- env XDG_RUNTIME_DIR=/run/user/1000 systemctl --user start stall-watch.timer stall-watch-wake.path`
(restores stall-watch even on SIGKILL), `OnFailure=goose-cutover-failed.service`
(one notify via opencode-drift-alert: "goose-cutover@%i died; state.json phase=...,
goose-serve may need `goose-cutover deploy --recover`"). The script traps SIGTERM:
inside deploy steps D5-D8 it runs the rollback before exiting; before D5 it restores
stall-watch, keeps `phase=prepared`, and exits 0.

The launcher (`prepare`/`deploy` without `--run`) refuses (exit 2) if
`/proc/self/cgroup` contains `goose-serve`, then `sudo systemctl start
--no-block goose-cutover@<phase>-<instance>.service` (instance encodes pr and
flags, e.g. `prepare-902`, `prepare-dry-noop-902`, `deploy-1`) and prints the
`journalctl -fu` line. `--run` refuses unless `$INVOCATION_ID` is set and
`/proc/self/cgroup` names `goose-cutover@`.

Commands that need dev's identity run as `runuser -u dev -- env HOME=/home/dev
XDG_RUNTIME_DIR=/run/user/1000 GH_TOKEN=<from /run/secrets/github_api_token>`.
Log lines: `goose-cutover: <step>: <msg>`.

## prepare <pr>

P1. **Preconditions.** hostname `cloudbox` (read from
    `/proc/sys/kernel/hostname`); `goose-link status` exit 0; no state.json in
    `prepared`/`deploying`/`failed`; PR (`gh pr view -R johnnymo87/workstation --json
    state,baseRefName,labels,headRefOid,files,statusCheckRollup,mergeable`):
    OPEN, base `main`, label `goose-upgrade`, non-empty `statusCheckRollup` with every check
    SUCCESS/NEUTRAL/SKIPPED, not CONFLICTING;
    - labelled `goose-major` => also `goose-major-ok`;
    - **files changed only `pkgs/goose/**`** unless labelled `goose-config-ok`
      (a rollback then runs the old binary under the new config; the probe did
      not test that combination);
    - **hosts-ready check** (mechanical, no human label; W1's ask): every
      goose host's link exists and devbox and the Mac run the consumer
      versions the candidate needs (honk/honkd A6-capable, comparing
      `honk_version >= GOOSE_MIN_HONK_VERSION` if set). cloudbox is read
      locally; devbox and the Mac are read from a per-host report
      (`goose-link status` + consumer versions) published on a channel
      cloudbox can read (bead workstation-6w7i.27.12). A missing or stale
      report (> 26 h) fails closed with `hosts-not-ready: <host>`. When the
      check passes, the script applies label `goose-hosts-ready` to the PR as
      a record (skipped in `--dry-run`). The only human-applied label is `goose-major-ok`.
      Why: a merge moves devbox's CLI (fallback to the pin while it has no
      link) and schedules an unprobed Mac restart on its next home-switch.
P2. **Candidate.** As dev: fetch with explicit refspec
    `git -C ~/projects/workstation fetch origin +refs/pull/<pr>/merge:refs/remotes/origin/pr/<pr>/merge +refs/heads/main:refs/remotes/origin/main`;
    require the merge ref's first parent == current `origin/main` (else fail
    `stale-merge-ref`: GitHub has not recomputed it; rerun later). Throwaway
    detached worktree at `refs/remotes/origin/pr/<pr>/merge`. Build ONLY the candidate goose:
    `<wt>#nixosConfigurations.cloudbox.config.environment.etc."goose/pinned".source`
    with out-link `/var/lib/goose-cutover/gcroots/candidate-<pr>` (for the probe).
    candidate == current link target => fail unless `--allow-noop`.
P3. **Probe.** As dev: `goose-upgrade-probe <cand>/bin/goose --old-bin
    /var/lib/goose/current/bin/goose`; non-zero = fail (log last 40 lines).
P4. **Merge & Build from origin/main** (skipped by `--dry-run`). `gh pr merge <pr>
    -R johnnymo87/workstation --squash --match-head-commit <head>`; poll until MERGED (5 min).
    Record `merge_sha` from `gh pr view <pr> -R johnnymo87/workstation --json mergeCommit -q .mergeCommit.oid`.
    Fetch `origin/main`; throwaway worktree at `origin/main`. Record `built_from = origin/main`.
    Build candidate + toplevel + HM activation package from that worktree:
    `<wt_main>#nixosConfigurations.cloudbox.config.environment.etc."goose/pinned".source`
    (`--out-link /var/lib/goose-cutover/gcroots/candidate-<pr>`),
    `<wt_main>#nixosConfigurations.cloudbox.config.system.build.toplevel`
    (`--out-link /var/lib/goose-cutover/gcroots/toplevel-<pr>`),
    `<wt_main>#homeConfigurations.cloudbox.activationPackage`
    (`--out-link /var/lib/goose-cutover/gcroots/hm-<pr>`).
    Require that the candidate store path built from `origin/main` == the probed path from P2;
    a mismatch => phase `failed`, step `merged-mismatch`, nothing deployed (needs re-probe;
    `prepare --resume-merged <pr>`: for a MERGED PR with step=merged-mismatch, re-runs probe on
    origin/main's candidate and builds/persists without calling merge).
P5. Write state.json `phase=prepared` with all paths, `merge_sha` and `built_from`; notify (info):
    "goose-cutover: PR #<pr> merged and prepared; deploy pending".

## deploy

D1. **Load.** Load state.json, require `phase=prepared` (or `--recover`, below).
    Refuse if `phase=failed` (unless `--recover`). Re-verify the GC-rooted paths exist.
D2. **Quiet window** (poll 30 s; give up after 2 h => stays `prepared`, notify warning,
    exit 0; deploy is resumable). Quiet = all at once:
    - latest stall-watch JSON tick line (root: `journalctl
      _SYSTEMD_USER_UNIT=stall-watch.service _UID=1000 --since -15min -o cat`,
      last line starting `{"ts"`) has `coordinator.runs == 0` (missing tick line = not quiet),
      and `stall-watch.service` status is not `active|activating|reloading`;
    - sessions.db `select max(id) from messages` (sqlite `mode=ro`) unchanged
      for >= 10 min of this run's observation;
    - no PID under `/sys/fs/cgroup/system.slice/goose-serve.service`
      (recursive `cgroup.procs`) with `oom_score_adj >= 500`;
    - `honk list --json` (via HONK_BIN as dev) shows no session running a turn or with
      pending requests (field names: read honk's list output; if the shape is
      unknown, treat as not quiet and log it).
    Refuse to proceed past D2 with less than 60 min left of `TimeoutStartSec` (5h).
D3. **Locks and holds**, in this order, released in `finally` in reverse:
    open `/tmp/reset-workspace.lock` READ-ONLY (never O_CREAT; create it as dev
    if absent) and `flock -n` (busy => back to D2 polling within the 2h budget);
    as dev take `/run/user/1000/pull-workstation.lock` (`flock -n -o ... sh -c 'echo locked; exec sleep infinity'`
    held by child process, readiness check on 'locked');
    as dev stop BOTH `stall-watch.timer` AND `stall-watch-wake.path`
    (`systemctl --user stop stall-watch.timer stall-watch-wake.path`), wait until
    `stall-watch.service` is inactive (max 10 min; timing out is a pre-D5 clean refusal).
    Reconcile main: fetch `origin/main`; if `origin/main` != `built_from`, rebuild candidate +
    top + HM activation package from `origin/main`. If candidate store path differs from
    `candidate`, set `phase=failed, step=merged-mismatch`, notify error, and exit 1 (so
    `prepare --resume-merged <pr>` is the recovery path). If candidate is unchanged, update
    `built_from`, `toplevel`, `hm_package` in `state.json`.
    Re-check D2 once (fails => release, restore, back to D2 polling).
D4. **Gate + backup.** `<toplevel>/bin/switch-to-configuration dry-activate` (parse
    stdout AND stderr); refuse if it would stop/restart any unit outside an allowlist
    (start empty plus units this host restarts harmlessly, e.g. `systemd-tmpfiles-resetup`;
    `lgtm-run`: wait until inactive/failed). sqlite online backup of sessions.db to
    `/var/lib/goose-cutover/backups/sessions-<UTC>-pr<pr>.db` (failure is fatal), keep newest 5.
    Record `old_system=readlink -f /nix/var/nix/profiles/system`.
    *Pre-D5 failure rule:* any failure, timeout, or SIGTERM in D3/D4 resets state to `phase=prepared`,
    releases locks, restores stall-watch (timer + path), notifies warning, and exits 0.
    Immediately before D5: write `phase=deploying`.
D5. **Activate.** `nix-env -p /nix/var/nix/profiles/system --set <toplevel>`
    then `<toplevel>/bin/switch-to-configuration switch`; as dev
    `<hm_package>/activate`. (No re-evaluation: exactly what prepare built.)
D6. **Flip.** `goose-link set <candidate>`; require `goose-link status`
    current == candidate.
D7. **Restart.** Record goose-serve `ExecMainStartTimestampMonotonic`;
    `systemctl restart goose-serve`; poll `curl -sf :4080/status` 60 s; the
    timestamp increased; `/proc/<MainPID>/cmdline` argv0 ==
    `/var/lib/goose/current/bin/goose`; `readlink /proc/<MainPID>/exe` ==
    `<cand>/bin/goose`; ACP initialize (`POST :4080/acp` with `-H @<header_file>`,
    secret never in argv) `result.agentInfo.version` == the candidate's upstream version
    (package version before `-patched`).
    honkd (dev user unit): restart honkd ONLY IF its unit's current ExecStart binary
    (`systemctl --user show -p ExecStart honkd`, parse path=) differs from
    `readlink /proc/<honkd MainPID>/exe` (i.e. HM changed honkd); then wait up to 30 s for
    `listening` in its journal since restart. Otherwise wait up to 30 s for
    `Upstream control connection re-initialized successfully` since the goose restart.
D8. **Post-checks.** (a) honk headless as dev: `honk launch --tag goose-upgrade
    --no-attach --title goose-cutover-probe --model claude-haiku-4-5@20251001
    --effort off /tmp 'Reply with exactly: PONG'`, parse `native=<id>`, poll `honk list --json`
    (≤300 s) until running=false and pendingRequests=0, then `timeout 30 honk tail
    --text-only <id>` (rc 124 ok) contains `PONG`; log session id.
    (b) restart `stall-watch.timer` and `stall-watch-wake.path`, then
    wait (max 10 min) for the first tick JSON line with `ts` (milliseconds epoch)
    after the goose restart; require `ok == true`; log its `coordinator.runs`. Failure here
    triggers rollback.
D9. **Success.** `phase=deployed`; write `/var/lib/goose-cutover/deployed.json`
    {pr, merge_sha, store_path, version, ts} (L7 reads it); notify
    "goose-cutover: PR #<pr> live: <old> -> <new>". Release everything.

**Rollback** (failure in D5-D8, SIGTERM in D5-D8, or `deploy --recover`):
Rollback executes while `/tmp/reset-workspace.lock` is held.
1. `goose-link set <old_target from state.json>` (never `rollback`: it swaps
   with whatever `previous` holds, wrong when the flip was a no-op);
2. set restarted_goose=True before calling restart; if goose-serve was restarted
   (or `--recover`): restart it, poll `/status` up to 60 s, and verify argv0 ==
   /var/lib/goose/current/bin/goose and exe == <old_target>/bin/goose;
   restart honkd if D7 restarted it;
3. system/HM generations are NOT rolled back (pull-workstation re-applies main;
   the revert PR restores pin-gated config);
4. **control check**: run the D8(a) PONG against the old binary. If it also
   fails, the cause is environmental: notify "goose-cutover: rolled back,
   failure looks environmental (<step>: <detail>); pin left merged; rerun
   deploy" with no revert PR, `phase=prepared` (deploy can be retried);
5. otherwise open the revert PR as dev (worktree at origin/main, `git -C <wt> revert
   --no-edit <merge_sha>`, push `goose-cutover-revert-<pr>`, `gh pr create
   -R johnnymo87/workstation --base main --head goose-cutover-revert-<pr> --label goose-revert`,
   body: failing step + redacted detail) with cwd=<revert worktree>.
   `goose-revert` PRs are pin moves back to what is already running: merging one is safe
   and is covered by the standing auto-merge (no `goose-upgrade` label); the next
   switch only rebuilds config. `phase=rolled-back`; notify error with the
   revert PR URL;
6. a rollback step failing: notify "ROLLBACK FAILED at <step>; goose-serve
   state unknown", `phase=failed`, exit 3.
Always restore stall-watch.timer and stall-watch-wake.path and release locks in finally.

## Dry runs

`prepare --dry-run` runs P1-P3 (P3 makes real model turns and runs tool shells
with dev's HOME on a COPY of sessions.db; it changes no production state) and
reports what P4-P5 would do. `deploy --dry-run` runs D1-D2 once without waiting
and D4's dry-activate gate, and reports D3-D9. Neither merges, activates,
flips or restarts. Test against a no-op pin: `prepare --allow-noop` on a PR
that changes only a comment in pkgs/goose (candidate == current).

## Tests (unittest)

Fake Runner; at least: launcher refuses in goose-serve cgroup; `--run` refuses
outside a unit; global lock busy; each P1 precondition (hosts-ready check:
missing/stale/old-consumer report fails closed, pass applies the label; goose-major/ok, goose-config-ok, files, checks
pending/failed, base, state); stale merge ref; noop refused/allowed; probe fail
stops before merge; merged mismatch; dry-run issues no mutating command
(assert none of: gh pr merge, switch-to-configuration switch, nix-env --set,
goose-link set, systemctl restart/stop); quiet window: each signal blocks
alone, all pass after 10 min unchanged max(id), unknown honk shape = not quiet,
2 h give-up keeps `prepared`; D3 order and finally-release incl. timer restore
on failure; dry-activate allowlist refusal; failure at D5/D6/D7/D8 each runs
rollback with set-to-old (never `goose-link rollback`), restarts only what was
restarted; control PONG fail => no revert PR, phase prepared; control pass =>
revert PR with goose-revert label; rollback failure => exit 3; `--recover`
from phase deploying; success writes deployed.json and notifies once. Gate in
flake.nix with a pinned "Ran N tests" + "OK".
