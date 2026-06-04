# lgtm Dedicated tmux Session — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Route lgtm's `opencode-launch`-spawned sessions into a dedicated tmux session named `lgtm` so background launches never yank the user out of their current nvim tab / tmux window.

**Architecture:** A new `--tmux-session <name>` flag flows `lgtm → opencode-launch → oc-auto-attach`. When set, `oc-auto-attach` confines all pane discovery (`list-panes -s -t =<name>`) and window creation (`new-window -t <name>:` / `new-session -s <name>`) to that one session, creating it detached if absent. Because the user isn't attached to that session during normal work, `select-window`/`tabnew` can't steal focus. No flag = current behavior, unchanged.

**Tech Stack:** Bash (Nix `writeShellApplication`), TypeScript + vitest (lgtm), tmux, home-manager.

**Design doc:** `docs/plans/2026-06-04-lgtm-dedicated-tmux-session-design.md`

**Repos:** `~/projects/workstation` (Tasks 1–2, 4), `~/projects/lgtm` (Task 3).

> **Nix escaping reminder:** Tasks 1–2 edit bash embedded in Nix `text = ''…''`
> strings. Bash `${var}` must be written `''${var}` and a literal `$` not
> followed by `{` is just `$`. Match the surrounding file's existing style
> (e.g. `''${1#--model=}`). The snippets below are shown **as they must appear
> in the `.nix` file**.

---

## Task 1: `oc-auto-attach` — accept and honor `--tmux-session`

**Files:**
- Modify: `pkgs/oc-auto-attach/default.nix`

This is bash-in-Nix; TDD is via manual verification (Task 4 has the end-to-end
check). Make the edits, then `nix build` the package to confirm it still
evaluates and passes the shellcheck baked into `writeShellApplication`.

**Step 1: Parse the optional flag before the session id**

Replace the current arg block (lines 99–109):

```bash
    if [ $# -ne 1 ]; then
      log "usage: oc-auto-attach <session-id>"
      exit 0
    fi
    sid="$1"

    # Hard-validate session id before any shell interpolation.
    if ! [[ "$sid" =~ ^ses_[A-Za-z0-9]+$ ]]; then
      log "invalid session id: $sid"
      exit 0
    fi
```

with:

```bash
    # Optional leading --tmux-session <name>: confine all pane discovery and
    # window creation to that one tmux session (create it detached if absent).
    # Used by background callers (lgtm) so launches never steal the user's
    # focus -- the user isn't attached to that session during normal work.
    target_session=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --tmux-session)
          if [ $# -lt 2 ] || [ -z "$2" ]; then
            log "--tmux-session requires a name"
            exit 0
          fi
          target_session="$2"
          shift 2
          ;;
        --tmux-session=*)
          target_session="''${1#--tmux-session=}"
          shift
          ;;
        *)
          break
          ;;
      esac
    done

    if [ $# -ne 1 ]; then
      log "usage: oc-auto-attach [--tmux-session <name>] <session-id>"
      exit 0
    fi
    sid="$1"

    # Hard-validate session id before any shell interpolation.
    if ! [[ "$sid" =~ ^ses_[A-Za-z0-9]+$ ]]; then
      log "invalid session id: $sid"
      exit 0
    fi

    # Validate the tmux session name (tmux forbids '.' and ':'; this also
    # blocks any shell-interpolation hazard).
    if [ -n "$target_session" ] && ! [[ "$target_session" =~ ^[A-Za-z0-9_-]+$ ]]; then
      log "invalid tmux session name: $target_session"
      exit 0
    fi
    [ -n "$target_session" ] && log "confining to tmux session: $target_session"
```

**Step 2: Scope the pane scan to the target session**

Replace the scan loop's source (line 188):

```bash
    done < <(tmux list-panes -a -F '#{pane_id}|#{pane_current_command}|#{pane_current_path}' 2>/dev/null || true)
```

with a branch on `target_session`. Change the loop to read from a variable:

Before the `while IFS='|' read -r p_id p_cmd p_path; do` line (line 177), add:

```bash
    # Source of panes to scan: the whole tmux server (-a) by default, or just
    # the confined session (-s -t =<name>) when --tmux-session was given.
    if [ -n "$target_session" ]; then
      panes_src="$(tmux list-panes -s -t "=$target_session" -F '#{pane_id}|#{pane_current_command}|#{pane_current_path}' 2>/dev/null || true)"
    else
      panes_src="$(tmux list-panes -a -F '#{pane_id}|#{pane_current_command}|#{pane_current_path}' 2>/dev/null || true)"
    fi
```

and change the loop terminator (line 188) from the process substitution to:

```bash
    done <<< "$panes_src"
```

**Step 3: Add a confined-session create branch**

In the `if [ -n "$pane_id" ]; then … else … fi` block (lines 190–258), insert a
new `elif [ -n "$target_session" ]; then` branch between the match-log `if` and
the existing current-session `else`. The structure becomes:

```bash
    if [ -n "$pane_id" ]; then
      log "matched existing pane $pane_id (cmd=$pane_cmd)"
    elif [ -n "$target_session" ]; then
      # Confined-session create path: no pane matched inside $target_session,
      # so make a window there (creating the session itself if needed). We
      # deliberately skip the "are we inside tmux?" bail and the by-name
      # defense-in-depth scan used by the default path -- the -s scan above
      # already covered every window in this session, and new-session will
      # start a tmux server if none exists.
      if ! nvims_path="$(resolve_nvims)"; then
        log "nvims not resolvable (neither OC_NVIMS_BIN nor PATH); skipping"
        exit 0
      fi
      log "resolved nvims at $nvims_path"
      if tmux has-session -t "=$target_session" 2>/dev/null; then
        pane_id="$(tmux new-window -d -P -F '#{pane_id}' \
          -t "$target_session:" -c "$project_key" -n "$window_name" -- "$nvims_path" 2>/dev/null || true)"
      else
        pane_id="$(tmux new-session -d -P -F '#{pane_id}' \
          -s "$target_session" -c "$project_key" -n "$window_name" -- "$nvims_path" 2>/dev/null || true)"
      fi
      if [ -z "$pane_id" ]; then
        log "tmux window/session create failed in $target_session; giving up"
        exit 0
      fi
      pane_cmd="nvim"
      log "created pane $pane_id in session $target_session (window $window_name)"
    else
      # ... EXISTING current-session create path stays exactly as-is ...
```

Leave everything from the existing `else` (the `if [ -z "''${TMUX:-}" ]` bail
through the `tmux new-window` create) and all of Steps 3.5–6 **unchanged**.
`classify_pane`, `select-window`, the socket wait, and the nvim RPC are reused
verbatim — they are harmless when acting on a session the user isn't attached to.

**Step 4: Build to verify it evaluates + passes shellcheck**

Run: `cd ~/projects/workstation && nix build .#oc-auto-attach --no-link`
Expected: builds successfully (the shellcheck baked into `writeShellApplication`
passes). If shellcheck flags the `<<< "$panes_src"` herestring or anything else,
fix per its message and rebuild.

**Step 5: Commit**

```bash
cd ~/projects/workstation
git add pkgs/oc-auto-attach/default.nix
git commit -m "feat(oc-auto-attach): --tmux-session confines attach to one session"
```

---

## Task 2: `opencode-launch` — add `--tmux-session` flag and forward it

**Files:**
- Modify: `users/dev/home.base.nix` (the `opencode-launch` `writeShellApplication`, lines 7–208)

**Step 1: Add the flag to `usage()`**

In `usage()` (after the `--mcp` line, ~line 26), add:

```bash
        echo "  --tmux-session <name>          Confine auto-attach to a dedicated tmux session"
```

**Step 2: Declare the variable and parse the flag**

Add near the other state vars (after `mcp_servers=()`, ~line 49):

```bash
      tmux_session=""
```

In the option-parsing `while` loop, add two cases (alongside `--mcp` / `--mcp=*`):

```bash
          --tmux-session)
            if [ $# -lt 2 ] || [ -z "$2" ]; then
              echo "Error: --tmux-session requires a name" >&2
              exit 1
            fi
            tmux_session="$2"
            shift 2
            ;;
          --tmux-session=*)
            tmux_session="''${1#--tmux-session=}"
            if [ -z "$tmux_session" ]; then
              echo "Error: --tmux-session requires a name" >&2
              exit 1
            fi
            shift
            ;;
```

**Step 3: Forward it to the auto-attach spawn**

Replace the auto-attach block (lines 198–200):

```bash
      if command -v oc-auto-attach >/dev/null 2>&1; then
        setsid nohup oc-auto-attach "$session_id" </dev/null >>/tmp/oc-auto-attach.log 2>&1 & disown
      fi
```

with:

```bash
      if command -v oc-auto-attach >/dev/null 2>&1; then
        oc_attach_args=()
        if [ -n "$tmux_session" ]; then
          oc_attach_args+=(--tmux-session "$tmux_session")
        fi
        # ''${arr[@]+"...} guards the empty-array expansion under `set -u`.
        setsid nohup oc-auto-attach ''${oc_attach_args[@]+"''${oc_attach_args[@]}"} "$session_id" </dev/null >>/tmp/oc-auto-attach.log 2>&1 & disown
      fi
```

**Step 4: Build to verify**

`opencode-launch` is defined inline in `home.base.nix`, and cloudbox uses
*standalone* home-manager (not a NixOS module), so build the home activation
package — that evaluates the `opencode-launch` derivation and runs its shellcheck:

Run: `cd ~/projects/workstation && nix build .#homeConfigurations.cloudbox.activationPackage --no-link`
Expected: builds successfully (shellcheck on `opencode-launch` passes).

**Step 5: Commit**

```bash
cd ~/projects/workstation
git add users/dev/home.base.nix
git commit -m "feat(opencode-launch): add --tmux-session flag, forward to oc-auto-attach"
```

---

## Task 3: lgtm — pass `--tmux-session lgtm` for dispatch and gather

**Files:**
- Modify: `~/projects/lgtm/src/dispatch.ts`
- Modify: `~/projects/lgtm/src/gather.ts`
- Test: `~/projects/lgtm/tests/dispatch.test.ts`, `~/projects/lgtm/tests/gather.test.ts`

**Step 1: Update the dispatch test to expect the new arg (failing test)**

In `tests/dispatch.test.ts`, change the `buildDispatchArgs` expectation
(lines 17–23) to:

```ts
    expect(buildDispatchArgs("/tmp/worktree")).toEqual([
      "--model",
      "google-vertex-anthropic/claude-opus-4-8@default",
      "--tmux-session",
      "lgtm",
      "--",
      "/tmp/worktree",
      expect.stringContaining(".lgtm-review-prompt.md"),
    ]);
```

**Step 2: Run it; verify it fails**

Run: `cd ~/projects/lgtm && npx vitest run tests/dispatch.test.ts -t buildDispatchArgs`
Expected: FAIL (actual array lacks `--tmux-session`/`lgtm`).

**Step 3: Implement — add the constant and the args in dispatch.ts**

In `src/dispatch.ts`, add a constant near the other top-level consts (~line 11):

```ts
/** tmux session that lgtm-launched OpenCode sessions are confined to, so
 * background launches never steal the user's nvim/tmux focus. Torn down by
 * the nightly reset (and `tmux kill-session -t lgtm`). */
export const LGTM_TMUX_SESSION = "lgtm";
```

Change `buildDispatchArgs` (lines 53–55) to:

```ts
export function buildDispatchArgs(worktreeDir: string): string[] {
  return [
    "--model", REVIEW_MODEL,
    "--tmux-session", LGTM_TMUX_SESSION,
    "--", worktreeDir, READ_PROMPT_INSTRUCTION,
  ];
}
```

**Step 4: Run; verify dispatch test passes**

Run: `cd ~/projects/lgtm && npx vitest run tests/dispatch.test.ts -t buildDispatchArgs`
Expected: PASS.

**Step 5: Update the gather test (failing test)**

In `tests/gather.test.ts`, change the `buildGatherArgs` expectation
(lines 85–93) to:

```ts
    expect(buildGatherArgs("/tmp/wt")).toEqual([
      "--model",
      "google-vertex/gemini-3.5-flash",
      "--mcp",
      "slack-ro",
      "--tmux-session",
      "lgtm",
      "--",
      "/tmp/wt",
      expect.stringContaining(".lgtm-gather-prompt.md"),
    ]);
```

**Step 6: Run it; verify it fails**

Run: `cd ~/projects/lgtm && npx vitest run tests/gather.test.ts -t buildGatherArgs`
Expected: FAIL.

**Step 7: Implement — use the shared constant in gather.ts**

In `src/gather.ts`, extend the existing dispatch import (line 6) to include the
constant:

```ts
import { parseLaunchOutput, LGTM_TMUX_SESSION } from "./dispatch.js";
```

Change `buildGatherArgs` (lines 110–112) to:

```ts
export function buildGatherArgs(worktreeDir: string): string[] {
  return [
    "--model", GATHER_MODEL,
    "--mcp", "slack-ro",
    "--tmux-session", LGTM_TMUX_SESSION,
    "--", worktreeDir, READ_GATHER_PROMPT_INSTRUCTION,
  ];
}
```

**Step 8: Run the full suite + typecheck**

Run: `cd ~/projects/lgtm && npx vitest run && npx tsc --noEmit`
Expected: all tests PASS, no type errors.

**Step 9: Commit**

```bash
cd ~/projects/lgtm
git add src/dispatch.ts src/gather.ts tests/dispatch.test.ts tests/gather.test.ts
git commit -m "feat: confine lgtm OpenCode launches to a dedicated 'lgtm' tmux session"
```

---

## Task 4: Roll out and verify end-to-end

**Files:** none (deploy + manual verification)

**Step 1: Apply the workstation changes on cloudbox**

Run: `cd ~/projects/workstation && nix run home-manager -- switch --flake .#cloudbox`
Expected: switches; `oc-auto-attach` and `opencode-launch` on PATH are the new versions.
Verify: `opencode-launch --help` shows the `--tmux-session` line.

**Step 2: Manual end-to-end — focus is NOT stolen, drawer session appears**

While attached to your normal working tmux session (with at least one nvim open
via `nvims`), in a shell run:

```bash
opencode-launch --tmux-session scratch ~/projects/workstation "echo hi from a confined launch"
```

Verify:
1. Your tmux client is **NOT** switched to another window, and your nvim tab
   does **not** change.
2. A tmux session named `scratch` now exists: `tmux ls | grep scratch`.
3. That session has a window with an `opencode attach` tab:
   `tmux list-windows -t scratch` and `tmux capture-pane -t scratch -p | head`.
4. `/tmp/oc-auto-attach.log` shows `confining to tmux session: scratch` and the
   created-pane line.

Cleanup: `tmux kill-session -t scratch`.

**Step 3: Backward-compat check**

Run: `opencode-launch ~/projects/workstation "echo hi default path"`
Expected: attaches into your **current** session exactly as before (you may be
switched to it — that's the unchanged interactive behavior).
Cleanup: kill the session via the printed `curl ... DELETE` line.

**Step 4: Deploy lgtm**

Rebuild/redeploy lgtm and restart its daemon so the new arg builders take
effect (follow lgtm's normal deploy: `cd ~/projects/lgtm && npm run build` then
restart the lgtm service/daemon).

**Step 5: Live verification with a real lgtm dispatch**

Trigger (or wait for) one lgtm review cycle. Verify:
1. You are not yanked out of your work.
2. The review session lands in the `lgtm` tmux session: `tmux ls | grep '^lgtm'`.
3. `/tmp/oc-auto-attach.log` shows `confining to tmux session: lgtm`.

**Step 6: Push both repos**

```bash
cd ~/projects/workstation && git pull --rebase && git push && git status
cd ~/projects/lgtm && git pull --rebase && git push && git status
```
Expected: both show "up to date with origin".
