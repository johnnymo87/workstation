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
      bb = p.callPackage ./pkgs/bb { };
      beads = p.callPackage ./pkgs/beads { };
      caveman = p.callPackage ./pkgs/caveman { };
      claude-failover-proxy = p.callPackage ./pkgs/claude-failover-proxy { };
      clerk = p.callPackage ./pkgs/clerk { };
      gclpr = p.callPackage ./pkgs/gclpr { };
      git-work = p.callPackage ./pkgs/git-work { };
      gws = p.callPackage ./pkgs/gws { };
      lgtm-gh = p.callPackage ./pkgs/lgtm-gh { };
      nvims = p.callPackage ./pkgs/nvims { };
      oc-auto-attach = p.callPackage ./pkgs/oc-auto-attach { };
      oc-cost = p.callPackage ./pkgs/oc-cost { };
      oc-session-list = p.callPackage ./pkgs/oc-session-list { };
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
        nativeBuildInputs = [ devboxPkgs.bash devboxPkgs.neovim ];
      } ''
        cd ${self}
        bash assets/nvim/test-session-switcher.sh
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
        nativeBuildInputs = [ devboxPkgs.bash ];
      } ''
        cd ${self}
        bash users/dev/test-loader-pin.sh
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
        nativeBuildInputs = [ devboxPkgs.bash devboxPkgs.bun devboxPkgs.gnugrep ];
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
