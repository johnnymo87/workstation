# Cloudbox (GCP ARM) home-manager configuration
# Contains systemd services, sops secrets, and other cloudbox-only features
#
# Closely mirrors home.devbox.nix but without:
#   - /persist volume checks (GCP uses single persistent boot disk)
# And uses #cloudbox for the pull-workstation HM flake target.
{ config, pkgs, lib, localPkgs, projects, isCloudbox, assetsPath, ... }:

let
  # Serve-pool descriptor: the SAME single source of truth the serve units and
  # pigeon read (users/dev/serve-pool.nix). The pool-auth CLI below must never
  # hardcode ports -- a stale port list would write the credential to a serve
  # that no longer exists and silently skip one that does.
  # Single source of truth for the bazel slice name (bead workstation-mqp3).
  #
  # It is used TWICE: the shim passes it to `systemd-run --slice=`, and the slice
  # unit below is declared under it. They must agree. If they ever diverge,
  # systemd-run does not fail -- it silently creates a transient slice of that
  # name with NO limits, the 16G aggregate cap disappears, and nothing goes red
  # until the host OOMs. That is exactly the silent-failure class this whole
  # change exists to eliminate, so the name is bound once here rather than
  # written as a literal in two places.
  bazelSliceName = "bazel";

  # Slice for agent-spawned bash-tool commands. The OTHER side of this name is
  # the `sliceName` passed to `pkgs/oc-scoped-shell` (configured via opencode's `shell`
  # config key in users/dev/opencode-config.nix), which cannot import Nix. They are tied
  # together by the `agent-slice-wiring` check in flake.nix rather than by convention,
  # for exactly the reason spelled out on bazel-slice-wiring: `systemd-run --slice=NAME`
  # does NOT fail on a slice that was never declared. It creates a transient one with no
  # limits, so a rename on either side stays green and silently unbounded until the host OOMs.
  agentSliceName = "oc-agent";
  bazelScope = pkgs.callPackage ../../pkgs/bazel-scope {
    sliceName = bazelSliceName;
  };

  # Memory + PSI sampler. Separate from the S2 series on purpose -- see the long
  # comment in pkgs/pressure-sampler/default.nix.
  pressureSampler = pkgs.callPackage ../../pkgs/pressure-sampler { };

  # Shared alert helper (dedup by signature, exponential backoff, warning->error
  # escalation, POST to pigeon's /alert). Same package the cloudbox canaries and
  # devbox's frontdoor canary use -- do not fork it.
  driftAlert = pkgs.callPackage ../../pkgs/opencode-drift-alert { };

  servePool = (import ./serve-pool.nix).forHost.cloudbox;
  anchorUrl = builtins.head servePool.endpoints;
  allEndpoints = builtins.concatStringsSep " " servePool.endpoints;

  # opencode-pool-auth: the escape hatch for provider-credential mutation,
  # which the front door denies (see pkgs/opencode-frontdoor/src/routes.dispositions.ts
  # and docs/plans/2026-07-26-mlve11-d4-mechanisms.md).
  #
  # Why a CLI and not a door feature: the door cannot make these routes correct.
  # auth.json is shared, but every serve memoizes it into a Provider cache whose
  # only invalidation path is instance disposal, so an anchor-forwarded write
  # returns 200 while the rest of the pool keeps the old credential forever. The
  # correct sequence is write-once-then-dispose-everywhere, and a CLI can block
  # for minutes where the door's 5s first-byte timeout cannot.
  #
  # Two deliberate design choices, both learned the hard way:
  #  - The credential is read from a FILE or stdin, never from argv. Anything in
  #    argv is world-readable in `ps` for the lifetime of the process.
  #  - The write goes to exactly ONE port. Writing all four is strictly worse:
  #    auth.json is a whole-document read-modify-write with no lock
  #    (auth/index.ts:73-81), so four concurrent writers quadruple the
  #    lost-update window against a background token refresh, for zero benefit.
  opencode-pool-auth = pkgs.writeShellApplication {
    name = "opencode-pool-auth";
    runtimeInputs = [ pkgs.curl pkgs.jq ];
    text = ''
      # shellcheck disable=SC1091  # sourced from a nix store path shellcheck cannot follow
      source "${localPkgs.opencode-serve-auth-sh}"
      serve_auth_load

      ANCHOR="${anchorUrl}"
      ALL_ENDPOINTS=(${allEndpoints})

      usage() {
        cat >&2 <<USAGE
      Usage:
        opencode-pool-auth set <providerID> (--file <path> | --stdin) [--yes]
        opencode-pool-auth remove <providerID> [--yes]

      Mutate a provider credential across the whole opencode serve pool.

      The front door denies these routes on purpose: a write delivered to one
      serve returns 200 while the other members keep using the previous
      credential indefinitely, because each caches auth.json in memory until its
      instance is disposed. This command does the only correct sequence --
      write once, then dispose every member so they all re-read from disk.

      DISRUPTIVE. The dispose step cancels EVERY in-flight run on each serve,
      for every directory, and SIGTERMs its stdio MCP children. Expect a
      cold-boot latency spike afterwards. Use it for deliberate credential
      rotation, not casually.

      Options:
        --file <path>  Read the credential JSON from a file.
        --stdin        Read the credential JSON from stdin.
                       (The credential is never passed via argv, which would be
                       visible in ps to every user on the box.)
        --yes          Skip the confirmation prompt.

      Examples:
        opencode-pool-auth set anthropic --file ./creds.json
        pass show anthropic | opencode-pool-auth set anthropic --stdin
        opencode-pool-auth remove anthropic --yes
      USAGE
        exit 2
      }

      [ $# -ge 2 ] || usage
      ACTION="$1"; shift
      PROVIDER="$1"; shift

      CRED_FILE=""
      USE_STDIN=0
      ASSUME_YES=0
      while [ $# -gt 0 ]; do
        case "$1" in
          --file) shift; [ $# -gt 0 ] || usage; CRED_FILE="$1" ;;
          --stdin) USE_STDIN=1 ;;
          --yes|-y) ASSUME_YES=1 ;;
          *) echo "opencode-pool-auth: unknown argument '$1'" >&2; usage ;;
        esac
        shift
      done

      case "$ACTION" in
        set|remove) ;;
        *) echo "opencode-pool-auth: unknown action '$ACTION'" >&2; usage ;;
      esac

      PAYLOAD=""
      if [ "$ACTION" = "set" ]; then
        if [ "$USE_STDIN" -eq 1 ]; then
          PAYLOAD="$(cat)"
        elif [ -n "$CRED_FILE" ]; then
          [ -r "$CRED_FILE" ] || { echo "opencode-pool-auth: cannot read $CRED_FILE" >&2; exit 1; }
          PAYLOAD="$(cat -- "$CRED_FILE")"
        else
          echo "opencode-pool-auth: 'set' needs --file <path> or --stdin" >&2
          usage
        fi
        # Fail before touching the pool rather than writing a corrupt auth.json:
        # the writer does a whole-document RMW and a torn/invalid document is
        # read back as "no credentials at all" (auth/index.ts:65).
        echo "$PAYLOAD" | jq -e . >/dev/null 2>&1 || {
          echo "opencode-pool-auth: credential payload is not valid JSON; refusing to write" >&2
          exit 1
        }
      fi

      echo "About to $ACTION provider credential '$PROVIDER' across ''${#ALL_ENDPOINTS[@]} serve(s)." >&2
      echo "  1. write once  -> $ANCHOR" >&2
      echo "  2. dispose all -> ''${ALL_ENDPOINTS[*]}" >&2
      echo "" >&2
      echo "Step 2 CANCELS EVERY IN-FLIGHT RUN on each serve and SIGTERMs its MCP children." >&2

      if [ "$ASSUME_YES" -ne 1 ]; then
        printf 'Continue? [y/N] ' >&2
        read -r reply
        case "$reply" in
          y|Y|yes|YES) ;;
          *) echo "opencode-pool-auth: aborted; nothing was changed." >&2; exit 1 ;;
        esac
      fi

      # --- Step 1: write ONCE ---------------------------------------------
      if [ "$ACTION" = "set" ]; then
        CODE=$(printf '%s' "$PAYLOAD" | curl -sS -o /dev/null -w '%{http_code}' \
          ''${SERVE_AUTH_CURL_ARGS[@]+"''${SERVE_AUTH_CURL_ARGS[@]}"} \
          -X PUT "$ANCHOR/auth/$PROVIDER" \
          -H 'Content-Type: application/json' --data-binary @-) || {
            echo "opencode-pool-auth: write to $ANCHOR failed (curl error); pool unchanged." >&2
            exit 1
          }
      else
        CODE=$(curl -sS -o /dev/null -w '%{http_code}' \
          ''${SERVE_AUTH_CURL_ARGS[@]+"''${SERVE_AUTH_CURL_ARGS[@]}"} \
          -X DELETE "$ANCHOR/auth/$PROVIDER") || {
            echo "opencode-pool-auth: delete on $ANCHOR failed (curl error); pool unchanged." >&2
            exit 1
          }
      fi

      case "$CODE" in
        2*) echo "write ok ($CODE) on $ANCHOR" >&2 ;;
        *)
          echo "opencode-pool-auth: write returned HTTP $CODE from $ANCHOR." >&2
          echo "  NOT disposing: the pool is unchanged, and disposing now would" >&2
          echo "  cancel running work for no reason." >&2
          exit 1
          ;;
      esac

      # --- Step 2: dispose EVERYWHERE --------------------------------------
      # Sequential and best-effort: a member that fails to dispose keeps a stale
      # credential, so report it loudly rather than exiting on the first error.
      FAILED=()
      for ep in "''${ALL_ENDPOINTS[@]}"; do
        DCODE=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 120 \
          ''${SERVE_AUTH_CURL_ARGS[@]+"''${SERVE_AUTH_CURL_ARGS[@]}"} \
          -X POST "$ep/global/dispose" || echo "000")
        case "$DCODE" in
          2*) echo "disposed $ep ($DCODE)" >&2 ;;
          *)  echo "DISPOSE FAILED $ep (HTTP $DCODE)" >&2; FAILED+=("$ep") ;;
        esac
      done

      if [ ''${#FAILED[@]} -gt 0 ]; then
        echo "" >&2
        echo "opencode-pool-auth: the credential WAS written, but ''${#FAILED[@]} serve(s) were not disposed:" >&2
        printf '  %s\n' "''${FAILED[@]}" >&2
        echo "Those serves will keep using the PREVIOUS credential until they restart." >&2
        echo "Re-run the dispose by hand, or restart them, before assuming the rotation took." >&2
        exit 1
      fi

      echo "" >&2
      echo "opencode-pool-auth: done. All serves re-read auth.json on next use." >&2
    '';
  };
in
lib.mkIf isCloudbox {
  # Cloudbox identity
  home.username = "dev";
  home.homeDirectory = "/home/dev";

  home.stateVersion = "25.11";

  # SSH alias for driving the macOS box from a cloudbox-side agent. Reaches the
  # Mac via the reverse tunnel (cloudbox 127.0.0.1:2222 -> Mac :22).
  #
  # SECURITY (2026-07): this reverse tunnel is NO LONGER always-on. It only
  # exists while a human on the Mac runs `ssh cloudbox-cutover` (see the
  # cloudbox-cutover host in scripts/update-ssh-config.sh). Outside that window
  # `ssh mac` from cloudbox will fail (connection refused on :2222) — expected.
  # Additionally, unattended passwordless root via darwin-rebuild is disabled on
  # the Mac (enableUnattendedRemoteRoot in hosts/Y0FMQX93RR-2/configuration.nix).
  # Auth: ~/.ssh/id_mac (trusted in the Mac's JumpCloud-managed authorized_keys).
  # For operator-initiated remote cutovers / darwin-rebuild.
  programs.ssh.matchBlocks.mac = {
    hostname = "127.0.0.1";
    port = 2222;
    user = "jonathan.mohrbacher";
    identityFile = "~/.ssh/id_mac";
    identitiesOnly = true;
    extraOptions = {
      StrictHostKeyChecking = "accept-new";
      UserKnownHostsFile = "~/.ssh/known_hosts_mac";
    };
  };

  # Constrain vitest worker count — default uses all cores, which starves
  # opencode sessions and devenv services when tests run in watch mode.
  home.sessionVariables.VITEST_MAX_WORKERS = "2";  # 4-core box, keep 50% free

  # Guard: abort activation if running on the wrong machine.
  # Devbox and cloudbox share arch, user, and home dir -- applying the wrong
  # flake target silently deploys incorrect config (wrong secrets, /persist
  # assumptions, wrong pull-workstation target) and is hard to diagnose.
  home.activation.assertPlatform =
    lib.hm.dag.entryBefore [ "writeBoundary" ] ''
      current="$(cat /etc/hostname 2>/dev/null || echo unknown)"
      if [ "$current" != "cloudbox" ]; then
        echo "FATAL: flake target #cloudbox is for cloudbox, but running on $current." >&2
        echo "Use --flake .#$current (or the correct target) instead." >&2
        exit 1
      fi
    '';

  # Developer tooling (project-specific)
  home.packages = with pkgs; [

    # `bazel` on PATH is a SHIM, not bazelisk (bead workstation-mqp3). It re-execs
    # the build inside `systemd-run --user --scope --slice=bazel`, so bazel is
    # charged to bazel.slice (declared below) instead of to the cgroup of whatever
    # spawned it. Under `opencode serve` that cgroup is
    # opencode-serve@<port>.service, MemoryMax=14G, OOMPolicy=stop -- so a build
    # that OOMs there restarts the whole serve and destroys every session on it.
    # That happened four times in ~6h on 2026-08-03/04 (960 HTTP 502s at the door).
    #
    # This provides bin/bazel and MUST win over the legacy ~/.local/bin/bazel
    # symlink. It does: ~/.nix-profile/bin precedes ~/.local/bin both in the login
    # PATH and in the serve unit's own `path=`. The activation below repoints that
    # legacy symlink anyway, for callers that bypass PATH order.
    # Provides BOTH `bazel` and `bazelisk`. The real bazelisk is deliberately NOT
    # a separate entry here any more: it would sit on PATH as a fully unscoped
    # bypass for anyone -- human or agent -- who types `bazelisk build`. The shim
    # reaches the real bazelisk by absolute store path instead.
    bazelScope
    buf         # Protobuf linting, breaking change detection, codegen
    protobuf    # protoc compiler
    python3     # Required by Docker image build steps
    coreutils   # dirname, mkdir, cat, etc. (explicit for restricted PATH contexts)
    gnused      # sed (explicit for restricted PATH contexts)

    # Cloud / Tunnels (kubectl, kubelogin, awscli2, azure-cli are in home.base.nix)
    cloudflared      # Cloudflare Tunnel client (Access-protected API calls)
    google-cloud-sdk # GCP VM management (gcloud, gsutil, bq)

    # Serve-pool operator tooling
    opencode-pool-auth # provider-credential rotation across the whole pool
  ];

  # GCP project: read from sops in initExtra below (org-identifying, not in public source)

  # Export secrets from sops-nix (system-level decryption to /run/secrets/)
  programs.bash.initExtra = lib.mkAfter ''
    # NOTE: there is deliberately NO `alias bazel=bazelisk` here any more.
    # `bazel` is now a real binary on PATH -- the scope shim in home.packages
    # above (bead workstation-mqp3). A shell alias takes precedence over PATH
    # lookup, so keeping it would have silently bypassed the shim in every
    # interactive shell while the agent's non-interactive bash used the shim: the
    # exact split where a human "verifies" a fix that is not in the path being
    # measured.

    # GitHub API token for gh CLI
    if [ -r /run/secrets/github_api_token ]; then
      export GH_TOKEN="$(cat /run/secrets/github_api_token)"
    fi

    if [ -r /run/secrets/cloudflare_api_token ]; then
      export CLOUDFLARE_API_TOKEN="$(cat /run/secrets/cloudflare_api_token)"
    fi

    # DoltHub REST API token for creating DoltHub databases (v1alpha1 API).
    # Separate from the dolthub_jwk push/pull cred deployed by deployDoltCreds.
    if [ -r /run/secrets/dolthub_api_token ]; then
      export DOLTHUB_API_TOKEN="$(cat /run/secrets/dolthub_api_token)"
    fi

    # Personal Anthropic subscription token. Consumed by the
    # @ex-machina/opencode-anthropic-auth opencode plugin (in ad-hoc CLI
    # opencode runs from this shell; opencode-serve gets its own copy in
    # hosts/cloudbox/configuration.nix). Claude Code is not installed --
    # the env var name is what the plugin requires, not what consumes it.
    if [ -r /run/secrets/claude_personal_oauth_token ]; then
      export CLAUDE_CODE_OAUTH_TOKEN="$(cat /run/secrets/claude_personal_oauth_token)"
    fi

    # Gemini API key for OpenCode's @ai-sdk/google provider (direct API)
    if [ -r /run/secrets/gemini_api_key ]; then
      export GOOGLE_GENERATIVE_AI_API_KEY="$(cat /run/secrets/gemini_api_key)"
    fi

    # Atlassian API token for nvim Atlassian commands
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
    # Bundler env var name is BUNDLE_<HOST_UPPER_WITH_DOTS_AS_DOUBLE_UNDERSCORES>.
    # Compose dynamically so the vendor-encoded host doesn't appear in source.
    if [ -r /run/secrets/bundle_source_host ] && [ -r /run/secrets/bundle_source_token ]; then
      _bundle_host="$(cat /run/secrets/bundle_source_host)"
      _bundle_var="BUNDLE_$(printf '%s' "$_bundle_host" | tr '[:lower:]' '[:upper:]' | sed 's/\./__/g')"
      export "$_bundle_var=$(cat /run/secrets/bundle_source_token)"
      unset _bundle_host _bundle_var
    fi

    # Datadog CLI credentials (dd-cli): Personal Access Token (Bearer auth).
    export DD_SITE="us3.datadoghq.com"
    if [ -r /run/secrets/dd_pat ]; then
      export DD_PAT="$(cat /run/secrets/dd_pat)"
    fi

    # BuildBuddy CLI + bb-test-log helper. BUILDBUDDY_HOST is the org-branded
    # subdomain (no scheme); BUILDBUDDY_API_KEY is the org read API key.
    if [ -r /run/secrets/buildbuddy_host ]; then
      export BUILDBUDDY_HOST="$(cat /run/secrets/buildbuddy_host)"
    fi
    if [ -r /run/secrets/buildbuddy_api_key ]; then
      export BUILDBUDDY_API_KEY="$(cat /run/secrets/buildbuddy_api_key)"
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

  # Deploy the shared DoltHub credential used by `bd dolt push/pull` to back up
  # the git-free beads issue DB (remote configured in .beads/config.yaml). The
  # Ed25519 JWK keypair lives in sops; we materialize it as a real 0600 file at
  # ~/.dolt/creds/<keyid>.jwk and point ~/.dolt/config_global.json at it via the
  # "user.creds" key (merged, not clobbered). The keyid is stable/known up front
  # and identical on every host. Mirrors the verified devbox implementation.
  home.activation.deployDoltCreds = lib.hm.dag.entryAfter [ "writeBoundary" "linkGeneration" ] ''
    set -euo pipefail

    keyid="6fnahnt9ls5iud8ac4eulmqf535p13co1jcjrluch86ve"
    secret="/run/secrets/dolthub_jwk"

    if [ ! -r "$secret" ]; then
      echo "deployDoltCreds: skipping (sops secret not available)"
    else
      creds_dir="$HOME/.dolt/creds"
      mkdir -p "$creds_dir"

      tmp="$(mktemp "$creds_dir/$keyid.jwk.tmp.XXXXXX")"
      cat "$secret" > "$tmp"
      mv "$tmp" "$creds_dir/$keyid.jwk"
      chmod 600 "$creds_dir/$keyid.jwk"

      # Point dolt at this credential without dropping any other config keys.
      cfg="$HOME/.dolt/config_global.json"
      existing="{}"
      [ -f "$cfg" ] && existing="$(cat "$cfg")"
      ctmp="$(mktemp "$HOME/.dolt/config_global.json.tmp.XXXXXX")"
      printf '%s' "$existing" | ${pkgs.jq}/bin/jq --arg k "$keyid" '.["user.creds"] = $k' > "$ctmp"
      mv "$ctmp" "$cfg"

      echo "deployDoltCreds: dolt credential deployed"
    fi
  '';

  # Materialize lgtm reviewer PATs from sops to the runtime location the
  # nix-managed `lgtm-gh` wrapper (pkgs/lgtm-gh) reads. The wrapper does
  # `cat ~/.config/lgtm/tokens/<login>.pat`, so decrypt the per-login sops
  # secrets (system-decrypted to /run/secrets) into that dir as real files
  # owned by dev, chmod 600, with the parent dir chmod 700 — exactly the
  # layout the multi-reviewer design specifies. Mirrors deployDoltCreds; skips
  # gracefully (no failure) when a secret hasn't been rendered yet (e.g. a
  # home-manager switch before nixos-rebuild). See lgtm:
  # docs/plans/2026-04-30-multi-reviewer-identity-design.md.
  home.activation.deployLgtmTokens = lib.hm.dag.entryAfter [ "writeBoundary" "linkGeneration" ] ''
    set -euo pipefail

    tokens_dir="$HOME/.config/lgtm/tokens"
    mkdir -p "$tokens_dir"
    chmod 700 "$HOME/.config/lgtm" "$tokens_dir"

    deployed=0
    for login in johnnymo87 Krosantos jamesvec; do
      secret="/run/secrets/lgtm_token_$login"
      dest="$tokens_dir/$login.pat"
      if [ ! -r "$secret" ]; then
        echo "deployLgtmTokens: skipping $login (sops secret not available)"
        continue
      fi
      tmp="$(mktemp "$tokens_dir/.$login.pat.XXXXXX")"
      cat "$secret" > "$tmp"
      chmod 600 "$tmp"
      mv "$tmp" "$dest"
      deployed=$((deployed + 1))
    done
    echo "deployLgtmTokens: $deployed lgtm reviewer token(s) deployed"
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
  # ---- bazel.slice: the AGGREGATE cap (bead workstation-mqp3) ----------------
  #
  # The shim gives each bazel invocation its own scope with MemoryMax=10G. That
  # bounds ONE workspace; it does not bound how many workspaces build at once.
  # This slice is the parent of every one of those scopes and bounds the total.
  # Without it, N concurrent builds would be N x 10G and we would have moved the
  # host-OOM problem rather than solved it.
  #
  # SIZING. One active build <=10G (the scope cap) + resident idle server JVMs of
  # other workspaces (~2.4G measured across two on a single serve) + headroom for
  # a second build spinning up => 16G. A genuinely concurrent second full build
  # will hit this cap; the kernel then kills the fattest JVM inside the slice and
  # that build fails. That is the intended trade on a 62G box whose swap is
  # already saturated -- budgeting 2x10G here would just relocate the OOM to the
  # host, where OOMScoreAdjust=500 makes the serves the preferred victim.
  #
  # MemorySwapMax bounds swap churn: swap on this host is already fully consumed,
  # and an unbounded build would thrash it host-wide before ever reaching
  # memory.max. Deliberately NO MemoryHigh -- throttling reclaim against a
  # saturated swap device stalls builds for minutes, which is worse than a clean
  # kill and much harder to diagnose.
  #
  # The serve units are in /system.slice/system-opencode\x2dserve.slice/..., a
  # different cgroup subtree, so a memcg OOM in here cannot reach them.
  #
  # NOTE the new neighbours. This slice nests under user-1000.slice, so builds
  # that used to sit in system.slice now also count against that slice's
  # MemoryHigh/MemorySwapMax/TasksMax (hosts/cloudbox/configuration.nix), which
  # they share with tmux, nvim and every interactive shell. TasksMax in
  # particular is worth remembering: bazel's symlink-forest and sandbox phases
  # are thread-hungry, so a pathological build now shows up as task exhaustion
  # for the interactive session rather than as memory pressure on a serve.
  systemd.user.slices.${bazelSliceName} = {
    Unit = {
      Description = "Bazel builds, capped and held outside the opencode serve cgroup";
      Documentation = [ "https://github.com/johnnymo87/workstation/blob/main/pkgs/bazel-scope/default.nix" ];
    };
    Slice = {
      MemoryMax = "16G";
      MemorySwapMax = "2G";
    };
  };

  # Every OTHER agent-spawned subprocess, held outside the serve cgroup.
  #
  # bazel.slice above fixed one binary. This one fixes the class: the bash tool
  # spawns each command as a direct child of `opencode serve`, so ANY of them can
  # OOM-kill it (the unit is OOMPolicy=stop). vitest did exactly that twice on
  # 2026-08-09 -- and unlike bazel it could not be shimmed at all, because vitest
  # is not on PATH and npm prepends node_modules/.bin ahead of anything we could
  # put there. pkgs/oc-scoped-shell therefore wraps commands at spawn time
  # via opencode's `shell` config key. See beads workstation-yt0p and workstation-rdsq.4
  # and docs/plans/2026-08-10-agent-subprocess-scope.md.
  #
  # The aggregate cap is the point of the slice: the per-command MemoryMax=10G
  # bounds ONE command, and nothing else bounds N of them running concurrently
  # across four serves. 20G lets two heavy commands run without letting the whole
  # population reach the 62G host.
  systemd.user.slices.${agentSliceName} = {
    Unit = {
      Description = "opencode agent bash-tool commands, capped and held outside the serve cgroup";
      Documentation = [ "https://github.com/johnnymo87/workstation/blob/main/docs/plans/2026-08-10-agent-subprocess-scope.md" ];
    };
    Slice = {
      MemoryMax = "20G";
      MemorySwapMax = "4G";
    };
  };

  # Repoint the legacy hand-made ~/.local/bin/bazel symlink at the shim.
  #
  # It predates this repo's management of bazel (created by hand in 2026-04) and
  # points straight at bazelisk, which is precisely the unscoped path the shim
  # exists to close. PATH order already makes it unreachable in practice
  # (~/.nix-profile/bin precedes ~/.local/bin everywhere that matters), so this is
  # belt-and-braces for anything invoking the absolute path.
  #
  # Guarded: only ever replaces a SYMLINK, never a real file, and only one that
  # resolves to bazelisk or to a bazel-scope shim. Anything else is left alone and
  # reported, because silently eating a file someone put there by hand is worse
  # than an unrepointed symlink.
  home.activation.repointLegacyBazelSymlink =
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      legacy="$HOME/.local/bin/bazel"
      want="$HOME/.nix-profile/bin/bazel"

      if [ ! -L "$legacy" ] && [ -e "$legacy" ]; then
        echo "NOTE: $legacy is a real file, not a symlink; leaving it alone." >&2
      elif [ -L "$legacy" ]; then
        # Compare the UNRESOLVED link: once repointed it names the profile path,
        # which is the idempotent no-op case. Resolving first would instead follow
        # through to the store and re-run the match every activation.
        if [ "$(readlink "$legacy")" = "$want" ]; then
          : # already points at the shim
        else
          target=$(readlink -f "$legacy" 2>/dev/null || true)
          case "$target" in
            # Only the two things we are willing to replace: the real bazelisk,
            # or an older shim generation. Deliberately NOT a bare */bin/bazel
            # glob -- that would also match a hand-pinned real bazel (e.g. one
            # under ~/.cache/bazelisk/downloads/.../bin/bazel), contradicting the
            # promise not to touch anything the user put there on purpose.
            *"/bin/bazelisk"|/nix/store/*-bazel-scope/bin/bazel|/nix/store/*-bazel/bin/bazel)
              run ln -sfn "$want" "$legacy"
              ;;
            *)
              echo "NOTE: leaving $legacy alone; it resolves to ''${target:-a broken target}, which is neither bazelisk nor the shim." >&2
              ;;
          esac
        fi
      fi
    '';

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
      Nice = 15;                          # Low scheduling priority
      CPUQuota = "200%";                  # Hard cap at 2 cores (of 4)
      IOSchedulingClass = "idle";         # Yield IO to interactive work
      Environment = [
        "HOME=%h"
        "PATH=${pkgs.nix}/bin:${pkgs.git}/bin:/run/current-system/sw/bin:/run/wrappers/bin"
      ];
    };
  };

  # ---------------------------------------------------------------------------
  # ff-mono-root: keep the mono PRIMARY checkout current.
  #
  # The mono root rots: 84 commits behind origin/main on 2026-07-08, 175 on
  # 07-27, 272 on 08-03, and 27 again within a day of a manual refresh.
  # mono/.agents/skills lives in that tree, so a stale root serves stale agent
  # skills -- on 08-03 that produced a production finding 100x off. Nothing else
  # refreshes it (reset-workspace only prunes merged worktrees).
  #
  # Cloudbox only, and deliberately so: cloudbox is the work machine, devbox is
  # personal, and mono is work. No devbox counterpart is wanted. This file is
  # cloudbox-only by construction, so no isCloudbox guard is needed here -- the
  # same reason its neighbour pull-workstation has none.
  #
  # The script's contract (fast-forward or skip; never reset/stash/clean) is
  # documented at assets/scripts/ff-mono-root and pinned by
  # assets/scripts/test-ff-mono-root.sh, wired into `nix flake check`.
  # ---------------------------------------------------------------------------
  home.file.".local/bin/ff-mono-root" = {
    source = "${assetsPath}/scripts/ff-mono-root";
    executable = true;
  };

  systemd.user.services.ff-mono-root = {
    Unit = {
      Description = "Fast-forward the mono primary checkout (skips if anything is in the way)";
    };
    Service = {
      Type = "oneshot";
      ExecStart = "%h/.local/bin/ff-mono-root";
      StandardOutput = "journal";
      StandardError = "journal";
      Nice = 15;                          # Low scheduling priority
      IOSchedulingClass = "idle";         # Yield IO to interactive work
      # Type=oneshot defaults to TimeoutStartSec=infinity, and `git fetch` has
      # no timeout of its own. A network black hole would leave the unit
      # "activating" forever; the timer does not re-fire a unit that is still
      # activating, so every subsequent night would be skipped with no failure
      # recorded and no log line -- the one genuinely silent-forever path in
      # this design. Bounding it turns that into a visible failed unit.
      TimeoutStartSec = "10min";
      Environment = [
        "HOME=%h"
        "PATH=${pkgs.git}/bin:${pkgs.util-linux}/bin:${pkgs.coreutils}/bin:/run/current-system/sw/bin:/run/wrappers/bin"
      ];
    };
  };

  # Fires at 02:45, fifteen minutes BEFORE the 03:00 nightly-restart-background
  # timer (hosts/cloudbox/configuration.nix) tears down and respawns sessions.
  # The ordering is the whole point: OpenCode snapshots skill content at SESSION
  # START, so refreshing the tree mid-session does nothing for sessions already
  # running. Landing the fast-forward before the 03:00 turnover is what makes
  # every session created afterwards read fresh skills.
  #
  # Daily rather than every-N-hours for the same reason: a mid-day run would
  # mutate a shared working tree that live sessions are reading, and would only
  # benefit sessions spawned later that same day.
  #
  # Honest about the residual risk: 02:45 is BEFORE the 03:00 teardown, so
  # sessions may still be alive and reading the tree while the fast-forward
  # lands. Working-tree file replacement during a merge is not atomic across
  # files, so a session reading at that instant can see a torn mix of old and
  # new. Accepted deliberately: those sessions are idle at 02:45, the window is
  # seconds long, and the alternative (running after teardown but before
  # respawn) means synchronising a user timer against a system unit's internals
  # for a much smaller gain.
  #
  # Persistent is deliberately NOT set. A catch-up run would fire at an
  # arbitrary moment after boot -- likely mid-day, with live sessions actively
  # reading the tree -- which is exactly the mid-day mutation this schedule
  # exists to avoid. The host is always-on, so a missed night is rare and costs
  # one day of drift; a sustained run of misses shows up as the staleness
  # tripwire failing the unit.
  systemd.user.timers.ff-mono-root = {
    Unit = {
      Description = "Nightly fast-forward of the mono primary checkout";
    };
    Timer = {
      OnCalendar = "*-*-* 02:45:00";
      RandomizedDelaySec = "2min";
    };
    Install = {
      WantedBy = [ "timers.target" ];
    };
  };

  # ---------------------------------------------------------------------------
  # trunk-drift-detector: notice when a PRIMARY root is holding work nobody else
  # can see. Bead workstation-v03j.9.
  #
  # On 2026-08-11 four primary clones under ~/projects were sitting on commits
  # that existed nowhere but this disk -- workstation (that same day), meridian
  # (17d), opencode-cached (17d) and k8s-gitops (140 DAYS) -- and nobody knew
  # about any of them. The pigeon one was found only because a third session
  # needed to pull for a deploy. This is the layer that looks.
  #
  # It complements rather than duplicates its neighbours: ff-mono-root asks "is
  # mono BEHIND", em-drift-detector asks the same of eternal-machinery on devbox,
  # and this asks "is anything AHEAD or dirty" across every primary root here.
  # It never fetches and never writes to a repo (contract at the top of the
  # script), so it is safe to run against ~40 trees that peer sessions are using.
  #
  # Cloudbox-only for now: this is where the swarm runs and where the incidents
  # happened. A devbox rollout would double-report eternal-machinery against
  # em-drift-detector and needs that overlap resolved first.
  #
  # Delivery is TELEGRAM, deliberately. The bead asked for the daily morning
  # recommendation agent, which was deleted on 2026-08-10 (678ae2f); routing to
  # journald alone would inherit workstation-yb4b ("nothing watches failed user
  # units"), and a detector nobody reads is worth about as much as no detector.
  #
  # Pinned by assets/scripts/test-trunk-drift-detector.sh, wired into
  # `nix flake check`, and mutation-checked (12 mutants, all killed).
  # ---------------------------------------------------------------------------
  home.file.".local/bin/trunk-drift-detector" = {
    source = "${assetsPath}/scripts/trunk-drift-detector";
    executable = true;
  };

  systemd.user.services.trunk-drift-detector = {
    Unit = {
      Description = "Report primary git roots under ~/projects holding stranded commits or uncommitted work (read-only)";
    };
    Service = {
      Type = "oneshot";
      ExecStart = "%h/.local/bin/trunk-drift-detector";
      StandardOutput = "journal";
      StandardError = "journal";
      Nice = 19;
      IOSchedulingClass = "idle";
      # Bounded for the same reason ff-mono-root is: a oneshot stuck in
      # "activating" is never re-fired by its timer, and that failure records
      # nothing at all. Each git call is individually bounded too
      # (TDD_GIT_TIMEOUT), so this ceiling should be unreachable.
      TimeoutStartSec = "10min";
      Environment = [
        "HOME=%h"
        "TDD_ALERT_CMD=${driftAlert}"
        "PATH=${pkgs.git}/bin:${pkgs.util-linux}/bin:${pkgs.coreutils}/bin:${pkgs.gnugrep}/bin:/run/current-system/sw/bin:/run/wrappers/bin"
      ];
    };
  };

  # Every 30 minutes, like em-drift-detector. Frequency is cheap (no network,
  # ~40 local git calls) and it is what makes the alert arrive while the session
  # that stranded the commit is still around to fix it. Persistent so a reboot
  # does not skip a window -- unlike ff-mono-root, a catch-up run here mutates
  # nothing, so there is no mid-day hazard to avoid.
  systemd.user.timers.trunk-drift-detector = {
    Unit = {
      Description = "Timer for the primary-root trunk-drift detector";
    };
    Timer = {
      OnCalendar = "*:0/30";
      Persistent = true;
      RandomizedDelaySec = "3min";
    };
    Install = {
      WantedBy = [ "timers.target" ];
    };
  };

  # ---- pressure-sampler: the instrument for "does this box run well" --------
  #
  # DURABLE ON PURPOSE, unlike the S2 samplers. Those are transient units on
  # tmpfs (workstation-rdsq.3) and that was the right call for a six-day
  # throwaway measurement. This one answers a standing question -- is the box
  # right-sized, and is anything stalling -- so it has to survive a reboot or a
  # user-manager restart without anyone remembering to recreate it.
  #
  # 15s cadence: PSI totals are monotonic counters, so resolution only bounds how
  # short a stall can be localised, and a bazel scope's whole life can be under a
  # minute. Cost is ~10 cgroups x 4 small sysfs reads per tick.
  systemd.user.services.pressure-sampler = {
    Unit = {
      Description = "Sample memory + PSI stall pressure (serves, bazel scopes, host)";
      Documentation = [ "https://github.com/johnnymo87/workstation/blob/main/pkgs/pressure-sampler/default.nix" ];
    };
    Service = {
      Type = "oneshot";
      ExecStart = "${pressureSampler}/bin/pressure-sampler";
      # Never let the instrument become the incident: it must not be able to
      # starve or stall the thing it is measuring.
      Nice = 10;
      IOSchedulingClass = "idle";
      MemoryMax = "128M";
    };
  };

  systemd.user.timers.pressure-sampler = {
    Unit.Description = "Sample memory + PSI stall pressure every 15s";
    Timer = {
      OnBootSec = "1min";
      OnUnitActiveSec = "15s";
      AccuracySec = "1s";
      Unit = "pressure-sampler.service";
    };
    Install.WantedBy = [ "timers.target" ];
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

  # NOT HERE, DELIBERATELY: the phantom-busy sweeper. Devbox defines it as a
  # systemd USER unit (users/dev/home.devbox.nix:1312-1358), so diffing the two
  # host files makes cloudbox look like it is missing one. It is not — cloudbox
  # ships it as a SYSTEM service + timer with User=dev in
  # hosts/cloudbox/configuration.nix, because its serve units are system-scoped
  # and the sweeper must query them on the same bus. See step 1 of
  # docs/plans/2026-08-01-cloudbox-serve-reliability-roadmap.md (workstation-s5gl).
}
