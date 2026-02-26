# Workstation

NixOS devbox + nix-darwin macOS configuration with standalone home-manager.

## Quick Start

**Devbox (NixOS):**
```bash
sudo nixos-rebuild switch --flake .#devbox            # System changes
nix run home-manager -- switch --flake .#dev           # User changes (fast, no sudo)
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
3. Apply: `nix run home-manager -- switch --flake .#dev` (devbox) or `darwin-rebuild switch` (macOS)

**Devbox projects survive rebuilds** — stored on `/persist/projects`, bind-mounted to `~/projects`.

## Commands

| Command | Description |
|---------|-------------|
| [/rebuild](.opencode/commands/rebuild.md) | Apply system and/or home changes |
| [/apply-home](.opencode/commands/apply-home.md) | Quick home-manager apply |
| [/post-provision](.opencode/commands/post-provision.md) | Complete devbox setup after first SSH |

## Automated Dependency Updates

- **Flake inputs** (`devenv`): auto-updated by `.github/workflows/update-devenv.yml` (every 4 hours) using `DeterminateSystems/update-flake-lock`.
- **Local packages** (`beads`): auto-updated by `.github/workflows/update-packages.yml` (daily) using `nix-update`.
- Both workflows open a PR with auto-merge enabled.

## Skills

| Skill | Description |
|-------|-------------|
| [Understanding Workstation](.opencode/skills/understanding-workstation/SKILL.md) | Repo structure, concepts, navigation |
| [Setting Up Hetzner](.opencode/skills/setting-up-hetzner/SKILL.md) | Initial machine setup, hcloud context |
| [Rebuilding Devbox](.opencode/skills/rebuilding-devbox/SKILL.md) | How to apply changes, full rebuilds |
| [Troubleshooting Devbox](.opencode/skills/troubleshooting-devbox/SKILL.md) | SSH issues, host keys, NixOS problems |
| [Automated Updates](.opencode/skills/automated-updates/SKILL.md) | GitHub Actions + systemd timer update pipeline |
| [Managing Secrets](.opencode/skills/managing-secrets/SKILL.md) | Adding, removing, and using sops-nix secrets |
| [Growing Neovim Config](.opencode/skills/growing-nvim-config/SKILL.md) | How to incrementally add nvim config |
| [Gradual Dotfiles Migration](.opencode/skills/gradual-dotfiles-migration/SKILL.md) | Migrating from dotfiles to home-manager on Darwin |
| [OSC52 Clipboard](.opencode/skills/osc52-clipboard/SKILL.md) | Copy/paste over SSH, clipboard sync |
| [Screenshot to Devbox](.opencode/skills/screenshot-to-devbox/SKILL.md) | Sharing screenshots with remote OpenCode |
| [OpenCode Agents](.opencode/skills/opencode-agents/SKILL.md) | Agent set rationale, what was kept/removed and why |
| [Tracking Cache Costs](.opencode/skills/tracking-cache-costs/SKILL.md) | Measuring OpenCode prompt caching efficiency |

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
│   ├── opencode-config.nix  # OpenCode managed config + agents
│   └── opencode-skills.nix  # System-wide OpenCode skills deployed to ~/.config/opencode/skills/
├── pkgs/                  # Self-packaged tools (auto-updated by nix-update)
│   ├── beads/             # Distributed issue tracker
│   └── pinentry-op/       # macOS GPG pinentry via 1Password
├── assets/                # Content deployed to user
│   ├── opencode/          # OpenCode agents, skills, plugins, base config
│   └── nvim/              # Neovim Lua config
├── secrets/               # sops-nix encrypted secrets
└── .opencode/             # Documentation and config for THIS repo
    ├── skills/            # Repo-specific skills (auto-discovered by OpenCode)
    └── commands/          # Repo-specific slash commands
```

## Fresh Devbox Setup

After `nixos-anywhere`:
1. Copy age key: `scp /path/to/key devbox:/persist/sops-age-key.txt`
2. Clone workstation: `git clone ... ~/projects/workstation`
3. Apply system: `sudo nixos-rebuild switch --flake .#devbox`
4. Apply home: `nix run home-manager -- switch --flake .#dev`
5. Projects auto-clone on next login (or run `~/.local/bin/ensure-projects`)

## Fresh macOS Setup

1. Install Nix: `curl -L https://nixos.org/nix/install | sh`
2. Clone workstation: `git clone ... ~/Code/workstation`
3. Apply: `sudo darwin-rebuild switch --flake ~/Code/workstation#Y0FMQX93RR-2`
4. Projects auto-clone during activation (to `~/Code/`)
5. For devenv projects: `cd ~/Code/<project> && direnv allow`

## Secrets

**Devbox:** Secrets at `/run/secrets/<name>` via sops-nix. Env vars auto-exported in bash. See [Managing Secrets](.opencode/skills/managing-secrets/SKILL.md).

**macOS:** 1Password via desktop app or service account token in Keychain.

## Landing the Plane (Session Completion)

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   bd sync
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds
