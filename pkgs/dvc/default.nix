{
  lib,
  buildNpmPackage,
  fetchurl,
  nodejs,
  makeWrapper,
}:

# DevCycle CLI (`dvc`) — feature-flag management from the command line.
#   https://github.com/DevCycleHQ/cli
#
# Why package it?
#   The `@devcycle/cli` npm package ships TWO bins: `dvc-mcp` (the local MCP
#   server wired into opencode by users/dev/opencode-config.nix) and `dvc`, the
#   full CLI. Both authenticate off the SAME ~/.config/devcycle/auth.yml SSO
#   credentials, so the CLI needs no API token. It used to be invoked ad hoc as
#     npx -y --package '@devcycle/cli@6.3.2' dvc ...
#   which is slow (re-resolves on every call), unpinned at run time (the pin
#   lives in whatever command line someone happened to type), and
#   undiscoverable (not on PATH).
#
#   NOTE: this derivation is a workstation convenience only. The shared skill
#   documenting the CLI stays npx-based on purpose — it is written for readers
#   who do not have this Nix setup. Do not "helpfully" point it here.
#
# Version pinning / MCP consistency:
#   `version` below is the SINGLE source of truth for the @devcycle/cli pin.
#   users/dev/opencode-config.nix builds the `devcycle-mcp` wrapper from this
#   derivation's `dvc-mcp` bin, so the MCP server and the CLI cannot drift to
#   different versions. Bumping here bumps both.
#
# How it's packaged:
#   `src` is a vendored wrapper package whose package.json lists the CLI's OWN
#   dependencies (not the CLI), plus a lockfile pinning the full transitive
#   closure — buildNpmPackage fetches that reproducibly (npmDepsHash, no network
#   at build time). The CLI itself is fetched separately as its published
#   tarball (`cliSrc`, hash-pinned with upstream's own sha512 integrity) and
#   unpacked into node_modules/@devcycle/cli, so Node resolves its deps by
#   walking up to the sibling node_modules.
#
#   That two-part shape exists because @devcycle/cli publishes an
#   npm-shrinkwrap.json that is unusable under Nix (no resolved/integrity on
#   ~1000 entries; x64-only binaries pinned non-optional). ./update-lock.sh
#   documents the failure modes in detail — read it before "simplifying" this
#   into a plain `{"@devcycle/cli": "<ver>"}` dependency, which does not build.
#
# Bumping the version:
#   1. Run ./update-lock.sh <new-version>. It rewrites package.json +
#      package-lock.json and prints both hashes.
#   2. Update `version`, `cliHash`, and `npmDepsHash` below.
let
  version = "6.3.2";

  # Upstream's own dist.integrity for the tarball — fetchurl takes SRI directly.
  cliHash = "sha512-1N42AJuG/1iaY4x2PLRsjBV2W4yDQJpfKV7maO+0yxqXEB8YGVDQoHA9msfoBF+fWBDoSnq+0B66OO7UW+75EQ==";

  cliSrc = fetchurl {
    url = "https://registry.npmjs.org/@devcycle/cli/-/cli-${version}.tgz";
    hash = cliHash;
  };
in
buildNpmPackage {
  pname = "dvc";
  inherit version;

  src = ./.;

  npmDepsHash = "sha256-G/QNj1+lMeYu3gI3n1oG/0EyWLbL+f0Zo5S0zmjH4Gw=";

  # Our wrapper package has no build step and no bin of its own.
  dontNpmBuild = true;

  nativeBuildInputs = [ makeWrapper ];

  # As in pkgs/vercel, node_modules is nested under a package-unique
  # `libexec/dvc/` path rather than the conventional `lib/node_modules`:
  # home-manager merges every package into one buildEnv, and this closure's
  # transitive `typescript` would otherwise collide with wrangler's
  # `lib/node_modules/typescript`.
  installPhase = ''
    runHook preInstall

    mkdir -p $out/libexec/dvc $out/bin
    cp -r node_modules $out/libexec/dvc/node_modules

    cli=$out/libexec/dvc/node_modules/@devcycle/cli
    mkdir -p $cli
    tar xf ${cliSrc} -C $cli --strip-components=1
    # Purely defensive: nothing reads it at runtime, and leaving it invites the
    # next person to try installing through it (see ./update-lock.sh).
    rm -f $cli/npm-shrinkwrap.json

    makeWrapper ${lib.getExe nodejs} $out/bin/dvc \
      --add-flags $cli/bin/run

    makeWrapper ${lib.getExe nodejs} $out/bin/dvc-mcp \
      --add-flags $cli/bin/mcp

    runHook postInstall
  '';

  # Smoke test: the oclif entrypoint must load its dependency closure and
  # report the pinned version. Catches a broken node_modules layout at build
  # time rather than on first use. (Anything beyond --version would need
  # network + credentials, which the sandbox has neither of.)
  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    $out/bin/dvc --version | grep -F "@devcycle/cli/${version}"
    runHook postInstallCheck
  '';

  meta = with lib; {
    description = "DevCycle CLI for managing feature flags from the command line";
    homepage = "https://github.com/DevCycleHQ/cli";
    license = licenses.mit;
    sourceProvenance = with sourceTypes; [ fromSource ];
    mainProgram = "dvc";
    platforms = platforms.unix;
  };
}
