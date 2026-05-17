# oc-auto-attach: reuse existing tmux window for a project's cwd

**Date:** 2026-05-16
**Bead:** [workstation-mlr](../../README.md) (discovered-from workstation-6bz)
**Status:** Design approved, ready for implementation plan.

## Problem

`oc-auto-attach <sid>` is the bridge between an opencode session being launched
(by `opencode-launch`, by `reset-workspace`'s recommendation session, or by any
other caller) and a tmux+nvim window the user can actually work in. Its job is
to find the right tmux window for the session's project, ensure nvim is running
in it, and RPC into nvim to open an `opencode attach` tab.

Tonight's live verification of the recommendation-driven nightly reset
(workstation-6bz) surfaced a gap. The user kept a long-lived tmux window
named `ws` open for `~/projects/workstation` (a shell prompt; no nvim
running). When the recommendation session shelled out to
`oc-auto-attach <sid>` for a session in that directory, `oc-auto-attach`
created a NEW tmux window named `workstation` instead of reusing the
existing `ws` window. The user now had two windows for the same project
— exactly the kind of clutter the recommendation flow was built to
avoid.

## Root cause

`oc-auto-attach`'s current "find an existing pane" scan
([pkgs/oc-auto-attach/default.nix:87-97](../../pkgs/oc-auto-attach/default.nix))
filters on `pane_current_command == "nvim"` as well as the path match:

```bash
while IFS='|' read -r p_id p_cmd p_path; do
  [ "$p_cmd" = "nvim" ] || continue
  if [ "$p_path" = "$project_key" ]; then
    pane_id="$p_id"
    break
  fi
  ...
done < <(tmux list-panes -a -F '#{pane_id}|#{pane_current_command}|#{pane_current_path}' 2>/dev/null || true)
```

The `ws` window's pane had `pane_current_command == "bash"` (shell
prompt), so the scan skipped it. The defense-in-depth fallback on
[lines 121-130](../../pkgs/oc-auto-attach/default.nix) looks for a
window literally named `$window_name` (which is `workstation` — the
basename of the project root), so it also missed `ws`. Result:
`tmux new-window` created a fresh `workstation` window.

The `nvim`-only filter made sense when `oc-auto-attach`'s only path to
opening an opencode tab went through nvim's RPC (you can't attach to a
nvim that isn't running). But it means any window where the user has
parked at a shell or some other tool gets ignored, even though that
window is conceptually "the workstation window" and the user wants
their opencode tab there.

## Design

### Behavior

For a given `sid` whose session has `directory=<dir>`:

1. **Resolve project key + window name** — unchanged from today
   ([lines 76-82](../../pkgs/oc-auto-attach/default.nix)). Collapse
   `~/projects/<P>(/.worktrees/<W>)?(/.*)?` to `~/projects/<P>`.

2. **Find candidate pane** — scan `tmux list-panes -a` for panes
   whose `pane_current_path` equals `project_key` exactly or is a
   descendant. Prefer exact-path matches. **Drop the
   `pane_current_command == "nvim"` filter.** Capture both the
   `pane_id` AND `pane_current_command` of the chosen pane.

3. **Branch on candidate's foreground command** (new logic):
   - **`nvim`** → reuse exactly as today. Compute socket path from
     `pane_id`, wait for RPC + helper module, open tab. Also
     `tmux select-window -t <pane_id>`.
   - **shell (`bash`, `zsh`, `fish`, `sh`)** →
     `tmux send-keys -t <pane_id> C-c` (clears any half-typed command),
     then `tmux send-keys -t <pane_id> 'nvims' Enter`, then
     `tmux select-window -t <pane_id>`, then proceed to socket-wait +
     RPC. `nvims` will `exec` into `nvim --listen
     /tmp/nvim-<pane>.sock` so the socket appears as soon as nvim
     starts. The existing 5-second socket-wait absorbs the startup
     race.
   - **anything else** (`opencode`, `tail`, `less`, `top`, etc.) →
     refuse to clobber. `tmux select-window -t <pane_id>` so the
     user sees the window we noticed, log
     `found existing window for <project_key> with <cmd> running; not launching nvims — start it yourself`,
     exit 0.

4. **No candidate pane found** — fall through to the existing
   "create new window" path
   ([lines 132-143](../../pkgs/oc-auto-attach/default.nix)):
   `tmux new-window -n <window_name> -c <project_key> -- nvims`.
   Add `tmux select-window -t <new pane_id>` (today's
   `new-window -d` leaves the new window unselected).

5. The window-by-name fallback ([lines 121-130](../../pkgs/oc-auto-attach/default.nix))
   becomes largely redundant once the main scan no longer filters on
   command (a pane in a window literally named `$window_name` will
   almost always have a matching `pane_current_path`). But it's cheap,
   defends against any weird `pane_current_path` staleness, and we
   keep it for safety. Refactor it to share the Step 3 branching
   (extract into a small bash function so both call sites use it).

### Why send-keys + `C-c` is safe enough

`tmux send-keys` literally types characters into the pane's tty. The
hazard is appending `nvims\n` to a half-typed shell command line.
`send-keys C-c` first clears the current line by sending SIGINT to
the shell — the standard tmux idiom for "force a clean shell prompt
before sending a command." Against an idle prompt it's a no-op; against
a half-typed command it discards the input and gives us a fresh prompt.

We gate this on `pane_current_command ∈ {bash, zsh, fish, sh}`. If
the foreground process is anything else (an editor, opencode, a long
pipe), we refuse to send keys — the cost of clobbering is too high
for the benefit of saving the user a `nvims` keystroke.

### Why we don't restart nvims when the picker is up

The `nvims` shell script is a thin wrapper that `exec`s into `nvim
--listen <socket>` ([pkgs/.../nvims](../../users/dev/home.base.nix)).
By the time it's "running" in a pane, the foreground process IS `nvim`
— there is no separate "picker" stage. So the only two interesting
foreground commands are `nvim` and "not nvim."

### Why we always `select-window`

Today's "create new window" path uses `tmux new-window -d`, which
creates the window but doesn't make it the active window in its
session. So even when the workflow "succeeds," the user has to
manually find and select the new window. Across all three paths
(reuse-nvim, send-nvims, no-clobber select-only, create-new) the
right behavior is: leave the user looking at the window the new
tab/session landed in. So always `select-window`.

## Edge cases & gotchas

- **Stale `pane_current_path`.** tmux updates `pane_current_path` via
  shell hooks (OSC 7 or `chpwd`-style). If a shell hasn't fired one
  recently, the path can lag behind reality. Worst case we don't
  match and fall through to creating a new window — same as today.
  Not worth designing around.

- **Multiple matching panes.** Today's loop picks the first exact-cwd
  match, then the first descendant if no exact. Preserved. If the user
  has two `ws`-like windows for the same project, only the first
  reuses; the rest stay alone. Acceptable.

- **Multi-pane windows.** `list-panes -a` enumerates panes flat across
  all windows. If the matching pane isn't the active pane in its
  window, `send-keys -t <pane_id>` still targets the right pane, and
  `select-window` brings the user to the right window. No change
  needed.

- **`tmux send-keys` racing with nvim startup.** After
  `send-keys 'nvims' Enter`, the shell `exec`s into nvim almost
  immediately. The existing Step 5 socket-wait (up to 5 seconds for
  `[ -S "$sock" ]` AND the helper module is loaded) covers this race
  — same code that handles a brand-new window today.

## Verification

A live repro matrix on cloudbox. For each case, observe that
`oc-auto-attach <sid>` for a session with `directory=~/projects/workstation`
behaves as expected. The matrix:

| # | Existing window state | Expected outcome | Window count delta |
|---|---|---|---|
| 1 | `ws` window with shell prompt at `~/projects/workstation` | `send-keys` runs `nvims`, tab opens in that window's nvim. Window auto-selected. | 0 |
| 2 | `ws` window with nvim already running | Tab opens in that nvim. No `send-keys`. Window auto-selected. | 0 |
| 3 | `ws` window with `opencode` (or `tail -f`) in foreground | `tmux select-window` to it, log "found existing window … not launching nvims", no `send-keys`, no new window. | 0 |
| 4 | No existing window for `~/projects/workstation` at all | New `workstation` window created with `nvims`, tab opens, window auto-selected. | +1 |

Pre-flight: `nix build .#packages.aarch64-linux.oc-auto-attach` to confirm parse + lint clean.
Deploy: `nix run home-manager -- switch --flake .#cloudbox`.
Sanity: `grep -c 'send-keys' "$(which oc-auto-attach)"` should be ≥ 2 (one for `C-c`, one for `nvims\n`).
For each case 1-4: arrange the tmux state, then trigger `oc-auto-attach <some-real-sid>` directly from the shell, observe.

## Out of scope (do NOT fold in)

- Window-name aliases (`ws` ↔ `workstation`) — once cwd-matching
  works, name doesn't matter.
- Persistent state files for window mappings — overengineered.
- Changes to `nvims`, the nvim helper module, or the
  socket-naming convention.
- Multi-pane window layout management.
- The reset-workspace recommendation prompt itself or the manifest format.
- workstation-dg6 (in-flight question wedging) — orthogonal.

## Files touched

- `pkgs/oc-auto-attach/default.nix` (only file).

That's the whole change.
