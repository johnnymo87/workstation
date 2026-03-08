# opencode-serve Environment Parity — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Give `opencode-serve` sessions the same tools and environment variables as interactive terminal sessions, so `/launch`-ed sessions have full development capabilities.

**Architecture:** Enrich each machine's `opencode-serve` service definition with a full PATH (system packages + wrappers + home-manager profile) and environment variables (secrets loaded from sops/Keychain). Add `pkgs.bun` to `home.packages` for all machines.

**Tech Stack:** Nix (NixOS modules, nix-darwin, home-manager), systemd, launchd

**Repo:** `~/projects/workstation`

---

### Task 1: Add `pkgs.bun` to cross-platform home packages

**Files:**
- Modify: `users/dev/home.base.nix:163-188` (home.packages list)

**Step 1: Add bun to home.packages**

In `users/dev/home.base.nix`, add `pkgs.bun` to the `home.packages` list, after the `pkgs.devenv` entry:

```nix
    pkgs.devenv

    # JavaScript runtime (used by pigeon and other projects)
    pkgs.bun
  ]
```

**Step 2: Verify nix evaluation**

Run: `nix flake check --no-build 2>&1 | head -20`
Expected: No evaluation errors (build errors are OK — we're not building yet)

If `nix flake check` takes too long or is unavailable, verify with:
Run: `nix eval .#homeConfigurations.dev.config.home.packages --apply 'ps: map (p: p.name or "unnamed") ps' 2>&1 | grep bun`
Expected: Output contains `bun`

**Step 3: Commit**

```bash
git -c commit.gpgsign=false add users/dev/home.base.nix
git -c commit.gpgsign=false commit -m "feat: add bun to cross-platform home packages"
```

---

### Task 2: Enrich devbox opencode-serve service

**Files:**
- Modify: `hosts/devbox/configuration.nix:215-232` (opencode-serve service)

**Step 1: Replace the opencode-serve service definition**

Replace lines 215-232 in `hosts/devbox/configuration.nix` with:

```nix
  systemd.services.opencode-serve = {
    description = "OpenCode headless serve";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" "sops-nix.service" ];
    path = [ config.system.path "/run/wrappers" "/home/dev/.nix-profile" ];
    serviceConfig = {
      Type = "simple";
      User = "dev";
      Group = "dev";
      WorkingDirectory = "/home/dev";
      Environment = [
        "HOME=/home/dev"
        "OPENCODE_ENABLE_EXA=1"
      ];
      ExecStart = "${pkgs.writeShellScript "opencode-serve-start" ''
        set -euo pipefail
        export GH_TOKEN="$(cat /run/secrets/github_api_token)"
        export CLOUDFLARE_API_TOKEN="$(cat /run/secrets/cloudflare_api_token)"
        export CLAUDE_CODE_OAUTH_TOKEN="$(cat /run/secrets/claude_personal_oauth_token)"
        export GOOGLE_GENERATIVE_AI_API_KEY="$(cat /run/secrets/gemini_api_key)"
        exec /home/dev/.nix-profile/bin/opencode serve --port 4096 --hostname 127.0.0.1
      ''}";
      Restart = "always";
      RestartSec = 10;
    };
  };
```

Key changes from the original:
- `after` adds `"sops-nix.service"` (secrets must be decrypted first)
- `path` changed from `[ pkgs.git pkgs.fzf pkgs.ripgrep ]` to `[ config.system.path "/run/wrappers" "/home/dev/.nix-profile" ]`
- `Environment` added with `HOME` and `OPENCODE_ENABLE_EXA`
- `ExecStart` script loads 4 secrets from `/run/secrets/*`

**Step 2: Verify nix evaluation**

Run: `nix eval .#nixosConfigurations.devbox.config.systemd.services.opencode-serve.serviceConfig.ExecStart 2>&1 | head -5`
Expected: Outputs a nix store path string (no evaluation errors)

**Step 3: Commit**

```bash
git -c commit.gpgsign=false add hosts/devbox/configuration.nix
git -c commit.gpgsign=false commit -m "feat(devbox): enrich opencode-serve with full PATH and secrets"
```

---

### Task 3: Enrich cloudbox opencode-serve service

**Files:**
- Modify: `hosts/cloudbox/configuration.nix:252-278` (opencode-serve service)

**Step 1: Replace the opencode-serve service definition**

Replace lines 252-278 in `hosts/cloudbox/configuration.nix` with:

```nix
  systemd.services.opencode-serve = {
    description = "OpenCode headless serve";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" "sops-nix.service" ];
    path = [ config.system.path "/run/wrappers" "/home/dev/.nix-profile" ];
    serviceConfig = {
      Type = "simple";
      User = "dev";
      Group = "dev";
      WorkingDirectory = "/home/dev";
      Environment = [
        "HOME=/home/dev"
      ];
      ExecStart = "${pkgs.writeShellScript "opencode-serve-start" ''
        set -euo pipefail
        export GH_TOKEN="$(cat /run/secrets/github_api_token)"
        export CLOUDFLARE_API_TOKEN="$(cat /run/secrets/cloudflare_api_token)"
        export GOOGLE_GENERATIVE_AI_API_KEY="$(cat /run/secrets/gemini_api_key)"
        if [ -r /run/secrets/google_cloud_project ]; then
          export GOOGLE_CLOUD_PROJECT="$(cat /run/secrets/google_cloud_project)"
        fi
        export GOOGLE_APPLICATION_CREDENTIALS="/home/dev/.config/gcloud/application_default_credentials.json"
        exec /home/dev/.nix-profile/bin/opencode serve --port 4096 --hostname 127.0.0.1
      ''}";
      Restart = "always";
      RestartSec = 10;
    };
  };
```

Key differences from devbox:
- No `CLAUDE_CODE_OAUTH_TOKEN` (work machine uses work auth)
- No `OPENCODE_ENABLE_EXA` (not configured on cloudbox)
- Keeps the existing `GOOGLE_CLOUD_PROJECT` and `GOOGLE_APPLICATION_CREDENTIALS`
- Adds `GH_TOKEN`, `CLOUDFLARE_API_TOKEN`, `GOOGLE_GENERATIVE_AI_API_KEY`
- Same PATH enrichment

**Step 2: Verify nix evaluation**

Run: `nix eval .#nixosConfigurations.cloudbox.config.systemd.services.opencode-serve.serviceConfig.ExecStart 2>&1 | head -5`
Expected: Outputs a nix store path string (no evaluation errors)

**Step 3: Commit**

```bash
git -c commit.gpgsign=false add hosts/cloudbox/configuration.nix
git -c commit.gpgsign=false commit -m "feat(cloudbox): enrich opencode-serve with full PATH and secrets"
```

---

### Task 4: Enrich macOS opencode-serve launchd agent

**Files:**
- Modify: `users/dev/home.darwin.nix:165-192` (opencode-serve launchd agent)

**Step 1: Replace the opencode-serve launchd agent definition**

Replace lines 165-192 in `users/dev/home.darwin.nix` with:

```nix
  launchd.agents.opencode-serve = {
    enable = true;
    config = {
      ProgramArguments = [
        "${pkgs.writeShellScript "opencode-serve-start" ''
          export HOME="${config.home.homeDirectory}"
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

          # GitHub API token from macOS Keychain
          GH_TOKEN_VAL="$(/usr/bin/security find-generic-password -s github-api-token -w 2>/dev/null)" \
            && export GH_TOKEN="$GH_TOKEN_VAL"

          # Google Vertex AI: project from Keychain, ADC from gcloud config
          GCP_VAL="$(/usr/bin/security find-generic-password -s google-cloud-project -w 2>/dev/null)" \
            && export GOOGLE_CLOUD_PROJECT="$GCP_VAL"
          export GOOGLE_APPLICATION_CREDENTIALS="$HOME/.config/gcloud/application_default_credentials.json"

          exec "$HOME/.nix-profile/bin/opencode" serve --port 4096 --hostname 127.0.0.1
        ''}"
      ];
      RunAtLoad = true;
      KeepAlive = true;
      StandardOutPath = "${config.home.homeDirectory}/Library/Logs/opencode-serve.out.log";
      StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/opencode-serve.err.log";
    };
  };
```

Key changes from original:
- PATH expanded: added `openssh`, `gh`, `bun`, `~/.nix-profile/bin`
- Added `GH_TOKEN` from Keychain
- Kept existing `GOOGLE_CLOUD_PROJECT` and `GOOGLE_APPLICATION_CREDENTIALS`

**Step 2: Verify nix evaluation**

Run: `nix eval .#darwinConfigurations.Y0FMQX93RR-2.config.launchd 2>&1 | head -5`
Expected: No evaluation errors (may show a large attribute set)

If the above is slow or hard to verify, just check syntax:
Run: `nix flake check --no-build 2>&1 | head -20`

**Step 3: Commit**

```bash
git -c commit.gpgsign=false add users/dev/home.darwin.nix
git -c commit.gpgsign=false commit -m "feat(macbook): enrich opencode-serve with full PATH and secrets"
```

---

### Task 5: Enrich chromebook opencode-serve user service

**Files:**
- Modify: `users/dev/home.crostini.nix:116-139` (opencode-serve systemd user service)

**Step 1: Replace the opencode-serve user service definition**

Replace lines 116-139 in `users/dev/home.crostini.nix` with:

```nix
  systemd.user.services.opencode-serve = {
    Unit = {
      Description = "OpenCode headless serve";
      After = [ "network-online.target" ];
      Wants = [ "network-online.target" ];
    };
    Service = {
      Type = "simple";
      WorkingDirectory = config.home.homeDirectory;
      Environment = [
        "HOME=${config.home.homeDirectory}"
        "PATH=${lib.makeBinPath [
          pkgs.git pkgs.openssh pkgs.fzf pkgs.ripgrep pkgs.gh pkgs.bun
          pkgs.coreutils pkgs.findutils pkgs.gnugrep pkgs.gnused
        ]}:${config.home.homeDirectory}/.nix-profile/bin"
      ];
      ExecStart = "${pkgs.writeShellScript "opencode-serve-start" ''
        set -euo pipefail
        if [ -r "${config.sops.secrets.gemini_api_key.path}" ]; then
          export GOOGLE_GENERATIVE_AI_API_KEY="$(cat "${config.sops.secrets.gemini_api_key.path}")"
        fi
        exec ${config.home.homeDirectory}/.nix-profile/bin/opencode serve --port 4096 --hostname 127.0.0.1
      ''}";
      Restart = "always";
      RestartSec = 10;
    };
    Install = {
      WantedBy = [ "default.target" ];
    };
  };
```

Key changes from original:
- PATH expanded: added `openssh`, `gh`, `bun`, `coreutils`, `findutils`, `gnugrep`, `gnused`, `~/.nix-profile/bin`
- Loads `GOOGLE_GENERATIVE_AI_API_KEY` from sops in ExecStart
- No `GH_TOKEN` or `CLAUDE_CODE_OAUTH_TOKEN` (not in chromebook's sops secrets)

**Step 2: Verify nix evaluation**

Run: `nix eval .#homeConfigurations.livia.config.systemd.user.services.opencode-serve.Service.ExecStart 2>&1 | head -5`
Expected: Outputs a nix store path string (no evaluation errors)

**Step 3: Commit**

```bash
git -c commit.gpgsign=false add users/dev/home.crostini.nix
git -c commit.gpgsign=false commit -m "feat(chromebook): enrich opencode-serve with full PATH and secrets"
```

---

### Task 6: Final verification and deployment instructions

**Step 1: Run full flake check**

Run: `nix flake check --no-build 2>&1`
Expected: All configurations evaluate without errors

**Step 2: Write deployment instructions to /tmp**

Write a file to `/tmp/deploy-opencode-serve-env-parity.md` with per-machine deployment commands:

```markdown
# Deploy: opencode-serve Environment Parity

## What Changed
opencode-serve now has full PATH (system packages + sudo + home-manager binaries)
and environment variables (GH_TOKEN, API keys). /launch sessions will have the
same capabilities as interactive terminal sessions.

Also adds `bun` to all machines via home.packages.

## Deploy Steps

### Devbox
cd ~/projects/workstation && git pull
sudo nixos-rebuild switch --flake .#devbox
# Verify:
curl -s http://127.0.0.1:4096/global/health

### Cloudbox
cd ~/projects/workstation && git pull
sudo nixos-rebuild switch --flake .#cloudbox
curl -s http://127.0.0.1:4096/global/health

### MacBook
cd ~/Code/workstation && git pull
sudo darwin-rebuild switch --flake .#Y0FMQX93RR-2
curl -s http://127.0.0.1:4096/global/health

### Chromebook
cd ~/projects/workstation && git pull
nix run home-manager -- switch --flake .#livia
systemctl --user restart opencode-serve.service
curl -s http://127.0.0.1:4096/global/health
```

**Step 3: Commit**

```bash
git -c commit.gpgsign=false add -A
git -c commit.gpgsign=false commit -m "docs: add deployment instructions for opencode-serve env parity"
```
