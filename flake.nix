{
  description = "Workstation configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";

    home-manager = {
      url = "github:nix-community/home-manager/release-25.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nix-darwin = {
      url = "github:nix-darwin/nix-darwin/nix-darwin-25.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    devenv = {
      url = "github:cachix/devenv";
    };
  };

  outputs = { self, nixpkgs, home-manager, nix-darwin, disko, sops-nix, devenv, ... }@inputs:
  let
    # Centralized pkgs definition to prevent drift
    pkgsFor = system: import nixpkgs {
      inherit system;
      config.allowUnfree = true;
      overlays = [];
    };

    devboxSystem = "aarch64-linux";
    devboxPkgs = pkgsFor devboxSystem;

    # Darwin (macOS) pkgs
    darwinSystem = "aarch64-darwin";
    darwinPkgs = pkgsFor darwinSystem;

    # Self-packaged tools (updated via nix-update in CI)
    localPkgsFor = system: let
      p = pkgsFor system;
    in {
      ask-question = p.callPackage ./pkgs/ask-question { };
      # Named `bazel-scope` rather than `bazel`: the DERIVATION provides bin/bazel
      # (it has to shadow the real one on PATH), but a flake output called `bazel`
      # would be a trap for anyone running `nix build .#bazel` expecting bazel.
      bazel-scope = p.callPackage ./pkgs/bazel-scope { };
      bb = p.callPackage ./pkgs/bb { };
      pressure-sampler = p.callPackage ./pkgs/pressure-sampler { };
      beads = p.callPackage ./pkgs/beads { };
      caveman = p.callPackage ./pkgs/caveman { };
      claude-failover-proxy = p.callPackage ./pkgs/claude-failover-proxy { };
      clerk = p.callPackage ./pkgs/clerk { };
      # DevCycle CLI. Provides BOTH `dvc` (CLI, on PATH via home.base.nix) and
      # `dvc-mcp` (the local MCP server opencode-config.nix wires up), so the
      # two can never drift to different @devcycle/cli versions.
      dvc = p.callPackage ./pkgs/dvc { };
      gclpr = p.callPackage ./pkgs/gclpr { };
      git-work = p.callPackage ./pkgs/git-work { };
      worktree-guard-hook = p.callPackage ./pkgs/worktree-guard-hook { };
      gws = p.callPackage ./pkgs/gws { };
      hm-deploy-gate-sh = p.callPackage ./pkgs/hm-deploy-gate-sh { };
      hm-deploy-canary-sh = p.callPackage ./pkgs/hm-deploy-canary-sh { };
      lgtm-gh = p.callPackage ./pkgs/lgtm-gh { };
      nvims = p.callPackage ./pkgs/nvims { };
      oc-auto-attach = p.callPackage ./pkgs/oc-auto-attach { };
      oc-context = p.callPackage ./pkgs/oc-context { };
      oc-search = p.callPackage ./pkgs/oc-search { };
      oc-cost = p.callPackage ./pkgs/oc-cost { };
      oc-mcp-enable = p.callPackage ./pkgs/oc-mcp-enable { };
      oc-scoped-shell = p.callPackage ./pkgs/oc-scoped-shell { };
      oc-session-list = p.callPackage ./pkgs/oc-session-list { };
      oc-throwaway-serve = p.callPackage ./pkgs/oc-throwaway-serve { };
      opencode-frontdoor = p.callPackage ./pkgs/opencode-frontdoor { };
      # NOTE: `opencode-frontdoor-route-gate` is deliberately NOT exposed here.
      # It needs the PINNED opencode, and that pin lives in
      # `users/dev/home.base.nix` (edited in place by
      # .github/workflows/update-opencode-patched.yml, so it must not be moved).
      # Exposing a flake output would require a second copy of the pin here, which
      # the updater would not bump — the gate would then silently validate a STALE
      # binary while the pool ran the new one: green and wrong, at exactly the
      # moment the gate exists for. The gate is instantiated in home.base.nix
      # against the real pin; `pkgs/opencode-frontdoor/test.sh` runs the same
      # check on demand.
      opencode-launch = p.callPackage ./pkgs/opencode-launch { };
      opencode-serve-auth-sh = p.callPackage ./pkgs/opencode-serve-auth-sh { };
      reset-workspace = p.callPackage ./pkgs/reset-workspace { };
      self-compact-plugin = p.callPackage ./pkgs/self-compact-plugin { };
      session-state-plugin = p.callPackage ./pkgs/session-state-plugin { };
      teamclaude = p.callPackage ./pkgs/teamclaude { };
      vercel = p.callPackage ./pkgs/vercel { };
    } // nixpkgs.lib.optionalAttrs (system == devboxSystem || system == darwinSystem) {
      terraform = p.callPackage ./pkgs/terraform { };
    };

    # macOS host facts
    mac = import ./hosts/Y0FMQX93RR-2/vars.nix;

    # Filter projects by platform tag.
    # Projects without a `platforms` attr are included everywhere.
    allProjects = import ./projects.nix;
    projectsFor = platform: nixpkgs.lib.filterAttrs
      (_: p: !(p ? platforms) || builtins.elem platform p.platforms)
      allProjects;
    # All systems we target
    systems = [ devboxSystem darwinSystem ];

    pluginSrc = ./assets/opencode/plugins;

    # node_modules INCLUDING devDependencies, for the TypeScript test checks
    # below. Deliberately a SECOND deps stage rather than a reuse of the one in
    # pkgs/opencode-plugin-bundle: that one passes `--omit=dev` because a
    # shipped bundle needs no test tooling, and vitest lives in
    # devDependencies. Sharing a single stage would mean either shipping test
    # tooling into every plugin bundle or having no vitest to run here.
    #
    # Built with `importNpmLock.buildNodeModules` (not buildNpmPackage +
    # npmDepsHash) to match the convention pkgs/opencode-plugin-bundle
    # documents at length: each dep is fetched by the lockfile's own SRI
    # integrity, so there is NO output hash to maintain and a nixpkgs nodejs
    # bump can at most trigger a rebuild, never a hash mismatch.
    pluginTestNodeModules = devboxPkgs.importNpmLock.buildNodeModules {
      package = devboxPkgs.lib.importJSON (pluginSrc + "/package.json");
      packageLock = devboxPkgs.lib.importJSON (pluginSrc + "/package-lock.json");
      nodejs = devboxPkgs.nodejs;
      derivationArgs = {
        pname = "opencode-plugin-node-modules-dev";
        version = "0.1.0";
      };
    };

    frontdoorSrc = ./pkgs/opencode-frontdoor;

    # node_modules INCLUDING devDependencies, for the frontdoor vitest check.
    #
    # pkgs/opencode-frontdoor/default.nix builds the SHIPPED artifact with
    # buildNpmPackage + a pinned npmDepsHash; this is a separate deps stage for
    # the same reason the plugin one above is separate from the bundle's. It
    # also uses importNpmLock rather than a second npmDepsHash on purpose: a
    # hash is a thing to maintain and to get wrong, and the lockfile's own SRI
    # integrity already pins every dep.
    frontdoorTestNodeModules = devboxPkgs.importNpmLock.buildNodeModules {
      package = devboxPkgs.lib.importJSON (frontdoorSrc + "/package.json");
      packageLock = devboxPkgs.lib.importJSON (frontdoorSrc + "/package-lock.json");
      nodejs = devboxPkgs.nodejs_22;
      derivationArgs = {
        pname = "opencode-frontdoor-node-modules-dev";
        version = "1.0.0";
      };
    };
  in {
    # Expose local packages for nix-update and nix build.
    # Filter out packages whose meta.platforms excludes the target system
    # (e.g. a package restricted to aarch64 won't appear in packages.x86_64-linux).
    packages = builtins.listToAttrs (map (system: {
      name = system;
      value = let
        all = localPkgsFor system;
        platform = (pkgsFor system).stdenv.hostPlatform;
      in nixpkgs.lib.filterAttrs
        (_: pkg: nixpkgs.lib.meta.availableOn platform pkg)
        all;
    }) systems);

    # Build-level CI gate.
    #
    # `nix flake check` on its own is NOT a build gate for this repo. It
    # *evaluates* `nixosConfigurations` (drv level only) and does not even
    # evaluate `homeConfigurations` -- it just confirms the attrset exists. So a
    # derivation that is fine at eval time but fails at BUILD time sails through
    # CI green and only explodes later, on the user's machine, at `switch` time.
    #
    # That is not hypothetical. #211 added `source "${opencode-serve-auth-sh}"`
    # to three `writeShellApplication`s; that builder runs shellcheck with
    # findings treated as fatal, and shellcheck always emits SC1091 for a source
    # target it cannot resolve -- which a /nix/store path never is at lint time.
    # All three failed to build, taking `home-manager-generation` with them,
    # while CI reported success on both legs. It went unnoticed for a day, so
    # nothing from #211/#212 reached the box, which in turn silently invalidated
    # an unrelated measurement that was about to be acted on. Fixed in #215.
    #
    # Listing the configurations here makes `nix flake check` actually realise
    # them, locally and in CI, by the same command. Both NixOS hosts are
    # aarch64-linux (devbox is ARM on Hetzner, cloudbox is ARM on GCP), so the
    # ubuntu-24.04-arm leg builds all four. This is keyed per-system so the
    # x86_64 leg never tries to realise an aarch64 attribute.
    #
    # Deliberately absent:
    #
    #   nixos-cloudbox -- that host pulls in `claude-failover-proxy`, whose
    #     binary lives in a PRIVATE repo and is fetched through the GitHub API
    #     with a token supplied via `netrcImpureEnvVars`. A CI runner has no
    #     such credential, so the fetch 404s and the toplevel cannot be built
    #     there at all. This is a credential wall, not a defect: it was proven
    #     empirically in the first run of this gate (#218), where the other
    #     three checks built clean and only this one failed. Note the recurring
    #     hazard is unaffected -- `writeShellApplication` (the shellcheck-fatal
    #     builder) appears zero times in either host configuration and only in
    #     the home configs, which ARE built below. Cloudbox also keeps the
    #     eval-level checking `nix flake check` already did. Restoring a real
    #     build needs a CI credential; tracked separately.
    #
    #   darwinConfigurations -- needs a macOS builder. Tracked separately.
    checks.${devboxSystem} = {
      home-dev = self.homeConfigurations.dev.activationPackage;
      home-cloudbox = self.homeConfigurations.cloudbox.activationPackage;
      nixos-devbox = self.nixosConfigurations.devbox.config.system.build.toplevel;

      # ---- pkgs/opencode-frontdoor vitest suite (bead workstation-5m47) ----
      #
      # WHY THIS EXISTS: 25 test files and 496 assertions covering the routing
      # layer every consumer is required to go through -- the repo's largest
      # untested surface -- ran NOWHERE. The suite was believed un-runnable as a
      # nix check because it binds loopback sockets; that belief was wrong, and
      # the counter-example was already in the tree (pkgs/opencode-frontdoor/
      # route-gate.nix boots a real opencode serve on 127.0.0.1 inside the
      # sandbox, and depends on the sandbox's private network namespace to make
      # a FIXED port safe). Only the `npm ci` half was a real obstacle, and
      # importNpmLock removes it.
      #
      # Two properties worth knowing before editing:
      #
      #   - This lives under checks.${devboxSystem}, so it is evaluated for
      #     aarch64-linux only and darwin never sees it. The loopback tests
      #     lean on the Linux sandbox's private network namespace; if a darwin
      #     checks leg is ever added, do not assume this one travels.
      #   - It copies the whole ${self} (see below), so it REBUILDS on any
      #     change anywhere in the repo, and 25 socket-driven integration
      #     files now gate every PR. That is the deliberate trade for
      #     hermeticity, but it does promote any flakiness in this suite into
      #     a repo-wide blocker. If one turns out flaky, fix or delete it --
      #     do not skip it, which the skip census below refuses anyway.
      frontdoor-vitest = devboxPkgs.runCommand "frontdoor-vitest-tests" {
        nativeBuildInputs = [ devboxPkgs.nodejs_22 devboxPkgs.diffutils ];
      } ''
        # Copies the whole ${self}, not just the frontdoor directory, for the
        # same reason plugin-vitest does: test/wire-text.test.ts:160 resolves
        # `../../..` to the repo root to assert the operator runbook it points
        # at exists. Measured: with only the package directory, that one case
        # fails ENOENT while the other 495 pass.
        cp -r --no-preserve=mode,ownership ${self} ./repo
        cd ./repo/pkgs/opencode-frontdoor

        # A symlink FARM, not a symlink to the store directory. vitest writes a
        # results cache to node_modules/.vite, and with `ln -s` that resolves
        # into the read-only store: EACCES, raised as an unhandled error that
        # fails the run AFTER every test has already passed. `cp -rs` gives real
        # (writable) directories whose leaves are symlinks into the store, so
        # the cache write lands in the build dir. Version-independent, unlike
        # pinning vitest's cacheDir flag.
        cp -rs ${frontdoorTestNodeModules}/node_modules ./node_modules
        # cp copies the SOURCE's mode, and store directories are r-x: without
        # this the farm is as unwritable as the symlink was, and the EACCES
        # comes back at the same place.
        chmod -R u+w ./node_modules
        export HOME="$TMPDIR/home"
        mkdir -p "$HOME"

        # Typecheck FIRST, and note it is not redundant with the package build.
        # default.nix compiles tsconfig.build.json, which excludes test/ -- so
        # the type-correctness of 25 test files was checked by nothing in CI
        # either. `npm run typecheck` is tsconfig.json, which includes them.
        node_modules/.bin/tsc --noEmit

        node_modules/.bin/vitest run \
          --reporter=default \
          --reporter=json --outputFile.json="$TMPDIR/vitest.json"

        # Same two assertions as plugin-vitest below, for the same reasons: a
        # green runner is not evidence that anything ran. (1) nothing was
        # skipped -- vitest exits 0 over a `describe.skip` and leaves the file
        # in testResults, so a skip is invisible to both the exit code and the
        # file-set check. (2) the set of files vitest EXECUTED equals the
        # *.test.ts files on disk -- a set and not a count, because the failure
        # being defended against is whole-file exclusion by the include
        # pattern, which a count cannot see and which invites a reviewer to
        # "fix" it by bumping the number.
        node -e 'const fs=require("fs"),path=require("path");const j=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));if(!(j.numTotalTests>0)){console.error("GATE FAILURE: vitest reported 0 tests.");process.exit(1)}if(j.numPendingTests>0||j.numTodoTests>0){console.error("GATE FAILURE: "+j.numPendingTests+" skipped and "+j.numTodoTests+" todo test(s). A skipped test is not a passing one; un-skip it or delete it.");process.exit(1)}console.log(j.testResults.map(function(r){return path.relative(process.cwd(),r.name)}).sort().join("\n"))' \
          "$TMPDIR/vitest.json" > "$TMPDIR/ran.txt"

        find test -name '*.test.ts' -type f | sort > "$TMPDIR/ondisk.txt"

        if ! diff -u --label "on disk" --label "actually ran" "$TMPDIR/ondisk.txt" "$TMPDIR/ran.txt"; then
          echo "" >&2
          echo "GATE FAILURE: the *.test.ts files on disk are not the files vitest ran." >&2
          echo "  A '-' line is a file that EXISTS but was NOT RUN -- silently excluded" >&2
          echo "    by vitest's include pattern. That is the defect this check ends." >&2
          echo "  A '+' line is a file vitest ran that this check did not expect --" >&2
          echo "    most likely the on-disk glob above needs widening." >&2
          exit 1
        fi
        touch $out
      '';

      # Phase 9.2 opacity guard. Bash-only, so it adds seconds to the ARM leg that
      # already spends ~3 min realising the three configurations above.
      #
      # WHY THIS EXISTS: the guard was written in Phase 9.2 and then enforced
      # NOWHERE -- no flake check, no CI step, no canary. It sat red on main from
      # #217 (which added a devbox door, and with it two unmarked sites) until
      # 2026-08-01 and nothing noticed. A guard nothing runs is documentation with
      # a shebang.
      frontdoor-opacity = devboxPkgs.runCommand "frontdoor-opacity-guard" {
        nativeBuildInputs = [ devboxPkgs.bash ];
      } ''
        cd ${self}
        bash users/dev/test-frontdoor-opacity.sh
        bash users/dev/test-frontdoor-opacity-guard.sh
        touch $out
      '';

      # ---------------------------------------------------------------------
      # workstation-dad9: five suites that existed and ran nowhere.
      #
      # The bead estimated all of these as "add a checks entry and grep the
      # final PASS line". Running them first showed that was true of two. What
      # the other three needed is recorded on each check below, because the
      # useful artifact is not the wiring, it is the reason the estimate was
      # wrong.
      # ---------------------------------------------------------------------

      # The worktree-guard pre-commit hook: 7 cases over the only remaining
      # enforcement of the read-only-trunk rule, including the LOAD-BEARING
      # bypasses (merge must still work, or `git pull` at a deploy root breaks).
      #
      # It could not be a check while it pointed at the raw asset, whose shebang
      # is #!/bin/bash: a nix sandbox has only /bin/sh (measured). Rather than
      # patch a copy for the sandbox's benefit, the hook is now a package whose
      # interpreter is a store path, home-manager deploys THAT, and this check
      # runs the suite against the same artifact -- so a green check here is a
      # statement about the deployed hook, not about a sandbox-only variant.
      #
      # That package also closed a live hazard: /bin/bash is declared nowhere in
      # this repo and exists on cloudbox only as an undeclared hand-made symlink,
      # so a reprovisioned host would have deployed an unexecutable hook.
      # pool-route-clients: 14 source-guard assertions over PRODUCTION files --
      # users/dev/home.base.nix and hosts/cloudbox/configuration.nix. It is a
      # tripwire rather than a unit test, and that is the point: the same class
      # as checks.frontdoor-opacity.
      #
      # Why this file earns a check rather than deletion. Its own HISTORY block
      # (test-pool-route-clients.sh:42-48) records that it once asserted the
      # OPPOSITE of the current behaviour -- it required the lgtm-sessions attach
      # hint to resolve a serve URL via pigeon /route -- and because it pinned
      # the stale behaviour as correct while running NOWHERE, it protected the
      # last direct-to-serve data-plane call site from being fixed for two
      # phases. A guard that runs is what keeps that fix fixed.
      #
      # Two vacuous-green paths were fixed in the same commit as this wiring.
      # The suite printed its gate token ("ALL PASS") and exited 0 when
      # home.base.nix was not beside it, and silently skipped the four
      # control-plane exemption assertions when configuration.nix was absent.
      # Either one would have let this check pass having adjudicated nothing, so
      # both are now fatal. The count below is the second half of that fix:
      # pin it, and update it in the same commit that adds an assertion.
      pool-route-clients-guards = devboxPkgs.runCommand "pool-route-clients-guards" {
        nativeBuildInputs = [ devboxPkgs.bash devboxPkgs.gnugrep devboxPkgs.coreutils ];
      } ''
        cd ${self}
        export HOME="$TMPDIR"
        bash users/dev/test-pool-route-clients.sh 2>&1 | tee "$TMPDIR/prc.txt"
        grep -q '^ALL PASS' "$TMPDIR/prc.txt" || {
          echo "GATE FAILURE: pool-route-clients did not reach ALL PASS." >&2
          exit 1
        }
        [ "$(grep -c '^ok: ' "$TMPDIR/prc.txt")" = 14 ] || {
          echo "GATE FAILURE: expected 14 'ok: ' lines, got" \
               "$(grep -c '^ok: ' "$TMPDIR/prc.txt")." >&2
          exit 1
        }
        touch $out
      '';

      # oc-pool-attach: 87 assertions, and the name says "mirror" on purpose.
      #
      # ~70 of those assertions exercise helpers REDEFINED inside test.sh
      # (classify_oc_invocation, parse_serve_url, resolve_pigeon_auth), so they
      # cannot fail when pkgs/oc-pool-attach/default.nix drifts -- measured: a
      # logic mutation in the production classify body survives all of them. The
      # honest half is the ~17 source-greps over default.nix, which are real
      # regression tripwires (the IFS tab-split read anti-pattern, the POST
      # /place fallback, and FRONTDOOR_URL/session vs the stale anchor).
      #
      # Wired anyway, following the precedent set for lgtm-gh-mirror-tests in
      # PR #370: leaving the file unwired ran the honest greps NOWHERE AT ALL.
      # Execution and fidelity are orthogonal problems, and the *-mirror-tests
      # suffix exists so a green here cannot be misread as "production is
      # covered". Killing the mirror is tracked in workstation-dimz, which now
      # owns this file too.
      #
      # Three vacuous-green paths were closed in the same commit as the wiring:
      # a missing default.nix printed SKIP and fell through to the final banner
      # (so the only non-tautological half was optional), jq absent silently
      # dropped 9 assertions the same way, and the count below pins both shut.
      oc-pool-attach-mirror-tests = devboxPkgs.runCommand "oc-pool-attach-mirror-tests" {
        nativeBuildInputs = [
          devboxPkgs.bash devboxPkgs.jq devboxPkgs.gnugrep devboxPkgs.coreutils
        ];
      } ''
        cd ${self}
        export HOME="$TMPDIR"
        bash pkgs/oc-pool-attach/test.sh 2>&1 | tee "$TMPDIR/opa.txt"
        grep -q '^all oc-pool-attach tests passed' "$TMPDIR/opa.txt" || {
          echo "GATE FAILURE: oc-pool-attach suite did not reach its final banner." >&2
          exit 1
        }
        [ "$(grep -c '^PASS' "$TMPDIR/opa.txt")" = 87 ] || {
          echo "GATE FAILURE: expected 87 'PASS' lines, got" \
               "$(grep -c '^PASS' "$TMPDIR/opa.txt")." >&2
          exit 1
        }
        touch $out
      '';

      # ---- workstation-oo4q: suites that used to shell out to nix themselves --
      #
      # Each of these three extracted its subject by running `nix eval` or
      # `nix build` INSIDE the test, which a build sandbox cannot do (no daemon
      # socket, no network, recursive-nix off). Each now takes the artifact
      # through a seam instead, so the CHECK's dependency graph does the
      # building and the suite only ever reads a path. Same shape as
      # WORKTREE_GUARD_HOOK_DIR below: the check points at the artifact
      # home-manager actually deploys, not a sandbox-only rebuild.
      #
      # Two sandbox facts these preambles work around, both measured:
      #   - /usr/bin/env does not exist, so the disk-cleanup suite now writes
      #     its generated harness with an absolute bash shebang.
      #   - /tmp/opencode does not exist, and two of these mktemp into it.
      disk-cleanup-worktree-tests = devboxPkgs.runCommand "disk-cleanup-worktree-tests" {
        nativeBuildInputs = [
          devboxPkgs.bash devboxPkgs.git devboxPkgs.python3
          devboxPkgs.coreutils devboxPkgs.gnugrep
        ];
        DISK_CLEANUP_SRC = self.homeConfigurations.cloudbox.config.home.file.".local/bin/disk-cleanup".source;
      } ''
        cd ${self}
        export HOME="$TMPDIR"
        mkdir -p /tmp/opencode
        export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
        export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
        bash users/dev/test-disk-cleanup-worktrees.sh 2>&1 | tee "$TMPDIR/dc.txt"
        grep -q '^all disk-cleanup worktree tests passed' "$TMPDIR/dc.txt" || {
          echo "GATE FAILURE: disk-cleanup suite did not reach its final banner." >&2
          exit 1
        }
        # Pinned, following checks.oc-auto-attach: a suite that stops
        # adjudicating must not be able to present as green.
        [ "$(grep -c '^PASS ' "$TMPDIR/dc.txt")" = 3 ] || {
          echo "GATE FAILURE: expected 3 'PASS ' lines, got" \
               "$(grep -c '^PASS ' "$TMPDIR/dc.txt")." >&2
          exit 1
        }
        touch $out
      '';

      opencode-llm-audit-tests = devboxPkgs.runCommand "opencode-llm-audit-tests" {
        nativeBuildInputs = [
          devboxPkgs.bash devboxPkgs.git devboxPkgs.python3
          devboxPkgs.coreutils devboxPkgs.gnugrep
        ];
        OPENCODE_LLM_AUDIT_SRC = self.homeConfigurations.cloudbox.config.home.file.".local/bin/opencode-llm-audit".source;
      } ''
        cd ${self}
        export HOME="$TMPDIR"
        mkdir -p /tmp/opencode
        bash users/dev/test-opencode-llm-audit.sh 2>&1 | tee "$TMPDIR/la.txt"
        grep -q '^ALL PASS' "$TMPDIR/la.txt" || {
          echo "GATE FAILURE: llm-audit suite did not reach ALL PASS." >&2
          exit 1
        }
        [ "$(grep -c '^ok: ' "$TMPDIR/la.txt")" = 30 ] || {
          echo "GATE FAILURE: expected 30 'ok:' lines, got" \
               "$(grep -c '^ok: ' "$TMPDIR/la.txt")." >&2
          exit 1
        }
        touch $out
      '';

      reset-workspace-shada-report-tests = devboxPkgs.runCommand "reset-workspace-shada-report-tests" {
        nativeBuildInputs = [
          devboxPkgs.bash devboxPkgs.gawk devboxPkgs.gnused
          devboxPkgs.coreutils devboxPkgs.gnugrep
        ];
        RESET_WORKSPACE_BIN = "${(localPkgsFor devboxSystem).reset-workspace}/bin/reset-workspace";
      } ''
        cd ${self}
        export HOME="$TMPDIR"
        bash pkgs/reset-workspace/test-shada-report.sh 2>&1 | tee "$TMPDIR/sr.txt"
        grep -q '^ALL PASS' "$TMPDIR/sr.txt" || {
          echo "GATE FAILURE: shada-report suite did not reach ALL PASS." >&2
          exit 1
        }
        [ "$(grep -c '^ok: ' "$TMPDIR/sr.txt")" = 12 ] || {
          echo "GATE FAILURE: expected 12 'ok:' lines, got" \
               "$(grep -c '^ok: ' "$TMPDIR/sr.txt")." >&2
          exit 1
        }
        touch $out
      '';

      # hosts/devbox/test-phantom-busy-sweeper.sh drives the SHIPPED ExecStart
      # artifact of the devbox sweeper against scratch WAL databases. It used to
      # build its own subject with `nix eval` + `nix-store -r`, which a build
      # sandbox cannot do; SWEEPER_OVERRIDE hands it the same store path the
      # systemd user unit runs, so the check's dependency graph does the building.
      #
      # WHY THIS RUNS AT ALL OFF-DEVBOX: the sandbox has no systemctl, so the
      # suite's discovery block finds no serves and CUTOFF collapses to now. The
      # file is written for that path (see its header) and every assertion holds
      # under it. Note this bakes in a property of the DEVBOX discovery block --
      # that it fails OPEN when systemctl is missing. Its cloudbox sibling fails
      # CLOSED and would exit 1 here. If the two discovery blocks are ever
      # converged (workstation-yvxh.10), this check needs a systemctl shim or a
      # discovery seam, or it will go permanently red for a non-obvious reason.
      devbox-phantom-busy-sweeper-tests = devboxPkgs.runCommand "devbox-phantom-busy-sweeper-tests" {
        nativeBuildInputs = [
          devboxPkgs.bash devboxPkgs.sqlite devboxPkgs.coreutils
          devboxPkgs.gnugrep devboxPkgs.gawk devboxPkgs.procps
        ];
        SWEEPER_OVERRIDE = builtins.head
          self.homeConfigurations.dev.config.systemd.user.services.opencode-phantom-busy-sweeper.Service.ExecStart;
      } ''
        cd ${self}
        export HOME="$TMPDIR"

        # The devbox and cloudbox sweepers are different derivations with the SAME
        # derivation name, so a cross-wired path is invisible in a build log.
        # `systemctl --user` is the devbox discovery block and appears nowhere in
        # the cloudbox artifact. This gate is fail-fast ergonomics rather than a
        # safety barrier -- a cross-wired cloudbox artifact would already fail ~40
        # assertions -- but it turns a confusing red into a named one.
        grep -q 'systemctl --user' "$SWEEPER_OVERRIDE" || {
          echo "GATE FAILURE: SWEEPER_OVERRIDE is not the devbox sweeper" >&2
          echo "  (no 'systemctl --user' discovery block in $SWEEPER_OVERRIDE)" >&2
          exit 1
        }

        # The suite's own safety note: SWEEPER_OVERRIDE escapes its HOME-pinning
        # guarantee, so the artifact MUST honour the OPENCODE_SWEEPER_DB seam.
        # Unlike the gate above this asserts the safety property itself, and so
        # also covers a future pre-seam artifact or wrapper.
        grep -q 'OPENCODE_SWEEPER_DB' "$SWEEPER_OVERRIDE" || {
          echo "GATE FAILURE: artifact does not honour the OPENCODE_SWEEPER_DB seam" >&2
          exit 1
        }

        bash hosts/devbox/test-phantom-busy-sweeper.sh 2>&1 | tee "$TMPDIR/sweeper.txt"

        # Both gates below pin the same number, deliberately: the banner proves the
        # suite adjudicated and reached its end, the count proves it adjudicated
        # THIS MANY things. T10 emits one assertion per command in a 7-element
        # loop, so editing that list moves the count -- which is exactly when a
        # human should re-read this.
        grep -q '^==== 45 passed, 0 failed ====$' "$TMPDIR/sweeper.txt" || {
          echo "GATE FAILURE: sweeper suite did not reach its 45-passed banner." >&2
          exit 1
        }
        [ "$(grep -c '^  PASS: ' "$TMPDIR/sweeper.txt")" = 45 ] || {
          echo "GATE FAILURE: expected 45 '  PASS: ' lines, got" \
               "$(grep -c '^  PASS: ' "$TMPDIR/sweeper.txt")." >&2
          exit 1
        }
        touch $out
      '';

      worktree-guard-hook-tests = devboxPkgs.runCommand "worktree-guard-hook-tests" {
        nativeBuildInputs = [
          devboxPkgs.bash devboxPkgs.git devboxPkgs.coreutils devboxPkgs.gnugrep
        ];
        WORKTREE_GUARD_HOOK_DIR = "${(localPkgsFor devboxSystem).worktree-guard-hook}";
      } ''
        cd ${self}
        export HOME="$TMPDIR"
        bash assets/git-hooks/test-pre-commit.sh 2>&1 | tee "$TMPDIR/out.txt"
        grep -q '^=== All tests PASSED ===' "$TMPDIR/out.txt" || {
          echo "GATE FAILURE: hook suite did not reach its final PASSED line." >&2
          exit 1
        }
        # This suite was, until PR #350, incapable of failing: it assigned fail=1
        # inside ( ... ) subshells, so every failure was discarded and it always
        # exited 0. Assert the case COUNT as well as the banner, so a suite that
        # silently stops adjudicating cannot present as green again.
        [ "$(grep -c '^ok: ' "$TMPDIR/out.txt")" = 19 ] || {
          echo "GATE FAILURE: expected 19 'ok:' lines, got" \
               "$(grep -c '^ok: ' "$TMPDIR/out.txt")." >&2
          exit 1
        }
        touch $out
      '';

      # oc-cost: 101 tests over the cost model, sqlite in-memory, hermetic.
      #
      # Read the gate below before changing the invocation. This file had NO
      # `if __name__ == "__main__"` block, so `python3 test_oc_cost.py` imported
      # it, defined all 101 tests, ran NONE, printed nothing, and exited 0
      # (measured). Wiring it the obvious way would have added a check that
      # could never fail -- the oc-session-list `--help` checkPhase again, in
      # python. Its own header said to run it via `python3 -m unittest <file>`,
      # which the reachability guard cannot match (`-m` does not end in `.py`),
      # so the file was made directly runnable instead of teaching the guard a
      # new shape.
      oc-cost-tests = devboxPkgs.runCommand "oc-cost-tests" {
        nativeBuildInputs = [ devboxPkgs.python3 ];
      } ''
        cd ${self}
        export HOME="$TMPDIR"
        # unittest writes its summary to STDERR, so 2>&1 is load-bearing here.
        python3 pkgs/oc-cost/test_oc_cost.py 2>&1 | tee "$TMPDIR/out.txt"

        # The count is PINNED, following checks.oc-auto-attach. "OK" alone is
        # also what a suite that silently stopped collecting tests prints.
        grep -q '^Ran 101 tests' "$TMPDIR/out.txt" || {
          echo "GATE FAILURE: expected 'Ran 101 tests'. If you added or removed" >&2
          echo "tests deliberately, update the count here in the same commit." >&2
          exit 1
        }
        grep -q '^OK$' "$TMPDIR/out.txt" || {
          echo "GATE FAILURE: oc-cost suite did not report OK." >&2
          exit 1
        }
        touch $out
      '';

      # opencode-serve-auth.sh: the serve pool's password/curl-args resolver.
      # `source`s the real production file (pkgs/opencode-serve-auth-sh's
      # default.nix is writeText of that same file), so this is production, not
      # a mirror. Deliberately bash-builtins-only, hence the bare input list.
      opencode-serve-auth-sh-tests = devboxPkgs.runCommand "opencode-serve-auth-sh-tests" {
        nativeBuildInputs = [ devboxPkgs.bash devboxPkgs.gnused devboxPkgs.coreutils ];
      } ''
        cd ${self}
        export HOME="$TMPDIR"
        bash pkgs/opencode-serve-auth-sh/test.sh 2>&1 | tee "$TMPDIR/out.txt"
        grep -q '^all opencode-serve-auth-sh tests passed' "$TMPDIR/out.txt" || {
          echo "GATE FAILURE: serve-auth suite did not reach its final pass line." >&2
          exit 1
        }
        touch $out
      '';

      # caveman's compaction exemption, driven against the SHIPPED plugin.js.
      #
      # This one already ran in CI, via pkgs/caveman/default.nix's
      # installCheckPhase inside the home closures -- so its unwired-test marker
      # was a false "not covered" claim. The guard rejects checkPhase as
      # evidence anyway (oc-session-list), and prescribes exactly this remedy:
      # "add a thin checks.* entry that runs the same script". Both now run. The
      # duplication is deliberate: the installCheckPhase gates `nix build
      # .#caveman`, home switches and the auto-bump PRs at artifact-build time,
      # while this makes the coverage legible to the guard and to a reader.
      caveman-exemption = devboxPkgs.runCommand "caveman-exemption-tests" {
        nativeBuildInputs = [ devboxPkgs.nodejs_22 ];
      } ''
        cd ${self}
        # Load-bearing, and copied from the installCheckPhase: unset, the test
        # falls back to `process.cwd()/exemption-scratch`, and with `cd ${self}`
        # that is the read-only store -- EACCES before a single assertion runs.
        export TEST_SCRATCH="$TMPDIR/caveman-exemption-scratch"
        export HOME="$TMPDIR"
        node pkgs/caveman/exemption-test.js \
          ${(localPkgsFor devboxSystem).caveman}/plugin/plugin.js 2>&1 \
          | tee "$TMPDIR/out.txt"
        grep -q '^OK: compaction exemption verified' "$TMPDIR/out.txt" || {
          echo "GATE FAILURE: caveman exemption test did not reach its OK line." >&2
          exit 1
        }
        touch $out
      '';

      # lgtm-gh. NAMED "-mirror-" on purpose: 9 of its 15 assertions drive a
      # COPY of the resolution logic that lives in pkgs/lgtm-gh/default.nix,
      # not the shipped wrapper, so a green result here is NOT behavioural
      # coverage of production. Do not read it as such.
      #
      # It is wired anyway because the remaining 6 assertions grep the real
      # default.nix and are the only live tripwire on it, and because the
      # alternative (leave it unwired until the mirror is gone) runs those 6
      # nowhere at all. The mirror exists because production cannot currently
      # be intercepted -- writeShellApplication prepends its runtimeInputs to
      # PATH, so a fake `gh` fixture loses to the pinned real one. Removing the
      # mirror means overriding that input with a stub package and driving the
      # real binary; that is workstation-dimz's job and its bead records this.
      lgtm-gh-mirror-tests = devboxPkgs.runCommand "lgtm-gh-mirror-tests" {
        nativeBuildInputs = [
          devboxPkgs.bash devboxPkgs.gnugrep devboxPkgs.coreutils
        ];
      } ''
        cd ${self}
        export HOME="$TMPDIR"
        bash pkgs/lgtm-gh/test.sh 2>&1 | tee "$TMPDIR/out.txt"
        grep -q '^all lgtm-gh tests passed' "$TMPDIR/out.txt" || {
          echo "GATE FAILURE: lgtm-gh suite did not reach its final pass line." >&2
          exit 1
        }
        # Pinned like oc-cost: the 6 production-source greps are the only part
        # of this suite that touches production, and a silent drop to 9 would
        # leave a green check testing nothing but the mirror.
        grep -q '^15 passed, 0 failed' "$TMPDIR/out.txt" || {
          echo "GATE FAILURE: expected '15 passed, 0 failed' (9 mirror + 6" >&2
          echo "production-source greps). Update deliberately, in the same commit." >&2
          exit 1
        }
        touch $out
      '';

      # git-work: the `work` worktree helper, sourced from its BUILT script.
      #
      # Two things had to change before this could be a check, neither of them
      # in the "grep the PASS line" shape the bead predicted. It ran `nix build
      # .#git-work` itself, which cannot happen inside a build sandbox (and
      # left a `result` symlink in the repo root); it now accepts WORK_BIN,
      # which this check supplies. And it inherited the invoking user's git
      # config: `git init --bare` + `git push origin main` passes only where
      # init.defaultBranch is already `main`, and in the sandbox it is
      # `master` (measured), so the suite now pins its own config file.
      git-work-tests = devboxPkgs.runCommand "git-work-tests" {
        nativeBuildInputs = [
          devboxPkgs.bash devboxPkgs.git devboxPkgs.coreutils
          devboxPkgs.gnugrep devboxPkgs.gnused
        ];
        # The built script under test. Also proves the derivation still exposes
        # bin/work, which the suite would otherwise discover only at runtime.
        WORK_BIN = "${(localPkgsFor devboxSystem).git-work}/bin/work";
      } ''
        cd ${self}
        export HOME="$TMPDIR"
        bash pkgs/git-work/test.sh 2>&1 | tee "$TMPDIR/out.txt"
        grep -q '^ALL PASS' "$TMPDIR/out.txt" || {
          echo "GATE FAILURE: git-work suite did not reach its ALL PASS line." >&2
          exit 1
        }
        # Sourcing a writeShellApplication also prepends ITS runtimeInputs to
        # PATH, which would mask a tool this check forgot to declare. Assert the
        # suite reported the binary we handed it rather than one it built.
        grep -q "^Testing: $WORK_BIN\$" "$TMPDIR/out.txt" || {
          echo "GATE FAILURE: suite did not test the WORK_BIN we supplied." >&2
          exit 1
        }
        touch $out
      '';

      # Repo-wide test reachability (bead workstation-oeyv).
      #
      # Five times a test file was added here and executed by nothing, each one
      # caught by a human reading code: an unrun writer (h0mp), a guard enforced
      # nowhere that sat red on main for weeks (frontdoor-opacity), a 71-assertion
      # suite with no doCheck (pscu), three TS harnesses totalling 238 tests
      # (dmat), and oc-session-list's 700-line suite sitting beside a checkPhase
      # that only ran `--help`. This makes the sixth fail CI instead.
      #
      # The meta-test runs in the SAME derivation on purpose. A guard that cannot
      # fail is precisely the defect being guarded against, and this repo has the
      # receipts: the opacity guard shipped inert. Splitting them into two checks
      # would let the meta-test be dropped while the guard kept reporting green.
      #
      # Deliberately run from $TMPDIR rather than `cd ${self}`. The guard resolves
      # the repo root from its own BASH_SOURCE, and pscu's suite passed for months
      # partly because nobody noticed it only worked from one directory.
      test-reachability = devboxPkgs.runCommand "test-reachability-guard" {
        nativeBuildInputs = [
          devboxPkgs.bash devboxPkgs.gnugrep devboxPkgs.gnused
          devboxPkgs.findutils devboxPkgs.gawk devboxPkgs.coreutils
        ];
      } ''
        cd "$TMPDIR"
        bash ${self}/users/dev/test-unwired-tests.sh 2>&1 | tee "$TMPDIR/guard.txt"
        bash ${self}/users/dev/test-unwired-tests-guard.sh 2>&1 | tee "$TMPDIR/meta.txt"

        # Assert the assertions RAN. Both scripts could exit 0 having adjudicated
        # nothing if find(1) or the seed broke; the store-prefix lesson is that a
        # check which merely runs a script proves nothing about what it proved.
        grep -q '^ALL PASS (test reachability)' "$TMPDIR/guard.txt" || {
          echo "GATE FAILURE: the reachability guard did not reach its ALL PASS line." >&2
          exit 1
        }
        grep -q '^ALL PASS (test-unwired-tests guard meta-test' "$TMPDIR/meta.txt" || {
          echo "GATE FAILURE: the guard's meta-test did not reach its ALL PASS line." >&2
          exit 1
        }
        touch $out
      '';

      # Serve registry PID fence wrapper invariant (bead workstation-4b1q).
      #
      # The fence is only sound while each serve wrapper `exec`s the serve: exec
      # makes the serve REPLACE the wrapper shell, so its pid IS the $$ that the
      # wrapper exported as OPENCODE_SERVE_EXPECTED_PID. Lose the exec and the
      # serve is a child with a different pid, fails the fence, and crash-loops
      # the whole pool on exit 21 -- at the next deploy, unattended.
      #
      # Checked STATICALLY at build time on purpose. A runtime probe can only
      # notice after the bad wrapper is already deployed, which is the window this
      # is meant to close. Step 4 of the roadmap requires the exec property be
      # ASSERTED rather than left as a comment; this is that assertion.
      serve-pid-fence = devboxPkgs.runCommand "serve-pid-fence-guard" {
        nativeBuildInputs = [ devboxPkgs.bash ];
      } ''
        cd ${self}
        bash users/dev/test-serve-pid-fence.sh
        touch $out
      '';

      # bazel scope shim behaviour (bead workstation-mqp3, epic workstation-rdsq).
      #
      # The shim keeps bazel builds out of the opencode serve cgroup, where four
      # OOM kills of opencode-serve@4098 on 2026-08-03/04 took down every session
      # on that serve and produced 960 HTTP 502s at the door.
      #
      # BEHAVIOURAL, not a grep: it runs the real built shim against a stubbed
      # systemd-run and asserts on the argv the shim actually emits. That matters
      # because every interesting failure mode here is silent -- a shim that
      # forgets to export XDG_RUNTIME_DIR (which is UNSET under `opencode serve`)
      # still installs, still runs builds, and still charges every one of them to
      # the serve. There is no symptom until the next OOM kill.
      bazel-scope-shim = devboxPkgs.runCommand "bazel-scope-shim-guard" {
        nativeBuildInputs = [ devboxPkgs.bash ];
        BAZEL_SCOPE_SHIM_BIN = "${(localPkgsFor devboxSystem).bazel-scope}/bin/bazel";
      } ''
        cd ${self}
        bash users/dev/test-bazel-scope-shim.sh
        touch $out
      '';

      # The shim's --slice= must name a slice unit that actually SHIPS.
      #
      # This is the one failure in the bazel work that no other check can see.
      # `systemd-run --slice=NAME` does not fail on an undeclared slice: it
      # silently creates a transient one with NO limits. So a rename on either
      # side leaves every build still scoped, still green, still passing
      # bazel-scope-shim above -- and silently unbounded in aggregate, with no
      # symptom until the host OOMs. home.cloudbox.nix binds both sides to one
      # `bazelSliceName`; this asserts that binding held all the way into the
      # built generation, which is the only place the two can be compared.
      bazel-slice-wiring = devboxPkgs.runCommand "bazel-slice-wiring-guard" {
        nativeBuildInputs = [ devboxPkgs.bash ];
        gen = self.homeConfigurations.cloudbox.activationPackage;
      } ''
        shim="$gen/home-path/bin/bazel"
        [ -e "$shim" ] || { echo "FAIL: no bazel on the generation's PATH"; exit 1; }

        slice=$(sed -n 's/^SLICE_NAME="\(.*\)"$/\1/p' "$(readlink -f "$shim")")
        [ -n "$slice" ] || { echo "FAIL: could not read SLICE_NAME from the shim"; exit 1; }

        unit="$gen/home-files/.config/systemd/user/$slice.slice"
        if [ ! -e "$unit" ]; then
          echo "FAIL: shim targets --slice=$slice but no $slice.slice unit ships."
          echo "      systemd would create it transiently with NO MemoryMax, so the"
          echo "      aggregate cap would silently not exist. See workstation-mqp3."
          exit 1
        fi

        grep -q '^MemoryMax=' "$unit" || {
          echo "FAIL: $slice.slice ships without a MemoryMax; the aggregate cap is the"
          echo "      entire reason the slice exists."
          exit 1
        }

        echo "ALL PASS (bazel slice wiring: shim --slice=$slice matches a capped $slice.slice)"
        touch $out
      '';

      # Same guard as bazel-slice-wiring, for the oc-scoped-shell wrapper.
      #
      # Worth restating why this needs its own check rather than review: the
      # wrapper's SLICE_NAME is in the shell script and the slice unit is a Nix
      # attribute, so nothing in either language can see the other. A rename on
      # either side leaves every command still scoped, still green, still passing
      # the wrapper's own unit tests -- and silently unbounded in aggregate,
      # because systemd-run invents an uncapped transient slice rather than
      # failing. The symptom would be a host OOM, weeks later.
      agent-slice-wiring = devboxPkgs.runCommand "agent-slice-wiring-guard" {
        nativeBuildInputs = [ devboxPkgs.bash devboxPkgs.gnugrep devboxPkgs.gnused ];
        gen = self.homeConfigurations.cloudbox.activationPackage;
      } ''
        managed="$gen/home-files/.config/opencode/opencode.managed.json"
        [ -e "$managed" ] || { echo "FAIL: opencode.managed.json does not ship in the cloudbox generation"; exit 1; }

        shell_bin=$(grep -oP '"shell":\s*"\K[^"]+' "$managed" || true)
        [ -n "$shell_bin" ] || { echo "FAIL: opencode.managed.json does not set shell for cloudbox"; exit 1; }

        slice=$(grep -oP 'SLICE_NAME="\K[^"]+' "$shell_bin" || grep -oP '--slice=\K[a-zA-Z0-9_-]+' "$shell_bin" | head -n1 || true)
        [ -n "$slice" ] || { echo "FAIL: could not read SLICE_NAME from $shell_bin"; exit 1; }

        unit="$gen/home-files/.config/systemd/user/$slice.slice"
        if [ ! -e "$unit" ]; then
          echo "FAIL: oc-scoped-shell targets --slice=$slice but no $slice.slice unit ships."
          echo "      systemd-run would create it transiently with NO MemoryMax, so the"
          echo "      aggregate cap would silently not exist. See workstation-yt0p."
          exit 1
        fi

        grep -q '^MemoryMax=' "$unit" || {
          echo "FAIL: $slice.slice ships without a MemoryMax; the aggregate cap is the"
          echo "      entire reason the slice exists."
          exit 1
        }

        echo "ALL PASS (agent slice wiring: wrapper --slice=$slice matches a capped $slice.slice)"
        touch $out
      '';

      oc-scoped-shell = devboxPkgs.runCommand "oc-scoped-shell-tests" {
        nativeBuildInputs = [ devboxPkgs.bash devboxPkgs.coreutils ];
        WRAPPER_BIN = "${(localPkgsFor devboxSystem).oc-scoped-shell}/bin/oc-scoped-shell";
      } ''
        bash ${self}/pkgs/oc-scoped-shell/test.sh
        touch $out
      '';

      # Headless-Lua unit tests for assets/nvim/lua/user/session_switcher/.
      #
      # Registered here rather than bolted onto pkgs/oc-auto-attach's
      # test-project-key.sh, which was the obvious home: that file is a real
      # `nvim -l` harness and the right pattern to copy, but its derivation
      # sets no doCheck/checkPhase and CI runs only `nix flake check`, so
      # nothing executes it. Its assertions are inert. Landing S4's tests there
      # would have repeated the frontdoor-opacity mistake documented directly
      # above -- a guard nothing runs is documentation with a shebang.
      nvim-lua = devboxPkgs.runCommand "nvim-lua-tests" {
        nativeBuildInputs = [
          devboxPkgs.bash devboxPkgs.neovim devboxPkgs.gnugrep devboxPkgs.gnused devboxPkgs.coreutils
        ];
      } ''
        cd ${self}
        export HOME="$TMPDIR"
        bash assets/nvim/test-session-switcher.sh 2>&1 | tee "$TMPDIR/out.txt"

        grep -q '^all session_switcher lua tests passed' "$TMPDIR/out.txt" || {
          echo "GATE FAILURE: session_switcher lua suite did not reach its final pass line." >&2
          exit 1
        }
        [ "$(grep -c '^PASS  ' "$TMPDIR/out.txt")" = 6 ] || {
          echo "GATE FAILURE: expected 6 'PASS  ' lines, got" \
               "$(grep -c '^PASS  ' "$TMPDIR/out.txt")." >&2
          exit 1
        }
        grep -q '^PASS  session_switcher\.cli unit tests (31 assertions via nvim -l)' "$TMPDIR/out.txt" || {
          echo "GATE FAILURE: session_switcher.cli did not report expected 31 assertions." >&2
          exit 1
        }
        grep -q '^PASS  session_switcher\.discovery + \.rpc unit tests (69 assertions via nvim -l)' "$TMPDIR/out.txt" || {
          echo "GATE FAILURE: session_switcher.discovery + .rpc did not report expected 69 assertions." >&2
          exit 1
        }
        grep -q '^PASS  session_switcher\.model unit tests (87 assertions via nvim -l)' "$TMPDIR/out.txt" || {
          echo "GATE FAILURE: session_switcher.model did not report expected 87 assertions." >&2
          exit 1
        }
        grep -q '^PASS  session_switcher\.spec unit tests (310 assertions via nvim -l)' "$TMPDIR/out.txt" || {
          echo "GATE FAILURE: session_switcher.spec did not report expected 310 assertions." >&2
          exit 1
        }
        touch $out
      '';

      # Locks the serve-canary's staleness comparison to a store-path PREFIX
      # match. On 2026-08-01 an operator hand-wrote the full-path form
      # (`readlink -f profile` vs `readlink /proc/<pid>/exe`), which reports
      # STALE unconditionally because bin/opencode execs bin/.opencode-wrapped,
      # and restarted the whole serve pool on that false signal, killing live
      # sessions. The deployed canary was already correct -- and had no test at
      # all, so nothing would have caught it regressing into that form.
      # Bash-only; adds seconds. See pkgs/opencode-store-prefix-sh/test.sh.
      #
      # The positive path (an executable, correctly shaped reference resolves to
      # its prefix) needs a REAL /nix/store path: the shape gate is anchored at
      # the literal /nix/store, and a test may not write there. Without a fixture
      # the assertion SKIPped -- and SKIPping is what CI actually did, which made
      # the gate blind to the one regression that fails quiet: a
      # opencode_reference_prefix that returns "" unconditionally leaves every
      # pass UNKNOWN, so drift detection is dead forever and no alert ever fires.
      # Every other assertion expects "", so they all stay green through it.
      #
      # So build a throwaway package whose name matches the shape gate and hand
      # its path to the suite, then assert the assertion RAN. Grepping for the
      # PASS line is the point: a future edit that drops the env var would
      # otherwise silently restore the blind spot.
      # Plugin-load canary logic (E2, workstation-5yox step 2). The canary itself
      # is a minutely systemd oneshot, and everything hard about it -- byte-offset
      # windowing over a shared 668MB log, rotation and truncation detection, the
      # partial-line rule, the latch lifecycle that turns edge detection into
      # level alerting, and the probe status table -- is invisible in a green
      # timer. Both of the tempting one-liners for that table are silently wrong
      # in opposite directions (page on every routine restart, or go permanently
      # quiet when upstream moves a route), so the table is asserted row by row.
      #
      # Registered here because `nix flake check` is all CI runs. That is not a
      # theoretical concern in this bead: it already shipped a well-designed pin
      # guard wired into no CI path at all, and #292 landed the same day this was
      # written because three plugin test harnesses were green and unreachable.
      #
      # gawk is a real dependency, not incidental: the partial-line rule uses
      # gawk's RT to tell a terminated record from a final unterminated one, which
      # is what stops the canary from consuming a half-written failure line.
      # The mono-root fast-forwarder. Worth a check rather than trusting review:
      # the script decides between fast-forwarding and skipping in a SHARED
      # working tree that holds peer sessions' uncommitted data, so the
      # never-discard promise and the never-silently-skip-forever tripwire both
      # need pinning. Test 7 in particular pins a bug found by review, not by
      # running it: `merge --ff-only origin/main` while parked on a feature
      # branch silently relocates that branch.
      ff-mono-root = devboxPkgs.runCommand "ff-mono-root-tests" {
        nativeBuildInputs = [
          devboxPkgs.bash devboxPkgs.git devboxPkgs.coreutils
          devboxPkgs.gnugrep devboxPkgs.util-linux
        ];
      } ''
        cd ${self}
        export HOME="$TMPDIR"
        bash assets/scripts/test-ff-mono-root.sh
        touch $out
      '';

      # The lane dead-man watcher. Checked here because its whole job is to be the thing that
      # still speaks when the subject has gone quiet, and every one of its interesting cases is
      # a DATE case that cannot be exercised by waiting: the Monday false-positive (a Friday
      # success is 3 calendar days old but only ONE missed weekday slot), the UTC-stamp vs
      # local-slot mismatch, and the DST week. It needs no network and no credentials, which is
      # exactly what lets it be checked here with no mocks beyond a recorder for the alerter.
      lane-deadman-watch = devboxPkgs.runCommand "lane-deadman-watch-tests" {
        nativeBuildInputs = [
          devboxPkgs.bash devboxPkgs.coreutils devboxPkgs.gnugrep
        ];
      } ''
        cd ${self}
        export HOME="$TMPDIR"
        bash assets/scripts/test-lane-deadman-watch.sh
        touch $out
      '';

      # The primary-root trunk-drift detector (bead workstation-v03j.9). It is
      # the only layer in the worktree-guard family that WATCHES rather than
      # blocks, so its failure mode is silence -- exactly the failure this epic
      # has shipped before (a guard plugin that never loaded on any process, and
      # a suite that set fail=1 in a subshell and so could never go red). The
      # suite is therefore mutation-checked: 19 mutants of the detector were run
      # against it and all 19 were killed, including the two that matter most --
      # rewriting the ahead test as `@{u}..HEAD` (blind to a commit on a branch
      # with no upstream, i.e. the incident this was built for) and dropping
      # `--no-optional-locks` (which lets a read-only walk rewrite a peer's
      # index).
      trunk-drift-detector = devboxPkgs.runCommand "trunk-drift-detector-tests" {
        nativeBuildInputs = [
          devboxPkgs.bash devboxPkgs.git devboxPkgs.coreutils
          devboxPkgs.gnugrep devboxPkgs.findutils devboxPkgs.util-linux
        ];
      } ''
        cd ${self}
        export HOME="$TMPDIR"
        bash assets/scripts/test-trunk-drift-detector.sh > "$TMPDIR/out.txt" || {
          cat "$TMPDIR/out.txt"; exit 1;
        }
        cat "$TMPDIR/out.txt"
        # Assert the assertions RAN, not merely that bash exited 0.
        grep -q '^trunk-drift-detector: ALL PASS$' "$TMPDIR/out.txt"
        touch $out
      '';

      # Stale-deploy gate (bead workstation-h0mp). The gate aborts a
      # `home-manager switch` that would drop live commits, so its logic can
      # only be exercised by a real switch -- which on this box means either
      # deploying or refusing to deploy for every other agent. The decision
      # logic therefore lives in a sourceable library with real throwaway git
      # repos behind it, and runs here.
      hm-deploy-gate = devboxPkgs.runCommand "hm-deploy-gate-test" {
        nativeBuildInputs = [ devboxPkgs.bash devboxPkgs.git devboxPkgs.coreutils ];
      } ''
        cd ${self}
        bash pkgs/hm-deploy-gate-sh/test.sh > "$TMPDIR/out.txt" || {
          cat "$TMPDIR/out.txt"; exit 1;
        }
        cat "$TMPDIR/out.txt"
        # Assert the assertions RAN. A suite that exits 0 having executed
        # nothing is the failure mode this whole roadmap is about.
        grep -q '^hm-deploy-gate: ALL PASS$' "$TMPDIR/out.txt"
        touch $out
      '';

      # Drift canary (bead workstation-4ze8), layer 2 for the stale-deploy gate
      # above. The gate is deployed BY the thing it guards, so it cannot close
      # its own holes; this library is the detector that runs from a NixOS
      # system unit instead. Only the pure decision logic runs here -- the unit
      # itself needs a live profile, a real clone and a network fetch, none of
      # which exist in the sandbox.
      #
      # NOT COVERAGE EVIDENCE FOR THE TIMER. This roadmap already rejected a
      # host-timer channel as a sandbox-checkable coverage claim; the check
      # below proves the predicates and nothing about whether the unit fires.
      hm-deploy-canary = devboxPkgs.runCommand "hm-deploy-canary-test" {
        nativeBuildInputs = [ devboxPkgs.bash devboxPkgs.git devboxPkgs.coreutils ];
      } ''
        cd ${self}
        bash pkgs/hm-deploy-canary-sh/test.sh > "$TMPDIR/out.txt" || {
          cat "$TMPDIR/out.txt"; exit 1;
        }
        cat "$TMPDIR/out.txt"
        grep -q '^hm-deploy-canary: ALL PASS$' "$TMPDIR/out.txt"
        # Pin the count. ALL PASS is also what a suite that executed nothing
        # prints, and every sibling check in this file stops at the banner.
        n="$(grep -c '^  PASS: ' "$TMPDIR/out.txt")"
        if [ "$n" -ne 36 ]; then
          echo "expected 36 assertions, ran $n" >&2; exit 1
        fi
        touch $out
      '';

      # Behavioural half of the drift canary: runs the SHIPPED runner
      # (pkgs/hm-deploy-canary-sh/canary.sh) end to end through its seams,
      # against scratch state and a stub alert sink. The library check above
      # proves the predicates; it cannot see a canary whose glue never reaches
      # the alert sink. That is not hypothetical -- the sibling gate silently
      # ALLOWED every deploy when its library failed to source, and only its
      # behavioural suite caught it.
      hm-deploy-canary-behaviour = devboxPkgs.runCommand "hm-deploy-canary-behaviour" {
        nativeBuildInputs = [ devboxPkgs.bash devboxPkgs.git devboxPkgs.coreutils ];
      } ''
        export HOME="$TMPDIR/home"; mkdir -p "$HOME"
        cd ${self}
        bash pkgs/hm-deploy-canary-sh/test-behaviour.sh > "$TMPDIR/out.txt" || {
          cat "$TMPDIR/out.txt"; exit 1;
        }
        cat "$TMPDIR/out.txt"
        grep -q '^hm-deploy-canary-behaviour: ALL PASS$' "$TMPDIR/out.txt"
        n="$(grep -c '^  PASS: ' "$TMPDIR/out.txt")"
        if [ "$n" -ne 19 ]; then
          echo "expected 19 assertions, ran $n" >&2; exit 1
        fi
        touch $out
      '';

      # Behavioural half: runs the ACTUAL activation script from the evaluated
      # cloudbox config through its three test seams. The library check above
      # only proves the decision logic; it cannot see a guard whose glue never
      # reaches `exit 1`. This check earned its place immediately -- it caught
      # the gate silently ALLOWING every deploy when its own library failed to
      # source (empty verdict, no matching case branch). Nothing in the library
      # suite could have found that.
      hm-deploy-gate-behaviour = devboxPkgs.runCommand "hm-deploy-gate-behaviour" {
        nativeBuildInputs = [ devboxPkgs.bash devboxPkgs.git devboxPkgs.coreutils devboxPkgs.gnused ];
        GATE_SCRIPT = devboxPkgs.writeText "hm-deploy-gate-activation.sh"
          self.homeConfigurations.cloudbox.config.home.activation.assertFreshDeploy.data;
      } ''
        export HOME="$TMPDIR/home"; mkdir -p "$HOME"
        cd ${self}
        bash pkgs/hm-deploy-gate-sh/test-behaviour.sh > "$TMPDIR/out.txt" || {
          cat "$TMPDIR/out.txt"; exit 1;
        }
        cat "$TMPDIR/out.txt"
        grep -q '^hm-deploy-gate-behaviour: ALL PASS$' "$TMPDIR/out.txt"
        touch $out
      '';

      # oc-mcp-enable grants a RUNNING session an MCP server (connect + a
      # session-scoped allow rule). The suite pins the two things a silent
      # regression would break: the `<server>_*` permission pattern (a wrong
      # pattern grants nothing, and the session just fails to use the tool with
      # no error anywhere), and the source guards -- connect-before-PATCH,
      # front-door-only, and never disconnecting a per-directory-shared client.
      oc-mcp-enable-tests = devboxPkgs.runCommand "oc-mcp-enable-test" {
        nativeBuildInputs = [ devboxPkgs.bash devboxPkgs.jq devboxPkgs.gnugrep devboxPkgs.coreutils ];
      } ''
        cd ${self}
        bash pkgs/oc-mcp-enable/test.sh > "$TMPDIR/out.txt" || {
          cat "$TMPDIR/out.txt"; exit 1;
        }
        cat "$TMPDIR/out.txt"
        # Assert the assertions RAN: a suite that exits 0 having executed
        # nothing (e.g. jq missing, helper renamed) is green and worthless.
        grep -q '^all oc-mcp-enable helper tests passed$' "$TMPDIR/out.txt"
        touch $out
      '';

      # oc-throwaway-serve's suite. The wrapper's job is to make a throwaway
      # serve provably unable to touch the production database (incident
      # 2026-08-14, where the hand-rolled XDG_DATA_HOME recipe silently did the
      # opposite). Its behavioural half runs the real /proc/<pid>/fd measurement
      # against real processes holding real fds -- including a -wal-only handle,
      # which a naive check misses -- plus the negative control, so a check that
      # always fires cannot pass. The source guards pin each env var that must be
      # set or scrubbed; dropping one is silent, which is exactly how OPENCODE_DB
      # was missed in the first place.
      oc-throwaway-serve-tests = devboxPkgs.runCommand "oc-throwaway-serve-test" {
        nativeBuildInputs = [ devboxPkgs.bash devboxPkgs.gnugrep devboxPkgs.coreutils ];
      } ''
        cd ${self}
        bash pkgs/oc-throwaway-serve/test.sh > "$TMPDIR/out.txt" || {
          cat "$TMPDIR/out.txt"; exit 1;
        }
        cat "$TMPDIR/out.txt"
        # Assert the assertions RAN: a suite that exits 0 having executed nothing
        # is green and worthless.
        grep -q '^all oc-throwaway-serve tests passed' "$TMPDIR/out.txt"
        touch $out
      '';

      plugin-canary = devboxPkgs.runCommand "opencode-plugin-canary-test" {
        nativeBuildInputs = [ devboxPkgs.bash devboxPkgs.gawk devboxPkgs.gnugrep devboxPkgs.gnused devboxPkgs.coreutils ];
      } ''
        cd ${self}
        bash pkgs/opencode-plugin-canary-sh/test.sh
        touch $out
      '';

      # Behavioural half of the canary suite: runs the ACTUAL ExecStart script
      # from the evaluated cloudbox config, via its four test seams, against a
      # scratch state dir and a dead door.
      #
      # The check above asserts the library's logic plus three static greps for
      # ordering markers in configuration.nix. Those greps are deletion
      # tripwires and little more -- a refactor hoisting the offset write above
      # the latch loop keeps the comment and passes all three. The property they
      # gesture at is the entire design: driftAlert is a throttle, not a
      # scheduler, so an edge-triggered caller sends one page and goes quiet
      # forever. This check executes that property instead of describing it: it
      # runs three passes with no new log content and requires three
      # re-invocations, and it requires an alert whose delivery failed at
      # detection time to still be delivered on a later pass.
      #
      # Hermetic: the door URL is pointed at a dead port, so leg A takes its SKIP
      # path and the sandbox needs no network.
      plugin-canary-behaviour = devboxPkgs.runCommand "opencode-plugin-canary-behaviour" {
        nativeBuildInputs = [ devboxPkgs.bash devboxPkgs.coreutils devboxPkgs.gawk devboxPkgs.gnugrep devboxPkgs.util-linux ];
        CANARY_SCRIPT = self.nixosConfigurations.cloudbox.config.systemd.services.opencode-plugin-canary.serviceConfig.ExecStart;
      } ''
        cd ${self}
        bash pkgs/opencode-plugin-canary-sh/test-behaviour.sh
        touch $out
      '';

      # The SAME behavioural suite against DEVBOX's real ExecStart.
      #
      # This is the load-bearing half of workstation-fg2w. Leg B was extracted
      # into the shared library so devbox runs the identical code rather than a
      # fork, but "shares a library" is not the property that matters -- the
      # property is that devbox's assembled unit actually tails a log, latches,
      # and re-alerts. Only running devbox's own evaluated script proves that,
      # and it is what catches a host-shaped omission (a missing variable, a lock
      # gate left out) that the cloudbox check passes straight over.
      #
      # LEGS=B: devbox has no front door, so the leg A assertions are skipped by
      # declaration rather than by inference. Sniffing "no probe alert appeared"
      # would report a BROKEN leg A as a passing devbox.
      plugin-canary-behaviour-devbox = devboxPkgs.runCommand "opencode-plugin-canary-behaviour-devbox" {
        nativeBuildInputs = [ devboxPkgs.bash devboxPkgs.coreutils devboxPkgs.gawk devboxPkgs.gnugrep devboxPkgs.util-linux ];
        # home-manager normalises Service.ExecStart to a LIST, while the NixOS
        # module yields a bare string. Unwrapped explicitly: the naive
        # cross-module copy fails eval with "cannot coerce a list to a string",
        # and the tempting `toString` "fix" would silently hand the suite a
        # space-joined string that is not an executable path.
        CANARY_SCRIPT =
          let e = self.homeConfigurations.dev.config.systemd.user.services.opencode-plugin-canary.Service.ExecStart;
          in if builtins.isList e then builtins.head e else e;
        CANARY_LEGS = "B";
      } ''
        cd ${self}
        bash pkgs/opencode-plugin-canary-sh/test-behaviour.sh
        touch $out
      '';

      store-prefix = devboxPkgs.runCommand "opencode-store-prefix-test" {
        nativeBuildInputs = [ devboxPkgs.bash devboxPkgs.gnugrep ];
        OPENCODE_TEST_PKG_BIN = "${devboxPkgs.runCommand "opencode-patched-0.0.0-fixture" { } ''
          mkdir -p $out/bin
          printf '#!/bin/sh\nexit 0\n' > $out/bin/opencode
          chmod +x $out/bin/opencode
        ''}/bin/opencode";
      } ''
        cd ${self}
        bash pkgs/opencode-store-prefix-sh/test.sh > "$TMPDIR/out.txt" || {
          cat "$TMPDIR/out.txt"; exit 1;
        }
        cat "$TMPDIR/out.txt"
        grep -q '^PASS  reference prefix returned for an executable opencode package path' \
          "$TMPDIR/out.txt" || {
          echo "GATE FAILURE: the positive reference-resolution assertion did not run." >&2
          echo "A skipped assertion is not a passing one -- see OPENCODE_TEST_PKG_BIN." >&2
          exit 1
        }
        touch $out
      '';

      # Loader-replica pin guard. Same rationale as the opacity guard above.
      #
      # The assertion also exists as a vitest case, which -- as of the
      # plugin-vitest check below -- now DOES run in CI. This bash copy stays
      # anyway, deliberately, for two reasons. It is dependency-free, so it
      # still fires when the node_modules stage or vitest itself is broken,
      # which is exactly when the vitest copy goes dark. And it covers ground
      # vitest cannot reach: the LOADER_SEMANTICS_PIN marker inside
      # pkgs/opencode-plugin-bundle/default.nix, which is a third copy of loader
      # semantics living in a derivation, not in a test file.
      loader-pin = devboxPkgs.runCommand "loader-pin-guard" {
        # gnupatch/diffutils/coreutils: the guard recomposes the patched loader
        # fixture from pristine upstream + our own patch and byte-compares it,
        # and hashes the patch. All offline -- the sandbox has no network, which
        # is exactly why the cross-repo half of this lives in
        # .github/workflows/update-opencode-patched.yml instead.
        nativeBuildInputs = with devboxPkgs; [ bash gnupatch diffutils coreutils ];
      } ''
        cd ${self}
        bash users/dev/test-loader-pin.sh
        touch $out
      '';

      monitor-pr-once = devboxPkgs.runCommand "monitor-pr-once-guard" {
        nativeBuildInputs = with devboxPkgs; [ bash python3 coreutils gnugrep ];
      } ''
        cd ${self}
        bash users/dev/test-monitor-pr-once.sh
        touch $out
      '';

      # ---- assets/opencode/plugins TypeScript suites (bead workstation-dmat) ----
      #
      # WHY THESE EXIST: this directory held THREE test harnesses and CI ran
      # NONE of them -- 205 vitest tests, 34 bun tests, and a 116-line
      # integration script, all invisible to `nix flake check`. Worse than
      # absent: `npm test` exited GREEN over the bun suite it never loaded
      # (vitest's `include` matches *.test.ts, and that file is a bun *.spec.ts),
      # so the pre-push signal actively said "covered". The same sentence the
      # opacity guard above earned applies to a test nobody runs.
      #
      # Split into separate checks on purpose: CI runs `nix flake check
      # --keep-going`, so three checks report three independent verdicts in one
      # run, and the check NAME attributes the failure without reading a log.

      # Naming taxonomy + runner-claim guard. Bash-only and dependency-free, so
      # it still fails when the node_modules stage or a runner is itself broken
      # -- precisely when the two checks below go dark.
      plugin-test-coverage = devboxPkgs.runCommand "plugin-test-coverage-guard" {
        nativeBuildInputs = [ devboxPkgs.bash devboxPkgs.gnugrep devboxPkgs.findutils ];
      } ''
        cd ${self}
        bash assets/opencode/plugins/test-runner-coverage.sh
        touch $out
      '';

      # Typecheck the plugins directory.
      #
      # Added because its absence let a defect ship in the very PR that added
      # this check: four test fixtures used `unread_state: "present"`, a value
      # that is not in the `"counted" | "absent" | "unavailable"` union. `bun
      # test` transpiles without typechecking and `bun build` does not check
      # either, so the suite was green and the literal was meaningless. tsc
      # reported exactly those four errors and nothing else -- the tree is
      # otherwise clean, so this gate costs nothing to keep green.
      #
      # The frontdoor tsc run above covers a different directory; this one is
      # the plugins' own tsconfig (strict, noEmit, isolatedModules).
      plugin-tsc = devboxPkgs.runCommand "plugin-tsc-typecheck" {
        nativeBuildInputs = [ devboxPkgs.nodejs ];
      } ''
        cp -r --no-preserve=mode,ownership ${self} ./repo
        cd ./repo/assets/opencode/plugins
        ln -s ${pluginTestNodeModules}/node_modules ./node_modules
        export HOME="$TMPDIR/home"
        mkdir -p "$HOME"

        node_modules/.bin/tsc --noEmit 2>&1 | tee "$TMPDIR/tsc.txt"
        if [ -s "$TMPDIR/tsc.txt" ]; then
          echo "GATE FAILURE: tsc reported errors in assets/opencode/plugins." >&2
          exit 1
        fi
        touch $out
      '';

      # The vitest half (test/**/*.test.ts).
      #
      # Copies the whole ${self} rather than just the plugins directory because
      # test/plugin-loader-contract.test.ts resolves ../../../users/dev/*.nix and
      # needs the real repo layout; with only the plugins dir it fails ENOENT
      # while the other eight files pass.
      plugin-vitest = devboxPkgs.runCommand "plugin-vitest-tests" {
        nativeBuildInputs = [ devboxPkgs.nodejs ];
      } ''
        cp -r --no-preserve=mode,ownership ${self} ./repo
        cd ./repo/assets/opencode/plugins
        ln -s ${pluginTestNodeModules}/node_modules ./node_modules
        export HOME="$TMPDIR/home"
        mkdir -p "$HOME"

        node_modules/.bin/vitest run \
          --reporter=default \
          --reporter=json --outputFile.json="$TMPDIR/vitest.json"

        # A green runner is NOT evidence that anything ran. Two assertions.
        #
        # (1) Nothing was SKIPPED. vitest exits 0 with `describe.skip`, keeps the
        # file in testResults, and leaves numTotalTests unchanged -- so a skip is
        # invisible to both the exit code and the file-set check below (measured:
        # skipping one describe moved numPendingTests 0 -> 4 and nothing else).
        # Baseline here is a clean 0 pending / 0 todo, so demanding that costs
        # nothing and closes the cheapest possible way to silence a failing test
        # at 2am. Per the store-prefix check above: a skipped assertion is not a
        # passing one.
        #
        # (2) The set of files vitest EXECUTED equals the *.test.ts files on
        # disk. Deliberately a set and not a count: the failure this bead exists
        # to fix was whole-file EXCLUSION (a suite silently outside `include`),
        # which a count cannot see and which a hardcoded count would invite
        # reviewers to "fix" by bumping the number. The set is self-maintaining --
        # a new test file appears on both sides at once.
        #
        # Paths are compared repo-relative, not by basename: `include` is
        # `test/**`, so a nested test/unit/foo.test.ts is legitimate, and
        # basenames would both collide across directories and mis-report a
        # nested file as missing.
        node -e 'const fs=require("fs"),path=require("path");const j=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));if(!(j.numTotalTests>0)){console.error("GATE FAILURE: vitest reported 0 tests.");process.exit(1)}if(j.numPendingTests>0||j.numTodoTests>0){console.error("GATE FAILURE: "+j.numPendingTests+" skipped and "+j.numTodoTests+" todo test(s). A skipped test is not a passing one; un-skip it or delete it.");process.exit(1)}console.log(j.testResults.map(function(r){return path.relative(process.cwd(),r.name)}).sort().join("\n"))' \
          "$TMPDIR/vitest.json" > "$TMPDIR/ran.txt"

        find test -name '*.test.ts' -type f | sort > "$TMPDIR/ondisk.txt"

        if ! diff -u --label "on disk" --label "actually ran" "$TMPDIR/ondisk.txt" "$TMPDIR/ran.txt"; then
          echo "" >&2
          echo "GATE FAILURE: the *.test.ts files on disk are not the files vitest ran." >&2
          echo "  A '-' line is a file that EXISTS but was NOT RUN -- silently excluded" >&2
          echo "    by the include pattern in assets/opencode/plugins/vitest.config.ts." >&2
          echo "    That is the whole defect this check was added to end." >&2
          echo "  A '+' line is a file vitest ran that this check did not expect --" >&2
          echo "    most likely the on-disk glob above needs widening, not the config." >&2
          exit 1
        fi
        touch $out
      '';

      # The bun half (test/*.spec.ts). Needs no node_modules: that suite's
      # import graph is closed over relative + node: + bun: specifiers only.
      #
      # The glob is EXPLICIT rather than a bare `bun test` because bun's default
      # matcher also picks up the *.test.ts files, which import vitest and fail
      # under it (measured: 43 failures, 4 errors). Globbing is also what makes
      # a newly added *.spec.ts run automatically -- execution is enumeration.
      plugin-bun = devboxPkgs.runCommand "plugin-bun-tests" {
        nativeBuildInputs = [ devboxPkgs.bash devboxPkgs.bun devboxPkgs.gnugrep devboxPkgs.gnused devboxPkgs.coreutils ];
      } ''
        cp -r --no-preserve=mode,ownership ${self} ./repo
        cd ./repo/assets/opencode/plugins

        # Seed a REAL-looking overlay dir. test/oc-session-list.spec.ts has a
        # tripwire asserting the live overlay directory is not touched by the
        # suite; with an empty HOME it compares [] to [] and passes having
        # tested nothing.
        #
        # The sentinel must be GC-ELIGIBLE or the seeding is decoration. An
        # arbitrary blob (say {"sentinel":true}) is skipped by runOrphanGc at
        # oc-session-list-state.ts:205 for want of numeric pid/heartbeat, so it
        # survives even a GC aimed straight at this directory -- i.e. it stays
        # green through the exact disaster the tripwire exists to catch
        # (measured). A dead pid plus an epoch heartbeat makes it collectable,
        # so a mispointed GC deletes it and both this check and the tripwire go
        # red.
        export HOME="$TMPDIR/home"
        mkdir -p "$HOME/.local/share/opencode/session-state.d"
        echo '{"version":1,"serveId":"sentinel","pid":999999,"heartbeat":0,"directory":"/sentinel","sessions":{}}' \
          > "$HOME/.local/share/opencode/session-state.d/sentinel.json"

        n=0
        for f in test/*.spec.ts; do
          echo "== bun test $f =="
          bun test "$f" 2>&1 | tee "$TMPDIR/bun-out.txt"
          grep -qE '^ *[1-9][0-9]* pass' "$TMPDIR/bun-out.txt" \
            || { echo "GATE FAILURE: $f reported no passing tests." >&2; exit 1; }
          grep -qE '^ *0 fail' "$TMPDIR/bun-out.txt" \
            || { echo "GATE FAILURE: $f reported failures." >&2; exit 1; }

          # Assertion count is pinned: a suite whose assertions are deleted or
          # early-returned would still pass the pass/fail/skip gate above.
          expects=$(sed -nE 's/^ *([0-9]+) expect\(\) calls.*/\1/p' "$TMPDIR/bun-out.txt" | head -1)
          expects=''${expects:-0}
          case "$f" in
            test/oc-session-list.spec.ts)
              expected_expects=262
              ;;
            *)
              echo "GATE FAILURE: unrecognised spec file $f has no pinned expect() count in flake.nix." >&2
              echo "Register it in the case block with its measured expect() call count." >&2
              exit 1
              ;;
          esac
          if [ "$expects" -ne "$expected_expects" ]; then
            echo "GATE FAILURE: $f reported $expects expect() call(s); exactly $expected_expects is expected." >&2
            echo "If you added or removed assertions, update this pin with the measured count." >&2
            exit 1
          fi

          # Skips are counted, not ignored -- same reasoning as the vitest gate.
          # EXACTLY ONE is expected and it is a known, reviewed degradation: the
          # "against the REAL routing DB" case in oc-session-list.spec.ts, which
          # needs a live pigeon daemon DB under $HOME and can never run in a
          # sandbox. It is marked `it.skipIf` rather than early-returning so it
          # lands in this count instead of masquerading as a pass.
          #
          # Deterministic here because HOME is the sandbox's, so the real DBs are
          # always absent. A SECOND skip appearing means someone silenced a test
          # that could have run; make that a decision, not a default.
          skips=$(sed -nE 's/^ *([0-9]+) skip.*/\1/p' "$TMPDIR/bun-out.txt" | head -1)
          skips=''${skips:-0}
          if [ "$skips" -ne 1 ]; then
            echo "GATE FAILURE: $f reported $skips skipped test(s); exactly 1 is expected" >&2
            echo "(the REAL-routing-DB case). A new skip is a coverage loss that must be" >&2
            echo "reviewed -- justify it here or un-skip the test." >&2
            exit 1
          fi
          n=$((n + 1))
        done

        if [ "$n" -eq 0 ]; then
          echo "GATE FAILURE: no test/*.spec.ts matched, so this check ran nothing." >&2
          exit 1
        fi

        # The tripwire above is only meaningful while its subject exists.
        [ -f "$HOME/.local/share/opencode/session-state.d/sentinel.json" ] \
          || { echo "GATE FAILURE: the suite deleted the sentinel overlay file." >&2; exit 1; }

        echo "bun: $n spec file(s) executed"
        touch $out
      '';

      # The BUILT ARTIFACT (pkgs/oc-session-list/test.sh stages 3-4).
      #
      # That script sat unrun despite its derivation setting doCheck = true --
      # the checkPhase only ran `--help`. It is the sole coverage of the nix-built
      # binary: recursive-CTE root resolution over a 3-level session tree,
      # archived-session exclusion, and the S3 nodata-vs-idle distinction whose
      # absence made the 2026-08-01 outage look normal for ~9 hours.
      #
      # The binary is injected via OC_SESSION_LIST_BIN (same fixture-injection
      # shape as store-prefix above) because the script otherwise runs `nix build`
      # on itself, which a build sandbox cannot do. A side effect worth naming:
      # this is the first time oc-session-list is BUILT in CI rather than merely
      # evaluated.
      # oc-context's suite: hermetic (stdlib unittest, temp sqlite fixtures, no
      # network -- the model catalog is injected via --models-json/--no-server),
      # so it runs as a plain check rather than needing a workflow step.
      #
      # A `checks.*` entry rather than leaning on pkgs/oc-context's checkPhase,
      # because test-unwired-tests.sh deliberately does not accept checkPhase as
      # evidence -- see the oc-session-list story in its header.
      oc-context = devboxPkgs.runCommand "oc-context-tests" {
        nativeBuildInputs = [ devboxPkgs.python3 devboxPkgs.gnugrep ];
      } ''
        python3 ${self}/pkgs/oc-context/test_oc_context.py 2>&1 | tee "$TMPDIR/out.txt"

        # Assert the assertions RAN. `unittest.main` exits 0 on a suite that
        # collected nothing, which is exactly the vacuously-green failure the
        # reachability guard exists to prevent.
        grep -qE '^Ran [0-9]+ tests' "$TMPDIR/out.txt" || {
          echo "GATE FAILURE: no tests were collected." >&2
          exit 1
        }
        grep -qE '^Ran ([3-9][0-9]|[0-9]{3,}) tests' "$TMPDIR/out.txt" || {
          echo "GATE FAILURE: fewer than 30 tests ran; the suite was gutted." >&2
          exit 1
        }
        touch $out
      '';

      # oc-search's suite: same shape and same reasoning as oc-context above --
      # hermetic stdlib unittest over temp sqlite fixtures, wired here rather
      # than relying on pkgs/oc-search's checkPhase.
      #
      # The gate is set at 30 because the load-bearing test
      # (test_index_matches_scan_for_every_substring, >1000 substrings checked
      # three ways) is a single test method: a suite that silently lost it
      # would still "Ran N tests". The floor catches wholesale gutting; the
      # equivalence assertion inside the suite catches the subtle case.
      oc-search = devboxPkgs.runCommand "oc-search-tests" {
        nativeBuildInputs = [ devboxPkgs.python3 devboxPkgs.gnugrep ];
      } ''
        python3 ${self}/pkgs/oc-search/test_oc_search.py 2>&1 | tee "$TMPDIR/out.txt"

        grep -qE '^Ran [0-9]+ tests' "$TMPDIR/out.txt" || {
          echo "GATE FAILURE: no tests were collected." >&2
          exit 1
        }
        grep -qE '^Ran ([3-9][0-9]|[0-9]{3,}) tests' "$TMPDIR/out.txt" || {
          echo "GATE FAILURE: fewer than 30 tests ran; the suite was gutted." >&2
          exit 1
        }
        touch $out
      '';

      oc-session-list-bin = devboxPkgs.runCommand "oc-session-list-bin-tests" {
        nativeBuildInputs = [ devboxPkgs.bash devboxPkgs.bun devboxPkgs.gnugrep ];
        OC_SESSION_LIST_BIN = "${(localPkgsFor devboxSystem).oc-session-list}/bin/oc-session-list";
      } ''
        cd ${self}
        bash pkgs/oc-session-list/test.sh 2>&1 | tee "$TMPDIR/out.txt"

        # Assert the assertions RAN. The env var above skips stages 1-2 by
        # design, and a future edit that widened that skip would otherwise leave
        # this check green over nothing -- the store-prefix lesson.
        grep -q '^PASS: --with-state distinguishes nodata' "$TMPDIR/out.txt" || {
          echo "GATE FAILURE: the nodata-vs-idle assertion did not run." >&2
          exit 1
        }
        grep -q '^ALL PASS (oc-session-list)' "$TMPDIR/out.txt" || {
          echo "GATE FAILURE: the suite did not reach its final ALL PASS line." >&2
          exit 1
        }
        touch $out
      '';

      # workstation-pscu. pkgs/oc-auto-attach/test-project-key.sh is an 83-assertion
      # suite covering project_key/window_name derivation, pool-aware serve
      # resolution, the tmux window/session name collision that once leaked
      # `main`'s panes into confined sessions, and an `nvim -l` unit test of the
      # pre/post-settle discriminator. Until this check existed it ran NOWHERE:
      # pkgs/oc-auto-attach/default.nix sets no doCheck/checkPhase and CI runs
      # only `nix flake check`. Every assertion in it was inert from the day it
      # was written -- the same failure flake.nix documents for the opacity guard
      # a few hundred lines above, and the reason assets/nvim/test-session-switcher.sh
      # exists as a separate file rather than an extension of that suite.
      #
      # THE TOOL LIST IS THE CHECK. jq, tmux, neovim and the oc-auto-attach
      # package are not conveniences: each gates a block that SKIPs when its tool
      # is absent. Measured on a stripped PATH, the suite dropped 20 of its 71
      # assertions -- every tmux, lua and production-artifact assertion it has --
      # and still printed a triumphant final line and exited 0. Removing an entry
      # here does not fail this check; it silently empties it. That is why the
      # script hard-fails on a missing tool when NIX_BUILD_TOP is set, and why
      # the gates below assert the COUNT rather than the exit status.
      oc-auto-attach = devboxPkgs.runCommand "oc-auto-attach-tests" {
        nativeBuildInputs = [
          devboxPkgs.bash
          devboxPkgs.jq
          devboxPkgs.tmux
          devboxPkgs.neovim
          devboxPkgs.gnugrep
          (localPkgsFor devboxSystem).oc-auto-attach
        ];
        # Positive control: this runner promises every tool above, so a missing
        # one is a mis-wired check and must be fatal rather than a SKIP. The
        # suite deliberately does NOT infer this from NIX_BUILD_TOP -- nix-shell
        # exports that too (measured), which would hard-fail developers.
        OC_AA_REQUIRE_ALL_TOOLS = "1";
      } ''
        # Deliberately NOT `cd ${self}`. The suite derives its own repo root from
        # BASH_SOURCE, and running it from a neutral cwd is what proves that: the
        # nvim harness used to `loadfile` a path relative to the caller's cwd, so
        # it passed from the repo root and failed from anywhere else. A check
        # that cd'd to the repo root first would have been green over that bug.
        cd "$TMPDIR"
        bash ${self}/pkgs/oc-auto-attach/test-project-key.sh 2>&1 | tee "$TMPDIR/out.txt"

        # Assert the assertions RAN, not merely that the script exited 0 -- the
        # store-prefix / oc-session-list-bin lesson. The count is the gate: any
        # block that goes dark changes it.
        grep -q '^ALL PASS (oc-auto-attach): 83 assertions' "$TMPDIR/out.txt" || {
          echo "GATE FAILURE: the suite did not report its full 83-assertion tally." >&2
          echo "If you deliberately changed coverage, update EXPECTED_ASSERTIONS in" >&2
          echo "pkgs/oc-auto-attach/test-project-key.sh and this gate together." >&2
          exit 1
        }

        # Belt and braces: SKIP must be unreachable in the sandbox. If this ever
        # matches, a tool vanished from nativeBuildInputs and the suite quietly
        # shrank -- the exact regression this check was created to end.
        if grep -q '^SKIP' "$TMPDIR/out.txt"; then
          echo "GATE FAILURE: a block SKIPped inside the Nix build:" >&2
          grep '^SKIP' "$TMPDIR/out.txt" >&2
          exit 1
        fi

        # Name the two assertions that are worthless if they go dark and cheap to
        # lose: the tmux collision regression (needs a real tmux server in the
        # sandbox) and the nvim -l lua harness (needs a writable HOME).
        grep -q '^PASS  list_session_panes: ignores same-named window in another session' "$TMPDIR/out.txt" || {
          echo "GATE FAILURE: the tmux window/session collision regression did not run." >&2
          exit 1
        }
        grep -q '^PASS  lua module unit test via nvim -l' "$TMPDIR/out.txt" || {
          echo "GATE FAILURE: the nvim -l lua unit test did not run." >&2
          exit 1
        }
        touch $out
      '';
    };

    # NixOS system configuration
    nixosConfigurations.devbox = nixpkgs.lib.nixosSystem {
      system = devboxSystem;
      modules = [
        disko.nixosModules.disko
        sops-nix.nixosModules.sops
        ./hosts/devbox/configuration.nix
        ./hosts/devbox/hardware.nix
        ./hosts/devbox/disko.nix
      ];
    };

    # NixOS system configuration for GCP ARM devbox
    nixosConfigurations.cloudbox = nixpkgs.lib.nixosSystem {
      system = devboxSystem;  # aarch64-linux (same as devbox)
      modules = [
        disko.nixosModules.disko
        sops-nix.nixosModules.sops
        ./hosts/cloudbox/configuration.nix
        ./hosts/cloudbox/hardware.nix
        ./hosts/cloudbox/disko.nix
      ];
    };

    # Home-manager configuration (standalone for fast iteration on devbox)
    homeConfigurations.dev = home-manager.lib.homeManagerConfiguration {
      pkgs = devboxPkgs;
      modules = [
        sops-nix.homeManagerModules.sops
        ./users/dev/home.nix
      ];
      extraSpecialArgs = {
        inherit self;
        localPkgs = localPkgsFor devboxSystem;
        devenvPkg = devenv.packages.${devboxSystem}.devenv;
        assetsPath = ./assets;
        projects = projectsFor "devbox";
        isLinux = true;
        isDarwin = false;
        isDevbox = true;
        isCloudbox = false;
      };
    };

    # Home-manager configuration for GCP ARM devbox (standalone)
    homeConfigurations.cloudbox = home-manager.lib.homeManagerConfiguration {
      pkgs = devboxPkgs;  # aarch64-linux (same as devbox)
      modules = [
        sops-nix.homeManagerModules.sops
        ./users/dev/home.nix
      ];
      extraSpecialArgs = {
        inherit self;
        localPkgs = localPkgsFor devboxSystem;
        devenvPkg = devenv.packages.${devboxSystem}.devenv;
        assetsPath = ./assets;
        projects = projectsFor "cloudbox";
        isLinux = true;
        isDarwin = false;
        isDevbox = false;
        isCloudbox = true;
      };
    };

    # Darwin (macOS) system configuration
    darwinConfigurations.${mac.hostname} = nix-darwin.lib.darwinSystem {
      specialArgs = { inherit inputs mac; };
      modules = [
        ./hosts/Y0FMQX93RR-2/configuration.nix
        home-manager.darwinModules.home-manager
        {
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          home-manager.backupFileExtension = "hm-backup";
          home-manager.extraSpecialArgs = {
            localPkgs = localPkgsFor darwinSystem;
            devenvPkg = devenv.packages.${darwinSystem}.devenv;
            assetsPath = ./assets;
        projects = projectsFor "darwin";
        isLinux = false;
        isDarwin = true;
            isDevbox = false;
            isCloudbox = false;
          };
          home-manager.users.${mac.username} = { lib, ... }: {
            home.username = lib.mkForce mac.username;
            home.homeDirectory = lib.mkForce mac.homeDir;
            home.stateVersion = lib.mkForce "25.11";
            imports = [
              sops-nix.homeManagerModules.sops
              ./users/dev/home.nix
            ];
          };
        }
      ];
    };
  };
}
