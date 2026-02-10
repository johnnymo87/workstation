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

  # Platform-specific overlay (placeholder for future macOS MCP servers)
  opencodeOverlay = lib.optionalAttrs isDarwin { };

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

   # Plugins (SRP: non-interactive env, compaction context)
   xdg.configFile."opencode/plugins/non-interactive-env.ts".source = "${assetsPath}/opencode/plugins/non-interactive-env.ts";
   xdg.configFile."opencode/plugins/compaction-context.ts".source = "${assetsPath}/opencode/plugins/compaction-context.ts";

   # OpenCode plugins deployed via out-of-store symlink (path resolved at activation, not eval)
    xdg.configFile."opencode/plugins/opencode-pigeon.ts".source =
      config.lib.file.mkOutOfStoreSymlink (
        if isDarwin
        then "${config.home.homeDirectory}/Code/opencode-pigeon/src/index.ts"
        else "${config.home.homeDirectory}/projects/opencode-pigeon/src/index.ts"
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
    # but unmentioned runtime keys are preserved
    ${pkgs.jq}/bin/jq -S -s '.[0] * .[1]' "$base" "$managed" > "$tmp"

    mv "$tmp" "$runtime"
    [[ "$base" == "$runtime" ]] || rm -f "$base"
  '';

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
