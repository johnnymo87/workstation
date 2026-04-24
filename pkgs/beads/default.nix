{
  lib,
  buildGoModule,
  fetchFromGitHub,
}:

buildGoModule rec {
  pname = "beads";
  version = "0.49.1";

  src = fetchFromGitHub {
    owner = "steveyegge";
    repo = "beads";
    rev = "v${version}";
    hash = "sha256-roOyTMy9nKxH2Bk8MnP4h2CDjStwK6z0ThQhFcM64QI=";
  };

  vendorHash = "sha256-YU+bRLVlWtHzJ1QPzcKJ70f+ynp8lMoIeFlm+29BNPE=";

  # Remove go version constraint that requires newer Go than nixpkgs provides
  postPatch = ''
    sed -i '/^toolchain /d' go.mod
  '';

  subPackages = [ "cmd/bd" ];

  doCheck = false;

  # Wrap `bd` so that `bd init` always passes `--skip-hooks`.
  #
  # Why: upstream `bd init` (cmd/bd/init.go ~L585) installs git hooks by
  # default into .git/hooks/ for SQLite-backed repos. The pre-commit hook it
  # writes (cmd/bd/init_git_hooks.go -> installGitHooks) is the inline variant
  # which has a worktree bug: it correctly resolves the main repo's .beads
  # directory into a `BEADS_DIR` shell variable, but never exports it nor cd's
  # to the main repo before running `bd sync --flush-only`. Result: every
  # commit inside any worktree of a beads-tracked repo fails with
  #   Error: Failed to flush bd changes to JSONL
  # forcing `git commit --no-verify` as a workaround.
  #
  # Even fixing the worktree bug doesn't address the larger objection: the
  # bd daemon already auto-flushes on a 30s debounce and we run `bd sync`
  # manually at session end, so the pre-commit gate is overhead with
  # negligible safety benefit in this workflow.
  #
  # Upstream offers no env var or config knob to disable hook installation
  # globally — only the per-invocation `--skip-hooks` flag on `bd init`. So
  # we wrap the binary and inject the flag for any `bd init` invocation that
  # didn't already pass it (we still let the user opt back in by passing
  # --skip-hooks=false explicitly, though that's an unusual invocation).
  #
  # `bd hooks install` and `bd doctor --fix` can still install hooks if run
  # explicitly. That's intentional — those are deliberate user actions, not
  # silent side effects of `bd init`.
  #
  # See ~/projects/workstation/assets/opencode/skills/beads/SKILL.md for the
  # workstation-wide hook policy.
  postInstall = ''
    mkdir -p $out/libexec
    mv $out/bin/bd $out/libexec/bd-real
    cat > $out/bin/bd <<WRAPPER_EOF
    #!/bin/sh
    # bd wrapper: inject --skip-hooks into \`bd init\` (workstation policy).
    # Source: pkgs/beads/default.nix in the workstation flake.
    if [ "\$1" = "init" ]; then
        shift
        # Don't double-add the flag if caller already specified it.
        for arg in "\$@"; do
            case "\$arg" in
                --skip-hooks|--skip-hooks=*)
                    exec $out/libexec/bd-real init "\$@"
                    ;;
            esac
        done
        exec $out/libexec/bd-real init --skip-hooks "\$@"
    fi
    exec $out/libexec/bd-real "\$@"
    WRAPPER_EOF
    # Strip the 4-space indentation that the heredoc preserved.
    sed -i "s/^    //" $out/bin/bd
    chmod +x $out/bin/bd
  '';

  meta = with lib; {
    description = "A distributed issue tracker designed for AI-supervised coding workflows";
    homepage = "https://github.com/steveyegge/beads";
    license = licenses.mit;
    sourceProvenance = with sourceTypes; [ fromSource ];
    mainProgram = "bd";
    platforms = platforms.unix;
  };
}
