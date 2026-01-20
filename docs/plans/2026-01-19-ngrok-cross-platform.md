# Cross-Platform ngrok Integration for Claude Code Remote

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add ngrok as a managed service on both NixOS devbox and macOS, enabling Claude Code Remote webhooks to receive Telegram callbacks on both platforms.

**Architecture:** "Clean divergence" - use ngrok-nix systemd service on NixOS with sops-nix secrets, use home-manager launchd agent on macOS with Keychain secrets. Share tunnel config (domain, port) via flake specialArgs.

**Tech Stack:** Nix flakes, ngrok-nix, sops-nix, home-manager, launchd, macOS Keychain

---

## Phase 1: NixOS Devbox (Tasks 1-5)

### Task 1: Add ngrok-nix flake input

**Files:**
- Modify: `flake.nix`

**Step 1: Add ngrok input to flake.nix**

Find the inputs section and add ngrok:

```nix
ngrok = {
  url = "github:ngrok/ngrok-nix";
  inputs.nixpkgs.follows = "nixpkgs";
};
```

**Step 2: Add ngrok to outputs function parameters**

Update the outputs line to include ngrok:

```nix
outputs = { self, nixpkgs, home-manager, nix-darwin, disko, llm-agents, sops-nix, ngrok, ... }@inputs:
```

**Step 3: Commit**

```bash
git add flake.nix
git commit -m "Add ngrok-nix flake input"
```

---

### Task 2: Add shared ngrok config and pass via specialArgs

**Files:**
- Modify: `flake.nix`

**Step 1: Define shared ngrok config in the let block**

After the `mac = import ./hosts/Y0FMQX93RR-2/vars.nix;` line, add:

```nix
# Shared ngrok tunnel configuration for CCR
ccrNgrok = {
  name = "ccr-webhooks";
  domain = "rehabilitative-joanie-undefeatedly.ngrok-free.dev";
  port = 4731;
};
```

**Step 2: Pass ccrNgrok to NixOS via specialArgs**

Update nixosConfigurations.devbox to include specialArgs:

```nix
nixosConfigurations.devbox = nixpkgs.lib.nixosSystem {
  system = devboxSystem;
  specialArgs = { inherit ngrok ccrNgrok; };
  modules = [
    disko.nixosModules.disko
    sops-nix.nixosModules.sops
    ngrok.nixosModules.ngrok
    ./hosts/devbox/configuration.nix
    ./hosts/devbox/hardware.nix
    ./hosts/devbox/disko.nix
  ];
};
```

**Step 3: Pass ccrNgrok to Darwin via specialArgs**

Update darwinConfigurations to include ccrNgrok:

```nix
darwinConfigurations.${mac.hostname} = nix-darwin.lib.darwinSystem {
  specialArgs = { inherit inputs mac ccrNgrok; };
  modules = [
    # ... existing modules
  ];
};
```

**Step 4: Pass ccrNgrok to standalone home-manager**

Update homeConfigurations.dev extraSpecialArgs:

```nix
extraSpecialArgs = {
  inherit self llm-agents ccrNgrok;
  # ... existing args
};
```

**Step 5: Commit**

```bash
git add flake.nix
git commit -m "Add shared ccrNgrok config and pass via specialArgs"
```

---

### Task 3: Add ngrok authtoken to sops secrets

**Files:**
- Modify: `secrets/devbox.yaml`

**Step 1: Edit the encrypted secrets file**

```bash
SOPS_AGE_KEY_FILE=/persist/sops-age-key.txt sops secrets/devbox.yaml
```

Add the ngrok authtoken (get from ngrok dashboard or existing .env):

```yaml
ngrok_authtoken: "YOUR_NGROK_AUTHTOKEN_HERE"
```

Save and exit. sops will re-encrypt the file.

**Step 2: Verify the secret was added**

```bash
SOPS_AGE_KEY_FILE=/persist/sops-age-key.txt sops -d secrets/devbox.yaml | grep ngrok
```

Expected: Shows the decrypted authtoken line.

**Step 3: Commit**

```bash
git add secrets/devbox.yaml
git commit -m "Add ngrok authtoken to sops secrets"
```

---

### Task 4: Configure ngrok service on NixOS

**Files:**
- Modify: `hosts/devbox/configuration.nix`

**Step 1: Add ngrok and ccrNgrok to module arguments**

Update the module header to accept the new arguments:

```nix
{ config, pkgs, lib, ngrok, ccrNgrok, ... }:
```

**Step 2: Add sops secret and template for ngrok**

After the existing `sops.secrets.github_ssh_key` block, add:

```nix
    ngrok_authtoken = {
      owner = "ngrok";
      group = "ngrok";
      mode = "0400";
    };
  };

  # Render ngrok config with authtoken
  sops.templates."ngrok-secrets.yml" = {
    owner = "ngrok";
    group = "ngrok";
    mode = "0400";
    content = ''
      version: 3
      agent:
        authtoken: ${config.sops.placeholder.ngrok_authtoken}
    '';
  };
```

**Step 3: Add services.ngrok configuration**

After the sops block, add:

```nix
  # ngrok tunnel for CCR webhooks
  services.ngrok = {
    enable = true;
    extraConfigFiles = [ config.sops.templates."ngrok-secrets.yml".path ];
    extraConfig = {
      version = 3;
      endpoints = [
        {
          name = ccrNgrok.name;
          url = "https://${ccrNgrok.domain}";
          upstream.url = toString ccrNgrok.port;
        }
      ];
    };
  };
```

**Step 4: Commit**

```bash
git add hosts/devbox/configuration.nix
git commit -m "Configure ngrok service with sops-managed authtoken

Uses ngrok-nix module with endpoint for CCR webhooks.
Authtoken injected via sops.templates for secure merging."
```

---

### Task 5: Apply and test on NixOS

**Step 1: Update flake.lock**

```bash
nix flake update ngrok
```

**Step 2: Rebuild NixOS**

```bash
sudo nixos-rebuild switch --flake .#devbox
```

Expected: Should complete without errors.

**Step 3: Verify ngrok service is running**

```bash
systemctl status ngrok
```

Expected: Active (running).

**Step 4: Verify tunnel is established**

```bash
curl -s http://127.0.0.1:4040/api/tunnels | jq '.tunnels[].public_url'
```

Expected: Shows the reserved domain URL.

**Step 5: Test webhook endpoint (expect 502 since CCR not running)**

```bash
curl -I https://rehabilitative-joanie-undefeatedly.ngrok-free.dev
```

Expected: HTTP 502 (upstream not available) - this is correct, CCR isn't running yet.

**Step 6: Commit flake.lock if updated**

```bash
git add flake.lock
git commit -m "Update flake.lock with ngrok-nix"
```

---

## Phase 2: CCR Webhook Service on NixOS (Tasks 6-7)

### Task 6: Add CCR webhook systemd service

**Files:**
- Modify: `hosts/devbox/configuration.nix`

**Step 1: Add systemd service for CCR webhooks**

After the services.ngrok block, add:

```nix
  # CCR webhook server (depends on ngrok)
  systemd.services.ccr-webhooks = {
    description = "Claude Code Remote webhook server";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" "ngrok.service" ];
    requires = [ "ngrok.service" ];

    serviceConfig = {
      Type = "simple";
      User = "dev";
      Group = "dev";
      WorkingDirectory = "/home/dev/projects/Claude-Code-Remote";
      Environment = [
        "HOME=/home/dev"
        "NODE_ENV=production"
      ];
      ExecStart = "${pkgs.nodejs}/bin/npm run webhooks";
      Restart = "on-failure";
      RestartSec = 5;
    };
  };

  # Optional: Stack target to start/stop both together
  systemd.targets.ccr = {
    description = "CCR stack (ngrok + webhooks)";
    wants = [ "ngrok.service" "ccr-webhooks.service" ];
  };
```

**Step 2: Commit**

```bash
git add hosts/devbox/configuration.nix
git commit -m "Add CCR webhook systemd service

Runs npm webhooks as user dev, depends on ngrok.
Includes ccr.target for stack management."
```

---

### Task 7: Apply and test CCR service

**Step 1: Rebuild NixOS**

```bash
sudo nixos-rebuild switch --flake .#devbox
```

**Step 2: Check both services**

```bash
systemctl status ngrok ccr-webhooks
```

Expected: Both active (running).

**Step 3: Test full flow**

```bash
curl -I https://rehabilitative-joanie-undefeatedly.ngrok-free.dev
```

Expected: HTTP 200 or appropriate response from webhook server.

**Step 4: Test stack control**

```bash
sudo systemctl stop ccr.target
systemctl status ngrok ccr-webhooks
# Both should be stopped

sudo systemctl start ccr.target
systemctl status ngrok ccr-webhooks
# Both should be running
```

---

## CHECKPOINT: Push and switch to macOS

Tasks 1-7 complete the NixOS devbox setup. Commit, push, and continue Phase 3 on macOS.

```bash
git push origin main
```

---

## Phase 3: macOS Setup (Tasks 8-11) - RUN ON MACOS

### Task 8: Store ngrok authtoken in macOS Keychain

**Prerequisites:** Must be on macOS.

**Step 1: Add authtoken to Keychain**

```bash
security add-generic-password -s ngrok-authtoken -a ngrok -w 'YOUR_NGROK_AUTHTOKEN' -U
```

Replace `YOUR_NGROK_AUTHTOKEN` with the actual token (same one used on devbox).

**Step 2: Verify retrieval works**

```bash
security find-generic-password -s ngrok-authtoken -w
```

Expected: Prints the authtoken.

---

### Task 9: Add ngrok launchd agent to home.darwin.nix

**Files:**
- Modify: `users/dev/home.darwin.nix`

**Step 1: Add ccrNgrok to module arguments**

Update the module header:

```nix
{ config, pkgs, lib, assetsPath, isDarwin, ccrNgrok, ... }:
```

**Step 2: Add ngrok package and launchd agent**

Inside the `lib.mkIf isDarwin { ... }` block, add:

```nix
  # ngrok for CCR webhooks
  home.packages = [
    (pkgs.writeShellApplication {
      name = "screenshot-to-devbox";
      text = builtins.readFile "${assetsPath}/scripts/screenshot-to-devbox.sh";
    })
    pkgs.ngrok  # Add this
  ];

  # ngrok launchd agent with Keychain-sourced authtoken
  launchd.agents.ngrok-ccr = {
    enable = true;
    config = {
      ProgramArguments = [
        "/bin/sh" "-c"
        ''
          export NGROK_AUTHTOKEN="$(/usr/bin/security find-generic-password -s ngrok-authtoken -w)"
          exec ${pkgs.ngrok}/bin/ngrok start --all --config ${
            (pkgs.formats.yaml {}).generate "ngrok-ccr.yml" {
              version = 3;
              endpoints = [
                {
                  name = ccrNgrok.name;
                  url = "https://${ccrNgrok.domain}";
                  upstream.url = toString ccrNgrok.port;
                }
              ];
            }
          }
        ''
      ];
      RunAtLoad = false;  # Start manually, not at login
      KeepAlive = false;  # Don't auto-restart
      StandardOutPath = "${config.home.homeDirectory}/Library/Logs/ngrok-ccr.out.log";
      StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/ngrok-ccr.err.log";
    };
  };
```

**Step 3: Commit**

```bash
git add users/dev/home.darwin.nix
git commit -m "Add ngrok launchd agent for macOS

Uses Keychain for authtoken (no secrets in repo).
RunAtLoad=false for on-demand usage on interactive workstation."
```

---

### Task 10: Remove brew ngrok and apply darwin config

**Step 1: Uninstall brew ngrok**

```bash
brew uninstall ngrok
```

**Step 2: Pull latest workstation**

```bash
cd ~/Code/workstation  # or your macOS path
git pull origin main
```

**Step 3: Rebuild darwin**

```bash
darwin-rebuild switch --flake .#Y0FMQX93RR-2
```

Expected: Should complete without errors.

---

### Task 11: Test ngrok on macOS

**Step 1: Start the launchd agent**

```bash
launchctl start ngrok-ccr
```

**Step 2: Verify ngrok is running**

```bash
curl -s http://127.0.0.1:4040/api/tunnels | jq '.tunnels[].public_url'
```

Expected: Shows the reserved domain URL.

**Step 3: Stop the agent**

```bash
launchctl stop ngrok-ccr
```

**Step 4: Test manual ngrok command**

```bash
NGROK_AUTHTOKEN="$(security find-generic-password -s ngrok-authtoken -w)" ngrok http 4731 --url=rehabilitative-joanie-undefeatedly.ngrok-free.dev
```

Expected: ngrok starts and shows tunnel info.

**Step 5: Commit if any changes**

```bash
git add -A
git commit -m "Complete macOS ngrok setup"
git push origin main
```

---

## Post-Implementation Notes

### Service Management

**NixOS devbox:**
```bash
# Check status
systemctl status ngrok ccr-webhooks

# Restart stack
sudo systemctl restart ccr.target

# View logs
journalctl -u ngrok -f
journalctl -u ccr-webhooks -f
```

**macOS:**
```bash
# Start/stop ngrok
launchctl start ngrok-ccr
launchctl stop ngrok-ccr

# View logs
tail -f ~/Library/Logs/ngrok-ccr.*.log

# Manual run (for debugging)
NGROK_AUTHTOKEN="$(security find-generic-password -s ngrok-authtoken -w)" ngrok http 4731 --url=rehabilitative-joanie-undefeatedly.ngrok-free.dev
```

### Secrets

| Platform | Secret Location | How to Update |
|----------|----------------|---------------|
| NixOS | sops `secrets/devbox.yaml` | `sops secrets/devbox.yaml` |
| macOS | Keychain | `security add-generic-password -s ngrok-authtoken -w 'TOKEN' -U` |

### Architecture Summary

```
┌─────────────────────────────────────────────────────────────────┐
│                         flake.nix                               │
│  ccrNgrok = { domain, port, name }  ← Single source of truth   │
└─────────────────────────────────────────────────────────────────┘
                    │                           │
         specialArgs│                           │specialArgs
                    ▼                           ▼
    ┌───────────────────────────┐   ┌───────────────────────────┐
    │     NixOS (devbox)        │   │     macOS (laptop)        │
    │                           │   │                           │
    │ services.ngrok (ngrok-nix)│   │ launchd.agents.ngrok-ccr  │
    │ + sops.templates          │   │ + Keychain authtoken      │
    │                           │   │                           │
    │ systemd.services.ccr-*    │   │ (manual CCR, or launchd)  │
    └───────────────────────────┘   └───────────────────────────┘
```
