# OpenCode configuration management
# Manages opencode.json via home-manager
# with merge-on-activate pattern (runtime keys preserved, managed keys enforced)
{ config, lib, pkgs, localPkgs, assetsPath, isDevbox, isCloudbox, isCrostini, ... }:

let
  isDarwin = pkgs.stdenv.isDarwin;
  useGeminiForAgents = isDarwin || isCloudbox;
  devboxModel = "anthropic/claude-opus-4-8";
  geminiModel = "google-vertex/gemini-3.5-flash";
  geminiVariant = "high";
  gemini35FlashModel = {
    id = "gemini-3.5-flash";
    name = "Gemini 3.5 Flash";
    family = "gemini-flash";
    release_date = "2026-05-19";
    attachment = true;
    reasoning = true;
    temperature = true;
    tool_call = true;
    cost = {
      input = 1.5;
      output = 9;
      cache_read = 0.15;
    };
    limit = {
      context = 1048576;
      output = 65536;
    };
    modalities = {
      input = [ "text" "image" "video" "audio" "pdf" ];
      output = [ "text" ];
    };
  };

  # Patch agent files if needed to override the sonnet hardcoded model.
  # Gemini 3.5 Flash uses Gemini-native thinking levels, not xhigh.
  patchAgent = name: src:
    if useGeminiForAgents then
      pkgs.runCommand "''${name}-gemini.md" {} ''
        ${pkgs.perl}/bin/perl -0pe 's|model: anthropic/claude-sonnet-4-6|model: ${geminiModel}\nvariant: ${geminiVariant}|' ${src} > $out
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

  pagerduty-mcp = pkgs.writeShellApplication {
    name = "pagerduty-mcp";
    runtimeInputs = [ pkgs.uv ];
    text = ''
      exec uvx --from 'pagerduty-mcp==0.17.0' pagerduty-mcp "$@"
    '';
  };

  opencodeBase = builtins.fromJSON (builtins.readFile "${assetsPath}/opencode/opencode.base.json");

  # Platform overlay:
  # - devbox + crostini default to the Anthropic subscription path, so sessions
  #   do not depend on the OpenAI API key.
  # - cloudbox + macOS default to Vertex Gemini 3.5 Flash on high thinking.
  # - macOS + cloudbox get Atlassian MCP wiring.
  # OpenAI GPT-5.5 remains in opencode.base.json as a runtime fallback; its
  # provider options stay there because OpenCode defaults GPT-5.x to medium
  # reasoning unless a variant or model option overrides it.
  opencodeOverlay =
    (lib.optionalAttrs (isDevbox || isCrostini) {
      model = devboxModel;
    })
    // (lib.optionalAttrs isCloudbox {
      # Cloudbox uses Vertex/ADC for Google models; hide the direct
      # Google Generative AI API provider to avoid selecting google/* by mistake.
      disabled_providers = [ "google" ];
    })
    // (lib.optionalAttrs (isDarwin || isCloudbox) {
      model = geminiModel;
      agent = {
        build.variant = geminiVariant;
        plan.variant = geminiVariant;
        # Route the built-in `compaction` agent to Gemini 3.5 Flash. This is the
        # cheap fix for compaction cost on Opus-heavy sessions: Opus pays
        # ~$2.50 per compaction call AND writes 200-400k cache tokens that no
        # subsequent call ever reads (compaction is one-shot summarization),
        # so we pay the 25% cache-write premium for zero benefit. Routing
        # compaction to Flash zeros out both the per-call cost and the
        # wasted cache-write premium. Measured impact: ~$60 / 8 days of
        # compaction spend, ~$22 of which was pure cache-write waste.
        #
        # The deeper structural fix is upstream PR anomalyco/opencode#25100
        # ("feat(opencode): cache-aligned compaction to reuse prefix cache"),
        # which makes the compaction request share its prefix with the main
        # agent loop so the dropped messages serve from cache (~90% cheaper
        # per compaction). Open as of 2026-05-27, not yet merged. If/when it
        # lands upstream, revisit whether this override is still needed.
        compaction.model = geminiModel;
      };
      provider = (opencodeBase.provider or {}) // {
        "google-vertex" = (opencodeBase.provider."google-vertex" or {}) // {
          models = ((opencodeBase.provider."google-vertex" or {}).models or {}) // {
            "gemini-3.5-flash" = gemini35FlashModel;
          };
        };
      };
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
    });

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

   # Custom agents via OpenCode-native markdown format.
   # OpenCode loads agents from ~/.config/opencode/agents/ with tools as a YAML map.
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
      # MCP is disabled by default; enable manually or use dedicated slack agent when needed.
      # Two variants: `slack` (read + write, SLACK_MCP_ADD_MESSAGE_TOOL=true) and
      # `slack-ro` (read-only; omits SLACK_MCP_ADD_MESSAGE_TOOL so the korotovsky
      # server registers read tools only). slack-ro is used by lgtm's read-only
      # gather session (`opencode-launch --mcp slack-ro`) so it structurally cannot post.
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
          }
          | .mcp."slack-ro" = {
            "type": "local",
            "command": ["npx", "-y", "slack-mcp-server@latest", "--transport", "stdio"],
            "enabled": false,
            "environment": {
              "SLACK_MCP_XOXP_TOKEN": $xoxp
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

      # If token is missing or empty, delete both slack variants and exit cleanly
      if [[ -z "''${xoxp_token}" ]]; then
        if [[ -f "$runtime" ]]; then
          tmp="$(mktemp "''${runtime}.tmp.XXXXXX")"
          ${pkgs.jq}/bin/jq 'del(.mcp.slack) | del(.mcp."slack-ro")' "$runtime" > "$tmp"
          mv "$tmp" "$runtime"
        fi
        echo "Slack MCP xoxp token not found in sops; removed mcp.slack + mcp.slack-ro from config" >&2
        exit 0
      fi

      # Token present: inject Slack MCP config with xoxp auth.
      # Two variants: `slack` (read + write) and `slack-ro` (read-only; omits
      # SLACK_MCP_ADD_MESSAGE_TOOL so only read tools register). slack-ro is used
      # by lgtm's read-only gather session so it structurally cannot post.
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
          }
          | .mcp."slack-ro" = {
            "type": "local",
            "command": ["npx", "-y", "slack-mcp-server@latest", "--transport", "stdio"],
            "enabled": false,
            "environment": {
              "SLACK_MCP_XOXP_TOKEN": $xoxp
            }
          }' "$runtime" > "$tmp"

        mv "$tmp" "$runtime"
      fi
    '');

  # Inject PagerDuty MCP secrets from macOS Keychain into opencode.json.
  # Uses PagerDuty's official local stdio server in read-only mode (no
  # --enable-write-tools). Disabled by default; enable only when needed.
  home.activation.injectPagerDutyMcpSecrets = lib.mkIf isDarwin
    (lib.hm.dag.entryAfter [ "mergeOpencode" ] ''
      set -euo pipefail

      runtime="$HOME/.config/opencode/opencode.json"

      pd_api_key="$(/usr/bin/security find-generic-password -s pagerduty-user-api-key -w 2>/dev/null || true)"

      if [[ -z "''${pd_api_key}" ]]; then
        if [[ -f "$runtime" ]]; then
          tmp="$(mktemp "''${runtime}.tmp.XXXXXX")"
          ${pkgs.jq}/bin/jq 'del(.mcp.pagerduty)' "$runtime" > "$tmp"
          mv "$tmp" "$runtime"
        fi
        echo "PagerDuty API token not found in Keychain; removed mcp.pagerduty from config" >&2
        exit 0
      fi

      if [[ -f "$runtime" ]]; then
        tmp="$(mktemp "''${runtime}.tmp.XXXXXX")"

        ${pkgs.jq}/bin/jq \
          --arg command "${pagerduty-mcp}/bin/pagerduty-mcp" \
          --arg api_key "''${pd_api_key}" \
          '.mcp.pagerduty = {
            "type": "local",
            "command": [$command],
            "enabled": false,
            "environment": {
              "PAGERDUTY_USER_API_KEY": $api_key
            }
          }' "$runtime" > "$tmp"

        mv "$tmp" "$runtime"
      fi
    '');

  # Inject PagerDuty MCP secrets from sops on cloudbox into opencode.json.
  # Same pattern as Darwin, but reads from /run/secrets/ instead of Keychain.
  home.activation.injectPagerDutyMcpSecretsSops = lib.mkIf isCloudbox
    (lib.hm.dag.entryAfter [ "mergeOpencode" ] ''
      set -euo pipefail

      runtime="$HOME/.config/opencode/opencode.json"

      pd_api_key=""
      if [ -r /run/secrets/pagerduty_user_api_key ]; then
        pd_api_key="$(cat /run/secrets/pagerduty_user_api_key)"
      fi

      if [[ -z "''${pd_api_key}" ]]; then
        if [[ -f "$runtime" ]]; then
          tmp="$(mktemp "''${runtime}.tmp.XXXXXX")"
          ${pkgs.jq}/bin/jq 'del(.mcp.pagerduty)' "$runtime" > "$tmp"
          mv "$tmp" "$runtime"
        fi
        echo "PagerDuty API token not found in sops; removed mcp.pagerduty from config" >&2
        exit 0
      fi

      if [[ -f "$runtime" ]]; then
        tmp="$(mktemp "''${runtime}.tmp.XXXXXX")"

        ${pkgs.jq}/bin/jq \
          --arg command "${pagerduty-mcp}/bin/pagerduty-mcp" \
          --arg api_key "''${pd_api_key}" \
          '.mcp.pagerduty = {
            "type": "local",
            "command": [$command],
            "enabled": false,
            "environment": {
              "PAGERDUTY_USER_API_KEY": $api_key
            }
          }' "$runtime" > "$tmp"

        mv "$tmp" "$runtime"
      fi
    '');

  # Inject (or strip) the aigateway baseURL override on cloudbox.
  # Trigger: `aigateway.service` is currently active AND we have a
  # GOOGLE_CLOUD_PROJECT secret. When both conditions hold: set
  # `provider.google-vertex-anthropic.options.baseURL` to a URL pointing
  # at the local Docker gateway, with the project baked into the path.
  # Otherwise: strip the override so opencode falls back to direct Vertex.
  #
  # Why is-active and not is-enabled? NixOS unit files live in the
  # read-only /etc/systemd/system (symlinks into the Nix store), so
  # `systemctl enable/disable` fails ("Read-only file system") and
  # `is-enabled` returns "linked" permanently. `is-active` is the signal
  # the operator actually controls via `systemctl start`/`stop`.
  # Persistence across reboot is not preserved (unit is wantedBy = [ ]) —
  # explicit design choice for an opt-in tool.
  #
  # The path shape MUST match what @ai-sdk/google-vertex/anthropic
  # generates by default — verified against
  # node_modules/.bun/@ai-sdk+google-vertex@4.0.112+.../anthropic/index.js
  # (the `getBaseURL` function). If that SDK version drifts in opencode's
  # bundled deps, this hardcoded path may need to move with it. Verified
  # against opencode commit at the time of writing — see design doc
  # 2026-05-13-aigateway-opencode-integration-design.md.
  home.activation.injectAigatewayBaseUrl = lib.mkIf isCloudbox
    (lib.hm.dag.entryAfter [ "mergeOpencode" ] ''
      set -euo pipefail

      runtime="$HOME/.config/opencode/opencode.json"
      hash_file="$HOME/.cache/workstation/aigateway-url.hash"
      mkdir -p "$(dirname "$hash_file")"

      # Trigger: aigateway.service is running. `is-active` returns
      # "active" once ExecStart succeeds (RemainAfterExit keeps that
      # state). "activating" means start.sh is mid-build but we still
      # treat it as opt-in. Anything else (inactive, failed, unknown)
      # means the operator hasn't started it or it crashed.
      active_state="$(/run/current-system/sw/bin/systemctl is-active aigateway.service 2>/dev/null || true)"
      case "$active_state" in
        active|activating) gateway_enabled=1 ;;
        *)                 gateway_enabled=0 ;;
      esac

      project=""
      if [ -r /run/secrets/google_cloud_project ]; then
        project="$(cat /run/secrets/google_cloud_project)"
      fi

      if [[ "$gateway_enabled" = "0" ]] || [[ -z "$project" ]]; then
        if [[ "$gateway_enabled" = "0" ]]; then
          echo "aigateway: aigateway.service is not running (state=$active_state); opencode pointed at direct Vertex" >&2
        else
          echo "aigateway: GOOGLE_CLOUD_PROJECT secret unavailable; opencode pointed at direct Vertex" >&2
        fi
        if [[ -f "$runtime" ]]; then
          tmp="$(mktemp "''${runtime}.tmp.XXXXXX")"
          ${pkgs.jq}/bin/jq 'del(.provider."google-vertex-anthropic".options.baseURL)
                            | if .provider."google-vertex-anthropic".options == {}
                              then del(.provider."google-vertex-anthropic".options) else . end
                            | if .provider."google-vertex-anthropic" == {}
                              then del(.provider."google-vertex-anthropic") else . end
                            | if .provider == {} then del(.provider) else . end' \
            "$runtime" > "$tmp"
          mv "$tmp" "$runtime"
        fi
        new_hash="DIRECT-VERTEX"
      else
        full_url="http://localhost:8080/v1/projects/$project/locations/global/publishers/anthropic/models"
        if [[ -f "$runtime" ]]; then
          tmp="$(mktemp "''${runtime}.tmp.XXXXXX")"
          ${pkgs.jq}/bin/jq --arg url "$full_url" \
            '.provider."google-vertex-anthropic".options.baseURL = $url' \
            "$runtime" > "$tmp"
          mv "$tmp" "$runtime"
        fi
        echo "aigateway: pointed opencode at $full_url" >&2
        new_hash="$(printf '%s' "$full_url" | ${pkgs.coreutils}/bin/sha256sum | ${pkgs.coreutils}/bin/cut -d' ' -f1)"
      fi

      # Auto-restart opencode-serve only when the effective URL changed.
      # Same sudo dance as installOpencodePlugins for the same reasons
      # (sudo path-sanitization, errexit-mask interactions): use absolute
      # paths to systemctl, capture exit code into a variable. Hash file
      # is updated ONLY after a successful restart so the next rebuild
      # retries on failure.
      old_hash=""
      [ -r "$hash_file" ] && old_hash="$(cat "$hash_file")"
      if [[ "$new_hash" != "$old_hash" ]]; then
        echo "aigateway: baseURL changed ($old_hash -> $new_hash); restarting opencode-serve" >&2
        sudo_err="$(mktemp)"
        sudo_rc=0
        /run/wrappers/bin/sudo -n /run/current-system/sw/bin/systemctl restart opencode-serve.service 2>"$sudo_err" || sudo_rc=$?
        if [ "$sudo_rc" -eq 0 ]; then
          echo "$new_hash" > "$hash_file"
          echo "aigateway: opencode-serve restarted; hash file updated" >&2
        else
          {
            echo "aigateway: WARNING — opencode-serve restart failed (sudo exit $sudo_rc):"
            ${pkgs.gnused}/bin/sed 's/^/  /' "$sudo_err"
            echo "aigateway: hash file NOT updated; next rebuild will retry"
          } >&2
        fi
        rm -f "$sudo_err"
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
