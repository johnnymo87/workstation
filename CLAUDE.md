# Workstation

NixOS devbox + nix-darwin macOS configuration with standalone home-manager.

## Quick Start

**Devbox (NixOS):**
```bash
sudo nixos-rebuild switch --flake .#devbox   # System changes
home-manager switch --flake .#dev            # User changes (fast, no sudo)
```

**macOS (nix-darwin):**
```bash
sudo darwin-rebuild switch --flake .#Y0FMQX93RR-2   # System + user changes
```

## Managing Projects

Projects are declared in `projects.nix` and auto-cloned per platform.

| Platform | Clone target | Trigger |
|----------|-------------|---------|
| Devbox | `~/projects/` | Login (systemd service) or `~/.local/bin/ensure-projects` |
| macOS | `~/Code/` | `darwin-rebuild switch` (activation script) |

**Add a project:**
1. Edit `projects.nix`:
   ```nix
   my-new-project = { url = "git@github.com:org/repo.git"; };
   ```
2. Push to GitHub
3. Apply: `home-manager switch --flake .#dev` (devbox) or `darwin-rebuild switch` (macOS)

**Devbox projects survive rebuilds** — stored on `/persist/projects`, bind-mounted to `~/projects`.

## Commands

| Command | Description |
|---------|-------------|
| [/rebuild](.claude/commands/rebuild.md) | Apply system and/or home changes |
| [/apply-home](.claude/commands/apply-home.md) | Quick home-manager apply |

## Skills

| Skill | Description |
|-------|-------------|
| [Understanding Workstation](.claude/skills/understanding-workstation/SKILL.md) | Repo structure, concepts, navigation |
| [Setting Up Hetzner](.claude/skills/setting-up-hetzner/SKILL.md) | Initial machine setup, hcloud context |
| [Rebuilding Devbox](.claude/skills/rebuilding-devbox/SKILL.md) | How to apply changes, full rebuilds |
| [Troubleshooting Devbox](.claude/skills/troubleshooting-devbox/SKILL.md) | SSH issues, host keys, NixOS problems |
| [Automated Updates](.claude/skills/automated-updates/SKILL.md) | GitHub Actions + systemd timer update pipeline |
| [Managing Secrets](.claude/skills/managing-secrets/SKILL.md) | Adding, removing, and using sops-nix secrets |
| [Growing Neovim Config](.claude/skills/growing-nvim-config/SKILL.md) | How to incrementally add nvim config |
| [Migrating Claude Assets](.claude/skills/migrating-claude-assets/SKILL.md) | Moving skills/commands to home-manager |
| [Gradual Dotfiles Migration](.claude/skills/gradual-dotfiles-migration/SKILL.md) | Migrating from dotfiles to home-manager on Darwin |
| [OSC52 Clipboard](.claude/skills/osc52-clipboard/SKILL.md) | Copy/paste over SSH, clipboard sync |
| [Screenshot to Devbox](.claude/skills/screenshot-to-devbox/SKILL.md) | Sharing screenshots with remote Claude Code |

## Structure

```
workstation/
├── flake.nix              # Flake: NixOS + nix-darwin + home-manager
├── projects.nix           # Declarative project list (both platforms)
├── hosts/
│   ├── devbox/            # NixOS system config
│   └── Y0FMQX93RR-2/     # macOS (nix-darwin) system config
├── users/dev/
│   ├── home.nix           # Entry point (imports all modules)
│   ├── home.base.nix      # Shared config (git, bash, packages)
│   ├── home.linux.nix     # Linux-only (systemd services, ensure-projects)
│   ├── home.darwin.nix    # macOS-only (launchd, ensure-projects, dotfiles migration)
│   ├── opencode-config.nix # OpenCode managed config
│   ├── claude-skills.nix  # Claude Code skills deployed to ~/.claude/
│   └── claude-hooks.nix   # Claude Code hooks (session start/stop)
├── assets/                # Content deployed to user (claude/, nvim/)
├── secrets/               # sops-nix encrypted secrets
└── .claude/               # Documentation for THIS repo
```

## Fresh Devbox Setup

After `nixos-anywhere`:
1. Copy age key: `scp /path/to/key devbox:/persist/sops-age-key.txt`
2. Clone workstation: `git clone ... ~/projects/workstation`
3. Apply system: `sudo nixos-rebuild switch --flake .#devbox`
4. Apply home: `home-manager switch --flake .#dev`
5. Projects auto-clone on next login (or run `~/.local/bin/ensure-projects`)

## Fresh macOS Setup

1. Install Nix: `curl -L https://nixos.org/nix/install | sh`
2. Clone workstation: `git clone ... ~/Code/workstation`
3. Apply: `sudo darwin-rebuild switch --flake ~/Code/workstation#Y0FMQX93RR-2`
4. Projects auto-clone during activation (to `~/Code/`)
5. For devenv projects: `cd ~/Code/<project> && direnv allow`

## Secrets

**Devbox:** Secrets at `/run/secrets/<name>` via sops-nix. Env vars (`CLOUDFLARE_API_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN`) auto-exported in bash. See [Managing Secrets](.claude/skills/managing-secrets/SKILL.md).

**macOS:** 1Password via desktop app or service account token in Keychain. See [configuring-notifications](https://github.com/johnnymo87/claude-code-remote/.claude/skills/configuring-notifications/SKILL.md) for CCR secrets.
