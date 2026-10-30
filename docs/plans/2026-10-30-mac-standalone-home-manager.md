# Mac: standalone home-manager, ahead of losing local admin

**Goal:** after IT removes local admin from the Mac, every *user-level* change
(dotfiles, skills, opencode config, plugins, launchd agents, activation hooks)
must still deploy with no root. Only *system* changes (nix.conf, /etc/bashrc,
/etc/shells, login shell, nix-daemon, sudoers) need an Admin By Request window.

**Architecture:** home-manager stops being a nix-darwin module on the Mac and
becomes a standalone `homeConfigurations.Y0FMQX93RR-2`, exactly like devbox and
cloudbox. `home-switch` (unprivileged) deploys it; `darwin-switch` keeps doing
`sudo darwin-rebuild switch` for the system only. nix-darwin also gains
`nix.gc` / `nix.optimise` root daemons so system generations are collected with
no human sudo.

## What changes

| Piece | Before | After |
|---|---|---|
| Home config | `home-manager.users.<user>` inside `darwinConfigurations.Y0FMQX93RR-2` | `homeConfigurations.Y0FMQX93RR-2` (standalone) |
| User packages | `/etc/profiles/per-user/$USER` (`useUserPackages`) | `~/.nix-profile` -> `~/.local/state/nix/profiles/profile` |
| `config.home.profileDirectory` | `/etc/profiles/per-user/$USER` | `~/.nix-profile` |
| Deploy user config | `darwin-switch` (sudo) | `home-switch` (no sudo) |
| Deploy system config | `darwin-switch` (sudo) | `darwin-switch` (sudo -> Admin By Request) |
| HM generation tracking | `~/.local/state/home-manager/gcroots/current-home` only | same gcroot, plus the `home-manager` profile |
| System generation GC | manual `sudo nix-collect-garbage` | `nix.gc` launchd daemon (weekly, >30d) + `nix.optimise` |
| Package set | nix-darwin's pkgs (`useGlobalPkgs`) | `darwinHomePkgs`: same nixpkgs, same two overlays (cloudflared, setproctitle) |

Hardcoded references to the old per-user profile that had to move:
- opencode serve launchd PATH (`home.darwin.nix`) -> `config.home.profileDirectory`.
  Without this, every serve's `exec opencode` fails once `/etc/profiles/per-user/$USER`
  disappears.
- `scripts/update-ssh-config.sh` `GCLOUD_BIN` (bakes the IAP ProxyCommand into
  `~/.ssh/config`) -> prefers `~/.nix-profile/bin/gcloud`. The generated
  `~/.ssh/config` must be regenerated during migration.

## Why the cutover is safe in this order

Verified against the pinned home-manager / nix-darwin sources:

- HM finds the *previous* generation through
  `~/.local/state/home-manager/gcroots/current-home`, which module mode keeps
  current. So the first standalone switch diffs against the module-mode
  generation: home files it owned are replaced without "would be clobbered"
  errors, and launchd plists that changed are booted out and re-bootstrapped.
- Plists whose content does not change are left running. Most agents reference
  store paths that are identical in both modes (same nixpkgs + overlays); the
  ones that change are those that embed `profileDirectory` (gcloud-reauth x3,
  opencode-serve-N) and anything whose script closure changed.
- `/etc/bashrc`'s PATH already has `$HOME/.nix-profile/bin` **before**
  `/etc/profiles/per-user/$USER/bin`, so between steps 2 and 4 below the new
  profile wins wherever both exist.
- When the system no longer sets `users.users.<user>.packages`, nix-darwin
  stops generating `/etc/profiles/per-user/$USER` and its etc activation deletes
  the stale link; `environment.profiles` drops the entry too.
- The boot-time `org.nixos.activate-system` daemon does **not** run HM
  activation, so a reboot between steps cannot revert anything.

## One-time migration (the human runs this)

Run from a **plain Terminal/iTerm window, not from inside opencode**: step 2
restarts the opencode serve launchd agents (their PATH changes), which would
kill the session driving it.

```bash
cd ~/Code/workstation && git pull --ff-only

# 1. Record the current (module-mode) HM and system generations, for rollback.
readlink ~/.local/state/home-manager/gcroots/current-home | tee ~/.hm-module-generation
readlink /nix/var/nix/profiles/system | tee ~/.darwin-module-generation   # e.g. system-184-link

# 2. NO ROOT. Build + activate standalone home-manager. Seeds cfp first.
nix run ~/Code/workstation#home-switch

# 3. NO ROOT. Regenerate ~/.ssh/config so the IAP ProxyCommand points at
#    ~/.nix-profile/bin/gcloud instead of /etc/profiles/per-user/$USER/bin/gcloud
#    (which step 4 deletes).
bash ~/Code/workstation/scripts/update-ssh-config.sh
grep -c 'profiles/per-user' ~/.ssh/config   # want 0

# 4. ADMIN BY REQUEST WINDOW. System switch without the HM module; also
#    installs the nix-gc / nix-optimise daemons.
darwin-switch

#    Same window, OPTIONAL but needed for remote repair from cloudbox: Remote
#    Login (sshd) is currently DISABLED on this Mac, and enabling it needs root.
#    The cutover tunnel targets :22. Only if IT policy allows it:
#      sudo launchctl enable system/com.openssh.sshd
#      sudo launchctl bootstrap system /System/Library/LaunchDaemons/ssh.plist
#      launchctl print-disabled system | grep sshd   # want => enabled
#    (`systemsetup -setremotelogin on` fails under sudo without Full Disk
#    Access for the terminal. Done 2026-10-30; left on.)

# 5. Verify (no root). Open NEW shells first (or `hash -r` in old ones): bash
#    caches command paths under /etc/profiles/per-user/..., which step 4
#    deleted, so old tmux panes / nvim terminals print "No such file".
test ! -e /etc/profiles/per-user/$USER && echo "per-user profile gone (good)"
readlink ~/.nix-profile; command -v opencode gcloud home-switch
launchctl print gui/$(id -u)/org.nix-community.home.opencode-serve-0 | grep -E 'state|pid'
sudo launchctl list | grep -E 'nix-gc|nix-optimise'   # optional, needs the window
home-switch                                             # idempotent second run, no sudo
```

Steps 2-3 need no elevation and can be done before requesting the window;
only step 4 needs it. Keep 2 -> 4 close together: until step 4, the old system
generation still contains the HM module, and any `darwin-rebuild` of an *older*
checkout would re-activate module-mode HM over the standalone one (recoverable
by running `home-switch` again).

## Rollback

- **After step 2, before step 4 (no root):** re-activate the module-mode
  generation recorded in step 1. Its `installPackages` step removes the
  standalone `home-manager-path` from `~/.nix-profile`, and its plists point back
  at `/etc/profiles/per-user/$USER`, which still exists at this point.
  ```bash
  "$(cat ~/.hm-module-generation)/activate"
  ```
  Then re-run `scripts/update-ssh-config.sh` if you ran step 3.
- **After step 4 (Admin By Request window):** switch the system back to the
  generation recorded in step 1, which re-runs module-mode HM activation and
  recreates `/etc/profiles/per-user/$USER`. Use the recorded number, not
  `--rollback`: that only goes back one generation, which is wrong after any
  later system deploy (e.g. flipping the remote-root toggle).
  ```bash
  gen="$(sed 's/^system-\([0-9]*\)-link$/\1/' ~/.darwin-module-generation)"
  sudo darwin-rebuild --switch-generation "$gen"
  bash ~/Code/workstation/scripts/update-ssh-config.sh
  ```
  `nix.gc` deletes system generations older than 30 days, so this is available
  for roughly a month after the migration. Do not run a manual
  `sudo nix-collect-garbage --delete-older-than <shorter>` before you are sure.

## Verification done in the PR

- `nix flake check --keep-going` on the Mac, which builds the new
  `checks.aarch64-darwin.{home-mac,darwin-system}`. The Linux CI leg cannot
  build or even fully evaluate them (devenv's darwin package is
  import-from-derivation of darwin-only drvs); it still evaluates the Mac's
  home config for `bazelrc-disk-cache-tests`.
- Built `darwinConfigurations.Y0FMQX93RR-2.system` and
  `homeConfigurations.Y0FMQX93RR-2.activationPackage`.
- Diffed the old module-mode generation's `LaunchAgents` and `home-files`
  against the new standalone generation.
