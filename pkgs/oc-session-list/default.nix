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
