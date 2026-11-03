# em-history-shell: the server half of eternal-machinery's sandboxed history shell
# (EM bead qpmfc.101.5, phase 2). Runs commands the model wrote as the system user
# `em-history-shell`, one bubblewrap sandbox per socket connection. Wired up in
# hosts/devbox/em-history-shell.nix; design in docs/plans/2026-11-03-em-history-shell.md.
#
# THE STORE PATH IS THE PROOF. This derivation embeds, as store paths, the bwrap, the
# tools environment (and its whole closure) and the seccomp program, in config.json,
# and puts its own path in it as "server". Anything that changes what a command can
# do therefore changes this path, and every answer carries it ("server"), so EM's
# client can tell a changed server from the one its escape suite proved.
#
# The tool set and the seccomp policy are COPIES of eternal-machinery's
# nix/history-shell.nix and nix/history_shell_seccomp.py (that repo is private, so
# this one cannot import it). They MUST stay in step with EM's: a different tool set
# changes what the agents can run, a different policy changes the sandbox. `ping`
# reports the sha256 of the seccomp program so EM's suite can compare it with the one
# its own generator makes. (Nixpkgs differ too, so libseccomp may differ: the sha is
# the check, not the policy text.)
{
  lib,
  stdenv,
  buildEnv,
  runCommand,
  closureInfo,
  python3,
  bubblewrap,
  jq,
  bash,
  coreutils,
  gnugrep,
  gnused,
  gawk,
  findutils,
  diffutils,
  ripgrep,
}:

let
  # What an agent may run inside the sandbox. Same list as EM's nix/history-shell.nix.
  tools = buildEnv {
    name = "history-shell-tools";
    paths = [
      bash
      coreutils
      gnugrep
      gnused
      gawk
      findutils
      diffutils
      jq
      ripgrep
      python3
    ];
    pathsToLink = [ "/bin" ];
  };

  seccompPython = python3.withPackages (ps: [ ps.seccomp ]);

  # The libseccomp the blob is built with: the Python binding is built from libseccomp's
  # own source, so its version is the library's (and the closure carries that library).
  libseccompVersion = python3.pkgs.seccomp.version;

  seccomp =
    runCommand "history-shell-seccomp" { nativeBuildInputs = [ seccompPython ]; }
      ''
        mkdir -p $out
        python3 ${./seccomp_policy.py} $out/seccomp.bpf
      '';

  # Every store path the tools need, one per line: what bwrap binds read-only.
  closure = closureInfo { rootPaths = [ tools ]; };
in
stdenv.mkDerivation {
  pname = "em-history-shell";
  version = "1";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./server.py
      ./probe.sh
    ];
  };

  nativeBuildInputs = [ jq ];
  buildInputs = [ python3 ];

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin $out/share/em-history-shell

    install -m755 server.py $out/bin/em-history-shell-server
    patchShebangs $out/bin/em-history-shell-server

    # One definition of the canonical policy hash: the server's own function.
    policy_sha256=$(PYTHONPATH=. python3 -c \
      'import sys, server; print(server.policy_sha256(open(sys.argv[1], encoding="utf-8").read()))' \
      ${./seccomp_policy.py})

    jq -n \
      --arg server "$out" \
      --arg bwrap "${bubblewrap}/bin/bwrap" \
      --arg tools "${tools}" \
      --arg seccomp "${seccomp}/seccomp.bpf" \
      --arg libseccomp_version "${libseccompVersion}" \
      --arg policy_sha256 "$policy_sha256" \
      --rawfile closure "${closure}/store-paths" \
      '{server: $server, bwrap: $bwrap, tools: $tools, seccomp: $seccomp,
        libseccomp_version: $libseccomp_version, policy_sha256: $policy_sha256,
        closure: ($closure | split("\n") | map(select(length > 0)))}' \
      > $out/share/em-history-shell/config.json

    # The probe (run with sudo before the rebuild) needs the same pieces.
    install -m755 probe.sh $out/bin/em-history-shell-probe
    substituteInPlace $out/bin/em-history-shell-probe \
      --replace-fail '@bash@' '${bash}/bin/bash' \
      --replace-fail '@config@' "$out/share/em-history-shell/config.json" \
      --replace-fail '@jq@' '${jq}/bin/jq' \
      --replace-fail '@coreutils@' '${coreutils}'
    runHook postInstall
  '';

  passthru = { inherit tools seccomp closure; };

  meta = {
    description = "Sandboxed history shell server (socket-activated, own uid, bubblewrap)";
    mainProgram = "em-history-shell-server";
    platforms = lib.platforms.linux;
  };
}
