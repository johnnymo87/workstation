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
# All are inert unless their variables are set.
#
# WHY A PINNED RELEASE AND NO AUTO-BUMP. The pigeon goose runner depends on
# measured facts about the ACP server: the /acp path, ?token= auth, the
# YYYYMMDD_N session-id format, extensionResults, run ids and steer. They were
# measured at 1.48.0 and RE-MEASURED at 1.54.0 + patches on 2026-10-09: a
# throwaway serve passed pigeon's goose-launch, goose-runner and goose-id-split
# probes. Bumping is a deploy action: back up sessions.db, bump, restart
# goose-serve in a window, re-run those probes. Session DB schema is 16 at both
# 1.48.0 and 1.54.0, so this particular bump needs no migration.
#
# Release assets are byte-for-byte what upstream's workflow produces for the
# patched source (gnu, default features), so measurements of upstream behaviour
# still hold outside the patched lines.

{ lib
, stdenv
, fetchurl
, autoPatchelfHook
}:

let
  version = "1.54.0-patched.2";
  tag = "patched-1.54.0.2";

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
      hash = "sha256-BxLs1VyTQF//IZQZzMAcUXvMVZp3JdFh/l2E3kzpySk=";
    };
    "x86_64-linux" = {
      asset = "goose-x86_64-unknown-linux-gnu.tar.gz";
      hash = "sha256-X+OhF/FxRrMSExxDsX+V0rSVqhHvmRh87z1DlIOpXJ4=";
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
    description = "goose CLI: upstream release plus local patches, pinned to what the pigeon ACP integration was measured against";
    homepage = "https://github.com/johnnymo87/goose";
    mainProgram = "goose";
    platforms = lib.attrNames platforms;
  };
}
