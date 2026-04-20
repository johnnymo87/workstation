# Cross-platform home-manager configuration
# Platform-specific code lives in home.linux.nix and home.darwin.nix
{ config, pkgs, lib, localPkgs, devenvPkg, assetsPath, isDarwin, isCloudbox, isCrostini, ... }:

let

  opencode-launch = pkgs.writeShellApplication {
    name = "opencode-launch";
    runtimeInputs = [ pkgs.curl pkgs.jq ];
    text = ''
      OPENCODE_URL="''${OPENCODE_URL:-http://127.0.0.1:4096}"

      usage() {
        echo "Usage: opencode-launch [directory] <prompt>"
        echo ""
        echo "Launch a headless opencode session."
        echo ""
        echo "  opencode-launch ~/projects/pigeon \"fix the test\""
        echo "  opencode-launch \"fix the test\"  # uses current directory"
        exit 1
      }

      if [ $# -eq 0 ]; then
        usage
      elif [ $# -eq 1 ]; then
        directory="$PWD"
        prompt="$1"
      else
        directory="$1"
        shift
        prompt="$*"
      fi

      # Resolve ~ to $HOME
      directory="''${directory/#\~/$HOME}"

      # Health check
      if ! curl -sf "$OPENCODE_URL/global/health" >/dev/null 2>&1; then
        echo "Error: opencode serve is not reachable at $OPENCODE_URL" >&2
        echo "Check: systemctl status opencode-serve (Linux) or launchctl list | grep opencode (macOS)" >&2
        exit 1
      fi

      # GPG agent forwarding check (Linux only)
      GPG_SOCKET="/run/user/1000/gnupg/S.gpg-agent"
      if [ -d "/run/user/1000" ] && [ ! -S "$GPG_SOCKET" ]; then
        echo "Warning: GPG agent socket not found at $GPG_SOCKET" >&2
        echo "Signed commits will fail in this session." >&2
        echo "Ensure the persistent GPG tunnel is active from macOS." >&2
        echo "" >&2
      fi

      # Create session
      session_response=$(curl -sf -X POST "$OPENCODE_URL/session" \
        -H "x-opencode-directory: $directory") || {
        echo "Error: failed to create session" >&2
        exit 1
      }

      session_id=$(echo "$session_response" | jq -r '.id')
      if [ -z "$session_id" ] || [ "$session_id" = "null" ]; then
        echo "Error: no session ID in response: $session_response" >&2
        exit 1
      fi

      # Send prompt
      curl -sf -X POST "$OPENCODE_URL/session/$session_id/prompt_async" \
        -H "x-opencode-directory: $directory" \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg p "$prompt" '{parts: [{type: "text", text: $p}]}')" >/dev/null || {
        echo "Error: failed to send prompt to session $session_id" >&2
        exit 1
      }

      echo "Session launched: $session_id"
      echo "Directory: $directory"
      echo ""
      echo "Attach:  opencode attach $OPENCODE_URL --session $session_id"
      echo "Kill:    curl -sf -X DELETE $OPENCODE_URL/session/$session_id"
    '';
  };

  # Patched opencode with prompt caching (PR #5422) + vim (PR #12679) + tool fix (PR #16751) + MCP reconnect (#15247) + Opus 4.7
  # https://github.com/johnnymo87/opencode-patched
  # All 4 platforms built by the patched fork's CI
  #
  # Darwin gotcha: the darwin-*.zip assets must be ad-hoc codesigned by the
  # upstream CI or macOS kernels will SIGKILL the binary with "Killed: 9".
  # See opencode-patched/.opencode/skills/darwin-signing.md for the full
  # story (Bun 1.3.12 #29120 regression + the BUN_NO_CODESIGN_MACHO_BINARY
  # workaround in build-release.yml). If a hash bump here lands a binary
  # that dies on launch, the upstream workflow has regressed.
  opencode-platforms = {
    aarch64-linux = {
      asset = "opencode-linux-arm64.tar.gz";
      hash = "sha256-7+xtQx0dM1kXofk39beRevUD6YcjSsaOEqAih2NoKaM=";
      isZip = false;
    };
    aarch64-darwin = {
      asset = "opencode-darwin-arm64.zip";
      hash = "sha256-dV1M7sD0+AptxH6yGljpUS9AW6vAG8PHlBcmKl1+Xvs=";
      isZip = true;
    };
    x86_64-linux = {
      asset = "opencode-linux-x64.tar.gz";
      hash = "sha256-BhdHk+LORZTWvH8umu6+VdxZeJrPMf6K+xkT2mSww98=";
      isZip = false;
    };
    x86_64-darwin = {
      asset = "opencode-darwin-x64.zip";
      hash = "sha256-pJSNyq8eApPIJKAJuzuwr8yTM9YbQvbfDkKGUVnH/l0=";
      isZip = true;
    };
  };

  opencode = let
    version = "1.14.18";
    platformInfo = opencode-platforms.${pkgs.stdenv.hostPlatform.system};
  in pkgs.stdenv.mkDerivation {
    pname = "opencode-patched";
    inherit version;
    src = pkgs.fetchurl {
      url = "https://github.com/johnnymo87/opencode-patched/releases/download/v${version}-patched/${platformInfo.asset}";
      hash = platformInfo.hash;
    };
    nativeBuildInputs = [ pkgs.makeWrapper ]
      ++ lib.optionals platformInfo.isZip [ pkgs.unzip ]
      ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux [
        pkgs.autoPatchelfHook
      ];
    buildInputs = lib.optionals pkgs.stdenv.hostPlatform.isLinux [
      pkgs.stdenv.cc.cc.lib
    ];
    dontConfigure = true;
    dontBuild = true;
    dontStrip = true;
    unpackPhase = ''
      runHook preUnpack
    '' + lib.optionalString platformInfo.isZip ''
      unzip $src
    '' + lib.optionalString (!platformInfo.isZip) ''
      tar -xzf $src
    '' + ''
      runHook postUnpack
    '';
    installPhase = ''
      runHook preInstall
      mkdir -p $out/bin
      install -m755 bin/opencode $out/bin/opencode
      wrapProgram $out/bin/opencode \
        --prefix PATH : ${lib.makeBinPath [ pkgs.fzf pkgs.ripgrep ]}
      runHook postInstall
    '';
    meta = {
      description = "OpenCode with prompt caching + vim + tool fix + MCP reconnect";
      homepage = "https://github.com/johnnymo87/opencode-patched";
      mainProgram = "opencode";
    };
  };

  # Azure CLI with msal 1.34.0 patch and azure-devops extension (work machines)
  # NOTE: azure-cli 2.79.0 ships msal 1.33.0 which has a bug where
  # `az login --use-device-code` crashes with "Session.request() got
  # an unexpected keyword argument 'claims_challenge'". Fixed in msal 1.34.0.
  # Remove this block when nixpkgs bumps azure-cli to >= 2.83.0.
  azureCliPatched = let
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
    azWithExts = pkgs.azure-cli.withExtensions (with pkgs.azure-cli.extensions; [
      azure-devops
    ]);
  in azWithExts.overrideAttrs (old: {
    postFixup = (old.postFixup or "") + ''
      for f in $out/bin/az $out/bin/.az-wrapped $out/bin/.az-wrapped_; do
        if [ -f "$f" ]; then
          substituteInPlace "$f" \
            --replace-quiet "${msal133Path}" "${msal134Path}"
        fi
      done
    '';
  });
in
{
  # NOTE: home.username and home.homeDirectory are set per-host
  # (in flake.nix for Darwin, in home.linux.nix for NixOS devbox)

  # User packages
  home.packages = [
    # Self-packaged tools (in pkgs/, some auto-updated by CI)
    localPkgs.beads
    pkgs.pandoc
    opencode

    # Cloudflare Workers CLI
    pkgs.wrangler

    # Remote clipboard (gclpr client talks to macOS server over SSH tunnel)
    localPkgs.gclpr

    # Headless opencode session launcher
    opencode-launch

    # GitHub CLI
    pkgs.gh

    # Google Workspace CLI
    localPkgs.gws

    # Mobile shell (survives sleep/wake, network changes)
    pkgs.mosh

    # Other tools
    devenvPkg

    # JavaScript runtime (used by pigeon and other projects)
    pkgs.bun
  ]
  # Work tools (macOS + cloudbox only)
  ++ lib.optionals (isDarwin || isCloudbox) [
    localPkgs.acli
    localPkgs.datadog-mcp-cli
    # Bazel mono repo needs zip at build time and java for ktlint execution.
    # rules_kotlin <2.3.0 falls back to system PATH for java:
    # https://github.com/bazelbuild/rules_kotlin/pull/1452
    pkgs.zip
    pkgs.jdk21
    # Cloud / Kubernetes
    azureCliPatched
    pkgs.awscli2       # AWS CLI (EKS kubeconfig credential plugin, ba exec SSO)
    pkgs.kubelogin     # Azure AD credential plugin for kubectl
    pkgs.kubectl       # Kubernetes CLI (for AKS clusters)
  ];

  # Bazel user config (~/.bazelrc) — work machines only
  home.file.".bazelrc" = lib.mkIf (isDarwin || isCloudbox) {
    text = lib.concatStringsSep "\n" ([
      "# Managed by home-manager — edits will be overwritten"
      ""
      "# Show test errors inline"
      "test --test_output errors"
      ""
      "# Local disk and repository caches"
      "common --disk_cache ~/bazel-diskcache --repository_cache ~/bazel-cache/repository"
      ""
      "# GCS remote cache — shared across worktrees and machines"
      "# Local disk_cache is checked first (fast); remote is fallback + shared warming"
      "common --remote_cache=https://storage.googleapis.com/wonder-sandbox-bazel-cache"
      "common --remote_upload_local_results"
      ""
      "# Reap idle Bazel servers after 15 min (default 3h) to free RAM across worktrees"
      "startup --max_idle_secs=900"
      ""
      "# Cap Kotlin persistent workers to 1 per worktree (default can spawn 2-3)"
      "build --worker_max_instances=KotlinCompile=1"
      "test  --worker_max_instances=KotlinCompile=1"
      ""
      "# Evict idle workers if they collectively exceed 2.5 GB"
      "build --experimental_total_worker_memory_limit_mb=2500"
      "build --experimental_shrink_worker_pool"
      "test  --experimental_total_worker_memory_limit_mb=2500"
      "test  --experimental_shrink_worker_pool"
    ] ++ lib.optionals pkgs.stdenv.isLinux [
      ""
      "# NixOS: explicit PATH for sandbox — forwarding alone doesn't cover all action types"
      "build --action_env=PATH=/home/dev/.nix-profile/bin:/etc/profiles/per-user/dev/bin:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin"
      "build --host_action_env=PATH=/home/dev/.nix-profile/bin:/etc/profiles/per-user/dev/bin:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin"
      ""
      "# Auto-shutdown server when system is low on memory"
      "startup --shutdown_on_low_sys_mem"
    ]);
  };

  # Azure DevOps npm registry auth (~/.npmrc) — work machines only
  # Uses npm's native ${ENV_VAR} interpolation; ADO_NPM_PAT_B64 is exported
  # in platform-specific bash init (home.cloudbox.nix / home.darwin.nix).
  # We generate the file at activation time to avoid hardcoding the ADO registry URL
  # (which contains the employer org/project name) in the Nix config.
  home.activation.generateNpmrc = lib.mkIf (isDarwin || isCloudbox) (lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    NPMRC_PATH="$HOME/.npmrc"
    rm -f "$NPMRC_PATH"
    REGISTRY_URL=""

    ${if isCloudbox then ''
      SECRET_PATH="/run/secrets/ado_npm_registry_url"
      if [ -f "$SECRET_PATH" ]; then
        REGISTRY_URL=$(cat "$SECRET_PATH")
      else
        echo "Warning: ADO npm registry secret not found at $SECRET_PATH"
      fi
    '' else ''
      if /usr/bin/security find-generic-password -s ado-npm-registry-url -w >/dev/null 2>&1; then
        REGISTRY_URL=$(/usr/bin/security find-generic-password -s ado-npm-registry-url -w)
      else
        echo "Warning: ADO npm registry URL not found in macOS Keychain (ado-npm-registry-url)"
      fi
    ''}

    if [ -n "$REGISTRY_URL" ]; then
      ORG_NAME=$(echo "$REGISTRY_URL" | cut -d/ -f4)
      cat > "$NPMRC_PATH" <<EOF
; begin auth token
$REGISTRY_URL/registry/:username=$ORG_NAME
$REGISTRY_URL/registry/:_password=\''${ADO_NPM_PAT_B64}
$REGISTRY_URL/registry/:email=npm requires email to be set but doesn't use the value
$REGISTRY_URL/:username=$ORG_NAME
$REGISTRY_URL/:_password=\''${ADO_NPM_PAT_B64}
$REGISTRY_URL/:email=npm requires email to be set but doesn't use the value
; end auth token
EOF
    else
      cat > "$NPMRC_PATH" <<EOF
; ADO npm registry URL secret not found during activation
; Add it to sops (Cloudbox) or Keychain (Darwin) and run rebuild
EOF
    fi
  '');

home.activation.deployGclprKey = lib.mkIf (!isDarwin && !isCrostini) (
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      if [ -f /run/secrets/gclpr_private_key ]; then
        mkdir -p "$HOME/.gclpr"
        chmod 700 "$HOME/.gclpr"
        (
          umask 077
          ${pkgs.coreutils}/bin/base64 -d /run/secrets/gclpr_private_key > "$HOME/.gclpr/key.tmp"
        )
        mv -f "$HOME/.gclpr/key.tmp" "$HOME/.gclpr/key"
        chmod 400 "$HOME/.gclpr/key"
      else
        echo "deployGclprKey: skipping (secret not available)"
      fi
    ''
  );

  # Install/update ba CLI from private GitHub release (work machines)
  # Downloads platform-appropriate binary, caches by version in ~/.local/bin
  # macOS: reads ba_cli_repo from Keychain, GH token from gh CLI auth
  # Cloudbox: reads both from sops-nix secrets at /run/secrets/
  home.activation.installBaCli = lib.mkIf (isDarwin || isCloudbox) (
    lib.hm.dag.entryAfter [ "writeBoundary" ] (let
      platform = if isDarwin then "darwin" else "linux";
      asset = "ba-${platform}-arm64.tar.gz";
    in ''
      ba_repo=""
      ${if isCloudbox then ''
        if [ -r /run/secrets/ba_cli_repo ]; then
          ba_repo="$(cat /run/secrets/ba_cli_repo)"
        fi
      '' else ''
        ba_repo="$(/usr/bin/security find-generic-password -s ba-cli-repo -w 2>/dev/null || true)"
      ''}

      if [ -z "$ba_repo" ]; then
        echo "installBaCli: skipping (ba_cli_repo not available)"
      else
        gh_token=""
        ${if isCloudbox then ''
          if [ -r /run/secrets/github_api_token ]; then
            gh_token="$(cat /run/secrets/github_api_token)"
          fi
        '' else ''
          gh_token="$(${pkgs.gh}/bin/gh auth token 2>/dev/null || true)"
        ''}

        if [ -z "$gh_token" ]; then
          echo "installBaCli: skipping (GitHub token not available)"
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
                   -p '${asset}' \
                   -D "$tmpdir" 2>/dev/null; then
                ${pkgs.gnutar}/bin/tar --use-compress-program=${pkgs.gzip}/bin/gzip -xf "$tmpdir/${asset}" -C "$tmpdir"
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
    ''));

  # Cap JetBrains kotlin-lsp JVM heap — each OpenCode session spawns its
  # own instance; without a cap they grow to ~1.5 GB each.
  # IJ_JAVA_OPTIONS is read by JetBrains tools only (not generic JVMs).
  home.sessionVariables = lib.mkIf (isDarwin || isCloudbox) {
    IJ_JAVA_OPTIONS = "-Xms128m -Xmx1024m -XX:MaxMetaspaceSize=256m -XX:+UseSerialGC";
  };

  # Git
  programs.git = {
    enable = true;
    signing.key = "0C0EF2DF7ADD5DD9";
    ignores = [];
    settings = {
      user.name = "Jonathan Mohrbacher";
      user.email = "jonathan.mohrbacher@gmail.com";
      init.defaultBranch = "main";
      push.autoSetupRemote = true;
      pull.rebase = true;
      commit.gpgsign = true;
      gpg.format = "openpgp";
      diff.algorithm = "patience";  # Better diffs for code with repeated patterns
      rerere.enabled = true;        # Remember conflict resolutions for rebase
      # Use the gh CLI as the git credential helper for GitHub HTTPS remotes.
      # Lets headless services (e.g. cloudbox lgtm-run) clone/fetch via HTTPS
      # without SSH keys; interactive workflows over SSH (git@github.com:) are
      # unaffected. Reads GH_TOKEN if set, falls back to gh's auth.json.
      credential."https://github.com".helper = "!${pkgs.gh}/bin/gh auth git-credential";
      alias = {
        st = "status";
        co = "checkout";
        br = "branch";
        ci = "commit";
        lg = "log --oneline --graph --decorate";
      };
    };
  };

  # GPG - shared settings (both platforms)
  programs.gpg = {
    enable = true;
    package = pkgs.gnupg;  # Use nixpkgs GPG for consistency
    publicKeys = lib.mkIf (!isCrostini) [
      {
        source = "${assetsPath}/gpg-signing-key.asc";
        trust = 5;  # ultimate (our own key)
      }
    ];
    settings = {
      auto-key-retrieve = true;
      no-emit-version = true;
      # NOTE: no-autostart is NOT here - it's Linux-only (see home.linux.nix)
    };
  };

  # Dirmngr config (keyserver) - manual file since dirmngrSettings not in our HM version
  home.file.".gnupg/dirmngr.conf".text = ''
    keyserver hkps://keys.openpgp.org
  '';

  # gclpr clipboard bridge public key
  home.file.".gclpr/key.pub" = lib.mkIf (!isDarwin && !isCrostini) {
    source = "${assetsPath}/gclpr/key.pub";
  };

  # OpenCode session history search CLI
  home.file.".local/bin/oc-search" = {
    executable = true;
    text = ''
      #!${pkgs.bash}/bin/bash
      set -euo pipefail

      show_help() {
        cat <<'HELP_EOF'
      Usage: oc-search [OPTIONS] QUERY

      Search OpenCode session history for QUERY.

      Options:
        --types TYPES    Comma-separated list of part types to search (default: tool)
        --all            Search all part types (ignores --types)
        -h, --help       Show this help message
      HELP_EOF
      }

      types="tool"
      search_all=false
      query=""

      while [[ $# -gt 0 ]]; do
        case "$1" in
          -h|--help)
            show_help
            exit 0
            ;;
          --types)
            if [[ $# -gt 1 && ! "$2" == -* ]]; then
              types="$2"
              shift 2
            else
              echo "Error: --types requires an argument." >&2
              show_help >&2
              exit 1
            fi
            ;;
          --types=*)
            types="''${1#*=}"
            shift
            ;;
          --all)
            search_all=true
            shift
            ;;
          --)
            shift
            for arg in "$@"; do
              if [[ -n "$query" ]]; then
                echo "Error: Multiple queries provided." >&2
                show_help >&2
                exit 1
              fi
              query="$arg"
            done
            break
            ;;
          -*)
            echo "Unknown option: $1" >&2
            show_help >&2
            exit 1
            ;;
          *)
            if [[ -n "$query" ]]; then
              echo "Error: Multiple queries provided ('$query' and '$1')" >&2
              show_help >&2
              exit 1
            fi
            query="$1"
            shift
            ;;
        esac
      done

      if [[ -z "$query" ]]; then
        echo "Error: Search query is required." >&2
        show_help >&2
        exit 1
      fi

      DB_PATH="$HOME/.local/share/opencode/opencode.db"

      if [[ ! -f "$DB_PATH" ]]; then
        echo "Error: Database not found at $DB_PATH" >&2
        exit 1
      fi

      type_filter=""
      if [[ "$search_all" == false ]]; then
        IFS=',' read -ra type_array <<< "$types"
        in_list=""
        for t in "''${type_array[@]}"; do
          t_clean="''${t//\'/}"
          if [[ -z "$in_list" ]]; then
            in_list="'$t_clean'"
          else
            in_list="$in_list, '$t_clean'"
          fi
        done
        type_filter="AND json_extract(p.data, '$.type') IN ($in_list)"
      fi

      query_escaped="''${query//\'/\'\'}"

      # Execute SQLite query (pragmas use .output /dev/null to suppress echo)
      ${pkgs.sqlite}/bin/sqlite3 "file:$DB_PATH?mode=ro" <<SQL_EOF
      .output /dev/null
      PRAGMA query_only=ON;
      PRAGMA busy_timeout=2000;
      PRAGMA temp_store=MEMORY;
      PRAGMA cache_size=-65536;
      .output stdout
      .headers on
      .mode column
      WITH matched AS (
        SELECT
          p.session_id,
          COUNT(*) AS match_count,
          MAX(p.time_created) AS last_match_ms
        FROM part p
        WHERE instr(p.data, '$query_escaped') > 0
          $type_filter
        GROUP BY p.session_id
      )
      SELECT
        s.id,
        substr(s.title, 1, 40) AS title,
        substr(s.directory, 1, 45) AS directory,
        datetime(m.last_match_ms / 1000, 'unixepoch', 'localtime') AS last_match,
        m.match_count AS matches
      FROM matched m
      JOIN session s ON s.id = m.session_id
      ORDER BY m.last_match_ms DESC;
      SQL_EOF
    '';
  };

  # lgtm-sessions: list active OpenCode sessions dispatched by lgtm.
  # See lgtm-3j8 in ~/projects/lgtm beads tracker for design notes.
  home.file.".local/bin/lgtm-sessions" = {
    executable = true;
    text = ''
      #!${pkgs.bash}/bin/bash
      set -euo pipefail

      OPENCODE_URL="''${OPENCODE_URL:-http://127.0.0.1:4096}"
      PROJECTS_DIR="''${LGTM_PROJECTS_DIR:-$HOME/projects}"

      CURL="${pkgs.curl}/bin/curl"
      JQ="${pkgs.jq}/bin/jq"
      GIT="${pkgs.git}/bin/git"

      # Health check
      if ! "$CURL" -sf -m 5 "$OPENCODE_URL/global/health" >/dev/null 2>&1; then
        echo "OpenCode server not reachable at $OPENCODE_URL" >&2
        exit 1
      fi

      # Find lgtm worktrees on disk: ~/projects/<repo>/.worktrees/pr-<N>
      shopt -s nullglob
      worktrees=( "$PROJECTS_DIR"/*/.worktrees/pr-[0-9]* )
      shopt -u nullglob

      if [ ''${#worktrees[@]} -eq 0 ]; then
        echo "No active lgtm worktrees"
        exit 0
      fi

      # Unique project roots (parent dir of .worktrees)
      declare -A seen_root
      project_roots=()
      for wt in "''${worktrees[@]}"; do
        root="''${wt%/.worktrees/*}"
        if [ -z "''${seen_root[$root]:-}" ]; then
          seen_root[$root]=1
          project_roots+=( "$root" )
        fi
      done

      # Resolve org/repo per project root via git remote (cached)
      declare -A repo_id
      for root in "''${project_roots[@]}"; do
        url="$( "$GIT" -C "$root" remote get-url origin 2>/dev/null || true )"
        # Parse https://github.com/<org>/<repo>(.git) or git@github.com:<org>/<repo>(.git)
        case "$url" in
          https://github.com/*)
            id="''${url#https://github.com/}"
            ;;
          git@github.com:*)
            id="''${url#git@github.com:}"
            ;;
          *)
            id="$(basename "$root")"
            ;;
        esac
        id="''${id%.git}"
        repo_id[$root]="$id"
      done

      # Query API per project root and collect sessions whose directory is a
      # pr-<N> worktree under that root. Build TSV: updated_ms\tcreated_ms\trepo_id\tpr_num\tsession_id
      now_ms=$(( $(date +%s) * 1000 ))
      tsv=""
      for root in "''${project_roots[@]}"; do
        body="$( "$CURL" -sf -m 10 -H "x-opencode-directory: $root" "$OPENCODE_URL/session" || echo "[]" )"
        prefix="$root/.worktrees/pr-"
        rows="$(
          printf '%s' "$body" | "$JQ" -r --arg prefix "$prefix" --arg id "''${repo_id[$root]}" '
            .[]
            | select(.directory | startswith($prefix))
            | (.directory | sub("^.*/pr-"; "")) as $tail
            | select($tail | test("^[0-9]+$"))
            | [ .time.updated, .time.created, $id, $tail, .id ]
            | @tsv
          '
        )"
        if [ -n "$rows" ]; then
          tsv="$tsv$rows"$'\n'
        fi
      done

      # Strip trailing blank line
      tsv="''${tsv%$'\n'}"

      if [ -z "$tsv" ]; then
        echo "No active lgtm sessions"
        exit 0
      fi

      # Format relative time from epoch ms
      fmt_ago() {
        local ms="$1"
        local secs=$(( (now_ms - ms) / 1000 ))
        if [ "$secs" -lt 0 ]; then secs=0; fi
        if [ "$secs" -lt 60 ]; then
          echo "''${secs}s ago"
        elif [ "$secs" -lt 3600 ]; then
          echo "$(( secs / 60 ))m ago"
        elif [ "$secs" -lt 86400 ]; then
          echo "$(( secs / 3600 ))h ago"
        else
          echo "$(( secs / 86400 ))d ago"
        fi
      }

      # Sort by updated desc and render table
      printf '%-50s  %-12s  %-12s  %s\n' "PR" "CREATED" "UPDATED" "SESSION"
      count=0
      while IFS=$'\t' read -r updated created repo_full pr_num sid; do
        [ -z "$updated" ] && continue
        printf '%-50s  %-12s  %-12s  %s\n' \
          "''${repo_full}#''${pr_num}" \
          "$(fmt_ago "$created")" \
          "$(fmt_ago "$updated")" \
          "$sid"
        count=$(( count + 1 ))
      done < <(printf '%s\n' "$tsv" | sort -t$'\t' -k1,1nr)

      echo
      echo "$count session(s). Attach: opencode attach $OPENCODE_URL --session <ID>"
    '';
  };

  # opencode-send: post a prompt into another local OpenCode session.
  #
  # Talks directly to opencode serve at http://127.0.0.1:4096 (POST
  # /session/<id>/prompt_async). Bypasses the pigeon daemon entirely — this is
  # purely local opencode-to-opencode messaging.
  #
  # See assets/opencode/skills/sending-to-opencode-session/SKILL.md for usage.
  home.file.".local/bin/opencode-send" = {
    executable = true;
    text = ''
      #!${pkgs.bash}/bin/bash
      set -euo pipefail

      OPENCODE_URL="''${OPENCODE_URL:-http://127.0.0.1:4096}"

      CURL="${pkgs.curl}/bin/curl"
      JQ="${pkgs.jq}/bin/jq"

      show_help() {
        cat <<'HELP_EOF'
      Usage:
        opencode-send [OPTIONS] <session-id> <message>
        opencode-send [OPTIONS] <session-id> -        # read message from stdin
        opencode-send --list [OPTIONS]                # list local sessions

      Post a text prompt into another OpenCode session running on the local
      machine. Talks directly to opencode serve via POST /session/<id>/prompt_async.

      Options:
        --list             List local sessions (id, updated, directory, title)
        --cwd DIR          Set x-opencode-directory header (default: $PWD)
        --url URL          opencode serve base URL
                           (default: $OPENCODE_URL or http://127.0.0.1:4096)
        -h, --help         Show this help

      Environment:
        OPENCODE_URL       Override the default opencode serve URL

      Examples:
        opencode-send --list
        opencode-send ses_abc123 "please run the tests"
        echo "long message body" | opencode-send ses_abc123 -
        cat plan.md | opencode-send --cwd ~/projects/foo ses_abc123 -
      HELP_EOF
      }

      mode="send"
      cwd=""
      session_id=""
      message=""

      while [[ $# -gt 0 ]]; do
        case "$1" in
          -h|--help)
            show_help
            exit 0
            ;;
          --list)
            mode="list"
            shift
            ;;
          --cwd)
            if [[ $# -lt 2 ]]; then
              echo "Error: --cwd requires an argument." >&2
              exit 1
            fi
            cwd="$2"
            shift 2
            ;;
          --cwd=*)
            cwd="''${1#*=}"
            shift
            ;;
          --url)
            if [[ $# -lt 2 ]]; then
              echo "Error: --url requires an argument." >&2
              exit 1
            fi
            OPENCODE_URL="$2"
            shift 2
            ;;
          --url=*)
            OPENCODE_URL="''${1#*=}"
            shift
            ;;
          --)
            shift
            break
            ;;
          -*)
            # Allow bare "-" as the message arg (stdin sentinel)
            if [[ "$1" == "-" ]]; then
              break
            fi
            echo "Unknown option: $1" >&2
            show_help >&2
            exit 1
            ;;
          *)
            break
            ;;
        esac
      done

      # Health check (cheap and gives a clearer error than a failed POST)
      if ! "$CURL" -sf -m 5 "$OPENCODE_URL/global/health" >/dev/null 2>&1; then
        echo "Error: opencode serve not reachable at $OPENCODE_URL" >&2
        exit 1
      fi

      if [[ "$mode" == "list" ]]; then
        if [[ $# -gt 0 ]]; then
          echo "Error: --list takes no positional arguments." >&2
          exit 1
        fi

        json="$( "$CURL" -sf -m 10 "$OPENCODE_URL/session" )" || {
          echo "Error: GET $OPENCODE_URL/session failed" >&2
          exit 1
        }

        # Render: id, updated (relative), directory, title
        # Sort by time.updated descending.
        now_ms="$(date +%s%3N)"
        printf '%-32s  %-10s  %-40s  %s\n' "ID" "UPDATED" "DIRECTORY" "TITLE"
        printf '%s' "$json" | "$JQ" -r --argjson now "$now_ms" '
          sort_by(-.time.updated) | .[] |
          [.id, (.time.updated // 0 | tostring), (.directory // ""), (.title // "")] |
          @tsv
        ' | while IFS=$'\t' read -r id updated dir title; do
          [ -z "$id" ] && continue
          secs=$(( (now_ms - updated) / 1000 ))
          if [ "$secs" -lt 0 ]; then secs=0; fi
          if   [ "$secs" -lt 60 ];    then ago="''${secs}s"
          elif [ "$secs" -lt 3600 ];  then ago="$(( secs / 60 ))m"
          elif [ "$secs" -lt 86400 ]; then ago="$(( secs / 3600 ))h"
          else                              ago="$(( secs / 86400 ))d"
          fi
          # Truncate long fields for table neatness
          dir_short="''${dir:0:40}"
          title_short="''${title:0:60}"
          printf '%-32s  %-10s  %-40s  %s\n' "$id" "$ago" "$dir_short" "$title_short"
        done
        exit 0
      fi

      # Send mode: need <session-id> <message>
      if [[ $# -lt 1 ]]; then
        echo "Error: session-id is required." >&2
        show_help >&2
        exit 1
      fi
      session_id="$1"
      shift

      if [[ $# -lt 1 ]]; then
        echo "Error: message is required (or pass '-' to read from stdin)." >&2
        show_help >&2
        exit 1
      fi

      if [[ "$1" == "-" ]]; then
        message="$(cat)"
      else
        message="$1"
      fi
      shift || true

      if [[ $# -gt 0 ]]; then
        echo "Error: unexpected extra arguments: $*" >&2
        echo "Hint: quote multi-word messages." >&2
        exit 1
      fi

      if [[ -z "$message" ]]; then
        echo "Error: message is empty." >&2
        exit 1
      fi

      # Default cwd to current directory if not specified
      if [[ -z "$cwd" ]]; then
        cwd="$PWD"
      fi

      # Pre-flight: verify the session exists.
      #
      # opencode serve's POST /session/<id>/prompt_async returns 204 No Content
      # for ANY id, including nonexistent ones — there's no signal in the POST
      # response that the target was real. So we GET /session/<id> first:
      # 200 = exists, 404 = not found, anything else = treat as error.
      check_status="$( "$CURL" -sS -o /dev/null -m 5 -w '%{http_code}' \
        "$OPENCODE_URL/session/$session_id" )" || {
        echo "Error: pre-flight GET to opencode serve failed" >&2
        exit 1
      }

      if [[ "$check_status" == "404" ]]; then
        echo "Error: session not found: $session_id" >&2
        echo "Hint: run 'opencode-send --list' to see available sessions." >&2
        exit 1
      fi

      if [[ "$check_status" -lt 200 || "$check_status" -ge 300 ]]; then
        echo "Error: pre-flight GET returned HTTP $check_status for session $session_id" >&2
        exit 1
      fi

      # Build JSON body via jq to handle escaping safely
      body="$( "$JQ" -nc --arg text "$message" \
        '{parts: [{type: "text", text: $text}]}' )"

      http_status="$( "$CURL" -sS -o /tmp/opencode-send-resp.$$ -w '%{http_code}' \
        -X POST \
        -H "Content-Type: application/json" \
        -H "x-opencode-directory: $cwd" \
        --data "$body" \
        "$OPENCODE_URL/session/$session_id/prompt_async" )" || {
        echo "Error: POST to opencode serve failed" >&2
        rm -f /tmp/opencode-send-resp.$$
        exit 1
      }

      if [[ "$http_status" -lt 200 || "$http_status" -ge 300 ]]; then
        echo "Error: opencode serve returned HTTP $http_status" >&2
        cat /tmp/opencode-send-resp.$$ >&2 || true
        echo >&2
        rm -f /tmp/opencode-send-resp.$$
        exit 1
      fi

      rm -f /tmp/opencode-send-resp.$$
      echo "Sent to $session_id (cwd=$cwd, ''${#message} chars)"
    '';
  };

  # common.conf is platform-specific - see home.linux.nix and home.darwin.nix

  # Tmux
  programs.tmux = {
    enable = true;
    secureSocket = false;  # Use /tmp for socket so mosh and non-login contexts find it
    shell = "${pkgs.bash}/bin/bash";  # Explicit: macOS defaults to zsh, but our config is all bash
    clock24 = true;
    terminal = "tmux-256color";
    historyLimit = 50000;  # Generous scrollback for long build logs
    extraConfig = ''
      # Prefix key: Ctrl-a (easier to reach than Ctrl-b)
      unbind C-b
      set -g prefix C-a
      bind C-a send-prefix    # Press C-a twice to send C-a to nested tmux/app

      # Usability
      set -g mouse on
      set -g renumber-windows on
      set -g allow-rename off     # Don't let programs rename windows via escape sequences
      set -g automatic-rename off # Don't auto-rename based on running command; manual names stick

      # Vi keybindings
      set -g status-keys vi      # Vi keys in command prompt (prefix + :)
      set -g mode-keys vi        # Vi keys in copy mode

      # Modern terminal integration
      set -g focus-events on     # Pass focus events to apps (neovim FocusGained/Lost)
      set -s escape-time 10      # Responsive Esc (tmux 3.5+ default is 10ms)

      # Truecolor support
      set -ag terminal-overrides ",xterm-256color:RGB"

      # Load extra config if it exists (safe during partial migration)
      if-shell -b '[ -f ~/.config/tmux/extra.conf ]' 'source-file ~/.config/tmux/extra.conf'
    '';
  };

  # Tmux extra config (OSC 52 clipboard, etc.)
  xdg.configFile."tmux/extra.conf".source = "${assetsPath}/tmux/extra.conf";

  # Neovim
  programs.neovim = {
    enable = true;
    defaultEditor = true;
    viAlias = true;
    vimAlias = true;

    plugins = with pkgs.vimPlugins; [
      tabby-nvim
      goyo-vim
      mini-align
      plenary-nvim
      telescope-fzy-native-nvim
      telescope-nvim
      (nvim-treesitter.withPlugins (p: with p; [
        bash c comment css csv diff dockerfile
        editorconfig git_config gitcommit gitignore go
        html http javascript json json5 lua luadoc
        make markdown markdown_inline nix python
        regex ruby sql ssh_config tmux toml
        typescript vimdoc xml yaml
      ]))
      (pkgs.vimUtils.buildVimPlugin {
        pname = "vim-ripgrep";
        version = "unstable-2026-01-13";
        src = pkgs.fetchFromGitHub {
          owner = "jremmen";
          repo = "vim-ripgrep";
          rev = "2bb2425387b449a0cd65a54ceb85e123d7a320b8";
          hash = "sha256-OvQPTEiXOHI0uz0+6AVTxyJ/TUMg6kd3BYTAbnCI7W8=";
        };
      })
    ];

    extraPackages = [ pkgs.ripgrep ];

    extraLuaConfig = ''
      require("user.settings")
      require("user.mappings")
      require("user.tabby")             -- OpenCode session tab labels
      require("user.cursor_highlight")  -- Ctrl+K cursor crosshair toggle
      require("user.telescope")         -- treesitter + telescope + keymaps
      require("mini.align").setup()     -- text alignment (ga/gA)
    '' + lib.optionalString (isDarwin || isCloudbox) ''
      require("user.atlassian")         -- :FetchJiraTicket, :FetchConfluencePage
    '';
  };

  # Neovim Lua config files (kept separate from HM-managed init.vim)
  # User config modules from workstation assets
  xdg.configFile."nvim/lua/user" = {
    source = "${assetsPath}/nvim/lua/user";
    recursive = true;
  };

  # Home Manager (standalone command on PATH for all platforms)
  programs.home-manager.enable = true;

  # Direnv
  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };

  # Bash
  programs.bash = {
    enable = true;
    shellAliases = {
      ll = "ls -la";
      ".." = "cd ..";
      "..." = "cd ../..";
      # Git shortcuts (from deprecated-dotfiles)
      gs = "git status";
      gco = "git checkout";
      gd = "git diff";
      gl = "git log";
      gp = "git push";
    };
    initExtra = ''
      # Vertex AI: Gemini 3.x models require the "global" endpoint.
      # Without this, OpenCode defaults to "us-east5" which 404s on newer models.
      export GOOGLE_CLOUD_LOCATION="global"

      # GPG TTY - tmux-aware (from deprecated-dotfiles)
      if [ -n "$TMUX" ]; then
          export GPG_TTY=$(tmux display-message -p '#{pane_tty}')
      else
          export GPG_TTY=$(tty)
      fi
      export HISTSIZE=10000
      export HISTFILESIZE=20000
      export HISTCONTROL=ignoredups:erasedups
      shopt -s histappend

      # Checkout default branch (from deprecated-dotfiles)
      gcom() {
        git fetch origin && git checkout "origin/$(git remote show origin | grep 'HEAD branch:' | awk '{ print $3 }')"
      }
      '';
  };

  # SSH
  programs.ssh = {
    enable = true;
    enableDefaultConfig = false;  # Silence deprecation warning; defaults mirror SSH's own
    matchBlocks."github.com" = {
      hostname = "github.com";
      user = "git";
      identityFile = "~/.ssh/id_ed25519_github";
      identitiesOnly = true;
    };
  };

  # Nix binary caches (devenv projects use their own flake inputs, cachix avoids rebuilds)
  # mkDefault: in module mode (nix-darwin/NixOS), home-manager's nixos/common.nix
  # forwards the system nix.package into each user, causing a duplicate definition
  # error. mkDefault lets the system's value win. In standalone mode (devbox),
  # this provides the required package for nix.settings below. (HM #5870)
  nix.package = lib.mkDefault pkgs.nix;
  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    extra-substituters = [
      "https://devenv.cachix.org"
    ];
    extra-trusted-public-keys = [
      "devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw="
    ];
  };

  # FZF
  programs.fzf = {
    enable = true;
    enableBashIntegration = true;
  };

  # Session path
  home.sessionPath = [
    "$HOME/.local/bin"
    "$HOME/.npm-global/bin"
  ];

  # Install dd-cli (Datadog CLI) in editable mode from local checkout (work machines)
  # Editable install means source changes are reflected immediately without reinstalling.
  # Only re-run `home-manager switch` if dependencies in pyproject.toml change.
  home.activation.installDdCli = lib.mkIf (isDarwin || isCloudbox) (
    lib.hm.dag.entryAfter [ "writeBoundary" ] (let
      ddCliDir = if isCloudbox
        then "$HOME/projects/dd-cli"
        else "$HOME/Code/dd-cli";
    in ''
      set -euo pipefail
      dd_cli_dir="${ddCliDir}"
      if [ -d "$dd_cli_dir" ]; then
        ${pkgs.uv}/bin/uv tool install --editable "$dd_cli_dir" --force --quiet 2>&1 || {
          echo "installDdCli: WARNING: uv tool install failed"
        }
        echo "installDdCli: dd-cli installed (editable) from $dd_cli_dir"
      else
        echo "installDdCli: skipping ($dd_cli_dir not found)"
      fi
    ''));

  # npm-global packages that can't be managed by Nix
  # (e.g. nixpkgs version is too old, or package not in nixpkgs)
  # Installed to ~/.npm-global which is already on sessionPath
  home.activation.installNpmGlobalPackages = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    set -euo pipefail
    export PATH="${pkgs.nodejs}/bin:$PATH"
    export npm_config_prefix="$HOME/.npm-global"

    # chrome-devtools-mcp: primary browser MCP server for AI agent visual QA
    # (replaces @playwright/mcp — better token efficiency, DevTools-native
    # capabilities like Lighthouse audits, perf traces, memory snapshots)
    wanted_cdmcp="0.20.3"
    current_cdmcp="$(npm ls -g --prefix "$HOME/.npm-global" chrome-devtools-mcp --json 2>/dev/null \
      | ${pkgs.jq}/bin/jq -r '.dependencies["chrome-devtools-mcp"].version // empty' 2>/dev/null || true)"
    if [[ "$current_cdmcp" != "$wanted_cdmcp" ]]; then
      echo "Installing chrome-devtools-mcp@$wanted_cdmcp (have: ''${current_cdmcp:-none})"
      npm install -g "chrome-devtools-mcp@$wanted_cdmcp" --prefix "$HOME/.npm-global" --no-fund --no-audit 2>&1 || true
    fi
  '';

}
