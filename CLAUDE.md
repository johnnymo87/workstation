# Workstation

NixOS devbox configuration with standalone home-manager.

## Quick Start

```bash
# Apply system changes (requires sudo)
sudo nixos-rebuild switch --flake .#devbox

# Apply user changes (fast, no sudo)
home-manager switch --flake .#dev
```

## Commands

| Command | Description |
|---------|-------------|
| [/rebuild](.claude/commands/rebuild.md) | Apply system and/or home changes |
| [/apply-home](.claude/commands/apply-home.md) | Quick home-manager apply |

## Skills

| Skill | Description |
|-------|-------------|
| [Understanding Workstation](.claude/skills/understanding-workstation/SKILL.md) | Repo structure, concepts, navigation |
| [Rebuilding Devbox](.claude/skills/rebuilding-devbox/SKILL.md) | How to apply changes, full rebuilds |

## Structure

```
workstation/
├── hosts/devbox/     # NixOS system config
├── users/dev/        # Home-manager user config
├── assets/           # Content deployed to user (claude/, nvim/)
├── secrets/          # sops-nix encrypted secrets (skeleton)
├── scripts/          # Helper scripts
└── .claude/          # Documentation for THIS repo
```
