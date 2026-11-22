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

- **prepare** (no lock, no restart): preconditions, build candidate + system
  toplevel + HM activation package from the PR's merge ref, probe, merge,
  rebuild at `origin/main`, verify, persist. Afterwards the pin is merged but
  NOT deployed: on cloudbox nothing moved (L6), which is the same state a
  rollback leaves.
- **deploy** (idempotent, resumable from the state file): quiet window, locks,
  pause stall-watch, dry-activate gate, activate the PREBUILT system and HM,
  `goose-link set <cand>`, restart, post-checks, restore.
- State: `/var/lib/goose-cutover/state.json` =
  `{phase: prepared|deploying|deployed|rolled-back|failed, pr, head_sha,
  merge_sha, old_target, candidate, toplevel, hm_package, old_system,
  started_at, step}`. deploy refuses to start if `phase=deploying` from an
  earlier run (crashed mid-deploy) unless `--recover`, which runs the rollback.
- Global `flock -n /var/lib/goose-cutover/run.lock` for both phases: one
  cutover at a time.

Implementation: `pkgs/goose-cutover/goose_cutover.py`, Python 3 stdlib; every
side effect through one injectable `Runner` (run, read_file, write_file, now,
sleep) so `test_goose_cutover.py` (unittest) drives every path with fakes.
`default.nix` wraps it with runtime inputs (python3, gh, git, nix, curl, jq,
util-linux, systemd, goose-link). `goose-upgrade-probe` and `honk` by absolute
path from env (`GOOSE_UPGRADE_PROBE`, `HONK_BIN`; defaults in
`/home/dev/.nix-profile/bin`); missing = hard fail.

Unit (`modules/goose-cutover.nix`, cloudbox only):
`systemd.services."goose-cutover@"`: root oneshot, `ExecStart=goose-cutover
--run %i`, **`restartIfChanged=false`, `stopIfChanged=false`** (deploy activates
a system config itself), `PrivateTmp=false`, `TimeoutStartSec=5h`,
`MemoryMax=8G` (the probe builds/runs things), `StateDirectory=goose-cutover`,
`OnFailure=goose-cutover-failed.service` (one notify via opencode-drift-alert:
"goose-cutover@%i died; state.json phase=..., goose-serve may need
`goose-cutover deploy --recover`"). The script traps SIGTERM: inside deploy
steps D5-D8 it runs the rollback before exiting.

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

P1. **Preconditions.** hostname `cloudbox`; `goose-link status` exit 0; no
    state.json in `prepared`/`deploying`; PR (`gh pr view --json
    state,baseRefName,labels,headRefOid,files,statusCheckRollup,mergeable`):
    OPEN, base `main`, label `goose-upgrade`, every check
    SUCCESS/NEUTRAL/SKIPPED, not CONFLICTING;
    - labelled `goose-major` => also `goose-major-ok`;
    - **files changed only `pkgs/goose/**`** unless labelled `goose-config-ok`
      (a rollback then runs the old binary under the new config; the probe did
      not test that combination);
    - **hosts-ready check** (mechanical, no human label; W1's ask): every
      goose host's link exists and devbox and the Mac run the consumer
      versions the candidate needs (honk/honkd A6-capable). cloudbox is read
      locally; devbox and the Mac are read from a per-host report
      (`goose-link status` + consumer versions) published on a channel
      cloudbox can read (bead workstation-6w7i.27.12). A missing or stale
      report (> 26 h) fails closed with `hosts-not-ready: <host>`. When the
      check passes, the script applies label `goose-hosts-ready` to the PR as
      a record. The only human-applied label is `goose-major-ok`.
      Why: a merge moves devbox's CLI (fallback to the pin while it has no
      link) and schedules an unprobed Mac restart on its next home-switch.
P2. **Candidate.** As dev: fetch `origin` and `refs/pull/<pr>/merge`; require
    the merge ref's first parent == current `origin/main` (else fail
    `stale-merge-ref`: GitHub has not recomputed it; rerun later). Throwaway
    detached worktree at the merge ref. Build, with out-links under
    `/var/lib/goose-cutover/gcroots/` (GC roots for the hours until deploy):
    `.#nixosConfigurations.cloudbox.config.environment.etc."goose/pinned".source`
    (= candidate), `.#nixosConfigurations.cloudbox.config.system.build.toplevel`,
    `.#homeConfigurations.cloudbox.activationPackage`. candidate == current
    link target => fail unless `--allow-noop`.
P3. **Probe.** As dev: `goose-upgrade-probe <cand>/bin/goose --old-bin
    /var/lib/goose/current/bin/goose`; non-zero = fail (log last 40 lines).
P4. **Merge** (skipped by `--dry-run`). `gh pr merge <pr> --squash
    --match-head-commit <head>`; poll until MERGED (5 min). Fetch; require
    `origin/main` == the merge commit (if main moved past it, rebuild at
    `origin/main` and require all three paths to be identical to P2's; a
    mismatch => phase `failed`, step `merged-mismatch`, nothing deployed;
    `prepare --resume-merged` re-runs P2-P3 at origin/main for a MERGED PR).
P5. Write state.json `phase=prepared` with all paths; notify (info):
    "goose-cutover: PR #<pr> merged and prepared; deploy pending".

## deploy

D1. **Load** state.json, require `phase=prepared` (or `--recover`, below).
    Re-verify the GC-rooted paths exist.
D2. **Quiet window** (poll 30 s; give up after 2 h => stays `prepared`, notify,
    exit 1; deploy is resumable). Quiet = all at once:
    - latest stall-watch JSON tick line (root: `journalctl
      _SYSTEMD_USER_UNIT=stall-watch.service _UID=1000 --since -15min -o cat`,
      last line starting `{"ts"`) has `coordinator.runs == 0`, and
      `stall-watch.service` is not active right now;
    - sessions.db `select max(id) from messages` (sqlite `mode=ro`) unchanged
      for >= 10 min of this run's observation;
    - no PID under `/sys/fs/cgroup/system.slice/goose-serve.service`
      (recursive `cgroup.procs`) with `oom_score_adj >= 500`;
    - `honk list --json` (as dev) shows no session running a turn or with
      pending requests (field names: read honk's list output; if the shape is
      unknown, treat as not quiet and log it).
    Refuse to proceed past D2 with less than 60 min left of `TimeoutStartSec`.
D3. **Locks and holds**, in this order, released in `finally` in reverse:
    open `/tmp/reset-workspace.lock` READ-ONLY (never O_CREAT; create it as dev
    if absent) and `flock -n` (busy => back to D2 polling); as dev take
    `/run/user/1000/pull-workstation.lock` (`flock -n`, held by a child
    process for the duration); as dev `systemctl --user stop
    stall-watch.timer`, wait until `stall-watch.service` is inactive (max 10
    min; a tick in progress means not quiet). Re-check D2 once. Write
    `phase=deploying`.
D4. **Gate + backup.** `<toplevel>/bin/switch-to-configuration dry-activate`;
    refuse if it would stop/restart any unit outside an allowlist (start empty
    plus units this host restarts harmlessly, e.g. `systemd-tmpfiles-resetup`;
    `lgtm-run`: wait until inactive). sqlite online backup of sessions.db to
    `/var/lib/goose-cutover/backups/sessions-<UTC>-pr<pr>.db`, keep newest 5.
    Record `old_system=readlink -f /nix/var/nix/profiles/system`.
D5. **Activate.** `nix-env -p /nix/var/nix/profiles/system --set <toplevel>`
    then `<toplevel>/bin/switch-to-configuration switch`; as dev
    `<hm_package>/activate`. (No re-evaluation: exactly what prepare built.)
D6. **Flip.** `goose-link set <candidate>`; require `goose-link status`
    current == candidate.
D7. **Restart.** Record goose-serve `ExecMainStartTimestampMonotonic`;
    `systemctl restart goose-serve`; poll `curl -sf :4080/status` 60 s; the
    timestamp increased; `/proc/<MainPID>/cmdline` argv0 ==
    `/var/lib/goose/current/bin/goose`; `readlink /proc/<MainPID>/exe` ==
    `<cand>/bin/goose`; ACP initialize (`POST :4080/acp`, `x-secret-key` from
    `/run/secrets/pigeon_goose_acp_token`) `result.agentInfo.version` == the
    candidate's upstream version (package version before `-patched`).
    honkd (dev user unit, keep-old): if its `ExecStart` path differs from
    `/proc/<MainPID>/exe`, restart it and wait for `listening` in its journal;
    otherwise wait 30 s for `Upstream control connection re-initialized
    successfully` since the goose restart.
D8. **Post-checks.** (a) honk headless as dev: `honk launch --tag goose-upgrade
    --no-attach --title goose-cutover-probe --model claude-haiku-4-5@20251001
    --effort off /tmp 'Reply with exactly: PONG'` (check the flags exist on
    this honk; drop any that do not), parse `native=<id>`, then `timeout 300
    honk tail --text-only --exit-on-turn-end <id>` contains `PONG`; archive or
    delete the session if honk can. (b) restart `stall-watch.timer`, then
    wait (max 10 min) for the first tick JSON line with `ts` after the goose
    restart; require `ok == true`; log its `coordinator.runs` (it may be 0:
    report, do not claim coordinator coverage).
D9. **Success.** `phase=deployed`; write `/var/lib/goose-cutover/deployed.json`
    {pr, merge_sha, store_path, version, ts} (L7 reads it); notify
    "goose-cutover: PR #<pr> live: <old> -> <new>". Release everything.

**Rollback** (failure in D5-D8, SIGTERM in D5-D8, or `deploy --recover`):
1. `goose-link set <old_target from state.json>` (never `rollback`: it swaps
   with whatever `previous` holds, wrong when the flip was a no-op);
2. if goose-serve was restarted (or `--recover`): restart it and verify
   `/status` + argv0/exe == old target; restart honkd if D7 restarted it;
3. system/HM generations are NOT rolled back (pull-workstation re-applies main;
   the revert PR restores pin-gated config);
4. **control check**: run the D8(a) PONG against the old binary. If it also
   fails, the cause is environmental: notify "goose-cutover: rolled back,
   failure looks environmental (<step>: <detail>); pin left merged; rerun
   deploy" with no revert PR, `phase=prepared` (deploy can be retried);
5. otherwise open the revert PR as dev (worktree at origin/main, `git revert
   --no-edit <merge_sha>`, push `goose-cutover-revert-<pr>`, `gh pr create
   --label goose-revert`, body: failing step + detail). `goose-revert` PRs are
   pin moves back to what is already running: merging one is safe and is
   covered by the standing auto-merge (no `goose-upgrade` label); the next
   switch only rebuilds config. `phase=rolled-back`; notify error with the
   revert PR URL;
6. a rollback step failing: notify "ROLLBACK FAILED at <step>; goose-serve
   state unknown", `phase=failed`, exit 3.
Always restore stall-watch.timer and release locks.

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
