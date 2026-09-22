# goose CLI, pinned to the exact upstream release binary that this repo's goose
# integration was measured against.
#
# WHY PACKAGE IT AT ALL. The first cut of the goose-serve units (#567) ran
# /home/dev/.local/bin/goose -- a hand-installed 296 MB file in $HOME. That
# works, but it makes a declarative unit depend on something no rebuild can
# reproduce, and it leans on nix-ld to supply the loader for a gnu-linked
# binary. Neither dependency is visible to `nix eval`, so a deleted or swapped
# binary surfaces at runtime, not at build time.
#
# WHY IT IS SAFE TO SWITCH. The upstream asset is BYTE-IDENTICAL to the
# hand-installed binary it replaces -- both sha256
# a261d5b7e0bf34abf2f4ad8e446bc69339c687e9ca2bac7f0221fa6fbb940830, verified on
# cloudbox 2026-09-21. So this is a provenance change, not a behaviour change:
# every measurement taken against the hand-installed 1.48.0 still holds.
#
# WHY THERE IS NO AUTO-BUMP WORKFLOW, unlike opencode-patched. Two reasons, and
# the second is the sharp one:
#   1. The version is pinned to MEASURED behaviour. The ACP endpoint path, the
#      query-parameter auth, and the session-id format are all facts about
#      1.48.0 that the pigeon side depends on; a silent bump would invalidate
#      them without anything failing loudly.
#   2. goose keeps session state in a sqlite DB at
#      ~/.local/share/goose/sessions/sessions.db. A version jump can panic on a
#      stale schema -- and since goose-serve runs Restart=always, that turns
#      into a crash loop rather than a clean stop. There is already a
#      sessions.pre-1.46-backup-* directory beside it from exactly such a
#      migration. Bumping is therefore a deploy action: back the DB up first,
#      then bump, then watch the unit.
# Treat this file as the place a human decides to move, deliberately.
#
# KNOWN GAP, deliberately not closed here. The hand-installed
# /home/dev/.local/bin/goose still exists and is what a human gets
# interactively, and it shares ~/.local/share/goose/sessions/sessions.db with
# the serve. So packaging pins the SERVE's provenance while a second,
# unmanaged copy keeps write access to the same state -- and the first version
# drift between them is precisely the stale-schema panic described above.
# Closing it means installing this package for the user and removing the
# hand-installed binary, which is a deploy action on every host rather than a
# nix change; tracked separately.
{ lib
, stdenv
, fetchurl
, autoPatchelfHook
}:

let
  version = "1.48.0";

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
      hash = "sha256-tlBuc+wVY3rHzY08Cd+X9e7/VACUap6PDUyPWQXlPzs=";
    };
    "x86_64-linux" = {
      asset = "goose-x86_64-unknown-linux-gnu.tar.gz";
      hash = "sha256-PDjHkHI/3kUyNX81NGtxkL1w0ZjmvlWfn/6sTPfJgVI=";
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
    url = "https://github.com/block/goose/releases/download/v${version}/${platformInfo.asset}";
    inherit (platformInfo) hash;
  };

  nativeBuildInputs = [ autoPatchelfHook ];
  buildInputs = [ stdenv.cc.cc.lib ];

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
  # invisible until runtime otherwise. Cheap, and it is the whole point of
  # packaging rather than pointing at $HOME.
  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    $out/bin/goose --version
    runHook postInstallCheck
  '';

  meta = {
    description = "goose CLI, pinned to the release measured by the pigeon ACP integration";
    homepage = "https://github.com/block/goose";
    mainProgram = "goose";
    platforms = lib.attrNames platforms;
  };
}
