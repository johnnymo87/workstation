# OpenCode configuration management
# Manages opencode.json via home-manager
# with merge-on-activate pattern (runtime keys preserved, managed keys enforced)
{ config, lib, pkgs, assetsPath, ... }:

let
  isDarwin = pkgs.stdenv.isDarwin;

  # ---------------------------------------------------------------------------
  # opencode.json managed config
  # ---------------------------------------------------------------------------
  opencodeBase = builtins.fromJSON (builtins.readFile "${assetsPath}/opencode/opencode.base.json");

  # Platform-specific overlay (macOS only: Gemini Code Assist via wonder-sandbox)
  opencodeOverlay = lib.optionalAttrs isDarwin {
    model = "google/gemini-3-pro-preview";

    plugin = opencodeBase.plugin ++ [
      "opencode-gemini-auth@1.3.10"
    ];

    mcp = (opencodeBase.mcp or {}) // {
      atlassian = {
        type = "local";
        command = [
          "${pkgs.nodejs}/bin/npx"
          "-y"
          "mcp-remote"
          "https://mcp.atlassian.com/v1/sse"
        ];
        enabled = false;
      };
    };

    provider = (opencodeBase.provider or {}) // {
      google = {
        options = {
          projectId = "wonder-sandbox";
        };
        models = {
          "gemini-3-pro-preview" = {
            name = "Gemini 3 Pro (Code Assist)";
            limit = { context = 1048576; output = 65536; };
            modalities = { input = ["text" "image"]; output = ["text"]; };
            options.thinkingConfig = { thinkingLevel = "high"; includeThoughts = true; };
          };
          "gemini-3-flash-preview" = {
            name = "Gemini 3 Flash (Code Assist)";
            limit = { context = 1048576; output = 65536; };
            modalities = { input = ["text" "image"]; output = ["text"]; };
            options.thinkingConfig = { thinkingLevel = "low"; includeThoughts = true; };
          };
          "gemini-2.5-pro" = {
            name = "Gemini 2.5 Pro (Code Assist)";
            limit = { context = 1048576; output = 65536; };
            modalities = { input = ["text" "image"]; output = ["text"]; };
            options.thinkingConfig = { thinkingBudget = 8192; includeThoughts = true; };
          };
          "gemini-2.5-flash" = {
            name = "Gemini 2.5 Flash (Code Assist)";
            limit = { context = 1048576; output = 65536; };
            modalities = { input = ["text" "image"]; output = ["text"]; };
            options.thinkingConfig = { thinkingBudget = 4096; includeThoughts = true; };
          };
        };
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

   # Custom agents via OpenCode-native markdown format
   # OpenCode loads agents from ~/.config/opencode/agents/ with tools as YAML map
   # (NOT Claude Code-style ~/.claude/agents/ with comma-separated tools string)
   xdg.configFile."opencode/agents/slack.md".source = "${assetsPath}/opencode/agents/slack.md";
   xdg.configFile."opencode/agents/prometheus.md".source = "${assetsPath}/opencode/agents/prometheus.md";
   xdg.configFile."opencode/agents/atlas.md".source = "${assetsPath}/opencode/agents/atlas.md";
   xdg.configFile."opencode/agents/librarian.md".source = "${assetsPath}/opencode/agents/librarian.md";
   xdg.configFile."opencode/agents/metis.md".source = "${assetsPath}/opencode/agents/metis.md";
   xdg.configFile."opencode/agents/momus.md".source = "${assetsPath}/opencode/agents/momus.md";
   xdg.configFile."opencode/agents/sisyphus.md".source = "${assetsPath}/opencode/agents/sisyphus.md";
   xdg.configFile."opencode/agents/oracle.md".source = "${assetsPath}/opencode/agents/oracle.md";
   xdg.configFile."opencode/agents/hephaestus.md".source = "${assetsPath}/opencode/agents/hephaestus.md";
   xdg.configFile."opencode/agents/multimodal-looker.md".source = "${assetsPath}/opencode/agents/multimodal-looker.md";

   # Plugins (SRP: non-interactive env, compaction context)
   xdg.configFile."opencode/plugins/non-interactive-env.ts".source = "${assetsPath}/opencode/plugins/non-interactive-env.ts";
   xdg.configFile."opencode/plugins/compaction-context.ts".source = "${assetsPath}/opencode/plugins/compaction-context.ts";

   # OpenCode plugins deployed via out-of-store symlink (path resolved at activation, not eval)
    xdg.configFile."opencode/plugins/opencode-pigeon.ts".source =
      config.lib.file.mkOutOfStoreSymlink (
        if isDarwin
        then "${config.home.homeDirectory}/Code/pigeon/packages/opencode-plugin/src/index.ts"
        else "${config.home.homeDirectory}/projects/pigeon/packages/opencode-plugin/src/index.ts"
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
    # Use reduce over managed keys so arrays fully replace (not merge by index).
    ${pkgs.jq}/bin/jq -S -s '
      .[1] as $managed |
      .[0] | reduce ($managed | keys[]) as $k (.; .[$k] = $managed[$k])
    ' "$base" "$managed" > "$tmp"

    mv "$tmp" "$runtime"
    [[ "$base" == "$runtime" ]] || rm -f "$base"
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

      # If either credential is missing, delete mcp.basecamp and exit cleanly
      if [[ -z "''${bc_username}" ]] || [[ -z "''${bc_password}" ]]; then
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
              "BASECAMP_ACCOUNT_ID": "3671212",
              "USER_AGENT": "Basecamp MCP Server (espresso@wonder.com)"
            }
          }' "$runtime" > "$tmp"

        mv "$tmp" "$runtime"
      fi
    '');

  # Inject Slack MCP secrets from macOS Keychain into opencode.json
  # Runs after mergeOpencode to ensure runtime file exists
  # If tokens missing/empty, explicitly deletes mcp.slack to prevent stale config
  # Uses OpenCode's mcp config format: type=local, command=array, environment=object
  home.activation.injectSlackMcpSecrets = lib.mkIf isDarwin
    (lib.hm.dag.entryAfter [ "mergeOpencode" ] ''
      set -euo pipefail

      runtime="$HOME/.config/opencode/opencode.json"

      # Fetch tokens from Keychain
      xoxc_token="$(/usr/bin/security find-generic-password -s slack-mcp-xoxc-token -w 2>/dev/null || true)"
      xoxd_token="$(/usr/bin/security find-generic-password -s slack-mcp-xoxd-token -w 2>/dev/null || true)"

      # If either token is missing or empty, delete mcp.slack and exit cleanly
      if [[ -z "''${xoxc_token}" ]] || [[ -z "''${xoxd_token}" ]]; then
        if [[ -f "$runtime" ]]; then
          tmp="$(mktemp "''${runtime}.tmp.XXXXXX")"
          ${pkgs.jq}/bin/jq 'del(.mcp.slack)' "$runtime" > "$tmp"
          mv "$tmp" "$runtime"
        fi
        echo "Slack MCP tokens not found in Keychain; removed mcp.slack from config" >&2
        exit 0
      fi

      # Both tokens present: inject full Slack MCP config
      # OpenCode format: type=local, command=array, environment=object
      if [[ -f "$runtime" ]]; then
        tmp="$(mktemp "''${runtime}.tmp.XXXXXX")"
        
        # Escape tokens for jq and inject into mcp.slack
        # MCP is disabled by default; enable manually or use dedicated slack agent when needed
        ${pkgs.jq}/bin/jq \
          --arg xoxc "''${xoxc_token}" \
          --arg xoxd "''${xoxd_token}" \
          '.mcp.slack = {
            "type": "local",
            "command": ["npx", "-y", "slack-mcp-server@latest", "--transport", "stdio"],
            "enabled": false,
            "environment": {
              "SLACK_MCP_XOXC_TOKEN": $xoxc,
              "SLACK_MCP_XOXD_TOKEN": $xoxd,
              "SLACK_MCP_CUSTOM_TLS": "1",
              "SLACK_MCP_USER_AGENT": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/139.0.0.0 Safari/537.36"
            }
          }' "$runtime" > "$tmp"
        
        mv "$tmp" "$runtime"
      fi
    '');
}
