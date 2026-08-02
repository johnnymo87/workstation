# OpenCode configuration management
# Manages opencode.json via home-manager
# with merge-on-activate pattern (runtime keys preserved, managed keys enforced)
{ config, lib, pkgs, localPkgs, assetsPath, isDevbox, isCloudbox, ... }:

let
  isDarwin = pkgs.stdenv.isDarwin;
  useGeminiForAgents = isDarwin || isCloudbox;
  devboxModel = "anthropic/claude-opus-5";
  # Compaction model for devbox: direct Anthropic Sonnet 5 (NOT Vertex).
  # Runs via the Claude Max subscription (teamclaude on devbox), so there is no
  # per-token cost. Cheaper/faster than Opus for one-shot summarization while
  # staying off the Vertex path.
  sonnetModel = "anthropic/claude-sonnet-5";
  # Cloudbox default: Opus over Vertex (no Claude Max subscription here, unlike
  # devbox). Carries its own medium thinking effort from opencode.base.json's
  # google-vertex-anthropic model options, so no variant override is needed.
  vertexOpusModel = "google-vertex-anthropic/claude-opus-5@default";
  geminiModel = "google-vertex/gemini-3.6-flash";
  geminiVariant = "high";
  gemini36FlashModel = {
    id = "gemini-3.6-flash";
    name = "Gemini 3.6 Flash";
    family = "gemini-flash";
    release_date = "2026-05-19";
    attachment = true;
    reasoning = true;
    temperature = true;
    tool_call = true;
    cost = {
      input = 1.5;
      output = 7.5;
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
  #   1. sonnet-5 -> Gemini 3.6 Flash on the Gemini-for-agents hosts (macOS +
  #      cloudbox). These are the cheap plan-execution / research subagents;
  #      Gemini uses Gemini-native thinking levels, so add `variant: high`.
  #
  #   2. opus-N -> Vertex Anthropic (`google-vertex-anthropic/claude-opus-N@default`)
  #      on cloudbox ONLY. Cloudbox has no first-party `anthropic/` auth (it
  #      routes Anthropic through Vertex/ADC), so an opus agent left pinned to
  #      `anthropic/claude-opus-*` reaches an unusable provider and the model
  #      loop dies with an EMPTY response — the exact silent-failure the oracle
   #      subagent was hitting historically. devbox keeps the direct
   #      `anthropic/claude-opus-*` pin (it is the working primary there via
   #      TeamClaude); macOS is left untouched (status
  #      quo — its primary is Gemini and opus agents are rare there). This
  #      mirrors the host-conditional primary `model =` below
  #      (`if isCloudbox then vertexOpusModel else geminiModel`). The Vertex
  #      opus-5 model already carries its own `effort` setting from
  #      opencode.base.json, so no variant override is added here. (opus-4-7
  #      and opus-4-8 have no provider-level model entry anymore, and no agent
  #      is pinned to either as of 2026-07-28.)
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
            ${pkgs.perl}/bin/perl -0pe 's|model: anthropic/claude-opus-([0-9]+(?:-[0-9]+)*)|model: google-vertex-anthropic/claude-opus-''${1}\@default|' ${afterSonnet} > $out
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

  # mkAgentVariant: build a model-pinned twin of a `<base>-opus` agent from the
  # SAME source body at build time, so a shared prompt has a single source of
  # truth (no hand-maintained copies to drift). Used for both adversarial-reviewer
  # and oracle (any agent whose opus source pins anthropic/claude-opus-5 and
  # carries an "(opus-5 model)" token in its description). It rewrites only:
  #   - the model pin (opus-5 -> modelPin)
  #   - the "(opus-5 model)" description token -> "(modelTag model)"
  #   - appends an opt-in CAUTION so the orchestrator does NOT auto-select the
  #     twin; `<base>-opus` stays the default.
  # The result is fed through patchAgent for any host rewrites (e.g. the afterFable
  # Vertex rewrite on cloudbox; a no-op for pins no branch matches, like
  # openai/gpt-5.6-sol).
  #
  # IMPORTANT: the appended text must NOT contain a colon-space (": "). opencode
  # parses agent frontmatter with gray-matter/js-yaml (packages/opencode/src/
  # config/markdown.ts), and a ": " inside an unquoted YAML scalar (the
  # `description:` value) makes the primary `matter()` parse THROW, forcing the
  # fragile fallbackSanitization double-parse path. That path is racy under the
  # concurrent agent-load in loadAgent(): it nondeterministically fails, and a
  # failed parse SKIPS the agent (config.ts:198-207), leaving a default stub
  # (mode=all, model=null) that silently runs the caller's model (opus) instead
  # of the pinned one. Colon-free descriptions (like the opus twin's) parse on the
  # first try and are rock-solid, so we keep this value colon-free (em-dash).
  mkAgentVariant = { base, slug, modelPin, modelTag }: src:
    pkgs.runCommand "${base}-${slug}-src.md" {} ''
      ${pkgs.perl}/bin/perl -0pe '
        s|model: anthropic/claude-opus-5|model: ${modelPin}|;
        s|\(opus-5 model\)|(${modelTag} model)|;
        s|^(description: .*)$|$1. CAUTION — use this ${modelTag} variant ONLY when the user explicitly asks for it; otherwise default to ${base}-opus|m;
      ' ${src} > $out
    '';

  # Per-model twin builders, parameterized by base agent name. Apply to any
  # `<base>-opus.md` source.
  #   fable-5    (all hosts; cloudbox gets the Vertex rewrite via patchAgent)
  #   gpt-5.6-sol (ChatGPT/Codex-subscription frontier model via codex-lb on
  #                127.0.0.1:2455; deployed on all hosts, reachable wherever
  #                codex-lb serves it; patchAgent is a pass-through for the pin)
  mkFableVariant = base: mkAgentVariant { inherit base; slug = "fable"; modelPin = "anthropic/claude-fable-5"; modelTag = "fable-5"; };
  mkSolVariant   = base: mkAgentVariant { inherit base; slug = "sol";   modelPin = "openai/gpt-5.6-sol";      modelTag = "gpt-5.6-sol"; };

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
        exec npx -y mcp-remote@0.1.38 https://mcp.atlassian.com/v1/mcp/authv2 ${toString port} --resource "https://''${SITE}/"
      '';
  };

  atlassian-mcp = mkAtlassianMcp {
    name = "atlassian-mcp";
    port = 3334;
    keychainService = "atlassian-site";
    sopsSecret = "atlassian_site";
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

  # DevCycle's local MCP server, shipped as the `dvc-mcp` bin inside
  # @devcycle/cli. We use the LOCAL server (not the hosted
  # https://mcp.devcycle.com/mcp) because DevCycle's OAuth server does not
  # support RFC 7591 dynamic client registration, which opencode's native
  # remote-MCP OAuth flow AND the mcp-remote shim both hard-require — the hosted
  # endpoint fails with "Incompatible auth server: does not support dynamic
  # client registration". The local server instead authenticates via
  # DEVCYCLE_CLIENT_ID / DEVCYCLE_CLIENT_SECRET (+ optional DEVCYCLE_PROJECT_KEY)
  # injected through the `environment` block by the inject* activations below,
  # mirroring the pagerduty-mcp / rollbar-mcp token-gated pattern. Pinned to
  # avoid surprise upstream changes. Several tools are writes (create/update/
  # delete feature|variable), so the entry stays enabled:false by default.
  devcycle-mcp = pkgs.writeShellApplication {
    name = "devcycle-mcp";
    runtimeInputs = [ pkgs.nodejs ];
    text = ''
      exec npx -y --package '@devcycle/cli@6.3.2' dvc-mcp "$@"
    '';
  };

  # ---------------------------------------------------------------------------
  # MCP credential indirection ({file:...} references, not values)
  # ---------------------------------------------------------------------------
  #
  # opencode's config loader runs ConfigVariable.substitute over the RAW TEXT of
  # opencode.json BEFORE it parses the JSON, expanding two forms:
  #
  #   {env:VAR}   -> process.env[VAR]; missing expands to "" (never throws)
  #   {file:PATH} -> file contents, .trim()ed and JSON-escaped; supports ~/,
  #                  absolute, and config-dir-relative paths
  #
  # Because the pass is pre-parse and whole-file, it works in ANY string — MCP
  # `headers` values and MCP `environment` values alike. (Remote MCP url+headers
  # additionally get their own dedicated substitution pass.) Verified against the
  # installed opencode 1.17.13 bundle and then proven live with a dummy secret.
  #
  # This is what lets a credential stay OUT of opencode.json. Previously every
  # inject* activation below read the plaintext and inlined it, which meant a
  # 0600 file in $HOME held live third-party tokens in cleartext — readable by
  # anything running as `dev` (including an agent that `cat`s its own config into
  # a transcript, which is how this was found), and copied verbatim into every
  # opencode.json.bak.* that mergeOpencode spawns. Now the file holds only a
  # PATH, and the secret materializes solely inside the opencode process.
  #
  # WHY {file:} AND NOT {env:}
  # {env:} is the fail-soft form, but the value would have to be in opencode's
  # environment, and it reliably is not: opencode's bash tool runs NON-interactive
  # shells, so ~/.bashrc short-circuits and the home.nix token exports never run
  # (this is the whole reason assets/opencode/plugins/shell-env.ts exists), and
  # the TUI/serve processes have no better guarantee. {file:} reads from the
  # source of truth directly and does not care how the process was started.
  #
  # !! THE HAZARD THAT SHAPES EVERY CALL SITE BELOW !!
  # For the main config, substitute's `missing` mode defaults to "error". A
  # {file:} pointing at a path that does not exist does NOT degrade to empty —
  # it fails the ENTIRE config load:
  #   Error: Configuration is invalid at ...: bad file reference: "{file:...}"
  # That bricks ALL of opencode, not just the one MCP server. So a reference may
  # only ever be written when the target is known to exist. Every inject* block
  # below already had exactly that gate (secret present -> write entry, secret
  # absent -> `del(.mcp.X)`); the gate is preserved verbatim and is now
  # load-bearing rather than merely tidy. Do not "simplify" it away.

  # Where the plaintext a {file:...} points at actually lives, per host.
  #   NixOS (devbox/cloudbox): sops-nix tmpfs at /run/secrets, mode 0400 owner
  #     dev. opencode and opencode-serve both run as dev, so it is readable, and
  #     the plaintext never persists across a reboot.
  #   macOS: there is no /run/secrets. Keychain remains the source of truth, but
  #     nothing in-process can call `security` during config parse, so activation
  #     mirrors each item into a 0600 file under ~/.config/opencode/secrets and
  #     the reference points there. Degrades sanely: opencode.json is still
  #     credential-free and there is one emission path for all hosts; macOS just
  #     does not get the tmpfs property.
  darwinSecretsDir = "$HOME/.config/opencode/secrets";

  # The literal written into opencode.json in place of a credential.
  # `~/` is expanded by substitute itself, which keeps an absolute home path out
  # of the config file too.
  secretRef = name:
    if isDarwin
    then "{file:~/.config/opencode/secrets/${name}}"
    else "{file:/run/secrets/${name}}";

  # macOS only: mirror Keychain item `service` to the 0600 file that secretRef
  # will point at, and set shell variable `flag` to 1 on success.
  #
  # Removes the mirror when the item is gone, so a revoked credential cannot
  # leave opencode pointing at a stale path — the caller's existing gate then
  # strips the MCP entry, which is what keeps the missing-file hazard above from
  # ever firing. The value passes through a shell variable (unavoidable: Keychain
  # has no file interface) but is never echoed, and the subshell umask means the
  # file is never briefly world-readable.
  keychainMirror = { name, service, flag }: ''
    ${flag}=0
    if _kc_val="$(/usr/bin/security find-generic-password -s ${service} -w 2>/dev/null)" && [ -n "$_kc_val" ]; then
      mkdir -p ${darwinSecretsDir}
      chmod 700 ${darwinSecretsDir}
      ( umask 077; printf '%s' "$_kc_val" > ${darwinSecretsDir}/${name} )
      ${flag}=1
    else
      rm -f ${darwinSecretsDir}/${name}
    fi
    unset _kc_val
  '';

  # NixOS only: set shell variable `flag` to 1 when the sops secret is readable.
  # Deliberately does NOT read the value — the whole point is that the plaintext
  # never enters the activation script's memory, let alone the config.
  sopsPresent = { name, flag }: ''
    ${flag}=0
    [ -r /run/secrets/${name} ] && ${flag}=1
  '';

  # Every sops secret an inject* block can reference from opencode.json.
  # Used by the leak guard below to know WHAT to check for.
  #
  # This list must be explicit and cannot be replaced by globbing /run/secrets/*:
  # sops-nix points /run/secrets at /run/secrets.d/<gen>, which is mode
  # `drwxr-x--x root:keys` — `dev` may TRAVERSE it (so `cat /run/secrets/foo`
  # works) but may NOT LIST it. A glob therefore silently expands to nothing and
  # any loop over it becomes a no-op that reports success. (Learned the hard way:
  # the first version of the guard globbed, "passed" on a deliberately poisoned
  # config, and was verified only because the positive control failed to fire.)
  mcpSopsSecretNames = [
    "dd_pat"
    "slack_mcp_xoxp_token"
    "pagerduty_user_api_key"
    "rollbar_access_token"
    "devcycle_client_id"
    "devcycle_client_secret"
    "devcycle_project_key"
  ];

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
  # - devbox defaults to the Anthropic subscription path, so sessions
  #   do not depend on the OpenAI API key.
  # - cloudbox defaults to Vertex Opus 5 (interactive primary model), while
  #   keeping compaction + the plan-execution subagents on cheap Gemini Flash.
  # - macOS defaults to Vertex Gemini 3.6 Flash on high thinking.
  # - macOS + cloudbox get Atlassian MCP wiring.
  # OpenAI GPT-5.5 remains in opencode.base.json as a runtime fallback; its
  # provider options stay there because OpenCode defaults GPT-5.x to medium
  # reasoning unless a variant or model option overrides it.
  opencodeOverlay =
    # caveman (pkgs/caveman), all hosts. opencode's local-plugin auto-discovery
    # globs `{plugin,plugins}/*.{ts,js}` — ONE level deep, files only. caveman
    # must ship as a DIRECTORY (plugin.js needs caveman-config.cjs as a real
    # sibling), so auto-discovery can never see it and an explicit entry is
    # required. A relative path here resolves against the config file's
    # directory (not $PWD) and is NOT sent to npm — verified against 1.17.13,
    # which reports it back as
    # file:///home/dev/.config/opencode/plugins/caveman/plugin.js. Because the
    # directory cannot match the auto-discovery glob, there is exactly one load
    # and no duplicate. `recursiveUpdate` REPLACES lists, hence base ++ append.
    #
    # NOTE: there is deliberately NO `instructions` entry for caveman's
    # ruleset. `instructions` is global and reaches every agent INCLUDING
    # compaction/summary, and opencode offers no per-agent scoping for it.
    # The ruleset is instead pushed through the plugin's own
    # experimental.chat.system.transform hook, which pkgs/caveman patches to
    # skip compaction. See pkgs/caveman/compaction-exemption.js.
    {
      plugin = (opencodeBase.plugin or []) ++ [ "./plugins/caveman/plugin.js" ];
    }
    // (lib.optionalAttrs isDevbox {
      model = devboxModel;
      # Route the built-in `compaction` agent to Sonnet 5 on devbox.
      # Without this, compaction inherits opencode.base.json's top-level default
      # (openai/gpt-5.5), which is billed per-token AND hits OpenAI usage caps —
      # leaving sessions stuck retrying "usage limit reached" forever (the
      # cloudbox/darwin branch routes compaction to cheap Gemini Flash instead).
      # On devbox Sonnet 5 runs via the Claude Max subscription
      # (teamclaude), so there is no per-token cost; Vertex Gemini Flash isn't
      # available here anyway. Sonnet (vs. the interactive Opus default) is
      # plenty for one-shot summarization.
      agent.compaction.model = sonnetModel;
      # Hide the Vertex providers on devbox: they are compiled into the shared
      # opencode.base.json for every host, but devbox has NEITHER ADC
      # (~/.config/gcloud/application_default_credentials.json is absent) NOR the
      # Vertex gateway baseURL (injectAigatewayBaseUrl / claude-failover-proxy are
      # isCloudbox-only), so any turn on google-vertex-anthropic/* or
      # google-vertex/* falls through to the stock @ai-sdk/google-vertex ADC path
      # and dies on the first turn with "Could not load the default credentials".
      # The picker listed the Vertex "Claude Opus 5" (and "Gemini 3.6 Flash")
      # entries right next to the working first-party anthropic/google ones; a
      # mis-pick persisted into ~/.local/state/opencode/model.json poisoned every
      # subsequently-opened session (3 crashes 2026-06..07). Disabling removes the
      # providers from the registry/picker entirely (recursiveUpdate treats the
      # list as a leaf and REPLACES it — base.json has no disabled_providers, and
      # the cloudbox branch below is a separate host, so there is no union/collision).
      disabled_providers = [ "google-vertex" "google-vertex-anthropic" ];
      # vision-qa (deployed below on devbox only) uses the direct
      # Google Generative AI API here (google/gemini-3.6-flash,
      # GOOGLE_GENERATIVE_AI_API_KEY / GEMINI_API_KEY auth — no Vertex).
      # Inject the same cost/limit catalog entry used for the Vertex flavor
      # below so cost tracking (oc-cost/aigateway) stays accurate.
      provider = {
        google = (opencodeBase.provider.google or {}) // {
          models = ((opencodeBase.provider.google or {}).models or {}) // {
            "gemini-3.6-flash" = gemini36FlashModel;
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
      #   - cloudbox -> Vertex Opus 5 (interactive primary model). The plan-
      #     execution subagents + compaction stay on cheap Gemini Flash below.
      #   - macOS    -> Gemini 3.6 Flash with high thinking (unchanged).
      model = if isCloudbox then vertexOpusModel else geminiModel;
      agent = {
        # Route the built-in `compaction` agent to Gemini 3.6 Flash. This is the
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
        # Cloudbox defaults to Opus, which uses opencode.base.json's shared
        # build/plan `variant: medium`, so it gets no Gemini-style override.
        build.variant = geminiVariant;
        plan.variant = geminiVariant;
      };
      provider = (opencodeBase.provider or {}) // {
        "google-vertex" = (opencodeBase.provider."google-vertex" or {}) // {
          models = ((opencodeBase.provider."google-vertex" or {}).models or {}) // {
            "gemini-3.6-flash" = gemini36FlashModel;
          };
        };
      } // lib.optionalAttrs isCloudbox {
        # codex-lb subscription models (cloudbox — same as the devbox branch).
        # recursiveUpdate against the base openai below restores its options +
        # gpt-5.5, so this shallow `//` doesn't drop them; the sol/terra/luna
        # tiers only route anywhere once codex-lb.service is active (opt-in).
        openai = lib.recursiveUpdate (opencodeBase.provider.openai or {}) {
          models = codexLbModels;
        };
      };
      mcp = (opencodeBase.mcp or {}) // {
        atlassian = {
          type = "local";
          command = [ "${atlassian-mcp}/bin/atlassian-mcp" ];
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

  # NOTE: the worktree-guard opencode plugin was removed 2026-07-25. It never
  # loaded on any process (see below), and its path heuristic flagged every
  # relative path as a hit, so it could only ever have produced noise. Commits
  # at a primary root are still blocked by the git pre-commit hook installed by
  # `installMonoWorktreeGuardHook` in home.base.nix — that layer works and stays.
  # What is no longer enforced is blocking *edits* (as opposed to commits) at a
  # primary root; that is convention-only now.

   # Custom agents via OpenCode-native markdown format.
   # OpenCode loads agents from ~/.config/opencode/agents/ with tools as a YAML map.
   xdg.configFile."opencode/agents/librarian.md".source = patchAgent "librarian" "${assetsPath}/opencode/agents/librarian.md";
   # Distinctly-named model-pinned twins so the model is unambiguous at the call
   # site, all generated from each agent's `<base>-opus.md` source (single source
   # of truth for the prompt body, no drift):
   #   @<base>-opus   -> opus-5 (source of truth for the prompt)
   #   @<base>-fable  -> claude-fable-5 (mkFableVariant; cloudbox gets the Vertex
   #                     rewrite via patchAgent)
   #   @<base>-sol    -> openai/gpt-5.6-sol (mkSolVariant; deployed on all hosts —
   #                     reachable wherever codex-lb serves gpt-5.6-sol; patchAgent
   #                     is a no-op for this pin)
   # -fable and -sol carry an opt-in CAUTION in their description; -opus is the
   # default the orchestrator should reach for.
   xdg.configFile."opencode/agents/adversarial-reviewer-opus.md".source = patchAgent "adversarial-reviewer-opus" "${assetsPath}/opencode/agents/adversarial-reviewer-opus.md";
   xdg.configFile."opencode/agents/adversarial-reviewer-fable.md".source =
     patchAgent "adversarial-reviewer-fable" (mkFableVariant "adversarial-reviewer" "${assetsPath}/opencode/agents/adversarial-reviewer-opus.md");
   xdg.configFile."opencode/agents/adversarial-reviewer-sol.md".source =
     patchAgent "adversarial-reviewer-sol" (mkSolVariant "adversarial-reviewer" "${assetsPath}/opencode/agents/adversarial-reviewer-opus.md");
   xdg.configFile."opencode/agents/oracle-opus.md".source = patchAgent "oracle-opus" "${assetsPath}/opencode/agents/oracle-opus.md";
   xdg.configFile."opencode/agents/oracle-fable.md".source =
     patchAgent "oracle-fable" (mkFableVariant "oracle" "${assetsPath}/opencode/agents/oracle-opus.md");
   xdg.configFile."opencode/agents/oracle-sol.md".source =
     patchAgent "oracle-sol" (mkSolVariant "oracle" "${assetsPath}/opencode/agents/oracle-opus.md");
   xdg.configFile."opencode/agents/implementer.md".source = patchAgent "implementer" "${assetsPath}/opencode/agents/implementer.md";
   xdg.configFile."opencode/agents/spec-reviewer.md".source = patchAgent "spec-reviewer" "${assetsPath}/opencode/agents/spec-reviewer.md";
   xdg.configFile."opencode/agents/code-reviewer.md".source = patchAgent "code-reviewer" "${assetsPath}/opencode/agents/code-reviewer.md";
   # vision-qa is API-key-only by design (no Vertex): its base pin is
   # google/gemini-3.6-flash (Google Generative AI API, authed via
   # GOOGLE_GENERATIVE_AI_API_KEY / GEMINI_API_KEY from sops). Deploy it only
   # on the hosts where that auth path exists — devbox. macOS has
   # no Gemini API key (Vertex ADC only) and cloudbox deliberately disables
   # the direct `google` provider (disabled_providers above), so neither
   # gets the agent. Bare source, no patchAgent: the pin is already
   # host-correct where deployed and must NOT be rewritten to Vertex.
   xdg.configFile."opencode/agents/vision-qa.md" = lib.mkIf isDevbox {
     source = "${assetsPath}/opencode/agents/vision-qa.md";
   };

     # Plugins (SRP: shell env injection, compaction context, subagent routing)
      xdg.configFile."opencode/plugins/shell-env.ts".source = "${assetsPath}/opencode/plugins/shell-env.ts";
     xdg.configFile."opencode/plugins/compaction-context.ts".source = "${assetsPath}/opencode/plugins/compaction-context.ts";
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

    # session-state: the overlay writer behind the session switcher. Also a
    # Nix-built bundle, and here bundling is not a preference — the plugin is
    # session-state.ts + session-state-impl.ts, and two xdg.configFile entries
    # would put them in different store paths, so the sibling import would throw
    # at load and opencode would swallow it (empty log, plugin still listed by
    # `opencode debug info`). Shipping the impl file into the plugins directory
    # would ALSO log `Plugin export is not a function` every bootstrap, since
    # opencode loads every .ts/.js there as a plugin (a .js.map is ignored --
    # self-compact's has sat there for months). One file avoids both.
    #
    # Cloudbox-only, deliberately: this writes state for the serve pool, and the
    # pool (opencode-serve@{4096..4099}) exists only here. The plugin no-ops
    # elsewhere anyway — it stays inert unless OPENCODE_SERVE_ID is set AND
    # /proc/self/cmdline shows a real `serve` — but there is no reason to ship a
    # writer to hosts with nothing to write about.
    xdg.configFile."opencode/plugins/session-state.js" = lib.mkIf isCloudbox {
      source = "${localPkgs.session-state-plugin}/session-state.js";
    };
    xdg.configFile."opencode/plugins/session-state.js.map" = lib.mkIf isCloudbox {
      source = "${localPkgs.session-state-plugin}/session-state.js.map";
    };

    # caveman: symlink the whole DIRECTORY, never the individual files.
    # opencode resolves a plugin entry through realpathSync before importing
    # it, so plugin.js sees import.meta.url as its /nix/store path and looks
    # for caveman-config.cjs next to itself IN THE STORE. Per-file
    # xdg.configFile entries would put each file in a different store path and
    # the sibling lookup would throw at import — and opencode swallows that:
    # `opencode debug info` still lists the plugin and opencode.log stays
    # empty. pkgs/caveman's installCheckPhase asserts the three siblings; this
    # symlink is the other half of the contract. The only observable proof it
    # actually loaded is ~/.config/opencode/.caveman-active appearing after a
    # fresh session starts.
    # Deployed on all three hosts (cloudbox, devbox, macOS). Nothing here is
    # host-specific: the payload is pure prompt/skill/command text plus a
    # plugin that only touches ~/.config/opencode, so there is no MCP, secret,
    # or model dependency to gate on.
    xdg.configFile."opencode/plugins/caveman".source = "${localPkgs.caveman}/plugin";

    # caveman slash commands. caveman-stats is deliberately absent — see the
    # exclusion notes in pkgs/caveman/default.nix.
    xdg.configFile."opencode/commands/caveman.md".source =
      "${localPkgs.caveman}/commands/caveman.md";
    xdg.configFile."opencode/commands/caveman-commit.md".source =
      "${localPkgs.caveman}/commands/caveman-commit.md";
    xdg.configFile."opencode/commands/caveman-compress.md".source =
      "${localPkgs.caveman}/commands/caveman-compress.md";
    xdg.configFile."opencode/commands/caveman-help.md".source =
      "${localPkgs.caveman}/commands/caveman-help.md";
    xdg.configFile."opencode/commands/caveman-review.md".source =
      "${localPkgs.caveman}/commands/caveman-review.md";

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

    # Strip any `instructions` entry pointing at a caveman ruleset.
    #
    # This merge preserves runtime-only keys, which is normally what we want —
    # but it means a key we USED to manage lingers forever after we stop
    # managing it. An earlier iteration of the caveman wiring set
    # `instructions` to the packaged caveman-activate.md; that approach was
    # abandoned precisely because `instructions` is global and therefore also
    # reaches the compaction/summary agent, which must stay caveman-free. Any
    # machine that applied the earlier version still has the entry in its
    # runtime opencode.json, and without this it would survive every future
    # switch and silently re-introduce the exact leak the exemption exists to
    # prevent (see pkgs/caveman/compaction-exemption.js).
    #
    # Deliberately narrow: only caveman rule paths are dropped, so unrelated
    # user-added instructions are preserved. The key is removed entirely when
    # nothing else remains, to avoid leaving an empty array behind.
    cleaned="$(mktemp "''${runtime}.tmp.XXXXXX")"
    ${pkgs.jq}/bin/jq '
      if has("instructions") then
        .instructions |= map(select(test("caveman-activate\\.md$") | not))
        | if (.instructions | length) == 0 then del(.instructions) else . end
      else . end
    ' "$tmp" > "$cleaned"
    mv "$cleaned" "$tmp"

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

  # Regression guard: assert no sops plaintext ever lands in opencode.json.
  #
  # This is the backstop for the bug this whole {file:...} scheme exists to fix
  # (found 2026-08-01: live Datadog/Slack/PagerDuty/Rollbar tokens sitting in
  # cleartext in a 0600 file in $HOME, having been inlined by the very
  # activations above, and copied into every opencode.json.bak.* alongside).
  # The convention "emit secretRef, never the value" is easy to regress with one
  # careless `--arg tok "$(cat /run/secrets/...)"`, and the failure is SILENT —
  # everything keeps working, the credential is just exposed. So we check the
  # observable end state rather than trusting the convention.
  #
  # Method: substring-match every /run/secrets/* value against the finished
  # config. Comparing real values means ZERO false positives from
  # credential-shaped-but-harmless strings, unlike a token-prefix regex.
  # Only secrets >= 16 chars are considered, so short non-secret config values
  # (site names, project ids, numeric ids) cannot trip it by coincidence.
  #
  # Warn-only, deliberately: a hard failure here would block every future
  # home-manager switch on a machine that is already in the bad state, which is
  # exactly when you most need switch to work in order to FIX it. The message is
  # loud and names the offending secret (never its value).
  #
  # Runs after every inject* for this host — hence the conditional dep list; the
  # blocks are mkIf'd per platform and naming an absent activation is a dag error.
  home.activation.assertOpencodeConfigHasNoSecrets = lib.mkIf (isDevbox || isCloudbox)
    (lib.hm.dag.entryAfter ([ "mergeOpencode" ]
      ++ lib.optionals isCloudbox [
        "injectDatadogMcpSecretsSops"
        "injectSlackMcpSecretsSops"
        "injectPagerDutyMcpSecretsSops"
        "injectRollbarMcpSecretsSops"
        "injectDevcycleMcpSecretsSops"
      ]) ''
      set -euo pipefail

      runtime="$HOME/.config/opencode/opencode.json"
      [[ -f "$runtime" ]] || exit 0
      [ -d /run/secrets ] || exit 0

      leaked=0
      checked=0
      for name in ${lib.concatStringsSep " " mcpSopsSecretNames}; do
        secret="/run/secrets/$name"
        [ -r "$secret" ] || continue
        # Strip the trailing newline the way {file:...} does before comparing.
        value="$(tr -d '\n' < "$secret")"
        # Skip short values: a <16-char secret could collide with ordinary
        # config text and produce a false positive.
        [ "''${#value}" -ge 16 ] || continue
        checked=$((checked + 1))
        if ${pkgs.gnugrep}/bin/grep -qF -- "$value" "$runtime" 2>/dev/null; then
          echo "opencode secrets guard: !! PLAINTEXT of sops secret '$name' found in $runtime" >&2
          leaked=1
        fi
      done
      unset value

      # A guard that checks nothing must not look like a guard that passed.
      if [ "$checked" -eq 0 ]; then
        echo "opencode secrets guard: WARNING — checked 0 secrets; guard is not actually verifying anything." >&2
      fi

      if [ "$leaked" = "1" ]; then
        {
          echo "opencode secrets guard: the config must reference secrets, not contain them."
          echo "opencode secrets guard: use \`secretRef \"<name>\"\` in users/dev/opencode-config.nix"
          echo "opencode secrets guard: (emits {file:/run/secrets/<name>}, which opencode expands at config load)."
          echo "opencode secrets guard: after fixing, ROTATE the named credential — it has been on disk in cleartext."
        } >&2
      fi
    '');

  # Inject Basecamp MCP secrets from macOS Keychain into opencode.json
  # Runs after mergeOpencode to ensure runtime file exists
  # Uses basic auth (username/password) instead of OAuth for simpler setup
  home.activation.injectBasecampMcpSecrets = lib.mkIf isDarwin
    (lib.hm.dag.entryAfter [ "mergeOpencode" ] ''
      set -euo pipefail

      runtime="$HOME/.config/opencode/opencode.json"

      # Mirror credentials from Keychain to the 0600 files {file:...} will read.
      # NOTE: the username is ALSO used verbatim in the USER_AGENT string below,
      # so it is additionally kept in a shell variable. It is an identifier, not
      # a secret; the password and account id never enter the config.
      bc_username="$(/usr/bin/security find-generic-password -a basecamp-mcp -s basecamp-mcp-username -w 2>/dev/null || true)"
      ${keychainMirror { name = "basecamp_mcp_username"; service = "basecamp-mcp-username"; flag = "have_bc_user"; }}
      ${keychainMirror { name = "basecamp_mcp_password"; service = "basecamp-mcp-password"; flag = "have_bc_pass"; }}
      ${keychainMirror { name = "basecamp_account_id"; service = "basecamp-account-id"; flag = "have_bc_acct"; }}

      # If any credential is missing, delete mcp.basecamp and exit cleanly
      if [[ "$have_bc_user" -eq 0 || "$have_bc_pass" -eq 0 || "$have_bc_acct" -eq 0 ]]; then
        if [[ -f "$runtime" ]]; then
          tmp="$(mktemp "''${runtime}.tmp.XXXXXX")"
          ${pkgs.jq}/bin/jq 'del(.mcp.basecamp)' "$runtime" > "$tmp"
          mv "$tmp" "$runtime"
        fi
        echo "Basecamp MCP credentials not found in Keychain; removed mcp.basecamp from config" >&2
      # Both credentials present: inject full Basecamp MCP config
      # Disabled by default; enable manually when needed
      # NOTE: elif (not a separate `if` after `exit 0`) — an `exit` here would
      # abort the whole concatenated home-manager activation, silently skipping
      # every later activation (setupLaunchAgents, other injects). See git log.
      elif [[ -f "$runtime" ]]; then
        tmp="$(mktemp "''${runtime}.tmp.XXXXXX")"

        ${pkgs.jq}/bin/jq \
          --arg user "${secretRef "basecamp_mcp_username"}" \
          --arg pass "${secretRef "basecamp_mcp_password"}" \
          --arg home "$HOME" \
          --arg ua_user "''${bc_username}" \
          --arg account_id "${secretRef "basecamp_account_id"}" \
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
              "USER_AGENT": ("Basecamp MCP Server (" + $ua_user + ")")
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

      # Mirror the Keychain item to the 0600 file that {file:...} will read.
      ${keychainMirror { name = "slack_mcp_xoxp_token"; service = "slack-mcp-xoxp-token"; flag = "have_xoxp"; }}

      # If token is missing, delete mcp.slack + mcp.slack-ro and exit cleanly
      if [[ "$have_xoxp" -eq 0 ]]; then
        if [[ -f "$runtime" ]]; then
          tmp="$(mktemp "''${runtime}.tmp.XXXXXX")"
          # Both variants, not just .mcp.slack. They share one token, so a
          # stale slack-ro would keep a reference to a mirror we just deleted —
          # which now fails the WHOLE config load, not just that server.
          ${pkgs.jq}/bin/jq 'del(.mcp.slack) | del(.mcp."slack-ro")' "$runtime" > "$tmp"
          mv "$tmp" "$runtime"
        fi
        echo "Slack MCP xoxp token not found in Keychain; removed mcp.slack + mcp.slack-ro from config" >&2
      # Token present: inject Slack MCP config with xoxp auth
      # MCP is disabled by default; enable manually or use dedicated slack agent when needed.
      # Two variants: `slack` (read + write, SLACK_MCP_ADD_MESSAGE_TOOL=true) and
      # `slack-ro` (read-only; omits SLACK_MCP_ADD_MESSAGE_TOOL so the korotovsky
      # server registers read tools only). slack-ro is used by lgtm's read-only
      # gather session (`opencode-launch --mcp slack-ro`) so it structurally cannot post.
      # elif (not `exit 0` + separate if): an exit aborts the whole HM activation.
      elif [[ -f "$runtime" ]]; then
        tmp="$(mktemp "''${runtime}.tmp.XXXXXX")"

        ${pkgs.jq}/bin/jq \
          --arg xoxp "${secretRef "slack_mcp_xoxp_token"}" \
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

      # Presence-check the sops secret; the value is never read (see secretRef).
      ${sopsPresent { name = "slack_mcp_xoxp_token"; flag = "have_xoxp"; }}

      # If token is missing, delete both slack variants and exit cleanly
      if [[ "$have_xoxp" -eq 0 ]]; then
        if [[ -f "$runtime" ]]; then
          tmp="$(mktemp "''${runtime}.tmp.XXXXXX")"
          ${pkgs.jq}/bin/jq 'del(.mcp.slack) | del(.mcp."slack-ro")' "$runtime" > "$tmp"
          mv "$tmp" "$runtime"
        fi
        echo "Slack MCP xoxp token not found in sops; removed mcp.slack + mcp.slack-ro from config (secret absent -> reference would fail the whole config load)" >&2
      # Token present: inject Slack MCP config with xoxp auth.
      # Two variants: `slack` (read + write) and `slack-ro` (read-only; omits
      # SLACK_MCP_ADD_MESSAGE_TOOL so only read tools register). slack-ro is used
      # by lgtm's read-only gather session so it structurally cannot post.
      # elif (not `exit 0` + separate if): an exit aborts the whole HM activation.
      elif [[ -f "$runtime" ]]; then
        tmp="$(mktemp "''${runtime}.tmp.XXXXXX")"

        ${pkgs.jq}/bin/jq \
          --arg xoxp "${secretRef "slack_mcp_xoxp_token"}" \
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

      ${keychainMirror { name = "pagerduty_user_api_key"; service = "pagerduty-user-api-key"; flag = "have_pd"; }}

      if [[ "$have_pd" -eq 0 ]]; then
        if [[ -f "$runtime" ]]; then
          tmp="$(mktemp "''${runtime}.tmp.XXXXXX")"
          ${pkgs.jq}/bin/jq 'del(.mcp.pagerduty)' "$runtime" > "$tmp"
          mv "$tmp" "$runtime"
        fi
        echo "PagerDuty API token not found in Keychain; removed mcp.pagerduty from config" >&2
      # elif (not `exit 0` + separate if): an exit aborts the whole HM activation.
      elif [[ -f "$runtime" ]]; then
        tmp="$(mktemp "''${runtime}.tmp.XXXXXX")"

        ${pkgs.jq}/bin/jq \
          --arg command "${pagerduty-mcp}/bin/pagerduty-mcp" \
          --arg api_key "${secretRef "pagerduty_user_api_key"}" \
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

      ${sopsPresent { name = "pagerduty_user_api_key"; flag = "have_pd"; }}

      if [[ "$have_pd" -eq 0 ]]; then
        if [[ -f "$runtime" ]]; then
          tmp="$(mktemp "''${runtime}.tmp.XXXXXX")"
          ${pkgs.jq}/bin/jq 'del(.mcp.pagerduty)' "$runtime" > "$tmp"
          mv "$tmp" "$runtime"
        fi
        echo "PagerDuty API token not found in sops; removed mcp.pagerduty from config" >&2
      # elif (not `exit 0` + separate if): an exit aborts the whole HM activation.
      elif [[ -f "$runtime" ]]; then
        tmp="$(mktemp "''${runtime}.tmp.XXXXXX")"

        ${pkgs.jq}/bin/jq \
          --arg command "${pagerduty-mcp}/bin/pagerduty-mcp" \
          --arg api_key "${secretRef "pagerduty_user_api_key"}" \
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

      ${keychainMirror { name = "rollbar_access_token"; service = "rollbar-access-token"; flag = "have_rollbar"; }}

      if [[ "$have_rollbar" -eq 0 ]]; then
        if [[ -f "$runtime" ]]; then
          tmp="$(mktemp "''${runtime}.tmp.XXXXXX")"
          ${pkgs.jq}/bin/jq 'del(.mcp.rollbar)' "$runtime" > "$tmp"
          mv "$tmp" "$runtime"
        fi
        echo "Rollbar access token not found in Keychain; removed mcp.rollbar from config" >&2
      # elif (not `exit 0` + separate if): an exit aborts the whole HM activation.
      elif [[ -f "$runtime" ]]; then
        tmp="$(mktemp "''${runtime}.tmp.XXXXXX")"

        ${pkgs.jq}/bin/jq \
          --arg command "${rollbar-mcp}/bin/rollbar-mcp" \
          --arg token "${secretRef "rollbar_access_token"}" \
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

      ${sopsPresent { name = "rollbar_access_token"; flag = "have_rollbar"; }}

      if [[ "$have_rollbar" -eq 0 ]]; then
        if [[ -f "$runtime" ]]; then
          tmp="$(mktemp "''${runtime}.tmp.XXXXXX")"
          ${pkgs.jq}/bin/jq 'del(.mcp.rollbar)' "$runtime" > "$tmp"
          mv "$tmp" "$runtime"
        fi
        echo "Rollbar access token not found in sops; removed mcp.rollbar from config" >&2
      # elif (not `exit 0` + separate if): an exit aborts the whole HM activation.
      elif [[ -f "$runtime" ]]; then
        tmp="$(mktemp "''${runtime}.tmp.XXXXXX")"

        ${pkgs.jq}/bin/jq \
          --arg command "${rollbar-mcp}/bin/rollbar-mcp" \
          --arg token "${secretRef "rollbar_access_token"}" \
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

  # Inject the DevCycle MCP entry on macOS.
  # Uses DevCycle's local stdio server (dvc-mcp from @devcycle/cli); the hosted
  # remote endpoint is unusable (no dynamic client registration — see the
  # devcycle-mcp wrapper above). Two auth modes, either of which surfaces the
  # entry:
  #   1. Client credentials in Keychain (devcycle-client-id/-secret[/-project-key])
  #      -> injected into the `environment` block (durable, reproducible path).
  #   2. Interactive SSO: `~/.config/devcycle/auth.yml` present (from a
  #      `dvc login sso` + `dvc projects select`) -> entry emitted with NO
  #      `environment`; dvc-mcp reads auth.yml + user.yml (project) off disk.
  # Client creds win when both are present. If neither exists, the entry is
  # stripped. Disabled by default; enabling loads write tools (create/update/
  # delete feature|variable), so enable only when you intend to change flags.
  home.activation.injectDevcycleMcpSecrets = lib.mkIf isDarwin
    (lib.hm.dag.entryAfter [ "mergeOpencode" ] ''
      set -euo pipefail

      runtime="$HOME/.config/opencode/opencode.json"

      ${keychainMirror { name = "devcycle_client_id"; service = "devcycle-client-id"; flag = "have_id"; }}
      ${keychainMirror { name = "devcycle_client_secret"; service = "devcycle-client-secret"; flag = "have_secret"; }}
      ${keychainMirror { name = "devcycle_project_key"; service = "devcycle-project-key"; flag = "have_pk"; }}

      have_creds=0
      [[ "$have_id" -eq 1 && "$have_secret" -eq 1 ]] && have_creds=1
      have_sso=0
      [[ -f "$HOME/.config/devcycle/auth.yml" ]] && have_sso=1

      if [[ "$have_creds" -eq 0 && "$have_sso" -eq 0 ]]; then
        if [[ -f "$runtime" ]]; then
          tmp="$(mktemp "''${runtime}.tmp.XXXXXX")"
          ${pkgs.jq}/bin/jq 'del(.mcp.devcycle)' "$runtime" > "$tmp"
          mv "$tmp" "$runtime"
        fi
        echo "DevCycle: no client id/secret (Keychain) and no SSO auth.yml; removed mcp.devcycle from config" >&2
      fi
      # NOTE: no 'exit' after the removal above — an exit aborts the whole
      # concatenated HM activation. Gate the inject on creds/SSO instead.

      env_json="{}"
      if [[ "$have_creds" -eq 1 ]]; then
        # $pk is gated on have_pk, not on emptiness: the reference string is
        # never empty, so presence of the underlying secret is the only valid
        # test — and emitting a reference to an absent project key would fail
        # the entire config load.
        env_json="$(${pkgs.jq}/bin/jq -n \
          --arg id "${secretRef "devcycle_client_id"}" \
          --arg secret "${secretRef "devcycle_client_secret"}" \
          --arg pk "${secretRef "devcycle_project_key"}" \
          --argjson have_pk "$have_pk" \
          '{DEVCYCLE_CLIENT_ID: $id, DEVCYCLE_CLIENT_SECRET: $secret}
           + (if $have_pk == 1 then {DEVCYCLE_PROJECT_KEY: $pk} else {} end)')"
      fi

      if [[ ( "$have_creds" -eq 1 || "$have_sso" -eq 1 ) && -f "$runtime" ]]; then
        tmp="$(mktemp "''${runtime}.tmp.XXXXXX")"
        ${pkgs.jq}/bin/jq \
          --arg command "${devcycle-mcp}/bin/devcycle-mcp" \
          --argjson env "$env_json" \
          '.mcp.devcycle = ({
            "type": "local",
            "command": [$command],
            "enabled": false
          } + (if ($env | length) > 0 then {environment: $env} else {} end))' "$runtime" > "$tmp"
        mv "$tmp" "$runtime"
      fi
    '');

  # Inject the DevCycle MCP entry on cloudbox.
  # Same two-mode logic as the Darwin block above, but client creds come from
  # sops (/run/secrets/devcycle_*) instead of Keychain. SSO mode is identical:
  # `~/.config/devcycle/auth.yml` present -> entry emitted with no `environment`.
  home.activation.injectDevcycleMcpSecretsSops = lib.mkIf isCloudbox
    (lib.hm.dag.entryAfter [ "mergeOpencode" ] ''
      set -euo pipefail

      runtime="$HOME/.config/opencode/opencode.json"

      ${sopsPresent { name = "devcycle_client_id"; flag = "have_id"; }}
      ${sopsPresent { name = "devcycle_client_secret"; flag = "have_secret"; }}
      ${sopsPresent { name = "devcycle_project_key"; flag = "have_pk"; }}

      have_creds=0
      [[ "$have_id" -eq 1 && "$have_secret" -eq 1 ]] && have_creds=1
      have_sso=0
      [[ -f "$HOME/.config/devcycle/auth.yml" ]] && have_sso=1

      if [[ "$have_creds" -eq 0 && "$have_sso" -eq 0 ]]; then
        if [[ -f "$runtime" ]]; then
          tmp="$(mktemp "''${runtime}.tmp.XXXXXX")"
          ${pkgs.jq}/bin/jq 'del(.mcp.devcycle)' "$runtime" > "$tmp"
          mv "$tmp" "$runtime"
        fi
        echo "DevCycle: no client id/secret (sops) and no SSO auth.yml; removed mcp.devcycle from config" >&2
      fi
      # NOTE: no 'exit' after the removal above — an exit aborts the whole
      # concatenated HM activation. Gate the inject on creds/SSO instead.

      env_json="{}"
      if [[ "$have_creds" -eq 1 ]]; then
        # $pk is gated on have_pk, not on emptiness: the reference string is
        # never empty, so presence of the underlying secret is the only valid
        # test — and emitting a reference to an absent project key would fail
        # the entire config load.
        env_json="$(${pkgs.jq}/bin/jq -n \
          --arg id "${secretRef "devcycle_client_id"}" \
          --arg secret "${secretRef "devcycle_client_secret"}" \
          --arg pk "${secretRef "devcycle_project_key"}" \
          --argjson have_pk "$have_pk" \
          '{DEVCYCLE_CLIENT_ID: $id, DEVCYCLE_CLIENT_SECRET: $secret}
           + (if $have_pk == 1 then {DEVCYCLE_PROJECT_KEY: $pk} else {} end)')"
      fi

      if [[ ( "$have_creds" -eq 1 || "$have_sso" -eq 1 ) && -f "$runtime" ]]; then
        tmp="$(mktemp "''${runtime}.tmp.XXXXXX")"
        ${pkgs.jq}/bin/jq \
          --arg command "${devcycle-mcp}/bin/devcycle-mcp" \
          --argjson env "$env_json" \
          '.mcp.devcycle = ({
            "type": "local",
            "command": [$command],
            "enabled": false
          } + (if ($env | length) > 0 then {environment: $env} else {} end))' "$runtime" > "$tmp"
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
  # NOTE: Gemini (`google-vertex/gemini-3.6-flash`) is the GLOBAL DEFAULT
  # model on cloudbox, so routing it through the gateway means every
  # session (interactive + opencode-serve/pigeon/Telegram) depends on the
  # gateway being up. The gateway parses Gemini `usageMetadata` and prices
  # `gemini-3.6-flash`; unpriced Gemini models still ledger tokens (NULL
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

  # Darwin flavor of injectTeamclaudeBaseUrl. Port-probe detection; dummy-cred
  # seed identical to the systemd path; no auto serve-restart (pool) — the dummy
  # cred's shape-only mode is decided at provider init, so a manual
  # `opencode-serve-pool-restart` is required to take effect.
  home.activation.injectTeamclaudeBaseUrlDarwin = lib.mkIf isDarwin
    (lib.hm.dag.entryAfter [ "mergeOpencode" ] ''
      set -euo pipefail
      runtime="$HOME/.config/opencode/opencode.json"

      anthropic_url=""
      if /usr/bin/nc -z -G2 127.0.0.1 3456 2>/dev/null; then
        anthropic_url="http://127.0.0.1:3456/v1"
      fi

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
          mv "$atmp" "$auth"; chmod 600 "$auth"
          echo "teamclaude(darwin): seeded non-expiring dummy anthropic oauth credential (plugin shape-only)" >&2
        fi
      fi

      echo "teamclaude(darwin): anthropic -> ''${anthropic_url:-<direct Anthropic>}" >&2
      [[ -n "$anthropic_url" ]] && echo "teamclaude(darwin): run 'opencode-serve-pool-restart' to apply to running serves" >&2 || true
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
  home.activation.injectCodexLbBaseUrl = lib.mkIf (isDevbox || isCloudbox)
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
        echo "codex-lb: config written — restart your opencode serve(s) to apply (devbox: systemctl --user restart 'opencode-serve@*.service')" >&2
      fi
    '');

  # Darwin flavor of injectCodexLbBaseUrl. No systemctl on macOS, so detect
  # "codex-lb is up" with a loopback port probe. No auto serve-restart: the Mac
  # runs an opencode-serve POOL, so we write config + clear the auth entry and
  # print the apply command; run `opencode-serve-pool-restart` to pick it up.
  home.activation.injectCodexLbBaseUrlDarwin = lib.mkIf isDarwin
    (lib.hm.dag.entryAfter [ "mergeOpencode" ] ''
      set -euo pipefail
      runtime="$HOME/.config/opencode/opencode.json"

      openai_url=""
      openai_key=""
      if /usr/bin/nc -z -G2 127.0.0.1 2455 2>/dev/null; then
        openai_url="http://127.0.0.1:2455/v1"
        openai_key="sk-codex-lb-local"
      fi

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

      if [[ -n "$openai_url" ]]; then
        auth="$HOME/.local/share/opencode/auth.json"
        if [[ -f "$auth" ]] && ${pkgs.jq}/bin/jq -e '.openai' "$auth" >/dev/null 2>&1; then
          atmp="$(mktemp "''${auth}.tmp.XXXXXX")"
          ${pkgs.jq}/bin/jq 'del(.openai)' "$auth" > "$atmp"
          mv "$atmp" "$auth"; chmod 600 "$auth"
          echo "codex-lb(darwin): removed .openai from auth store (force apiKey mode)" >&2
        fi
      fi

      echo "codex-lb(darwin): openai -> ''${openai_url:-<direct OpenAI>}" >&2
      [[ -n "$openai_url" ]] && echo "codex-lb(darwin): run 'opencode-serve-pool-restart' to apply to running serves" >&2 || true
    '');

  # Inject Datadog MCP config (remote HTTP transport) into opencode.json
  # Authenticates with a Datadog Personal Access Token (dd_pat/dd-pat) sent as an
  # HTTP Bearer token ("Authorization: Bearer <pat>"). NOTE: do NOT use a
  # "DD_APPLICATION_KEY" header — Datadog's edge drops HTTP header names
  # containing underscores, so the PAT never reaches auth and every request 401s
  # ("server unavailable" in opencode). Bearer (or the dashed "DD-APPLICATION-KEY")
  # is required; Bearer matches how dd-cli authenticates the same PAT.
  # Endpoint host is mcp.<DD_SITE>; site is us3 for our org.
  # Disabled by default — enable manually or via dedicated agent when needed.
  #
  # NOTE: We previously used the local datadog_mcp_cli stdio proxy, but Datadog
  # broke its hardcoded api.us3.datadoghq.com/api/unstable/mcp-server/mcp path
  # (returns 404) and hasn't shipped a fixed binary. Remote HTTP is now the
  # recommended path per docs.datadoghq.com/mcp_server/setup/. The endpoint has
  # since graduated from the .../api/unstable/mcp-server/mcp path to the stable
  # mcp.<DD_SITE>/v1/mcp path; ?toolsets=all surfaces all generally-available
  # toolsets (opencode supports tool filtering).
  home.activation.injectDatadogMcpSecrets = lib.mkIf isDarwin
    (lib.hm.dag.entryAfter [ "mergeOpencode" ] ''
      set -euo pipefail

      runtime="$HOME/.config/opencode/opencode.json"

      ${keychainMirror { name = "dd_pat"; service = "dd-pat"; flag = "have_pat"; }}

      if [[ "$have_pat" -eq 0 ]]; then
        if [[ -f "$runtime" ]]; then
          tmp="$(mktemp "''${runtime}.tmp.XXXXXX")"
          ${pkgs.jq}/bin/jq 'del(.mcp.datadog)' "$runtime" > "$tmp"
          mv "$tmp" "$runtime"
        fi
        echo "Datadog PAT not found in Keychain (dd-pat); removed mcp.datadog from config" >&2
      # elif (not `exit 0` + separate if): an exit aborts the whole HM activation.
      elif [[ -f "$runtime" ]]; then
        tmp="$(mktemp "''${runtime}.tmp.XXXXXX")"

        ${pkgs.jq}/bin/jq \
          --arg url "https://mcp.us3.datadoghq.com/v1/mcp?toolsets=all" \
          --arg pat "${secretRef "dd_pat"}" \
          '.mcp.datadog = {
            "type": "remote",
            "url": $url,
            "enabled": false,
            "oauth": false,
            "headers": {
              "Authorization": ("Bearer " + $pat)
            }
          }' "$runtime" > "$tmp"

        mv "$tmp" "$runtime"
      fi
    '');

  home.activation.injectDatadogMcpSecretsSops = lib.mkIf isCloudbox
    (lib.hm.dag.entryAfter [ "mergeOpencode" ] ''
      set -euo pipefail

      runtime="$HOME/.config/opencode/opencode.json"

      ${sopsPresent { name = "dd_pat"; flag = "have_pat"; }}

      if [[ "$have_pat" -eq 0 ]]; then
        if [[ -f "$runtime" ]]; then
          tmp="$(mktemp "''${runtime}.tmp.XXXXXX")"
          ${pkgs.jq}/bin/jq 'del(.mcp.datadog)' "$runtime" > "$tmp"
          mv "$tmp" "$runtime"
        fi
        echo "Datadog PAT not found in sops (dd_pat); removed mcp.datadog from config" >&2
      # elif (not `exit 0` + separate if): an exit aborts the whole HM activation.
      elif [[ -f "$runtime" ]]; then
        tmp="$(mktemp "''${runtime}.tmp.XXXXXX")"

        ${pkgs.jq}/bin/jq \
          --arg url "https://mcp.us3.datadoghq.com/v1/mcp?toolsets=all" \
          --arg pat "${secretRef "dd_pat"}" \
          '.mcp.datadog = {
            "type": "remote",
            "url": $url,
            "enabled": false,
            "oauth": false,
            "headers": {
              "Authorization": ("Bearer " + $pat)
            }
          }' "$runtime" > "$tmp"

        mv "$tmp" "$runtime"
      fi
    '');
}
