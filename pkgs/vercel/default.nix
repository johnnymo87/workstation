{
  lib,
  buildNpmPackage,
  nodejs,
  makeWrapper,
}:

# Vercel CLI.
#
# Why a custom derivation instead of nixpkgs?
#   nixpkgs (nixos-25.11) only ships `nodePackages.vercel` at 41.4.1, which is
#   ~15 major versions behind upstream npm (56.4.1 at time of writing). boldco
#   provisioning needs a current CLI, so we package the current release the Nix
#   way: pinned version + content-addressed npm dependency closure.
#
# How it's packaged:
#   Upstream's `vercel` npm package ships no lockfile and its `bin` resolves to
#   `dist/vc.js`, which requires its node_modules at runtime (it is NOT a
#   self-contained bundle). So we vendor a tiny wrapper package (./package.json)
#   that depends on the exact `vercel` version, plus a generated
#   ./package-lock.json pinning the full transitive closure. buildNpmPackage
#   fetches that closure reproducibly (npmDepsHash) with no network at build
#   time, then we expose a `vercel` launcher that runs the installed CLI via
#   node.
#
# Bumping the version:
#   1. Edit the version in ./package.json.
#   2. Regenerate the lock:  (cd pkgs/vercel && npm install --package-lock-only)
#   3. Recompute npmDepsHash: nix run nixpkgs#prefetch-npm-deps -- pkgs/vercel/package-lock.json
#   4. Update `version` and `npmDepsHash` below.
buildNpmPackage rec {
  pname = "vercel";
  version = "56.4.1";

  src = ./.;

  npmDepsHash = "sha256-Jr9zsKvoKjhFdSwgT2WRSsmWUVrSl7hhmb5RWFN34uE=";

  # Our wrapper package has no build step and no bin of its own.
  dontNpmBuild = true;

  nativeBuildInputs = [ makeWrapper ];

  # The installed CLI is a plain node script; run it with node at runtime.
  #
  # We nest node_modules under a vercel-unique `libexec/vercel/` path rather
  # than the conventional `lib/node_modules`. home-manager merges every
  # package into one buildEnv, and vercel's transitive `typescript` would
  # otherwise collide with wrangler's `lib/node_modules/typescript`. Keeping
  # the tree under libexec/vercel/ makes the paths disjoint.
  installPhase = ''
    runHook preInstall

    mkdir -p $out/libexec/vercel $out/bin
    cp -r node_modules $out/libexec/vercel/node_modules

    makeWrapper ${lib.getExe nodejs} $out/bin/vercel \
      --add-flags $out/libexec/vercel/node_modules/vercel/dist/vc.js
    ln -s $out/bin/vercel $out/bin/vc

    runHook postInstall
  '';

  meta = with lib; {
    description = "Develop, preview, and ship Vercel projects from the command line";
    homepage = "https://vercel.com/docs/cli";
    license = licenses.asl20;
    sourceProvenance = with sourceTypes; [ fromSource ];
    mainProgram = "vercel";
    platforms = platforms.unix;
  };
}
