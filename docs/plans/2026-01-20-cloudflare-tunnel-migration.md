# Cloudflare Tunnel Migration (Replace ngrok)

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace ngrok with Cloudflare Tunnel for CCR webhooks, enabling both devbox and macOS to run as replicas of the same tunnel simultaneously.

**Architecture:** Use Cloudflare Tunnel with a dashboard-managed tunnel (remotely configured). Both machines connect using the same tunnel token. Cloudflare handles failover/load-balancing between whichever connectors are online. Store token in sops-nix (NixOS) and Keychain (macOS).

**Tech Stack:** Cloudflare Tunnel, cloudflared, sops-nix, NixOS systemd, macOS launchd, home-manager

---

## Prerequisites (Manual Browser Steps)

Before starting the automated tasks, the user must complete these manual steps in the browser:

### Prereq A: Add Domain to Cloudflare

1. Log into [Cloudflare Dashboard](https://dash.cloudflare.com)
2. Click **"Add a domain"** (or "Onboard a domain")
3. Enter: `mohrbacher.dev`
4. Select **Free** plan
5. Cloudflare will scan for existing DNS records (likely none since domain is parked)
6. Click **Continue**
7. Cloudflare shows two nameservers (e.g., `anna.ns.cloudflare.com`, `bob.ns.cloudflare.com`)
8. **Write these down** - you'll need them for Prereq B

### Prereq B: Change Nameservers at Squarespace

1. Log into [Squarespace Domains](https://account.squarespace.com/domains)
2. Click `mohrbacher.dev`
3. Go to **DNS** → **Domain Nameservers**
4. Click **"Use Custom Nameservers"**
5. Re-authenticate if prompted
6. If prompted to disable DNSSEC, do so
7. Enter the two Cloudflare nameservers from Prereq A
8. Click **Save**
9. Wait for propagation (can take up to 48 hours, often much faster)

### Prereq C: Verify Domain is Active

1. Return to [Cloudflare Dashboard](https://dash.cloudflare.com)
2. Click on `mohrbacher.dev`
3. Check that the status shows **"Active"** (not "Pending nameservers")
4. If still pending, wait and refresh

### Prereq D: Create Tunnel and Get Token

1. Go to [Cloudflare One](https://one.dash.cloudflare.com)
2. Navigate: **Networks** → **Tunnels**
3. Click **"Create a tunnel"**
4. Select **"Cloudflared"** as connector type
5. Name it: `ccr-webhooks`
6. Click **Save tunnel**
7. Cloudflare shows installation commands - **copy the tunnel token** (the long string after `--token`)
8. **Save the token securely** - you'll add it to sops secrets in Task 2
9. Click **Next** (skip the connector install for now, we'll do it via Nix)

### Prereq E: Add Public Hostname to Tunnel

1. Still in the tunnel configuration, go to **Public Hostnames** tab
2. Click **"Add a public hostname"**
3. Configure:
   - **Subdomain:** `ccr`
   - **Domain:** `mohrbacher.dev` (select from dropdown)
   - **Type:** HTTP
   - **URL:** `localhost:4731`
4. Click **Save hostname**
5. Cloudflare automatically creates the DNS CNAME record

**After completing Prerequisites A-E, tell Claude to proceed with Task 1.**

---

## Phase 1: NixOS Devbox (Tasks 1-5)

### Task 1: Remove ngrok flake input and ccrNgrok config

**Files:**
- Modify: `flake.nix`

**Step 1: Remove ngrok input**

Find and remove this block from the `inputs` section:

```nix
    ngrok = {
      url = "github:ngrok/ngrok-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
```

**Step 2: Remove ngrok from outputs function parameters**

Change:
```nix
  outputs = { self, nixpkgs, home-manager, nix-darwin, disko, llm-agents, sops-nix, ngrok, ... }@inputs:
```

To:
```nix
  outputs = { self, nixpkgs, home-manager, nix-darwin, disko, llm-agents, sops-nix, ... }@inputs:
```

**Step 3: Remove ccrNgrok definition**

Find and remove this block from the `let` section:

```nix
    # Shared ngrok tunnel configuration for CCR
    ccrNgrok = {
      name = "ccr-webhooks";
      domain = "rehabilitative-joanie-undefeatedly.ngrok-free.dev";
      port = 4731;
    };
```

**Step 4: Add ccrTunnel definition**

In the same location, add:

```nix
    # Shared Cloudflare Tunnel configuration for CCR webhooks
    ccrTunnel = {
      hostname = "ccr.mohrbacher.dev";
      port = 4731;
    };
```

**Step 5: Update NixOS specialArgs**

Change:
```nix
      specialArgs = { inherit ngrok ccrNgrok; };
```

To:
```nix
      specialArgs = { inherit ccrTunnel; };
```

**Step 6: Remove ngrok module from NixOS modules**

Remove this line from the `modules` list:
```nix
        ngrok.nixosModules.ngrok
```

**Step 7: Update home-manager extraSpecialArgs (devbox)**

Change:
```nix
        inherit self llm-agents ccrNgrok;
```

To:
```nix
        inherit self llm-agents ccrTunnel;
```

**Step 8: Update Darwin extraSpecialArgs**

Change:
```nix
      specialArgs = { inherit inputs mac ccrNgrok; };
```

To:
```nix
      specialArgs = { inherit inputs mac ccrTunnel; };
```

And in `home-manager.extraSpecialArgs`:

Change:
```nix
            inherit llm-agents ccrNgrok;
```

To:
```nix
            inherit llm-agents ccrTunnel;
```

**Step 9: Commit**

```bash
git add flake.nix
git commit -m "$(cat <<'EOF'
Replace ngrok with Cloudflare Tunnel config in flake

- Remove ngrok-nix flake input
- Replace ccrNgrok with ccrTunnel (hostname + port)
- Update all specialArgs references

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Add cloudflared tunnel token to sops secrets

**Files:**
- Modify: `secrets/devbox.yaml`

**Step 1: Edit the encrypted secrets file**

```bash
SOPS_AGE_KEY_FILE=/persist/sops-age-key.txt sops secrets/devbox.yaml
```

**Step 2: Add the tunnel token**

Add this line (replace with actual token from Prereq D):

```yaml
cloudflared_tunnel_token: "YOUR_TUNNEL_TOKEN_HERE"
```

Save and exit. sops will re-encrypt the file.

**Step 3: Verify the secret was added**

```bash
SOPS_AGE_KEY_FILE=/persist/sops-age-key.txt sops -d secrets/devbox.yaml | grep cloudflared
```

Expected: Shows the decrypted token line.

**Step 4: Commit**

```bash
git add secrets/devbox.yaml
git commit -m "$(cat <<'EOF'
Add cloudflared tunnel token to sops secrets

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Replace ngrok with cloudflared service on NixOS

**Files:**
- Modify: `hosts/devbox/configuration.nix`

**Step 1: Update module arguments**

Change:
```nix
{ config, pkgs, lib, ngrok, ccrNgrok, ... }:
```

To:
```nix
{ config, pkgs, lib, ccrTunnel, ... }:
```

**Step 2: Remove ngrok sops secret**

Find and remove:
```nix
      ngrok_authtoken = {
        owner = "ngrok";
        group = "ngrok";
        mode = "0400";
      };
```

**Step 3: Add cloudflared sops secret**

In the `sops.secrets` block, add:

```nix
      cloudflared_tunnel_token = {
        owner = "cloudflared";
        group = "cloudflared";
        mode = "0400";
      };
```

**Step 4: Remove ngrok sops template**

Find and remove the entire block:
```nix
    # Render ngrok config with authtoken
    templates."ngrok-secrets.yml" = {
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

**Step 5: Remove services.ngrok block**

Find and remove:
```nix
  # ngrok tunnel for CCR webhooks
  services.ngrok = {
    enable = true;
    extraConfigFiles = [ config.sops.templates."ngrok-secrets.yml".path ];
    # Use top-level endpoints option (not extraConfig) so module starts with --all
    endpoints = [
      {
        name = ccrNgrok.name;
        url = "https://${ccrNgrok.domain}";
        upstream.url = toString ccrNgrok.port;
      }
    ];
  };
```

**Step 6: Remove allowUnfree (if only for ngrok)**

Find and remove:
```nix
  # Allow unfree packages (ngrok)
  nixpkgs.config.allowUnfree = true;
```

(Note: If other unfree packages are needed, keep this line)

**Step 7: Add cloudflared user and group**

After the existing user configuration, add:

```nix
  # cloudflared service user
  users.groups.cloudflared = {};
  users.users.cloudflared = {
    isSystemUser = true;
    group = "cloudflared";
    description = "Cloudflare Tunnel daemon user";
  };
```

**Step 8: Add cloudflared systemd service**

Replace the ngrok section with:

```nix
  # Cloudflare Tunnel for CCR webhooks (dashboard-managed with token)
  systemd.services.cloudflared-tunnel = {
    description = "Cloudflare Tunnel for CCR webhooks";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];

    serviceConfig = {
      Type = "simple";
      User = "cloudflared";
      Group = "cloudflared";
      ExecStart = "${pkgs.cloudflared}/bin/cloudflared tunnel --no-autoupdate run --token $(cat ${config.sops.secrets.cloudflared_tunnel_token.path})";
      Restart = "on-failure";
      RestartSec = 5;
    };
  };
```

**Step 9: Update ccr-webhooks service dependency**

Change:
```nix
    after = [ "network-online.target" "ngrok.service" ];
    requires = [ "ngrok.service" ];
```

To:
```nix
    after = [ "network-online.target" "cloudflared-tunnel.service" ];
    requires = [ "cloudflared-tunnel.service" ];
```

**Step 10: Update ccr.target**

Change:
```nix
  systemd.targets.ccr = {
    description = "CCR stack (ngrok + webhooks)";
    wants = [ "ngrok.service" "ccr-webhooks.service" ];
  };
```

To:
```nix
  systemd.targets.ccr = {
    description = "CCR stack (cloudflared + webhooks)";
    wants = [ "cloudflared-tunnel.service" "ccr-webhooks.service" ];
  };
```

**Step 11: Commit**

```bash
git add hosts/devbox/configuration.nix
git commit -m "$(cat <<'EOF'
Replace ngrok with cloudflared tunnel service

- Remove ngrok service and sops template
- Add cloudflared user/group
- Add cloudflared-tunnel systemd service with token from sops
- Update ccr-webhooks to depend on cloudflared-tunnel
- Update ccr.target

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Update flake.lock

**Step 1: Remove ngrok from flake.lock**

```bash
nix flake lock --update-input nixpkgs
```

(This regenerates flake.lock without the ngrok input)

**Step 2: Commit**

```bash
git add flake.lock
git commit -m "$(cat <<'EOF'
Update flake.lock (remove ngrok-nix)

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Apply and test on NixOS

**Step 1: Rebuild NixOS**

```bash
sudo nixos-rebuild switch --flake .#devbox
```

Expected: Should complete without errors.

**Step 2: Verify cloudflared service is running**

```bash
systemctl status cloudflared-tunnel
```

Expected: Active (running).

**Step 3: Verify ccr-webhooks service is running**

```bash
systemctl status ccr-webhooks
```

Expected: Active (running).

**Step 4: Verify tunnel is connected in Cloudflare**

Go to [Cloudflare One](https://one.dash.cloudflare.com) → Networks → Tunnels → `ccr-webhooks`

Expected: Shows 1 connector with "Healthy" status.

**Step 5: Test the public endpoint**

```bash
curl -sI https://ccr.mohrbacher.dev
```

Expected: HTTP response from the webhook server (likely 404 on root path, which is fine).

**Step 6: Verify webhook path works**

```bash
curl -s https://ccr.mohrbacher.dev/health 2>/dev/null || echo "No /health endpoint - try the actual webhook path"
```

---

## Phase 2: macOS (Tasks 6-9) - RUN ON MACOS

**CHECKPOINT:** Push changes and switch to macOS.

```bash
git push origin main
```

On macOS, pull and continue:

```bash
cd ~/Code/workstation  # or your macOS workstation path
git pull origin main
```

---

### Task 6: Store cloudflared token in macOS Keychain

**Prerequisites:** Must be on macOS.

**Step 1: Add token to Keychain**

```bash
security add-generic-password -s cloudflared-tunnel-token -a cloudflared -w 'YOUR_TUNNEL_TOKEN_HERE' -U
```

Replace `YOUR_TUNNEL_TOKEN_HERE` with the actual token from Prereq D.

**Step 2: Verify retrieval works**

```bash
security find-generic-password -s cloudflared-tunnel-token -w
```

Expected: Prints the token.

---

### Task 7: Replace ngrok with cloudflared in home.darwin.nix

**Files:**
- Modify: `users/dev/home.darwin.nix`

**Step 1: Update module arguments**

Change:
```nix
{ config, pkgs, lib, assetsPath, isDarwin, ccrNgrok, ... }:
```

To:
```nix
{ config, pkgs, lib, assetsPath, isDarwin, ccrTunnel, ... }:
```

**Step 2: Replace ngrok package with cloudflared**

Change:
```nix
  home.packages = [
    (pkgs.writeShellApplication {
      name = "screenshot-to-devbox";
      text = builtins.readFile "${assetsPath}/scripts/screenshot-to-devbox.sh";
    })
    pkgs.ngrok
  ];
```

To:
```nix
  home.packages = [
    (pkgs.writeShellApplication {
      name = "screenshot-to-devbox";
      text = builtins.readFile "${assetsPath}/scripts/screenshot-to-devbox.sh";
    })
    pkgs.cloudflared
  ];
```

**Step 3: Replace ngrok launchd agent with cloudflared**

Replace the entire `launchd.agents.ngrok-ccr` block:

```nix
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

With:

```nix
  # Cloudflare Tunnel launchd agent with Keychain-sourced token
  launchd.agents.cloudflared-ccr = {
    enable = true;
    config = {
      ProgramArguments = [
        "/bin/sh" "-c"
        ''
          TUNNEL_TOKEN="$(/usr/bin/security find-generic-password -s cloudflared-tunnel-token -w)"
          exec ${pkgs.cloudflared}/bin/cloudflared tunnel --no-autoupdate run --token "$TUNNEL_TOKEN"
        ''
      ];
      RunAtLoad = false;  # Start manually, not at login
      KeepAlive = false;  # Don't auto-restart
      StandardOutPath = "${config.home.homeDirectory}/Library/Logs/cloudflared-ccr.out.log";
      StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/cloudflared-ccr.err.log";
    };
  };
```

**Step 4: Commit**

```bash
git add users/dev/home.darwin.nix
git commit -m "$(cat <<'EOF'
Replace ngrok with cloudflared on macOS

- Replace pkgs.ngrok with pkgs.cloudflared
- Replace ngrok-ccr launchd agent with cloudflared-ccr
- Token sourced from Keychain (cloudflared-tunnel-token)

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: Remove ngrok from Keychain and uninstall brew ngrok

**Step 1: Remove old ngrok Keychain entry (if exists)**

```bash
security delete-generic-password -s ngrok-authtoken 2>/dev/null || echo "No ngrok keychain entry to remove"
```

**Step 2: Uninstall brew ngrok (if installed)**

```bash
brew uninstall ngrok 2>/dev/null || echo "ngrok not installed via brew"
```

**Step 3: Stop any running ngrok launchd agent**

```bash
launchctl stop ngrok-ccr 2>/dev/null || echo "ngrok-ccr not running"
```

---

### Task 9: Apply and test on macOS

**Step 1: Rebuild darwin**

```bash
darwin-rebuild switch --flake .#Y0FMQX93RR-2
```

Expected: Should complete without errors.

**Step 2: Start the cloudflared launchd agent**

```bash
launchctl start cloudflared-ccr
```

**Step 3: Verify cloudflared is running**

```bash
ps aux | grep cloudflared | grep -v grep
```

Expected: Shows cloudflared process.

**Step 4: Check logs**

```bash
tail -20 ~/Library/Logs/cloudflared-ccr.out.log
```

Expected: Shows tunnel connection messages.

**Step 5: Verify tunnel has 2 connectors in Cloudflare**

Go to [Cloudflare One](https://one.dash.cloudflare.com) → Networks → Tunnels → `ccr-webhooks`

Expected: Shows **2 connectors** (devbox + macOS), both "Healthy".

**Step 6: Test the public endpoint**

```bash
curl -sI https://ccr.mohrbacher.dev
```

Expected: HTTP response from webhook server.

**Step 7: Commit and push**

```bash
git add -A
git commit -m "$(cat <<'EOF'
Complete macOS cloudflared setup

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>
EOF
)" 2>/dev/null || echo "Nothing to commit"
git push origin main
```

---

## Phase 3: Update CCR Webhook URL (Task 10) - RUN ON DEVBOX

### Task 10: Update CCR to use new webhook URL

**Files:**
- Modify: `/home/dev/projects/claude-code-remote/.env` (or wherever webhook URL is configured)

**Step 1: Find the webhook URL configuration**

```bash
grep -r "ngrok" /home/dev/projects/claude-code-remote --include="*.env*" --include="*.json" --include="*.ts" --include="*.js" 2>/dev/null | head -20
```

**Step 2: Update the webhook URL**

Change any reference from:
```
rehabilitative-joanie-undefeatedly.ngrok-free.dev
```

To:
```
ccr.mohrbacher.dev
```

**Step 3: Update Telegram webhook registration**

The CCR webhook server may need to re-register with Telegram. Check the logs after restart:

```bash
sudo systemctl restart ccr-webhooks
journalctl -u ccr-webhooks -n 50 --no-pager
```

Expected: Should show webhook registration with new URL.

**Step 4: Commit CCR changes (in CCR repo)**

```bash
cd /home/dev/projects/claude-code-remote
git add -A
git commit -m "$(cat <<'EOF'
Update webhook URL to ccr.mohrbacher.dev

Migrated from ngrok to Cloudflare Tunnel.

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>
EOF
)"
git push origin main
```

---

## Phase 4: Cleanup (Task 11)

### Task 11: Final cleanup on devbox

**Step 1: Pull latest changes from macOS**

```bash
cd /home/dev/projects/workstation
git pull origin main
```

**Step 2: Verify both services running**

```bash
systemctl status cloudflared-tunnel ccr-webhooks
```

Expected: Both active (running).

**Step 3: Delete ngrok Keychain entry on devbox (if any ngrok remnants)**

Check for any ngrok-related files:
```bash
ls -la /run/secrets/ | grep ngrok
```

(Should be empty after rebuild)

**Step 4: Final verification - stop macOS connector and test failover**

On macOS:
```bash
launchctl stop cloudflared-ccr
```

Then test from anywhere:
```bash
curl -sI https://ccr.mohrbacher.dev
```

Expected: Still works (routed to devbox).

Restart macOS connector:
```bash
launchctl start cloudflared-ccr
```

---

## Post-Implementation Notes

### Service Management

**NixOS devbox:**
```bash
# Check status
systemctl status cloudflared-tunnel ccr-webhooks

# Restart stack
sudo systemctl restart ccr.target

# View logs
journalctl -u cloudflared-tunnel -f
journalctl -u ccr-webhooks -f
```

**macOS:**
```bash
# Start/stop cloudflared
launchctl start cloudflared-ccr
launchctl stop cloudflared-ccr

# View logs
tail -f ~/Library/Logs/cloudflared-ccr.*.log
```

### Secrets

| Platform | Secret Location | How to Update |
|----------|----------------|---------------|
| NixOS | sops `secrets/devbox.yaml` | `SOPS_AGE_KEY_FILE=/persist/sops-age-key.txt sops secrets/devbox.yaml` |
| macOS | Keychain | `security add-generic-password -s cloudflared-tunnel-token -w 'TOKEN' -U` |

### Architecture Summary

```
┌─────────────────────────────────────────────────────────────────┐
│                         flake.nix                               │
│  ccrTunnel = { hostname, port }  ← Single source of truth       │
└─────────────────────────────────────────────────────────────────┘
                    │                           │
         specialArgs│                           │specialArgs
                    ▼                           ▼
    ┌───────────────────────────┐   ┌───────────────────────────┐
    │     NixOS (devbox)        │   │     macOS (laptop)        │
    │                           │   │                           │
    │ systemd cloudflared-tunnel│   │ launchd cloudflared-ccr   │
    │ + sops token              │   │ + Keychain token          │
    │                           │   │                           │
    │ systemd ccr-webhooks      │   │ (manual CCR, or launchd)  │
    └───────────────────────────┘   └───────────────────────────┘
                    │                           │
                    └───────────┬───────────────┘
                                ▼
                    ┌───────────────────────────┐
                    │   Cloudflare Tunnel       │
                    │   (dashboard-managed)     │
                    │                           │
                    │   ccr.mohrbacher.dev      │
                    │   → localhost:4731        │
                    └───────────────────────────┘
                                │
                                ▼
                    ┌───────────────────────────┐
                    │      Telegram API         │
                    │   (sends webhooks to      │
                    │    ccr.mohrbacher.dev)    │
                    └───────────────────────────┘
```

### Key Differences from ngrok

| Aspect | ngrok | Cloudflare Tunnel |
|--------|-------|-------------------|
| Simultaneous connectors | No (domain conflict) | Yes (replicas) |
| Cost | Free tier limited | Free |
| Domain | Random subdomain | Your own domain |
| TLS termination | ngrok edge | Cloudflare edge |
| Dashboard | ngrok.com | one.dash.cloudflare.com |
