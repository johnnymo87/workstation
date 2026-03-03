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
    python3     # Required by Docker image build steps
    coreutils   # dirname, mkdir, cat, etc. (explicit for restricted PATH contexts)
    gnused      # sed (explicit for restricted PATH contexts)

    # Cloud / Kubernetes
    # NOTE: azure-cli 2.79.0 ships msal 1.33.0 which has a bug where
    # `az login --use-device-code` crashes with "Session.request() got
    # an unexpected keyword argument 'claims_challenge'". Fixed in msal 1.34.0.
    # Remove this block when nixpkgs bumps azure-cli to >= 2.83.0.
    (let
      msal134 = pkgs.python3Packages.msal.overridePythonAttrs (old: rec {
        version = "1.34.0";
        src = pkgs.python3Packages.fetchPypi {
          inherit (old) pname;
          inherit version;
          hash = "sha256-drqDtxbqWm11sCecCsNToOBbggyh9mgsDrf0UZDEPC8=";
        };
      });
      msal134Path = "${msal134}/${pkgs.python3.sitePackages}";
      msal133 = pkgs.python3Packages.msal;
      msal133Path = "${msal133}/${pkgs.python3.sitePackages}";
      azWithExts = azure-cli.withExtensions (with azure-cli.extensions; [
        azure-devops
      ]);
    in azWithExts.overrideAttrs (old: {
      # withExtensions creates wrapper scripts with hardcoded msal 1.33.0
      # store paths. Patch them to use msal 1.34.0 instead.
      postFixup = (old.postFixup or "") + ''
        for f in $out/bin/az $out/bin/.az-wrapped $out/bin/.az-wrapped_; do
          if [ -f "$f" ]; then
            substituteInPlace "$f" \
              --replace-quiet "${msal133Path}" "${msal134Path}"
          fi
        done
      '';
    }))
    awscli2          # AWS CLI (EKS kubeconfig credential plugin)
    kubelogin        # Azure AD credential plugin for kubectl
    kubectl          # Kubernetes CLI (for AKS clusters)
    google-cloud-sdk # GCP VM management (gcloud, gsutil, bq)
  ];

  # GCP project: read from sops in initExtra below (org-identifying, not in public source)

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

    # Atlassian API token for acli / nvim Atlassian commands
    if [ -r /run/secrets/atlassian_api_token ]; then
      export ATLASSIAN_API_TOKEN="$(cat /run/secrets/atlassian_api_token)"
    fi

    # Atlassian org config (non-secret but org-identifying)
    if [ -r /run/secrets/atlassian_site ]; then
      export ATLASSIAN_SITE="$(cat /run/secrets/atlassian_site)"
    fi

    if [ -r /run/secrets/atlassian_email ]; then
      export ATLASSIAN_EMAIL="$(cat /run/secrets/atlassian_email)"
    fi

    if [ -r /run/secrets/atlassian_cloud_id ]; then
      export ATLASSIAN_CLOUD_ID="$(cat /run/secrets/atlassian_cloud_id)"
    fi

    # GCP project for Vertex AI
    if [ -r /run/secrets/google_cloud_project ]; then
      export GOOGLE_CLOUD_PROJECT="$(cat /run/secrets/google_cloud_project)"
    fi

    # Azure DevOps PAT for private artifact registry
    if [ -r /run/secrets/azure_devops_pat ]; then
      export SYSTEM_ACCESSTOKEN="$(cat /run/secrets/azure_devops_pat)"
    fi

    # ba CLI config (org-identifying, used by install-ba activation script and ba login)
    if [ -r /run/secrets/ba_cli_repo ]; then
      export BA_CLI_REPO="$(cat /run/secrets/ba_cli_repo)"
    fi

    # ba uses GITHUB_API_TOKEN (same token as GH_TOKEN, different var name)
    if [ -r /run/secrets/github_api_token ]; then
      export GITHUB_API_TOKEN="$(cat /run/secrets/github_api_token)"
    fi

    # Jenkins credentials (for ba login)
    if [ -r /run/secrets/jenkins_api_token ]; then
      export JENKINS_API_TOKEN="$(cat /run/secrets/jenkins_api_token)"
    fi
    if [ -r /run/secrets/jenkins_user ]; then
      export JENKINS_USER="$(cat /run/secrets/jenkins_user)"
    fi

    # Enable Exa AI-backed websearch and codesearch tools in OpenCode.
    export OPENCODE_ENABLE_EXA=1
  '';

  # Install/update ba CLI from private GitHub release
  # Downloads linux-arm64 binary via gh CLI, caches by version in ~/.local/bin
  home.activation.installBaCli = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    ba_repo=""
    if [ -r /run/secrets/ba_cli_repo ]; then
      ba_repo="$(cat /run/secrets/ba_cli_repo)"
    fi

    if [ -z "$ba_repo" ]; then
      echo "installBaCli: skipping (ba_cli_repo secret not available)"
    else
      gh_token=""
      if [ -r /run/secrets/github_api_token ]; then
        gh_token="$(cat /run/secrets/github_api_token)"
      fi

      if [ -z "$gh_token" ]; then
        echo "installBaCli: skipping (github_api_token not available)"
      else
        latest=$(GH_TOKEN="$gh_token" ${pkgs.gh}/bin/gh api \
          "repos/$ba_repo/releases/latest" --jq .tag_name 2>/dev/null || true)

        if [ -z "$latest" ]; then
          echo "installBaCli: WARNING: could not fetch latest release"
        else
          current=""
          if [ -x "$HOME/.local/bin/ba" ]; then
            current=$("$HOME/.local/bin/ba" --version 2>/dev/null \
              | ${pkgs.gnugrep}/bin/grep -oP 'v?\K[0-9]+\.[0-9]+\.[0-9]+' \
              | head -1 || true)
          fi

          if [ "$current" = "$latest" ]; then
            echo "installBaCli: ba $latest already installed"
          else
            echo "installBaCli: installing ba $latest (was: ''${current:-not installed})..."
            ${pkgs.coreutils}/bin/mkdir -p "$HOME/.local/bin"
            tmpdir=$(${pkgs.coreutils}/bin/mktemp -d)
            if GH_TOKEN="$gh_token" ${pkgs.gh}/bin/gh release download "$latest" \
                 --repo "$ba_repo" \
                 -p 'ba-linux-arm64.tar.gz' \
                 -D "$tmpdir" 2>/dev/null; then
              ${pkgs.gnutar}/bin/tar --use-compress-program=${pkgs.gzip}/bin/gzip -xf "$tmpdir/ba-linux-arm64.tar.gz" -C "$tmpdir"
              ${pkgs.coreutils}/bin/install -m 755 "$tmpdir/ba" "$HOME/.local/bin/ba"
              echo "installBaCli: ba $latest installed"
            else
              echo "installBaCli: WARNING: download failed"
            fi
            ${pkgs.coreutils}/bin/rm -rf "$tmpdir"
          fi
        fi
      fi
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
