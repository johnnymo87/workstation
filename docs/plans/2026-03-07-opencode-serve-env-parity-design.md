# Enrich opencode-serve Environment for /launch Parity

## Problem

Sessions launched via pigeon's `/launch` command inherit the systemd/launchd environment of `opencode-serve`, which is far more restricted than an interactive terminal. Missing: `ssh` (git push fails), `sudo` (can't restart services), `gh`, `bun`, `node`, API keys, and most system packages. This makes `/launch` sessions second-class citizens that can't perform basic development operations.

## Root Cause

Each machine's `opencode-serve` service declares only `path = [ pkgs.git pkgs.fzf pkgs.ripgrep ]` and no environment variables. NixOS system services don't inherit the interactive shell environment -- everything must be explicitly declared.

## Solution

Three changes per machine:

1. **PATH**: Include all system packages, setuid wrappers (sudo), and home-manager binaries
2. **Environment variables**: Load secrets from sops/Keychain in ExecStart, matching what `.bashrc` does
3. **Add `pkgs.bun`** to `environment.systemPackages` on all machines (currently missing everywhere except macOS which has it via home-manager)

### direnv

Not fixable in the service -- direnv requires interactive shell hooks. Agents in `/launch` sessions can run `devenv shell` if they need project-specific tooling. No change needed.

## Per-Machine Changes

### Devbox (`hosts/devbox/configuration.nix`)

**PATH** -- replace `path = [ pkgs.git pkgs.fzf pkgs.ripgrep ]` with:
```nix
path = [ config.system.path "/run/wrappers" "/home/dev/.nix-profile" ];
```

This adds all `environment.systemPackages` binaries, `/run/wrappers/bin` (sudo), and `~/.nix-profile/bin` (node, npm, devenv, opencode, wrangler, etc.).

**After** -- add `"sops-nix.service"` so secrets are decrypted before the service reads them.

**Environment** -- add `HOME` and `OPENCODE_ENABLE_EXA`:
```nix
Environment = [
  "HOME=/home/dev"
  "OPENCODE_ENABLE_EXA=1"
];
```

**ExecStart** -- load secrets from sops (same pattern as pigeon-daemon):
```nix
ExecStart = "${pkgs.writeShellScript "opencode-serve-start" ''
  set -euo pipefail
  export GH_TOKEN="$(cat /run/secrets/github_api_token)"
  export CLOUDFLARE_API_TOKEN="$(cat /run/secrets/cloudflare_api_token)"
  export CLAUDE_CODE_OAUTH_TOKEN="$(cat /run/secrets/claude_personal_oauth_token)"
  export GOOGLE_GENERATIVE_AI_API_KEY="$(cat /run/secrets/gemini_api_key)"
  exec /home/dev/.nix-profile/bin/opencode serve --port 4096 --hostname 127.0.0.1
''}";
```

**systemPackages** -- add `pkgs.bun`.

### Cloudbox (`hosts/cloudbox/configuration.nix`)

Same pattern as devbox. Already has `after = [ ... "sops-nix.service" ]`. Keep the existing Google Cloud credentials. No `CLAUDE_CODE_OAUTH_TOKEN` (work machine uses work auth).

**ExecStart** secrets:
```
GH_TOKEN, CLOUDFLARE_API_TOKEN, GOOGLE_GENERATIVE_AI_API_KEY,
GOOGLE_CLOUD_PROJECT (existing), GOOGLE_APPLICATION_CREDENTIALS (existing)
```

**systemPackages** -- add `pkgs.bun`.

### macOS/MacBook (`users/dev/home.darwin.nix`)

macOS uses launchd, not systemd. No `path =` option -- PATH is set as a string in `EnvironmentVariables` or the script.

**PATH** -- expand the script PATH to include Nix profile paths:
```nix
export PATH="${lib.concatStringsSep ":" [
  "${pkgs.git}/bin"
  "${pkgs.openssh}/bin"
  "${pkgs.fzf}/bin"
  "${pkgs.ripgrep}/bin"
  "${pkgs.gh}/bin"
  "${pkgs.bun}/bin"
  "$HOME/.nix-profile/bin"
  "/usr/bin"
  "/bin"
]}"
```

**Secrets** -- read from Keychain (same pattern as pigeon-daemon on macOS):
```bash
GH_TOKEN_VAL="$(/usr/bin/security find-generic-password -s github-api-token -w 2>/dev/null)" \
  && export GH_TOKEN="$GH_TOKEN_VAL"
```

### Chromebook (`users/dev/home.crostini.nix`)

User-level systemd service managed by home-manager. Uses `Service.Environment` (not NixOS `path =`).

**PATH** -- expand to include home-manager profile and sops-managed packages:
```nix
Environment = [
  "HOME=${config.home.homeDirectory}"
  "PATH=${lib.makeBinPath [ pkgs.git pkgs.fzf pkgs.ripgrep pkgs.openssh pkgs.gh pkgs.bun pkgs.coreutils pkgs.findutils pkgs.gnugrep pkgs.gnused ]}:${config.home.homeDirectory}/.nix-profile/bin"
];
```

**Secrets** -- load Gemini key from sops path:
```bash
export GOOGLE_GENERATIVE_AI_API_KEY="$(cat "${config.sops.secrets.gemini_api_key.path}")"
```

No `CLAUDE_CODE_OAUTH_TOKEN` or `GH_TOKEN` on chromebook (not in its sops secrets).

## Deployment

Each machine needs a rebuild:

| Machine | Command |
|---------|---------|
| devbox | `sudo nixos-rebuild switch --flake .#devbox` |
| cloudbox | `sudo nixos-rebuild switch --flake .#cloudbox` |
| macbook | `sudo darwin-rebuild switch --flake .#Y0FMQX93RR-2` |
| chromebook | `nix run home-manager -- switch --flake .#livia` |

## What This Fixes

| Capability | Before | After |
|---|---|---|
| `git push` (ssh) | Fails -- ssh not on PATH | Works |
| `sudo systemctl restart` | Fails -- /run/wrappers not on PATH | Works (NixOS only) |
| `gh` CLI | Missing | Works with GH_TOKEN |
| `bun` | Not installed | Works |
| `node`/`npm` | Missing from service | Works via ~/.nix-profile |
| API keys (GH, Cloudflare, Gemini) | Missing | Loaded from sops/Keychain |
| `curl`, `jq`, `gcc`, etc. | Missing | Works via system.path |

## What This Doesn't Fix

- **GPG commit signing** -- requires forwarded agent from active SSH session. Use `git -c commit.gpgsign=false`.
- **direnv project activation** -- structural mismatch with services. Use `devenv shell` manually.
