# Linux-specific home-manager configuration
# Contains systemd services and other Linux-only features
{ config, pkgs, lib, projects, isLinux, ... }:

lib.mkIf isLinux {
  # Linux devbox identity
  home.username = "dev";
  home.homeDirectory = "/home/dev";

  # home.stateVersion for this platform
  home.stateVersion = "25.11";

  # Cloudflare API token for wrangler (from sops-nix secret)
  programs.bash.initExtra = lib.mkAfter ''
    if [ -r /run/secrets/cloudflare_api_token ]; then
      export CLOUDFLARE_API_TOKEN="$(cat /run/secrets/cloudflare_api_token)"
    fi

    # Personal Claude subscription token (not work account)
    # Enables headless/cron Claude Code without interactive OAuth
    if [ -r /run/secrets/claude_personal_oauth_token ]; then
      export CLAUDE_CODE_OAUTH_TOKEN="$(cat /run/secrets/claude_personal_oauth_token)"
    fi
  '';

  # Mask GPG agent units for forwarding (systemd-specific)
  # Masks both sockets AND service to prevent any local agent from starting
  home.activation.maskGpgAgentUnits = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    mkdir -p "$HOME/.config/systemd/user"
    for unit in gpg-agent.service gpg-agent.socket gpg-agent-extra.socket gpg-agent-browser.socket gpg-agent-ssh.socket; do
      ln -sf /dev/null "$HOME/.config/systemd/user/$unit"
    done
    ${pkgs.systemd}/bin/systemctl --user daemon-reload 2>/dev/null || true
  '';

  # Ensure GPG socket directory exists before SSH tries to bind RemoteForward
  systemd.user.tmpfiles.rules = [
    "d %t/gnupg 0700 - - -"
  ];

  # GPG common.conf for devbox: no-autostart prevents local agent from clobbering
  # the forwarded socket. Do NOT use use-keyboxd here (causes issues with no-autostart).
  home.file.".gnupg/common.conf".text = ''
    no-autostart
  '';

  # Generate ensure-projects script from declarative manifest
  home.file.".local/bin/ensure-projects" = {
    executable = true;
    text = let
      mkLine = name: p: ''
        ensure_repo ${lib.escapeShellArg name} ${lib.escapeShellArg p.url}
      '';
      lines = lib.concatStringsSep "\n" (lib.mapAttrsToList mkLine projects);
    in ''
      #!${pkgs.bash}/bin/bash
      set -euo pipefail

      # Refuse to run if /persist isn't mounted
      if ! ${pkgs.util-linux}/bin/findmnt -rn /persist >/dev/null; then
        echo "ERROR: /persist is not mounted; refusing to clone."
        exit 1
      fi

      # Verify SSH key exists
      if [ ! -f "$HOME/.ssh/id_ed25519_github" ]; then
        echo "ERROR: GitHub SSH key not found at ~/.ssh/id_ed25519_github"
        echo "Run: sudo nixos-rebuild switch --flake .#devbox"
        exit 1
      fi

      base="$HOME/projects"

      ensure_repo() {
        local name="$1"
        local url="$2"
        local dir="$base/$name"

        if [ -d "$dir/.git" ]; then
          echo "OK: $name exists"
          return 0
        fi

        echo "Cloning $name ..."
        ${pkgs.git}/bin/git clone --recursive "$url" "$dir"
      }

      ${lines}

      echo "All projects ready."
    '';
  };

  # Systemd user service to ensure projects on login
  systemd.user.services.ensure-projects = {
    Unit = {
      Description = "Ensure declared dev projects are present in ~/projects";
      After = [ "network-online.target" ];
      Wants = [ "network-online.target" ];
    };
    Service = {
      Type = "oneshot";
      ExecStart = "%h/.local/bin/ensure-projects";
      StandardOutput = "journal";
      StandardError = "journal";
      Environment = [
        "GIT_SSH_COMMAND=${pkgs.openssh}/bin/ssh"
        "HOME=%h"
      ];
    };
    Install = {
      WantedBy = [ "default.target" ];
    };
  };

  # Auto-expire old home-manager generations
  # System nix.gc runs weekly; this cleans up HM generations daily
  services.home-manager.autoExpire = {
    enable = true;
    frequency = "daily";
    timestamp = "-7 days";
    store.cleanup = true;  # Also run nix-collect-garbage for user store
  };

  # Script to pull workstation updates and apply home-manager
  home.file.".local/bin/pull-workstation" = {
    executable = true;
    text = ''
      #!${pkgs.bash}/bin/bash
      set -euo pipefail

      repo="$HOME/projects/workstation"
      lock_dir="''${XDG_RUNTIME_DIR:-/tmp}"
      lock="$lock_dir/pull-workstation.lock"

      # Prevent concurrent runs
      exec 9>"$lock"
      ${pkgs.util-linux}/bin/flock -n 9 || { echo "Already running"; exit 0; }

      cd "$repo"

      # Fail if working tree is dirty
      if [[ -n "$(${pkgs.git}/bin/git status --porcelain)" ]]; then
        echo "Working tree not clean; skipping auto-pull"
        exit 0
      fi

      # Fetch and pull if there are updates
      ${pkgs.git}/bin/git fetch origin

      local_rev=$(${pkgs.git}/bin/git rev-parse HEAD)
      remote_rev=$(${pkgs.git}/bin/git rev-parse origin/main)

      if [[ "$local_rev" != "$remote_rev" ]]; then
        echo "Pulling updates..."
        # Fast-forward only (fail if diverged)
        ${pkgs.git}/bin/git pull --ff-only origin main
      else
        echo "Git already up to date"
      fi

      # Always attempt switch (handles retry after failed switch)
      echo "Applying home-manager..."
      ${pkgs.nix}/bin/nix run github:nix-community/home-manager/release-25.11 -- switch --flake "$repo#dev"

      echo "Update complete"
    '';
  };

  # Systemd service to pull and apply workstation updates
  systemd.user.services.pull-workstation = {
    Unit = {
      Description = "Pull workstation updates and apply home-manager";
    };
    Service = {
      Type = "oneshot";
      ExecStart = "%h/.local/bin/pull-workstation";
      StandardOutput = "journal";
      StandardError = "journal";
      Environment = [
        "HOME=%h"
        "GIT_SSH_COMMAND=${pkgs.openssh}/bin/ssh -i %h/.ssh/id_ed25519_github -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes"
      ];
    };
  };

  # Timer: run at startup + every 4 hours
  systemd.user.timers.pull-workstation = {
    Unit = {
      Description = "Pull workstation updates periodically";
    };
    Timer = {
      OnStartupSec = "10min";        # Run 10min after boot/login
      OnUnitInactiveSec = "4h";       # Then every 4h after last run
      RandomizedDelaySec = "15min";   # Jitter to avoid thundering herd
    };
    Install = {
      WantedBy = [ "timers.target" ];
    };
  };
}
