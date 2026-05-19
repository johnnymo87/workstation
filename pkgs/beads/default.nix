{
  lib,
  buildGo126Module,
  fetchFromGitHub,
  icu,
}:

# Beads requires Go 1.26.x (go.mod declares `go 1.26.2`). Our pinned nixpkgs
# (nixos-25.11) still ships go_1_25 as the default `buildGoModule`, but ships
# `buildGo126Module` (backed by go_1_26) alongside. Use that explicitly.
buildGo126Module rec {
  pname = "beads";
  version = "1.0.4";

  src = fetchFromGitHub {
    owner = "gastownhall";
    repo = "beads";
    rev = "v${version}";
    hash = "sha256-a356lk3dWJg2VzXmvBL0xVYUMgICDY/6s6A5km8cjBU=";
  };

  vendorHash = "sha256-gTOYABrdQ9T5uxW5QEE8hRWH6AnCPFE/hbB2t1OJTrY=";

  # Beads 1.0+ uses github.com/dolthub/go-icu-regex (CGo bindings to ICU4C)
  # for MySQL-compatible regex, so we need ICU headers + libs at build time.
  buildInputs = [ icu ];

  subPackages = [ "cmd/bd" ];

  doCheck = false;

  # Wrap `bd` so that `bd init` always passes `--skip-hooks`.
  #
  # Why: workstation policy is to keep git hook installation explicit. Beads
  # 1.0.4 no longer installs hooks during non-interactive `bd init`, but this
  # wrapper preserves the policy if upstream changes that default or if another
  # init path would otherwise add hooks silently.
  #
  # The active hook surface in 1.0 is `bd hooks install` and `bd doctor --fix`.
  # We leave those available as deliberate user actions, but `bd init` should
  # not make future commits depend on beads hook behavior as a side effect.
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
    homepage = "https://github.com/gastownhall/beads";
    license = licenses.mit;
    sourceProvenance = with sourceTypes; [ fromSource ];
    mainProgram = "bd";
    platforms = platforms.unix;
  };
}
