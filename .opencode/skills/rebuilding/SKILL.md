---
name: rebuilding
description: How to apply configuration changes to NixOS hosts (devbox, cloudbox). Use when you need to rebuild the system, apply home-manager changes, or recover from issues.
---

# Rebuilding NixOS Hosts

## CRITICAL: Identify the Host First

**Before running ANY rebuild command, you MUST determine which machine you are on:**

```bash
cat /etc/hostname
```

This returns `devbox`, `cloudbox`, or another hostname. **Use the matching flake target.** Applying the wrong target overwrites system identity, secrets paths, and service configs — and can brick the machine.

There are NixOS activation guards that will abort if you use the wrong target, but **do not rely on them as a substitute for checking first.**

## Flake Targets

| Hostname | System rebuild | Home-manager |
|----------|---------------|--------------|
| `devbox` | `sudo nixos-rebuild switch --flake .#devbox` | `home-manager switch --flake .#dev` |
| `cloudbox` | `sudo nixos-rebuild switch --flake .#cloudbox` | `home-manager switch --flake .#cloudbox` |

**macOS** uses `sudo darwin-rebuild switch --flake .#Y0FMQX93RR-2` (system + home combined).

## Applying Changes

### System Changes (requires sudo)

After editing files in `hosts/<hostname>/`:

```bash
cd ~/projects/workstation
hostname=$(cat /etc/hostname)
sudo nixos-rebuild switch --flake ".#$hostname"
```

This rebuilds the NixOS system. May require reboot if kernel changed.

> **WARNING (cloudbox):** `nixos-rebuild switch` updates `opencode-frontdoor` on disk but does **NOT** restart the running process (`restartIfChanged = false`). Run `sudo systemctl restart opencode-frontdoor` afterward or the door keeps serving OLD code. See [Deploy Runbook: Front Door & Serve Pool](#deploy-runbook-front-door--serve-pool).

### User Changes (no sudo, fast)

After editing files in `users/dev/` or `assets/`:

```bash
cd ~/projects/workstation
hostname=$(cat /etc/hostname)
# devbox uses #dev, cloudbox uses #cloudbox
if [ "$hostname" = "devbox" ]; then
  home-manager switch --flake .#dev
else
  home-manager switch --flake ".#$hostname"
fi
```

This is fast (~10 seconds).

> **WARNING (cloudbox):** `home-manager switch` repoints `/home/dev/.nix-profile/bin/opencode` but does **NOT** restart active serve units (`restartIfChanged = false`). Run `sudo systemctl restart opencode-serve-pool.target` afterward or serves keep running OLD code in version drift. See [Deploy Runbook: Front Door & Serve Pool](#deploy-runbook-front-door--serve-pool).

## Deploy Runbook: Front Door & Serve Pool

When deploying updates that affect `opencode-frontdoor` or the `opencode-serve@` pool (e.g. on `cloudbox`), explicit service restarts are **REQUIRED**.

### Canonical Deploy Sequence

```bash
sudo nixos-rebuild switch --flake ".#$(hostname)"   # installs new door binary, rewrites unit
sudo systemctl restart opencode-frontdoor           # REQUIRED: door does NOT self-restart
home-manager switch --flake .#cloudbox              # installs new opencode into /home/dev/.nix-profile
sudo systemctl restart opencode-serve-pool.target   # REQUIRED: serves do NOT self-restart
```

### Why Explicit Restarts Are Required (`restartIfChanged = false`)

Both `opencode-frontdoor` and `opencode-serve@` are configured with `restartIfChanged = false` in `hosts/cloudbox/configuration.nix`.

This design is **deliberate**:
- Restarting `opencode-frontdoor` drops active SSE connections and resets sticky session routing maps.
- Restarting `opencode-serve-pool.target` terminates running worker sessions.

Because neither service self-restarts on rebuild, `nixos-rebuild switch` and `home-manager switch` update binary files and unit definitions on disk while **leaving old processes running in version drift**.

**Past Production Incidents (2026-07-24):**
- **Stale serves (`reset-workspace` skipped pool restart):** Front door routed new session-scoped paths, but stale serves returned HTML SPA fallbacks. The attach TUI threw when trying to JSON-parse HTML and reconnected infinitely, resulting in a frozen TUI.
- **Stale door (`nixos-rebuild` ran without restart):** Front door binary was updated on disk but process wasn't restarted. The MCP dialog returned 404 through the door for ~70 minutes until `opencode-frontdoor` was restarted.

**Third incident, 2026-07-26 — and the reason this section was not enough.**
Arming pigeon's auth token (`workstation-dx8p`) 503ed every mutating request
through the door: `nixos-rebuild` installed the new door build, the old process
kept running, sent no bearer, was 401ed by a freshly-armed pigeon, and classified
it `pigeon-error`. Typed prompts failed across live TUIs until a human restarted
the door. The `home-manager switch` step was omitted too, so `opencode-launch`
and `oc-auto-attach` had no token support at all.

**The canonical sequence above was already correct and already written here. It
was not consulted** — a bespoke runbook was written in a plan file instead. If you
are about to write deploy steps for cloudbox, use this section rather than
composing your own.

> ### The rationalization that defeats this section
>
> The design in question resolved the token **at call time** specifically so that
> no restart would be needed — and that reasoning is *correct in steady state*
> and **wrong for the deploy that ships it.** Call-time resolution only helps a
> process already running the call-time code, and that code arrived in the same
> rebuild.
>
> **A mechanism that removes a deployment constraint cannot remove it for the
> deployment that introduces the mechanism.** Read every "this makes restarts
> unnecessary" claim as "…starting with the deployment *after* this one."
>
> The question that catches it: **which processes are running the OLD code at the
> moment the switch flips?** With `restartIfChanged = false`, the answer is
> always "the door and every serve," no matter how clever the new code is.

**Do not count on the nightly reset to clear door drift.** `reset-workspace`
restarts `opencode-serve-pool.target` only. Verified 2026-07-27: after the 03:00
reset, serves showed `ActiveEnterTimestamp` 03:01:13 and pigeon 03:00:10, while
the door still read 22:53:30 — the previous evening's *manual* restart. A stale
serve pool self-heals overnight; **a stale door does not, and will keep serving
old code indefinitely.**

### Checking for Version Drift

Note: Drift alerting is **cloudbox-only**; devbox runs the same serve pool with the same deliberate no-bounce and has no drift detection (deliberately deferred — no front door exists on devbox, so there is no cross-service version skew class).

**Front Door Drift:**
The canary checks `/healthz` against unit `ExecStart` every 60s (`WARNING: version drift: running=... execstart=...`) and raises a throttled Telegram alert via pigeon. Check manually with:
```bash
journalctl -u opencode-frontdoor-canary --since today | grep -i drift
```

**Serve Pool Drift:**
Compare the store path of the running serve process against the active nix profile:
```bash
readlink /proc/$(systemctl show opencode-serve@4096 -p MainPID --value)/exe   # running process
readlink -f /home/dev/.nix-profile/bin/opencode                               # profile target
```
Mismatched `/nix/store/<hash>-...` prefixes indicate stale serve processes requiring a pool restart (`sudo systemctl restart opencode-serve-pool.target`).

## Verifying a Nix-Built Script Before You Deploy It

Canaries, alert helpers, and activation scripts are shell embedded in Nix (`pkgs.writeShellScript`, `''…''` strings). Nix transforms that text before it ever runs, and **the source reads correctly while the built artifact is broken**. Reasoning about the source is not verification.

**Rule: test the built artifact against real recorded input.** For a canary, that means replaying an actual incident timeline, not one synthetic call.

This caught a live near-miss on 2026-07-27. A fix for the alert-escalation bug read its retry counter with `sed -n 2p`, but the script pins `PATH` to coreutils+curl+jq and **`sed` is not in coreutils**. It failed silently, the counter stayed pinned at 1, and the backoff degraded to a flat 15-minute nag with no severity escalation — **51 pages instead of 7**, for a change whose entire purpose was fixing notification. It would have shipped looking correct, with a busy alert stream as its "evidence". Replaying all 760 passes of the real incident against the built script is the only thing that exposed it.

### The procedure

1. **Build, don't switch.** `nix build --no-link --print-out-paths '.#nixosConfigurations.<host>.config.system.build.toplevel'`. Use `--no-link` so no `result` symlink lands in a shared worktree. This also proves the config evaluates.
2. **Derive the artifact from the unit that uses it** — never from a store glob:
   ```bash
   CANARY=$(rg -o '/nix/store/[a-z0-9]+-<name>-canary' "$TOP/etc/systemd/system/<name>-canary.service" | head -1)
   REAL=$(rg -o '/nix/store/[a-z0-9]+-<script>' "$CANARY" | head -1)
   ```
   `ls /nix/store/*-<script> | tail -1` sorts by **hash, not build time**. There were four `opencode-drift-alert` derivations in the store; the glob picked a stale one and the test "proved" the wrong thing. Same failure shape as measuring the wrong port: a plausible stand-in accepted in place of derivation.
3. **Confirm the artifact contains your change** before trusting any result (`rg -c '<new symbol>' "$REAL"`). A passing test on the old artifact is worse than no test.
4. **Patch exactly one line to make it testable, and prove it.** These scripts hardcode `export PATH=…`, so a stub binary cannot be injected via the environment. Prepend a stub dir to that one line and `diff` against the real artifact — if the diff is more than that line, the logic under test is no longer the logic that deploys.
5. **Simulate time via state-file mtime**, not a faked clock: `touch`/`os.utime` the state file backwards and let the script compute its own ages.

### Nix `''` string traps

- A **bare `''` inside the script** terminates the Nix string. A shell comment reading `# the Nix '' string` is a syntax error at eval time. Write `''\''` or reword.
- A **column-0 line** inside a `''` string drops common-indentation stripping for the *entire* script (minimum indent becomes 0). Harmless to bash, but it silently reshapes the output and breaks anchored matching like `sed 's|^export PATH=|…|'`. Build multi-line message bodies with `printf '%s\n\n%s'` instead of embedding a literal flush-left line.
- Shell vars need `''${VAR}`; a plain `${VAR}` is Nix interpolation and will fail to evaluate or silently splice.

### Deploy note

Timer-driven canaries pick up a new script on their **next pass** — no service restart, unlike the `restartIfChanged = false` services above. Know which of the two you are shipping before you write the deploy instructions.

## Pulling and Applying Updates

When fetching remote changes and applying them:

```bash
cd ~/projects/workstation
hostname=$(cat /etc/hostname)
git pull --rebase

# Check what changed to decide what to rebuild
git log --oneline HEAD@{1}..HEAD --name-only

# If hosts/$hostname/* changed → system rebuild
sudo nixos-rebuild switch --flake ".#$hostname"
# WARNING (cloudbox): If front door code changed, also run:
# sudo systemctl restart opencode-frontdoor

# If users/dev/* or assets/* changed → home-manager
# (use correct HM target for this host)
# WARNING (cloudbox): If opencode package changed, also run:
# sudo systemctl restart opencode-serve-pool.target
```

> **WARNING (cloudbox):** Neither `nixos-rebuild switch` nor `home-manager switch` automatically restarts the front door or serve pool (`restartIfChanged = false`). Always run `sudo systemctl restart opencode-frontdoor` and/or `sudo systemctl restart opencode-serve-pool.target` after applying changes. See [Deploy Runbook: Front Door & Serve Pool](#deploy-runbook-front-door--serve-pool).

## Updating Flake Inputs

To update all flake inputs (nixpkgs, home-manager, etc.):

```bash
nix flake update
git add flake.lock
git commit -m "Update flake.lock"
```

Then apply as above.

## Nuclear Option: Full Rebuild with nixos-anywhere

If a host is corrupted or you want a fresh start, see the host-specific setup skill:
- **Devbox (Hetzner):** Manual nixos-anywhere from macOS
- **Cloudbox (GCP):** See `setting-up-cloudbox` skill

## Troubleshooting

### "flake.nix not found"

Make sure you're in the workstation repo directory (`~/projects/workstation`).

### Home-manager errors about missing files

The `assets/` directory must exist. Check that `assets/` is populated.

### System won't boot after rebuild

- **Devbox:** Boot into previous generation from bootloader menu, then fix config.
- **Cloudbox:** Hard reset via `gcloud compute instances reset cloudbox --zone=us-east1-b --project=<project>`. See `setting-up-cloudbox` skill gotcha #10.

### Wrong flake target applied

If you accidentally applied the wrong host's config (e.g., `#devbox` on cloudbox):
1. The activation guard should catch this and abort. If it didn't (e.g., `/etc/hostname` was already overwritten):
2. Re-apply the correct config immediately: `sudo nixos-rebuild switch --flake .#<correct-hostname>`
3. If SSH is broken, use out-of-band access (serial console for GCP, rescue mode for Hetzner).
