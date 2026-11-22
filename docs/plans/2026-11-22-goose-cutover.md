# goose-cutover (L3a, bead workstation-6w7i.27.3)

The only path by which a goose pin PR (workstation, label `goose-upgrade`)
reaches the running goose on cloudbox. Runbook: epic workstation-6w7i.27 design
section 6. Research facts with file:line evidence: bead workstation-6w7i.27.3
notes ("W3 research for L3a"). Depends on L6 (`/var/lib/goose/current`,
`goose-link`, PR #902) and L2 (`goose-upgrade-probe <bin> [--old-bin <bin>]`,
exit 0 iff every check passes; bead .27.1, worktree .worktrees/goose-upgrade-probe).

## Shape

- `pkgs/goose-cutover/goose_cutover.py`: Python 3 stdlib only. All side effects
  go through one `Runner` object (run a command, read a file, sleep, now) so the
  unit tests (`test_goose_cutover.py`, unittest) drive every path with fakes.
- `pkgs/goose-cutover/default.nix`: wraps it (`goose-cutover` on PATH) with
  runtime inputs: python3, gh, git, nix, curl, util-linux (flock, runuser),
  systemd, goose-link (pkgs/goose-link). `goose-upgrade-probe` and `honk` are
  resolved by absolute path from env with defaults
  (`GOOSE_UPGRADE_PROBE`, default `/home/dev/.nix-profile/bin/goose-upgrade-probe`;
  `HONK_BIN`, default `/home/dev/.nix-profile/bin/honk`); missing = hard fail.
- `modules/goose-cutover.nix` (cloudbox only, imported from flake modules list):
  `systemd.services."goose-cutover@"` template: root, `Type=oneshot`,
  `ExecStart=goose-cutover --run %i`, `TimeoutStartSec=4h`, `PrivateTmp=false`,
  **`restartIfChanged=false` and `stopIfChanged=false`** (the unit runs
  `nixos-rebuild switch` itself; a changed unit would otherwise be restarted
  mid-cutover and kill its own run), `StateDirectory=goose-cutover`,
  `Environment=PATH` incl. `/run/wrappers` and `/run/current-system/sw/bin`.
  Installs `goose-cutover` in `environment.systemPackages`.

## CLI

    goose-cutover <pr> [--dry-run] [--allow-noop]     # launcher (human/opencode shell)
    goose-cutover --run <instance>                    # inside the unit only

Launcher: refuse (exit 2) if `/proc/self/cgroup` contains `goose-serve` (a goose
tool shell lives in goose-serve's cgroup; the restart would kill the caller).
Then `sudo systemctl start --no-block goose-cutover@<instance>.service`, where
instance is `<pr>`, `dry-<pr>`, `noop-<pr>` or `dry-noop-<pr>`; print the
`journalctl -fu` line. `--run` refuses unless `$INVOCATION_ID` is set and
`/proc/self/cgroup` names `goose-cutover@`.

Every log line is `goose-cutover: <step>: <message>` on stdout (journal).

## Run steps

Each step is a function; failure raises `CutoverError(step, detail)`.
`dry-` runs steps 1-4 for real (all read-only to production) and prints what
5-12 would do, then exits 0 if 1-4 passed.

1. **Preconditions.** hostname is `cloudbox`; `goose-link status` exits 0;
   PR (via `gh pr view <pr> --repo johnnymo87/workstation --json
   state,baseRefName,labels,headRefOid,files,statusCheckRollup,mergeable`) is
   OPEN, base `main`, labelled `goose-upgrade`, touches `pkgs/goose/default.nix`,
   every status check SUCCESS/NEUTRAL/SKIPPED (none pending/failed), mergeable
   not CONFLICTING; if labelled `goose-major`, also `goose-major-ok`.
   GH auth: `GH_TOKEN` from `/run/secrets/github_api_token`. All git/gh/nix
   build/probe/honk/HM commands run as dev: `runuser -u dev -- env HOME=/home/dev
   XDG_RUNTIME_DIR=/run/user/1000 GH_TOKEN=... <cmd>`.
2. **Candidate.** As dev: `git -C /home/dev/projects/workstation fetch origin`,
   throwaway `git worktree add --detach <tmp> <headRefOid>`; `nix build --no-link
   --print-out-paths '<tmp>#nixosConfigurations.cloudbox.config.environment.etc."goose/pinned".source'`
   = candidate store path. If candidate == current link target: fail unless
   `noop-` (the no-op pin test path). Remove the worktree in a `finally`.
3. **Probe.** As dev: `goose-upgrade-probe <cand>/bin/goose --old-bin
   /var/lib/goose/current/bin/goose`; non-zero = fail (log its last 40 lines).
4. **Quiet window.** Poll every 30 s, give up after 2 h (fail `quiet-window`).
   Quiet = all three, evaluated together:
   - latest stall-watch tick JSON line (root: `journalctl _SYSTEMD_USER_UNIT=stall-watch.service
     _UID=1000 --since -15min -o cat`, last line starting `{"ts"`) has
     `coordinator.runs == 0`; no such line in 15 min = not quiet;
   - `select max(id) from messages` in sessions.db (sqlite3, `file:...?mode=ro`)
     unchanged for >= 10 min of observation (the script's own observation clock;
     the window starts when first observed);
   - no PID under `/sys/fs/cgroup/system.slice/goose-serve.service` (any
     `cgroup.procs`, recursive) has `/proc/<pid>/oom_score_adj >= 500`.
   Dry-run: one evaluation, report each condition, do not wait.
5. **Lock.** Open `/tmp/reset-workspace.lock` READ-ONLY (never O_CREAT: dev-owned
   file in sticky /tmp, protected_regular) and `flock -n`; if held, keep polling
   inside the quiet-window deadline. Held from here through step 11; re-check
   the quiet window once immediately after taking it. If the file is absent,
   create it as dev (`runuser -u dev -- touch`) first.
6. **Backup.** sqlite3 online backup (python `sqlite3.Connection.backup`) of
   sessions.db to `/var/lib/goose-cutover/backups/sessions-<UTC ts>-pr<pr>.db`;
   keep the newest 5. Record rollback state in `/var/lib/goose-cutover/run.json`:
   old link target, old system generation (`readlink -f
   /nix/var/nix/profiles/system`), PR, candidate.
7. **Merge.** As dev: `gh pr merge <pr> --squash --match-head-commit <headRefOid>`;
   poll `gh pr view --json state,mergeCommit` until MERGED (5 min). Fetch, new
   throwaway detached worktree at the merge commit's `origin/main` descendant
   (`origin/main` after fetch; it must contain the merge commit); rebuild the
   pinned path there and require == candidate (else fail `merged-pin-mismatch`:
   link not yet moved, so production is unchanged).
8. **Switch.** `nixos-rebuild switch --flake <wt>#cloudbox` (root), then as dev
   `nix run github:nix-community/home-manager/release-25.11 -- switch --flake <wt>#cloudbox`.
9. **Flip.** `goose-link pinned`; then require `goose-link status` current ==
   candidate.
10. **Restart.** Record goose-serve `ExecMainStartTimestampMonotonic`;
    `systemctl restart goose-serve`; poll `curl -sf http://127.0.0.1:4080/status`
    60 s; timestamp must have increased; `/proc/<MainPID>/cmdline` argv0 ==
    `/var/lib/goose/current/bin/goose` and `readlink /proc/<MainPID>/exe` ==
    `<cand>/bin/goose`; ACP initialize (`POST :4080/acp`, header `x-secret-key`
    from `/run/secrets/pigeon_goose_acp_token`) `result.agentInfo.version` ==
    the candidate's upstream version (pkg version before `-patched`).
    honkd (dev user unit, keep-old): if its `ExecStart` path differs from
    `/proc/<MainPID>/exe`, restart it. Either way wait up to 30 s for
    `Upstream control connection re-initialized successfully` in its journal
    since the goose restart.
11. **Post-checks.** (a) force one stall-watch tick as dev (`systemctl --user
    start stall-watch.service`, blocks) and require its JSON line `ok == true`;
    (b) honk headless: `honk launch --tag auto --no-attach --title goose-cutover-probe
    /tmp 'Reply with exactly: PONG'`, parse `native=<id>`, then `timeout 300 honk
    tail --text-only --exit-on-turn-end <id>` output contains `PONG`.
    Release the lock.
12. **Success.** Write `/var/lib/goose-cutover/deployed.json` {pr, store_path,
    version, merged_sha, ts} (L7 reads it); notify via opencode-drift-alert
    (signature `goose-cutover:<pr>:<sha>:ok`): "goose-cutover: PR #<pr> live:
    <old> -> <new>".

**Failure handling.** Steps 1-7 failing: nothing in production moved (a merge
without a switch is still a no-op for the running goose, thanks to L6); notify
error and exit 1. A failure in 8-11 runs **rollback**: `goose-link rollback`
(only if step 9 flipped), restart goose-serve (only if 10 started) and honkd
(only if restarted), verify `/status` and argv0/exe == old target; then open the
revert PR as dev (worktree at origin/main, `git revert --no-edit <merge sha>`,
push `goose-cutover-revert-<pr>`, `gh pr create --label goose-upgrade` with the
failing step in the body); notify error with the step, detail and revert PR URL.
It does NOT roll back system/HM generations: pull-workstation re-applies main;
the revert PR is what restores pin-gated config. A rollback failure notifies
"ROLLBACK FAILED, goose-serve state unknown" and exits 3.

Always: release the lock, remove throwaway worktrees.

## Tests (unittest, `python3 pkgs/goose-cutover/test_goose_cutover.py`)

Fake `Runner` records commands and returns scripted results. Cover at least:
launcher refuses inside goose-serve cgroup; `--run` refuses outside a unit;
each precondition failing (label, base, checks pending/failed, major without
ok, file not touched); candidate == current refused without noop, allowed with;
probe failure stops before quiet window; quiet window: each of the three
conditions individually blocks, all three pass after 10 min of unchanged max(id),
deadline gives up; lock taken read-only and re-check; merged-pin mismatch fails
without flip; failure at switch/flip/restart/post-check each triggers the right
subset of rollback actions and the revert PR; dry-run performs no mutating
command (assert no merge/switch/goose-link set/systemctl restart in the log);
success writes deployed.json and notifies once. Gate in flake.nix like
astra-probe-tests (pinned "Ran N tests" + "OK").
