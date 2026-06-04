# Route lgtm's auto-attached sessions to a dedicated tmux session

**Date:** 2026-06-04
**Status:** Approved (design)
**Repos touched:** `workstation` (opencode-launch, oc-auto-attach), `lgtm` (arg builders)

## Problem

When a background process (notably `lgtm`, the PR-review daemon at
`~/projects/lgtm`) runs `opencode-launch` while the user is working,
`oc-auto-attach` yanks the user out of their current nvim tab and tmux window.

Two distinct focus thefts, both in `oc-auto-attach`:

1. **tmux level** — `tmux select-window` in all three `classify_pane` branches
   (`pkgs/oc-auto-attach/default.nix:271,279,286`) brings the target window to
   the foreground of the user's client. (A *brand-new* window is created with
   `tmux new-window -d`, so creation itself is non-disruptive — only the later
   `select-window` steals focus.)
2. **nvim level** — `M.open()` calls `vim.cmd.tabnew()`
   (`assets/nvim/lua/user/oc_auto_attach.lua:46`), which always switches to the
   new tab.

## Decision

Give lgtm a **dedicated tmux session** (literally named `lgtm`) and have
`oc-auto-attach` confine *all* of its activity to that session when told to.
Because the user is not *attached* to that session during normal work,
`select-window` and `tabnew` only ever act on a view the user isn't looking at —
focus theft becomes structurally impossible.

The user reviews lgtm output by switching to the `lgtm` session
(`tmux attach -t lgtm` / `switch-client`) when they choose to, and kills it
whenever (manually or via the nightly reset side effect).

### Why this over the alternatives

Considered and rejected:

- **TTY auto-detect + "quiet/unfocused" background mode.** `opencode-launch`
  would check `[ -t 1 ]` (interactive → steal focus; daemon → quiet) and
  `oc-auto-attach`/nvim would open tabs without focusing. This solves the same
  problem but requires building "unfocused tab" logic in Lua and tmux, plus a
  second concept (TTY detection). Session-routing is **less code** and a single
  concept ("lgtm has a sandbox"). Dropped as YAGNI; can revisit if a
  "launch-by-hand-but-don't-jump-me" need ever materializes.
- **New detached window in the *current* session.** Still clutters the user's
  working session. Rejected.

### Mechanism: `--tmux-session <name>` flag, threaded

`lgtm` → `opencode-launch --tmux-session lgtm` → `oc-auto-attach --tmux-session lgtm`.
Chosen over an env var because it is explicit, discoverable, unit-testable in
lgtm, and matches the existing `--model` / `--mcp` plumbing conventions.

When the flag is **absent**, behavior is **100% unchanged** (current `-a`
whole-server scan, current session). The new code path activates only with the
flag.

## Component changes

### 1. `opencode-launch` (`users/dev/home.base.nix`)

- Parse `--tmux-session <name>` and `--tmux-session=<name>` in the existing
  option loop (alongside `--model` / `--mcp`).
- Forward to the auto-attach spawn:
  `setsid nohup oc-auto-attach --tmux-session "$tmux_session" "$session_id" ...`
  (only add the flag when non-empty).
- Add to `usage()`.

### 2. `oc-auto-attach` (`pkgs/oc-auto-attach/default.nix`)

- Accept an optional leading `--tmux-session <name>` arg before the session id.
  Validate `^[A-Za-z0-9_-]+$` (tmux forbids `.` and `:` in session names; this
  also blocks injection). Invalid → log + exit 0 (consistent with the script's
  never-break-the-launcher posture).
- When a target session is set:
  - **Scan only that session** for a reusable pane:
    `tmux list-panes -s -t "=<name>" -F '#{pane_id}|#{pane_current_command}|#{pane_current_path}'`
    (the `-s` flag = all panes across all windows in the session; `=` = exact
    name match). Keep the existing exact-cwd-then-descendant matching logic.
  - **Create inside that session** when no pane matches:
    - exists: `tmux new-window -d -P -F '#{pane_id}' -t "<name>:" -c "$project_key" -n "$window_name" -- "$nvims_path"`
    - absent: `tmux new-session -d -P -F '#{pane_id}' -s "<name>" -c "$project_key" -n "$window_name" -- "$nvims_path"`
      (`new-session` starts the tmux server if none exists.)
  - **Skip the "no tmux server running; skipping" bail** (line 196–199) in this
    path — we *want* to create the session.
- Everything downstream (`classify_pane`, `select-window`, socket-wait, the nvim
  RPC) is reused verbatim. It is harmless within an unattached session.

### 3. `lgtm` (`src/dispatch.ts`, `src/gather.ts`)

- Add `--tmux-session lgtm` to `buildDispatchArgs` and `buildGatherArgs`.
- Session name is a hardcoded constant `lgtm` (not configurable for now).
- Extend the existing arg-builder unit tests to assert the new arg is present.

### Not changing

- `assets/nvim/lua/user/oc_auto_attach.lua` — no nvim-side change. Tab focus
  within an unattached session does not disturb the user.

## Edge cases / notes

- **Same-project reviews collapse** into one window-with-tabs in the drawer
  (existing worktree → project-root collapse in
  `oc-auto-attach` step 2 is kept). Acceptable for a junk drawer.
- **Default tmux socket assumed.** The daemon-spawned `oc-auto-attach` and the
  user's interactive tmux must share a server (standard `/tmp/tmux-<uid>/default`
  socket). A custom `-L` socket would diverge — noted, not handled.
- **Nightly reset cleanup.** `reset-workspace` does `pkill -9 -x nvim` +
  `systemctl restart opencode-serve` (`pkgs/reset-workspace/default.nix:239,253`).
  It does not kill tmux sessions directly, but killing every nvim closes the
  `nvims`-rooted windows, and tmux destroys a session when its last window
  closes — so the `lgtm` drawer is torn down nightly as a side effect.
- **Recommendation-agent noise.** `reset-workspace` snapshots all
  `opencode attach` clients, so the morning recommendation agent will list lgtm
  review sessions among its suggestions. Minor noise; out of scope.

## Testing

- **lgtm:** extend the existing `buildDispatchArgs` / `buildGatherArgs` unit
  tests (`src/dispatch.ts`, `src/gather.ts`) to assert `--tmux-session lgtm`.
- **oc-auto-attach (manual):** while attached to the main tmux session, run
  `opencode-launch --tmux-session scratch ~/projects/<foo> "echo hi"` and verify:
  1. The user's client is **not** yanked to another window/tab.
  2. A tmux session named `scratch` exists containing a window with the
     `opencode attach` tab.
  3. `/tmp/oc-auto-attach.log` shows the target-session branch was taken.
- **Backward compat:** `opencode-launch ~/projects/<foo> "echo hi"` (no flag)
  still attaches into the current session as today.

## Rollout

1. Land workstation change; rebuild home-manager on cloudbox
   (`nix run home-manager -- switch --flake .#cloudbox`) so the new
   `opencode-launch` / `oc-auto-attach` are on PATH and in the pigeon-daemon's
   injected env paths.
2. Land lgtm change; redeploy/restart the lgtm daemon so it picks up the new
   arg builders.
