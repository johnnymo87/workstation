{ lib
, python3
, makeWrapper
}:

let
  py = python3.withPackages (ps: [ ps.tzdata ]);
in
python3.pkgs.buildPythonApplication {
  pname = "llm-ledger";
  version = "0.1.0";
  format = "other";

  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ./llm_ledger.py
      ../oc-tags/oc_tags.py
    ];
  };

  dontBuild = true;

  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    runHook preInstall

    mkdir -p $out/libexec/llm-ledger $out/bin
    cp llm-ledger/llm_ledger.py $out/libexec/llm-ledger/llm_ledger.py
    cp oc-tags/oc_tags.py $out/libexec/llm-ledger/oc_tags.py
    chmod +x $out/libexec/llm-ledger/llm_ledger.py

    makeWrapper ${py}/bin/python3 $out/bin/llm-ledger \
      --add-flags "$out/libexec/llm-ledger/llm_ledger.py"

    runHook postInstall
  '';

  meta = with lib; {
    description = "Maintains /var/lib/llm-ledger/ledger.db and raw archives";
    license = licenses.mit;
    platforms = platforms.unix;
    mainProgram = "llm-ledger";
  };
}
