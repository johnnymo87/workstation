# reset-workspace Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans (or superpowers:subagent-driven-development) to implement this plan task-by-task.

**Goal:** A single command, `reset-workspace`, that tears down all nvims and opencode sessions, restarts opencode-serve, and brings nvims back up as `nvims`. Replace the existing `nightly-restart-background` 3 AM serve-only restart with this command running on the same timer.

**Architecture:** A `writeShellApplication` (`pkgs/reset-workspace/default.nix`) following the same pattern as `pkgs/oc-auto-attach/`. Cloudbox systemd unit `nightly-restart-background` is repurposed to invoke `reset-workspace --yes`. A NixOS sudoers rule grants passwordless `systemctl restart opencode-serve` to user `dev` so the same command works for both manual and nightly invocations.

**Tech Stack:** Bash (writeShellApplication), tmux CLI, systemd units, NixOS `security.sudo.extraRules`.

**Authoritative design:** `docs/plans/2026-04-24-reset-workspace-design.md`

---

## Pre-flight: Verification spikes

Before writing any package code, verify these primitives behave as the design assumes. **STOP and discuss if any spike fails.**

### Spike 1: `pkill -9 -u dev -x nvim` actually kills bare nvim and the nvim --embed pair

**Why:** Each interactive nvim is actually two processes: a TTY frontend (`nvim --cmd ... --embed`) and an embedded server (`nvim --embed`). `-x` matches only `nvim` exactly (not `nvim --embed`).

**Run:**
```bash
ps -u dev -o pid,comm,args | grep -E '\bnvim\b' | grep -v grep | head -10
```

Expected: see your 5 nvim panes, each with a `nvim` (frontend) AND `nvim --embed` (server). The frontend's `comm` field is `nvim`, the server's `comm` is `nvim`.

Then test the kill match (don't actually kill — use `pgrep` first):
```bash
pgrep -u dev -x nvim
```

Expected: PIDs of every nvim process (both frontends and embeds). If `-x nvim` matches only frontends, the embeds will become orphans and tmux panes won't return to bash. If that's what we see, switch to `pkill -9 -u dev -f '^/nix/store/.*/nvim '` or similar.

### Spike 2: Polling `pane_current_command` after a kill

**Why:** Step 3 polls until each pane's command transitions away from `nvim`. Confirm this attribute updates after the process dies.

**Run (DRY — pick ONE pane to test, restore after):**
```bash
PANE=%23  # the cul pane, pick a low-stakes one
ORIG_DIR=$(tmux display-message -t "$PANE" -p '#{pane_current_path}')
echo "before: $(tmux display-message -t "$PANE" -p '#{pane_current_command}')"
tmux send-keys -t "$PANE" C-\\ C-n ":qa!" Enter
for i in $(seq 1 50); do
  CMD=$(tmux display-message -t "$PANE" -p '#{pane_current_command}')
  echo "$i: $CMD"
  [ "$CMD" = "bash" ] && break
done
# restore
tmux send-keys -t "$PANE" "cd $ORIG_DIR && nvim" Enter
```

Expected: see `nvim → bash` transition within ~10 polls (sub-second).

### Spike 3: `tmux send-keys` from a non-tmux context (systemd unit simulation)

**Why:** The nightly run has no `$TMUX`. Confirm we can drive tmux by setting socket explicitly.

**Run:**
```bash
unset TMUX
tmux -S /tmp/tmux-1000/default list-panes -a -F '#{pane_id} #{window_name}' | head -3
```

Expected: see your 5 panes. If "no server running on /tmp/tmux-1000/default" — your tmux socket lives elsewhere; investigate `ls -la /tmp/tmux-*` and adjust the design's `TMUX_TMPDIR` value.

### Spike 4: Curl DELETE works on opencode sessions

**Why:** Step 4 deletes all sessions. Confirm the API exists and works.

**Run (pick the oldest session, the "Greeting" one is harmless):**
```bash
SESSION_ID=$(curl -sf http://127.0.0.1:4096/session | jq -r '.[] | select(.title == "Greeting") | .id')
echo "deleting $SESSION_ID"
curl -sf -X DELETE "http://127.0.0.1:4096/session/$SESSION_ID" -o /dev/null -w '%{http_code}\n'
curl -sf http://127.0.0.1:4096/session | jq -r '.[].id' | grep -c "$SESSION_ID"
```

Expected: HTTP 200 from DELETE, count 0 from the verify (session is gone).

### Spike 5: Passwordless sudo for `systemctl restart opencode-serve`

**Why:** Both manual and nightly invocations need this to work without prompting. Verify the sudoers rule format works on this NixOS.

**Run (just check current state — don't add the rule yet, that's Task 7):**
```bash
sudo -n -l 2>&1 | grep opencode || echo "no rule yet (expected)"
```

Expected: "no rule yet (expected)". This is just baseline confirmation.

After Task 7, this command should show the rule.

---

## Task 1: Package skeleton + manifest snapshot

**Goal:** Create `pkgs/reset-workspace/default.nix` with the `writeShellApplication` skeleton, argument parsing (`--yes`), and the tmux manifest snapshot. No destructive actions yet.

**Files:**
- Create: `pkgs/reset-workspace/default.nix`
- Modify: `flake.nix:53-62` (add `reset-workspace = p.callPackage ./pkgs/reset-workspace { };` to `localPkgsFor`)
- Modify: `users/dev/home.base.nix:212-216` (add `localPkgs.reset-workspace` to `home.packages`)

**Step 1: Write the package**

Create `pkgs/reset-workspace/default.nix`:

```nix
{ pkgs }:

pkgs.writeShellApplication {
  name = "reset-workspace";
  runtimeInputs = with pkgs; [
    curl
    jq
    tmux
    procps         # pkill, pgrep
    util-linux     # flock
    coreutils      # timeout
  ];
  text = ''
    # reset-workspace [--yes]
    #
    # Tear down all nvims and opencode sessions, restart opencode-serve,
    # bring nvims back up as `nvims`. See:
    # docs/plans/2026-04-24-reset-workspace-design.md
    #
    # --yes  Skip the confirmation prompt (used by the nightly systemd unit).

    OPENCODE_URL="''${OPENCODE_URL:-http://127.0.0.1:4096}"
    YES=0

    log() {
      printf '[reset-workspace] %s\n' "$*" >&2
    }

    die() {
      log "FATAL: $*"
      exit 1
    }

    # Parse args
    while [ $# -gt 0 ]; do
      case "$1" in
        --yes|-y) YES=1; shift ;;
        --help|-h)
          cat <<EOF
Usage: reset-workspace [--yes]

Tear down all nvims and opencode sessions, restart opencode-serve,
bring nvims back up as \`nvims\`.

  --yes, -y    Skip the confirmation prompt.
EOF
          exit 0
          ;;
        *) die "unknown arg: $1 (try --help)" ;;
      esac
    done

    # ---- Step 1: Snapshot tmux manifest ----
    log "snapshotting tmux panes running nvim/nvims..."
    MANIFEST=$(tmux list-panes -a \
      -F '#{pane_id}'$'\t''#{window_name}'$'\t''#{pane_current_command}'$'\t''#{pane_current_path}' \
      | awk -F'\t' '$3 == "nvim" || $3 == "nvims" { print }')

    if [ -z "$MANIFEST" ]; then
      log "no nvim/nvims panes found"
      MANIFEST_COUNT=0
    else
      MANIFEST_COUNT=$(printf '%s\n' "$MANIFEST" | wc -l)
      log "found $MANIFEST_COUNT nvim/nvims pane(s):"
      printf '%s\n' "$MANIFEST" | while IFS=$'\t' read -r pane window cmd path; do
        log "  $pane  $window  ($cmd)  $path"
      done
    fi

    log "(Tasks 2-7 not yet implemented — exiting)"
  '';
}
```

**Step 2: Wire into flake.nix**

Edit `flake.nix` line 59 area, add `reset-workspace` alphabetically after `oc-cost`:

```nix
    localPkgsFor = system: let p = pkgsFor system; in {
      acli = p.callPackage ./pkgs/acli { };
      beads = p.callPackage ./pkgs/beads { };
      gclpr = p.callPackage ./pkgs/gclpr { };
      gws = p.callPackage ./pkgs/gws { };
      nvims = p.callPackage ./pkgs/nvims { };
      oc-auto-attach = p.callPackage ./pkgs/oc-auto-attach { };
      oc-cost = p.callPackage ./pkgs/oc-cost { };
      reset-workspace = p.callPackage ./pkgs/reset-workspace { };  # NEW
      self-compact-plugin = p.callPackage ./pkgs/self-compact-plugin { };
    };
```

**Step 3: Add to home.packages**

In `users/dev/home.base.nix` around line 216 (the existing `localPkgs.oc-auto-attach` line):

```nix
    localPkgs.nvims
    localPkgs.oc-auto-attach
    localPkgs.reset-workspace   # NEW
```

**Step 4: Git-add and apply**

```bash
cd ~/projects/workstation
git add pkgs/reset-workspace/ flake.nix users/dev/home.base.nix
nix run home-manager -- switch --flake .#cloudbox 2>&1 | tail -20
```

Expected: home-manager switch succeeds, no errors.

**Step 5: Smoke test the skeleton**

```bash
reset-workspace --help
reset-workspace
```

Expected from `--help`: usage block prints, exits 0.
Expected from no-arg: `[reset-workspace] snapshotting...` then a list of your 5 panes (workstation/mono/salmon/lgtm/cul) then `[reset-workspace] (Tasks 2-7 not yet implemented — exiting)`. Exit 0.

**Step 6: Commit**

```bash
git commit -m "feat(reset-workspace): scaffold package + tmux manifest snapshot"
```

---

## Task 2: Confirmation prompt

**Goal:** After the manifest snapshot, print what's about to happen and prompt `[y/N]`. `--yes` skips.

**Files:**
- Modify: `pkgs/reset-workspace/default.nix` (insert before the "Tasks 2-7 not yet implemented" log line)

**Step 1: Insert the confirmation block**

After the manifest log block, before the `(Tasks 2-7 not yet implemented)` line, add:

```bash
    # ---- Step 2: Confirm with user ----
    SESSION_COUNT=$(curl -sf "$OPENCODE_URL/session" 2>/dev/null | jq -r 'length' 2>/dev/null || echo "?")
    log ""
    log "About to:"
    log "  1. SIGKILL $MANIFEST_COUNT nvim/nvims process(es)"
    log "  2. DELETE $SESSION_COUNT opencode session(s) via HTTP API"
    log "  3. Restart opencode-serve.service (this Claude session's TUI will reconnect)"
    log "  4. Respawn nvims in $MANIFEST_COUNT pane(s)"
    log ""

    if [ "$YES" -ne 1 ]; then
      printf '[reset-workspace] Continue? [y/N] ' >&2
      read -r REPLY
      case "$REPLY" in
        [yY]|[yY][eE][sS]) ;;
        *) die "aborted by user" ;;
      esac
    else
      log "(--yes: skipping confirmation)"
    fi
```

**Step 2: Smoke test interactive**

```bash
reset-workspace
```

Expected: manifest prints, then "About to:" block, then "Continue? [y/N]". Type `n`, see "FATAL: aborted by user", exit 1. Type `y`, see "(Tasks 3-7 not yet implemented — exiting)".

**Step 3: Smoke test --yes**

```bash
reset-workspace --yes
```

Expected: manifest prints, "About to:" block, "(--yes: skipping confirmation)", "(Tasks 3-7...)".

**Step 4: Commit**

```bash
git add pkgs/reset-workspace/default.nix
git commit -m "feat(reset-workspace): confirmation prompt + --yes flag"
```

---

## Task 3: Kill nvims + poll panes back to bash

**Goal:** `pkill -9` all nvim processes, then poll each manifest pane until its `pane_current_command` is no longer `nvim`/`nvims`.

**Files:**
- Modify: `pkgs/reset-workspace/default.nix`

**Step 1: Insert the kill+poll block**

After the confirmation block, before the "Tasks 3-7" log line, add:

```bash
    # ---- Step 3: Kill all nvims ----
    if [ "$MANIFEST_COUNT" -gt 0 ]; then
      log "killing all nvim/nvims processes (SIGKILL)..."
      # Use -f to match the full command line so we catch both `nvim` (TTY
      # frontend) and `nvim --embed` (the embedded server). Anchor on the
      # nix store path to avoid matching unrelated processes.
      if pkill -9 -u dev -f '^/nix/store/[a-z0-9]+-neovim[^/]*/bin/nvim' 2>/dev/null; then
        log "  pkill returned matches"
      else
        log "  pkill returned no matches (none running, or already dead)"
      fi

      # Poll each pane until its current command is no longer nvim/nvims.
      log "polling panes for return to shell..."
      printf '%s\n' "$MANIFEST" | while IFS=$'\t' read -r pane _window _cmd _path; do
        DEADLINE=$(($(date +%s) + 10))
        while [ "$(date +%s)" -lt "$DEADLINE" ]; do
          CUR=$(tmux display-message -t "$pane" -p '#{pane_current_command}' 2>/dev/null || echo "GONE")
          if [ "$CUR" = "GONE" ]; then
            log "  $pane: pane no longer exists (skipping)"
            break
          fi
          if [ "$CUR" != "nvim" ] && [ "$CUR" != "nvims" ]; then
            log "  $pane: now running $CUR"
            break
          fi
          # Sub-second poll without sleep (per AGENTS.md no-sleep policy)
          read -t 0.1 -r _ < <(:) 2>/dev/null || true
        done
        if [ "$(date +%s)" -ge "$DEADLINE" ]; then
          log "  $pane: WARNING — still running $CUR after 10s"
        fi
      done
    fi
```

**Step 2: Spike-test `pkill -f` carefully BEFORE running on real workspace**

This is the highest-risk step. `pkill -f` with the wrong regex could kill unrelated processes. Verify the regex matches what we expect AND ONLY what we expect:

```bash
# Dry run: list matches, don't kill
pgrep -u dev -af '^/nix/store/[a-z0-9]+-neovim[^/]*/bin/nvim'
```

Expected: see ~10 PIDs (5 frontends + 5 embeds), all neovim. Nothing else.

If the regex matches anything you don't recognize, **STOP** and adjust before continuing.

**Step 3: Smoke test on a SINGLE throwaway pane first (NOT your real workspace)**

```bash
# Open a fresh tmux window for testing
tmux new-window -d -n reset-test -c /tmp 'nvim'
sleep 0.5
tmux list-panes -a -F '#{pane_id} #{window_name} #{pane_current_command}' | grep reset-test
# Note the pane_id, e.g., %42

# Now run reset-workspace and confirm with `y`. It will kill ALL nvims
# including your real ones. To test JUST the throwaway, temporarily edit
# the script to filter MANIFEST to only the test pane, OR proceed knowing
# the real nvims will die too (Task 6 will respawn them).
```

**Recommended approach:** skip the throwaway test, proceed directly to a real run. Tasks 6+7 will respawn everything. If something goes wrong, you can manually `nvims` in each pane.

**Step 4: Run reset-workspace and confirm**

```bash
reset-workspace
```

Type `y`. Expected:
- "killing all nvim/nvims processes (SIGKILL)..."
- "pkill returned matches"
- "polling panes for return to shell..."
- For each of your 5 panes: `%N: now running bash`
- Then `(Tasks 4-7 not yet implemented)` and exit 0.

After exit, your tmux windows should all show bash prompts. To recover, in each window: `nvims` Enter (until Task 6 lands).

**Step 5: Commit**

```bash
git add pkgs/reset-workspace/default.nix
git commit -m "feat(reset-workspace): SIGKILL all nvims and poll panes to shell"
```

---

## Task 4: Delete all opencode sessions

**Goal:** Loop through `GET /session`, DELETE each. Tolerate empty list and 404s.

**Files:**
- Modify: `pkgs/reset-workspace/default.nix`

**Step 1: Insert the delete block**

After the kill+poll block, add:

```bash
    # ---- Step 4: Delete all opencode sessions ----
    log "fetching opencode session list..."
    if ! IDS=$(curl -sf "$OPENCODE_URL/session" 2>/dev/null | jq -r '.[].id' 2>/dev/null); then
      log "  WARNING: failed to fetch session list (serve may be down)"
      IDS=""
    fi

    if [ -z "$IDS" ]; then
      log "  no sessions to delete"
    else
      DELETED=0
      FAILED=0
      while IFS= read -r id; do
        if curl -sf -X DELETE "$OPENCODE_URL/session/$id" -o /dev/null; then
          DELETED=$((DELETED + 1))
        else
          FAILED=$((FAILED + 1))
          log "  WARNING: failed to delete $id"
        fi
      done <<< "$IDS"
      log "  deleted $DELETED session(s), $FAILED failure(s)"
    fi
```

**Step 2: Smoke test**

```bash
reset-workspace --yes
```

Expected: kill block runs (your nvims die again — recover with `nvims` after), then `[reset-workspace] fetching opencode session list...`, then `deleted N session(s), 0 failure(s)`. Verify:

```bash
curl -sf http://127.0.0.1:4096/session | jq -r 'length'
```

Expected: 0 (or very low — anything that's been created since the delete).

**Step 3: Commit**

```bash
git add pkgs/reset-workspace/default.nix
git commit -m "feat(reset-workspace): delete all opencode sessions via HTTP API"
```

---

## Task 5: Restart opencode-serve + health check

**Goal:** `sudo systemctl restart opencode-serve`, then poll `/global/health` until 200. Note: this task assumes the sudoers rule isn't yet in place — manual smoke tests will prompt for password. Task 7 fixes that.

**Files:**
- Modify: `pkgs/reset-workspace/default.nix`

**Step 1: Insert the restart+poll block**

After the delete block, add:

```bash
    # ---- Step 5: Restart opencode-serve ----
    log "restarting opencode-serve.service..."
    if ! sudo systemctl restart opencode-serve.service; then
      die "failed to restart opencode-serve"
    fi

    log "polling /global/health for serve readiness..."
    DEADLINE=$(($(date +%s) + 30))
    while [ "$(date +%s)" -lt "$DEADLINE" ]; do
      if curl -sf "$OPENCODE_URL/global/health" >/dev/null 2>&1; then
        log "  serve healthy"
        break
      fi
      read -t 0.5 -r _ < <(:) 2>/dev/null || true
    done
    if ! curl -sf "$OPENCODE_URL/global/health" >/dev/null 2>&1; then
      die "opencode-serve did not become healthy within 30s"
    fi
```

**Step 2: Smoke test (will prompt for sudo password)**

```bash
reset-workspace --yes
```

Expected: kill, delete, then `restarting opencode-serve.service...`, sudo password prompt, then `polling /global/health...`, then `serve healthy`. Total time ~5–15s for serve restart.

**WARNING:** this WILL drop the HTTP connection this Claude session uses. The TUI will reconnect automatically. If you're driving this from a Claude session, expect a brief flicker.

**Step 3: Commit**

```bash
git add pkgs/reset-workspace/default.nix
git commit -m "feat(reset-workspace): restart opencode-serve and poll for health"
```

---

## Task 6: Respawn nvims in each pane

**Goal:** For each pane in the manifest, `tmux send-keys "nvims" Enter`. Use the original pane_current_path (don't assume cwd was preserved through the kill).

**Files:**
- Modify: `pkgs/reset-workspace/default.nix`

**Step 1: Insert the respawn block**

After the serve-restart block, add:

```bash
    # ---- Step 6: Respawn nvims in each manifest pane ----
    if [ "$MANIFEST_COUNT" -gt 0 ]; then
      log "respawning nvims in $MANIFEST_COUNT pane(s)..."
      printf '%s\n' "$MANIFEST" | while IFS=$'\t' read -r pane _window _cmd path; do
        # Verify pane still exists
        if ! tmux display-message -t "$pane" -p '#{pane_id}' >/dev/null 2>&1; then
          log "  $pane: pane no longer exists, skipping respawn"
          continue
        fi
        # cd to original path, then nvims. Single send-keys to keep it atomic.
        tmux send-keys -t "$pane" "cd $path && nvims" Enter
        log "  $pane: sent 'cd $path && nvims'"
      done
    fi
```

**Step 2: Smoke test**

```bash
reset-workspace --yes
```

Expected: full sequence ending with respawn block. After the script exits, switch to each tmux window — each should be running `nvims` in its original directory. Verify the sockets:

```bash
ls -la /tmp/nvim-*.sock
```

Expected: 5 sockets (one per pane), each owned by `dev`.

**Step 3: Commit**

```bash
git add pkgs/reset-workspace/default.nix
git commit -m "feat(reset-workspace): respawn nvims in each manifest pane"
```

---

## Task 7: Verify sockets + sudoers rule + flock

**Goal:** Add the verify-sockets step to the script, the NixOS sudoers rule for passwordless serve restart, and flock the script body to prevent concurrent runs.

**Files:**
- Modify: `pkgs/reset-workspace/default.nix` (add verify step + flock)
- Modify: `hosts/cloudbox/configuration.nix` (sudoers rule)

**Step 1: Insert verify-sockets block at end of script**

After the respawn block, add:

```bash
    # ---- Step 7: Verify nvim sockets exist ----
    if [ "$MANIFEST_COUNT" -gt 0 ]; then
      log "verifying nvim sockets..."
      DEADLINE=$(($(date +%s) + 5))
      MISSING=""
      printf '%s\n' "$MANIFEST" | while IFS=$'\t' read -r pane _window _cmd _path; do
        # pane_id is %N — strip the %
        SOCK="/tmp/nvim-''${pane#%}.sock"
        # Re-poll until found or deadline (sockets appear within ~1s typically)
        while [ "$(date +%s)" -lt "$DEADLINE" ]; do
          [ -S "$SOCK" ] && break
          read -t 0.2 -r _ < <(:) 2>/dev/null || true
        done
        if [ -S "$SOCK" ]; then
          log "  $pane: socket $SOCK ✓"
        else
          log "  $pane: WARNING — socket $SOCK missing"
        fi
      done
    fi

    log "reset-workspace complete"
```

Also remove the old `(Tasks N-7 not yet implemented)` log line if any remains.

**Step 2: Wrap the script body in flock**

The `writeShellApplication` script is already a self-contained bash. We add flock by re-exec'ing the script under flock at the very top of the body (right after argument parsing, before the snapshot step):

```bash
    # ---- Concurrency: re-exec under flock if not already locked ----
    LOCK="/tmp/reset-workspace.lock"
    if [ "''${RESET_WORKSPACE_LOCKED:-}" != "1" ]; then
      export RESET_WORKSPACE_LOCKED=1
      exec flock -n "$LOCK" "$0" "$@" || die "another reset-workspace is running (lock $LOCK held)"
    fi
```

Place this AFTER the `while [ $# -gt 0 ]` arg parsing but BEFORE the snapshot step. The `exec` replaces the current process with itself under flock; on the second entry, `RESET_WORKSPACE_LOCKED=1` so we skip the re-exec and proceed.

**Step 3: Add the sudoers rule to cloudbox**

Edit `hosts/cloudbox/configuration.nix`. Find a logical place (near other `security.sudo` config if it exists, otherwise near the bottom of the file before the closing `}`):

```nix
  # Allow user `dev` to restart opencode-serve without a password.
  # Used by reset-workspace (both manual invocation and the nightly
  # systemd timer). See docs/plans/2026-04-24-reset-workspace-design.md.
  security.sudo.extraRules = [{
    users = [ "dev" ];
    commands = [{
      command = "/run/current-system/sw/bin/systemctl restart opencode-serve.service";
      options = [ "NOPASSWD" ];
    }];
  }];
```

**Step 4: Apply both changes**

```bash
cd ~/projects/workstation
git add pkgs/reset-workspace/default.nix hosts/cloudbox/configuration.nix
sudo nixos-rebuild switch --flake .#cloudbox 2>&1 | tail -20
nix run home-manager -- switch --flake .#cloudbox 2>&1 | tail -10
```

Expected: both succeed.

**Step 5: Verify sudoers rule**

```bash
sudo -n systemctl status opencode-serve --no-pager | head -3
```

Expected: prints status WITHOUT prompting for password.

**Step 6: End-to-end smoke test (no password prompt this time)**

```bash
reset-workspace --yes
```

Expected: full sequence runs with NO password prompt. Final output includes verify block with all 5 sockets `✓`.

**Step 7: Test concurrency**

In one tmux pane, run `reset-workspace --yes`. While it's running (in the kill or restart phase), in another pane:

```bash
reset-workspace --yes
```

Expected: second invocation immediately exits with "FATAL: another reset-workspace is running".

**Step 8: Commit**

```bash
git add pkgs/reset-workspace/default.nix hosts/cloudbox/configuration.nix
git commit -m "feat(reset-workspace): verify sockets + flock + sudoers rule"
```

---

## Task 8: Repurpose nightly-restart-background

**Goal:** Change the systemd unit to invoke `reset-workspace --yes` instead of just restarting opencode-serve.

**Files:**
- Modify: `hosts/cloudbox/configuration.nix:393-410` (the `nightly-restart-background` service + timer blocks)

**Step 1: Edit the service block**

Replace the current `nightly-restart-background` service block with:

```nix
  # Nightly workspace reset (3 AM). Replaces the previous serve-only
  # restart with a full workspace reset (kill nvims, clear opencode
  # sessions, restart opencode-serve, respawn nvims). The serve restart
  # still happens — that was the original purpose (memory hygiene) — but
  # now it's bundled with the rest of the reset.
  #
  # Runs as user `dev` so it can drive the user's tmux server.
  # Passwordless `systemctl restart opencode-serve` is granted via
  # security.sudo.extraRules.
  systemd.services.nightly-restart-background = {
    description = "Nightly workspace reset (kill nvims, restart opencode-serve, respawn)";
    serviceConfig = {
      Type = "oneshot";
      User = "dev";
      Group = "dev";
      Environment = [
        "TMUX_TMPDIR=/tmp/tmux-1000"
        "PATH=/run/current-system/sw/bin:/home/dev/.nix-profile/bin"
      ];
    };
    script = ''
      /home/dev/.nix-profile/bin/reset-workspace --yes
    '';
  };
```

The timer block (lines 403–410) stays unchanged.

**Step 2: Apply**

```bash
cd ~/projects/workstation
git add hosts/cloudbox/configuration.nix
sudo nixos-rebuild switch --flake .#cloudbox 2>&1 | tail -20
```

Expected: succeeds.

**Step 3: Test the unit by starting it manually (don't wait for 3 AM)**

```bash
sudo systemctl start nightly-restart-background.service
journalctl -u nightly-restart-background.service -n 50 --no-pager
```

Expected in the journal: the full `[reset-workspace]` log sequence — snapshot, "(--yes: skipping confirmation)", kill, delete, restart, respawn, verify. Exit code 0.

After the unit completes, verify your nvims are alive:

```bash
tmux list-panes -a -F '#{pane_id} #{window_name} #{pane_current_command}' | grep nvim
```

Expected: 5 panes running `nvims`.

```bash
ls -la /tmp/nvim-*.sock
```

Expected: 5 sockets.

**Step 4: Verify the timer is still scheduled for 3 AM**

```bash
systemctl list-timers nightly-restart-background --no-pager
```

Expected: NEXT shows tomorrow at 03:00:00 EDT.

**Step 5: Commit**

```bash
git add hosts/cloudbox/configuration.nix
git commit -m "feat(cloudbox): nightly-restart-background now runs reset-workspace --yes

Replaces the serve-only 3 AM restart with a full workspace reset:
kill all nvims, delete all opencode sessions, restart opencode-serve,
respawn nvims with their listening sockets. The serve restart still
happens (memory hygiene was the original point), but now it's part
of a coherent reset rather than the only action."
```

---

## Task 9: Documentation

**Goal:** Add a skill describing reset-workspace, and link it from the main workstation AGENTS.md skills table.

**Files:**
- Create: `.opencode/skills/resetting-workspace/SKILL.md`
- Modify: `AGENTS.md` (add to skills table)

**Step 1: Write the skill**

Create `.opencode/skills/resetting-workspace/SKILL.md`:

```markdown
---
name: resetting-workspace
description: Use when the user wants a fresh start on cloudbox — kill all nvims, clear stale opencode sessions, restart opencode-serve. Also documents the nightly 3 AM autonomous reset.
---

# Resetting the Workspace

`reset-workspace` is a single command that fully resets the cloudbox dev environment.

## What it does (in order)

1. Snapshots the tmux panes currently running `nvim`/`nvims`.
2. Confirms with the user (skip with `--yes`).
3. SIGKILLs all `nvim` processes owned by `dev`.
4. DELETEs every opencode session via the HTTP API.
5. Restarts `opencode-serve.service` (passwordless sudo).
6. Respawns `nvims` in each manifest pane (with original cwd).
7. Verifies each `/tmp/nvim-${PANE#%}.sock` exists.

Concurrent runs are blocked by `flock /tmp/reset-workspace.lock`.

## When to use

- After landing changes to `nvims`, `oc-auto-attach`, or anything else that needs a fresh process to take effect.
- When opencode-serve has bloated past ~6 GB (memory hygiene).
- When the auto-attach plumbing is misbehaving and you want a known-good baseline.

## Nightly autonomous run

`systemd.services.nightly-restart-background` invokes `reset-workspace --yes` at 3 AM EDT daily. It runs as user `dev` with `TMUX_TMPDIR=/tmp/tmux-1000`.

To inspect:
```bash
systemctl list-timers nightly-restart-background
journalctl -u nightly-restart-background.service --since today
```

To trigger early (any time):
```bash
sudo systemctl start nightly-restart-background.service
```

## Caveats

- This Claude session's TUI will reconnect when serve restarts. Brief flicker.
- All in-flight headless opencode workers (e.g., spawned via `opencode-launch` or pigeon `/launch`) will be killed when their session is deleted. Don't run during important headless work.
- nvim is treated as disposable — no graceful quit, no `:wa`. By design (cloudbox nvim is purely a host for opencode tabs).

## Related

- Design: `docs/plans/2026-04-24-reset-workspace-design.md`
- Plan: `docs/plans/2026-04-24-reset-workspace-plan.md`
- Companion skill: `.opencode/skills/automated-updates/SKILL.md` (other timer-driven jobs).
```

**Step 2: Link from AGENTS.md**

In `/home/dev/projects/workstation/AGENTS.md`, find the skills table (around line ~120). Add a row alphabetically:

```markdown
| [Resetting Workspace](.opencode/skills/resetting-workspace/SKILL.md) | Manual + nightly cloudbox reset (kill nvims, clear sessions, restart serve) |
```

**Step 3: Commit**

```bash
cd ~/projects/workstation
git add .opencode/skills/resetting-workspace/ AGENTS.md
git commit -m "docs(skills): document reset-workspace and nightly autonomous reset"
```

---

## Task 10: End-to-end verification + push

**Goal:** Run the full reset, verify everything works, push both pending commits to origin.

**Files:** none modified

**Step 1: Run reset-workspace --yes one more time end-to-end**

```bash
reset-workspace --yes
```

Watch the output carefully. Expected:
- Snapshot: 5 panes
- Confirmation skipped
- Kill: 5 panes return to bash within seconds
- Delete: N sessions deleted, 0 failures
- Restart: serve healthy within 15s
- Respawn: 5 panes get `nvims`
- Verify: 5 sockets ✓
- "reset-workspace complete"

**Step 2: Confirm everything is functional post-reset**

```bash
# All 5 sockets exist
ls /tmp/nvim-*.sock | wc -l   # Expected: 5

# opencode-serve is healthy
curl -sf http://127.0.0.1:4096/global/health | jq

# Sessions are clean
curl -sf http://127.0.0.1:4096/session | jq 'length'   # Expected: 0 or low

# nvim panes are running nvims (not bare nvim)
tmux list-panes -a -F '#{pane_id} #{pane_current_command}' | grep -c nvims   # Expected: 5
```

**Step 3: Test auto-attach against the freshly-reset workspace**

```bash
opencode-launch ~/projects/workstation "echo hello from auto-attach test"
```

Expected: within ~5 seconds, a new tab appears in the workstation tmux window's nvim. Check `/tmp/oc-auto-attach.log`:

```bash
tail -10 /tmp/oc-auto-attach.log
```

Expected: NO "nvim at /tmp/nvim-1.sock not ready" warning. Instead: "tab opened in pane %1 for ses_..."

**Step 4: Push**

```bash
cd ~/projects/workstation
git pull --rebase
git push
git status   # Expected: "up to date with origin/main"
```

**Step 5: Verify the timer is still scheduled**

```bash
systemctl list-timers nightly-restart-background --no-pager
```

Expected: NEXT = tomorrow 03:00:00 EDT, UNIT = `nightly-restart-background.service`.

**Done.** The next 3 AM run will exercise the full path autonomously. If it fails, check `journalctl -u nightly-restart-background --since today` in the morning.

---

## Risk register

| What could go wrong | How we'd catch it | Recovery |
|---|---|---|
| `pkill -f` regex matches non-nvim processes | Spike 1 verifies regex matches ONLY neovim | Adjust regex, retest |
| nvim panes don't return to bash within 10s timeout | Step 3's poll loop logs WARNING per pane | Manual recovery: `tmux send-keys -t %N C-c "nvims" Enter` |
| Sudoers rule syntax wrong | `nixos-rebuild switch` fails fast | Fix syntax, retry |
| opencode-serve doesn't come back healthy in 30s | Script exits non-zero with clear error | `journalctl -u opencode-serve`, fix, manually `sudo systemctl restart opencode-serve` |
| flock contention bug (script can't re-acquire its own lock) | Concurrency test in Task 7 Step 7 | Remove flock, fall back to a touch-file check |
| Nightly run can't drive tmux (wrong socket path) | Step 3 of Task 8 starts the unit manually | Adjust `TMUX_TMPDIR`, redeploy |
| User runs reset-workspace from a tmux pane that's IN the manifest | Pane gets killed mid-execution; script aborts | Recovery: re-run `reset-workspace` from a different pane |

The last one is interesting — if you run `reset-workspace` from inside one of the nvim panes you're about to kill, the script gets killed. **Mitigation:** the script's parent shell is `bash`, not `nvim`, so killing nvim doesn't kill the script. Verified by tmux's pane-current-command behavior — only the foreground process is killed, not the pane's whole process tree. Should be fine, but worth testing in Task 7 Step 7.
