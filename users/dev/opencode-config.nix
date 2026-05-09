# OpenCode configuration management
# Manages opencode.json via home-manager
# with merge-on-activate pattern (runtime keys preserved, managed keys enforced)
{ config, lib, pkgs, localPkgs, assetsPath, isDevbox, isCloudbox, isCrostini, ... }:

let
  isDarwin = pkgs.stdenv.isDarwin;
  useGeminiForAgents = isDarwin || isCloudbox;
  geminiModel = "google-vertex/gemini-3.1-pro-preview";

  # Patch agent files if needed to override the sonnet hardcoded model
  patchAgent = name: src:
    if useGeminiForAgents then
      pkgs.runCommand "''${name}-gemini.md" {} ''
        sed 's|model: anthropic/claude-sonnet-4-6|model: ${geminiModel}|' ${src} > $out
      ''
    else
      src;

  # ---------------------------------------------------------------------------
  # Atlassian MCP wrapper: reads site URL from credentials at runtime
  # so org-identifying URLs stay out of version control.
  # ---------------------------------------------------------------------------
  mkAtlassianMcp = { name, port, keychainService, sopsSecret }: pkgs.writeShellApplication {
    inherit name;
    runtimeInputs = [ pkgs.nodejs ];
    text =
      let
        siteRead = if isDarwin
          then ''SITE="$(/usr/bin/security find-generic-password -s ${keychainService} -w 2>/dev/null || true)"''
          else ''SITE="$(cat /run/secrets/${sopsSecret} 2>/dev/null || true)"'';
      in ''
        ${siteRead}
        if [ -z "''${SITE:-}" ]; then
          echo "${name}: could not read atlassian site" >&2
          exit 1
        fi
        exec npx -y mcp-remote@0.1.38 https://mcp.atlassian.com/v1/mcp ${toString port} --resource "https://''${SITE}/"
      '';
  };

  atlassian-mcp = mkAtlassianMcp {
    name = "atlassian-mcp";
    port = 3334;
    keychainService = "atlassian-site";
    sopsSecret = "atlassian_site";
  };

  atlassian-alt-mcp = mkAtlassianMcp {
    name = "atlassian-alt-mcp";
    port = 3335;
    keychainService = "atlassian-alt-site";
    sopsSecret = "atlassian_alt_site";
  };

  opencodeBase = builtins.fromJSON (builtins.readFile "${assetsPath}/opencode/opencode.base.json");

  # Platform overlay: default model + Atlassian MCP wiring (macOS + cloudbox).
  # Routes the default through Google Vertex AI (google-vertex-anthropic/
  # claude-opus-4-7@default). Auth comes from gcloud Application Default
  # Credentials (~/.config/gcloud/application_default_credentials.json on
  # cloudbox; macOS via `gcloud auth application-default login`). Devbox skips
  # this overlay and uses opencode.base.json's anthropic/claude-opus-4-7
  # default (auth via @ex-machina/opencode-anthropic-auth plugin +
  # CLAUDE_CODE_OAUTH_TOKEN from sops). anthropic/claude-opus-4-7 and
  # github-copilot/claude-opus-4.7 remain reachable at runtime via /model
  # for fallback. github-copilot was tried as default but rejected: Copilot
  # caps context at 200k and limits Opus thinking to medium, while Anthropic
  # recommends xhigh.
  opencodeOverlay = lib.optionalAttrs (isDarwin || isCloudbox) {
    model = "google-vertex-anthropic/claude-opus-4-7@default";

    mcp = (opencodeBase.mcp or {}) // {
      atlassian = {
        type = "local";
        command = [ "${atlassian-mcp}/bin/atlassian-mcp" ];
        enabled = false;
      };
      atlassian-alt = {
        type = "local";
        command = [ "${atlassian-alt-mcp}/bin/atlassian-alt-mcp" ];
        enabled = false;
      };
    };
  };

  opencodeManaged = lib.recursiveUpdate opencodeBase opencodeOverlay;

  opencodeManagedFile = pkgs.writeText "opencode.managed.json"
    (builtins.toJSON opencodeManaged);

in
{
  # Symlink managed files to XDG config directory
  xdg.configFile."opencode/opencode.managed.json".source = opencodeManagedFile;

  # TUI config (separate from opencode.json -- opencode reads tui settings from tui.json)
  xdg.configFile."opencode/tui.json".source = "${assetsPath}/opencode/tui.json";

  # User-level AGENTS.md -- global instructions for all OpenCode sessions
  # (e.g. bash environment quirks like "no sleep"). Repo-specific instructions
  # still live in each project's AGENTS.md.
  xdg.configFile."opencode/AGENTS.md".source = "${assetsPath}/opencode/AGENTS.md";

   # Custom agents via OpenCode-native markdown format
   # OpenCode loads agents from ~/.config/opencode/agents/ with tools as YAML map
   # (NOT Claude Code-style ~/.claude/agents/ with comma-separated tools string)
   xdg.configFile."opencode/agents/slack.md".source = patchAgent "slack" "${assetsPath}/opencode/agents/slack.md";
   xdg.configFile."opencode/agents/librarian.md".source = patchAgent "librarian" "${assetsPath}/opencode/agents/librarian.md";
   xdg.configFile."opencode/agents/oracle.md".source = patchAgent "oracle" "${assetsPath}/opencode/agents/oracle.md";
   xdg.configFile."opencode/agents/vision-qa.md".source = patchAgent "vision-qa" "${assetsPath}/opencode/agents/vision-qa.md";
   xdg.configFile."opencode/agents/implementer.md".source = patchAgent "implementer" "${assetsPath}/opencode/agents/implementer.md";
   xdg.configFile."opencode/agents/spec-reviewer.md".source = patchAgent "spec-reviewer" "${assetsPath}/opencode/agents/spec-reviewer.md";
   xdg.configFile."opencode/agents/code-reviewer.md".source = patchAgent "code-reviewer" "${assetsPath}/opencode/agents/code-reviewer.md";

    # Plugins (SRP: shell env injection, compaction context, subagent routing)
     xdg.configFile."opencode/plugins/shell-env.ts".source = "${assetsPath}/opencode/plugins/shell-env.ts";
    xdg.configFile."opencode/plugins/compaction-context.ts".source = "${assetsPath}/opencode/plugins/compaction-context.ts";
   # Subagent routing overrides model selection for plan execution subagents
   # (implementer, spec-reviewer, code-reviewer). Disabled on devbox to let
   # subagents inherit the primary model, giving flexibility to choose at runtime.
   xdg.configFile."opencode/plugins/subagent-routing.ts" = lib.mkIf (isDarwin || isCloudbox) {
     source = "${assetsPath}/opencode/plugins/subagent-routing.ts";
   };

    # self-compact deployed as a Nix-built self-contained JS bundle.
    # See docs/plans/2026-04-21-self-compact-bundle-design.md.
    # The bundle inlines @opencode-ai/plugin and zod, so no node_modules
    # is needed at runtime; opencode loads the .js directly. This eliminates
    # the per-machine "remember to run bun install" footgun that bit us
    # on devbox earlier on 2026-04-21.
    xdg.configFile."opencode/plugins/self-compact.js".source =
      "${localPkgs.self-compact-plugin}/self-compact.js";
    # Sourcemap deployed alongside the bundle for stack-trace readability.
    xdg.configFile."opencode/plugins/self-compact.js.map".source =
      "${localPkgs.self-compact-plugin}/self-compact.js.map";

    xdg.configFile."opencode/plugins/opencode-pigeon.ts".source =
      config.lib.file.mkOutOfStoreSymlink (
        if isDarwin
        then "${config.home.homeDirectory}/Code/pigeon/packages/opencode-plugin/src/index.ts"
        else "${config.home.homeDirectory}/projects/pigeon/packages/opencode-plugin/src/index.ts"
      );

    xdg.configFile."opencode/plugins/superpowers.js".source =
      config.lib.file.mkOutOfStoreSymlink (
        if isDarwin
        then "${config.home.homeDirectory}/Code/superpowers/.opencode/plugins/superpowers.js"
        else "${config.home.homeDirectory}/projects/superpowers/.opencode/plugins/superpowers.js"
      );

  # Merge managed config into runtime opencode.json on each switch
  # Preserves runtime keys; managed keys win on conflict.
  home.activation.mergeOpencode = lib.hm.dag.entryAfter [ "writeBoundary" "linkGeneration" ] ''
    set -euo pipefail

    runtime="$HOME/.config/opencode/opencode.json"
    managed="${opencodeManagedFile}"

    # Ensure directory exists (handles fresh install)
    mkdir -p "$(dirname "$runtime")"

    # Treat missing/empty runtime file as {}
    # If present but invalid JSON, backup and reset
    if [[ -s "$runtime" ]]; then
      if ! ${pkgs.jq}/bin/jq empty "$runtime" 2>/dev/null; then
        cp "$runtime" "$runtime.bak.$(date +%s)"
        echo '{}' > "$runtime"
      fi
      base="$runtime"
    else
      base="$(mktemp)"
      echo '{}' > "$base"
    fi

    tmp="$(mktemp "''${runtime}.tmp.XXXXXX")"

    # Merge strategy: runtime first, then managed => managed wins on conflicts,
    # but unmentioned runtime keys are preserved.
    # Recursive merge: runtime first, managed second => managed wins on conflicts,
    # runtime-only nested keys are preserved (fixes shallow-merge bug).
    ${pkgs.jq}/bin/jq -S -s '.[0] * .[1]' "$base" "$managed" > "$tmp"

    mv "$tmp" "$runtime"
    [[ "$base" == "$runtime" ]] || rm -f "$base"
  '';

  # Pinned npm-resolved plugin versions. Add new entries here when adding more
  # plugins to opencode.base.json's `plugin` array that need version pinning.
  # Format: { "<package-name>" = "<exact-version>"; }
  # WARNING: opencode caches resolved plugins under ~/.cache/opencode/packages/
  # keyed by the version spec at first-fetch time (e.g. <pkg>@latest/). The
  # cache never re-resolves on its own, so bumping the pin below WITHOUT
  # invalidating the cache silently keeps the old version live in opencode-serve.
  # The activation script below handles the invalidation; do not skip it.
  home.activation.installOpencodePlugins = let
    opencodePluginPins = {
      "@ex-machina/opencode-anthropic-auth" = "1.8.0";
      "opencode-beads" = "0.6.0";
    };
    pinJson = builtins.toJSON opencodePluginPins;
    # Hosts where opencode-serve runs as a systemd user/system service.
    # NixOS hosts (devbox, cloudbox) only; macOS uses launchd / no serve.
    hasOpencodeServe = isDevbox || isCloudbox;
  in lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    set -euo pipefail
    export PATH="${pkgs.nodejs}/bin:${pkgs.jq}/bin:$PATH"
    mkdir -p "$HOME/.config/opencode"
    cd "$HOME/.config/opencode"

    # Bootstrap package.json if missing (first install on a fresh machine)
    if [ ! -f package.json ]; then
      echo '{"name":"opencode-config","private":true}' > package.json
    fi

    pins='${pinJson}'
    cache_invalidated=0

    # For each pinned plugin: install via npm into ~/.config/opencode/node_modules/
    # AND check ~/.cache/opencode/packages/ for stale copies that opencode-serve
    # would actually load (it prefers cache over node_modules).
    while IFS=$'\t' read -r pkg pinned_ver; do
      [ -n "$pkg" ] || continue

      npm install "''${pkg}@''${pinned_ver}" --no-save >/dev/null 2>&1

      # Find any cached copies of this package and purge those whose installed
      # version doesn't match the pin. The cache key is the version spec at
      # first-fetch time (e.g. "@latest"), so we glob over <scope>/<name>@*.
      # The cached package.json lives at:
      #   <cache_dir>/<scope>/<name>@<spec>/node_modules/<scope>/<name>/package.json
      cache_root="$HOME/.cache/opencode/packages"
      [ -d "$cache_root" ] || continue

      # Resolve <scope>/<name> globs. Empty glob => no cached copies, skip.
      shopt -s nullglob
      for cache_dir in "$cache_root/$pkg"@*; do
        cached_pkg_json="$cache_dir/node_modules/$pkg/package.json"
        if [ ! -f "$cached_pkg_json" ]; then
          # Malformed cache entry; nuke to be safe
          echo "installOpencodePlugins: removing malformed cache entry $cache_dir"
          rm -rf "$cache_dir"
          cache_invalidated=1
          continue
        fi
        cached_ver="$(jq -r '.version' "$cached_pkg_json" 2>/dev/null || echo "")"
        if [ "$cached_ver" != "$pinned_ver" ]; then
          echo "installOpencodePlugins: $pkg cached at $cached_ver, pinned at $pinned_ver -> purging $cache_dir"
          rm -rf "$cache_dir"
          cache_invalidated=1
        fi
      done
      shopt -u nullglob
    done < <(echo "$pins" | jq -r 'to_entries | .[] | "\(.key)\t\(.value)"')

    # Restart opencode-serve so it re-resolves the plugin from the freshly
    # populated cache on next request. Only on hosts where the service exists,
    # and only when we actually invalidated something (to avoid disrupting
    # active sessions on every home-manager switch).
    ${lib.optionalString hasOpencodeServe ''
      if [ "$cache_invalidated" = "1" ]; then
        # opencode-serve must restart to pick up the freshly resolved plugin.
        # Use sudo since the service is system-level (devbox + cloudbox both
        # have wheelNeedsPassword=false).
        #
        # Two non-obvious requirements (both learned the hard way 2026-04-30):
        #   1. Use the absolute path to systemctl. sudo sanitizes PATH
        #      (secure_path), so bare `systemctl` is "command not found".
        #      /run/current-system/sw/bin/systemctl is the stable NixOS path.
        #   2. Capture the exit code into a variable instead of relying on
        #      `if sudo ...; then ...; else ...; fi`. The straightforward
        #      `if` form *appeared* to work in interactive bash but reported
        #      stale exit codes inside the home-manager activation context
        #      while we were debugging. The `cmd || rc=$?` pattern is robust
        #      to whatever set -e / errexit-mask interactions home-manager
        #      activation introduces.
        sudo_err="$(mktemp)"
        sudo_rc=0
        /run/wrappers/bin/sudo -n /run/current-system/sw/bin/systemctl restart opencode-serve.service 2>"$sudo_err" || sudo_rc=$?
        if [ "$sudo_rc" -eq 0 ]; then
          echo "installOpencodePlugins: restarted opencode-serve after cache invalidation"
        else
          # Don't fail the whole activation — opencode-serve will eventually
          # restart on its own (timer / nightly), and the user can restart
          # manually. But surface the failure clearly.
          {
            echo "installOpencodePlugins: WARNING — opencode-serve restart failed (sudo exit $sudo_rc):"
            sed 's/^/  /' "$sudo_err"
            echo "installOpencodePlugins: cache was invalidated but service still running stale plugin."
            echo "installOpencodePlugins: run manually: sudo systemctl restart opencode-serve"
          } >&2
        fi
        rm -f "$sudo_err"
      fi
    ''}
  '';

  # Inject Basecamp MCP secrets from macOS Keychain into opencode.json
  # Runs after mergeOpencode to ensure runtime file exists
  # Uses basic auth (username/password) instead of OAuth for simpler setup
  home.activation.injectBasecampMcpSecrets = lib.mkIf isDarwin
    (lib.hm.dag.entryAfter [ "mergeOpencode" ] ''
      set -euo pipefail

      runtime="$HOME/.config/opencode/opencode.json"

      # Fetch credentials from Keychain
      bc_username="$(/usr/bin/security find-generic-password -a basecamp-mcp -s basecamp-mcp-username -w 2>/dev/null || true)"
      bc_password="$(/usr/bin/security find-generic-password -a basecamp-mcp -s basecamp-mcp-password -w 2>/dev/null || true)"
      bc_account_id="$(/usr/bin/security find-generic-password -s basecamp-account-id -w 2>/dev/null || true)"

      # If any credential is missing, delete mcp.basecamp and exit cleanly
      if [[ -z "''${bc_username}" ]] || [[ -z "''${bc_password}" ]] || [[ -z "''${bc_account_id}" ]]; then
        if [[ -f "$runtime" ]]; then
          tmp="$(mktemp "''${runtime}.tmp.XXXXXX")"
          ${pkgs.jq}/bin/jq 'del(.mcp.basecamp)' "$runtime" > "$tmp"
          mv "$tmp" "$runtime"
        fi
        echo "Basecamp MCP credentials not found in Keychain; removed mcp.basecamp from config" >&2
        exit 0
      fi

      # Both credentials present: inject full Basecamp MCP config
      # Disabled by default; enable manually when needed
      if [[ -f "$runtime" ]]; then
        tmp="$(mktemp "''${runtime}.tmp.XXXXXX")"

        ${pkgs.jq}/bin/jq \
          --arg user "''${bc_username}" \
          --arg pass "''${bc_password}" \
          --arg home "$HOME" \
          --arg account_id "''${bc_account_id}" \
          '.mcp.basecamp = {
            "type": "local",
            "command": [
              ($home + "/Code/Basecamp-MCP-Server/.venv/bin/python"),
              ($home + "/Code/Basecamp-MCP-Server/basecamp_fastmcp.py")
            ],
            "enabled": false,
            "environment": {
              "BASECAMP_USERNAME": $user,
              "BASECAMP_PASSWORD": $pass,
              "BASECAMP_ACCOUNT_ID": $account_id,
              "USER_AGENT": ("Basecamp MCP Server (" + $user + ")")
            }
          }' "$runtime" > "$tmp"

        mv "$tmp" "$runtime"
      fi
    '');

  # Inject Slack MCP secrets from macOS Keychain into opencode.json
  # Uses xoxp User OAuth token (registered Slack app) instead of browser session tokens.
  # Runs after mergeOpencode to ensure runtime file exists.
  # If token missing/empty, explicitly deletes mcp.slack to prevent stale config.
  home.activation.injectSlackMcpSecrets = lib.mkIf isDarwin
    (lib.hm.dag.entryAfter [ "mergeOpencode" ] ''
      set -euo pipefail

      runtime="$HOME/.config/opencode/opencode.json"

      # Fetch xoxp token from Keychain
      xoxp_token="$(/usr/bin/security find-generic-password -s slack-mcp-xoxp-token -w 2>/dev/null || true)"

      # If token is missing or empty, delete mcp.slack and exit cleanly
      if [[ -z "''${xoxp_token}" ]]; then
        if [[ -f "$runtime" ]]; then
          tmp="$(mktemp "''${runtime}.tmp.XXXXXX")"
          ${pkgs.jq}/bin/jq 'del(.mcp.slack)' "$runtime" > "$tmp"
          mv "$tmp" "$runtime"
        fi
        echo "Slack MCP xoxp token not found in Keychain; removed mcp.slack from config" >&2
        exit 0
      fi

      # Token present: inject Slack MCP config with xoxp auth
      # MCP is disabled by default; enable manually or use dedicated slack agent when needed
      if [[ -f "$runtime" ]]; then
        tmp="$(mktemp "''${runtime}.tmp.XXXXXX")"

        ${pkgs.jq}/bin/jq \
          --arg xoxp "''${xoxp_token}" \
          '.mcp.slack = {
            "type": "local",
            "command": ["npx", "-y", "slack-mcp-server@latest", "--transport", "stdio"],
            "enabled": false,
            "environment": {
              "SLACK_MCP_XOXP_TOKEN": $xoxp,
              "SLACK_MCP_ADD_MESSAGE_TOOL": "true"
            }
          }' "$runtime" > "$tmp"

        mv "$tmp" "$runtime"
      fi
    '');

  # Inject Slack MCP secrets from sops on cloudbox into opencode.json
  # Uses xoxp User OAuth token (registered Slack app) instead of browser session tokens.
  # Same pattern as Darwin, but reads from /run/secrets/ instead of Keychain.
  home.activation.injectSlackMcpSecretsSops = lib.mkIf isCloudbox
    (lib.hm.dag.entryAfter [ "mergeOpencode" ] ''
      set -euo pipefail

      runtime="$HOME/.config/opencode/opencode.json"

      # Read xoxp token from sops-decrypted secret
      xoxp_token=""
      if [ -r /run/secrets/slack_mcp_xoxp_token ]; then
        xoxp_token="$(cat /run/secrets/slack_mcp_xoxp_token)"
      fi

      # If token is missing or empty, delete mcp.slack and exit cleanly
      if [[ -z "''${xoxp_token}" ]]; then
        if [[ -f "$runtime" ]]; then
          tmp="$(mktemp "''${runtime}.tmp.XXXXXX")"
          ${pkgs.jq}/bin/jq 'del(.mcp.slack)' "$runtime" > "$tmp"
          mv "$tmp" "$runtime"
        fi
        echo "Slack MCP xoxp token not found in sops; removed mcp.slack from config" >&2
        exit 0
      fi

      # Token present: inject Slack MCP config with xoxp auth
      if [[ -f "$runtime" ]]; then
        tmp="$(mktemp "''${runtime}.tmp.XXXXXX")"

        ${pkgs.jq}/bin/jq \
          --arg xoxp "''${xoxp_token}" \
          '.mcp.slack = {
            "type": "local",
            "command": ["npx", "-y", "slack-mcp-server@latest", "--transport", "stdio"],
            "enabled": false,
            "environment": {
              "SLACK_MCP_XOXP_TOKEN": $xoxp,
              "SLACK_MCP_ADD_MESSAGE_TOOL": "true"
            }
          }' "$runtime" > "$tmp"

        mv "$tmp" "$runtime"
      fi
    '');

  # Inject Datadog MCP config (remote HTTP transport) into opencode.json
  # Uses Datadog's hosted MCP server with DD_API_KEY/DD_APPLICATION_KEY headers.
  # Endpoint host is mcp.<DD_SITE>; site is us3 for our org.
  # Disabled by default — enable manually or via dedicated agent when needed.
  #
  # NOTE: We previously used the local datadog_mcp_cli stdio proxy, but Datadog
  # broke its hardcoded api.us3.datadoghq.com/api/unstable/mcp-server/mcp path
  # (returns 404) and hasn't shipped a fixed binary. Remote HTTP is now the
  # recommended path per docs.datadoghq.com/bits_ai/mcp_server/setup/.
  home.activation.injectDatadogMcpSecrets = lib.mkIf isDarwin
    (lib.hm.dag.entryAfter [ "mergeOpencode" ] ''
      set -euo pipefail

      runtime="$HOME/.config/opencode/opencode.json"

      dd_api_key="$(/usr/bin/security find-generic-password -s dd-api-key -w 2>/dev/null || true)"
      dd_app_key="$(/usr/bin/security find-generic-password -s dd-app-key -w 2>/dev/null || true)"

      if [[ -z "''${dd_api_key}" ]] || [[ -z "''${dd_app_key}" ]]; then
        if [[ -f "$runtime" ]]; then
          tmp="$(mktemp "''${runtime}.tmp.XXXXXX")"
          ${pkgs.jq}/bin/jq 'del(.mcp.datadog)' "$runtime" > "$tmp"
          mv "$tmp" "$runtime"
        fi
        echo "Datadog API keys not found in Keychain; removed mcp.datadog from config" >&2
        exit 0
      fi

      if [[ -f "$runtime" ]]; then
        tmp="$(mktemp "''${runtime}.tmp.XXXXXX")"

        ${pkgs.jq}/bin/jq \
          --arg url "https://mcp.us3.datadoghq.com/api/unstable/mcp-server/mcp" \
          --arg api_key "''${dd_api_key}" \
          --arg app_key "''${dd_app_key}" \
          '.mcp.datadog = {
            "type": "remote",
            "url": $url,
            "enabled": false,
            "oauth": false,
            "headers": {
              "DD_API_KEY": $api_key,
              "DD_APPLICATION_KEY": $app_key
            }
          }' "$runtime" > "$tmp"

        mv "$tmp" "$runtime"
      fi
    '');

  home.activation.injectDatadogMcpSecretsSops = lib.mkIf isCloudbox
    (lib.hm.dag.entryAfter [ "mergeOpencode" ] ''
      set -euo pipefail

      runtime="$HOME/.config/opencode/opencode.json"

      dd_api_key=""
      dd_app_key=""
      if [ -r /run/secrets/dd_api_key ]; then
        dd_api_key="$(cat /run/secrets/dd_api_key)"
      fi
      if [ -r /run/secrets/dd_app_key ]; then
        dd_app_key="$(cat /run/secrets/dd_app_key)"
      fi

      if [[ -z "''${dd_api_key}" ]] || [[ -z "''${dd_app_key}" ]]; then
        if [[ -f "$runtime" ]]; then
          tmp="$(mktemp "''${runtime}.tmp.XXXXXX")"
          ${pkgs.jq}/bin/jq 'del(.mcp.datadog)' "$runtime" > "$tmp"
          mv "$tmp" "$runtime"
        fi
        echo "Datadog API keys not found in sops; removed mcp.datadog from config" >&2
        exit 0
      fi

      if [[ -f "$runtime" ]]; then
        tmp="$(mktemp "''${runtime}.tmp.XXXXXX")"

        ${pkgs.jq}/bin/jq \
          --arg url "https://mcp.us3.datadoghq.com/api/unstable/mcp-server/mcp" \
          --arg api_key "''${dd_api_key}" \
          --arg app_key "''${dd_app_key}" \
          '.mcp.datadog = {
            "type": "remote",
            "url": $url,
            "enabled": false,
            "oauth": false,
            "headers": {
              "DD_API_KEY": $api_key,
              "DD_APPLICATION_KEY": $app_key
            }
          }' "$runtime" > "$tmp"

        mv "$tmp" "$runtime"
      fi
    '');
}
