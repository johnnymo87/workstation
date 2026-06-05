# reset-workspace: tear down `lgtm` tmux session + exclude from morning recommendations

> **For Claude:** This is an APPROVED design + implementation plan. Implement it in `pkgs/reset-workspace/default.nix`. Follow TDD-ish discipline: build for shellcheck, unit-test the core logic standalone, then review.

**Goal:** Make the nightly `reset-workspace` explicitly tear down the dedicated `lgtm` tmux session AND exclude lgtm's `opencode attach` sessions from the morning recommendation manifest.

**Status:** Approved by user 2026-06-04. Not yet implemented.

## Background / why

The `lgtm` tmux session is the junk drawer that lgtm's launches land in (added earlier this session — see `docs/plans/2026-06-04-lgtm-dedicated-tmux-session-{design,plan}.md`, shipped: workstation `ea5f48a`+`4028cb7`, lgtm `0527d07`). The morning recommendation agent is built solely from the Step 2 snapshot in `reset-workspace`, which `pgrep`s all `opencode attach` processes **before** the nvim kill. lgtm's attach clients live in the `lgtm` session, so they get captured → recommended. The user wants them gone.

## Relevant file / current structure

`pkgs/reset-workspace/default.nix` (bash inside Nix `writeShellApplication`, runs under `set -euo pipefail`). Key landmarks (line numbers approximate, re-read before editing):
- Top helpers: `log()` (~line 29), `die()` (~line 33).
- The destructive re-exec dance (systemd-run scope + flock) runs first (~lines 38-106).
- **Step 2 snapshot** starts ~line 110. Builds `OPENCODE_MANIFEST`.
  - **Strict loop** (~137-161): `OC_ATTACH_PIDS=$(pgrep -u dev -f 'opencode attach')`; `for pid in $OC_ATTACH_PIDS; do … done`. Each matched pid → append sid to `OPENCODE_MANIFEST`.
  - **Bare loop** (~168-204): `OC_ALL_PIDS=$(pgrep -u dev -f opencode)`; resolves bare TUIs to sids. (lgtm attach has `--session` so it lands in the strict loop, not here — but filter both defensively.)
- Step 3 kills all nvims (`pkill -9 -u dev -x nvim`, ~239). Step 5 restarts opencode-serve. Step 6 writes `/tmp/reset-workspace-last-manifest.txt` and launches the recommendation session.

Nix escaping: bash `${var}` must be written `''${var}` in the file (e.g. existing `''${BASH_REMATCH[2]}`).

## Implementation

### Edit A — add a top-level helper near `log`/`die`
A recursive subtree collector (define once, top-level, for shellcheck cleanliness):
```bash
    # Print a pid and all of its descendant pids, one per line. Used to
    # attribute `opencode attach` processes to the lgtm tmux session BEFORE we
    # kill it (after the kill, children reparent to init and become
    # unattributable).
    collect_subtree() {
      local root="$1" child
      printf '%s\n' "$root"
      for child in $(pgrep -P "$root" 2>/dev/null || true); do
        collect_subtree "$child"
      done
    }
```

### Edit B — teardown + pid-capture, inserted BEFORE the Step 2 snapshot (before the `log "snapshotting…"` at ~line 118)
```bash
    # ---- Step 1.5: Tear down the lgtm junk-drawer tmux session ----
    # lgtm confines its OpenCode launches to a tmux session literally named
    # `lgtm` (see lgtm src/dispatch.ts LGTM_TMUX_SESSION + workstation
    # oc-auto-attach --tmux-session). Those review sessions are noise in the
    # morning recommendations, so we capture their attach-client PIDs (whole
    # process subtree of each pane, while the tree is still intact), exclude
    # them from the snapshot below, then kill the session outright. `=lgtm`
    # is an exact-match so a session named e.g. `lgtm-foo` is untouched.
    LGTM_PIDS=" "
    if tmux has-session -t '=lgtm' 2>/dev/null; then
      while read -r pane_pid; do
        [ -n "$pane_pid" ] || continue
        while read -r d; do
          LGTM_PIDS="''${LGTM_PIDS}''${d} "
        done < <(collect_subtree "$pane_pid")
      done < <(tmux list-panes -s -t '=lgtm' -F '#{pane_pid}' 2>/dev/null || true)
      log "tearing down lgtm tmux session (excluding its sessions from recommendations); pids:$LGTM_PIDS"
      tmux kill-session -t '=lgtm' 2>/dev/null || true
    fi
```
(`tmux` is already in `runtimeInputs`. Note `LGTM_PIDS` starts and stays space-padded for safe substring membership tests.)

### Edit C — filter both snapshot loops
In the **strict loop**, right after `for pid in $OC_ATTACH_PIDS; do` (before the exe filter), add:
```bash
      case "$LGTM_PIDS" in *" $pid "*) log "  skipping pid=$pid (lgtm junk-drawer session)"; continue ;; esac
```
In the **bare loop**, right after `for pid in $OC_ALL_PIDS; do`, add the same guard (message can say `(lgtm junk-drawer session)` too).

## Verification (reset-workspace is DESTRUCTIVE — do NOT run it end-to-end)

1. **Build / shellcheck:** `cd ~/projects/workstation && nix build .#reset-workspace --no-link` — must pass.
2. **Standalone logic test** (no reset): extract `collect_subtree` + the `case … *" $pid "*` membership check into a throwaway script in `/tmp`. Spawn a synthetic tree (`sleep 300 & ; ( sleep 300 & )` etc., or a parent that backgrounds children), run `collect_subtree <parent>`, assert it lists parent + all descendants; assert the membership test includes a descendant pid and excludes an unrelated pid. Clean up the sleeps.
3. **tmux enumeration test** (non-destructive): `tmux new-session -d -s lgtm 'sleep 600'` (or with a child), confirm `tmux list-panes -s -t '=lgtm' -F '#{pane_pid}'` returns the pane pid and `collect_subtree` on it includes the child; confirm `tmux has-session -t '=lgtm'` true; then `tmux kill-session -t '=lgtm'` and confirm gone. Make sure NOT to disturb the user's `main` session.
4. **Deploy:** `nix run home-manager -- switch --flake .#cloudbox` (reset-workspace is a home/system pkg — confirm which; it's referenced in cloudbox config / home). Verify `reset-workspace --help` still works.

## Review flow
Same as prior tasks: spec-reviewer (subagent) then code-reviewer (subagent). Then land the plane: commit + push workstation (`git push`, confirm `## main...origin/main`).

## Gotchas learned this session
- Subagent dispatches occasionally return EMPTY — if so, verify repo state directly and re-dispatch.
- A prior implementer subagent pushed to origin without being asked; if delegating, tell it commit-only and the orchestrator pushes.
- `reset-workspace` is NOT a long-running daemon; lgtm itself runs via `tsx` against live source on a 10-min systemd timer (`lgtm-run.timer`), so lgtm-side changes need no build/restart.
- The default tmux socket is shared between the user's interactive tmux and daemon-spawned tools.
