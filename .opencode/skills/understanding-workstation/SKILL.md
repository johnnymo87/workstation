---
name: understanding-workstation
description: This skill explains the workstation monorepo structure, how NixOS (devbox) and nix-darwin (macOS) are organized with standalone home-manager, and how to navigate the configuration. Use this when onboarding or trying to understand how either platform is configured.
---

# Understanding Workstation Config

This repo manages four platforms with standalone home-manager:
- **NixOS devbox** — Hetzner ARM server (system: `aarch64-linux`)
- **NixOS cloudbox** — GCP ARM VM (system: `aarch64-linux`)
- **Crostini chromebook** — ChromeOS Linux container (system: `x86_64-linux`)
- **nix-darwin macOS** — MacBook Pro (system: `aarch64-darwin`)

All share the same home-manager base config. Platform differences are isolated in dedicated modules.

## Repository Structure

```
workstation/
├── flake.nix                 # Single flake: NixOS + nix-darwin + home-manager
├── flake.lock                # Pinned nixpkgs version
├── projects.nix              # Declarative project list (consumed by both platforms)
│
├── hosts/                    # System-level configurations
│   ├── devbox/               # NixOS system config
│   │   ├── configuration.nix # System packages, SSH, firewall, users
│   │   ├── hardware.nix      # Hetzner ARM-specific (boot, kernel)
│   │   └── disko.nix         # Disk partitioning
│   └── Y0FMQX93RR-2/        # macOS nix-darwin config
│
├── users/                    # Home-manager configurations
│   └── dev/
│       ├── home.nix           # Entry point (imports all modules below)
│       ├── home.base.nix      # Shared: git, bash, tmux, neovim, packages
│       ├── home.devbox.nix    # Devbox-only: identity, sops secrets
│       ├── home.cloudbox.nix  # Cloudbox-only: identity, sops secrets, work tools
│       ├── home.crostini.nix  # Crostini-only: identity, sops secrets, pigeon, opencode-serve
│       ├── home.darwin.nix    # macOS-only: launchd, ensure-projects activation, dotfiles migration
│       ├── opencode-config.nix # OpenCode managed config
│       ├── opencode-skills.nix # OpenCode skills deployed to ~/.config/opencode/skills/
│       ├── tmux.devbox.nix    # Devbox tmux extras
│       ├── tmux.cloudbox.nix  # Cloudbox tmux extras
│       ├── tmux.crostini.nix  # Crostini tmux extras
│       └── tmux.darwin.nix    # macOS tmux extras
│
├── assets/                   # Content deployed by home-manager
│   ├── opencode/             # OpenCode agents, skills, plugins, base config
│   └── nvim/                 # Neovim Lua config (lua/user/)
│
├── secrets/                  # sops-nix encrypted secrets
│
├── scripts/                  # Helper scripts
│
└── .opencode/                # THIS REPO's OpenCode documentation
    ├── skills/               # How to understand/modify this config
    └── commands/             # Repo-specific slash commands
```

## Key Concepts

### Standalone Home-Manager

Home-manager is NOT a NixOS module here. This means:

| Platform | System changes | User changes |
|----------|---------------|--------------|
| Devbox | `sudo nixos-rebuild switch --flake .#devbox` | `home-manager switch --flake .#dev` |
| macOS | `sudo darwin-rebuild switch --flake .#Y0FMQX93RR-2` | Included in darwin-rebuild |

On devbox, system and user are independent (faster iteration on user config).
On macOS, `darwin-rebuild` handles both system and home-manager in one command.

### Modular home.nix Structure

`home.nix` is just an import list:
```nix
imports = [
  ./home.base.nix        # Cross-platform (always applied)
  ./home.devbox.nix      # Guarded with lib.mkIf isDevbox
  ./home.cloudbox.nix    # Guarded with lib.mkIf isCloudbox
  ./home.crostini.nix    # Guarded with lib.mkIf isCrostini
  ./home.darwin.nix      # Guarded with lib.mkIf isDarwin
  ./opencode-config.nix
  ./opencode-skills.nix
  ./tmux.devbox.nix
  ./tmux.cloudbox.nix
  ./tmux.crostini.nix
  ./tmux.darwin.nix
];
```

All modules are imported on all platforms. Platform-specific modules use guards like `lib.mkIf isDevbox` or `lib.mkIf isDarwin` at the top level, so they evaluate to `{}` on non-matching platforms.

### Platform Identity

| Property | Devbox | Cloudbox | Crostini | macOS |
|----------|--------|----------|----------|-------|
| Username | `dev` | `dev` | `livia` | `jonathan.mohrbacher` |
| Home dir | `/home/dev` | `/home/dev` | `/home/livia` | `/Users/jonathan.mohrbacher` |
| Projects dir | `~/projects/` | `~/projects/` | `~/projects/` | `~/Code/` |
| System type | `aarch64-linux` | `aarch64-linux` | `x86_64-linux` | `aarch64-darwin` |

**CRITICAL**: Never hardcode paths like `/home/dev` or `/Users/jonathan.mohrbacher`. Always use `config.home.homeDirectory`.

### projects.nix — Declarative Project List

`projects.nix` is a simple attrset consumed by both platforms:
```nix
{
  my-project = { url = "git@github.com:org/repo.git"; };
}
```

How each platform uses it:

| Platform | Mechanism | Clone target | Trigger |
|----------|-----------|-------------|---------|
| Devbox | `~/.local/bin/ensure-projects` script + systemd service | `~/projects/` | Login (systemd) or manual script |
| Cloudbox | `~/.local/bin/ensure-projects` script + systemd service | `~/projects/` | Login (systemd) or manual script |
| Crostini | `home.activation.ensureProjects` in `home.crostini.nix` | `~/projects/` | `home-manager switch` |
| macOS | `home.activation.ensureProjects` in `home.darwin.nix` | `~/Code/` | `darwin-rebuild switch` |

### assets/ vs .opencode/

- `assets/opencode/` — Skills, agents, plugins, base config deployed TO the user's `~/.config/opencode/`
- `.opencode/` — Skills/commands for working WITH this repo (auto-discovered by OpenCode)

### pkgsFor Pattern

The flake defines `pkgsFor` once to prevent drift:

```nix
pkgsFor = system: import nixpkgs {
  inherit system;
  config.allowUnfree = true;
};
```

Both NixOS and home-manager use this, ensuring consistent packages.

### Local Packages and External Inputs

LLM tools are either self-packaged in `pkgs/` or come from flake inputs:

| Package | Source | Notes |
|---------|--------|-------|
| beads | `pkgs/beads/` | Distributed issue tracker, auto-updated daily via nix-update |
| opencode | inline in `home.base.nix` | Cached fork for aarch64, upstream for x86_64 |
| devenv | nixpkgs | Development environments (stable channel) |

Local packages are exposed as `packages.<system>.<name>` in `flake.nix` and passed to home-manager via `localPkgs`.

### Merge-on-Activate Pattern

OpenCode settings use a merge-on-activate strategy:

1. Nix generates a `*.managed.json` (read-only, in Nix store)
2. On `home-manager switch`, an activation script merges managed → runtime
3. Managed keys win on conflict; runtime-only keys are preserved
4. This lets OpenCode write its own runtime state without clobbering

Files using this pattern:
- `~/.claude/settings.managed.json` → `~/.claude/settings.json`
- `~/.config/opencode/opencode.managed.json` → `~/.config/opencode/opencode.json`

OpenCode also caches resolved plugin packages under `~/.cache/opencode`. If plugin behavior does not match the version installed in `~/.config/opencode/node_modules`, inspect and clear `~/.cache/opencode` too. Verifying only the config directory can miss a stale runtime plugin copy.

### mkOutOfStoreSymlink — Out-of-Flake Paths

When `xdg.configFile.*.source` points to a path outside the flake (e.g., a cloned project), Nix pure evaluation fails:

```
access to absolute path '/Users' is forbidden in pure evaluation mode
```

**Solution**: Use `config.lib.file.mkOutOfStoreSymlink` — it defers path resolution to activation time:
```nix
xdg.configFile."opencode/plugins/opencode-pigeon.ts".source =
  config.lib.file.mkOutOfStoreSymlink (
    if isDarwin
    then "${config.home.homeDirectory}/Code/opencode-pigeon/src/index.ts"
    else "${config.home.homeDirectory}/projects/opencode-pigeon/src/index.ts"
  );
```

### Darwin Gradual Migration

On macOS, existing dotfiles may conflict with home-manager. The strategy is:

1. Disable conflicting HM programs with `lib.mkForce false`
2. Migrate one program at a time by removing the override
3. `home.activation.prepareForHM` removes stale symlinks before HM link-checking

Currently disabled on Darwin: `bash`, `ssh`, `neovim` (using existing dotfiles instead).

### Secrets

| Platform | Mechanism | Storage |
|----------|-----------|---------|
| Devbox | sops-nix (NixOS module) | `/run/secrets/<name>`, env vars in `.bashrc` |
| Cloudbox | sops-nix (NixOS module) | `/run/secrets/<name>`, env vars in `.bashrc` |
| Crostini | sops-nix (home-manager module) | `~/.config/sops-nix/secrets/<name>` |
| macOS | macOS Keychain | `security find-generic-password -s <service> -w` |

## Common Tasks

| Task | Devbox | macOS |
|------|--------|-------|
| Apply system changes | `sudo nixos-rebuild switch --flake .#devbox` | `sudo darwin-rebuild switch --flake .#Y0FMQX93RR-2` |
| Apply user changes | `home-manager switch --flake .#dev` | (included in darwin-rebuild) |
| Update nixpkgs | `nix flake update` | `nix flake update` |
| Check flake | `nix flake check` | `nix flake check` |
| Add a project | Edit `projects.nix`, push, apply | Edit `projects.nix`, push, apply |

## Files to Edit

| Want to change... | Edit this file |
|-------------------|----------------|
| System packages (devbox) | `hosts/devbox/configuration.nix` |
| System packages (macOS) | `hosts/Y0FMQX93RR-2/configuration.nix` |
| User packages (both) | `users/dev/home.base.nix` |
| Bash aliases (both) | `users/dev/home.base.nix` (programs.bash) |
| Git config (both) | `users/dev/home.base.nix` (programs.git) |
| Devbox systemd services | `users/dev/home.devbox.nix` |
| Cloudbox systemd services | `users/dev/home.cloudbox.nix` |
| Crostini systemd user services | `users/dev/home.crostini.nix` |
| macOS launchd agents | `users/dev/home.darwin.nix` |
| macOS dotfiles migration | `users/dev/home.darwin.nix` (disabled programs) |
| Declared projects | `projects.nix` |
| OpenCode agent models | `users/dev/opencode-config.nix` (ohMyManaged) |
| OpenCode MCP servers | `users/dev/opencode-config.nix` (opencodeBase) |
| OpenCode plugins | `users/dev/opencode-config.nix` (xdg.configFile plugins) |
| OpenCode skills (deployed) | `assets/opencode/skills/` |
| OpenCode skills config | `users/dev/opencode-skills.nix` |
| Neovim config | `assets/nvim/lua/user/` |
| SSH settings | `users/dev/home.base.nix` (programs.ssh) |
| Flake inputs | `flake.nix` |
| Tmux config (shared) | `users/dev/home.base.nix` (programs.tmux) |
| Tmux config (devbox) | `users/dev/tmux.devbox.nix` |
| Tmux config (cloudbox) | `users/dev/tmux.cloudbox.nix` |
| Tmux config (crostini) | `users/dev/tmux.crostini.nix` |
| Tmux config (macOS) | `users/dev/tmux.darwin.nix` |
