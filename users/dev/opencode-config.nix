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

  # Platform overlay: Claude via Vertex AI (macOS + cloudbox)
  # Model metadata comes from models.dev (auto-fetched by OpenCode); this overlay
  # sets the default model to route through Google Vertex AI.
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

   # Plugins (SRP: non-interactive env, compaction context, subagent routing)
    xdg.configFile."opencode/plugins/non-interactive-env.ts".source = "${assetsPath}/opencode/plugins/non-interactive-env.ts";
    xdg.configFile."opencode/plugins/compaction-context.ts".source = "${assetsPath}/opencode/plugins/compaction-context.ts";
   # Subagent routing overrides model selection for plan execution subagents
   # (implementer, spec-reviewer, code-reviewer). Disabled on devbox to let
   # subagents inherit the primary model, giving flexibility to choose at runtime.
   xdg.configFile."opencode/plugins/subagent-routing.ts" = lib.mkIf (isDarwin || isCloudbox) {
     source = "${assetsPath}/opencode/plugins/subagent-routing.ts";
   };

   # OpenCode plugins deployed via out-of-store symlink (path resolved at activation, not eval)
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

  home.activation.installOpencodePlugins = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    set -euo pipefail
    export PATH="${pkgs.nodejs}/bin:$PATH"
    mkdir -p "$HOME/.config/opencode"
    cd "$HOME/.config/opencode"
    
    # Check if package.json exists, if not initialize it
    if [ ! -f package.json ]; then
      echo '{"name":"opencode-config","private":true}' > package.json
    fi
    
    npm install @ex-machina/opencode-anthropic-auth@1.6.1 --no-save >/dev/null 2>&1
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

  # Inject Datadog MCP config with API key auth into opencode.json
  # Uses datadog_mcp_cli proxy binary with --site us3 and DD_API_KEY/DD_APP_KEY
  # Disabled by default — enable manually or via dedicated agent when needed
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
          --arg cmd "${localPkgs.datadog-mcp-cli}/bin/datadog_mcp_cli" \
          --arg api_key "''${dd_api_key}" \
          --arg app_key "''${dd_app_key}" \
          '.mcp.datadog = {
            "type": "local",
            "command": [$cmd, "--site", "us3"],
            "enabled": false,
            "environment": {
              "DD_API_KEY": $api_key,
              "DD_APP_KEY": $app_key
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
          --arg cmd "${localPkgs.datadog-mcp-cli}/bin/datadog_mcp_cli" \
          --arg api_key "''${dd_api_key}" \
          --arg app_key "''${dd_app_key}" \
          '.mcp.datadog = {
            "type": "local",
            "command": [$cmd, "--site", "us3"],
            "enabled": false,
            "environment": {
              "DD_API_KEY": $api_key,
              "DD_APP_KEY": $app_key
            }
          }' "$runtime" > "$tmp"

        mv "$tmp" "$runtime"
      fi
    '');
}
