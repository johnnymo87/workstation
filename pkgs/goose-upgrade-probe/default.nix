{ lib
, stdenvNoCC
, python3
, makeWrapper
, git
, uv
, honkRev
}:

# goose-upgrade-probe: the downstream gate for a goose binary (bead workstation-6w7i.27.1).
# Design: docs/plans/2026-11-22-goose-upgrade-probe.md.
#
# honkRev is the honk this flake deploys (flake input `honk`), so the honk suite the probe
# runs is the honk in production, not whatever ~/projects/honk has checked out.
#
# PATH: git and uv are suffixed as fallbacks. systemd-run/systemctl, nix, node (pigeon's
# probes) and cargo (via `nix develop` in the honk worktree) come from the caller's PATH,
# deliberately: systemd-run must match the RUNNING systemd, and node must match pigeon's
# node_modules.
let
  py = python3.withPackages (ps: [ ps.pyyaml ps.websockets ]);
in
stdenvNoCC.mkDerivation {
  pname = "goose-upgrade-probe";
  version = "0.1.0";
  src = ./.;
  nativeBuildInputs = [ makeWrapper ];
  dontBuild = true;
  installPhase = ''
    runHook preInstall
    mkdir -p $out/libexec $out/bin
    substitute goose_upgrade_probe.py $out/libexec/goose_upgrade_probe.py \
      --replace-fail '"@honkRev@"' '"${honkRev}"'
    makeWrapper ${py}/bin/python3 $out/bin/goose-upgrade-probe \
      --add-flags $out/libexec/goose_upgrade_probe.py \
      --suffix PATH : ${lib.makeBinPath [ git uv ]}
    runHook postInstall
  '';
  meta = {
    description = "Downstream gate for a candidate goose binary: isolated serve + honkd on a sessions.db copy";
    mainProgram = "goose-upgrade-probe";
    platforms = lib.platforms.linux;
  };
}
