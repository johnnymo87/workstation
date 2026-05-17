# oc-auto-attach: Reuse Existing tmux Window Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make `oc-auto-attach <sid>` reuse an existing tmux window whose pane is at the project's cwd, regardless of what command is currently in that pane's foreground. Launch `nvims` via `tmux send-keys` if the foreground is a shell; refuse to clobber non-shell foregrounds.

**Architecture:** Single file. Relax the existing "scan all panes" filter (drop the `pane_current_command == "nvim"` predicate). Add a branching step that decides what to do with the matched pane based on its foreground command: reuse-as-is for `nvim`, `send-keys` for shells, select-only for anything else. Always `tmux select-window` the target.

**Tech Stack:** Nix (`pkgs.writeShellApplication`), bash, tmux. No tests beyond a manual live-repro matrix on cloudbox (no test harness exists for this binary; the verification matrix in the design doc is the test plan).

**Bead:** workstation-mlr (discovered-from workstation-6bz).

**Design doc:** [docs/plans/2026-05-16-oc-auto-attach-reuse-existing-window-design.md](2026-05-16-oc-auto-attach-reuse-existing-window-design.md) — READ FIRST.

---

## Pre-flight

**Step 0.1: Confirm starting state**

Run from repo root:
```bash
grep -n 'pane_current_command' pkgs/oc-auto-attach/default.nix
grep -n 'tmux new-window' pkgs/oc-auto-attach/default.nix
grep -n 'tmux select-window' pkgs/oc-auto-attach/default.nix
```
Expected:
- `pane_current_command` appears on the `list-panes -F` format strings (≥2 occurrences) — these are what we'll be reading.
- `tmux new-window` appears once (the create-new-window block on ~line 137).
- `tmux select-window` should NOT appear at all in current code (we are adding it).

If any of these are surprising, STOP and re-read the design doc before proceeding.

**Step 0.2: Pre-build clean**

Run:
```bash
nix build .#packages.aarch64-linux.oc-auto-attach
```
Expected: builds cleanly. We want a known-good baseline so any build failure during implementation is clearly from our change.

**Step 0.3: Update bead**

```bash
bd update workstation-mlr --status in_progress
```

---

## Task 1: Add a shared helper that branches on the matched pane's foreground command

**Files:**
- Modify: `pkgs/oc-auto-attach/default.nix`

**Why this task first:** Step 3 and the fallback block (lines 121-130) both need the same "what do I do with this pane?" logic. DRY: write the helper once, then both call sites use it. The helper has no behavior change yet because nothing calls it; this is pure refactor groundwork.

**Step 1.1: Insert the helper function**

Insert immediately AFTER the `log()` definition (currently around line 32, before the `if [ $# -ne 1 ]` block). The helper is a bash function that takes `pane_id` and `pane_cmd` as $1 and $2 and prints one of three tokens to stdout (`REUSE`, `SEND_NVIMS`, `SKIP`) followed by exit 0. It does NOT modify state — the caller is responsible for acting on the token. This keeps it pure and trivially auditable.

```bash
    # classify_pane <pane_id> <pane_cmd>
    #
    # Decides what oc-auto-attach should do with a pane it has matched
    # by cwd. Prints exactly one token to stdout:
    #
    #   REUSE       — pane already has nvim in the foreground; caller
    #                 should proceed to the socket-wait + RPC path.
    #   SEND_NVIMS  — pane has a shell prompt; caller should
    #                 `tmux send-keys C-c` then `send-keys nvims Enter`
    #                 to start nvims in this pane, then proceed.
    #   SKIP        — pane has something else in the foreground (a
    #                 long-running tool the user doesn't want clobbered).
    #                 Caller should `tmux select-window` so the user
    #                 sees we noticed, log a hint, then exit 0.
    classify_pane() {
      local cmd="$2"
      case "$cmd" in
        nvim)
          printf 'REUSE\n'
          ;;
        bash|zsh|fish|sh)
          printf 'SEND_NVIMS\n'
          ;;
        *)
          printf 'SKIP\n'
          ;;
      esac
    }
```

Notes for the implementer:
- This is being inserted into a Nix `writeShellApplication`'s `text = ''...''` block, so bash `$1`/`$2` references need NO Nix escaping (no `''$` needed) BECAUSE there's no Nix interpolation to confuse the lexer here — but bash `${...}` parameter expansions WOULD need to be written as `''${...}` to escape Nix interpolation. The helper above uses only `$1`, `$2`, `$cmd`, and `$*` — all plain `$NAME` form, safe as-is. (See the existing `log()` function in this same file for the exact convention.)
- `local` is fine; bash supports it inside functions even in `set -o nounset`.

**Step 1.2: Verify the helper parses**

Run:
```bash
nix build .#packages.aarch64-linux.oc-auto-attach 2>&1 | tail -10
```
Expected: builds cleanly. (No call sites yet, so behavior is unchanged.)

**Step 1.3: Commit**

```bash
git add pkgs/oc-auto-attach/default.nix
git commit -m "refactor(oc-auto-attach): add classify_pane helper for window-reuse branching

Pure-function helper that takes a matched pane's id + foreground cmd and
returns one of REUSE / SEND_NVIMS / SKIP. No call sites yet — wired up
in the next commit. Refs workstation-mlr."
```

---

## Task 2: Rewire Step 3 (main scan) to drop the nvim-only filter and route through classify_pane

**Files:**
- Modify: `pkgs/oc-auto-attach/default.nix` (the Step 3 block around lines 85-145).

**Why this task:** This is the meat of the behavior change. The current Step 3 scan filters out non-nvim panes (`[ "$p_cmd" = "nvim" ] || continue`); we drop that filter so shell panes also get considered. We also need to capture the matched pane's command (not just its id) so we can pass it to `classify_pane`. Then we branch.

**Step 2.1: Read the current Step 3 + fallback block**

Re-read [pkgs/oc-auto-attach/default.nix:85-145](../../pkgs/oc-auto-attach/default.nix) carefully. Note:
- Lines 87-97 are the main scan. They set `pane_id` only.
- Lines 99-100: log if found.
- Lines 101-145: the `else` branch (no match found) — contains the "no tmux" guard, the window-by-name fallback, and the `tmux new-window` create path.

We are going to replace this block. Plan the edit before typing.

**Step 2.2: Replace the main scan loop to capture pane_cmd alongside pane_id**

Find this exact block (lines 87-97):
```bash
    pane_id=""
    while IFS='|' read -r p_id p_cmd p_path; do
      [ "$p_cmd" = "nvim" ] || continue
      if [ "$p_path" = "$project_key" ]; then
        pane_id="$p_id"
        break  # exact match wins
      fi
      if [[ "$p_path" == "$project_key"/* ]] && [ -z "$pane_id" ]; then
        pane_id="$p_id"  # remember as fallback, keep looking for exact
      fi
    done < <(tmux list-panes -a -F '#{pane_id}|#{pane_current_command}|#{pane_current_path}' 2>/dev/null || true)
```

Replace with:
```bash
    pane_id=""
    pane_cmd=""
    # Scan all panes for one whose pane_current_path matches the project,
    # regardless of foreground command. We capture the command too so we
    # can branch on it in Step 3.5.
    while IFS='|' read -r p_id p_cmd p_path; do
      if [ "$p_path" = "$project_key" ]; then
        pane_id="$p_id"
        pane_cmd="$p_cmd"
        break  # exact match wins
      fi
      if [[ "$p_path" == "$project_key"/* ]] && [ -z "$pane_id" ]; then
        # Remember descendant as fallback; keep looking for exact.
        pane_id="$p_id"
        pane_cmd="$p_cmd"
      fi
    done < <(tmux list-panes -a -F '#{pane_id}|#{pane_current_command}|#{pane_current_path}' 2>/dev/null || true)
```

Verify: `nix build .#packages.aarch64-linux.oc-auto-attach 2>&1 | tail -5` — should build cleanly.

**Step 2.3: Update the "if matched" log line to include the command**

Find:
```bash
    if [ -n "$pane_id" ]; then
      log "matched existing pane $pane_id"
```
Replace with:
```bash
    if [ -n "$pane_id" ]; then
      log "matched existing pane $pane_id (cmd=$pane_cmd)"
```

Verify build still clean.

**Step 2.4: Rewire the window-by-name fallback to also capture pane_cmd**

Find this block (currently lines 121-130):
```bash
      existing_pane=""
      while IFS='|' read -r ep_id ep_cmd; do
        if [ "$ep_cmd" = "nvim" ]; then
          existing_pane="$ep_id"
          break
        fi
      done < <(tmux list-panes -t ":$window_name" -F '#{pane_id}|#{pane_current_command}' 2>/dev/null || true)
      if [ -n "$existing_pane" ]; then
        pane_id="$existing_pane"
        log "reusing existing window $window_name pane $pane_id"
```

Replace with:
```bash
      # Defense-in-depth: the main scan should have caught a window for this
      # project by pane_current_path, but if pane_current_path is stale (some
      # shells don't fire OSC 7 reliably) or two sessions raced in the same
      # cwd, we also check for a window literally named $window_name. We no
      # longer require nvim to be the foreground here either — Step 3.5 below
      # will sort out what to do.
      existing_pane=""
      existing_pane_cmd=""
      while IFS='|' read -r ep_id ep_cmd; do
        existing_pane="$ep_id"
        existing_pane_cmd="$ep_cmd"
        break  # first pane in the window is fine
      done < <(tmux list-panes -t ":$window_name" -F '#{pane_id}|#{pane_current_command}' 2>/dev/null || true)
      if [ -n "$existing_pane" ]; then
        pane_id="$existing_pane"
        pane_cmd="$existing_pane_cmd"
        log "reusing existing window $window_name pane $pane_id (cmd=$pane_cmd)"
```

Verify build still clean.

**Step 2.5: Update the new-window create path to capture pane_cmd and select the window**

Find this block (currently around lines 132-143):
```bash
        nvims_path="$(command -v nvims || true)"
        if [ -z "$nvims_path" ]; then
          log "nvims not found on PATH; skipping"
          exit 0
        fi
        pane_id="$(tmux new-window -d -P -F '#{pane_id}' \
          -c "$project_key" -n "$window_name" -- "$nvims_path" 2>/dev/null || true)"
        if [ -z "$pane_id" ]; then
          log "tmux new-window failed; giving up"
          exit 0
        fi
        log "created new pane $pane_id (window $window_name)"
```

Replace with:
```bash
        nvims_path="$(command -v nvims || true)"
        if [ -z "$nvims_path" ]; then
          log "nvims not found on PATH; skipping"
          exit 0
        fi
        pane_id="$(tmux new-window -d -P -F '#{pane_id}' \
          -c "$project_key" -n "$window_name" -- "$nvims_path" 2>/dev/null || true)"
        if [ -z "$pane_id" ]; then
          log "tmux new-window failed; giving up"
          exit 0
        fi
        # Brand new window: we know nvims is the entrypoint, so the
        # foreground is (or will be momentarily) nvim. Skip the
        # send-keys branch in Step 3.5 and go straight to socket-wait.
        pane_cmd="nvim"
        log "created new pane $pane_id (window $window_name)"
        # Bring the new window to the user's attention. `new-window -d`
        # above is intentional (don't yank focus DURING the script's
        # races), but at this point we're committed and want the user
        # looking at where the tab will land.
        tmux select-window -t "$pane_id" 2>/dev/null || true
```

Verify build still clean.

**Step 2.6: Insert Step 3.5 (branch on pane_cmd) immediately AFTER the closing `fi` of the big if/else block**

The big if/else block (matched-pane vs no-match-create-new) closes at line ~145. Immediately after its closing `fi`, BEFORE Step 4 ("compute socket path", currently around line 147), insert:

```bash
    # Step 3.5: Decide what to do with $pane_id based on its foreground.
    #
    # By this point pane_id is non-empty (we either matched or created)
    # and pane_cmd reflects the pane's foreground command. classify_pane
    # tells us which branch to take.
    action="$(classify_pane "$pane_id" "$pane_cmd")"
    log "classify_pane: $action"
    case "$action" in
      REUSE)
        # Foreground is already nvim — bring the window to focus and
        # proceed to Step 4 (socket + RPC).
        tmux select-window -t "$pane_id" 2>/dev/null || true
        ;;
      SEND_NVIMS)
        # Shell prompt. Clear any half-typed command line with C-c,
        # then send `nvims\n`. nvims will exec into `nvim --listen
        # /tmp/nvim-<pane>.sock`, which Step 4-5 will pick up.
        tmux send-keys -t "$pane_id" C-c 2>/dev/null || true
        tmux send-keys -t "$pane_id" 'nvims' Enter 2>/dev/null || true
        tmux select-window -t "$pane_id" 2>/dev/null || true
        log "sent C-c + 'nvims' to pane $pane_id; waiting for nvim to come up"
        ;;
      SKIP)
        # Some other tool is running in the matched pane (opencode,
        # tail -f, top, etc). Don't clobber. Just bring it to focus
        # and ask the user to launch nvims themselves.
        tmux select-window -t "$pane_id" 2>/dev/null || true
        log "found existing window for $project_key with $pane_cmd running; not launching nvims — start it yourself, then re-run oc-auto-attach $sid"
        exit 0
        ;;
      *)
        log "classify_pane returned unexpected token: $action; bailing"
        exit 0
        ;;
    esac
```

Verify build still clean.

**Step 2.7: Commit**

```bash
git add pkgs/oc-auto-attach/default.nix
git commit -m "feat(oc-auto-attach): reuse existing tmux window by cwd, regardless of foreground

The main pane scan no longer filters on pane_current_command == nvim, so
it matches windows where the user has a shell prompt (or anything else)
parked at the project's cwd. A new Step 3.5 routes the matched pane
through classify_pane:

- REUSE (foreground is nvim): select-window and proceed to RPC.
- SEND_NVIMS (shell foreground): tmux send-keys C-c + 'nvims\\n', then
  select-window, then proceed to socket-wait + RPC. The existing 5s
  socket-wait absorbs nvims's startup.
- SKIP (anything else): select-window so the user knows we noticed,
  log a hint, exit 0.

The window-by-name fallback gets the same treatment (drop the nvim
filter, capture pane_cmd, route through classify_pane). The
create-new-window path now also tmux select-window's the new window
so the user is looking at where the tab will land.

Closes workstation-mlr. Discovered during live verify of workstation-6bz."
```

---

## Task 3: Build, deploy, live-verify the 4-case matrix

**Files:** none (verification only).

**Step 3.1: Build**

```bash
nix build .#packages.aarch64-linux.oc-auto-attach
```
Expected: builds cleanly, no warnings.

**Step 3.2: Deploy**

```bash
nix run home-manager -- switch --flake .#cloudbox
```
Expected: activation succeeds.

**Step 3.3: Sanity-check deployed binary**

```bash
grep -c 'send-keys' "$(which oc-auto-attach)"
grep -c 'classify_pane' "$(which oc-auto-attach)"
grep -c 'select-window' "$(which oc-auto-attach)"
```
Expected: `send-keys` ≥ 2 (C-c + nvims), `classify_pane` ≥ 5 (definition + call + 3 case-arms referenced in comments… approximately; the floor is ≥ 2: definition + call site), `select-window` ≥ 4 (REUSE, SEND_NVIMS, SKIP, new-window create).

If any count is 0 or surprisingly low, STOP — the deploy didn't take.

**Step 3.4: Live-verify case 1 (shell prompt in existing window)**

This task is interactive; coordinate with the user.

Setup:
1. Ensure a tmux window exists named e.g. `ws` with a bash prompt sitting at `~/projects/workstation`. (`tmux new-window -n ws -c ~/projects/workstation` if needed.)
2. Confirm: `tmux list-windows -F '#{window_name} #{pane_current_path} #{pane_current_command}'` shows the ws window with `bash`.
3. Launch a real opencode session in `~/projects/workstation` (e.g. via `opencode-launch ~/projects/workstation 'echo hi'`) — capture the returned `ses_xxx`.
4. Trigger: `oc-auto-attach ses_xxx`.

Expected:
- The `ws` window's bash prompt receives C-c (any half-typed text discarded) then `nvims\n`.
- `nvims` runs, exec's into nvim, socket appears at `/tmp/nvim-<pane>.sock`.
- The RPC succeeds and a new tab opens in that nvim with `opencode attach ses_xxx`.
- `tmux list-windows | wc -l` shows the same window count as before (no new window).
- The user is focused on the `ws` window.

If anything diverges, debug before proceeding to case 2.

**Step 3.5: Live-verify case 2 (nvim already in existing window)**

Setup:
1. The `ws` window from case 1 should now have nvim in the foreground (case 1 left it that way).
2. Confirm: `tmux list-windows -F '#{window_name} #{pane_current_command}'` shows `ws nvim`.
3. Launch another opencode session in `~/projects/workstation`, capture sid.
4. Trigger: `oc-auto-attach <new sid>`.

Expected:
- No `send-keys` (we should see the `REUSE` branch log line).
- A new tab opens in the existing nvim for the new sid.
- Window count unchanged.

**Step 3.6: Live-verify case 3 (non-shell, non-nvim foreground in existing window)**

Setup:
1. In the `ws` window, run a long-lived non-shell command: `tail -f /dev/null` is fine.
2. Confirm: foreground command is `tail`.
3. Launch another opencode session in `~/projects/workstation`, capture sid.
4. Trigger: `oc-auto-attach <new sid>`.

Expected:
- `classify_pane: SKIP` log line.
- `found existing window for ... with tail running; not launching nvims` log line.
- The user is focused on the `ws` window (selected).
- The `tail -f` is undisturbed.
- No new window, no `send-keys`.
- `oc-auto-attach` exits 0.

Then: Ctrl+C the `tail -f` to restore the window for the next case.

**Step 3.7: Live-verify case 4 (no existing window for the project)**

Setup:
1. Close the `ws` window: `tmux kill-window -t ws`.
2. Confirm no window has cwd at `~/projects/workstation`: `tmux list-panes -a -F '#{pane_current_path}' | grep -F "$HOME/projects/workstation"` should be empty.
3. Launch another opencode session in `~/projects/workstation`, capture sid.
4. Trigger: `oc-auto-attach <new sid>`.

Expected:
- A new tmux window named `workstation` is created.
- `nvims` runs in it, socket appears, tab opens.
- The user is focused on the new `workstation` window.
- Window count: +1.

**Step 3.8: Verification summary**

Briefly record (in chat back to user) the 4-case results: pass/fail/notes. If all pass, proceed to wrap-up.

---

## Wrap-up

**Step W.1: Close bead, sync, push (fast-forward to origin/main — no PR)**

```bash
bd close workstation-mlr --reason "Live-verified all 4 cases on cloudbox YYYY-MM-DD HH:MM. <add observations>"
bd sync
git add .beads/issues.jsonl
git commit -m "chore(beads): close workstation-mlr"
git pull --rebase
git push
git status
```
Expected: `git status` shows "up to date with origin/main".

**Step W.2: Confirm done**

Report to user:
- Live verify results (4 cases).
- Commits pushed (count + last sha).
- Bead workstation-mlr closed.

---

## Files Touched (summary)

- `pkgs/oc-auto-attach/default.nix` — the only code change.
- `docs/plans/2026-05-16-oc-auto-attach-reuse-existing-window-design.md` — already committed.
- `docs/plans/2026-05-16-oc-auto-attach-reuse-existing-window-plan.md` — this plan.
- `.beads/issues.jsonl` — bead status updates.

## Gotchas the implementer should know

- **Nix-in-bash escaping convention.** This file is a `pkgs.writeShellApplication`'s `text = ''…''` block. Bash `$VAR` is fine as-is. Bash `${VAR}` parameter expansions need `''${VAR}` to escape Nix antiquotation. Search existing file for `''${` to see examples.
- **`pane_current_command` is the foreground process name as seen by tmux.** It's "bash" not "/bin/bash". `nvim` is `nvim`. `nvims` doesn't appear here because nvims is a wrapper that `exec`s into nvim — by the time it's the foreground, the command is `nvim`.
- **`tmux send-keys C-c`**: `C-c` is the tmux notation for Ctrl-C. tmux translates it to the SIGINT-generating sequence; don't write `^C` or anything else.
- **`tmux select-window -t <pane_id>` works** — tmux accepts pane targets and resolves to the containing window. No need to look up the window id separately.
- **Errors are swallowed with `|| true` throughout this file.** The design choice (see file header comment) is that oc-auto-attach should never break the launcher — failures log to stderr and `exit 0`. Preserve that. The new code uses `2>/dev/null || true` on the tmux calls for the same reason.
- **No test harness.** This binary has no automated tests. The repro matrix in Task 3 IS the test. Do NOT invent a unit-test framework.
- **`bd close` before push.** Order matters: close the bead first, then `bd sync` to write the close into JSONL, then commit + push. Otherwise the close is stranded locally.
