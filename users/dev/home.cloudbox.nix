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

    # Cloud / Tunnels (kubectl, kubelogin, awscli2, azure-cli are in home.base.nix)
    cloudflared      # Cloudflare Tunnel client (Access-protected API calls)
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

    # Save default Atlassian credentials for round-tripping
    export ATLASSIAN_DEFAULT_SITE="''${ATLASSIAN_SITE:-}"
    export ATLASSIAN_DEFAULT_EMAIL="''${ATLASSIAN_EMAIL:-}"
    export ATLASSIAN_DEFAULT_CLOUD_ID="''${ATLASSIAN_CLOUD_ID:-}"
    export ATLASSIAN_DEFAULT_API_TOKEN="''${ATLASSIAN_API_TOKEN:-}"

    # Load alt Atlassian credentials (from sops)
    if [ -r /run/secrets/atlassian_alt_site ]; then
      export ATLASSIAN_ALT_SITE="$(cat /run/secrets/atlassian_alt_site)"
    fi

    if [ -r /run/secrets/atlassian_alt_email ]; then
      export ATLASSIAN_ALT_EMAIL="$(cat /run/secrets/atlassian_alt_email)"
    fi

    if [ -r /run/secrets/atlassian_alt_cloud_id ]; then
      export ATLASSIAN_ALT_CLOUD_ID="$(cat /run/secrets/atlassian_alt_cloud_id)"
    fi

    if [ -r /run/secrets/atlassian_alt_api_token ]; then
      export ATLASSIAN_ALT_API_TOKEN="$(cat /run/secrets/atlassian_alt_api_token)"
    fi

    # Switch Atlassian profile function
    switch-atlassian() {
      case "''${1:-}" in
        default)
          export ATLASSIAN_SITE="''${ATLASSIAN_DEFAULT_SITE:-}"
          export ATLASSIAN_EMAIL="''${ATLASSIAN_DEFAULT_EMAIL:-}"
          export ATLASSIAN_CLOUD_ID="''${ATLASSIAN_DEFAULT_CLOUD_ID:-}"
          export ATLASSIAN_API_TOKEN="''${ATLASSIAN_DEFAULT_API_TOKEN:-}"
          echo "Switched to default Atlassian instance (''${ATLASSIAN_SITE})"
          ;;
        alt)
          if [ -z "''${ATLASSIAN_ALT_SITE:-}" ]; then
            echo "Error: alt Atlassian credentials not found in secrets"
            return 1
          fi
          export ATLASSIAN_SITE="''${ATLASSIAN_ALT_SITE:-}"
          export ATLASSIAN_EMAIL="''${ATLASSIAN_ALT_EMAIL:-}"
          export ATLASSIAN_CLOUD_ID="''${ATLASSIAN_ALT_CLOUD_ID:-}"
          export ATLASSIAN_API_TOKEN="''${ATLASSIAN_ALT_API_TOKEN:-}"
          echo "Switched to alt Atlassian instance (''${ATLASSIAN_SITE})"
          ;;
        *)
          echo "Usage: switch-atlassian default|alt"
          echo "Current: ''${ATLASSIAN_SITE:-not set}"
          return 1
          ;;
      esac
    }

    # GCP project for Vertex AI
    if [ -r /run/secrets/google_cloud_project ]; then
      export GOOGLE_CLOUD_PROJECT="$(cat /run/secrets/google_cloud_project)"
    fi

    # Azure DevOps PAT for private artifact registry
    if [ -r /run/secrets/azure_devops_pat ]; then
      export SYSTEM_ACCESSTOKEN="$(cat /run/secrets/azure_devops_pat)"
      export ADO_NPM_PAT_B64="$(printf '%s' "$SYSTEM_ACCESSTOKEN" | base64 -w0)"
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

    # Bundler private gem source credentials
    if [ -r /run/secrets/bundle_gem_fury_io ]; then
      export BUNDLE_GEM__FURY__IO="$(cat /run/secrets/bundle_gem_fury_io)"
    fi
    if [ -r /run/secrets/bundle_enterprise_contribsys_com ]; then
      export BUNDLE_ENTERPRISE__CONTRIBSYS__COM="$(cat /run/secrets/bundle_enterprise_contribsys_com)"
    fi
    if [ -r /run/secrets/bundle_gems_graphql_pro ]; then
      export BUNDLE_GEMS__GRAPHQL__PRO="$(cat /run/secrets/bundle_gems_graphql_pro)"
    fi
    if [ -r /run/secrets/bundle_fury_freshrealm_com ]; then
      export BUNDLE_FURY__FRESHREALM__COM="$(cat /run/secrets/bundle_fury_freshrealm_com)"
    fi

    # Datadog CLI credentials (dd-cli)
    export DD_SITE="us3.datadoghq.com"
    if [ -r /run/secrets/dd_api_key ]; then
      export DD_API_KEY="$(cat /run/secrets/dd_api_key)"
    fi
    if [ -r /run/secrets/dd_app_key ]; then
      export DD_APP_KEY="$(cat /run/secrets/dd_app_key)"
    fi

    # Google Workspace CLI: point to assembled credentials
    export GOOGLE_WORKSPACE_CLI_CONFIG_DIR="$HOME/.config/gws"

    # Enable Exa AI-backed websearch and codesearch tools in OpenCode.
    export OPENCODE_ENABLE_EXA=1
  '';

  # installBaCli is in home.base.nix (shared between cloudbox and macOS)

  # Assemble gws config files from sops secrets at activation time
  # Both client_secret.json (OAuth client config, needed for re-auth)
  # and credentials.json (authorized_user tokens) are assembled from
  # the same sops secrets to avoid committing secrets to git.
  home.activation.assembleGwsCredentials = lib.hm.dag.entryAfter [ "writeBoundary" "linkGeneration" ] ''
    set -euo pipefail

    gws_dir="$HOME/.config/gws"

    # Read secrets from sops-decrypted files
    client_id=""
    client_secret=""
    refresh_token=""
    project_id=""
    if [ -r /run/secrets/gws_client_id ]; then
      client_id="$(cat /run/secrets/gws_client_id)"
    fi
    if [ -r /run/secrets/gws_client_secret ]; then
      client_secret="$(cat /run/secrets/gws_client_secret)"
    fi
    if [ -r /run/secrets/gws_refresh_token ]; then
      refresh_token="$(cat /run/secrets/gws_refresh_token)"
    fi
    if [ -r /run/secrets/google_cloud_project ]; then
      project_id="$(cat /run/secrets/google_cloud_project)"
    fi

    # Skip if any secret is missing
    if [ -z "$client_id" ] || [ -z "$client_secret" ] || [ -z "$refresh_token" ] || [ -z "$project_id" ]; then
      echo "assembleGwsCredentials: skipping (gws secrets not available)"
      exit 0
    fi

    mkdir -p "$gws_dir"

    # Assemble client_secret.json (OAuth client config for re-auth / token refresh)
    tmp="$(mktemp "''${gws_dir}/client_secret.json.tmp.XXXXXX")"
    ${pkgs.jq}/bin/jq -n \
      --arg cid "$client_id" \
      --arg cs "$client_secret" \
      --arg pid "$project_id" \
      '{
        installed: {
          client_id: $cid,
          project_id: $pid,
          auth_uri: "https://accounts.google.com/o/oauth2/auth",
          token_uri: "https://oauth2.googleapis.com/token",
          auth_provider_x509_cert_url: "https://www.googleapis.com/oauth2/v1/certs",
          client_secret: $cs,
          redirect_uris: ["http://localhost"]
        }
      }' > "$tmp"
    mv "$tmp" "$gws_dir/client_secret.json"
    chmod 600 "$gws_dir/client_secret.json"

    # Assemble credentials.json (authorized_user tokens for API access)
    tmp="$(mktemp "''${gws_dir}/credentials.json.tmp.XXXXXX")"
    ${pkgs.jq}/bin/jq -n \
      --arg cid "$client_id" \
      --arg cs "$client_secret" \
      --arg rt "$refresh_token" \
      '{
        type: "authorized_user",
        client_id: $cid,
        client_secret: $cs,
        refresh_token: $rt
      }' > "$tmp"
    mv "$tmp" "$gws_dir/credentials.json"
    chmod 600 "$gws_dir/credentials.json"

    echo "assembleGwsCredentials: client_secret.json and credentials.json assembled"
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
