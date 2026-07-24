# Cross-platform home-manager configuration
# Platform-specific code lives in home.linux.nix and home.darwin.nix
{ config, pkgs, lib, localPkgs, devenvPkg, assetsPath, isDarwin, isDevbox, isCloudbox, ... }:

let

  # Patched opencode targeting opencode v1.17.13. Patch set (main branch
  # of opencode-patched, see patches/apply.sh there):
  #   gemini-empty-parts, tool-fix, cache-thinking-skip, retry-cap, vim.
  # DROPPED for the 1.17 line (see workstation
  # docs/plans/2026-06-11-opencode-1.17-cutover-runbook.md):
  #   - prompt-loop-cache (#25367) + cache-aligned-compaction (#25100): cost-cache
  #     opts; dropped pending a measured cache-economics pass on 1.17 (whether they
  #     still help on the rewritten event-sourced loop is unverified; tracking-cache-costs).
  #   - eager-input-streaming: SUPERSEDED by upstream v1.17.2 transform.ts options()
  #     (sets toolStreaming=false for vertex/anthropic + non-claude anthropic).
  #   - instance-state-partition: FIXED UPSTREAM in v1.17.7 (commit 87c33b3, issue
  #     #29772 — plugin client calls reuse the active listener instance). Verified
  #     droppable via upstream regression test (Gate 1) + live Question-tool repro
  #     (Gate 2: 14 ask/reply round-trips, active plugin, 0 partition warnings).
  #   - mcp-reconnect: 1.17 remote MCP conn is oauth-aware; needs re-engineering. Deferred.
  # https://github.com/johnnymo87/opencode-patched
  # All 4 platforms built by the patched fork's CI
  #
  # Darwin gotcha: the darwin-*.zip assets must be ad-hoc codesigned by the
  # upstream CI or macOS kernels will SIGKILL the binary with "Killed: 9".
  # See opencode-patched/.opencode/skills/darwin-signing.md for the full
  # story (Bun 1.3.12 #29120 regression + the BUN_NO_CODESIGN_MACHO_BINARY
  # workaround in build-release.yml). If a hash bump here lands a binary
  # that dies on launch, the upstream workflow has regressed.
  opencode-platforms = {
    aarch64-linux = {
      asset = "opencode-linux-arm64.tar.gz";
      hash = "sha256-jUeXf36Bk+N4e1h/+NU6zhURZW/lBJ6PrTnMIndwBAU=";
      isZip = false;
    };
    aarch64-darwin = {
      asset = "opencode-darwin-arm64.zip";
      hash = "sha256-DMcEHDw9OVmyY35jtRmNIzmswLRCub88ZgzTgw1qh9o=";
      isZip = true;
    };
    x86_64-linux = {
      asset = "opencode-linux-x64.tar.gz";
      hash = "sha256-7IgsErIgRbez7WYnhnsKVRTfqXgposV4zxEZYB3FwBU=";
      isZip = false;
    };
    x86_64-darwin = {
      asset = "opencode-darwin-x64.zip";
      hash = "sha256-BztXdoRONcXrvYWmZb+BcPkKkYhQ0iyU1aGx4WDkGd8=";
      isZip = true;
    };
  };

  opencode = let
    # `upstreamVersion` is the OpenCode version we're patching. `patchedRevision`
    # bumps when we re-release the same upstream version with updated patches
    # (e.g. adding a new local patch). Release tag is
    # `v${upstreamVersion}-patched${patchedRevision == "" ? "" : ".${patchedRevision}"}`.
    # Bump `patchedRevision` (and the hashes above) for patch-only updates.
    # Bump `upstreamVersion` (and reset `patchedRevision` to "") for upstream
    # version bumps -- and check whether any patches in opencode-patched can be
    # dropped because they're now upstream (see check-sunset.yml in that repo).
    # CUTOVER DONE (2026-06-11): the old v1.16/1.17 "V2 DB corruption" HOLD was
    # CLEARED. The DB-corruption fears (subagent seq race #31072, destructive
    # migration #29908) were empirically disproven for our topology on real v1.17.2
    # (42-subagent stress: 0 orphans/0 missing/0 dup seq; old history loads; the
    # migration won't re-fire). Full evidence + the atomic-cutover procedure:
    #   docs/plans/2026-06-11-opencode-1.17-cutover-runbook.md
    #
    # ROLL-FORWARD (2026-07-06): now pins v1.17.13-patched (base upstream bumped
    # 1.17.7 -> 1.17.13, patchedRevision reset to "", hold moved to 1.17.13).
    # DROPPED integration-list-batch — UPSTREAMED: v1.17.13 Integration.list does
    # the bulk Map.groupBy(credentials.all(), integrationID) shape natively (the
    # "layer 1" half of the workstation-g3iy wedge fix; sunset target from bead
    # workstation-hbc3). The other 19 patches carry forward; 7 were rebased for
    # v1.17.13 context drift (retry-cap, sqlite-foreign-key-wrap, serve-lease,
    # bootstrap-disposed-filter, project-copy-debounce, event-log-gate,
    # available-cache — none upstreamed). available-cache ("layer 2") is still
    # needed: upstream >= v1.17.13 still recomputes the ~5k-model availability
    # projection per /api/model call. WARNING — the switch is NOT the same trivial
    # in-line bump as a patched.N: v1.17.13 ships 3 NEW upstream migrations over
    # 1.17.7 (20260622142730_simplify_session_context_epoch,
    # 20260622170816_reset_v2_session_state, 20260622202450_simplify_session_input)
    # that DELETE the V2 projection tables (session_message/event/event_sequence/
    # session_context_epoch/session_input/workspace) on first boot. Canonical
    # history (message/part tables) is UNTOUCHED, so this is a re-derivable
    # projection reset, but TEST-MIGRATE a DB copy and confirm old sessions still
    # render before the fleet switch (Phase 2 of the cutover runbook). Serves pick
    # up the new binary only on restart (nightly reset / manual switch).
    #
    # PATCHED.1 (2026-07-24, Phase 8 — bead workstation-mlve.3): now pins
    # v1.17.13-patched.1 (build-release.yml -f version=1.17.13 -f revision=1).
    # This ends the "no patched.N cut during Phases 0-8" hold — Phase 8 IS the
    # release. Adds THREE patches (removing tui-follow-owner, superseded), taking
    # the set to 21, so the attached TUI rides the opaque front door on a
    # SESSION-SCOPED /event stream instead of the /global/event firehose:
    #   session-door-routes (server ?session_ids= query field + session-scoped
    #     GET pending permissions/questions + POST questions/:qid/reply|reject
    #     routes + permissionRespond message parity + regenerated SDK gen),
    #   tui-door-attach (sdk.tsx scoped subscribe; drop pigeon /route self-resolve
    #     — the door owns ownership; D2 child-poll + fetch-on-reconnect reconcile
    #     so subagent prompts render without a no-replay hang; NEW-A min-open
    #     backoff reset + jitter; W5 session-scoped reply migration; attach.ts
    #     OPENCODE_FRONTDOOR_URL default),
    #   tui-door-tests (NEW-G client contract test + a build-release CI step that
    #     runs it — build-release ran no tests before).
    # Serves + attach TUIs pick up the new binary only on restart (nightly reset /
    # manual switch). Phase 9 will repoint attach's url at the door (:4700); the
    # door-side non-session-scopable routes (D4) stay in bead workstation-mlve.11.
    #
    # --- historical (1.17.7 hold line, patched.N revisions) ---
    # This pins v1.17.7-patched.11 (same upstream 1.17.7, build-release.yml
    # -f version=1.17.7 -f revision=11, staying on the 1.17.7 hold line). patched.11
    # adds ONE patch over patched.10, taking the set to 18:
    #   #17 compaction-bounded-load (bead workstation-g3iy): bound the prompt
    #     loop's per-iteration message load to the compaction window. Upstream
    #     filterCompactedEffect materializes the ENTIRE session history every
    #     loop step before discarding everything before the last completed
    #     compaction boundary; a 17k-part session froze devbox serve-0's main
    #     loop for minutes per touch (the recurring 2026-07-03 wedges). Lazy
    #     50-at-a-time paging stops at the boundary — O(window) not O(history),
    #     output identical. Serves pick it up only on restart.
    #
    # patched.10 history (same upstream 1.17.7, build-release.yml
    # -f version=1.17.7 -f revision=10). patched.10
    # added ONE patch over patched.9, taking the set to 17:
    #   #16 event-log-gate (bead workstation-bm1i): gate the durable event LOG
    #     (EventTable inserts in core/src/event.ts commitSyncEvent) behind a lazy
    #     read of OPENCODE_EXPERIMENTAL_WORKSPACES. In v1.17.7 every durable event
    #     commit unconditionally INSERTs a full event row (message.updated.1 =
    #     complete message snapshot -> O(n^2) bytes per long session; 2.8GB of a
    #     4.3GB opencode.db on devbox) plus a dup-check SELECT, synchronously
    #     inside the main-thread commit transaction — a workstation-g3iy wedge
    #     suspect. Only readers in v1.17.7 are the remote-workspace sync paths
    #     (unused here). EventSequenceTable (seq counters) still maintained.
    #     Mirrors upstream's later gate (commit b0017bf1b9); drop on cutover past
    #     it. Serves pick this up only on restart (nightly reset / manual).
    #
    # patched.9 history (same upstream 1.17.7, build-release.yml
    # -f version=1.17.7 -f revision=9). patched.9
    # added ONE patch over patched.8, taking the set to 16:
    #   #15 tui-follow-owner (bead workstation-yl00): make the attached TUI's live
    #     event stream FOLLOW a session that migrates serves mid-stream. The TUI
    #     subscribes to a per-PROCESS /global/event firehose pinned (at attach time)
    #     to whatever serve pigeon /route named then; attach-route-resolve only re-
    #     resolves /route at the START of an SSE attempt and a healthy /global/event
    #     attempt never ends on its own, so a session that migrates serves (serve-lease
    #     idle-migration / pool reshuffle) emits its later turns only on the NEW serve's
    #     bus while the TUI stays silently pinned to the old one — frozen until manual
    #     re-attach. (This is the REAL yl00 cause; the earlier #11 event-cold-start-
    #     directory patch fixed the instance-scoped /event handler, which the TUI does
    #     not use.) Fix extends attach-route-resolve: a pure confirm-twice/degrade-hard
    #     evaluateOwnerDrift() + a runSseAttempt() `poll` that re-checks /route every
    #     OPENCODE_OWNER_POLL_INTERVAL_MS (default 5000) against the attempt's OWN
    #     per-attempt signal (no AbortSignal.any off the long-lived parent — avoids the
    #     lyj0 leak); on a confirmed owner change it ends the attempt (drifted:true) so
    #     startSSE reconnects immediately to the new owner. Gated on a session id (no-op
    #     for a global TUI). Live TUIs pick this up only on restart (nightly reset /
    #     manual). NOTE: this is purely client-side; it does not stop migrations, it
    #     just follows them.
    #
    # patched.8 history (same upstream 1.17.7, build-release.yml
    # -f version=1.17.7 -f revision=8, staying on the 1.17.7 hold line). patched.8
    # adds TWO patches over patched.7, taking the set to 15:
    #   #14 bootstrap-disposed-filter (bead workstation-y69t): each `opencode attach`
    #     TUI held 30-65 churning idle conns to its serve because sync.tsx re-ran the
    #     full bootstrap() (~15 concurrent GETs) on EVERY server.instance.disposed
    #     event — unfiltered/undebounced. That event is a GlobalBus broadcast to ALL
    #     /global/event subscribers on a shared serve, so instance churn in other
    #     sessions/dirs fired a re-fetch storm in every co-located TUI; Node http's
    #     default 5s keepAliveTimeout held each burst's sockets idle. This was the
    #     dominant accumulation on the concentrated serve-0 (mid-day profile: 16 TUIs,
    #     ~900 conns, 2.5GB swap). Fix filters the re-bootstrap to this TUI's own
    #     directory+workspace (consistent with the server-side /event disposed gate)
    #     and 250ms-debounces it. NOTE: live TUIs pick this up only on restart
    #     (nightly reset / manual) — a profile switch updates the on-disk binary, not
    #     live processes.
    #   #13/M3.3 globalbus-maxlisteners (bead workstation-qjk4, commit 13e3747) was
    #     committed after the patched.7 build point, so it ships here too: uncaps the
    #     GlobalBus event-listener count (suppresses MaxListenersExceededWarning under
    #     N co-located TUIs).
    #
    # patched.7 history (same upstream 1.17.7, re-released 2026-06-24 via
    # build-release.yml -f version=1.17.7 -f revision=7, staying on the 1.17.7 hold
    # line). patched.7 fixes an `opencode attach` SSE reconnect connection LEAK in
    # the existing #10 attach-route-resolve patch (bead workstation-lyj0): the
    # reconnect loop shared one long-lived AbortController and never closed a
    # finished attempt's stream, so each reconnect leaked one ESTABLISHED connection
    # up to the per-origin pool cap (256). After a rolling serve restart, 18 idle
    # attach TUIs that all fell back to the default serve pinned ONE serve's event
    # loop with ~4600 connections (5.9GB RSS, /global/health timing out, slow new
    # session starts). New packages/tui/src/util/sse.ts runSseAttempt() runs each
    # (re)connect as a discrete attempt with its own controller (force-closed in
    # finally) + balanced abort bridge; resolveServeUrl + sdk.global.event take the
    # short-lived per-attempt signal (also kills the AbortSignal.any listener
    # accumulation / MaxListenersExceededWarning). NOTE: the running attach CLIENTS
    # pick this up only when each TUI restarts (nightly reset / manual) — a profile
    # switch updates the on-disk binary but not live processes. Patch set stays at 13.
    #
    # patched.6 history (same upstream 1.17.7, build-release.yml -f revision=6) added
    # TWO patches from the headless-serve wedge investigation, taking the set to 13:
    #   (a) #13 step-end-diff-bound (bead workstation-0lik, upstream #29762): bounds
    #       Snapshot.diffFull's jsdiff structuredPatch (was context:MAX_SAFE_INTEGER
    #       with no edit/time limit) that pinned one JS thread at 100% CPU (+~1GB
    #       alloc) on a full-file rewrite of a sub-2MB file at step-end summary time.
    #       New boundedFilePatch() composes a 1 MiB size pre-guard with jsdiff
    #       {maxEditLength:4000,timeout:1000ms}; on trip it omits the optional
    #       FileDiff.patch field (counts-only; consumers already guard typeof
    #       patch!=="string"). Does NOT address the distinct flat-RSS read-only-
    #       subagent spin variant (#32965).
    #   (b) #12 project-copy-debounce EXTENDED (bead workstation-wvv2): gate
    #       refreshAfterBoot behind OPENCODE_PROJECT_COPY_REFRESH_ON_BOOT — DEFAULT-
    #       OFF (unset / anything but "1" disables the per-boot O(#dirs) scan; ="1"
    #       restores the upstream every-boot behavior). Safe headless: source dirs
    #       self-register via Project.saveProjectDirectory on open, the Move Session
    #       dialog refreshes on demand, project identity is git-derived (not index-
    #       derived); the explicit refresh() API is untouched (gate is only at the
    #       boot entry). No cloudbox systemd-env step needed (binary default is off).
    #
    # patched.5 history (same upstream 1.17.7, re-released 2026-06-23 with
    # project-copy-debounce added on top of patched.4 — build-release.yml
    # -f version=1.17.7 -f revision=5). patched.5
    # adds #12 project-copy-debounce (bead workstation-sqd5): tames the 1.17.x
    # reconnect-storm wedge. ProjectCopy.refreshAfterBoot runs once per location
    # boot; a reconnect/poll storm fired N concurrent refreshes for the SAME
    # projectID, each with unbounded-concurrency fs.isDir + a `git worktree list`
    # subprocess per source dir (one refresh touched 136 dirs), blocking the Bun
    # event loop (RSS ~19.6 GB, HTTP wedge — serve-0 pinned >100% CPU, Recv-Q
    # climbing, GET /session timing out). Fix in packages/core/src/project/copy.ts:
    # a module-scope single-flight Map<projectID,Deferred> coalesces concurrent
    # refreshes per projectID (each location boot builds a FRESH Service via
    # LayerMap+Layer.fresh, so the dedup MUST be module-level), and
    # concurrency:"unbounded" -> REFRESH_CONCURRENCY=4 at both fan-out sites.
    # patched.4 carried serve-lease Fix C+D: Fix C (bead workstation-uzig) moves the
    # serve self-heartbeat OFF the agent event loop onto a worker_threads Worker so a
    # CPU-heavy turn can't starve it -> no false dead-serve / "session lease lost
    # mid-run"; Fix D (bead workstation-oqa1) re-acquires on a benign owner_generation
    # bump instead of dying. Both live inside serve-lease.patch. The 12-patch set is:
    # gemini-empty-parts, tool-fix, cache-thinking-skip, retry-cap, vim,
    # sqlite-foreign-key-wrap, event-session-scope (#7, x8wi), createnext-readback
    # (#8, mn9r M3), serve-lease (#9, mn9r M4), attach-route-resolve (#10, mn9r M7,
    # bead workstation-7zr7), event-cold-start-directory (#11, bead workstation-yl00 —
    # ?session_ids= gates session-scoped /event delivery on session-aggregate
    # membership instead of an exact-string directory match, fixing the cold-start
    # live-delivery race where an attached TUI missed pigeon-injected turns),
    # project-copy-debounce (#12, bead workstation-sqd5, above).
    # serve-lease adds serve-side session leases + the
    # OPENCODE_ROUTING_DB/OPENCODE_SERVE_ID flags; the WHOLE feature is gated on
    # OPENCODE_ROUTING_DB, so until M5 sets that env it is byte-behaviorally a no-op.
    # attach-route-resolve makes `opencode attach` pool-aware (self-resolve the
    # owning serve via pigeon GET /route + reconnect on SSE drop); it only activates
    # for `attach --session`, so default-TUI behavior is unchanged.
    # instance-state-partition.patch remains DROPPED (fixed upstream by 87c33b3).
    # NOTE: cloudbox is ~15-way multi-writer on the shared opencode.db, so a switch
    # that swaps the opencode binary should stop ALL opencode processes at once (serve
    # + every standalone TUI) from a plain SSH shell. Doing the switch from inside an
    # opencode session will kill that session mid-switch.
    upstreamVersion = "1.17.13";
    patchedRevision = "1";  # ".N" suffix — drop to "" on next upstream version bump
    tagSuffix = if patchedRevision == "" then "" else ".${patchedRevision}";
    releaseTag = "v${upstreamVersion}-patched${tagSuffix}";
    version = if patchedRevision == "" then upstreamVersion else "${upstreamVersion}.${patchedRevision}";
    # Cron hold: while non-empty, update-opencode-patched.yml tracks the highest
    # "v${opencodePatchedHold}-patched.N" release instead of releases/latest, so an
    # auto-bump can never carry us onto a new upstream line. Held at 1.17.7 to stay on
    # the current upstream line (the old 1.15 V2 DB-corruption hold is history; see the
    # cutover runbook). Set to "" to resume tracking the newest release. Greppable
    # marker only — it does not feed the derivation.
    opencodePatchedHold = "1.17.13";
    platformInfo = opencode-platforms.${pkgs.stdenv.hostPlatform.system};
  in pkgs.stdenv.mkDerivation {
    pname = "opencode-patched";
    inherit version;
    src = pkgs.fetchurl {
      url = "https://github.com/johnnymo87/opencode-patched/releases/download/${releaseTag}/${platformInfo.asset}";
      hash = platformInfo.hash;
    };
    nativeBuildInputs = [ pkgs.makeWrapper ]
      ++ lib.optionals platformInfo.isZip [ pkgs.unzip ]
      ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux [
        pkgs.autoPatchelfHook
      ];
    buildInputs = lib.optionals pkgs.stdenv.hostPlatform.isLinux [
      pkgs.stdenv.cc.cc.lib
    ];
    dontConfigure = true;
    dontBuild = true;
    dontStrip = true;
    unpackPhase = ''
      runHook preUnpack
    '' + lib.optionalString platformInfo.isZip ''
      unzip $src
    '' + lib.optionalString (!platformInfo.isZip) ''
      tar -xzf $src
    '' + ''
      runHook postUnpack
    '';
    installPhase = ''
      runHook preInstall
      mkdir -p $out/bin
      install -m755 bin/opencode $out/bin/opencode
      wrapProgram $out/bin/opencode \
        --prefix PATH : ${lib.makeBinPath [ pkgs.fzf pkgs.ripgrep ]}
      runHook postInstall
    '';
    meta = {
      description = "OpenCode with prompt caching and local patches";
      homepage = "https://github.com/johnnymo87/opencode-patched";
      mainProgram = "opencode";
    };
  };

  # Interactive opencode pooling (workstation-jiae): a shell "placer" behind a
  # gated shadow `opencode()` function (see programs.bash.initExtra). It pools a
  # fresh TUI / `-s` resume onto a pool serve via pigeon and self-hosts (today's
  # behavior) on any failure. Wired here (not flake.nix localPkgs) because it
  # needs the real `opencode` binary defined above. K (pool size) is baked from
  # serve-pool.nix so the placer's internal gate and the function gate agree
  # per host (cloudbox 4, devbox 2, darwin 2).
  servePool = import ./serve-pool.nix;
  servePoolK =
    if isCloudbox then servePool.forHost.cloudbox.k
    else if isDarwin then servePool.forHost.darwin.k
    else servePool.forHost.devbox.k;
  oc-pool-attach = pkgs.callPackage ../../pkgs/oc-pool-attach { inherit opencode; k = servePoolK; };

  # Azure CLI with msal 1.34.0 patch and azure-devops extension (work machines)
  # NOTE: azure-cli 2.79.0 ships msal 1.33.0 which has a bug where
  # `az login --use-device-code` crashes with "Session.request() got
  # an unexpected keyword argument 'claims_challenge'". Fixed in msal 1.34.0.
  # Remove this block when nixpkgs bumps azure-cli to >= 2.83.0.
  azureCliPatched = let
    msal134 = pkgs.python3Packages.msal.overridePythonAttrs (old: rec {
      version = "1.34.0";
      src = pkgs.python3Packages.fetchPypi {
        inherit (old) pname;
        inherit version;
        hash = "sha256-drqDtxbqWm11sCecCsNToOBbggyh9mgsDrf0UZDEPC8=";
      };
    });
    msal134Path = "${msal134}/${pkgs.python3.sitePackages}";
    msal133 = pkgs.python3Packages.msal;
    msal133Path = "${msal133}/${pkgs.python3.sitePackages}";
    azWithExts = pkgs.azure-cli.withExtensions (with pkgs.azure-cli.extensions; [
      azure-devops
    ]);
  in azWithExts.overrideAttrs (old: {
    postFixup = (old.postFixup or "") + ''
      for f in $out/bin/az $out/bin/.az-wrapped $out/bin/.az-wrapped_; do
        if [ -f "$f" ]; then
          substituteInPlace "$f" \
            --replace-quiet "${msal133Path}" "${msal134Path}"
        fi
      done
    '';
  });

  # bb-test-log: fetch the raw, untruncated test.log of a single target from a
  # BuildBuddy invocation. Built on top of the BuildBuddy enterprise HTTP API
  # (GetAction → GetFile). The bb CLI itself only exposes whole-build logs via
  # `bb view`, which is subject to the same UI/bazel truncation that drove us
  # to need this in the first place.
  #
  # Reads BUILDBUDDY_HOST and BUILDBUDDY_API_KEY from env. Both are provisioned
  # per-platform via the standard secrets pattern (sops on cloudbox, Keychain
  # on macOS). See assets/opencode/skills/using-buildbuddy/SKILL.md.
  bb-test-log = pkgs.writeShellApplication {
    name = "bb-test-log";
    runtimeInputs = [ pkgs.curl pkgs.jq ];
    text = ''
      usage() {
        cat >&2 <<USAGE
      Usage: bb-test-log <invocation-id-or-url> <target-label> [attempt]

      Fetch the raw test.log for a target from a BuildBuddy invocation and
      write it to stdout.

      Arguments:
        invocation-id-or-url  Either a bare UUID (e.g.
                              3be19ca0-7f9e-4ade-813f-05aec2f06cd2) or a full
                              invocation URL (e.g.
                              https://your-org.buildbuddy.io/invocation/UUID).
        target-label          Bazel label, e.g.
                              //path/to:test_target_name
        attempt               Optional 1-based attempt index. Defaults to
                              "last" (the most recent attempt). Useful when a
                              test was retried and you want a specific run.

      Environment:
        BUILDBUDDY_HOST       e.g. your-org.buildbuddy.io (no scheme).
        BUILDBUDDY_API_KEY    Org-scoped API key (header x-buildbuddy-api-key).

      Examples:
        bb-test-log "$URL" //some:test > /tmp/test.log
        bb-test-log "$INVOCATION_ID" //some:test 2 > /tmp/attempt2.log
      USAGE
        exit 2
      }

      if [ $# -lt 2 ]; then usage; fi
      if [ -z "''${BUILDBUDDY_API_KEY:-}" ]; then
        echo "bb-test-log: BUILDBUDDY_API_KEY is not set" >&2
        exit 2
      fi
      if [ -z "''${BUILDBUDDY_HOST:-}" ]; then
        echo "bb-test-log: BUILDBUDDY_HOST is not set" >&2
        exit 2
      fi

      invocation=$1
      label=$2
      attempt=''${3:-last}

      # Accept either a bare invocation ID or a full URL.
      if [[ "$invocation" == http*://*/invocation/* ]]; then
        invocation=''${invocation##*/invocation/}
        invocation=''${invocation%%[?#]*}
      fi

      api="https://''${BUILDBUDDY_HOST}/api/v1"
      auth_header="x-buildbuddy-api-key: ''${BUILDBUDDY_API_KEY}"

      # 1. List actions for the target → collect every attempt's test.log URI
      #    in chronological order (the API returns them in attempt order).
      selector=$(jq -nc --arg i "$invocation" --arg l "$label" \
        '{selector: {invocation_id: $i, target_label: $l}}')

      uris=$(curl -sS \
        -H "$auth_header" \
        -H 'Content-Type: application/json' \
        -d "$selector" \
        "$api/GetAction" \
        | jq -r '[.action[]
                  | select(.file)
                  | (.file[] | select(.name == "test.log").uri)] | .[]')

      if [ -z "$uris" ]; then
        echo "bb-test-log: no test.log found for $label in $invocation" >&2
        echo "  (target may not have run, may not be a test, or label may be wrong)" >&2
        exit 1
      fi

      if [ "$attempt" = "last" ]; then
        uri=$(echo "$uris" | tail -n1)
      else
        uri=$(echo "$uris" | sed -n "''${attempt}p")
        if [ -z "$uri" ]; then
          count=$(echo "$uris" | wc -l)
          echo "bb-test-log: no attempt #$attempt; available count: $count" >&2
          exit 1
        fi
      fi

      echo "bb-test-log: fetching $uri" >&2

      # 2. Stream the raw blob to stdout. The GetFile response body IS the
      #    file contents (no JSON wrapper), despite the JSON request.
      curl -sS \
        -H "$auth_header" \
        -H 'Content-Type: application/json' \
        -d "$(jq -nc --arg u "$uri" '{uri: $u}')" \
        "$api/GetFile"
    '';
  };
in
{
  # NOTE: home.username and home.homeDirectory are set per-host
  # (in flake.nix for Darwin, in home.linux.nix for NixOS devbox)

  # User packages
  home.packages = [
    # Self-packaged tools (in pkgs/, some auto-updated by CI)
    localPkgs.beads
    pkgs.pandoc
    opencode

    # Cloudflare Workers CLI
    pkgs.wrangler

    # Cloud-provider CLIs for boldco infra provisioning (Supabase, Vercel,
    # Clerk). All install binaries only — they authenticate at runtime from
    # env vars the user supplies; no secrets live in this config.
    pkgs.supabase-cli   # nixpkgs; binary `supabase`
    localPkgs.vercel    # pkgs/vercel (buildNpmPackage, current npm release)
    localPkgs.clerk     # pkgs/clerk (pinned release binary)
    pkgs.cloudflared    # nixpkgs; Cloudflare Tunnel (expose Clerk-gated demo)

    # Remote clipboard (gclpr client talks to macOS server over SSH tunnel)
    localPkgs.gclpr

    # Headless opencode session launcher
    localPkgs.opencode-launch

    # Identity-resolving `gh` wrapper for lgtm's multi-reviewer feature.
    # Dispatched review sessions invoke `lgtm-gh` (not `gh`) so the review
    # posts under the reviewer identity lgtm wrote into .lgtm-reviewer; it
    # resolves that login's PAT from ~/.config/lgtm/tokens/<login>.pat.
    # Active on cloudbox (where lgtm runs); harmless elsewhere.
    localPkgs.lgtm-gh

    # nvim wrapper with deterministic --listen socket (used by oc-auto-attach)
    localPkgs.nvims

    # Auto-attach launched sessions to nvim+tmux (calls into nvims via RPC)
    localPkgs.oc-auto-attach

    # GitHub CLI
    pkgs.gh

    # Google Workspace CLI
    localPkgs.gws

    # Repo-agnostic git worktree helper
    localPkgs.git-work

    # OpenCode usage and cost reporting
    localPkgs.oc-cost

    # Mobile shell (survives sleep/wake, network changes)
    pkgs.mosh

    # Other tools
    devenvPkg

    # JavaScript runtime (used by pigeon and other projects)
    pkgs.bun

    # Bazel BUILD/Starlark formatter + linter (bazelbuild/buildtools).
    # `buildifier` formats/lints BUILD files in the mono Bazel monorepo to
    # match what Gemini/CI enforce (`buildifier -r .`). Standalone Go binary
    # with no org-specific config, so it lives in the shared list (applies to
    # cloudbox and devbox alike) like the other generic CLIs above.
    pkgs.buildifier
  ]
  # Interactive opencode pooling placer (workstation-jiae). Only meaningful where
  # the gated shadow opencode() function exists (K>=2 hosts); the placer also
  # self-hosts when POOL_K<2, so this gate just avoids shipping a no-op binary.
  ++ lib.optionals (servePoolK >= 2) [
    oc-pool-attach
  ]
  # Linux-only tools (devbox, cloudbox). reset-workspace shells out
  # to systemd-run for cgroup re-exec and sudo systemctl restart, so it can't
  # even evaluate on Darwin under the newer stricter nixpkgs platform checks.
  ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux [
    localPkgs.reset-workspace
  ]
  # chatgpt-relay client CLI. `ask-question` POSTs prompts to
  # ask-question-server (running on macOS) over the localhost:3033 SSH
  # reverse tunnel, which exists on both NixOS hosts. The server/login halves
  # stay on macOS. See pkgs/ask-question + the using-chatgpt-relay skill.
  ++ lib.optionals (isDevbox || isCloudbox) [
    localPkgs.ask-question
  ]
  # Terraform CLI required by infra repositories on work hosts.
  ++ lib.optionals (isDarwin || isCloudbox) [
    localPkgs.terraform
  ]
  # Work tools (macOS + cloudbox only)
  ++ lib.optionals (isDarwin || isCloudbox) [
    # BuildBuddy CLI (Bazelisk wrapper + bb subcommands like login, view).
    # The bb-test-log helper below is the API-backed escape hatch for
    # fetching raw, untruncated per-target test logs.
    localPkgs.bb
    bb-test-log
    # Bazel mono repo needs zip at build time and java for ktlint execution.
    # rules_kotlin <2.3.0 falls back to system PATH for java:
    # https://github.com/bazelbuild/rules_kotlin/pull/1452
    pkgs.zip
    pkgs.jdk21
    # Cloud / Kubernetes
    azureCliPatched
    pkgs.awscli2       # AWS CLI (EKS kubeconfig credential plugin, ba exec SSO)
    pkgs.kubelogin     # Azure AD credential plugin for kubectl
    pkgs.kubectl       # Kubernetes CLI (for AKS clusters)
  ]
  # NOTE: dd-cli (Datadog CLI) is installed by home.activation.installDdCli
  # below as `dd-cli` in ~/.local/share/uv/tools/dd-cli/bin/dd-cli, symlinked
  # by uv onto $PATH. We deliberately do NOT install a wrapper named `dd`:
  # GNU coreutils ships its own `dd` (the disk-copy utility), and on agent-
  # spawned non-interactive shells the bundled coreutils ends up earlier on
  # PATH than ~/.nix-profile/bin, so any `dd`-named shim loses the race and
  # `dd <subcommand>` silently errors as a bad coreutils operand. Using a
  # unique entrypoint (`dd-cli`) sidesteps the precedence problem entirely
  # and works across every agent harness, not just opencode. See the
  # interactive `dd()` shell function in programs.bash.initExtra below for
  # the human-ergonomics shortcut.
  ;

  # Bazel user config (~/.bazelrc) — work machines only
  # Generated at activation time so the GCS remote-cache URL (which encodes
  # the GCP project name) can be templated in from sops/Keychain instead of
  # being hardcoded in source. Mirrors the generateNpmrc pattern below.
  home.activation.generateBazelrc = lib.mkIf (isDarwin || isCloudbox) (lib.hm.dag.entryAfter [ "writeBoundary" ] (let
    staticHeader = lib.concatStringsSep "\n" [
      "# Managed by home-manager — edits will be overwritten"
      ""
      "# Show test errors inline"
      "test --test_output errors"
      ""
      "# Local disk and repository caches"
      "common --disk_cache ~/bazel-diskcache --repository_cache ~/bazel-cache/repository"
      ""
    ];
    staticFooter = lib.concatStringsSep "\n" ([
      "common --remote_upload_local_results"
      ""
      "# Reap idle Bazel servers after 15 min (default 3h) to free RAM across worktrees"
      "startup --max_idle_secs=900"
      ""
      "# Cap Kotlin persistent workers to 1 per worktree (default can spawn 2-3)"
      "build --worker_max_instances=KotlinCompile=1"
      "test  --worker_max_instances=KotlinCompile=1"
      ""
      "# Evict idle workers if they collectively exceed 2.5 GB"
      "build --experimental_total_worker_memory_limit_mb=2500"
      "build --experimental_shrink_worker_pool"
      "test  --experimental_total_worker_memory_limit_mb=2500"
      "test  --experimental_shrink_worker_pool"
    ] ++ lib.optionals pkgs.stdenv.isLinux [
      ""
      "# NixOS: explicit PATH for sandbox — forwarding alone doesn't cover all action types"
      "build --action_env=PATH=/home/dev/.nix-profile/bin:/etc/profiles/per-user/dev/bin:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin"
      "build --host_action_env=PATH=/home/dev/.nix-profile/bin:/etc/profiles/per-user/dev/bin:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin"
      ""
      "# Auto-shutdown server when system is low on memory"
      "startup --shutdown_on_low_sys_mem"
    ]);
  in ''
    BAZELRC_PATH="$HOME/.bazelrc"
    rm -f "$BAZELRC_PATH"
    REMOTE_CACHE_URL=""

    ${if isCloudbox then ''
      SECRET_PATH="/run/secrets/bazel_remote_cache_url"
      if [ -r "$SECRET_PATH" ]; then
        REMOTE_CACHE_URL=$(cat "$SECRET_PATH")
      else
        echo "Warning: bazel remote cache URL secret not found at $SECRET_PATH"
      fi
    '' else ''
      if /usr/bin/security find-generic-password -s bazel-remote-cache-url -w >/dev/null 2>&1; then
        REMOTE_CACHE_URL=$(/usr/bin/security find-generic-password -s bazel-remote-cache-url -w)
      else
        echo "Warning: bazel remote cache URL not found in macOS Keychain (bazel-remote-cache-url)"
      fi
    ''}

    {
      cat <<'STATIC_HEADER_EOF'
${staticHeader}
STATIC_HEADER_EOF
      if [ -n "$REMOTE_CACHE_URL" ]; then
        echo "# GCS remote cache — shared across worktrees and machines"
        echo "# Local disk_cache is checked first (fast); remote is fallback + shared warming"
        echo "common --remote_cache=$REMOTE_CACHE_URL"
      else
        echo "# Remote cache URL not available; skipping --remote_cache"
      fi
      cat <<'STATIC_FOOTER_EOF'
${staticFooter}
STATIC_FOOTER_EOF
    } > "$BAZELRC_PATH"
  ''));

  # Azure DevOps npm registry auth (~/.npmrc) — work machines only
  # Uses npm's native ${ENV_VAR} interpolation; ADO_NPM_PAT_B64 is exported
  # in platform-specific bash init (home.cloudbox.nix / home.darwin.nix).
  # We generate the file at activation time to avoid hardcoding the ADO registry URL
  # (which contains the employer org/project name) in the Nix config.
  home.activation.generateNpmrc = lib.mkIf (isDarwin || isCloudbox) (lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    NPMRC_PATH="$HOME/.npmrc"
    rm -f "$NPMRC_PATH"
    REGISTRY_URL=""

    ${if isCloudbox then ''
      SECRET_PATH="/run/secrets/ado_npm_registry_url"
      if [ -f "$SECRET_PATH" ]; then
        REGISTRY_URL=$(cat "$SECRET_PATH")
      else
        echo "Warning: ADO npm registry secret not found at $SECRET_PATH"
      fi
    '' else ''
      if /usr/bin/security find-generic-password -s ado-npm-registry-url -w >/dev/null 2>&1; then
        REGISTRY_URL=$(/usr/bin/security find-generic-password -s ado-npm-registry-url -w)
      else
        echo "Warning: ADO npm registry URL not found in macOS Keychain (ado-npm-registry-url)"
      fi
    ''}

    if [ -n "$REGISTRY_URL" ]; then
      ORG_NAME=$(echo "$REGISTRY_URL" | cut -d/ -f4)
      cat > "$NPMRC_PATH" <<EOF
; begin auth token
$REGISTRY_URL/registry/:username=$ORG_NAME
$REGISTRY_URL/registry/:_password=\''${ADO_NPM_PAT_B64}
$REGISTRY_URL/registry/:email=npm requires email to be set but doesn't use the value
$REGISTRY_URL/:username=$ORG_NAME
$REGISTRY_URL/:_password=\''${ADO_NPM_PAT_B64}
$REGISTRY_URL/:email=npm requires email to be set but doesn't use the value
; end auth token
EOF
    else
      cat > "$NPMRC_PATH" <<EOF
; ADO npm registry URL secret not found during activation
; Add it to sops (Cloudbox) or Keychain (Darwin) and run rebuild
EOF
    fi
  '');

home.activation.deployGclprKey = lib.mkIf (!isDarwin) (
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      if [ -f /run/secrets/gclpr_private_key ]; then
        mkdir -p "$HOME/.gclpr"
        chmod 700 "$HOME/.gclpr"
        (
          umask 077
          ${pkgs.coreutils}/bin/base64 -d /run/secrets/gclpr_private_key > "$HOME/.gclpr/key.tmp"
        )
        mv -f "$HOME/.gclpr/key.tmp" "$HOME/.gclpr/key"
        chmod 400 "$HOME/.gclpr/key"
      else
        echo "deployGclprKey: skipping (secret not available)"
      fi
    ''
  );

home.activation.installMonoWorktreeGuardHook = lib.mkIf isCloudbox (
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      if [ ! -d "/home/dev/projects/mono/.git" ] && [ ! -f "/home/dev/projects/mono/.git" ]; then
        echo "installMonoWorktreeGuardHook: /home/dev/projects/mono/.git is not a git repo, skipping"
      else
        if ! ${pkgs.git}/bin/git -C /home/dev/projects/mono rev-parse --git-dir >/dev/null 2>&1; then
          echo "installMonoWorktreeGuardHook: /home/dev/projects/mono is not a git repo, skipping"
        else
          current_hooks_path="$(${pkgs.git}/bin/git -C /home/dev/projects/mono config --get core.hooksPath 2>/dev/null || true)"
          managed_hooks_dir="$HOME/.config/git-hooks"
          if [ -z "$current_hooks_path" ] || [ "$current_hooks_path" = "$managed_hooks_dir" ]; then
            ${pkgs.git}/bin/git -C /home/dev/projects/mono config core.hooksPath "$managed_hooks_dir"
            echo "installMonoWorktreeGuardHook: core.hooksPath set to $managed_hooks_dir"
          else
            echo "WARNING: installMonoWorktreeGuardHook: core.hooksPath is set to '$current_hooks_path', which differs from '$managed_hooks_dir'. Skipping installation to avoid clobbering."
          fi
        fi
      fi
    ''
  );

  # Install/update ba CLI from private GitHub release (work machines)
  # Downloads platform-appropriate binary, caches by version in ~/.local/bin
  # macOS: reads ba_cli_repo from Keychain, GH token from gh CLI auth
  # Cloudbox: reads both from sops-nix secrets at /run/secrets/
  home.activation.installBaCli = lib.mkIf (isDarwin || isCloudbox) (
    lib.hm.dag.entryAfter [ "writeBoundary" ] (let
      platform = if isDarwin then "darwin" else "linux";
      asset = "ba-${platform}-arm64.tar.gz";
    in ''
      ba_repo=""
      ${if isCloudbox then ''
        if [ -r /run/secrets/ba_cli_repo ]; then
          ba_repo="$(cat /run/secrets/ba_cli_repo)"
        fi
      '' else ''
        ba_repo="$(/usr/bin/security find-generic-password -s ba-cli-repo -w 2>/dev/null || true)"
      ''}

      if [ -z "$ba_repo" ]; then
        echo "installBaCli: skipping (ba_cli_repo not available)"
      else
        gh_token=""
        ${if isCloudbox then ''
          if [ -r /run/secrets/github_api_token ]; then
            gh_token="$(cat /run/secrets/github_api_token)"
          fi
        '' else ''
          gh_token="$(${pkgs.gh}/bin/gh auth token 2>/dev/null || true)"
        ''}

        if [ -z "$gh_token" ]; then
          echo "installBaCli: skipping (GitHub token not available)"
        else
          latest=$(GH_TOKEN="$gh_token" ${pkgs.gh}/bin/gh api \
            "repos/$ba_repo/releases/latest" --jq .tag_name 2>/dev/null || true)

          if [ -z "$latest" ]; then
            echo "installBaCli: WARNING: could not fetch latest release"
          else
            current=""
            if [ -x "$HOME/.local/bin/ba" ]; then
              # `ba --version` writes the version string to stderr (not stdout),
              # so we must merge with `2>&1` rather than discard with `2>/dev/null`.
              # Otherwise grep sees empty input, $current stays empty, the
              # equality check below always fails, and ba reinstalls on every
              # `home-manager switch`.
              current=$("$HOME/.local/bin/ba" --version 2>&1 \
                | ${pkgs.gnugrep}/bin/grep -oP 'v?\K[0-9]+\.[0-9]+\.[0-9]+' \
                | head -1 || true)
            fi

            if [ "$current" = "$latest" ]; then
              echo "installBaCli: ba $latest already installed"
            else
              echo "installBaCli: installing ba $latest (was: ''${current:-not installed})..."
              ${pkgs.coreutils}/bin/mkdir -p "$HOME/.local/bin"
              tmpdir=$(${pkgs.coreutils}/bin/mktemp -d)
              if GH_TOKEN="$gh_token" ${pkgs.gh}/bin/gh release download "$latest" \
                   --repo "$ba_repo" \
                   -p '${asset}' \
                   -D "$tmpdir" 2>/dev/null; then
                ${pkgs.gnutar}/bin/tar --use-compress-program=${pkgs.gzip}/bin/gzip -xf "$tmpdir/${asset}" -C "$tmpdir"
                ${pkgs.coreutils}/bin/install -m 755 "$tmpdir/ba" "$HOME/.local/bin/ba"
                echo "installBaCli: ba $latest installed"
              else
                echo "installBaCli: WARNING: download failed"
              fi
              ${pkgs.coreutils}/bin/rm -rf "$tmpdir"
            fi
          fi
        fi
      fi
    ''));

  # Default editor for all interactive shells.
  # NixOS sets EDITOR=nano in /etc/set-environment by default, which leaks into
  # GUI apps that read $EDITOR — notably the opencode TUI's `/export` slash
  # command (packages/opencode/src/cli/cmd/tui/util/editor.ts), which spawns
  # $VISUAL || $EDITOR. Without this override, /export opens nano.
  # home.sessionVariables is sourced by ~/.profile (login shells) and
  # propagates to anything launched from that shell, including opencode.
  home.sessionVariables = {
    EDITOR = "nvim";
    VISUAL = "nvim";
    # Raise opencode's default output-token cap from 32k to 64k. Per Anthropic
    # (https://docs.anthropic.com/en/build-with-claude/effort): "When running
    # Claude Opus 4.7/4.8 at xhigh or max effort, set a large max_tokens so the
    # model has room to think and act across subagents and tool calls.
    # Starting at 64k tokens and tuning from there is a reasonable default."
    # Pairs with the high adaptive default we set for opus 4.8 (and
    # claude-fable-5) in assets/opencode/opencode.base.json. This is a cap,
    # not a forced allocation: models still emit only what they want, but
    # high/xhigh runs no longer get truncated at 32k. Other models are
    # unaffected (their own model.limit.output still wins via Math.min in
    # packages/opencode/src/provider/transform.ts:1262). NOTE: this only
    # covers interactive shells (sourced via ~/.profile); the opencode-serve
    # systemd unit on devbox/cloudbox needs the same var added to its own
    # Environment list -- see hosts/{devbox,cloudbox}/configuration.nix.
    OPENCODE_EXPERIMENTAL_OUTPUT_TOKEN_MAX = "65536";
    # mn9r M2: pin opencode's SQLite DB to ONE absolute file so every writer
    # (serve, TUIs, pigeon revive, opencode-launch workers, lgtm run) resolves
    # the same database. opencode's resolver (storage/db.ts getPath) honours an
    # absolute OPENCODE_DB verbatim, bypassing the channel-suffixed default
    # (opencode-<channel>.db) that a from-source `bun run` or dev build would
    # otherwise write to -> latent split-brain (a stale opencode-local.db
    # already exists on cloudbox from exactly this). OPENCODE_DISABLE_CHANNEL_DB
    # is belt-and-suspenders for any path that ever leaves OPENCODE_DB unset.
    # Required by the K-serve pool (mn9r) where multiple serves share one DB.
    # NOTE: this only covers interactive shells (sourced via ~/.profile); the
    # systemd/launchd serve + pigeon units each need their own copy -- see
    # hosts/{devbox,cloudbox}/configuration.nix and home.{devbox,darwin}.nix.
    # Path matches Global.Path.data = xdgData/opencode (xdg-basedir falls back
    # to ~/.local/share on every platform incl. macOS absent $XDG_DATA_HOME).
    OPENCODE_DB = "${config.home.homeDirectory}/.local/share/opencode/opencode.db";
    OPENCODE_DISABLE_CHANNEL_DB = "1";
  } // lib.optionalAttrs (isDarwin || isCloudbox) {
    # Cap JetBrains kotlin-lsp JVM heap — each OpenCode session spawns its
    # own instance; without a cap they grow to ~1.5 GB each.
    # IJ_JAVA_OPTIONS is read by JetBrains tools only (not generic JVMs).
    IJ_JAVA_OPTIONS = "-Xms128m -Xmx1024m -XX:MaxMetaspaceSize=256m -XX:+UseSerialGC";
  };

  # Git
  programs.git = {
    enable = true;
    # Per-device SSH commit signing. Each host generates its own
    # ~/.ssh/id_ed25519_signing key (out-of-band; not deployed by nix).
    # GitHub verifies via the host's pubkey registered as a Signing Key;
    # local verification uses ~/.config/git/allowed_signers (see below).
    signing = {
      format = "ssh";
      key = "~/.ssh/id_ed25519_signing.pub";
      signByDefault = true;
    };
    ignores = [
      # lgtm (https://github.com/johnnymo87/lgtm) writes review dotfiles into
      # the worktree it dispatches against (.lgtm-context.md, .lgtm-reviewer,
      # .lgtm-review-prompt.md, .lgtm-rereview-prompt.md, plus attachments).
      # When lgtm reuses an existing worktree, these surface as untracked in
      # `git status`; ignore them globally so dev worktrees stay clean.
      ".lgtm-*"
    ];
    settings = {
      user.name = "Jonathan Mohrbacher";
      user.email = "jonathan.mohrbacher@gmail.com";
      init.defaultBranch = "main";
      push.autoSetupRemote = true;
      pull.rebase = true;
      "gpg \"ssh\"".allowedSignersFile = "~/.config/git/allowed_signers";
      diff.algorithm = "patience";  # Better diffs for code with repeated patterns
      rerere.enabled = true;        # Remember conflict resolutions for rebase
      # Use the gh CLI as the git credential helper for GitHub HTTPS remotes.
      # Lets headless services (e.g. cloudbox lgtm-run) clone/fetch via HTTPS
      # without SSH keys; interactive workflows over SSH (git@github.com:) are
      # unaffected. Reads GH_TOKEN if set, falls back to gh's auth.json.
      credential."https://github.com".helper = "!${pkgs.gh}/bin/gh auth git-credential";
      alias = {
        st = "status";
        co = "checkout";
        br = "branch";
        ci = "commit";
        lg = "log --oneline --graph --decorate";
      };
    };
  };

  # Allowed signers for git SSH-signature verification.
  # Lists every per-device SSH signing key trusted to sign as our identity.
  # Add a new line here when adding a new host or rotating a key, then re-apply.
  home.file.".config/git/allowed_signers".source = "${assetsPath}/git/allowed_signers";

  # Managed git hook for primary worktree protection (enforces committing in a
  # linked worktree only). Scoped to cloudbox, matching installMonoWorktreeGuardHook
  # (which sets core.hooksPath) and the cloudbox-only worktree-guard plugin/config.
  home.file.".config/git-hooks/pre-commit" = lib.mkIf isCloudbox {
    source = "${assetsPath}/git-hooks/pre-commit";
    executable = true;
  };

  # GPG - shared settings (both platforms)
  programs.gpg = {
    enable = true;
    package = pkgs.gnupg;  # Use nixpkgs GPG for consistency
    publicKeys = [
      {
        source = "${assetsPath}/gpg-signing-key.asc";
        trust = 5;  # ultimate (our own key)
      }
    ];
    settings = {
      auto-key-retrieve = true;
      no-emit-version = true;
      # NOTE: no-autostart is NOT here - it's Linux-only (see home.linux.nix)
    };
  };

  # Dirmngr config (keyserver) - manual file since dirmngrSettings not in our HM version
  home.file.".gnupg/dirmngr.conf".text = ''
    keyserver hkps://keys.openpgp.org
  '';

  # gclpr clipboard bridge public key
  home.file.".gclpr/key.pub" = lib.mkIf (!isDarwin) {
    source = "${assetsPath}/gclpr/key.pub";
  };

  # OpenCode session history search CLI
  home.file.".local/bin/oc-search" = {
    executable = true;
    text = ''
      #!${pkgs.bash}/bin/bash
      set -euo pipefail

      show_help() {
        cat <<'HELP_EOF'
      Usage: oc-search [OPTIONS] QUERY

      Search OpenCode session history for QUERY.

      Options:
        --types TYPES    Comma-separated list of part types to search (default: tool)
        --all            Search all part types (ignores --types)
        -h, --help       Show this help message
      HELP_EOF
      }

      types="tool"
      search_all=false
      query=""

      while [[ $# -gt 0 ]]; do
        case "$1" in
          -h|--help)
            show_help
            exit 0
            ;;
          --types)
            if [[ $# -gt 1 && ! "$2" == -* ]]; then
              types="$2"
              shift 2
            else
              echo "Error: --types requires an argument." >&2
              show_help >&2
              exit 1
            fi
            ;;
          --types=*)
            types="''${1#*=}"
            shift
            ;;
          --all)
            search_all=true
            shift
            ;;
          --)
            shift
            for arg in "$@"; do
              if [[ -n "$query" ]]; then
                echo "Error: Multiple queries provided." >&2
                show_help >&2
                exit 1
              fi
              query="$arg"
            done
            break
            ;;
          -*)
            echo "Unknown option: $1" >&2
            show_help >&2
            exit 1
            ;;
          *)
            if [[ -n "$query" ]]; then
              echo "Error: Multiple queries provided ('$query' and '$1')" >&2
              show_help >&2
              exit 1
            fi
            query="$1"
            shift
            ;;
        esac
      done

      if [[ -z "$query" ]]; then
        echo "Error: Search query is required." >&2
        show_help >&2
        exit 1
      fi

      DB_PATH="$HOME/.local/share/opencode/opencode.db"

      if [[ ! -f "$DB_PATH" ]]; then
        echo "Error: Database not found at $DB_PATH" >&2
        exit 1
      fi

      type_filter=""
      if [[ "$search_all" == false ]]; then
        IFS=',' read -ra type_array <<< "$types"
        in_list=""
        for t in "''${type_array[@]}"; do
          t_clean="''${t//\'/}"
          if [[ -z "$in_list" ]]; then
            in_list="'$t_clean'"
          else
            in_list="$in_list, '$t_clean'"
          fi
        done
        type_filter="AND json_extract(p.data, '$.type') IN ($in_list)"
      fi

      query_escaped="''${query//\'/\'\'}"

      # Execute SQLite query (pragmas use .output /dev/null to suppress echo)
      ${pkgs.sqlite}/bin/sqlite3 "file:$DB_PATH?mode=ro" <<SQL_EOF
      .output /dev/null
      PRAGMA query_only=ON;
      PRAGMA busy_timeout=2000;
      PRAGMA temp_store=MEMORY;
      PRAGMA cache_size=-65536;
      .output stdout
      .headers on
      .mode column
      WITH matched AS (
        SELECT
          p.session_id,
          COUNT(*) AS match_count,
          MAX(p.time_created) AS last_match_ms
        FROM part p
        WHERE instr(p.data, '$query_escaped') > 0
          $type_filter
        GROUP BY p.session_id
      )
      SELECT
        s.id,
        substr(s.title, 1, 40) AS title,
        substr(s.directory, 1, 45) AS directory,
        datetime(m.last_match_ms / 1000, 'unixepoch', 'localtime') AS last_match,
        m.match_count AS matches
      FROM matched m
      JOIN session s ON s.id = m.session_id
      ORDER BY m.last_match_ms DESC;
      SQL_EOF
    '';
  };

  # lgtm-sessions: list active OpenCode sessions dispatched by lgtm.
  # See lgtm-3j8 in ~/projects/lgtm beads tracker for design notes.
  home.file.".local/bin/lgtm-sessions" = {
    executable = true;
    text = ''
      #!${pkgs.bash}/bin/bash
      set -euo pipefail

      OPENCODE_URL="''${OPENCODE_URL:-http://127.0.0.1:4096}"
      # front-door cutover (Phase 7.5): the health check + session LIST are
      # data-plane reads and route through the opaque front door. The per-session
      # `opencode attach` HINT below stays direct-to-owner via GET /route (the
      # interactive TUI can't ride the door until Phase 8/9), so OPENCODE_URL is
      # kept as the /route fallback (raw anchor).
      FRONTDOOR_URL="''${FRONTDOOR_URL:-http://127.0.0.1:4700}"
      # mn9r M7: pigeon discovery endpoint. In a K-serve pool a live session's
      # event stream + TUI are hosted by the serve that OWNS it, so the
      # `opencode attach` hint must point at that serve, resolved per-session
      # via GET /route. Default matches opencode-launch's convention.
      PIGEON_DAEMON_URL="''${PIGEON_DAEMON_URL:-http://127.0.0.1:4731}"
      PROJECTS_DIR="''${LGTM_PROJECTS_DIR:-$HOME/projects}"

      CURL="${pkgs.curl}/bin/curl"
      JQ="${pkgs.jq}/bin/jq"
      GIT="${pkgs.git}/bin/git"

      # parse_serve_url <route-json-body> <fallback-url>: extract .apiBase from
      # a pigeon GET /route JSON body and print it. Falls back to <fallback-url>
      # when the body is empty, not JSON, or .apiBase is absent/null/empty.
      # Pure (no network): the caller does the curl and hands the body in, so
      # any pigeon hiccup degrades to the pre-pool single-serve behavior, never
      # worse. Mirror of pkgs/opencode-launch/default.nix.
      parse_serve_url() {
        local body="$1" fallback="$2" api
        api="$(printf '%s' "$body" | "$JQ" -r '.apiBase // empty' 2>/dev/null || true)"
        if [ -n "$api" ] && [ "$api" != "null" ]; then
          printf '%s\n' "$api"
        else
          printf '%s\n' "$fallback"
        fi
      }

      # Health check. Session metadata (below) comes from the shared opencode.db,
      # so listing works through the front door (which forwards to a pool serve).
      if ! "$CURL" -sf -m 5 "$FRONTDOOR_URL/global/health" >/dev/null 2>&1; then
        echo "OpenCode front door not reachable at $FRONTDOOR_URL" >&2
        exit 1
      fi

      # Find lgtm worktrees on disk: ~/projects/<repo>/.worktrees/pr-<N>
      shopt -s nullglob
      worktrees=( "$PROJECTS_DIR"/*/.worktrees/pr-[0-9]* )
      shopt -u nullglob

      if [ ''${#worktrees[@]} -eq 0 ]; then
        echo "No active lgtm worktrees"
        exit 0
      fi

      # Unique project roots (parent dir of .worktrees)
      declare -A seen_root
      project_roots=()
      for wt in "''${worktrees[@]}"; do
        root="''${wt%/.worktrees/*}"
        if [ -z "''${seen_root[$root]:-}" ]; then
          seen_root[$root]=1
          project_roots+=( "$root" )
        fi
      done

      # Resolve org/repo per project root via git remote (cached)
      declare -A repo_id
      for root in "''${project_roots[@]}"; do
        url="$( "$GIT" -C "$root" remote get-url origin 2>/dev/null || true )"
        # Parse https://github.com/<org>/<repo>(.git) or git@github.com:<org>/<repo>(.git)
        case "$url" in
          https://github.com/*)
            id="''${url#https://github.com/}"
            ;;
          git@github.com:*)
            id="''${url#git@github.com:}"
            ;;
          *)
            id="$(basename "$root")"
            ;;
        esac
        id="''${id%.git}"
        repo_id[$root]="$id"
      done

      # Query API per project root and collect sessions whose directory is a
      # pr-<N> worktree under that root. Build TSV: updated_ms\tcreated_ms\trepo_id\tpr_num\tsession_id
      now_ms=$(( $(date +%s) * 1000 ))
      tsv=""
      for root in "''${project_roots[@]}"; do
        body="$( "$CURL" -sf -m 10 -H "x-opencode-directory: $root" "$FRONTDOOR_URL/session" || echo "[]" )"
        prefix="$root/.worktrees/pr-"
        rows="$(
          printf '%s' "$body" | "$JQ" -r --arg prefix "$prefix" --arg id "''${repo_id[$root]}" '
            .[]
            | select(.directory | startswith($prefix))
            | (.directory | sub("^.*/pr-"; "")) as $tail
            | select($tail | test("^[0-9]+$"))
            | [ .time.updated, .time.created, $id, $tail, .id ]
            | @tsv
          '
        )"
        if [ -n "$rows" ]; then
          tsv="$tsv$rows"$'\n'
        fi
      done

      # Strip trailing blank line
      tsv="''${tsv%$'\n'}"

      if [ -z "$tsv" ]; then
        echo "No active lgtm sessions"
        exit 0
      fi

      # Format relative time from epoch ms
      fmt_ago() {
        local ms="$1"
        local secs=$(( (now_ms - ms) / 1000 ))
        if [ "$secs" -lt 0 ]; then secs=0; fi
        if [ "$secs" -lt 60 ]; then
          echo "''${secs}s ago"
        elif [ "$secs" -lt 3600 ]; then
          echo "$(( secs / 60 ))m ago"
        elif [ "$secs" -lt 86400 ]; then
          echo "$(( secs / 3600 ))h ago"
        else
          echo "$(( secs / 86400 ))d ago"
        fi
      }

      # Sort by updated desc and render table. Resolve each session's OWNING
      # serve via pigeon /route so the attach hints land on the right serve in
      # a K-serve pool (each degrades to $OPENCODE_URL on any pigeon hiccup).
      printf '%-50s  %-12s  %-12s  %s\n' "PR" "CREATED" "UPDATED" "SESSION"
      count=0
      attach_hints=()
      while IFS=$'\t' read -r updated created repo_full pr_num sid; do
        [ -z "$updated" ] && continue
        printf '%-50s  %-12s  %-12s  %s\n' \
          "''${repo_full}#''${pr_num}" \
          "$(fmt_ago "$created")" \
          "$(fmt_ago "$updated")" \
          "$sid"
        route_body="$( "$CURL" -sf --connect-timeout 2 --max-time 3 \
          "$PIGEON_DAEMON_URL/route?session_id=$sid" 2>/dev/null || true )"
        serve_url="$(parse_serve_url "$route_body" "$OPENCODE_URL")"
        attach_hints+=( "opencode attach $serve_url --session $sid" )
        count=$(( count + 1 ))
      done < <(printf '%s\n' "$tsv" | sort -t$'\t' -k1,1nr)

      echo
      echo "$count session(s). Attach (each routed to its owning serve):"
      for hint in "''${attach_hints[@]}"; do
        echo "  $hint"
      done
    '';
  };

  # common.conf is platform-specific - see home.linux.nix and home.darwin.nix

  # Tmux
  programs.tmux = {
    enable = true;
    secureSocket = false;  # Use /tmp for socket so mosh and non-login contexts find it
    shell = "${pkgs.bash}/bin/bash";  # Explicit: macOS defaults to zsh, but our config is all bash
    clock24 = true;
    terminal = "tmux-256color";
    historyLimit = 50000;  # Generous scrollback for long build logs
    extraConfig = ''
      # Prefix key: Ctrl-a (easier to reach than Ctrl-b)
      unbind C-b
      set -g prefix C-a
      bind C-a send-prefix    # Press C-a twice to send C-a to nested tmux/app

      # Usability
      set -g mouse on
      set -g renumber-windows on
      set -g allow-rename off     # Don't let programs rename windows via escape sequences
      set -g automatic-rename off # Don't auto-rename based on running command; manual names stick

      # Vi keybindings
      set -g status-keys vi      # Vi keys in command prompt (prefix + :)
      set -g mode-keys vi        # Vi keys in copy mode

      # Modern terminal integration
      set -g focus-events on     # Pass focus events to apps (neovim FocusGained/Lost)
      set -s escape-time 10      # Responsive Esc (tmux 3.5+ default is 10ms)

      # Truecolor support
      set -ag terminal-overrides ",xterm-256color:RGB"

      # Load extra config if it exists (safe during partial migration)
      if-shell -b '[ -f ~/.config/tmux/extra.conf ]' 'source-file ~/.config/tmux/extra.conf'
    '';
  };

  # Tmux extra config (OSC 52 clipboard, etc.)
  xdg.configFile."tmux/extra.conf".source = "${assetsPath}/tmux/extra.conf";

  # Neovim
  programs.neovim = {
    enable = true;
    defaultEditor = true;
    viAlias = true;
    vimAlias = true;

    plugins = with pkgs.vimPlugins; [
      tabby-nvim
      goyo-vim
      mini-align
      plenary-nvim
      telescope-fzy-native-nvim
      telescope-nvim
      (nvim-treesitter.withPlugins (p: with p; [
        bash c comment css csv diff dockerfile
        editorconfig git_config gitcommit gitignore go
        html http javascript json json5 lua luadoc
        make markdown markdown_inline nix python
        regex ruby sql ssh_config tmux toml
        typescript vimdoc xml yaml
      ]))
      (pkgs.vimUtils.buildVimPlugin {
        pname = "vim-ripgrep";
        version = "unstable-2026-01-13";
        src = pkgs.fetchFromGitHub {
          owner = "jremmen";
          repo = "vim-ripgrep";
          rev = "2bb2425387b449a0cd65a54ceb85e123d7a320b8";
          hash = "sha256-OvQPTEiXOHI0uz0+6AVTxyJ/TUMg6kd3BYTAbnCI7W8=";
        };
      })
    ];

    extraPackages = [ pkgs.ripgrep ];

    extraLuaConfig = ''
      require("user.settings")
      require("user.mappings")
      require("user.tabby")             -- OpenCode session tab labels
      require("user.oc_auto_attach")    -- external RPC: oc-auto-attach calls open({sid,dir,url})
      require("user.cursor_highlight")  -- Ctrl+K cursor crosshair toggle
      require("user.telescope")         -- treesitter + telescope + keymaps
      require("mini.align").setup()     -- text alignment (ga/gA)
    '' + lib.optionalString (isDarwin || isCloudbox) ''
      require("user.atlassian")         -- :FetchJiraTicket, :FetchConfluencePage
    '';
  };

  # Neovim Lua config files (kept separate from HM-managed init.vim)
  # User config modules from workstation assets
  xdg.configFile."nvim/lua/user" = {
    source = "${assetsPath}/nvim/lua/user";
    recursive = true;
  };

  # Home Manager (standalone command on PATH for all platforms)
  programs.home-manager.enable = true;

  # Direnv
  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };

  # Bash
  programs.bash = {
    enable = true;
    shellAliases = {
      ll = "ls -la";
      ".." = "cd ..";
      "..." = "cd ../..";
      # Git shortcuts (from deprecated-dotfiles)
      gs = "git status";
      gco = "git checkout";
      gd = "git diff";
      gl = "git log";
      gp = "git push";
    };
    initExtra = ''
      # Source home-manager session vars (PATH additions, EDITOR, etc.) for
      # interactive non-login shells. Home-manager only writes these to
      # ~/.profile, which bash sources for login shells only -- so mosh
      # reattach, nested `bash`, or terminals launched without `-l` end up
      # missing $HOME/.local/bin (where `ba`, `oc-search`, etc. live).
      # The script is idempotent (guarded by $__HM_SESS_VARS_SOURCED), so
      # sourcing it here after .profile already ran is a no-op.
      # Background: nix-community/home-manager#5474, #2445.
      if [ -f "$HOME/.nix-profile/etc/profile.d/hm-session-vars.sh" ]; then
        . "$HOME/.nix-profile/etc/profile.d/hm-session-vars.sh"
      fi

      # Vertex AI: Gemini 3.x models require the "global" endpoint.
      # Without this, OpenCode defaults to "us-east5" which 404s on newer models.
      export GOOGLE_CLOUD_LOCATION="global"

      # GPG TTY - tmux-aware (from deprecated-dotfiles)
      if [ -n "$TMUX" ]; then
          export GPG_TTY=$(tmux display-message -p '#{pane_tty}')
      else
          export GPG_TTY=$(tty)
      fi
      export HISTSIZE=10000
      export HISTFILESIZE=20000
      export HISTCONTROL=ignoredups:erasedups
      shopt -s histappend

      # Checkout default branch (from deprecated-dotfiles)
      gcom() {
        git fetch origin && git checkout "origin/$(git remote show origin | grep 'HEAD branch:' | awk '{ print $3 }')"
      }

      # Datadog CLI shortcut for humans. Agents and scripts must call
      # `dd-cli` directly — non-interactive shells (e.g. `bash -c '...'`
      # spawned by agent tooling) do not source this initExtra, so this
      # function is invisible to them and bare `dd` resolves to coreutils
      # for those callers. See the comment above the dd-cli activation
      # block for full context.
      dd() {
        command dd-cli "$@"
      }
    '' + lib.optionalString (servePoolK >= 2) ''
      # Pool interactive opencode (workstation-jiae). This initExtra runs only in
      # interactive shells (after ~/.bashrc's interactive guard, like dd()), so
      # nvim jobstart, systemd serves, and `bash -c` agent tooling never see this
      # function. It delegates to the oc-pool-attach placer, which pools a fresh
      # TUI / `-s` resume onto a pool serve via pigeon and self-hosts (today's
      # behavior) on any failure. `command` prevents the function from re-entering
      # itself; the placer execs the real opencode by absolute store path.
      opencode() { command oc-pool-attach "$@"; }
    '';
  };

  # SSH
  programs.ssh = {
    enable = true;
    enableDefaultConfig = false;  # Silence deprecation warning; defaults mirror SSH's own
    matchBlocks."github.com" = {
      hostname = "github.com";
      user = "git";
      identityFile = "~/.ssh/id_ed25519_github";
      identitiesOnly = true;
    };
  };

  # Nix binary caches (devenv projects use their own flake inputs, cachix avoids rebuilds)
  # mkDefault: in module mode (nix-darwin/NixOS), home-manager's nixos/common.nix
  # forwards the system nix.package into each user, causing a duplicate definition
  # error. mkDefault lets the system's value win. In standalone mode (devbox),
  # this provides the required package for nix.settings below. (HM #5870)
  nix.package = lib.mkDefault pkgs.nix;
  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    extra-substituters = [
      "https://devenv.cachix.org"
    ];
    extra-trusted-public-keys = [
      "devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw="
    ];
  };

  # FZF
  programs.fzf = {
    enable = true;
    enableBashIntegration = true;
  };

  # Session path
  home.sessionPath = [
    "$HOME/.local/bin"
    "$HOME/.npm-global/bin"
  ];

  # Install dd-cli (Datadog CLI) in editable mode from local checkout (work machines)
  # Editable install means source changes are reflected immediately without reinstalling.
  # Only re-run `home-manager switch` if dependencies in pyproject.toml change.
  home.activation.installDdCli = lib.mkIf (isDarwin || isCloudbox) (
    lib.hm.dag.entryAfter [ "writeBoundary" ] (let
      ddCliDir = if isCloudbox
        then "$HOME/projects/dd-cli"
        else "$HOME/Code/dd-cli";
    in ''
      set -euo pipefail
      dd_cli_dir="${ddCliDir}"
      if [ -d "$dd_cli_dir" ]; then
        ${pkgs.uv}/bin/uv tool install --editable "$dd_cli_dir" --force --quiet 2>&1 || {
          echo "installDdCli: WARNING: uv tool install failed"
        }
        echo "installDdCli: dd-cli installed (editable) from $dd_cli_dir"
      else
        echo "installDdCli: skipping ($dd_cli_dir not found)"
      fi
    ''));

  # npm-global packages that can't be managed by Nix
  # (e.g. nixpkgs version is too old, or package not in nixpkgs)
  # Installed to ~/.npm-global which is already on sessionPath
  home.activation.installNpmGlobalPackages = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    set -euo pipefail
    export PATH="${pkgs.nodejs}/bin:$PATH"
    export npm_config_prefix="$HOME/.npm-global"

    # chrome-devtools-mcp: primary browser MCP server for AI agent visual QA
    # (replaces @playwright/mcp — better token efficiency, DevTools-native
    # capabilities like Lighthouse audits, perf traces, memory snapshots)
    wanted_cdmcp="0.20.3"
    current_cdmcp="$(npm ls -g --prefix "$HOME/.npm-global" chrome-devtools-mcp --json 2>/dev/null \
      | ${pkgs.jq}/bin/jq -r '.dependencies["chrome-devtools-mcp"].version // empty' 2>/dev/null || true)"
    if [[ "$current_cdmcp" != "$wanted_cdmcp" ]]; then
      echo "Installing chrome-devtools-mcp@$wanted_cdmcp (have: ''${current_cdmcp:-none})"
      npm install -g "chrome-devtools-mcp@$wanted_cdmcp" --prefix "$HOME/.npm-global" --no-fund --no-audit 2>&1 || true
    fi
  '';

}
