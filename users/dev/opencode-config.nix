# OpenCode configuration management
# Manages opencode.json and oh-my-opencode.json via home-manager
# with merge-on-activate pattern (runtime keys preserved, managed keys enforced)
{ lib, pkgs, assetsPath, ... }:

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

  # ---------------------------------------------------------------------------
  # oh-my-opencode.json managed config
  # ---------------------------------------------------------------------------
  ohMyManaged = {
    "$schema" = "https://raw.githubusercontent.com/code-yeongyu/oh-my-opencode/master/assets/oh-my-opencode.schema.json";

    agents = {
      sisyphus = {
        model = "anthropic/claude-opus-4-6";
        variant = "max";
        prompt_append = builtins.readFile "${assetsPath}/opencode/prompts/sisyphus.md";
      };
      hephaestus = {
        model = "openai/gpt-5.2-codex";
        variant = "medium";
      };
      oracle = {
        model = "openai/gpt-5.2";
        variant = "high";
        prompt_append = builtins.readFile "${assetsPath}/opencode/prompts/oracle.md";
      };
      librarian = {
        model = "anthropic/claude-sonnet-4-5";
        prompt_append = builtins.readFile "${assetsPath}/opencode/prompts/librarian.md";
      };
      explore = {
        model = "anthropic/claude-haiku-4-5";
      };
      "multimodal-looker" = {
        model = "google/gemini-3-flash-preview";
      };
      prometheus = {
        model = "anthropic/claude-opus-4-6";
        variant = "max";
        prompt_append = builtins.readFile "${assetsPath}/opencode/prompts/prometheus.md";
      };
      metis = {
        model = "anthropic/claude-opus-4-6";
        variant = "max";
      };
      momus = {
        model = "openai/gpt-5.2";
        variant = "medium";
      };
      atlas = {
        model = "anthropic/claude-sonnet-4-5";
      };
      # Note: Custom "slack" agent is defined via markdown file in assets/opencode/agents/
      # oh-my-opencode.json agent overrides only work for built-in agents
    };

    categories = {
      "visual-engineering" = {
        model = "google/gemini-3-pro-preview";
      };
      ultrabrain = {
        model = "openai/gpt-5.2-codex";
        variant = "xhigh";
      };
      deep = {
        model = "openai/gpt-5.2-codex";
        variant = "medium";
      };
      quick = {
        model = "anthropic/claude-haiku-4-5";
      };
      "unspecified-low" = {
        model = "anthropic/claude-sonnet-4-5";
        variant = "medium";
      };
      "unspecified-high" = {
        model = "anthropic/claude-opus-4-6";
        variant = "max";
      };
      writing = {
        model = "google/gemini-3-flash-preview";
      };
      artistry = {
        model = "google/gemini-3-pro-preview";
        variant = "max";
      };
    };

    # Note: disabled_mcps only works for built-in MCPs (websearch, context7, grep_app)
    # Custom MCPs like "slack" cannot be disabled via this mechanism
    disabled_mcps = [ "websearch" "context7" "grep_app" ];
  };

  ohMyManagedFile = pkgs.writeText "oh-my-opencode.managed.json"
    (builtins.toJSON ohMyManaged);

in
{
  # Symlink managed files to XDG config directory
  xdg.configFile."opencode/opencode.managed.json".source = opencodeManagedFile;
  xdg.configFile."opencode/oh-my-opencode.managed.json".source = ohMyManagedFile;

  # Custom agents via OpenCode-native markdown format
  # OpenCode loads agents from ~/.config/opencode/agents/ with tools as YAML map
  # (NOT Claude Code-style ~/.claude/agents/ with comma-separated tools string)
  xdg.configFile."opencode/agents/slack.md".source = "${assetsPath}/opencode/agents/slack.md";

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

  # Merge managed config into runtime oh-my-opencode.json on each switch
  # Preserves runtime keys; managed keys win on conflict.
  home.activation.mergeOhMyOpencode = lib.hm.dag.entryAfter [ "writeBoundary" "linkGeneration" ] ''
    set -euo pipefail

    runtime="$HOME/.config/opencode/oh-my-opencode.json"
    managed="${ohMyManagedFile}"

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
