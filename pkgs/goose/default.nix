# goose CLI, pinned to a release of the johnnymo87/goose fork: an upstream goose
# release plus a few local patches, built by upstream's own Linux CLI workflow
# (.github/workflows/patched-release.yml on the fork's patched/<version> branch).
# Every goose on cloudbox runs THIS binary: the goose-serve unit below in
# hosts/cloudbox, and the user's `goose` via home.cloudbox.nix. One binary,
# because the serve and the CLI share ~/.local/share/goose/sessions/sessions.db,
# and a version gap between two writers of that DB is how a stale-schema panic
# starts.
#
# THE PATCHES (fork branch patched/v1.54.0, on top of tag v1.54.0):
#   1. GOOSE_HEADLESS_CACHE_TTL (5m|1h): lets a headless `goose run` opt out of
#      upstream's clamp of the prompt-cache TTL to 5m. Upstream clamps because
#      burst-only runs cannot idle; a standing session resumed by a timer every
#      15+ minutes is the opposite case, and a 5m cache is always cold for it.
#   2. GCP_VERTEX_HOST / GCP_VERTEX_SESSION_HEADER: the gcp_vertex_ai provider's
#      host was hard-coded to Google's endpoints. These point it at a local proxy
#      speaking the Vertex paths (claude-failover-proxy) and name the session
#      header that proxy keys stickiness on.
#   3. GCP_AUTH_SCOPES: the scopes goose requests when refreshing gcloud ADC
#      credentials (upstream: cloud-platform only). A gateway that attributes
#      requests by identity needs userinfo.email too.
# Patches 1-3 are inert unless their variables are set.
#   4. developer/shell: cancel, timeout and drop terminate the command's whole
#      process group (SIGTERM, 2s grace, SIGKILL). Upstream killed only the
#      direct child, so a cancelled `sleep`/build left orphans running.
#   5. acp-http GET /acp with `Acp-Takeover: 1` takes over a held SSE stream
#      instead of answering 409 (HTTP transport only).
#   6. acp-http SSE event ids, a bounded per-stream replay ring, and
#      Last-Event-ID resume (HTTP transport only). 5 and 6 are advertised in an
#      `Acp-Stream-Features: takeover, replay` response header and only change
#      behaviour for a client that sends those headers; the honk relay
#      (johnnymo87/honk) depends on them. The WebSocket transport is unchanged.
#   7. A restored session keeps its stored prompt-cache TTL unless
#      GOOSE_CACHE_TTL is set globally (upstream re-derived it from global
#      config on every restore, so a session pinned to 1h fell back to 5m).
#   8. ACP `_goose/unstable/session/settings/set {sessionId, cacheTtl?, recipe?}`
#      pins a session's cache TTL and recipe (instructions + final_output),
#      live and persisted; validated before anything changes; idempotent.
#   9. ACP session/prompt `_meta.goose.maxTurns` bounds that run's agent loop
#      (ACP otherwise always uses the global limit, default 1000).
#   7-9 let a timer-driven coordinator run its standing recipe sessions through
#   goose-serve (via honk) the way `goose run --recipe --resume` did. 8 and 9
#   change nothing for a client that does not send them; 7 only matters for a
#   session that stores a TTL (all such rows today are 1h coordinator sessions).
#  10. ACP session/list sorts and limits on session ids before fetching full
#      rows (recipe_json etc.), so a page takes ~0.01s instead of ~1.5s with
#      500+ sessions. Same rows, same order.
#  11. self_compact_and_resume: an agent compacts its own context and continues
#      the same run with a resume prompt it wrote (delivered as a steer-flagged
#      user message, so ACP clients see one run). Off with GOOSE_SELF_COMPACT=false;
#      never offered to recipe sessions (response schema/final_output or retry),
#      subagents, or providers that manage their own context.
#  12. Rolling memory (off unless configured per session or by env): folds
#      older history into a first-person memory at turn start.
#  13. GOOSE_GLOBAL_SKILLS=false limits skill discovery to project skill dirs:
#      it also drops the config dir's skills/ and user-scope plugin skill dirs.
#      Any value other than true/false counts as false; unset is upstream
#      behaviour. The maven-renovate lane relies on it.
#  14. MCP extension startup is bounded by GOOSE_EXTENSION_STARTUP_TIMEOUT
#      (default 25s; upstream waited forever for `initialize`), a failed start
#      kills the server's whole process group, and session/load starts stored
#      extensions in parallel. honk's per-session `/mcp` (honk#18) relies on it:
#      a hung server (e.g. mcp-remote waiting for OAuth) no longer freezes the
#      session's tool calls or every later reload.
#  15. ACP session/prompt reports a failed turn in `_meta.goose.turnError`
#      {kind, message}: most provider failures otherwise end as assistant text
#      with stopReason end_turn. honkd records it per session and the nvim
#      pickers show the session as errored (honk-9qf.15.11.3). Absent on
#      clean and cancelled turns; a client that ignores `_meta` sees no change.
#  16. Subagent policy (inert unless set): GOOSE_SUBAGENT_ROLES_DIR is scanned
#      first so repo files cannot shadow a role; a delegated recipe's declared
#      extensions replace the parent's (port of upstream #12938, not in 1.54);
#      GOOSE_SUBAGENT_DEFAULT_RECIPE scopes delegates that declare none (ad-hoc,
#      agent .md) and fails closed; with it set, a subagent extension that fails
#      to start fails the delegate. Used by users/dev/goose-roles.nix.
#  17. A plugin's .mcp.json may declare streamable-HTTP servers (type "http" or
#      "streamable-http", or a url with no command), and its entries are parsed
#      one at a time: upstream dropped EVERY server in the plugin when one entry
#      lacked a command. Project plugins (<cwd>/.agents/plugins) may only reach
#      localhost/loopback urls, so a cloned repo cannot trigger goose's browser
#      OAuth wait against a remote server; url and headers are never expanded.
#  18. The provider's response stream is read on its own task while tools run.
#      Upstream's legacy agent loop left the HTTP body unpolled during a tool,
#      and reqwest's 600s read_timeout then failed the rest of an already-sent
#      response: any tool call of 10+ minutes ended in "Network error: Stream
#      decode error ... Please resend your message to try again."
#  19. gcp_vertex_ai: GCP_VERTEX_GEMINI_HOST overrides the host for Gemini
#      (Google-published) models only, so Claude can stay on GCP_VERTEX_HOST
#      (cfp) while Gemini goes to aigateway; GCP_VERTEX_SESSION_HEADER takes a
#      comma-separated list; GCP_VERTEX_PARENT_SESSION_HEADER sends a delegated
#      subagent's parent session id. Used by goose-serve in hosts/cloudbox.
#  20. The system prompt stays fixed after session start. A subdirectory
#      AGENTS.md found mid-session (by reading a file under it) is delivered
#      once as an assistant-audience message in the conversation, not by
#      rewriting the system prompt, which invalidated the provider's prompt
#      cache from the first token on every later turn. Delivered hints are
#      re-queued if compaction or another history replacement drops them.
#  21. session/prompt accepts _meta.goose.messageId and stores the user message
#      under it; _goose/unstable/session/conversation/truncate_from_message
#      {sessionId, messageId} -> {found} deletes that message and everything
#      after it (row boundary, no same-second hazard), refused while a run or
#      live voice is active, and clears the session's stale context usage.
#      Advertised as agentCapabilities._meta.goose.truncateFromMessage. honkd
#      uses it for /undo in honk chat.
#  22. Cache-miss breaker for Gemini delegates (port of opencode's
#      cache-miss-breaker, workstation#840): 10 consecutive model calls at
#      >=50K prompt tokens with zero cache reads stop the delegate, and the lead
#      is told to re-dispatch it once. GOOSE_CACHE_MISS_BREAKER=off disables it;
#      _STEPS / _MIN_CONTEXT override the thresholds (johnnymo87/goose#17).
#  23. A recipe's settings.thinking_effort (off|low|medium|high|max) overrides
#      the effort a delegate would inherit from its lead session; recipes without
#      it inherit as before. goose-roles sets high on every role, so a worker
#      lead launched at medium (`honk launch --effort medium`) keeps its roles at
#      high (johnnymo87/goose#18, workstation-6w7i.20).
#  24. Claude requests carry thinking.display = "summarized" (backport of
#      upstream #13029, in v1.57.0+). claude-opus-5-5 and other newer models
#      otherwise omit the thinking text, so goose stored signature-only blocks
#      and honk showed empty thinking (johnnymo87/goose#19,
#      workstation-6w7i.24).
#  25. Claude thinking streams as it is generated: the Anthropic SSE parser
#      yields each thinking_delta instead of buffering the block to
#      content_block_stop, so honk shows thinking before the reply instead of
#      after ~10 s of silence. Storage still merges to one signed block per
#      thinking block (johnnymo87/goose#20, workstation-6w7i.25).
#
# WHY A PINNED RELEASE AND NO AUTO-BUMP. The pigeon goose runner depends on
# measured facts about the ACP server: the /acp path, ?token= auth, the
# YYYYMMDD_N session-id format, extensionResults, run ids and steer. They were
# measured at 1.48.0 and RE-MEASURED at 1.54.0 + patches on 2026-10-09: a
# throwaway serve passed pigeon's goose-launch, goose-runner and goose-id-split
# probes. Bumping is a deploy action: back up sessions.db, bump, restart
# goose-serve in a window, re-run those probes. Session DB schema is 16 at both
# 1.48.0 and 1.54.0, so this particular bump needs no migration.
# patched-1.54.0.3 (2026-10-12) is the same v1.54.0 base with patches 4-6 added;
# the three pigeon probes passed against it on an isolated serve (2026-10-11).
# patched-1.54.0.4 (2026-10-13) adds patches 7-9 on the same base (fork PR
# johnnymo87/goose#2); no schema change.
# patched-1.54.0.5 (2026-10-15) adds patch 10 (fork PR johnnymo87/goose#3).
# patched-1.54.0.6 (2026-10-18) adds patches 11-12 (fork PRs johnnymo87/goose#5,
# #4); no schema change. On an isolated serve of this store path the pigeon
# goose-launch and goose-id-split probes passed and a real-model self-compaction
# ran as one run; goose-runner-probe crashes before reaching goose (it predates
# the adapter's allowedSenderIds option) identically against .5.
# patched-1.54.0.7 adds patch 13 (johnnymo87/goose#6); patched-1.54.0.8
# (2026-10-19) adds patch 14 (johnnymo87/goose#7); no schema change.
# patched-1.54.0.9 (2026-10-20) adds patch 15 (johnnymo87/goose#8); no schema
# change. patched-1.54.0.10 (2026-10-21) adds patch 16 (johnnymo87/goose#9);
# no schema change. patched-1.54.0.11 (2026-11-05) adds patch 17
# (johnnymo87/goose#10); no schema change. patched-1.54.0.12 (2026-11-16)
# adds patch 18 (johnnymo87/goose#11); no schema change. patched-1.54.0.13
# (2026-11-16) adds patch 19 (johnnymo87/goose#12); no schema change.
# patched-1.54.0.14 (2026-11-17) adds patch 20 (johnnymo87/goose#13); no
# schema change.
# patched-1.54.0.15 (2026-11-20) adds patch 21 (johnnymo87/goose#14); no
# schema change.
# patched-1.54.0.16 (2026-11-20) adds patches 22-23 (johnnymo87/goose#17,
# #18) and an aarch64-apple-darwin asset (#15, #16); no schema change.
# patched-1.54.0.17 (2026-11-21) adds patch 24 (johnnymo87/goose#19); no
# schema change.
# patched-1.54.0.18 (2026-11-21) adds patch 25 (johnnymo87/goose#20); no
# schema change.
#
# Release assets are byte-for-byte what upstream's workflow produces for the
# patched source (gnu, default features), so measurements of upstream behaviour
# still hold outside the patched lines.
#
# DARWIN (the Mac, workstation-6w7i.17). The aarch64-apple-darwin asset is
# upstream's bundle-macos.yml CLI build of the same patched source (default
# features, unsigned: a Nix fetch sets no quarantine attribute and the linker's
# ad-hoc signature is all Apple Silicon needs). Releases from patched-1.54.0.16
# on carry it; patched-1.54.0.15's was backfilled onto the existing release by
# the fork's patched-release-darwin.yml without touching its Linux assets.
# On the Mac, goose-serve (launchd, users/dev/home.darwin.nix) and the CLI
# (users/dev/goose-config.nix) run this package.

{ lib
, stdenv
, fetchurl
, autoPatchelfHook
}:

let
  version = "1.54.0-patched.18";
  tag = "patched-1.54.0.18";

  # Upstream ships a bare `goose` binary at the archive root (not bin/goose).
  # gnu, not musl: the gnu asset is the one the integration was measured
  # against, and is what was already installed on both Linux hosts.
  #
  # Both NixOS hosts here are aarch64, so the x86_64 entry builds nowhere
  # today. It is kept because the hash is verified and a wrong-arch throw at
  # eval time is a worse failure than a pinned line nobody uses.
  platforms = {
    "aarch64-linux" = {
      asset = "goose-aarch64-unknown-linux-gnu.tar.gz";
      hash = "sha256-A5zUgC8dD2Qp5gIgB/+KYrlPk7yhNNIPpV82lsx5rkU=";
    };
    "x86_64-linux" = {
      asset = "goose-x86_64-unknown-linux-gnu.tar.gz";
      hash = "sha256-vpvTIQq8Gm7W4Qw8a/0+Yea05v2wFkA5kTpWD87u/zE=";
    };
    "aarch64-darwin" = {
      asset = "goose-aarch64-apple-darwin.tar.gz";
      hash = "sha256-aWynNerl2diIrrHp4c3UTN704NdP3gVxrotPR0jK1p4=";
    };
  };

  platformInfo =
    platforms.${stdenv.hostPlatform.system}
      or (throw "goose: no pinned release asset for ${stdenv.hostPlatform.system}");
in
stdenv.mkDerivation {
  pname = "goose";
  inherit version;

  src = fetchurl {
    url = "https://github.com/johnnymo87/goose/releases/download/${tag}/${platformInfo.asset}";
    inherit (platformInfo) hash;
  };

  # ELF only. The darwin binary links only system libraries (/usr/lib,
  # /System), which every macOS has at the same paths.
  nativeBuildInputs = lib.optionals stdenv.hostPlatform.isLinux [ autoPatchelfHook ];
  buildInputs = lib.optionals stdenv.hostPlatform.isLinux [ stdenv.cc.cc.lib ];

  dontConfigure = true;
  dontBuild = true;
  # Prebuilt release binary: stripping it buys nothing and risks breaking it.
  dontStrip = true;

  unpackPhase = ''
    runHook preUnpack
    tar -xzf $src
    runHook postUnpack
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    install -m755 goose $out/bin/goose
    runHook postInstall
  '';

  # autoPatchelfHook rewrites the interpreter to the nix loader, so this must
  # run to confirm the result is actually executable -- a patchelf miss is
  # invisible until runtime otherwise. On darwin it is the check that the
  # unsigned binary execs at all. Cheap, and it is the whole point of
  # packaging rather than pointing at $HOME.
  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    $out/bin/goose --version
    runHook postInstallCheck
  '';

  meta = {
    description = "goose CLI: upstream release plus local patches, pinned to what the pigeon ACP integration was measured against";
    homepage = "https://github.com/johnnymo87/goose";
    mainProgram = "goose";
    platforms = lib.attrNames platforms;
  };
}
