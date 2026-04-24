# reset-workspace: a single command for full workspace reset

**Status:** design
**Date:** 2026-04-24
**Author:** Claude (claude-opus-4-7) with Jonathan
**Predecessor:** `2026-04-22-launch-auto-attach-design.md` (the auto-attach feature this complements)

## Problem

After landing the launch auto-attach feature, the auto-attach plumbing requires every nvim to be started as `nvims` (the wrapper that gives each nvim a deterministic `/tmp/nvim-${PANE#%}.sock` socket). The 5 existing nvims on cloudbox were all started as bare `nvim`, so they have no socket, so auto-attach matches them by `pane_current_path` but then times out cleanly on the readiness probe.

The "fix" today is manual: `:qa` in each tmux window, then `nvims`. That's tolerable once but annoying to do regularly. It also doesn't help for related cleanup (stale opencode sessions, leaky opencode-serve).

Separately, cloudbox has a `nightly-restart-background` systemd timer that restarts `opencode-serve` at 3 AM nightly — purely to reclaim memory (serve leaks from ~350 MB to 8–13 GB over days). This is unrelated to nvim, but it's the same machinery: "restart something at 3 AM to reset state."

We can collapse both problems into one command: `reset-workspace`. It tears down nvims and opencode state, restarts opencode-serve, and brings nvims back up as `nvims`. Run it manually when you want a fresh start; run it nightly via the existing 3 AM timer for autonomous memory hygiene.

## Goals

- **One command** to fully reset the cloudbox workspace: nvims, opencode sessions, opencode-serve.
- **Idempotent and safe to re-run.**
- **Same code path** for manual invocation and the 3 AM systemd timer (no divergence between "what the human runs" and "what the timer runs").
- **Replace** `nightly-restart-background`'s 3 AM serve-restart with `reset-workspace --yes` running on the same timer.

## Non-goals

- **Not** a tmux session manager. We don't create new tmux windows or change layout. `reset-workspace` operates on the windows that already exist.
- **Not** a generalized "workspace bootstrap" tool. The set of windows you have is whatever is currently open; we don't read a config file or declare desired state.
- **Not** a replacement for `reap-stale-opencode` (the every-6h timer that SIGKILLs forgotten Telegram-launched headless workers). That solves a different problem and stays.
- **Not** a graceful-quit dance for nvim. nvim on cloudbox is a host for opencode tabs only — no editing, no unsaved buffers to worry about. SIGKILL is fine.

## Constraints (from brainstorming)

- **macOS is out of scope.** This is cloudbox-specific (NixOS, systemd, leaky opencode-serve, etc.). The package may end up cross-platform but the systemd integration is cloudbox-only.
- **Drop the serve restart from the original brainstorm.** Wait, no — *include* the serve restart, because the whole point is to replace `nightly-restart-background`. The cost (this Claude session's TUI reconnects, ~5–15s downtime) is acceptable because it's the explicit goal.
- **Kill nvims hard, no graceful quit.** User confirmed: "kill all nvims, I'm never doing anything in there besides opencode."
- **Delete all opencode sessions, not stale-only.** Since serve is restarting anyway, half-measures don't make sense.
- **Same command for manual + nightly.** The nightly run uses `--yes` to skip the confirmation prompt.

## Architecture

### Package layout

`pkgs/reset-workspace/default.nix` — `writeShellApplication` following the same pattern as `pkgs/oc-auto-attach/`. Registered in `flake.nix` `localPkgsFor`, added to `home.packages` in `home.base.nix`.

### Behavior (in order)

1. **Snapshot tmux workspace.** `tmux list-panes -a -F '#{pane_id}\t#{window_name}\t#{pane_current_command}\t#{pane_current_path}'`. Filter to panes whose `pane_current_command` is `nvim` or `nvims`. This is the manifest — the panes we'll respawn at the end.

2. **Confirm with the user.** Print the manifest + the count of opencode sessions about to be deleted. Prompt `[y/N]`. Skip with `--yes`.

3. **Kill all nvims.** `pkill -9 -u dev -x nvim` (the `-x` ensures we only match the `nvim` command, not anything that contains "nvim" as a substring). Then for each pane in the manifest, poll `pane_current_command` until it's no longer `nvim`/`nvims` (timeout 5s per pane).

4. **Delete all opencode sessions.** Loop: `curl -s http://127.0.0.1:4096/session | jq -r '.[].id' | while read id; do curl -sf -X DELETE http://127.0.0.1:4096/session/$id; done`.

5. **Restart opencode-serve.** `sudo systemctl restart opencode-serve`. Then poll `http://127.0.0.1:4096/global/health` until 200 OK (timeout 30s). The nightly run won't need `sudo` because the unit already runs as a privileged context — see "Sudo handling" below.

6. **Respawn nvims.** For each pane in the manifest: `tmux send-keys -t <pane_id> "nvims" Enter`.

7. **Verify.** For each pane, confirm `/tmp/nvim-${PANE_ID#%}.sock` exists (timeout 5s per pane). Report any missing sockets.

### Failure handling

Each step prints what it did. If any step fails, the script exits non-zero and reports — no rollback attempts. The user (or systemd journal) sees what happened.

### Concurrency

Wrap the body in `flock /tmp/reset-workspace.lock` so a manual invocation and the 3 AM timer can't collide.

### Sudo handling

`systemctl restart opencode-serve` requires root. Two paths:

- **Manual invocation (you sitting at the keyboard):** the script calls `sudo systemctl restart opencode-serve`. With a NixOS sudoers rule (`security.sudo.extraRules`) granting passwordless access to *just* `systemctl restart opencode-serve` for user `dev`, the prompt doesn't fire.
- **Nightly invocation (systemd unit):** the unit runs as `User=dev` for tmux/nvim access (the user's tmux socket is at `/tmp/tmux-1000/default` and only `dev` can write to it). The same sudoers rule covers the `systemctl restart` call from the unit script.

So one sudoers rule covers both cases:

```nix
security.sudo.extraRules = [{
  users = [ "dev" ];
  commands = [{
    command = "/run/current-system/sw/bin/systemctl restart opencode-serve.service";
    options = [ "NOPASSWD" ];
  }];
}];
```

### Nightly systemd unit

Replace `systemd.services.nightly-restart-background` in `hosts/cloudbox/configuration.nix`:

```nix
systemd.services.nightly-restart-background = {
  description = "Nightly workspace reset (replaces serve-only restart)";
  serviceConfig = {
    Type = "oneshot";
    User = "dev";
    Group = "dev";
    Environment = [
      "TMUX_TMPDIR=/tmp/tmux-1000"
      # PATH so reset-workspace can find tmux, curl, jq, etc.
      "PATH=/run/current-system/sw/bin:/home/dev/.nix-profile/bin"
    ];
  };
  script = ''
    /run/current-system/sw/bin/flock -n /tmp/reset-workspace.lock \
      /home/dev/.nix-profile/bin/reset-workspace --yes
  '';
};
```

The timer block stays as-is (`OnCalendar = "*-*-* 03:00:00"`).

The `flock -n` (non-blocking) means: if the user is mid-reset at 3 AM, the timer run silently no-ops instead of queuing.

## Risks and mitigations

| Risk | Mitigation |
|------|------------|
| User runs `reset-workspace` mid-conversation in this very Claude session | Confirmation prompt by default; the prompt explicitly says "this Claude session's TUI will reconnect." User can still proceed knowingly. |
| Timer fires during a manual run | `flock -n`: timer no-ops. |
| nvim doesn't quit (zombie process) | `pkill -9` is unconditional. Zombies will be reaped by init. Pane stays in `nvim` state but the next `tmux send-keys "nvims"` runs in the pane regardless of what's there — worst case we get a `nvims` running on top of a hung shell. Acceptable. |
| opencode-serve doesn't come back healthy in 30s | Script exits non-zero with a clear error. systemd `Restart=always` will keep retrying serve independently. Manual recovery: check `journalctl -u opencode-serve`. |
| User skips resets for a week, opencode-serve memory balloons | Existing memory limits (`MemoryMax=10G`, `MemoryHigh=8G`) prevent system-wide impact. The nightly timer still fires unconditionally — that's the safety net. The risk only materializes if BOTH the user AND the timer skip resets, which would require the timer to be broken. |
| nvim was launched in a window that's since been closed | The pane no longer exists; `tmux send-keys` to a non-existent pane errors. We snapshot panes BEFORE killing, so this can't happen within a single run. |
| New tmux windows opened mid-run | They're not in the manifest, so respawn skips them. They keep whatever they had. Acceptable. |

## What gets removed

- `systemd.services.nightly-restart-background.script`'s body (currently `systemctl restart opencode-serve.service`) becomes a `reset-workspace --yes` call.
- The unit's `serviceConfig` gets `User=dev`, `Group=dev`, `Environment=...` added.
- Comment at line 393–394 of `hosts/cloudbox/configuration.nix` updated to reflect the new behavior.

Nothing is deleted outright. The unit name (`nightly-restart-background`) stays for compatibility — if anything in the future references it, the name still works.

## What stays

- `reap-stale-opencode` timer (every 6h, kills forgotten Telegram-launched headless workers). Different problem.
- `opencode-serve` unit (`Restart=always`, memory limits). Unchanged.
- The auto-attach plumbing (`oc-auto-attach`, `nvims`, `oc_auto_attach.lua`). Unchanged — `reset-workspace` exists *because* of it.

## Estimated size

- `pkgs/reset-workspace/default.nix`: ~120 lines bash.
- `flake.nix`: 1 line added to `localPkgsFor`.
- `users/dev/home.base.nix`: 1 line added to `home.packages`.
- `hosts/cloudbox/configuration.nix`: ~15 lines changed (sudoers rule + unit script update).

Total: ~140 lines of net-new code.

## Open questions

None. All design decisions resolved during brainstorming. Ready to plan.
