# Devbox reset-workspace nightly parity Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Bring devbox to cloudbox parity for the nightly workspace reset + Telegram recommendation flow, so live interactive opencode TUIs are wiped/curated nightly (keeping process ages < 24h) instead of being surprise-`kill -9`'d mid-use by the 6-hourly `reap-stale-opencode` reaper.

**Architecture:** Two edits. (1) Make the *shared* `pkgs/reset-workspace/default.nix` step-5 serve restart host-aware — prefer `systemctl --user` when opencode-serve is a user unit (devbox), else keep the existing passwordless-sudo system-unit path (cloudbox). (2) Replace devbox's `nightly-restart-background` body (currently a bare serve+pigeon restart) with `reset-workspace --yes` run as `User=dev`, preceded by a `pigeon-daemon` restart so the recommendation session registers with a fresh daemon.

**Tech Stack:** Nix (`writeShellApplication`, NixOS systemd units), bash, systemd (user + system managers), opencode-serve HTTP API, pigeon Telegram bridge.

**Beads:** workstation-uqyu

---

## Background / confirmed facts (do not re-derive)

- **Incident (2026-06-16 12:30):** `reap-stale-opencode` (every 6h at :30) `kill -9`'d 3 interactive TUIs flagged "26h old". Branch `hosts/devbox/configuration.nix:379-389` kills interactive sessions purely on process age, no activity check. NOT OOM (memory was 78-88% free throughout).
- **Why parity fixes it:** cloudbox's nightly `reset-workspace` SIGKILLs all TUIs at 3 AM, so no interactive TUI ever reaches 24h → reaper degrades to a backstop for forgotten headless workers. Devbox's nightly only restarts serve, so TUIs age until the reaper kills them.
- **devbox nvim is disposable** (user-confirmed: purely an opencode-tab host) → nightly `pkill -9 nvim` is safe.
- **devbox serve = USER unit** (`~/.config/systemd/user/opencode-serve.service`), healthy on `127.0.0.1:4096`, restartable as `dev` via `systemctl --user` (no sudo). No system `opencode-serve` unit exists.
- **cloudbox serve = SYSTEM unit** (`hosts/cloudbox/configuration.nix:490`) → on cloudbox `systemctl --user is-active opencode-serve.service` returns non-zero → detection falls through to the existing sudo path. **Cloudbox behavior is unchanged.**
- **devbox passwordless sudo** (`security.sudo.wheelNeedsPassword = false`, devbox/configuration.nix:740); **linger=yes**, `XDG_RUNTIME_DIR=/run/user/1000` → the script's `systemd-run --user --scope` re-exec works when run as `User=dev`.
- **pigeon-daemon = SYSTEM unit on both hosts**; Telegram/question bridge = shared `opencode-pigeon.ts` plugin (`opencode-config.nix:218`) → recommendation round-trip works on devbox. `reset-workspace`, `oc-auto-attach`, `opencode-launch` already on devbox PATH. `main` tmux session present.

## Out of scope

- The narrow `reap-stale-opencode` activity-check fix (alternative the user did not pick). The reaper stays as-is on both hosts as a backstop.
- Stale opencode DB session pruning (tracked separately upstream of this work).

## Design decision: pigeon-daemon restart (both hosts)

Devbox's current nightly restarts `pigeon-daemon` (memory hygiene); cloudbox did not. **Decision (user-confirmed): keep the pigeon restart, move it BEFORE `reset-workspace`, and add the same restart to cloudbox** so both hosts are symmetric. Ordering pigeon-first ensures the recommendation session (spawned last, inside `reset-workspace`) registers with a fresh daemon; restarting pigeon AFTER the session spawns would drop its Telegram routing. Both hosts have passwordless sudo and pigeon-daemon is a system unit on both, so `/run/wrappers/bin/sudo systemctl restart pigeon-daemon.service` works as `User=dev` on each.

---

### Task 1: Make `reset-workspace` step-5 serve restart host-aware

**Files:**
- Modify: `pkgs/reset-workspace/default.nix:312-322` (the `# ---- Step 5: Restart opencode-serve ----` block)

**Step 1: Replace the restart block**

Current (lines 312-322):

```sh
    # ---- Step 5: Restart opencode-serve ----
    log "restarting opencode-serve.service..."
    # Passwordless sudo works via wheel group + security.sudo.wheelNeedsPassword=false (set in hosts/cloudbox/configuration.nix).
    # Use absolute path /run/wrappers/bin/sudo because:
    #   1. NixOS ships the working setuid sudo at /run/wrappers/bin/sudo.
    #   2. /run/current-system/sw/bin/sudo is a non-setuid symlink that
    #      sudo itself refuses to exec from. systemd units with restricted
    #      PATH won't find the wrapper unless explicitly named.
    if ! /run/wrappers/bin/sudo systemctl restart opencode-serve.service; then
      die "failed to restart opencode-serve"
    fi
```

New:

```sh
    # ---- Step 5: Restart opencode-serve ----
    # Host-aware restart. opencode-serve runs as a USER unit on devbox
    # (~/.config/systemd/user/opencode-serve.service; restart via
    # `systemctl --user`, no sudo) and as a SYSTEM unit on cloudbox
    # (hosts/cloudbox/configuration.nix; restart via passwordless sudo).
    # Prefer the user unit when it is active so this shared script is
    # portable. On cloudbox there is no user opencode-serve unit, so
    # `is-active --quiet` returns non-zero and we fall through to the
    # original sudo path (cloudbox behavior unchanged).
    log "restarting opencode-serve.service..."
    if systemctl --user is-active --quiet opencode-serve.service; then
      log "  opencode-serve is a user unit; restarting via systemctl --user"
      if ! systemctl --user restart opencode-serve.service; then
        die "failed to restart opencode-serve (user unit)"
      fi
    else
      # Passwordless sudo works via wheel group + security.sudo.wheelNeedsPassword=false.
      # Use absolute path /run/wrappers/bin/sudo because NixOS ships the working
      # setuid sudo there; /run/current-system/sw/bin/sudo is a non-setuid symlink
      # sudo refuses to exec from.
      log "  opencode-serve is a system unit; restarting via sudo"
      if ! /run/wrappers/bin/sudo systemctl restart opencode-serve.service; then
        die "failed to restart opencode-serve (system unit)"
      fi
    fi
```

**Step 2: Verify the Nix file still parses**

Run: `nix-instantiate --parse pkgs/reset-workspace/default.nix > /dev/null && echo "PARSE OK"`
Expected: `PARSE OK`

**Step 3: Build the package for this host**

Run: `nix build --no-link --print-out-paths .#packages.aarch64-linux.reset-workspace 2>&1 | tail -3`
Expected: prints a `/nix/store/...-reset-workspace` path, no errors. (devbox is aarch64 — a Hetzner ARM/CAX instance.)

**Step 4: Confirm the built script contains both branches**

Run: `STORE=$(nix build --no-link --print-out-paths .#packages.aarch64-linux.reset-workspace 2>/dev/null) && rg -n 'systemctl --user is-active --quiet opencode-serve|opencode-serve is a system unit' "$STORE/bin/reset-workspace"`
Expected: two matching lines.

**Step 5: Commit**

```bash
git add pkgs/reset-workspace/default.nix
git commit -m "feat(reset-workspace): host-aware opencode-serve restart (user vs system unit)

Prefer 'systemctl --user restart opencode-serve.service' when serve is a
user unit (devbox); fall back to the existing passwordless-sudo system-unit
path (cloudbox). Enables devbox to run reset-workspace as its nightly reset.

Refs workstation-uqyu"
```

---

### Task 2: Point devbox `nightly-restart-background` at reset-workspace

**Files:**
- Modify: `hosts/devbox/configuration.nix:276-299` (the `nightly-restart-background` service + timer)

**Step 1: Replace the service definition**

Current service (276-290):

```nix
  # Daily 3 AM restart of leaky long-running services.
  # opencode-serve leaks from ~350 MB to 8-13 GB over days.
  systemd.services.nightly-restart-background = {
    description = "Restart long-running background services to reclaim leaked memory";
    serviceConfig.Type = "oneshot";
    script = ''
      # opencode-serve is a USER service now (see users/dev/home.devbox.nix).
      # Restart it in the dev user manager via the machine transport. This
      # oneshot runs as root, which can reach user@1000 even with an empty
      # environment (verified: `systemctl --user -M dev@.host ...`). Linger
      # keeps user@1000.service up so the manager is always reachable.
      /run/current-system/sw/bin/systemctl --user -M dev@.host restart opencode-serve.service
      /run/current-system/sw/bin/systemctl restart pigeon-daemon.service
    '';
  };
```

New (mirrors cloudbox/configuration.nix:693-707, plus a pigeon restart first):

```nix
  # Daily 3 AM workspace reset (cloudbox parity). reset-workspace snapshots
  # live opencode TUIs in the `main` tmux session, SIGKILLs all nvims,
  # restarts opencode-serve (leaks ~350 MB -> 8-13 GB over days), and spawns a
  # headless recommendation session that Telegrams which sessions to reopen.
  # devbox nvim is disposable (an opencode-tab host only), so the SIGKILL is
  # safe. Wiping TUIs nightly also keeps interactive process ages < 24h, so the
  # reap-stale-opencode reaper never surprise-kills a live interactive session.
  #
  # Runs as User=dev so reset-workspace's `systemd-run --user --scope` re-exec
  # and `systemctl --user restart opencode-serve.service` work (serve is a USER
  # unit on devbox; linger keeps user@1000 up). pigeon-daemon (a SYSTEM unit) is
  # restarted FIRST via passwordless sudo so the recommendation session, spawned
  # last inside reset-workspace, registers with a fresh daemon.
  systemd.services.nightly-restart-background = {
    description = "Nightly workspace reset (kill nvims, restart opencode-serve, recommend)";
    serviceConfig = {
      Type = "oneshot";
      User = "dev";
      Group = "dev";
      Environment = [
        "TMUX_TMPDIR=/tmp"
        "PATH=/run/current-system/sw/bin:/home/dev/.nix-profile/bin"
      ];
    };
    script = ''
      /run/wrappers/bin/sudo systemctl restart pigeon-daemon.service
      /home/dev/.nix-profile/bin/reset-workspace --yes
    '';
  };
```

(The timer block at 292-299 is unchanged — `OnCalendar = "*-*-* 03:00:00"`, `Persistent = true`.)

**Step 2: Verify the devbox configuration evaluates**

Run: `nix eval .#nixosConfigurations.devbox.config.systemd.services.nightly-restart-background.description`
Expected: `"Nightly workspace reset (kill nvims, restart opencode-serve, recommend)"`

**Step 3: Confirm the unit will run as dev**

Run: `nix eval --raw .#nixosConfigurations.devbox.config.systemd.services.nightly-restart-background.serviceConfig.User`
Expected: `dev`

**Step 4: Commit**

```bash
git add hosts/devbox/configuration.nix
git commit -m "feat(devbox): nightly-restart-background runs reset-workspace (cloudbox parity)

Replace the bare serve+pigeon restart with reset-workspace --yes run as
User=dev, preceded by a pigeon-daemon restart. Wipes/curates TUIs nightly so
the reap-stale-opencode reaper no longer surprise-kills live interactive
sessions (incident 2026-06-16). devbox nvim is disposable.

Refs workstation-uqyu"
```

---

### Task 2b: Add pigeon-daemon restart to cloudbox nightly (symmetry)

**Files:**
- Modify: `hosts/cloudbox/configuration.nix:704-706` (the `script` of `nightly-restart-background`)

**Step 1: Prepend the pigeon restart**

Current:

```nix
    script = ''
      /home/dev/.nix-profile/bin/reset-workspace --yes
    '';
```

New:

```nix
    script = ''
      # Restart pigeon-daemon (system unit) FIRST so the recommendation
      # session spawned inside reset-workspace registers with a fresh daemon.
      # Symmetric with devbox (hosts/devbox/configuration.nix).
      /run/wrappers/bin/sudo systemctl restart pigeon-daemon.service
      /home/dev/.nix-profile/bin/reset-workspace --yes
    '';
```

**Step 2: Verify cloudbox config still evaluates**

Run: `nix eval --raw .#nixosConfigurations.cloudbox.config.systemd.services.nightly-restart-background.serviceConfig.User`
Expected: `dev`

**Note:** This host's rebuild is on cloudbox, not devbox. The change lands in the repo on push; it takes effect on cloudbox's next `sudo nixos-rebuild switch --flake .#cloudbox`. Not applied from this session.

---

### Task 3: Apply the system change (user-gated)

**Non-destructive to apply.** `nixos-rebuild switch` installs the new unit definition; it does NOT fire the timer. The first real run is tonight at 3 AM (or a manual trigger in Task 4). The rebuild itself will not reset the workspace.

**Step 1: Rebuild devbox**

Run: `sudo nixos-rebuild switch --flake .#devbox 2>&1 | tail -20`
Expected: `... switching to configuration ...` then activation success, no errors.

**Step 2: Verify the new unit + timer are loaded**

Run: `systemctl cat nightly-restart-background.service | rg -n 'User=|reset-workspace|pigeon'` and `systemctl list-timers nightly-restart-background --no-pager`
Expected: `User=dev`, the `reset-workspace --yes` + pigeon lines; timer shows next fire at 03:00.

**Step 3: Apply the home-manager change for the new reset-workspace binary**

The host-aware `reset-workspace` is installed via home-manager (home.base.nix).

Run: `nix run home-manager -- switch --flake .#dev 2>&1 | tail -15` then `rg -c 'opencode-serve is a system unit' "$(command -v reset-workspace)"`
Expected: activation success; `1` (new binary on PATH).

---

### Task 4: End-to-end exercise (EXPLICITLY user-gated — destructive)

**WARNING:** Triggering the service now runs a full reset: it SIGKILLs all `dev` nvims and restarts opencode-serve, which tears down/reconnects **every** live TUI on the box — including this session and any other active session. Do NOT run automatically. Only run when the user explicitly opts in and is ready to lose current tabs, or just wait for the 3 AM run.

**Step 1 (opt-in): Trigger without a pty so the orchestrator's TUI drop doesn't SIGHUP it**

Run: `sudo systemctl --no-block start nightly-restart-background.service`
(The bash tool may report "User aborted" as the TUI's TCP connection drops — that is expected, not a failure.)

**Step 2: Inspect the journal after serve comes back**

Run: `journalctl -u nightly-restart-background.service --since "-5 min" --no-pager | rg '\[reset-workspace\]|captured|wrote|launching recommendation|WARNING|FATAL'`
Expected: the snapshot summary (`captured N restorable session(s) ...`), `wrote N sid(s) to /tmp/reset-workspace-last-manifest.txt`, and `launching recommendation session in ~ ...`. No `FATAL`. A Telegram message should arrive with reopen recommendations.

**Step 3: Confirm serve is healthy and the manifest was written**

Run: `curl -sf --max-time 3 http://127.0.0.1:4096/global/health >/dev/null && echo HEALTHY; wc -l < /tmp/reset-workspace-last-manifest.txt`
Expected: `HEALTHY`; a sid count.

---

## Rollback

- Revert the two commits (`git revert`), `sudo nixos-rebuild switch --flake .#devbox`, `nix run home-manager -- switch --flake .#dev`. devbox returns to the bare serve+pigeon nightly restart. The shared reset-workspace change is backward-compatible with cloudbox, so a partial rollback (devbox config only) is also safe.

## Verification before "done"

- `nix-instantiate --parse` + `nix build` of reset-workspace pass (Task 1).
- `nix eval` of devbox config returns expected User/description (Task 2).
- Rebuild + home-manager switch succeed; new unit and binary present (Task 3).
- (Optional, user-gated) End-to-end journal shows snapshot + recommendation spawn, serve healthy (Task 4).
- `bd close workstation-uqyu` once the rebuild lands and (if exercised) Task 4 is green.
