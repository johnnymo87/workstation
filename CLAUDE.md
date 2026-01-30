# Workstation

NixOS devbox configuration with standalone home-manager.

## Quick Start

```bash
# Apply system changes (requires sudo)
sudo nixos-rebuild switch --flake .#devbox

# Apply user changes (fast, no sudo)
home-manager switch --flake .#dev
```

## Managing Projects

Projects are declared in `projects.nix` and auto-cloned on login.

**Add a project:**
1. Edit `projects.nix`:
   ```nix
   my-new-project = { url = "git@github.com:org/repo.git"; };
   ```
2. Push to GitHub
3. On devbox: `home-manager switch --flake .#dev`
4. Run: `~/.local/bin/ensure-projects` (or re-login)

**Projects survive rebuilds** - stored on `/persist/projects`, bind-mounted to `~/projects`.

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
├── flake.nix         # Flake with NixOS + home-manager
├── projects.nix      # Declarative project list
├── hosts/devbox/     # NixOS system config
├── users/dev/        # Home-manager user config
├── assets/           # Content deployed to user (claude/, nvim/)
├── secrets/          # sops-nix encrypted secrets
├── scripts/          # Helper scripts
└── .claude/          # Documentation for THIS repo
```

## Fresh Devbox Setup

After `nixos-anywhere`:
1. Copy age key: `scp /path/to/key devbox:/persist/sops-age-key.txt`
2. Clone workstation: `git clone ... ~/projects/workstation`
3. Apply system: `sudo nixos-rebuild switch --flake .#devbox`
4. Apply home: `home-manager switch --flake .#dev`
5. Projects auto-clone on next login (or run `~/.local/bin/ensure-projects`)

## Secrets on Devbox

See [Managing Secrets](.claude/skills/managing-secrets/SKILL.md) for full details.

Quick reference: secrets are at `/run/secrets/<name>`, env vars (`CLOUDFLARE_API_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN`) are auto-exported in bash.
