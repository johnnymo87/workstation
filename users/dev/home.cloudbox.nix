# Cloudbox (GCP ARM) home-manager configuration
# Contains systemd services, sops secrets, and other cloudbox-only features
#
# Closely mirrors home.devbox.nix but without:
#   - /persist volume checks (GCP uses single persistent boot disk)
#   - claude_personal_oauth_token (work machine, uses work auth)
# And uses #cloudbox for the pull-workstation HM flake target.
{ config, pkgs, lib, projects, isCloudbox, ... }:

lib.mkIf isCloudbox {
  # Cloudbox identity
  home.username = "dev";
  home.homeDirectory = "/home/dev";

  home.stateVersion = "25.11";

  # Developer tooling (project-specific)
  home.packages = with pkgs; [
    bazelisk    # Bazel version manager (respects .bazelversion)
    buf         # Protobuf linting, breaking change detection, codegen
    protobuf    # protoc compiler

    # Cloud / Kubernetes
    # NOTE: azure-cli 2.79.0 ships msal 1.33.0 which has a bug where
    # `az login --use-device-code` crashes with "Session.request() got
    # an unexpected keyword argument 'claims_challenge'". Fixed in msal 1.34.0.
    # Remove this workaround when nixpkgs bumps azure-cli to >= 2.83.0.
    # The msal override is applied via a pkgs overlay in flake.nix.
    (azure-cli.withExtensions (with azure-cli.extensions; [
      azure-devops
    ]))
    kubelogin        # Azure AD credential plugin for kubectl
    kubectl          # Kubernetes CLI (for AKS clusters)
    google-cloud-sdk # GCP VM management (gcloud, gsutil, bq)
  ];

  # Export secrets from sops-nix (system-level decryption to /run/secrets/)
  programs.bash.initExtra = lib.mkAfter ''
    # Alias bazelisk as bazel (projects expect `bazel` on PATH)
    alias bazel=bazelisk

    # GitHub API token for gh CLI
    if [ -r /run/secrets/github_api_token ]; then
      export GH_TOKEN="$(cat /run/secrets/github_api_token)"
    fi

    if [ -r /run/secrets/cloudflare_api_token ]; then
      export CLOUDFLARE_API_TOKEN="$(cat /run/secrets/cloudflare_api_token)"
    fi

    # Gemini API key for OpenCode's @ai-sdk/google provider (direct API)
    if [ -r /run/secrets/gemini_api_key ]; then
      export GOOGLE_GENERATIVE_AI_API_KEY="$(cat /run/secrets/gemini_api_key)"
    fi

    # Enable Exa AI-backed websearch and codesearch tools in OpenCode.
    export OPENCODE_ENABLE_EXA=1
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

  # GPG common.conf: no-autostart prevents local agent from clobbering
  # the forwarded socket from macOS.
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

      # Verify SSH key exists
      if [ ! -f "$HOME/.ssh/id_ed25519_github" ]; then
        echo "ERROR: GitHub SSH key not found at ~/.ssh/id_ed25519_github"
        echo "Run: sudo nixos-rebuild switch --flake .#cloudbox"
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

      ${pkgs.coreutils}/bin/mkdir -p "$base"
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
  services.home-manager.autoExpire = {
    enable = true;
    frequency = "daily";
    timestamp = "-7 days";
    store.cleanup = true;
  };

  # Git SSH wrapper for systemd services (avoids Environment= quoting issues)
  home.file.".local/bin/git-ssh-github" = {
    executable = true;
    text = ''
      #!${pkgs.bash}/bin/bash
      exec ${pkgs.openssh}/bin/ssh \
        -i "$HOME/.ssh/id_ed25519_github" \
        -o IdentitiesOnly=yes \
        -o BatchMode=yes \
        -o StrictHostKeyChecking=yes \
        "$@"
    '';
  };

  # Script to pull workstation updates and apply home-manager
  home.file.".local/bin/pull-workstation" = {
    executable = true;
    text = ''
      #!${pkgs.bash}/bin/bash
      set -euo pipefail

      export GIT_SSH_COMMAND="$HOME/.local/bin/git-ssh-github"

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
        ${pkgs.git}/bin/git pull --ff-only origin main
      else
        echo "Git already up to date"
      fi

      # Always attempt switch (handles retry after failed switch)
      echo "Applying home-manager..."
      ${pkgs.nix}/bin/nix run github:nix-community/home-manager/release-25.11 -- switch --flake "$repo#cloudbox"

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
        "PATH=${pkgs.nix}/bin:${pkgs.git}/bin:/run/current-system/sw/bin:/run/wrappers/bin"
      ];
    };
  };

  # Timer: run at startup + every 4 hours
  systemd.user.timers.pull-workstation = {
    Unit = {
      Description = "Pull workstation updates periodically";
    };
    Timer = {
      OnStartupSec = "10min";
      OnUnitInactiveSec = "4h";
      RandomizedDelaySec = "15min";
    };
    Install = {
      WantedBy = [ "timers.target" ];
    };
  };
}
