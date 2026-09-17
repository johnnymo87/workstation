# OpenCode configuration management
# Manages opencode.json via home-manager
# with merge-on-activate pattern (runtime keys preserved, managed keys enforced)
{ config, lib, pkgs, localPkgs, assetsPath, isDevbox, isCloudbox, ... }:

let
  isDarwin = pkgs.stdenv.isDarwin;
  useGeminiForAgents = isDarwin || isCloudbox;
  # Persistent operator intent for the cloudbox aigateway. Shared with
  # hosts/cloudbox/configuration.nix (the unit's ConditionPathExists and the
  # canary) via a single-string file so the three readers cannot drift apart —
  # see that file's header. Only consulted under isCloudbox.
  aigatewayFlag = import ../../hosts/cloudbox/aigateway-flag.nix;
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
  geminiModel = "google-vertex/gemini-3.8-flash";
  geminiVariant = "high";
  gemini38FlashModel = {
    id = "gemini-3.8-flash";
    name = "Gemini 3.8 Flash";
    family = "gemini-flash";
    release_date = "2026-09-02";
    attachment = true;
    reasoning = true;
    temperature = true;
    tool_call = true;
    # Google's INTRODUCTORY rate, in force through 2026-12-31. From
    # 2027-01-01 the standard rate applies and these three numbers double
    # (1.50 / 7.50 / 0.15). Unlike the aigateway PriceTable and oc-cost's
    # rate book — both of which now select a rate phase by request date —
    # opencode.json is a static catalog, so this one must be edited by hand
    # when the discount lapses. It only feeds opencode's own cost display;
    # the gateway ledger stays authoritative either way.
    # Source: https://cloud.google.com/vertex-ai/generative-ai/pricing
    cost = {
      input = 0.75;
      output = 3.75;
      cache_read = 0.075;
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
  #   1. sonnet-5 -> Gemini 3.8 Flash on the Gemini-for-agents hosts (macOS +
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
   #      TeamClaude).
   #
   #      macOS JOINED THIS BRANCH when cfp landed there. It used to be exempt
   #      ("its primary is Gemini and opus agents are rare"), but the Mac now
   #      hides the `anthropic` provider entirely (disabled_providers below), so
   #      an agent left pinned to `anthropic/claude-opus-*` would reach a
   #      provider that is not in the registry — the same empty-response
   #      silent failure this rewrite exists to prevent. The Max pool is still
   #      reached, just through cfp behind google-vertex-anthropic rather than
   #      through a second, fallback-less lane. This
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
        if isCloudbox || isDarwin then
          pkgs.runCommand "${name}-opus-vertex.md" {} ''
            ${pkgs.perl}/bin/perl -0pe 's|model: anthropic/claude-opus-([0-9]+(?:-[0-9]+)*)|model: google-vertex-anthropic/claude-opus-''${1}\@default|' ${afterSonnet} > $out
          ''
        else
          afterSonnet;
      # 3. fable -> Vertex Anthropic on cloudbox and macOS, mirroring the opus
      #    rewrite above and for the same reason: neither host offers a usable
      #    first-party `anthropic/` provider (cloudbox has no such auth at all;
      #    macOS hides it via disabled_providers now that cfp fronts Claude), so an
      #    agent left pinned to `anthropic/claude-fable-5-1` reaches an unusable
      #    provider and the model loop dies with an empty response. The Vertex
      #    fable entry (`google-vertex-anthropic/claude-fable-5-1@default`)
      #    carries its own high `effort` from opencode.base.json, so no variant
      #    override is added here. No-op on agents that don't pin fable.
      #
      #    The version is CAPTURED, not hardcoded — a literal `claude-fable-5`
      #    match against the 5.1 pin yields `claude-fable-5@default-1`, a
      #    provider/model pair that does not exist and fails at request time.
      afterFable =
        if isCloudbox || isDarwin then
          pkgs.runCommand "${name}-fable-vertex.md" {} ''
            ${pkgs.perl}/bin/perl -0pe 's|model: anthropic/claude-fable-([0-9]+(?:-[0-9]+)*)|model: google-vertex-anthropic/claude-fable-''${1}\@default|' ${afterOpus} > $out
          ''
        else
          afterOpus;
    in
      afterFable;

  # mkAgentVariant: build a model-pinned twin of an agent from the SAME source
  # body at build time, so a shared prompt has one source of truth and no
  # hand-maintained copy to drift. Used for oracle and adversarial-reviewer,
  # whose sources pin `anthropic/claude-fable-5-1` and carry a
  # `(fable-5-1 model)` token in their description. It rewrites only:
  #   - the model pin (fable-5-1 -> modelPin)
  #   - the `(fable-5-1 model)` description token -> `(modelTag model)`
  #   - appends an opt-in CAUTION so the orchestrator does NOT auto-select the
  #     twin; the `-fable` handle stays the default.
  # The result is fed through patchAgent for host rewrites. For an `openai/`
  # pin every patchAgent branch is a no-op, which is correct — codex-lb serves
  # that pin identically on both hosts.
  #
  # HISTORY, because this was deleted and brought back. An equivalent builder
  # (with -opus/-fable/-sol twins) existed until 2026-09-01, when #444 cut the
  # set to fable-only and deleted the machinery rather than leave it unused —
  # the stated reason being that an unevaluated nix builder gets no build
  # coverage and rots silently, which is exactly how the literal
  # `claude-fable-5` bug survived in the LIVE rewrite path until #443. That
  # reasoning was sound and still is: this builder is only safe to keep because
  # it is EVALUATED below. If the astra twins are ever removed, delete this
  # again rather than leaving it dormant.
  #
  # #444 also predicted this moment and paid for it in advance: it kept the
  # `-fable` suffix on the deployed handles even when nothing needed
  # disambiguating, precisely so re-introducing a second model would be purely
  # additive. It is. No handle renames here.
  #
  # IMPORTANT: the appended text must NOT contain a colon-space (": "). opencode
  # parses agent frontmatter with gray-matter/js-yaml (packages/opencode/src/
  # config/markdown.ts), and a ": " inside an unquoted YAML scalar (the
  # `description:` value) makes the primary matter() parse THROW, forcing the
  # fragile fallbackSanitization double-parse path. That path is racy under the
  # concurrent agent-load in loadAgent(): it nondeterministically fails, and a
  # failed parse SKIPS the agent (config.ts:198-207), leaving a default stub
  # (mode=all, model=null) that silently runs the CALLER's model instead of the
  # pinned one — i.e. the failure is a silent wrong-model, not an error. The
  # em-dashes below are load-bearing for that reason.
  # EVERY SUBSTITUTION IS VERSION-AGNOSTIC AND DIES IF IT DOES NOT MATCH.
  # Both properties are load-bearing and were added after review caught the
  # first draft repeating #443's exact mistake. That draft matched the literal
  # `claude-fable-5-1`; bump the source to fable-5-2 and all three matches miss,
  # the build stays GREEN, and the emitted twin is an `-astra` handle still
  # pinned to fable — which on cloudbox patchAgent then happily rewrites to a
  # working Vertex model, so `@oracle-astra` runs and answers, on the wrong
  # model, forever. Silent wrong-model is the worst outcome this file can
  # produce, and a literal version match is how you get there.
  #
  # `or die` under `-p` gives a non-zero exit, which fails the runCommand and
  # therefore the whole home-manager build. Loud beats silent.
  #
  # The description guard also refuses a quoted or folded YAML scalar
  # (`description: "..."` / `>-`): appending to those produces either broken
  # YAML or text outside the scalar, and the failure mode of broken agent
  # frontmatter is the racy skip-to-stub described above.
  mkAgentVariant = { base, slug, modelPin, modelTag }: src:
    pkgs.runCommand "${base}-${slug}-src.md" {} ''
      # Delimiter is `!`, not `|`: the description guard's character class
      # contains a literal `|` (the YAML block-scalar marker it must reject),
      # and perl scans for the closing delimiter without regard for brackets,
      # so `s|...[^"'"'"'>|]...|` terminates early and dies with a syntax error.
      # Nothing substituted here contains `!`.
      ${pkgs.perl}/bin/perl -0pe '
        s!model: anthropic/claude-fable-[0-9]+(?:-[0-9]+)*!model: ${modelPin}!
          or die "mkAgentVariant: no anthropic/claude-fable-* pin found in ${base} source\n";
        s!\(fable-[0-9]+(?:-[0-9]+)* model\)!(${modelTag} model)!
          or die "mkAgentVariant: no (fable-N model) token found in ${base} description\n";
        s!^(description: [^"'"'"'>|].*)$!$1. CAUTION — use this ${modelTag} variant ONLY when the user explicitly asks for it; otherwise default to ${base}-fable!m
          or die "mkAgentVariant: ${base} has no plain unquoted description: scalar to append to\n";
      ' ${src} > $out

      # Enforce the colon-space rule at BUILD time, not by comment. A ": "
      # anywhere in the description VALUE makes opencode's gray-matter parse
      # throw and fall into a racy fallback that skips the agent entirely,
      # leaving a stub that silently runs the caller's model. The key's own
      # ": " is the one legal occurrence on that line.
      colons=$(${pkgs.gnugrep}/bin/grep -m1 '^description: ' $out | ${pkgs.gnugrep}/bin/grep -o ': ' | ${pkgs.coreutils}/bin/wc -l)
      if [ "$colons" != "1" ]; then
        echo "mkAgentVariant: ${base}-${slug} description contains $colons colon-space sequences, expected exactly 1 (the key)." >&2
        echo "A ': ' inside the description value breaks opencode frontmatter parsing and silently degrades the agent to the caller's model." >&2
        exit 1
      fi
    '';

  # The one twin model: gpt-6-astra, OpenAI's most capable, reached over the
  # ChatGPT subscription through codex-lb on 127.0.0.1:2455. Deployed on devbox
  # and cloudbox (both run codex-lb); patchAgent is a pass-through for the pin.
  #
  # Unlike the fable twins this one can be present-but-dead: the agent file is
  # built unconditionally, while the model behind it exists only while
  # codex-lb.service is up AND codex-lb's upstream catalog refresh is healthy
  # (see the codex-lb model-catalog note further down for why astra in
  # particular can vanish). A call to @oracle-astra with codex-lb down fails at
  # request time rather than at build time.
  mkAstraVariant = base: mkAgentVariant { inherit base; slug = "astra"; modelPin = "openai/gpt-6-astra"; modelTag = "gpt-6-astra"; };

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
  #
  # This used to shell out to `npx -y --package '@devcycle/cli@6.3.2' dvc-mcp`.
  # It now runs the `dvc-mcp` bin out of pkgs/dvc — the same derivation that
  # puts the `dvc` CLI on PATH — so the MCP server and the CLI cannot drift to
  # different @devcycle/cli versions, and there is no npx resolve on startup.
  # The version pin lives in pkgs/dvc/default.nix.
  devcycle-mcp = "${localPkgs.dvc}/bin/dvc-mcp";

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

  # The sole directory the Slack MCP server may read when file_upload is called
  # with `file_path` (SLACK_MCP_FILE_UPLOAD_PATHS). Staging area only — nothing
  # lives here except artifacts copied in to be sent. See the long rationale at
  # the injectSlackMcpSecrets activation before widening it.
  #
  # Under /tmp because opencode.base.json pre-approves only
  # `external_directory: {"/tmp/*": "allow"}`; a path elsewhere would make the
  # `cp` into it prompt for permission, which stalls headless sessions.
  # Same literal on both platforms: macOS resolves /tmp -> /private/tmp, and the
  # server EvalSymlinks both the root and the candidate file before comparing.
  slackUploadStagingDir = "/tmp/opencode/slack-uploads";

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

  # Pinned npm-resolved plugin versions. Add new entries here when adding more
  # plugins to opencode.base.json's `plugin` array that need version pinning.
  # Format: { "<package-name>" = "<exact-version>"; }
  #
  # WHY THIS LIVES AT MODULE SCOPE: it feeds TWO consumers that must agree, and
  # they silently disagreed for months when it only fed one.
  #
  #   1. `pluginSpecs` below, which rewrites opencode.base.json's `plugin`
  #      entries from "<pkg>" to "<pkg>@<version>". This is the part that
  #      actually pins anything.
  #   2. `installOpencodePlugins`, which purges any ~/.cache/opencode/packages/
  #      entry whose on-disk version disagrees with the pin.
  #
  # Before pluginSpecs existed, the runtime `plugin` array carried BARE package
  # names. opencode resolves a bare name as `latest`, caches it under the bare
  # name, and never re-resolves. So the pin governed nothing: activation purged
  # the cache on every single rebuild (pinned 0.6.0 vs cached latest), opencode
  # immediately re-downloaded `latest`, and the next rebuild purged it again.
  # The visible symptom was a per-rebuild churn line that looked like a
  # DOWNGRADE ("cached at 0.7.0, pinned at 0.6.0 -> purging"); the real bug was
  # that the pin had no delivery mechanism. Keep both consumers fed from this
  # one attrset, or the loop comes back.
  opencodePluginPins = {
    # REQUIRED for the devbox TeamClaude routing — this plugin shapes opencode's
    # requests into Claude-Code OAuth form (anthropic-beta, ?beta=true, "You are
    # Claude Code" system identity, mcp_ tool prefixes) which premium models
    # require; TeamClaude only swaps the token, it does NOT shape. Removing it
    # makes opus/sonnet 429 and TeamClaude retry-loop forever. See
    # injectTeamclaudeBaseUrl below for the full coexistence rationale.
    #
    # >= 1.8.2 is REQUIRED, not merely preferred. Anthropic gates model access
    # on the Claude Code version the client reports, SERVER-SIDE. Releases up
    # to 1.8.1 hardcode 2.1.87, which newer models reject:
    #
    #   400 invalid_request_error / error_code: claude_code_version_too_old
    #   "Claude Code 2.1.87 does not support this model; version 2.1.251 or
    #    newer is required."
    #
    # opencode surfaces that as an EMPTY assistant turn with no visible error,
    # so it presents as "the agent is down". It broke oracle-fable and
    # adversarial-reviewer-fable the moment #443/#444 repinned them to
    # claude-fable-5-1. 1.8.2 reports 2.1.258 and derives the user-agent from
    # the same constant (upstream PR #223).
    #
    # This will recur whenever Anthropic gates a newer model than the bundled
    # constant. Diagnose from the stored `error` on the assistant message in
    # opencode.db before suspecting agent config; the fix is a pin bump here.
    #
    # 1.8.4 verified to report CLAUDE_CODE_VERSION 2.1.258 (>= the floor below).
    "@ex-machina/opencode-anthropic-auth" = "1.8.4";
    "opencode-beads" = "0.8.0";
  };

  # Every pin must be an EXACT version, never a range or a dist-tag. A pin of
  # "^1.8.0" or "latest" would key the cache on that literal spec, resolve to
  # some concrete version, and then fail the `cached_ver != pinned_ver` check on
  # every single activation — reintroducing the purge/refetch churn this whole
  # change exists to kill, through a new door. Fail at eval instead.
  _assertExactPins = lib.mapAttrsToList
    (name: ver: lib.throwIf (builtins.match "[0-9]+\\.[0-9]+\\.[0-9]+" ver == null)
      ''opencodePluginPins."${name}" = "${ver}" is not an exact version. Pins must be exact (e.g. "1.8.4"); ranges and dist-tags break cache invalidation.''
      null)
    opencodePluginPins;

  # opencode.base.json's `plugin` array carries bare package names so the file
  # stays readable and version-free; the pins are applied here. A bare name that
  # has no pin is passed through untouched (e.g. a relative "./plugins/..." path
  # would never match a pin key anyway).
  # deepSeq, not seq: the list is already in weak head normal form, so `seq`
  # would never force the elements and the throwIf would never fire.
  pluginSpecs = lib.deepSeq _assertExactPins (map
    (p: if opencodePluginPins ? ${p} then "${p}@${opencodePluginPins.${p}}" else p)
    (opencodeBase.plugin or []));

  # codex-lb: ChatGPT/Codex-subscription models served by the local codex-lb
  # rotator (127.0.0.1:2455). These model IDs only exist for a ChatGPT
  # subscription account routed through codex-lb — NOT the direct OpenAI API —
  # and are only reachable while codex-lb is actually serving (see
  # injectCodexLbBaseUrl below, which points provider.openai.options.baseURL at
  # codex-lb and clears the openai auth entry). Note that the baseURL is written
  # whenever the host OPTS IN via the ~/.codex-lb/enabled marker, not whenever
  # the service happens to be up — so a stopped codex-lb makes these models fail
  # at request time rather than silently rerouting them. Injected on devbox AND
  # cloudbox; both run codex-lb.
  # Effort defaults track each tier's role: Astra = most capable (high), Sol =
  # frontier workhorse (high), Terra = balanced (medium), Luna = fast (low).
  #
  # THESE MODELS CARRY LIST PRICE, NOT BILLED PRICE. This block used to zero
  # `cost` on the argument that subscription usage has no per-token billing.
  # That argument is about BILLING, and opencode's `cost` field is not a billing
  # figure — it is what oc-tags charts as "per-tag LLM list-price consumption".
  # Claude Opus 5 settles the question by precedent: it is also served by a
  # subscription (claude-failover-proxy sends it to Max first), yet it records
  # full list price. It IS declared (opencode.base.json:39) — but with `options`
  # only and no `cost`, so it inherits models.dev. The zero here was therefore
  # not a default we were stuck with; it was an explicit override of a catalog
  # that already had the right number. Zeroing made two identical situations
  # chart differently, and 6.3M tokens of real Astra work appeared as $0.00 —
  # visible only as an "Unpriced: gpt-6-astra" footer note, i.e. loud but not
  # counted. codex-lb's own dashboard remains the source of truth for ACTUAL
  # spend; nothing here claims a subscription bills per token.
  #
  # Prices are models.dev's base tier, which is the SAME catalog opencode itself
  # falls back to (cached at ~/.cache/opencode/models.json) — so they are quoted,
  # not invented. Reconcile with:
  #
  #   curl -s https://models.dev/api.json \
  #     | jq '.openai.models["gpt-6-astra"].cost'
  #
  # Base tier only, for two independent reasons: opencode's user-config merge
  # reads exactly input/output/cache_read/cache_write and DROPS
  # cost.tiers/context_over_200k, and the higher tier applies only when the raw
  # input total STRICTLY exceeds 272000 — which is exactly `limit.context`
  # below, and exactly what codex-lb serves, so it is unreachable anyway. The
  # `openai/gpt-5.5` entry in opencode.base.json follows the same convention.
  #
  # `cache_write` is quoted for completeness and is inert: OpenAI does not bill
  # cache writes and the Responses usage block never reports them, so every
  # openai row in opencode.db has cache.write = 0. It is models.dev carrying an
  # Anthropic-shaped field, not a cost we expect to pay. Do not "fix" it away —
  # inheriting from models.dev would supply the same number.
  #
  # WHY LITERALS AND NOT SIMPLY DELETING `cost`. Deleting it WOULD inherit
  # models.dev — a declared model resolves each absent cost field against the
  # upstream entry (`P?.cost?.input ?? _?.cost?.input ?? 0`), and a custom
  # baseURL does not change that. Verified against 1.18.18 end-to-end: with the
  # attribute removed, a real `opencode run -m openai/gpt-6-astra` recorded
  # $1.12658 on 112,633 input / 5 output, i.e. exactly the upstream 10/50.
  #
  # Deleting it here would nonetheless be a NO-OP on every host already
  # deployed. mergeOpencode below merges `runtime * managed` and deliberately
  # PRESERVES runtime-only keys, so a key the managed config stops mentioning
  # survives in ~/.config/opencode/opencode.json forever — the same trap the
  # caveman `instructions` strip further down exists to work around. Inheriting
  # would mean adding a second targeted deletion to that activation, whose only
  # gain over these literals is auto-tracking, and whose cost is a permanent
  # rule that silently discards any future intentional price override.
  #
  # The trade accepted here: these four numbers go stale, silently, if OpenAI
  # reprices. The reconcile command above is the mitigation; `cost` has no
  # default in mkCodexLbModel so a NEW model at least cannot ship at $0.00 by
  # omission. Flipping to inherit-plus-scrub is a defensible reversal — see
  # workstation-iq35 for the analysis rather than re-deriving it.
  #
  # Effect is PROSPECTIVE. opencode bakes `cost` into each message row as it is
  # written, so pre-existing rows keep their $0 forever and the chart's history
  # does not move. A flat historical total after editing these numbers is
  # correct, not a failed change.
  #
  # THIS CATALOG IS HAND-MAINTAINED AND WILL DRIFT. codex-lb re-fetches the real
  # catalog from upstream every 300s per account plan; opencode gets no such
  # feed, so anything not listed here is unselectable even when codex-lb serves
  # it. Reconcile against the live list rather than guessing:
  #
  #   curl -s localhost:2455/v1/models | jq -r '.data[].id'
  #   curl -s localhost:2455/backend-api/codex/models \
  #     | jq -r '.models[] | "\(.slug) ctx=\(.context_window) min_client=\(.minimal_client_version)"'
  #
  # Deliberately omitted from the live list: `gpt-reserve` (a quota bucket, not a
  # chat model) and `codex-auto-review` (a Codex-CLI-internal review model).
  #
  # A MODEL CAN BE ABSENT UPSTREAM FOR A REASON THAT IS NOT YOUR ACCOUNT.
  # Upstream gates new slugs on the Codex client version the caller presents.
  # codex-lb looks the latest release up from GitHub/npm at refresh time and
  # presents `codex_cli_rs/<version>`; its hardcoded FALLBACK is only 0.144.0
  # (`model_registry_client_version`), which is below astra's
  # `minimal_client_version` of 0.153.0. So if that lookup fails — no network at
  # refresh time, GitHub rate limit — astra silently vanishes from
  # /v1/models and opencode calls against it start failing. That is a codex-lb
  # degradation, not a subscription problem. `CODEX_LB_MODEL_REGISTRY_CLIENT_VERSION`
  # can pin it higher if this turns out to be flaky.
  # `cost` has deliberately NO default: a new codex-lb model added without a
  # sourced price must fail at eval rather than ship silently at $0.00, which is
  # the exact failure this block is fixing.
  mkCodexLbModel = { name, effort, cost }: {
    inherit name cost;
    reasoning = true;
    tool_call = true;
    attachment = true;
    release_date = "2026-06-01";
    limit = { context = 272000; output = 128000; };
    modalities = { input = [ "text" "image" ]; output = [ "text" ]; };
    options = {
      reasoningEffort = effort;
      reasoningSummary = "auto";
      include = [ "reasoning.encrypted_content" ];
    };
  };
  # Prices: models.dev base tier, $/Mtok. See the LIST-PRICE note above for why
  # the higher (>272k context) tier is omitted and why these are not zero.
  codexLbModels = {
    "gpt-6-astra" = mkCodexLbModel {
      name = "GPT-6 Astra";
      effort = "high";
      cost = { input = 10; output = 50; cache_read = 1; cache_write = 12.5; };
    };
    "gpt-5.6-sol" = mkCodexLbModel {
      name = "GPT-5.6 Sol";
      effort = "high";
      cost = { input = 4; output = 20; cache_read = 0.4; cache_write = 5; };
    };
    "gpt-5.6-terra" = mkCodexLbModel {
      name = "GPT-5.6 Terra";
      effort = "medium";
      cost = { input = 2; output = 12; cache_read = 0.2; cache_write = 2.5; };
    };
    "gpt-5.6-luna" = mkCodexLbModel {
      name = "GPT-5.6 Luna";
      effort = "low";
      cost = { input = 0.2; output = 1.2; cache_read = 0.02; cache_write = 0.25; };
    };
  };

  # Platform overlay:
  # - devbox defaults to the Anthropic subscription path, so sessions
  #   do not depend on the OpenAI API key.
  # - cloudbox defaults to Vertex Opus 5 (interactive primary model), while
  #   keeping compaction + the plan-execution subagents on cheap Gemini Flash.
  # - macOS defaults to Vertex Gemini 3.8 Flash on high thinking.
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
      plugin = pluginSpecs ++ [ "./plugins/caveman/plugin.js" ];
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
      # The picker listed the Vertex "Claude Opus 5" (and "Gemini 3.8 Flash")
      # entries right next to the working first-party anthropic/google ones; a
      # mis-pick persisted into ~/.local/state/opencode/model.json poisoned every
      # subsequently-opened session (3 crashes 2026-06..07). Disabling removes the
      # providers from the registry/picker entirely (recursiveUpdate treats the
      # list as a leaf and REPLACES it — base.json has no disabled_providers, and
      # the cloudbox branch below is a separate host, so there is no union/collision).
      disabled_providers = [ "google-vertex" "google-vertex-anthropic" ];
      # vision-qa (deployed below on devbox only) uses the direct
      # Google Generative AI API here (google/gemini-3.8-flash,
      # GOOGLE_GENERATIVE_AI_API_KEY / GEMINI_API_KEY auth — no Vertex).
      # Inject the same cost/limit catalog entry used for the Vertex flavor
      # below so cost tracking (oc-cost/aigateway) stays accurate.
      provider = {
        google = (opencodeBase.provider.google or {}) // {
          models = ((opencodeBase.provider.google or {}).models or {}) // {
            "gemini-3.8-flash" = gemini38FlashModel;
          };
        };
      } // lib.optionalAttrs isDevbox {
        # codex-lb subscription models (devbox only). Merged into the base openai
        # provider (which carries options.chunkTimeout + gpt-5.5) by the outer
        # recursiveUpdate, so gpt-5.5 and the sol/terra/luna tiers coexist. The
        # baseURL/apiKey that route these through codex-lb are set dynamically by
        # injectCodexLbBaseUrl (gated on the ~/.codex-lb/enabled opt-in marker).
        openai = { models = codexLbModels; };
      };
    })
    // (lib.optionalAttrs isDarwin {
      # ONE funnel for Claude on macOS. Before cfp there were two independent
      # lanes to the same Max pool: `anthropic/*` -> teamclaude directly, and
      # `google-vertex-anthropic/*` -> billed Vertex. The first has NO fallback —
      # when the pool 429s, teamclaude retries the same account and the request
      # hangs, which is exactly what happened on 2026-09-09 and is why that lane
      # was abandoned mid-day after 223 messages.
      #
      # cfp supersedes it: it reaches the same rotator, but falls back to Vertex
      # when Max refuses. Leaving `anthropic` in the picker would keep the
      # fallback-less path one mis-click away, and a model choice persists into
      # ~/.local/state/opencode/model.json and poisons later sessions (the same
      # failure mode documented for the Vertex entries on devbox above).
      #
      # recursiveUpdate treats this list as a leaf and REPLACES it; base.json has
      # no disabled_providers and the devbox/cloudbox branches are other hosts,
      # so there is no union to worry about.
      disabled_providers = [ "anthropic" ];
    })
    // (lib.optionalAttrs isCloudbox {
      # Cloudbox uses Vertex/ADC for Google models; hide the direct
      # Google Generative AI API provider to avoid selecting google/* by mistake.
      disabled_providers = [ "google" ];
      # Spawn-time bash wrapper (cloudbox only): runs every bash-tool command inside
      # its own transient systemd scope under `oc-agent.slice` (bead workstation-rdsq.4).
      shell = "${localPkgs.oc-scoped-shell}/bin/oc-scoped-shell";
    })
    // (lib.optionalAttrs (isDarwin || isCloudbox) {
      # Default model differs by host:
      #   - cloudbox -> Vertex Opus 5 (interactive primary model). The plan-
      #     execution subagents + compaction stay on cheap Gemini Flash below.
      #   - macOS    -> Gemini 3.8 Flash with high thinking (unchanged).
      model = if isCloudbox then vertexOpusModel else geminiModel;
      agent = {
        # Route the built-in `compaction` agent to Gemini 3.8 Flash. This is the
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
            "gemini-3.8-flash" = gemini38FlashModel;
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
  # `installWorktreeGuardHooks` in home.base.nix — that layer works and stays.
  # What is no longer enforced is blocking *edits* (as opposed to commits) at a
  # primary root; that is convention-only now.

   # Custom agents via OpenCode-native markdown format.
   # OpenCode loads agents from ~/.config/opencode/agents/ with tools as a YAML map.
   xdg.configFile."opencode/agents/librarian.md".source = patchAgent "librarian" "${assetsPath}/opencode/agents/librarian.md";
   # oracle and adversarial-reviewer each ship as TWO model-pinned twins,
   # generated from one prompt source per agent so the body cannot drift:
   #
   #   @<base>-fable  -> claude-fable-5-1, straight from the source file.
   #                     THE DEFAULT. On cloudbox patchAgent's afterFable branch
   #                     rewrites the `anthropic/` pin to
   #                     `google-vertex-anthropic/claude-fable-5-1@default`,
   #                     because cloudbox has no first-party Anthropic auth.
   #   @<base>-astra  -> openai/gpt-6-astra via codex-lb (mkAstraVariant).
   #                     Carries an opt-in CAUTION in its description so the
   #                     orchestrator does not reach for it on its own.
   #                     patchAgent is a no-op for an `openai/` pin.
   #
   # THE ASTRA TWINS ARE GATED TO devbox + cloudbox, matching the hosts where
   # `codexLbModels` is injected into the openai provider — NOT the hosts that
   # run codex-lb. macOS runs codex-lb too (home.darwin.nix, launchd flavor) and
   # has its baseURL redirected by injectCodexLbBaseUrlDarwin, but it never gets
   # the subscription model catalog, so `openai/gpt-6-astra` is not a selectable
   # model there and an astra agent would be a handle that always fails at
   # request time. Shipping a dead handle is worse than shipping none: the
   # orchestrator can still be asked for it by name. Closing that gap means
   # injecting codexLbModels on darwin as well — deliberately not done here
   # because it also adds sol/terra/luna to the macOS picker and nothing on this
   # box can test it.
   #
   # The deployed FILE keeps the `-fable` suffix while the SOURCE does not. That
   # asymmetry is deliberate and predates the astra twin: the suffix was held as
   # a compat hook precisely so a second model could be added without renaming a
   # handle that call sites and skill docs already reference.
   xdg.configFile."opencode/agents/adversarial-reviewer-fable.md".source =
     patchAgent "adversarial-reviewer-fable" "${assetsPath}/opencode/agents/adversarial-reviewer.md";
   xdg.configFile."opencode/agents/adversarial-reviewer-astra.md" = lib.mkIf (isDevbox || isCloudbox) {
     source = patchAgent "adversarial-reviewer-astra" (mkAstraVariant "adversarial-reviewer" "${assetsPath}/opencode/agents/adversarial-reviewer.md");
   };
   xdg.configFile."opencode/agents/oracle-fable.md".source =
     patchAgent "oracle-fable" "${assetsPath}/opencode/agents/oracle.md";
   xdg.configFile."opencode/agents/oracle-astra.md" = lib.mkIf (isDevbox || isCloudbox) {
     source = patchAgent "oracle-astra" (mkAstraVariant "oracle" "${assetsPath}/opencode/agents/oracle.md");
   };
   xdg.configFile."opencode/agents/implementer.md".source = patchAgent "implementer" "${assetsPath}/opencode/agents/implementer.md";
   xdg.configFile."opencode/agents/spec-reviewer.md".source = patchAgent "spec-reviewer" "${assetsPath}/opencode/agents/spec-reviewer.md";
   xdg.configFile."opencode/agents/code-reviewer.md".source = patchAgent "code-reviewer" "${assetsPath}/opencode/agents/code-reviewer.md";
   # vision-qa is API-key-only by design (no Vertex): its base pin is
   # google/gemini-3.8-flash (Google Generative AI API, authed via
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

  # WARNING: opencode caches resolved plugins under ~/.cache/opencode/packages/
  # keyed by the version spec in the runtime `plugin` array (e.g. <pkg>@1.2.3/).
  # The cache never re-resolves on its own, so bumping a pin in
  # `opencodePluginPins` WITHOUT invalidating the cache silently keeps the old
  # version live in opencode-serve. This script handles the invalidation; do not
  # skip it. The pin table itself lives at module scope — see the long note
  # there for why it must also drive `pluginSpecs`.
  home.activation.installOpencodePlugins = let
    pinJson = builtins.toJSON opencodePluginPins;

    # Minimum Claude Code version the pinned anthropic-auth plugin must report.
    # Asserted at activation; see the assertion block below for why.
    claudeCodeVersionFloor = "2.1.251";
  in lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    set -euo pipefail
    export PATH="${pkgs.nodejs}/bin:${pkgs.jq}/bin:${pkgs.coreutils}/bin:${pkgs.gnused}/bin:$PATH"
    mkdir -p "$HOME/.config/opencode"
    cd "$HOME/.config/opencode"

    # Bootstrap package.json if missing (first install on a fresh machine)
    if [ ! -f package.json ]; then
      echo '{"name":"opencode-config","private":true}' > package.json
    fi

    pins='${pinJson}'
    cache_invalidated=0

    # Install ALL pinned plugins in ONE npm invocation.
    #
    # This must not be done one-per-package inside the loop below. `npm install
    # <pkg> --no-save` does not record <pkg> in package.json, so the NEXT
    # --no-save install treats the previous one as extraneous and prunes it.
    # Sequential installs therefore leave only the last pin on disk, which is
    # exactly what cloudbox showed: node_modules/opencode-beads present,
    # node_modules/@ex-machina/ empty. That silently disabled the
    # CLAUDE_CODE_VERSION assertion below, which reads its constant out of
    # node_modules and skips when the file is absent.
    #
    # Note this leg is NOT on opencode's plugin-resolution path (opencode loads
    # from ~/.cache/opencode/packages/, never from here — see the
    # managing-opencode-plugins skill). It exists to materialise the
    # @opencode-ai/plugin peer dep and to fail early if a pin does not exist on
    # npm. Failure to reach the registry must not abort the whole switch, hence
    # the `|| true`; the assertion below reports the consequence.
    mapfile -t plugin_specs < <(echo "$pins" | jq -r 'to_entries | .[] | "\(.key)@\(.value)"')
    if [ ''${#plugin_specs[@]} -gt 0 ]; then
      npm install "''${plugin_specs[@]}" --no-save >/dev/null 2>&1 || \
        echo "installOpencodePlugins: WARNING: npm install of ''${plugin_specs[*]} failed (registry unreachable, or a pinned version does not exist). Cache checks below still run." >&2
    fi

    # For each pinned plugin, check ~/.cache/opencode/packages/ for stale copies
    # that opencode-serve would actually load (it prefers cache over node_modules).
    while IFS=$'\t' read -r pkg pinned_ver; do
      [ -n "$pkg" ] || continue

      # Find any cached copies of this package and purge those whose installed
      # version doesn't match the pin. The cache key is the version spec in the
      # runtime `plugin` array at first-fetch time, so we cover THREE shapes:
      #
      #   <name>@<pin>   what opencode writes NOW that pluginSpecs emits an
      #                  explicit version. This is the live one.
      #   <name>@latest  what it wrote while the array carried bare names.
      #                  Dead after this change; purged once, then never
      #                  recreated, because nothing resolves `latest` anymore.
      #   <name>         bare directories left by older opencode builds.
      #
      # Note the consequence for reading the cache by eye: immediately after
      # this change a host can hold all three directories at the SAME version,
      # so "which copy is live?" is answered by the spec in the generated
      # opencode.json, not by which directory exists. The stale two are purged
      # on the first activation whose pin differs from their contents.
      #
      # One case this does NOT cover: a PROJECT-level opencode.json that lists
      # a bare `opencode-beads`. opencode dedupes plugin origins by package
      # name with last-one-wins, so such a project reintroduces the `@latest`
      # spec and its churn on that host. No project in this estate does today.
      #
      # The cached package.json lives at:
      #   <cache_dir>/node_modules/<scope>/<name>/package.json
      cache_root="$HOME/.cache/opencode/packages"
      [ -d "$cache_root" ] || continue

      # Resolve <scope>/<name> globs. Empty glob => no cached copies, skip.
      shopt -s nullglob
      for cache_dir in "$cache_root/$pkg" "$cache_root/$pkg"@*; do
        [ -d "$cache_dir" ] || continue
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

    # Assert the anthropic-auth plugin reports a Claude Code version Anthropic
    # still accepts. Read-only: the pin above is what fixes this, and the purge
    # loop is what enforces the pin. This only makes the failure legible.
    #
    # Worth asserting rather than trusting the pin, because the symptom is an
    # EMPTY assistant turn with no visible error (the 400 lands only in the
    # stored message record in opencode.db). Every minute spent on that symptom
    # is spent suspecting agent config. One line at switch time replaces it.
    #
    # The floor moves on Anthropic's schedule, not ours: it is whatever the
    # newest model we pin an agent to demands. 2.1.251 is claude-fable-5-1's.
    cc_floor='${claudeCodeVersionFloor}'
    auth_pkg="@ex-machina/opencode-anthropic-auth"

    shopt -s nullglob
    for constants in \
      "$HOME/.config/opencode/node_modules/$auth_pkg/dist/constants.js" \
      "$HOME/.cache/opencode/packages/$auth_pkg" \
      "$HOME/.cache/opencode/packages/$auth_pkg"@*
    do
      # Accept either a file (node_modules path) or a cache dir, and normalise.
      if [ -d "$constants" ]; then
        constants="$constants/node_modules/$auth_pkg/dist/constants.js"
      fi
      [ -f "$constants" ] || continue

      reported="$(sed -nE "s/^export const CLAUDE_CODE_VERSION = '([^']*)'.*/\1/p" "$constants" | head -1)"

      if [ -z "$reported" ]; then
        {
          echo "installOpencodePlugins: WARNING — could not read CLAUDE_CODE_VERSION from $constants."
          echo "installOpencodePlugins: the plugin's constants.js shape changed; the version assertion below is now blind."
        } >&2
        continue
      fi

      # Version-sort both and check the floor didn't win. `sort -V` handles the
      # dotted components; string compare would rank 2.1.87 above 2.1.258.
      oldest="$(printf '%s\n%s\n' "$reported" "$cc_floor" | sort -V | head -1)"
      if [ "$reported" != "$cc_floor" ] && [ "$oldest" = "$reported" ]; then
        {
          echo "installOpencodePlugins: WARNING — $auth_pkg reports Claude Code $reported, below the $cc_floor floor."
          echo "installOpencodePlugins: gated models will return EMPTY assistant turns (400 claude_code_version_too_old)."
          echo "installOpencodePlugins: bump the pin in opencode-config.nix to a release reporting >= $cc_floor."
          echo "installOpencodePlugins: offending copy: $constants"
        } >&2
      fi
    done
    shopt -u nullglob

    # Report that the cache changed; do NOT restart anything.
    #
    # Neither NixOS host auto-restarts, deliberately. Both run a serve POOL of
    # templated opencode-serve@<port> units under opencode-serve-pool.target
    # (USER-scoped on devbox, system-scoped on cloudbox). There is no single
    # "opencode-serve.service" to bounce, and cycling the target is the only
    # correct whole-pool action — which kills every live session on the box,
    # including the session running this switch. That is why reset-workspace
    # does it nightly, behind a confirmation.
    #
    # Both branches used to `systemctl restart opencode-serve.service`. That
    # unit stopped existing at the pool migration (cloudbox aca3de6 2026-06-20,
    # devbox 67f9b69 2026-06-21), so the call became a guaranteed exit-5 no-op
    # that printed a warning telling you to run the same nonexistent unit by
    # hand. devbox was corrected earlier; this is cloudbox catching up, and the
    # two policies are now identical so they share one branch.
    #
    # The consequence was never staleness, only latency — the pool IS restarted
    # nightly at 03:00 by nightly-restart-background.timer (a SYSTEM timer on
    # both hosts; `systemctl --user list-timers` does not show it), so a newly
    # pinned plugin goes live within a day regardless. Verified on cloudbox
    # 2026-09-03: that run reported "pool restart verified for all ports".
    #
    # So: say what happened and what the options are, and let the human pick.
    ${lib.optionalString (isDevbox || isCloudbox) ''
      if [ "$cache_invalidated" = "1" ]; then
        {
          echo "installOpencodePlugins: stale plugin cache purged. Running serves keep the OLD plugin until the pool restarts."
          echo "installOpencodePlugins: the pinned version is not on disk yet — opencode re-fetches it from npm on the first restart, so that restart needs registry access."
          echo "installOpencodePlugins:   automatic — nightly at 03:00 (nightly-restart-background.timer)"
          echo "installOpencodePlugins:   now, disruptive — reset-workspace   (kills all live sessions)"
        } >&2
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
  # isCloudbox ONLY, not (isDevbox || isCloudbox). Cloudbox is the only host
  # that both declares these secrets (hosts/cloudbox/configuration.nix) and runs
  # the inject*Sops blocks. On devbox NONE of mcpSopsSecretNames is declared, so
  # every switch would print "checked 0 secrets" forever — and an always-on
  # warning is worse than no warning: it trains the operator to ignore the one
  # message that already caught a real bug (the glob that silently checked
  # nothing). A guard that cries wolf on one host is a guard nobody reads on any
  # host.
  home.activation.assertOpencodeConfigHasNoSecrets = lib.mkIf isCloudbox
    (lib.hm.dag.entryAfter [
      "mergeOpencode"
      "injectDatadogMcpSecretsSops"
      "injectSlackMcpSecretsSops"
      "injectPagerDutyMcpSecretsSops"
      "injectRollbarMcpSecretsSops"
      "injectDevcycleMcpSecretsSops"
    ] ''
      set -euo pipefail

      runtime="$HOME/.config/opencode/opencode.json"

      # NOTE: no bare `exit` anywhere in this block. home-manager concatenates
      # every activation into ONE script with no subshell, so an `exit` here
      # terminates the whole run — silently skipping every LATER activation
      # (deployDoltCreds, installOpencodePlugins, reloadSystemd, ...) while
      # still reporting success. The inject* blocks below carry the same warning
      # in three places; an earlier version of THIS block reintroduced the bug
      # anyway. Guard with `if`, never `|| exit`.
      if [[ ! -f "$runtime" ]] || [ ! -d /run/secrets ]; then
        echo "opencode secrets guard: skipped (no config or no /run/secrets on this host)." >&2
      else
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
        # Only meaningful where the secrets are actually declared — see the
        # isCloudbox gate on this activation.
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
        echo "opencode MCP: basecamp not configured (optional) -- no Basecamp credentials in Keychain; omitting mcp.basecamp." >&2
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
        echo "opencode MCP: slack not configured (optional) -- no 'slack-mcp-xoxp-token' in Keychain; omitting mcp.slack + mcp.slack-ro. To enable, see the slack-mcp-setup skill." >&2
      # Token present: inject Slack MCP config with xoxp auth
      # MCP is disabled by default; enable manually or use dedicated slack agent when needed.
      # Two variants: `slack` (read + write) and `slack-ro` (read-only). Both run
      # the PINNED localPkgs.slack-mcp-server build, not `npx -y ...@latest` —
      # see pkgs/slack-mcp-server for why (file_upload patch + no unpinned
      # network fetch for a process holding a Slack user token).
      #
      # The korotovsky server registers all READ tools unconditionally; each
      # write/side-effecting tool is opt-in via its own env var. So the read-only
      # guarantee of `slack-ro` is exactly "which gates are absent":
      #   SLACK_MCP_ADD_MESSAGE_TOOL  -> conversations_add_message  (slack only)
      #   SLACK_MCP_FILE_UPLOAD_TOOL  -> file_upload                (slack only)
      #   SLACK_MCP_ATTACHMENT_TOOL   -> attachment_get_data        (BOTH: download
      #                                  is read-only, so slack-ro keeps it)
      # slack-ro is used by lgtm's read-only gather session
      # (`opencode-launch --mcp slack-ro`) so it structurally cannot post.
      #
      # SLACK_MCP_FILE_UPLOAD_PATHS names exactly ONE directory, and it is a
      # staging area that exists for no other purpose. Everything about this
      # value is deliberate; read before widening it.
      #
      # Why it is set at all: it was previously unset, on the reasoning that
      # `content_base64` covers the same ground for free because "an agent can
      # base64 a file itself". That is false. A tool argument is emitted by the
      # MODEL, so the base64 has to pass through the context window -- a 294 KB
      # chart PNG is ~392 KB of base64, well over 100k tokens. In practice the
      # agent gave up and a human attached the file by hand.
      #
      # Why a staging dir and not the directory the artifact was born in: with
      # `content_base64` the exfiltrated bytes must cross the transcript, which
      # is what makes bulk exfiltration infeasible. `file_path` removes that
      # limit -- the server reads bytes the model never saw. So the allowlist
      # must contain only files that exist in order to be sent. That rules out
      # the two obvious candidates. A project's outputs/ directory is a years-
      # deep archive of data exports; /tmp/opencode itself is 2.1 GB and ~68k
      # files of scratch from every concurrent session, including whole repo
      # checkouts and multi-MB CSVs. Allowlisting either turns a prompt
      # injection into a single tool call against files already on disk.
      #
      # This is defense in depth, not a wall: a session holding the write tools
      # also holds bash, so `cp X <staging> && upload` is always available. What
      # the narrow root buys is that the copy is an explicit bash command naming
      # its source, visible in the transcript -- an injected instruction cannot
      # be satisfied by a bare tool call against pre-existing scratch.
      #
      # The root must EXIST at call time: a root that fails EvalSymlinks is
      # skipped, and an empty root list reports "not allowed", not "missing".
      # cloudbox creates it via systemd.tmpfiles; on macOS `mkdir -p` it.
      #
      # Not set on slack-ro: without SLACK_MCP_FILE_UPLOAD_TOOL the upload tool
      # is never registered there, so the variable would be inert.
      #
      # SLACK_MCP_LOG_LEVEL=warn because the server's logger middleware logs
      # every tool call's params at INFO -- which for file_upload is the file
      # CONTENT, and for conversations_add_message is the message text. The MCP
      # process's stderr is inherited by opencode-serve, so at the default level
      # anything uploaded is also durably in the journal. `warn` still logs tool
      # name and error on failures.
      #
      # Neither variant sets SLACK_MCP_ENABLED_TOOLS. Do not add it to slack-ro:
      # the runtime gate treats a tool named there as enabled, so it is a second
      # door into the write tools that bypasses the per-tool env vars above.
      # elif (not `exit 0` + separate if): an exit aborts the whole HM activation.
      elif [[ -f "$runtime" ]]; then
        # The one allowlisted upload root. A root that cannot be resolved is
        # skipped silently and the upload then fails as "not allowed", so
        # create it here rather than debug that error later. Best effort: on
        # cloudbox systemd.tmpfiles owns it, and /tmp is cleared out from under
        # this eventually on either host, so an agent should still `mkdir -p`.
        mkdir -p "${slackUploadStagingDir}" || true

        tmp="$(mktemp "''${runtime}.tmp.XXXXXX")"

        ${pkgs.jq}/bin/jq \
          --arg xoxp "${secretRef "slack_mcp_xoxp_token"}" \
          --arg bin "${localPkgs.slack-mcp-server}/bin/slack-mcp-server" \
          --arg uploads "${slackUploadStagingDir}" \
          '.mcp.slack = {
            "type": "local",
            "command": [$bin, "--transport", "stdio"],
            "enabled": false,
            "environment": {
              "SLACK_MCP_XOXP_TOKEN": $xoxp,
              "SLACK_MCP_ADD_MESSAGE_TOOL": "true",
              "SLACK_MCP_ATTACHMENT_TOOL": "true",
              "SLACK_MCP_FILE_UPLOAD_TOOL": "true",
              "SLACK_MCP_FILE_UPLOAD_PATHS": $uploads,
              "SLACK_MCP_LOG_LEVEL": "warn"
            }
          }
          | .mcp."slack-ro" = {
            "type": "local",
            "command": [$bin, "--transport", "stdio"],
            "enabled": false,
            "environment": {
              "SLACK_MCP_XOXP_TOKEN": $xoxp,
              "SLACK_MCP_ATTACHMENT_TOOL": "true",
              "SLACK_MCP_LOG_LEVEL": "warn"
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
        echo "opencode MCP: slack not configured (optional) -- no slack_mcp_xoxp_token in sops; omitting mcp.slack + mcp.slack-ro (a dangling secret reference would fail the WHOLE config load, so omitting is mandatory, not cosmetic). To enable, see the slack-mcp-setup skill." >&2
      # Token present: inject Slack MCP config with xoxp auth.
      # Two variants: `slack` (read + write) and `slack-ro` (read-only). Both run
      # the PINNED localPkgs.slack-mcp-server build (see pkgs/slack-mcp-server).
      # Read tools always register; each write tool is opt-in per env var, so
      # slack-ro's guarantee is the ABSENCE of SLACK_MCP_ADD_MESSAGE_TOOL and
      # SLACK_MCP_FILE_UPLOAD_TOOL. SLACK_MCP_ATTACHMENT_TOOL is set on both —
      # downloading an attachment is a read.
      #
      # SLACK_MCP_FILE_UPLOAD_PATHS names exactly one directory, a staging area
      # that exists for no other purpose, and is set on `slack` only (on
      # slack-ro the upload tool is never registered, so it would be inert).
      # `content_base64` is not a substitute -- the model has to emit the blob
      # as a tool argument, so a 294 KB PNG is ~100k tokens and does not fit.
      # But that same limit is what makes bulk exfiltration infeasible, and
      # `file_path` removes it: the server reads bytes the model never saw.
      # Hence the root must hold only files staged in order to be sent. NOT a
      # project outputs/ dir (years of data exports) and NOT /tmp/opencode
      # itself (2.1 GB, ~68k files of scratch from every concurrent session,
      # incl. repo checkouts and multi-MB CSVs) -- either would make a prompt
      # injection a single tool call against files already on disk. The copy
      # into the staging dir is a bash command naming its source, so it lands
      # in the transcript. Full reasoning in the Darwin block above.
      # The root must exist at call time (a root that fails EvalSymlinks is
      # silently skipped and the error reads "not allowed"); cloudbox creates
      # it via systemd.tmpfiles in hosts/cloudbox/configuration.nix.
      # SLACK_MCP_LOG_LEVEL=warn keeps upload content and message text out of
      # the journal: the logger middleware logs every call's params at INFO.
      # Do not add SLACK_MCP_ENABLED_TOOLS to slack-ro -- naming a tool there
      # enables it regardless of the per-tool gates.
      # elif (not `exit 0` + separate if): an exit aborts the whole HM activation.
      elif [[ -f "$runtime" ]]; then
        # The one allowlisted upload root. A root that cannot be resolved is
        # skipped silently and the upload then fails as "not allowed", so
        # create it here rather than debug that error later. Best effort: on
        # cloudbox systemd.tmpfiles owns it, and /tmp is cleared out from under
        # this eventually on either host, so an agent should still `mkdir -p`.
        mkdir -p "${slackUploadStagingDir}" || true

        tmp="$(mktemp "''${runtime}.tmp.XXXXXX")"

        ${pkgs.jq}/bin/jq \
          --arg xoxp "${secretRef "slack_mcp_xoxp_token"}" \
          --arg bin "${localPkgs.slack-mcp-server}/bin/slack-mcp-server" \
          --arg uploads "${slackUploadStagingDir}" \
          '.mcp.slack = {
            "type": "local",
            "command": [$bin, "--transport", "stdio"],
            "enabled": false,
            "environment": {
              "SLACK_MCP_XOXP_TOKEN": $xoxp,
              "SLACK_MCP_ADD_MESSAGE_TOOL": "true",
              "SLACK_MCP_ATTACHMENT_TOOL": "true",
              "SLACK_MCP_FILE_UPLOAD_TOOL": "true",
              "SLACK_MCP_FILE_UPLOAD_PATHS": $uploads,
              "SLACK_MCP_LOG_LEVEL": "warn"
            }
          }
          | .mcp."slack-ro" = {
            "type": "local",
            "command": [$bin, "--transport", "stdio"],
            "enabled": false,
            "environment": {
              "SLACK_MCP_XOXP_TOKEN": $xoxp,
              "SLACK_MCP_ATTACHMENT_TOOL": "true",
              "SLACK_MCP_LOG_LEVEL": "warn"
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
        echo "opencode MCP: pagerduty not configured (optional) -- no 'pagerduty-user-api-key' in Keychain; omitting mcp.pagerduty. To enable, see the pagerduty-mcp-setup skill." >&2
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
        echo "opencode MCP: pagerduty not configured (optional) -- no pagerduty_user_api_key in sops; omitting mcp.pagerduty. To enable, see the pagerduty-mcp-setup skill." >&2
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
        echo "opencode MCP: rollbar not configured (optional) -- no 'rollbar-access-token' in Keychain; omitting mcp.rollbar. To enable, see the rollbar-mcp-setup skill." >&2
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
        echo "opencode MCP: rollbar not configured (optional) -- no rollbar_access_token in sops; omitting mcp.rollbar. To enable, see the rollbar-mcp-setup skill." >&2
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
  # devcycle-mcp binding above). Two auth modes, either of which surfaces the
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
        echo "opencode MCP: devcycle not configured (optional) -- no 'devcycle-client-id'/'devcycle-client-secret' in Keychain and no ~/.config/devcycle/auth.yml; omitting mcp.devcycle. To enable, see the setting-up-devcycle-mcp skill." >&2
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
          --arg command "${devcycle-mcp}" \
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
        echo "opencode MCP: devcycle not configured (optional) -- no devcycle_client_id/devcycle_client_secret in sops and no ~/.config/devcycle/auth.yml; omitting mcp.devcycle. To enable, see the setting-up-devcycle-mcp skill." >&2
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
          --arg command "${devcycle-mcp}" \
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
  # Trigger: the aigateway INTENT FLAG exists AND we have a
  # GOOGLE_CLOUD_PROJECT secret. When both conditions hold: set both
  # `provider.google-vertex-anthropic.options.baseURL` (Claude) AND
  # `provider.google-vertex.options.baseURL` (Gemini) to URLs pointing
  # at the local Docker gateway, with the project baked into the path.
  # Otherwise: strip the overrides so opencode falls back to direct Vertex.
  #
  # NOTE: Gemini (`google-vertex/gemini-3.8-flash`) is the GLOBAL DEFAULT
  # model on cloudbox, so routing it through the gateway means every
  # session (interactive + opencode-serve/pigeon/Telegram) depends on the
  # gateway being up. The gateway parses Gemini `usageMetadata` and prices
  # `gemini-3.8-flash`; unpriced Gemini models still ledger tokens (NULL
  # dollars). Verified live 2026-06-05 — see investigation report
  # docs/investigations/2026-06-05-vertex-gemini-surge/aigateway-cost-fix.md.
  #
  # Why a flag and not `is-enabled` or `is-active`? NixOS unit files live in
  # the read-only /etc/systemd/system (symlinks into the Nix store), so
  # `is-enabled` returns "linked" permanently and can never be a signal. And
  # `is-active` — which this used until 2026-09-13 — answers "is it up right
  # now", not "does the operator want it up": anything that stops the unit
  # silently re-points opencode at direct Vertex on the next switch. See the
  # detailed rationale on the activation body below, and the long comment on
  # systemd.services.aigateway in hosts/cloudbox/configuration.nix.
  # The unit is now wantedBy = [ "multi-user.target" ], gated on the same
  # flag, so intent DOES survive a reboot.
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
      #   - gemini (google-vertex)            follows the aigateway INTENT FLAG
      #   - claude (google-vertex-anthropic)  follows claude-failover-proxy.service
      #     (the cfp budget-gated Vertex<->Max failover router on :8789).
      #
      # INTENT, NOT LIVENESS (changed 2026-09-13, bd workstation-f794). This
      # used to read `systemctl is-active aigateway.service`, which conflates
      # "the operator wants the gateway" with "the gateway is up right now".
      # That conflation has a nasty shape: the moment the gateway goes down,
      # the next home-manager switch silently rewrites opencode to talk direct
      # Vertex — and then the gateway coming back does NOT undo it, because
      # nothing re-runs this activation. You get a ledger gap that outlives the
      # outage and ends whenever someone happens to switch again.
      #
      # So: read the persistent flag. If the operator says the gateway should
      # be up, point at it even if it is currently down. A down gateway is a
      # LOUD failure (ECONNREFUSED on the first gemini turn) that
      # aigateway-canary heals within a minute; a silent direct-Vertex
      # fallback is a quiet failure that nobody notices and that costs the
      # per-request attribution the gateway exists to collect.
      #
      # cfp keeps using is-active: it is a plain long-running service with no
      # opt-in flag, so there the two questions genuinely coincide.
      sc=/run/current-system/sw/bin/systemctl
      aigw_intent=no
      [ -e ${aigatewayFlag} ] && aigw_intent=yes
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
        if [ "$aigw_intent" = yes ]; then
          gemini_url="http://localhost:8080/v1beta1/projects/$project/locations/global/publishers/google"
        fi
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
            if [ "$aigw_intent" = yes ]; then
              anthropic_url="http://localhost:8080/v1/projects/$project/locations/global/publishers/anthropic/models"
            fi ;;
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

      echo "aigateway/cfp: claude -> ''${anthropic_url:-<direct Vertex>} (cfp=$cfp_state); gemini -> ''${gemini_url:-<direct Vertex>} (aigw intent=$aigw_intent)" >&2
      new_hash="$(printf '%s\n%s' "$anthropic_url" "$gemini_url" | ${pkgs.coreutils}/bin/sha256sum | ${pkgs.coreutils}/bin/cut -d' ' -f1)"

      # A provider's baseURL is read at provider init, so a changed URL only
      # takes effect once a serve restarts. We do NOT restart here — same policy
      # as injectTeamclaudeBaseUrl and injectCodexLbBaseUrl, and for the same
      # reason: cloudbox runs a serve POOL (opencode-serve@<port> under
      # opencode-serve-pool.target), so there is no single unit to bounce and
      # cycling the target kills every live session, including the one running
      # this switch.
      #
      # This block used to `sudo systemctl restart opencode-serve.service`. That
      # unit has not existed here since the pool migration (aca3de6,
      # 2026-06-20), so the restart was a guaranteed exit-5 no-op — and because
      # the hash file was only written on restart SUCCESS, the failure path
      # re-armed itself: every switch that saw a changed URL would warn and
      # again decline to persist the hash, so the "next rebuild will retry"
      # promise could never be discharged. Writing the hash unconditionally is
      # what makes this converge.
      #
      # (The live hash file is dated 2026-06-19 — the last day the unit existed.
      # The URL has not changed since, which is the only reason this site had
      # stayed quiet rather than warning on every switch.)
      old_hash=""
      [ -r "$hash_file" ] && old_hash="$(cat "$hash_file")"
      if [[ "$new_hash" != "$old_hash" ]]; then
        echo "$new_hash" > "$hash_file"
        {
          echo "aigateway: baseURL changed (url hash $old_hash -> $new_hash)."
          echo "aigateway: config written — running serves keep the old provider init until they restart."
          echo "aigateway:   automatic — nightly at 03:00 (nightly-restart-background.timer)"
          echo "aigateway:   now, disruptive — reset-workspace   (kills all live sessions)"
        } >&2
      fi
    '');

  # Point opencode's first-party `anthropic` provider at the local TeamClaude
  # rotator (devbox) when this host has a SEEDED teamclaude config (at least one
  # account); otherwise strip the override so opencode talks to api.anthropic.com
  # directly. Note that predicate is about configuration, not liveness -- see the
  # PREDICATE section below. TeamClaude proxies
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
  # this play box. To go fully direct, move ~/.config/teamclaude.json aside and
  # re-switch so this block stops seeding the dummy, THEN `opencode auth login`.
  # Merely stopping the service no longer does it — see the PREDICATE note below.)
  #
  # THE PREDICATE IS THE OPT-IN MARKER, NOT LIVENESS — same fix, same reasoning
  # as injectCodexLbBaseUrl below (bead workstation-m55p, sibling of
  # workstation-k03x). Read that block's PREDICATE section for the full argument;
  # the short version is that home-manager runs file activation BEFORE sd-switch
  # starts changed units, so `systemctl --user is-active teamclaude.service` here
  # reads the PRE-switch state. A switch taken while teamclaude happened to be
  # down therefore stripped the baseURL, and systemd started teamclaude
  # successfully seconds later, leaving a healthy rotator that opencode was not
  # pointed at — until somebody ran a second switch. That exact sequence caused a
  # live outage on the codex-lb twin on 2026-09-13.
  #
  # The signal is `~/.config/teamclaude.json` -- the same file the unit gates on
  # (`ConditionPathExists`, users/dev/home.devbox.nix) and the darwin launchd
  # wrapper tests -- but read for a NON-EMPTY ACCOUNTS ARRAY rather than mere
  # existence. See the predicate comment at the test itself for why that
  # difference is load-bearing and why it does not reintroduce the race.
  # Seeded config => this host intends to route Anthropic through teamclaude.
  # Order-independent, so it cannot race sd-switch.
  #
  # "Stopping the service is a clean rollback" WAS TRUE OF THE OLD GATE AND IS
  # NOT TRUE NOW. Stopping teamclaude no longer reverts opencode to direct
  # Anthropic; you must remove/rename ~/.config/teamclaude.json (or move it aside)
  # and re-switch. That is a real loss of convenience, accepted because the thing
  # it bought was mostly fictional: the dummy credential seeded below is
  # non-expiring and NOT a real grant, so a "direct Anthropic" fallback reached by
  # stopping the service could not authenticate anyway — the header above already
  # said as much. Going genuinely direct always required a real
  # `opencode auth login` on top, and it still does.
  #
  # opencode-serve (a USER service on devbox) is restarted when the effective URL
  # changes OR the dummy credential is freshly seeded.
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

      # Decides the config. Order-independent.
      #
      # THE SHARED PREDICATE. `teamclaude-seeded` (pkgs/teamclaude) exits 0 iff
      # the config names at least one account. The devbox unit's ExecCondition
      # and the darwin launchd wrapper call the same binary, so all three sites
      # answer "is teamclaude usable here" identically by construction.
      #
      # STRICTER THAN THE UNIT'S OWN ConditionPathExists, deliberately. Mere
      # existence of teamclaude.json is NOT evidence that teamclaude will run:
      # `loadOrCreateConfig()` writes a default config with `accounts: []` on
      # almost any CLI invocation -- including at the TOP of `teamclaude login`,
      # before the OAuth flow (src/index.js), so an aborted login leaves the file
      # behind -- and `teamclaude remove` of the last account leaves it empty too.
      # teamclaude then exits 1 on a zero-account config and crash-loops.
      #
      # That matters here because being wrong in this direction is destructive,
      # not merely useless: we would point anthropic/* at a dead port AND
      # overwrite a real credential with the dummy below, on a host that had
      # simply run `teamclaude accounts` once. Nothing would self-heal it.
      #
      # This does not reintroduce the race #509 fixed. The stricter test only
      # diverges from the unit's where the unit CANNOT run healthily, so it still
      # never strips while a healthy teamclaude is about to start. A garbled or
      # unreadable config reads as disabled, which matches what the server would
      # do with it anyway.
      tc_enabled=0
      # TEAMCLAUDE_CONFIG is pinned here for the same reason the unit pins it:
      # this runs during a home-manager switch from whatever shell invoked it,
      # which may carry an XDG_CONFIG_HOME the service will never see. Without
      # the pin, activation and the service could resolve different files and
      # disagree about whether teamclaude is seeded.
      if TEAMCLAUDE_CONFIG="$HOME/.config/teamclaude.json" \
           ${localPkgs.teamclaude}/bin/teamclaude-seeded; then
        tc_enabled=1
      fi

      # Reported only, never decisive. Legitimately reads inactive/failed here on
      # a switch that is about to start the unit.
      tc_state="$($sc --user is-active teamclaude.service 2>/dev/null || true)"

      anthropic_url=""
      if [[ "$tc_enabled" == 1 ]]; then
        anthropic_url="http://127.0.0.1:3456/v1"
      fi

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
      # switch while the teamclaude MARKER exists (~/.config/teamclaude.json) --
      # not merely while the service is up -- so a stray `opencode auth login`
      # can't reintroduce the refresh conflict; idempotent via the sorted-key
      # compare.
      #
      # NOTE THIS NOW FIRES WHILE TEAMCLAUDE IS DOWN TOO. Under the old liveness
      # gate a stopped teamclaude left the auth store alone; now the dummy is
      # (re)seeded on every switch as long as the config file exists. In practice
      # that changes little -- the dummy would already be sitting there from the
      # previous switch, which is exactly why the header says the direct-Anthropic
      # fallback cannot authenticate -- but it does mean a real
      # `opencode auth login` performed while teamclaude is stopped gets
      # overwritten by the next switch. To go genuinely direct, move
      # ~/.config/teamclaude.json aside first, then log in.
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

      echo "teamclaude: anthropic -> ''${anthropic_url:-<direct Anthropic>} (marker=$tc_enabled, unit=''${tc_state:-unknown})" >&2
      if [[ -n "$anthropic_url" ]]; then
        case "$tc_state" in
          active|activating) ;;
          # sd-switch will NOT start a unit that is already `failed` on an
          # unchanged unit file, so unlike `inactive` this does not self-resolve.
          #
          # A zero-account config no longer lands here: the unit's ExecCondition
          # runs `teamclaude-seeded` and a condition-skip is inactive+success,
          # not failed. So `failed` now means the server started and died for a
          # reason the config file alone does not predict -- most likely every
          # account being unusable at runtime, or a port conflict on 3456.
          failed) echo "teamclaude: unit is FAILED and this switch will not start it — the config has accounts (ExecCondition passed), so check the logs, then: systemctl --user reset-failed teamclaude.service && systemctl --user start teamclaude.service" >&2 ;;
          *) echo "teamclaude: unit reads ''${tc_state:-unknown} right now — expected if this switch is about to start it; if anthropic/* still fails afterwards, check: systemctl --user status teamclaude" >&2 ;;
        esac
      fi
      new_hash="$(printf '%s' "$anthropic_url" | ${pkgs.coreutils}/bin/sha256sum | ${pkgs.coreutils}/bin/cut -d' ' -f1)"

      # The plugin's loader decides oauth-mode (shaping) at provider init, so a
      # changed URL or a fresh dummy-cred seed only takes effect once a serve
      # restarts. We do NOT restart here — same policy as injectCodexLbBaseUrl
      # below, and for the same reason: devbox runs a serve POOL
      # (opencode-serve@<port> under opencode-serve-pool.target), so there is no
      # single unit to bounce and cycling the target kills every live session,
      # including the one running this switch.
      #
      # This block used to `systemctl --user restart opencode-serve.service`.
      # That unit has not existed here since the pool migration, so the restart
      # was a guaranteed exit-5 no-op — and because the hash file was only
      # written on restart SUCCESS, the failure path re-armed itself: every
      # subsequent switch would re-detect "state changed", warn again, and again
      # decline to persist the hash. Writing the hash unconditionally is what
      # makes this converge.
      old_hash=""
      [ -r "$hash_file" ] && old_hash="$(cat "$hash_file")"
      if [[ "$new_hash" != "$old_hash" || "$seeded" == "1" ]]; then
        echo "$new_hash" > "$hash_file"
        {
          echo "teamclaude: state changed (url hash $old_hash -> $new_hash, seeded=$seeded)."
          echo "teamclaude: config written — running serves keep the old provider init until they restart."
          echo "teamclaude:   automatic — nightly at 03:00 (nightly-restart-background.timer)"
          echo "teamclaude:   now, disruptive — reset-workspace   (kills all live sessions)"
        } >&2
      fi
    '');

  # Darwin flavor of injectTeamclaudeBaseUrl. Same marker predicate and the same
  # reasoning as the systemd flavor above — read that header, not repeated here.
  # This one used a loopback port probe (`nc -z 127.0.0.1 3456`), which is the
  # same bug shape: the probe samples state from before the switch restarts the
  # launchd agent, so a teamclaude the switch is about to start reads as down.
  # (The systemd ordering was verified in a built activate script; the darwin
  # equivalent was not -- no darwin builder here -- so this says "same shape"
  # rather than naming an exact node order.)
  #
  # Predicate is `teamclaude-seeded`, the same BINARY the launchd wrapper and the
  # devbox unit's ExecCondition run (pkgs/teamclaude). Not merely the same rule
  # written out three times -- the same executable, so the three sites cannot
  # drift. If you add a fourth consumer, call it rather than re-deriving it.
  #
  # Dummy-cred seed identical to the systemd path; no auto serve-restart (pool)
  # — the dummy cred's shape-only mode is decided at provider init, so a manual
  # `opencode-serve-pool-restart` is required to take effect.
  home.activation.injectTeamclaudeBaseUrlDarwin = lib.mkIf isDarwin
    (lib.hm.dag.entryAfter [ "mergeOpencode" ] ''
      set -euo pipefail
      runtime="$HOME/.config/opencode/opencode.json"

      # Decides the config. Order- and race-independent. Same accounts-non-empty
      # test as the systemd flavor -- see its comment for why mere file existence
      # is not enough.
      tc_enabled=0
      # TEAMCLAUDE_CONFIG is pinned here for the same reason the unit pins it:
      # this runs during a home-manager switch from whatever shell invoked it,
      # which may carry an XDG_CONFIG_HOME the service will never see. Without
      # the pin, activation and the service could resolve different files and
      # disagree about whether teamclaude is seeded.
      if TEAMCLAUDE_CONFIG="$HOME/.config/teamclaude.json" \
           ${localPkgs.teamclaude}/bin/teamclaude-seeded; then
        tc_enabled=1
      fi

      # Reported only, never decisive.
      tc_live="down"
      /usr/bin/nc -z -G2 127.0.0.1 3456 2>/dev/null && tc_live="up"

      anthropic_url=""
      if [[ "$tc_enabled" == 1 ]]; then
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

      echo "teamclaude(darwin): anthropic -> ''${anthropic_url:-<direct Anthropic>} (marker=$tc_enabled, port=$tc_live)" >&2
      [[ -n "$anthropic_url" ]] && echo "teamclaude(darwin): run 'opencode-serve-pool-restart' to apply to running serves" >&2 || true
    '');

  # Point opencode's `google-vertex-anthropic` provider at the local cfp router
  # (:8789) on macOS, so Claude traffic goes Max-first with a Vertex fallback
  # instead of straight to work-billed Vertex.
  #
  # WHY THIS EXISTS SEPARATELY FROM THE TEAMCLAUDE BLOCK ABOVE. Those two blocks
  # aim at different providers and only one of them is now reachable: `anthropic`
  # is in `disabled_providers` on darwin (see the managed config above), so
  # everything that block writes is INERT while that stays true.
  #
  # It is retained only so that removing `anthropic` from disabled_providers is a
  # one-line rollback rather than a restoration project. Do NOT retain it for the
  # reason an earlier draft of this comment gave -- that its dummy oauth
  # credential still stops the @ex-machina plugin from refreshing and rotating
  # teamclaude's grant family out from under it. Review checked that claim and it
  # is false: opencode skips a disabled provider's plugin auth loader entirely,
  # and the plugin's refresh lives inside the `fetch` that loader returns, so
  # with no loader there is no refresh to suppress.
  #
  # cfp only accepts VERTEX-SHAPED paths (translate.ts MODEL_REGEX matches
  # /models/<id>:rawPredict|streamRawPredict), which is exactly why the router
  # sits behind google-vertex-anthropic and not behind `anthropic`. It cannot
  # take Anthropic-native /v1/messages.
  #
  # PREDICATE IS THE MARKER, NOT LIVENESS -- same argument as the teamclaude and
  # codex-lb blocks (beads workstation-k03x / workstation-m55p). A port probe
  # would read the PRE-switch state, and a switch taken while cfp happened to be
  # down would strip the baseURL and silently send every Claude turn direct to
  # billed Vertex, which is precisely the state this change exists to end. The
  # marker `teamclaude-seeded` is the right one because it is also what the cfp
  # launchd agent gates on: if there is no Max pool, cfp does not start and there
  # is nothing to point at.
  #
  # Unseeded => strip => direct Vertex. That is the status quo ante and is safe
  # here ONLY because the Mac's Vertex leg is direct anyway (no aigateway, no
  # tunnel by deliberate choice), so a strip loses the Max routing but not a cost
  # ledger.
  #
  # GEMINI IS DELIBERATELY UNTOUCHED. cfp is anthropic-only and never routes
  # gemini; google-vertex stays on its built-in direct path, which also keeps the
  # Mac's PRIMARY model independent of whether cfp is healthy.
  home.activation.injectCfpBaseUrlDarwin = lib.mkIf isDarwin
    (lib.hm.dag.entryAfter [ "mergeOpencode" ] ''
      set -euo pipefail
      runtime="$HOME/.config/opencode/opencode.json"

      cfp_enabled=0
      if TEAMCLAUDE_CONFIG="$HOME/.config/teamclaude.json" \
           ${localPkgs.teamclaude}/bin/teamclaude-seeded; then
        cfp_enabled=1
      fi

      # Reported only, never decisive.
      cfp_live="down"
      /usr/bin/nc -z -G2 127.0.0.1 8789 2>/dev/null && cfp_live="up"

      # macOS keeps this in the login Keychain; the NixOS hosts read it from
      # /run/secrets/google_cloud_project.
      project="$(/usr/bin/security find-generic-password -s google-cloud-project -w 2>/dev/null || true)"

      anthropic_url=""
      if [[ "$cfp_enabled" == 1 && -n "$project" ]]; then
        # 127.0.0.1, not "localhost": cfp binds IPv4 and localhost may resolve
        # to ::1. Trailing /models is required -- @ai-sdk/google-vertex appends
        # only /<id>:streamRawPredict to it.
        anthropic_url="http://127.0.0.1:8789/v1/projects/$project/locations/global/publishers/anthropic/models"
      elif [[ "$cfp_enabled" == 1 ]]; then
        echo "cfp(darwin): no google-cloud-project in Keychain; leaving claude on direct Vertex" >&2
      fi

      if [[ -f "$runtime" ]]; then
        tmp="$(mktemp "''${runtime}.tmp.XXXXXX")"
        ${pkgs.jq}/bin/jq --arg a "$anthropic_url" '
            (if $a == "" then del(.provider."google-vertex-anthropic".options.baseURL)
             else .provider."google-vertex-anthropic".options.baseURL = $a end)
          | (if (.provider."google-vertex-anthropic".options // {}) == {}
             then del(.provider."google-vertex-anthropic".options) else . end)
          | (if (.provider."google-vertex-anthropic" // {}) == {}
             then del(.provider."google-vertex-anthropic") else . end)
          | (if (.provider // {}) == {} then del(.provider) else . end)' \
          "$runtime" > "$tmp"
        mv "$tmp" "$runtime"
      fi

      echo "cfp(darwin): claude -> ''${anthropic_url:-<direct Vertex>} (marker=$cfp_enabled, port=$cfp_live)" >&2

      # The marker and the process can disagree, and only one direction hurts:
      # config says :8789 while nothing listens there means every Claude request
      # gets ECONNREFUSED. The launchd agent's StartInterval heals this within
      # 30s, so this is a heads-up rather than an error -- but say it out loud,
      # because the alternative is a silent outage whose cause (a first-ever
      # `teamclaude login` after the agent had already exited 0) is days behind
      # the symptom.
      if [[ -n "$anthropic_url" && "$cfp_live" == "down" ]]; then
        {
          echo "cfp(darwin): WARNING - pointing opencode at :8789 but nothing is listening yet."
          echo "cfp(darwin):   the agent retries every 30s; to apply immediately:"
          echo "cfp(darwin):   launchctl kickstart -k gui/\$(id -u)/org.nix-community.home.claude-failover-proxy"
        } >&2
      fi

      [[ -n "$anthropic_url" ]] && echo "cfp(darwin): run 'opencode-serve-pool-restart' to apply to running serves" >&2 || true
    '');

  # Point opencode's first-party `openai` provider at the local codex-lb rotator
  # when this host has OPTED IN to codex-lb (the ~/.codex-lb/enabled marker);
  # otherwise strip the override so the provider falls back to its default
  # (direct OpenAI). Note "opted in", not "currently running" — see the
  # PREDICATE section below, which is the whole design of this block. This is
  # the OpenAI/Codex analog of injectTeamclaudeBaseUrl above, but SIMPLER by
  # design:
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
  # tokens.
  #
  # THAT DELETE NOW FOLLOWS THE MARKER, NOT LIVENESS, and it is destructive, so
  # be precise about it: while the marker exists, every switch clears `.openai`
  # — INCLUDING when codex-lb is stopped or broken. Under the old liveness gate
  # a stopped codex-lb left the auth store alone. So if you `opencode auth login
  # openai` as a workaround while codex-lb is down, the next switch will wipe
  # that credential. Recoverable by logging in again (codex-lb's own tokens live
  # in its store.db and are never touched), but it will surprise you once.
  # Remove the marker if you actually want to go direct.
  #
  # NO AUTO SERVE-RESTART. Both NixOS hosts run a serve POOL
  # (opencode-serve@<port>, X-SwitchMethod=keep-old) under
  # opencode-serve-pool.target, so home-manager does not cycle the serves on
  # switch and there is no single unit to bounce. Rather than kill live pool
  # sessions, we just write the config + clear the auth entry and print the
  # apply command; running serves pick it up on their next natural restart.
  #
  # This was once described as a "deliberate divergence from
  # injectTeamclaudeBaseUrl". It is not, any more: every activation site that
  # named opencode-serve.service has now dropped its restart, so this is the
  # house policy rather than an exception to it.
  # THE PREDICATE IS "IS CODEX-LB CONFIGURED TO RUN HERE", NOT "IS IT UP RIGHT
  # NOW". That distinction is the whole point of this block, and getting it
  # wrong cost a live outage on 2026-09-13 (bead workstation-k03x).
  #
  # What went wrong: this used to gate on `systemctl --user is-active
  # codex-lb.service`. home-manager runs file activation BEFORE sd-switch starts
  # changed units, so on any switch where codex-lb happened to be down
  # beforehand — a reboot, a crash, a failed unit, or a version bump that left
  # it stopped — the probe saw `failed`, deleted the baseURL, and systemd then
  # started codex-lb successfully seconds later. Result: a healthy codex-lb that
  # opencode was not pointed at, with `openai/*` silently going direct to
  # api.openai.com (on cloudbox, with no key at all). It stayed that way until
  # somebody ran a second switch, because nothing re-evaluates this until then.
  #
  # Moving the DAG node after `reloadSystemd` would fix that particular
  # ordering, but it would still be the wrong instrument: we are writing a
  # DURABLE config file that serves read on their next restart, potentially
  # hours later, so a point-in-time liveness sample is not what should decide
  # its contents. A transient codex-lb outage must not rewrite config.
  #
  # So the predicate is the same one the UNIT itself uses: the opt-in marker
  # `~/.codex-lb/enabled` (`ConditionPathExists` on the unit). Marker present =>
  # this host intends to route OpenAI through codex-lb => write the baseURL,
  # regardless of whether the process happens to be running this second. Marker
  # absent => genuinely opted out => strip. This is order-independent, so it
  # cannot race sd-switch no matter where the node lands in the DAG.
  #
  # Consequence worth stating plainly: if codex-lb is enabled but broken, we now
  # point opencode at a dead port instead of falling back to direct OpenAI. That
  # is deliberate, and it costs less than it sounds like — the fallback was
  # already not real on either host. cloudbox has no OPENAI_API_KEY at all. On
  # devbox the key is exported only by the interactive bashrc, NOT by the
  # opencode-serve pool units, and sessions live in that pool — so a pool
  # session going "direct" had no credential either. (Unverified: whether
  # opencode serve can source the key from somewhere else entirely.) Either way
  # astra/sol/terra/luna exist only on codex-lb and were dead regardless.
  #
  # A broken codex-lb is a thing to fix, not a thing to silently reroute around,
  # and it now self-heals the moment the service comes back rather than needing
  # a switch.
  #
  # Liveness is still PROBED, but only to report it. See the log line below.
  # The `codexLbEnableMarker` edge is load-bearing on devbox, where that node
  # CREATES the marker declaratively. Without it the two nodes are unordered and
  # today's correct sequence is a toposort accident of alphabetical attribute
  # order -- rename either one and a fresh devbox strips on its first switch.
  # Naming a node that does not exist on a host is harmless (home-manager's DAG
  # resolves `after` by name match, so a dangling name simply never matches), so
  # this is safe on cloudbox where the marker is hand-made.
  home.activation.injectCodexLbBaseUrl = lib.mkIf (isDevbox || isCloudbox)
    (lib.hm.dag.entryAfter [ "mergeOpencode" "codexLbEnableMarker" ] ''
      set -euo pipefail

      runtime="$HOME/.config/opencode/opencode.json"

      export XDG_RUNTIME_DIR="''${XDG_RUNTIME_DIR:-/run/user/$UID}"
      sc=/run/current-system/sw/bin/systemctl

      # Decides the config. Order-independent.
      clb_enabled=0
      [[ -e "$HOME/.codex-lb/enabled" ]] && clb_enabled=1

      # Reported only, never decisive — see the header. May legitimately read
      # `failed`/`inactive` here on a switch that is about to start the unit.
      clb_state="$($sc --user is-active codex-lb.service 2>/dev/null || true)"

      openai_url=""
      openai_key=""
      if [[ "$clb_enabled" == 1 ]]; then
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

      # Force apiKey mode: drop any .openai entry from the auth store so the
      # provider uses the throwaway local bearer instead of the user's own ChatGPT
      # token (which would fight codex-lb's server-side injection). Enforced on
      # every switch while the codex-lb MARKER exists (not merely while the
      # service is up), so a stray `opencode auth login` can't reintroduce oauth
      # mode. See the destructive-side-effect note in the header.
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

      echo "codex-lb: openai -> ''${openai_url:-<direct OpenAI>} (marker=$clb_enabled, unit=''${clb_state:-unknown})" >&2
      if [[ -n "$openai_url" ]]; then
        echo "codex-lb: config written — restart your opencode serve(s) to apply (devbox: systemctl --user restart 'opencode-serve@*.service')" >&2
        # Not an error: activation runs before sd-switch starts units, so a
        # not-yet-active reading here is the NORMAL case on a switch that is
        # about to start codex-lb. Say so, so nobody reads it as the old bug.
        case "$clb_state" in
          active|activating) ;;
          # sd-switch will NOT start a unit that is already `failed` when its
          # unit file has not changed (e.g. the start-limit burst was hit), so
          # unlike `inactive` this one does not resolve itself.
          failed) echo "codex-lb: unit is FAILED and this switch will not start it — run: systemctl --user reset-failed codex-lb.service && systemctl --user start codex-lb.service" >&2 ;;
          *) echo "codex-lb: unit reads ''${clb_state:-unknown} right now — expected if this switch is about to start it; if openai/* still fails afterwards, check: systemctl --user status codex-lb" >&2 ;;
        esac
      fi
    '');

  # Darwin flavor of injectCodexLbBaseUrl. Same predicate and the same reasoning
  # as the NixOS flavor above — read that header, it is not repeated here.
  #
  # This one gated on a loopback port probe (`nc -z 127.0.0.1 2455`) — liveness
  # at its most literal — and has the SAME shape of bug, not a worse one: this
  # activation node runs before `setupLaunchAgents`, which is what boots the
  # agent out and back in, so the probe samples PRE-switch state and a codex-lb
  # that the switch is about to start reads as down. (An earlier draft of this
  # comment claimed `RunAtLoad` additionally made the plist start concurrently
  # with this script; review found that wrong — the load happens strictly after
  # this node. The fix is unaffected, but the reasoning was.)
  #
  # The marker file is the same opt-in the launchd wrapper itself tests
  # (`[ -e "$HOME/.codex-lb/enabled" ] || exit 0` in home.darwin.nix), so both
  # flavors now agree on one predicate. Keep them agreeing.
  #
  # No auto serve-restart: the Mac runs an opencode-serve POOL, so we write
  # config + clear the auth entry and print the apply command; run
  # `opencode-serve-pool-restart` to pick it up.
  home.activation.injectCodexLbBaseUrlDarwin = lib.mkIf isDarwin
    (lib.hm.dag.entryAfter [ "mergeOpencode" ] ''
      set -euo pipefail
      runtime="$HOME/.config/opencode/opencode.json"

      # Decides the config. Order- and race-independent.
      clb_enabled=0
      [[ -e "$HOME/.codex-lb/enabled" ]] && clb_enabled=1

      # Reported only, never decisive.
      clb_live="down"
      /usr/bin/nc -z -G2 127.0.0.1 2455 2>/dev/null && clb_live="up"

      openai_url=""
      openai_key=""
      if [[ "$clb_enabled" == 1 ]]; then
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

      echo "codex-lb(darwin): openai -> ''${openai_url:-<direct OpenAI>} (marker=$clb_enabled, port=$clb_live)" >&2
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
        echo "opencode MCP: datadog not configured (optional) -- no 'dd-pat' in Keychain; omitting mcp.datadog." >&2
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
        echo "opencode MCP: datadog not configured (optional) -- no dd_pat in sops; omitting mcp.datadog." >&2
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
