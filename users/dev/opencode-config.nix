# OpenCode configuration management
# Manages opencode.json via home-manager
# with merge-on-activate pattern (runtime keys preserved, managed keys enforced)
{ config, lib, pkgs, localPkgs, assetsPath, isDevbox, isCloudbox, isCrostini, ... }:

let
  isDarwin = pkgs.stdenv.isDarwin;
  useGeminiForAgents = isDarwin || isCloudbox;
  devboxModel = "anthropic/claude-opus-4-8";
  # Compaction model for devbox/crostini: direct Anthropic Sonnet 5 (NOT Vertex).
  # Runs via the Claude Max subscription (teamclaude on devbox / anthropic-auth
  # OAuth on crostini), so there is no per-token cost. Cheaper/faster than Opus
  # for one-shot summarization while staying off the Vertex path.
  sonnetModel = "anthropic/claude-sonnet-5";
  # Cloudbox default: Opus over Vertex (no Claude Max subscription here, unlike
  # devbox). Carries its own high thinking effort from opencode.base.json's
  # google-vertex-anthropic model options, so no variant override is needed.
  vertexOpusModel = "google-vertex-anthropic/claude-opus-4-8@default";
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

  # Patch agent model pins so each host resolves to a model it can actually
  # reach. Two independent, order-independent rewrites:
  #
  #   1. sonnet-5 -> Gemini 3.5 Flash on the Gemini-for-agents hosts (macOS +
  #      cloudbox). These are the cheap plan-execution / research subagents;
  #      Gemini uses Gemini-native thinking levels, so add `variant: high`.
  #
  #   2. opus-4-N -> Vertex Anthropic (`google-vertex-anthropic/claude-opus-4-N@default`)
  #      on cloudbox ONLY. Cloudbox has no first-party `anthropic/` auth (it
  #      routes Anthropic through Vertex/ADC), so an opus agent left pinned to
  #      `anthropic/claude-opus-*` reaches an unusable provider and the model
  #      loop dies with an EMPTY response — the exact silent-failure the oracle
  #      subagent was hitting historically. devbox/crostini keep the direct
  #      `anthropic/claude-opus-*` pin (it is the working primary there via
  #      TeamClaude / anthropic-auth OAuth); macOS is left untouched (status
  #      quo — its primary is Gemini and opus agents are rare there). This
  #      mirrors the host-conditional primary `model =` below
  #      (`if isCloudbox then vertexOpusModel else geminiModel`). The Vertex
  #      opus-4-8 model already carries its own `effort` setting from
  #      opencode.base.json, so no variant override is added here. (opus-4-7
  #      has no provider-level model entry anymore, and no agent is pinned
  #      to it as of 2026-07-03.)
  patchAgent = name: src:
    let
      afterSonnet =
        if useGeminiForAgents then
          pkgs.runCommand "${name}-gemini.md" {} ''
            ${pkgs.perl}/bin/perl -0pe 's|model: anthropic/claude-sonnet-5|model: ${geminiModel}\nvariant: ${geminiVariant}|' ${src} > $out
          ''
        else
          src;
      afterOpus =
        if isCloudbox then
          pkgs.runCommand "${name}-opus-vertex.md" {} ''
            ${pkgs.perl}/bin/perl -0pe 's|model: anthropic/claude-opus-([0-9]+-[0-9]+)|model: google-vertex-anthropic/claude-opus-''${1}\@default|' ${afterSonnet} > $out
          ''
        else
          afterSonnet;
      # 3. fable-5 -> Vertex Anthropic on cloudbox ONLY, mirroring the opus
      #    rewrite above and for the same reason: cloudbox has no first-party
      #    `anthropic/` auth (it routes Anthropic through Vertex/ADC), so an
      #    agent left pinned to `anthropic/claude-fable-5` reaches an unusable
      #    provider and the model loop dies with an empty response. The Vertex
      #    fable-5 entry (`google-vertex-anthropic/claude-fable-5@default`)
      #    carries its own high `effort` from opencode.base.json, so no variant
      #    override is added here. No-op on agents that don't pin fable-5.
      afterFable =
        if isCloudbox then
          pkgs.runCommand "${name}-fable-vertex.md" {} ''
            ${pkgs.perl}/bin/perl -0pe 's|model: anthropic/claude-fable-5|model: google-vertex-anthropic/claude-fable-5\@default|' ${afterOpus} > $out
          ''
        else
          afterOpus;
    in
      afterFable;

  # adversarial-reviewer-fable: a fable-5-pinned twin of adversarial-reviewer-opus.
  # Generated from the SAME source body at build time so the ~130-line prompt
  # has a single source of truth (no hand-maintained second copy to drift).
  # Rewrites only the model pin (opus-4-8 -> fable-5) and the matching
  # "(opus-4-8 model)" token in the description, so the two show up under
  # distinct handles with self-describing descriptions in the task-tool list.
  # The result is fed through patchAgent, whose afterFable branch applies the
  # cloudbox Vertex rewrite.
  # The description also gets a CAUTION appended so the orchestrator does NOT
  # auto-select the cheaper model: the fable twin is opt-in, only when the user
  # explicitly asks for it; otherwise adversarial-reviewer-opus is the default.
  #
  # IMPORTANT: the appended text must NOT contain a colon-space (": "). opencode
  # parses agent frontmatter with gray-matter/js-yaml (packages/opencode/src/
  # config/markdown.ts), and a ": " inside an unquoted YAML scalar (the
  # `description:` value) makes the primary `matter()` parse THROW, forcing the
  # fragile fallbackSanitization double-parse path. That path is racy under the
  # concurrent agent-load in loadAgent(): it nondeterministically fails, and a
  # failed parse SKIPS the agent (config.ts:198-207), leaving a default stub
  # (mode=all, model=null) that silently runs the caller's model (opus) instead
  # of fable. Colon-free descriptions (like the opus twin's) parse on the first
  # try and are rock-solid, so we keep this value colon-free (em-dash instead).
  mkFableVariant = src:
    pkgs.runCommand "adversarial-reviewer-fable-src.md" {} ''
      ${pkgs.perl}/bin/perl -0pe '
        s|model: anthropic/claude-opus-4-8|model: anthropic/claude-fable-5|;
        s|\(opus-4-8 model\)|(fable-5 model)|;
        s|^(description: .*)$|$1. CAUTION — use this fable-5 variant ONLY when the user explicitly asks for it; otherwise default to adversarial-reviewer-opus|m;
      ' ${src} > $out
    '';

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

  # --enable-write-tools surfaces the incident write tools (resolve, acknowledge,
  # reassign, add notes, etc.) in addition to the read tools. The MCP is still
  # enabled:false by default, so write tools only load when the operator
  # deliberately switches the server on. Requires a token whose user can manage
  # the target incidents.
  pagerduty-mcp = pkgs.writeShellApplication {
    name = "pagerduty-mcp";
    runtimeInputs = [ pkgs.uv ];
    text = ''
      exec uvx --from 'pagerduty-mcp==0.17.0' pagerduty-mcp --enable-write-tools "$@"
    '';
  };

  # Rollbar's official MCP server (stdio). Read-oriented tools (get-item-details,
  # list-items, get-deployments, get-top-items, get-version, get-replay) need only
  # a project access token with `read` scope; update-item additionally needs `write`.
  # Pinned to avoid surprise upstream changes, mirroring the pagerduty-mcp wrapper.
  rollbar-mcp = pkgs.writeShellApplication {
    name = "rollbar-mcp";
    runtimeInputs = [ pkgs.nodejs ];
    text = ''
      exec npx -y '@rollbar/mcp-server@0.5.0' "$@"
    '';
  };

  opencodeBase = builtins.fromJSON (builtins.readFile "${assetsPath}/opencode/opencode.base.json");

  # codex-lb (devbox only): ChatGPT/Codex-subscription models served by the local
  # codex-lb rotator (127.0.0.1:2455). These model IDs only exist for a ChatGPT
  # subscription account routed through codex-lb — NOT the direct OpenAI API — so
  # they are injected on devbox only, and only take effect while codex-lb.service
  # is up (see injectCodexLbBaseUrl below, which flips
  # provider.openai.options.baseURL to codex-lb and clears the openai auth entry).
  # Subscription usage has no per-token billing, so cost is zeroed here (codex-lb's
  # own dashboard tracks real spend). Effort defaults track each tier's role:
  # Sol = frontier (high), Terra = balanced (medium), Luna = fast (low); override
  # per call with a variant if needed.
  mkCodexLbModel = { name, effort }: {
    inherit name;
    reasoning = true;
    tool_call = true;
    attachment = true;
    release_date = "2026-06-01";
    cost = { input = 0; output = 0; cache_read = 0; };
    limit = { context = 272000; output = 128000; };
    modalities = { input = [ "text" "image" ]; output = [ "text" ]; };
    options = {
      reasoningEffort = effort;
      reasoningSummary = "auto";
      include = [ "reasoning.encrypted_content" ];
    };
  };
  codexLbModels = {
    "gpt-5.6-sol" = mkCodexLbModel { name = "GPT-5.6 Sol"; effort = "high"; };
    "gpt-5.6-terra" = mkCodexLbModel { name = "GPT-5.6 Terra"; effort = "medium"; };
    "gpt-5.6-luna" = mkCodexLbModel { name = "GPT-5.6 Luna"; effort = "low"; };
  };

  # Platform overlay:
  # - devbox + crostini default to the Anthropic subscription path, so sessions
  #   do not depend on the OpenAI API key.
  # - cloudbox defaults to Vertex Opus 4.8 (interactive primary model), while
  #   keeping compaction + the plan-execution subagents on cheap Gemini Flash.
  # - macOS defaults to Vertex Gemini 3.5 Flash on high thinking.
  # - macOS + cloudbox get Atlassian MCP wiring.
  # OpenAI GPT-5.5 remains in opencode.base.json as a runtime fallback; its
  # provider options stay there because OpenCode defaults GPT-5.x to medium
  # reasoning unless a variant or model option overrides it.
  opencodeOverlay =
    (lib.optionalAttrs (isDevbox || isCrostini) {
      model = devboxModel;
      # Route the built-in `compaction` agent to Sonnet 5 on devbox/crostini.
      # Without this, compaction inherits opencode.base.json's top-level default
      # (openai/gpt-5.5), which is billed per-token AND hits OpenAI usage caps —
      # leaving sessions stuck retrying "usage limit reached" forever (the
      # cloudbox/darwin branch routes compaction to cheap Gemini Flash instead).
      # On devbox/crostini Sonnet 5 runs via the Claude Max subscription
      # (teamclaude on devbox / anthropic-auth OAuth on crostini), so there is no
      # per-token cost; Vertex Gemini Flash isn't available here anyway. Sonnet
      # (vs. the interactive Opus default) is plenty for one-shot summarization.
      agent.compaction.model = sonnetModel;
      # vision-qa (deployed below on devbox/crostini only) uses the direct
      # Google Generative AI API here (google/gemini-3.5-flash,
      # GOOGLE_GENERATIVE_AI_API_KEY / GEMINI_API_KEY auth — no Vertex).
      # Inject the same cost/limit catalog entry used for the Vertex flavor
      # below so cost tracking (oc-cost/aigateway) stays accurate.
      provider = {
        google = (opencodeBase.provider.google or {}) // {
          models = ((opencodeBase.provider.google or {}).models or {}) // {
            "gemini-3.5-flash" = gemini35FlashModel;
          };
        };
      } // lib.optionalAttrs isDevbox {
        # codex-lb subscription models (devbox only). Merged into the base openai
        # provider (which carries options.chunkTimeout + gpt-5.5) by the outer
        # recursiveUpdate, so gpt-5.5 and the sol/terra/luna tiers coexist. The
        # baseURL/apiKey that route these through codex-lb are set dynamically by
        # injectCodexLbBaseUrl (gated on codex-lb.service being active).
        openai = { models = codexLbModels; };
      };
    })
    // (lib.optionalAttrs isCloudbox {
      # Cloudbox uses Vertex/ADC for Google models; hide the direct
      # Google Generative AI API provider to avoid selecting google/* by mistake.
      disabled_providers = [ "google" ];
    })
    // (lib.optionalAttrs (isDarwin || isCloudbox) {
      # Default model differs by host:
      #   - cloudbox -> Vertex Opus 4.8 (interactive primary model). The plan-
      #     execution subagents + compaction stay on cheap Gemini Flash below.
      #   - macOS    -> Gemini 3.5 Flash with high thinking (unchanged).
      model = if isCloudbox then vertexOpusModel else geminiModel;
      agent = {
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
      } // lib.optionalAttrs isDarwin {
        # Gemini-native high thinking for the build/plan agents on macOS only.
        # Cloudbox defaults to Opus, which uses its own high effort from
        # opencode.base.json, so it gets no Gemini-style variant override.
        build.variant = geminiVariant;
        plan.variant = geminiVariant;
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

  # Config for worktree-guard plugin (warn/block edits to enrolled primary roots).
  # Scoped to cloudbox: that's the only host where the mono read-only-main guard
  # is currently enrolled. Other hosts don't get the config, so the plugin (if
  # present) reads no enrolled roots and no-ops.
  xdg.configFile."opencode/worktree-guard.json" = lib.mkIf isCloudbox {
    text = builtins.toJSON [ { path = "/home/dev/projects/mono"; trunk = "main"; enforce = "warn"; worktreesDir = ".worktrees"; } ];
  };

   # Custom agents via OpenCode-native markdown format.
   # OpenCode loads agents from ~/.config/opencode/agents/ with tools as a YAML map.
   xdg.configFile."opencode/agents/librarian.md".source = patchAgent "librarian" "${assetsPath}/opencode/agents/librarian.md";
   xdg.configFile."opencode/agents/oracle.md".source = patchAgent "oracle" "${assetsPath}/opencode/agents/oracle.md";
   # Two distinctly-named twins so the model is unambiguous at the call site:
   #   @adversarial-reviewer-opus  -> opus-4-8 (source of truth for the prompt)
   #   @adversarial-reviewer-fable -> claude-fable-5 (generated from the opus
   #                                  source via mkFableVariant, no body drift)
   xdg.configFile."opencode/agents/adversarial-reviewer-opus.md".source = patchAgent "adversarial-reviewer-opus" "${assetsPath}/opencode/agents/adversarial-reviewer-opus.md";
   xdg.configFile."opencode/agents/adversarial-reviewer-fable.md".source =
     patchAgent "adversarial-reviewer-fable" (mkFableVariant "${assetsPath}/opencode/agents/adversarial-reviewer-opus.md");
   xdg.configFile."opencode/agents/implementer.md".source = patchAgent "implementer" "${assetsPath}/opencode/agents/implementer.md";
   xdg.configFile."opencode/agents/spec-reviewer.md".source = patchAgent "spec-reviewer" "${assetsPath}/opencode/agents/spec-reviewer.md";
   xdg.configFile."opencode/agents/code-reviewer.md".source = patchAgent "code-reviewer" "${assetsPath}/opencode/agents/code-reviewer.md";
   # vision-qa is API-key-only by design (no Vertex): its base pin is
   # google/gemini-3.5-flash (Google Generative AI API, authed via
   # GOOGLE_GENERATIVE_AI_API_KEY / GEMINI_API_KEY from sops). Deploy it only
   # on the hosts where that auth path exists — devbox + crostini. macOS has
   # no Gemini API key (Vertex ADC only) and cloudbox deliberately disables
   # the direct `google` provider (disabled_providers above), so neither
   # gets the agent. Bare source, no patchAgent: the pin is already
   # host-correct where deployed and must NOT be rewritten to Vertex.
   xdg.configFile."opencode/agents/vision-qa.md" = lib.mkIf (isDevbox || isCrostini) {
     source = "${assetsPath}/opencode/agents/vision-qa.md";
   };

     # Plugins (SRP: shell env injection, compaction context, subagent routing)
      xdg.configFile."opencode/plugins/shell-env.ts".source = "${assetsPath}/opencode/plugins/shell-env.ts";
     xdg.configFile."opencode/plugins/compaction-context.ts".source = "${assetsPath}/opencode/plugins/compaction-context.ts";
     # worktree-guard plugin: scoped to cloudbox (the only host with the mono
     # read-only-main guard enrolled). Pairs with the cloudbox-gated
     # worktree-guard.json above.
     xdg.configFile."opencode/plugins/worktree-guard.ts" = lib.mkIf isCloudbox {
       source = "${assetsPath}/opencode/plugins/worktree-guard.ts";
     };
   # Subagent routing overrides model selection for plan execution subagents
   # (implementer, spec-reviewer, code-reviewer). Disabled on devbox to let
   # subagents inherit the primary model, giving flexibility to choose at runtime.
    xdg.configFile."opencode/plugins/subagent-routing.ts" = lib.mkIf (isDarwin || isCloudbox) {
      source = "${assetsPath}/opencode/plugins/subagent-routing.ts";
    };
    # session-header injects x-opencode-session into google-vertex-anthropic
    # requests so the cloudbox claude-failover-proxy can do sticky / idle-migrate
    # routing (cache-affinity). Cloudbox-only: that is the only host whose
    # google-vertex-anthropic baseURL is (or will be, see T13) the router.
    xdg.configFile."opencode/plugins/session-header.ts" = lib.mkIf isCloudbox {
      source = "${assetsPath}/opencode/plugins/session-header.ts";
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
      # REQUIRED for the devbox TeamClaude routing — this plugin shapes opencode's
      # requests into Claude-Code OAuth form (anthropic-beta, ?beta=true, "You are
      # Claude Code" system identity, mcp_ tool prefixes) which premium models
      # require; TeamClaude only swaps the token, it does NOT shape. Removing it
      # makes opus/sonnet 429 and TeamClaude retry-loop forever. See
      # injectTeamclaudeBaseUrl below for the full coexistence rationale.
      "@ex-machina/opencode-anthropic-auth" = "1.8.0";
      "opencode-beads" = "0.6.0";
    };
    pinJson = builtins.toJSON opencodePluginPins;
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
    ${lib.optionalString isDevbox ''
      if [ "$cache_invalidated" = "1" ]; then
        # devbox: opencode-serve is a USER service (see home.devbox.nix), so
        # restart it in the user manager — no sudo. Ensure XDG_RUNTIME_DIR is set
        # so `systemctl --user` can reach the user bus even when this activation
        # runs from a context that didn't export it. Use the absolute systemctl
        # path (the activation PATH is minimal). Capture the exit code into a
        # variable (the `cmd || rc=$?` pattern) to stay robust to home-manager's
        # set -e / errexit-mask interactions.
        export XDG_RUNTIME_DIR="''${XDG_RUNTIME_DIR:-/run/user/$UID}"
        restart_rc=0
        /run/current-system/sw/bin/systemctl --user restart opencode-serve.service || restart_rc=$?
        if [ "$restart_rc" -eq 0 ]; then
          echo "installOpencodePlugins: restarted opencode-serve (user) after cache invalidation"
        else
          # Don't fail the whole activation — the service has Restart=always and
          # the nightly timer restarts it too. Surface the failure clearly.
          {
            echo "installOpencodePlugins: WARNING — user opencode-serve restart failed (exit $restart_rc)."
            echo "installOpencodePlugins: cache was invalidated but service still running stale plugin."
            echo "installOpencodePlugins: run manually: systemctl --user restart opencode-serve"
          } >&2
        fi
      fi
    ''}
    ${lib.optionalString isCloudbox ''
      if [ "$cache_invalidated" = "1" ]; then
        # cloudbox: opencode-serve is a system service; restart with sudo.
        # Use sudo since the service is system-level (cloudbox has
        # wheelNeedsPassword=false).
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
  # Uses PagerDuty's official local stdio server with write tools enabled
  # (see the pagerduty-mcp wrapper). Disabled by default; enabling the server
  # loads both read and write (resolve/ack/reassign) tools, so enable only when
  # you intend to act on incidents.
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

  # Inject Rollbar MCP secrets from macOS Keychain into opencode.json.
  # Uses Rollbar's official local stdio server. Disabled by default; enable only
  # when triaging an error. Token is a project access token (read scope is enough
  # for the read tools the triage flow uses).
  home.activation.injectRollbarMcpSecrets = lib.mkIf isDarwin
    (lib.hm.dag.entryAfter [ "mergeOpencode" ] ''
      set -euo pipefail

      runtime="$HOME/.config/opencode/opencode.json"

      rollbar_token="$(/usr/bin/security find-generic-password -s rollbar-access-token -w 2>/dev/null || true)"

      if [[ -z "''${rollbar_token}" ]]; then
        if [[ -f "$runtime" ]]; then
          tmp="$(mktemp "''${runtime}.tmp.XXXXXX")"
          ${pkgs.jq}/bin/jq 'del(.mcp.rollbar)' "$runtime" > "$tmp"
          mv "$tmp" "$runtime"
        fi
        echo "Rollbar access token not found in Keychain; removed mcp.rollbar from config" >&2
        exit 0
      fi

      if [[ -f "$runtime" ]]; then
        tmp="$(mktemp "''${runtime}.tmp.XXXXXX")"

        ${pkgs.jq}/bin/jq \
          --arg command "${rollbar-mcp}/bin/rollbar-mcp" \
          --arg token "''${rollbar_token}" \
          '.mcp.rollbar = {
            "type": "local",
            "command": [$command],
            "enabled": false,
            "environment": {
              "ROLLBAR_ACCESS_TOKEN": $token
            }
          }' "$runtime" > "$tmp"

        mv "$tmp" "$runtime"
      fi
    '');

  # Inject Rollbar MCP secrets from sops on cloudbox into opencode.json.
  # Same pattern as Darwin, but reads from /run/secrets/ instead of Keychain.
  home.activation.injectRollbarMcpSecretsSops = lib.mkIf isCloudbox
    (lib.hm.dag.entryAfter [ "mergeOpencode" ] ''
      set -euo pipefail

      runtime="$HOME/.config/opencode/opencode.json"

      rollbar_token=""
      if [ -r /run/secrets/rollbar_access_token ]; then
        rollbar_token="$(cat /run/secrets/rollbar_access_token)"
      fi

      if [[ -z "''${rollbar_token}" ]]; then
        if [[ -f "$runtime" ]]; then
          tmp="$(mktemp "''${runtime}.tmp.XXXXXX")"
          ${pkgs.jq}/bin/jq 'del(.mcp.rollbar)' "$runtime" > "$tmp"
          mv "$tmp" "$runtime"
        fi
        echo "Rollbar access token not found in sops; removed mcp.rollbar from config" >&2
        exit 0
      fi

      if [[ -f "$runtime" ]]; then
        tmp="$(mktemp "''${runtime}.tmp.XXXXXX")"

        ${pkgs.jq}/bin/jq \
          --arg command "${rollbar-mcp}/bin/rollbar-mcp" \
          --arg token "''${rollbar_token}" \
          '.mcp.rollbar = {
            "type": "local",
            "command": [$command],
            "enabled": false,
            "environment": {
              "ROLLBAR_ACCESS_TOKEN": $token
            }
          }' "$runtime" > "$tmp"

        mv "$tmp" "$runtime"
      fi
    '');

  # Inject (or strip) the aigateway baseURL override on cloudbox.
  # Trigger: `aigateway.service` is currently active AND we have a
  # GOOGLE_CLOUD_PROJECT secret. When both conditions hold: set both
  # `provider.google-vertex-anthropic.options.baseURL` (Claude) AND
  # `provider.google-vertex.options.baseURL` (Gemini) to URLs pointing
  # at the local Docker gateway, with the project baked into the path.
  # Otherwise: strip the overrides so opencode falls back to direct Vertex.
  #
  # NOTE: Gemini (`google-vertex/gemini-3.5-flash`) is the GLOBAL DEFAULT
  # model on cloudbox, so routing it through the gateway means every
  # session (interactive + opencode-serve/pigeon/Telegram) depends on the
  # gateway being up. The gateway parses Gemini `usageMetadata` and prices
  # `gemini-3.5-flash`; unpriced Gemini models still ledger tokens (NULL
  # dollars). Verified live 2026-06-05 — see investigation report
  # docs/investigations/2026-06-05-vertex-gemini-surge/aigateway-cost-fix.md.
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

      # Provider routing toggles (DECOUPLED as of T13b / 8fe.14):
      #   - gemini (google-vertex)            follows aigateway.service
      #   - claude (google-vertex-anthropic)  follows claude-failover-proxy.service
      #     (the cfp budget-gated Vertex<->Max failover router on :8789).
      # `is-active` returns "active" once ExecStart succeeds (RemainAfterExit
      # keeps that for the oneshot aigateway); "activating" is also treated as
      # opt-in. Anything else (inactive/failed/unknown) means not running.
      sc=/run/current-system/sw/bin/systemctl
      aigw_state="$($sc is-active aigateway.service 2>/dev/null || true)"
      cfp_state="$($sc is-active claude-failover-proxy.service 2>/dev/null || true)"

      project=""
      if [ -r /run/secrets/google_cloud_project ]; then
        project="$(cat /run/secrets/google_cloud_project)"
      fi

      # Desired baseURL per provider ("" => strip the override => opencode's
      # built-in direct-Vertex default).
      anthropic_url=""
      gemini_url=""
      if [ -z "$project" ]; then
        echo "aigateway/cfp: GOOGLE_CLOUD_PROJECT secret unavailable; both providers -> direct Vertex" >&2
      else
        # Gemini: aigateway only — cfp is anthropic-only and NEVER routes gemini.
        # Shape differs from anthropic: v1beta1, publishers/google, NO trailing
        # /models (the @ai-sdk/google-vertex `getBaseURL` appends
        # /models/<id>:streamGenerateContent itself). Verified live 2026-06-05.
        case "$aigw_state" in
          active|activating)
            gemini_url="http://localhost:8080/v1beta1/projects/$project/locations/global/publishers/google" ;;
        esac
        # Claude: prefer the cfp router (:8789). It re-bases the incoming Vertex
        # path onto its CFP_AIGATEWAY_URL (:8080), so the upstream call is
        # byte-identical to hitting the aigateway directly (verified). Use
        # 127.0.0.1 (cfp binds IPv4 *:8789; "localhost" may resolve to ::1).
        # Fallback when the router is down: the aigateway directly — preserves the
        # cost ledger AND is the exact pre-T13b behavior, so simply stopping
        # claude-failover-proxy.service + re-running this activation is a clean
        # rollback. If BOTH are down, leave it stripped (direct Vertex).
        case "$cfp_state" in
          active|activating)
            anthropic_url="http://127.0.0.1:8789/v1/projects/$project/locations/global/publishers/anthropic/models" ;;
          *)
            case "$aigw_state" in
              active|activating)
                anthropic_url="http://localhost:8080/v1/projects/$project/locations/global/publishers/anthropic/models" ;;
            esac ;;
        esac
      fi

      # Apply: set baseURL when non-empty, else delete it; then prune any
      # options/provider objects we emptied so the merged config stays clean.
      if [[ -f "$runtime" ]]; then
        tmp="$(mktemp "''${runtime}.tmp.XXXXXX")"
        ${pkgs.jq}/bin/jq --arg a "$anthropic_url" --arg g "$gemini_url" '
            (if $a == "" then del(.provider."google-vertex-anthropic".options.baseURL)
             else .provider."google-vertex-anthropic".options.baseURL = $a end)
          | (if $g == "" then del(.provider."google-vertex".options.baseURL)
             else .provider."google-vertex".options.baseURL = $g end)
          | (if .provider."google-vertex-anthropic".options == {}
             then del(.provider."google-vertex-anthropic".options) else . end)
          | (if .provider."google-vertex-anthropic" == {}
             then del(.provider."google-vertex-anthropic") else . end)
          | (if .provider."google-vertex".options == {}
             then del(.provider."google-vertex".options) else . end)
          | (if .provider."google-vertex" == {}
             then del(.provider."google-vertex") else . end)
          | (if .provider == {} then del(.provider) else . end)' \
          "$runtime" > "$tmp"
        mv "$tmp" "$runtime"
      fi

      echo "aigateway/cfp: claude -> ''${anthropic_url:-<direct Vertex>} (cfp=$cfp_state); gemini -> ''${gemini_url:-<direct Vertex>} (aigw=$aigw_state)" >&2
      new_hash="$(printf '%s\n%s' "$anthropic_url" "$gemini_url" | ${pkgs.coreutils}/bin/sha256sum | ${pkgs.coreutils}/bin/cut -d' ' -f1)"

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

  # Point opencode's first-party `anthropic` provider at the local TeamClaude
  # rotator (devbox) when its user service is active; otherwise strip the
  # override so opencode talks to api.anthropic.com directly. TeamClaude proxies
  # /v1/* to api.anthropic.com and SWAPS IN the active Max account's OAuth bearer
  # token, and exempts localhost from its x-api-key gate — so 127.0.0.1:3456/v1
  # with no key is all the *transport* opencode needs.
  #
  # BUT TeamClaude only swaps the token; it does NOT shape the request. Claude Max
  # OAuth tokens require a Claude-Code-shaped request (anthropic-beta:
  # oauth-2025-04-20, ?beta=true, a "You are Claude Code" system identity, mcp_
  # tool prefixes) or Anthropic 429s the premium models (opus/sonnet) — which
  # TeamClaude then misreads as quota and retries forever, hanging opencode. The
  # @ex-machina/opencode-anthropic-auth plugin is what produces that shaping, so
  # IT MUST STAY LOADED (see opencode.base.json + opencodePluginPins above). The
  # plugin also auto-refreshes its own OAuth credential, and since it shares
  # Claude Code's client_id with TeamClaude over the same accounts, that refresh
  # rotates the grant family and invalidates TeamClaude's tokens (invalid_grant).
  # Fix: the seed step below writes a NON-EXPIRING DUMMY oauth credential into
  # opencode's auth store so the plugin stays in oauth mode (shapes requests +
  # zeros cost) but never refreshes; TeamClaude overwrites the dummy bearer anyway
  # and remains the sole token owner. (Tradeoff: when TeamClaude is down the
  # direct-Anthropic fallback can't authenticate with the dummy — acceptable on
  # this play box; stop teamclaude AND re-`opencode auth login` to go fully direct.)
  #
  # Gated + auto-fallback (mirrors injectAigatewayBaseUrl): the override only
  # takes effect once accounts are seeded (`teamclaude login`) and the unit is
  # started, and reverts to direct Anthropic the moment teamclaude.service is
  # stopped + this activation re-runs — so stopping the service is a clean
  # rollback. opencode-serve (a USER service on devbox) is restarted when the
  # effective URL changes OR the dummy credential is freshly seeded.
  #
  # Path shape: api.anthropic.com base is .../v1 and @ai-sdk/anthropic appends
  # /messages, so the override is .../v1 (no trailing /messages). The
  # `anthropic.options` object also carries chunkTimeout from
  # opencode.base.json, so the empty-object prune below never deletes it.
  # (The overall per-request `timeout` was removed 2026-07-05: it killed
  # legitimately long streaming turns; silent-SSE hangs are caught by
  # chunkTimeout, and the pigeon delivery watchdog recovers wedged
  # messaged sessions — the layered replacement for the May crude bound.)
  home.activation.injectTeamclaudeBaseUrl = lib.mkIf isDevbox
    (lib.hm.dag.entryAfter [ "mergeOpencode" ] ''
      set -euo pipefail

      runtime="$HOME/.config/opencode/opencode.json"
      hash_file="$HOME/.cache/workstation/teamclaude-url.hash"
      mkdir -p "$(dirname "$hash_file")"

      # devbox opencode-serve + teamclaude are USER services; reach the user bus.
      export XDG_RUNTIME_DIR="''${XDG_RUNTIME_DIR:-/run/user/$UID}"
      sc=/run/current-system/sw/bin/systemctl
      tc_state="$($sc --user is-active teamclaude.service 2>/dev/null || true)"

      anthropic_url=""
      case "$tc_state" in
        active|activating)
          anthropic_url="http://127.0.0.1:3456/v1" ;;
      esac

      seeded=0

      if [[ -f "$runtime" ]]; then
        tmp="$(mktemp "''${runtime}.tmp.XXXXXX")"
        ${pkgs.jq}/bin/jq --arg a "$anthropic_url" '
            (if $a == "" then del(.provider.anthropic.options.baseURL)
             else .provider.anthropic.options.baseURL = $a end)
          | (if (.provider.anthropic.options // {}) == {}
             then del(.provider.anthropic.options) else . end)
          | (if (.provider.anthropic // {}) == {}
             then del(.provider.anthropic) else . end)
          | (if (.provider // {}) == {} then del(.provider) else . end)' \
          "$runtime" > "$tmp"
        mv "$tmp" "$runtime"
      fi

      # When routing through TeamClaude, make the @ex-machina/opencode-anthropic-auth
      # plugin SHAPE-ONLY: seed a non-expiring dummy oauth credential so the plugin
      # stays in oauth mode (shapes the Claude-Code request + zeros cost) but never
      # refreshes. TeamClaude owns + rotates the real tokens and overwrites the dummy
      # bearer. (See the header comment for the full rationale.) Enforced on every
      # switch while teamclaude is active, so a stray `opencode auth login` can't
      # reintroduce the refresh conflict; idempotent via the sorted-key compare. When
      # teamclaude is stopped (anthropic_url empty) we DON'T touch the auth store, so
      # going direct just needs a real `opencode auth login`.
      if [[ -n "$anthropic_url" ]]; then
        auth="$HOME/.local/share/opencode/auth.json"
        mkdir -p "$(dirname "$auth")"
        [[ -f "$auth" ]] || echo '{}' > "$auth"
        want="$(${pkgs.jq}/bin/jq -cnS '{type:"oauth",access:"teamclaude-managed-noop",refresh:"teamclaude-managed-noop",expires:4102444800000}')"
        have="$(${pkgs.jq}/bin/jq -cS '.anthropic // empty' "$auth" 2>/dev/null || true)"
        if [[ "$have" != "$want" ]]; then
          atmp="$(mktemp "''${auth}.tmp.XXXXXX")"
          ${pkgs.jq}/bin/jq '.anthropic = {type:"oauth",access:"teamclaude-managed-noop",refresh:"teamclaude-managed-noop",expires:4102444800000}' \
            "$auth" > "$atmp"
          mv "$atmp" "$auth"
          chmod 600 "$auth"
          seeded=1
          echo "teamclaude: seeded non-expiring dummy anthropic oauth credential (plugin shape-only; teamclaude owns tokens)" >&2
        fi
      fi

      echo "teamclaude: anthropic -> ''${anthropic_url:-<direct Anthropic>} (teamclaude=$tc_state)" >&2
      new_hash="$(printf '%s' "$anthropic_url" | ${pkgs.coreutils}/bin/sha256sum | ${pkgs.coreutils}/bin/cut -d' ' -f1)"

      # Restart opencode-serve (user service) when the effective URL changed OR the
      # dummy credential was freshly seeded — the plugin's loader decides oauth-mode
      # (shaping) at provider init, so a fresh seed needs a reload to take effect.
      old_hash=""
      [ -r "$hash_file" ] && old_hash="$(cat "$hash_file")"
      if [[ "$new_hash" != "$old_hash" || "$seeded" == "1" ]]; then
        echo "teamclaude: state changed (url hash $old_hash -> $new_hash, seeded=$seeded); restarting opencode-serve (user)" >&2
        restart_rc=0
        $sc --user restart opencode-serve.service || restart_rc=$?
        if [ "$restart_rc" -eq 0 ]; then
          echo "$new_hash" > "$hash_file"
          echo "teamclaude: opencode-serve restarted; hash file updated" >&2
        else
          {
            echo "teamclaude: WARNING — opencode-serve restart failed (exit $restart_rc)."
            echo "teamclaude: hash file NOT updated; next switch will retry."
          } >&2
        fi
      fi
    '');

  # Point opencode's first-party `openai` provider at the local codex-lb rotator
  # (devbox) when its user service is active; otherwise strip the override so the
  # provider falls back to its default (direct OpenAI). This is the OpenAI/Codex
  # analog of injectTeamclaudeBaseUrl above, but SIMPLER by design:
  #
  # codex-lb pools ChatGPT/Codex *subscription* OAuth accounts and injects the
  # active account's token + chatgpt-account-id SERVER-SIDE, exposing an
  # OpenAI-compatible /v1 surface that preserves the Responses API + encrypted
  # reasoning. So unlike teamclaude (which only swaps the bearer and needs the
  # anthropic-auth plugin to SHAPE requests + a dummy-cred dance), codex-lb needs
  # NO client-side shaping: opencode's built-in `openai` provider talks to
  # 127.0.0.1:2455/v1 with a throwaway bearer (localhost is auth-exempt on
  # codex-lb). The sol/terra/luna model catalog is injected statically in the
  # managed config above (harmless when codex-lb is down — just unselectable).
  #
  # AUTH STORE: the built-in openai provider prefers an `oauth` entry in
  # auth.json over the provider `apiKey` option, and in oauth mode it sends the
  # user's OWN ChatGPT token + account id — which fights codex-lb's server-side
  # injection. So when routing through codex-lb we DELETE .openai from auth.json,
  # forcing apiKey mode (the throwaway local bearer). codex-lb owns the real
  # tokens. When codex-lb is stopped we DON'T touch the auth store, so going
  # direct just needs a real `opencode auth login`.
  #
  # NO AUTO SERVE-RESTART (deliberate divergence from injectTeamclaudeBaseUrl):
  # devbox runs a serve POOL (opencode-serve@<port>, X-SwitchMethod=keep-old),
  # not a single opencode-serve.service, so home-manager does not cycle the
  # serves on switch and there is no single unit to bounce. (The teamclaude block
  # above still names opencode-serve.service, which no longer exists here, so its
  # restart is already a best-effort no-op.) Rather than kill live pool sessions,
  # we just write the config + clear the auth entry and print the apply command;
  # running serves pick it up on their next natural restart.
  home.activation.injectCodexLbBaseUrl = lib.mkIf isDevbox
    (lib.hm.dag.entryAfter [ "mergeOpencode" ] ''
      set -euo pipefail

      runtime="$HOME/.config/opencode/opencode.json"

      export XDG_RUNTIME_DIR="''${XDG_RUNTIME_DIR:-/run/user/$UID}"
      sc=/run/current-system/sw/bin/systemctl
      clb_state="$($sc --user is-active codex-lb.service 2>/dev/null || true)"

      openai_url=""
      openai_key=""
      case "$clb_state" in
        active|activating)
          openai_url="http://127.0.0.1:2455/v1"
          openai_key="sk-codex-lb-local" ;;
      esac

      if [[ -f "$runtime" ]]; then
        tmp="$(mktemp "''${runtime}.tmp.XXXXXX")"
        ${pkgs.jq}/bin/jq --arg u "$openai_url" --arg k "$openai_key" '
            (if $u == "" then del(.provider.openai.options.baseURL)
             else .provider.openai.options.baseURL = $u end)
          | (if $k == "" then del(.provider.openai.options.apiKey)
             else .provider.openai.options.apiKey = $k end)
          | (if (.provider.openai.options // {}) == {}
             then del(.provider.openai.options) else . end)
          | (if (.provider.openai // {}) == {}
             then del(.provider.openai) else . end)
          | (if (.provider // {}) == {} then del(.provider) else . end)' \
          "$runtime" > "$tmp"
        mv "$tmp" "$runtime"
      fi

      # Force apiKey mode: drop any .openai entry from the auth store so the
      # provider uses the throwaway local bearer instead of the user's own ChatGPT
      # token (which would fight codex-lb's server-side injection). Enforced on
      # every switch while codex-lb is active, so a stray `opencode auth login`
      # can't reintroduce oauth mode.
      if [[ -n "$openai_url" ]]; then
        auth="$HOME/.local/share/opencode/auth.json"
        if [[ -f "$auth" ]] && ${pkgs.jq}/bin/jq -e '.openai' "$auth" >/dev/null 2>&1; then
          atmp="$(mktemp "''${auth}.tmp.XXXXXX")"
          ${pkgs.jq}/bin/jq 'del(.openai)' "$auth" > "$atmp"
          mv "$atmp" "$auth"
          chmod 600 "$auth"
          echo "codex-lb: cleared .openai from auth store (forcing apiKey mode; codex-lb owns tokens)" >&2
        fi
      fi

      echo "codex-lb: openai -> ''${openai_url:-<direct OpenAI>} (codex-lb=$clb_state)" >&2
      if [[ -n "$openai_url" ]]; then
        echo "codex-lb: restart serves to apply -> systemctl --user restart 'opencode-serve@*.service'" >&2
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
