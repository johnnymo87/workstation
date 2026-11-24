# Moving this pin onto the running goose is goose-cutover's job (pkgs/goose-cutover; no-op rehearsal 2026-11-22).
# goose CLI, pinned to a release of the johnnymo87/goose fork: an upstream goose
# release plus a few local patches, built by upstream's own Linux CLI workflow
# (.github/workflows/patched-release.yml on the fork's patched/<version> branch).
# This is the PIN: what the next cutover approves. On the NixOS hosts nothing
# runs it directly; goose-serve and the user's `goose` both exec
# /var/lib/goose/current, which only goose-link moves (L6,
# modules/goose-current.nix), so merging a bump here changes no running goose
# binary on NixOS hosts (config files do change on the next home-manager switch
# after merge).
# One binary,
# because the serve and the CLI share ~/.local/share/goose/sessions/sessions.db,
# and a version gap between two writers of that DB is how a stale-schema panic
# starts.
#
# THE PATCHES (fork branch patched/v1.60.2, on top of tag v1.60.2; all platforms):
#
# CARRIED / REWRITTEN FOR v1.60.2:
#   2. GCP_VERTEX_HOST / GCP_VERTEX_SESSION_HEADER: the gcp_vertex_ai provider's
#      host was hard-coded to Google's endpoints. These point it at a local proxy
#      speaking the Vertex paths (claude-failover-proxy) and name the session
#      header that proxy keys stickiness on (commit 99e868bbc).
#   3. GCP_AUTH_SCOPES: the scopes goose requests when refreshing gcloud ADC
#      credentials (upstream: cloud-platform only). A gateway that attributes
#      requests by identity needs userinfo.email too (commit c9153313f).
#   5. acp-http GET /acp with `Acp-Takeover: 1` takes over a held SSE stream
#      instead of answering 409 (HTTP transport only, commit 69753852a).
#   6. acp-http SSE event ids, a bounded per-stream replay ring, and
#      Last-Event-ID resume (HTTP transport only, commit 69753852a).
#   1-misc. Apache-2.0 notices and Nix dev shell (bindgenHook, cmake, gemm-f16
#      opt-level). Rusty V8 parts dropped: upstream #12952 replaced v8 with
#      Boa (commit 945134d6e).
#   7. A restored session keeps its stored prompt-cache TTL unless
#      GOOSE_CACHE_TTL is set globally (commit b3c32d5ed).
#   8. ACP `_goose/unstable/session/settings/set {sessionId, cacheTtl?, recipe?, rollingMemory?}`
#      pins a session's cache TTL and recipe (instructions + final_output),
#      live and persisted. Rewritten on state machine (R8, commits 9701f2b4b, 188b49116).
#   9. ACP session/prompt `_meta.goose.maxTurns` bounds that run's agent loop
#      and ends with stopReason `max_turn_requests` (R9, commits 9701f2b4b, 80ed74c8c).
#  11. self_compact_and_resume: an agent compacts its own context and continues
#      the same run with a resume prompt it wrote. Rewritten as a state-machine
#      Operation (R11, commit 8feb5d158); GOOSE_SELF_COMPACT=false still read
#      to opt out; never offered to recipe sessions or subagents.
#  12. Rolling memory (off unless configured per session or by env): folds
#      older history into a first-person memory at turn start. Rewritten as a
#      pre-inference Operation (R12, commits f03cbbe2d, e2b5080dd).
#  13. GOOSE_GLOBAL_SKILLS=false limits skill discovery to project skill dirs:
#      drops the config dir's skills/ and user-scope plugin skill dirs (commit 1c59ef7a2),
#      and goose's built-in skills (web-search, goose-doc-guide), which 1.60 otherwise
#      advertises to every session with an extension (patched-1.60.2.3, johnnymo87/goose#46).
#  14. MCP extension startup is bounded by GOOSE_EXTENSION_STARTUP_TIMEOUT
#      (default 25s) and a failed start kills the server's whole process group
#      (R14, commits b72aa6410, d73dc1f00). Parallel extension start absorbed upstream #12775.
#  15. ACP session/prompt reports failed turns with JSON-RPC -32603 `turn_failed`
#      carrying `data.kind` and `data.message` (R15, commits 444cfee71, a6551d64c;
#      adapted to upstream #13043 `data.reason: turn_failed`).
#  16. Subagent policy: GOOSE_SUBAGENT_ROLES_DIR is scanned first so repo files
#      cannot shadow a role; GOOSE_SUBAGENT_DEFAULT_RECIPE scopes delegates that
#      declare none; strict extension start on lease. Rewritten on state machine
#      (R16, commit 09c12e526; recipe extensions replacing parent absorbed upstream #12938).
#  19. gcp_vertex_ai: GCP_VERTEX_GEMINI_HOST overrides the host for Gemini
#      models only; GCP_VERTEX_SESSION_HEADER takes a comma-separated list;
#      GCP_VERTEX_PARENT_SESSION_HEADER sends a delegated subagent's parent
#      session id (commit 908a0a75b).
#  20. The system prompt stays fixed after session start. Subdirectory AGENTS.md
#      hints are delivered once in tool responses rather than rewriting the
#      system prompt, preserving cache; if compaction drops earlier tool results,
#      a hint returns with the first call into its directory (R20, commit ab13c5fff).
#  21. session/prompt accepts _meta.goose.messageId and stores the user message
#      under it; _goose/unstable/session/conversation/truncate_from_message
#      deletes that message and later history, refused while run active; clears
#      stale context usage (R21, commits 99841a02c, b85106c4d). Used for /undo.
#  22. Cache-miss breaker for Gemini delegates on the state machine: 10
#      consecutive model calls at >=50K prompt tokens with zero cache reads stop
#      the delegate with guidance to re-dispatch (R22, commits 573cf9377, d21fa7b08);
#      GOOSE_CACHE_MISS_BREAKER=off disables it, and GOOSE_CACHE_MISS_BREAKER_STEPS
#      and _MIN_CONTEXT knobs are still read.
#  23. A recipe's settings.thinking_effort (off|low|medium|high|max) overrides
#      the effort a delegate would inherit from its lead session (commit a31606546).
#  25. Claude thinking streams as it is generated: Anthropic SSE parser yields
#      each thinking_delta immediately instead of buffering to content_block_stop
#      (commits 1c7160156, 3e0fecf13, 747b7d452).
#
# DROPPED FROM 1.54 STACK:
#   1. GOOSE_HEADLESS_CACHE_TTL: dropped, no live consumer found.
#   4. developer/shell process-group kill: dropped in favor of upstream #12958
#      (developer/shell_process.rs ProcessTree puts shell in own process group
#      and sends kill(-pgid, SIGKILL) on cancel/timeout/drop).
#  10. ACP session/list two-phase query: absorbed by upstream #12940 (commit
#      22413aba4), which implements the same two-phase sort+limit query.
#  17. plugin .mcp.json streamable-HTTP entries: dropped, no live consumer found.
#  18. Provider stream polled during tool execution: dropped as obsolete on
#      the state machine (inference drains provider stream before tools run).
#  24. thinking.display="summarized" backport: absorbed by upstream #13029 (commit
#      e970eea8a, in v1.57.0+).
#
# AUTO-COMPACT TOKEN LIMIT DECISION:
#   Upstream v1.60.2 introduced DEFAULT_AUTO_COMPACT_TOKEN_LIMIT = 225,000 (#12790),
#   capping auto-compaction threshold at min(0.8, GOOSE_AUTO_COMPACT_TOKEN_LIMIT/limit).
#   For 1M context models (Opus 5.5), 1.54 compacted at 0.8 * 1M = 800k tokens; 225k
#   would compact ~3.5x earlier for long sessions. 1.54 does not read
#   GOOSE_AUTO_COMPACT_TOKEN_LIMIT (it read GOOSE_AUTO_COMPACT_THRESHOLD instead).
#   To preserve 1.54 behaviour, GOOSE_AUTO_COMPACT_TOKEN_LIMIT = "800000" is set in
#   gooseConfigSettings in users/dev/goose-config.nix (enforced in ~/.config/goose/config.yaml
#   for CLI and serve across all hosts) and in goose-serve Environment.
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
# patched-1.60.2.x (2026-11-22) ports the fork onto upstream v1.60.2 for Linux
# (aarch64-linux and x86_64-linux); state machine agent loop, schema 18; drops
# obsolete patches (1, 4, 10, 17, 18, 24); rewrites loop-bound patches (8, 9,
# 11, 12, 14, 15, 16, 20, 21, 22). Darwin (aarch64-darwin) stayed on
# patched-1.54.0.18 until patched-1.60.2.3 (bead workstation-6w7i.26.15). patched-1.60.2.3
# (2026-11-24) extends patch 13 to the built-in skills (johnnymo87/goose#46);
# no schema change.
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
  # Upstream ships a bare `goose` binary at the archive root (not bin/goose).
  # gnu, not musl: the gnu asset is the one the integration was measured
  # against, and is what was already installed on both Linux hosts.
  #
  # Both NixOS hosts here are aarch64, so the x86_64 entry builds nowhere
  # today. It is kept because the hash is verified and a wrong-arch throw at
  # eval time is a worse failure than a pinned line nobody uses.
  #
  # Darwin follows the top-level pin again since patched-1.60.2.3 (bead
  # workstation-6w7i.26.15); an entry with its own version/tag holds a platform back.
  version = "1.60.2-patched.3";
  tag = "patched-1.60.2.3";

  # An entry carrying its own version/tag is held back (update-goose.yml leaves it alone);
  # the rest follow the top-level pin.
  platforms = {
    "aarch64-linux" = {
      asset = "goose-aarch64-unknown-linux-gnu.tar.gz";
      hash = "sha256-JfrgoXW3TXSA3Jvz1SqdDZi4dUf78IJ8yYeSBaLbTI4=";
    };
    "x86_64-linux" = {
      asset = "goose-x86_64-unknown-linux-gnu.tar.gz";
      hash = "sha256-OlRcvp+HHOHS3WfgUYv/9iQnVrCjyv5mHsTkw/MaLeg=";
    };
    "aarch64-darwin" = {
      asset = "goose-aarch64-apple-darwin.tar.gz";
      hash = "sha256-qIztYlEhahqYdf45VKieLzFCZNNnN438ak4w8/Pm6qA=";
    };
  };

  platformInfo =
    { inherit version tag; }
    // platforms.${stdenv.hostPlatform.system}
      or (throw "goose: no pinned release asset for ${stdenv.hostPlatform.system}");
in
stdenv.mkDerivation {
  pname = "goose";
  inherit (platformInfo) version;

  src = fetchurl {
    url = "https://github.com/johnnymo87/goose/releases/download/${platformInfo.tag}/${platformInfo.asset}";
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
