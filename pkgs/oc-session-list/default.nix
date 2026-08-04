{ lib
, stdenvNoCC
, bun
, nodejs
, importNpmLock
, makeWrapper
}:

let
  pluginSrc = ../../assets/opencode/plugins;

  nodeModules = importNpmLock.buildNodeModules {
    package = lib.importJSON (pluginSrc + "/package.json");
    packageLock = lib.importJSON (pluginSrc + "/package-lock.json");
    inherit nodejs;
    derivationArgs = {
      pname = "opencode-plugin-node-modules";
      version = "0.1.0";
      npmInstallFlags = [ "--omit=dev" ];
    };
  };
in
stdenvNoCC.mkDerivation {
  pname = "oc-session-list";
  version = "0.1.0";

  src = pluginSrc;

  nativeBuildInputs = [ bun makeWrapper ];

  dontConfigure = true;

  buildPhase = ''
    runHook preBuild

    ln -s ${nodeModules}/node_modules ./node_modules

    mkdir -p dist

    bun build oc-session-list.ts \
      --target=bun \
      --format=esm \
      --outdir=dist \
      --sourcemap=external

    runHook postBuild
  '';

  doCheck = true;

  # Smoke test only -- this deliberately does NOT run pkgs/oc-session-list/test.sh.
  #
  # `doCheck = true` next to a lone `--help` reads like the package is tested.
  # It is not, and that misreading is exactly how test.sh's 116 lines sat unrun
  # for months. The real suite runs in the `oc-session-list-bin` flake check,
  # which hands the BUILT binary to test.sh via OC_SESSION_LIST_BIN; it cannot
  # run here, because test.sh shells out to `nix build` and this IS that build.
  checkPhase = ''
    runHook preCheck

    bun --no-install ./dist/oc-session-list.js --help

    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin $out/libexec
    cp dist/oc-session-list.js $out/libexec/
    if [ -f dist/oc-session-list.js.map ]; then
      cp dist/oc-session-list.js.map $out/libexec/
    fi

    makeWrapper ${bun}/bin/bun $out/bin/oc-session-list \
      --add-flags "--no-install $out/libexec/oc-session-list.js"

    runHook postInstall
  '';

  passthru = { inherit nodeModules; };

  meta = with lib; {
    description = "CLI tool to query OpenCode sessions per-root recency";
    homepage = "https://github.com/anomalyco/workstation";
    license = licenses.mit;
    platforms = platforms.all;
  };
}
