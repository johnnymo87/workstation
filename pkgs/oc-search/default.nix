{ lib
, python3
}:

python3.pkgs.buildPythonApplication {
  pname = "oc-search";
  version = "0.2.0";
  format = "other";

  src = ./.;

  dontBuild = true;

  # Stdlib-only on purpose (sqlite3 / argparse / threading), same as
  # oc-context and oc-cost: this ships to devbox, cloudbox and macOS and must
  # not drag a dependency closure along to grep a database.
  #
  # The FTS5 trigram tokenizer this depends on has been in SQLite since 3.34
  # (2020) and is compiled into nixpkgs' python3 sqlite3 module; there is a
  # startup check in oc_search.py that says so out loud if it ever is not.
  doCheck = true;

  # NOTE: this checkPhase is NOT what makes the suite "run by CI" -- see
  # users/dev/test-unwired-tests.sh on why `doCheck` is not accepted as
  # evidence. The blessed reference is `checks.oc-search` in flake.nix, which
  # executes this same file. This is here so `nix build .#oc-search` also
  # catches a break locally.
  checkPhase = ''
    runHook preCheck
    ${python3.interpreter} test_oc_search.py
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin
    cp oc_search.py $out/bin/oc-search
    chmod +x $out/bin/oc-search

    runHook postInstall
  '';

  meta = with lib; {
    description = "Search OpenCode session history (trigram-indexed substring search)";
    license = licenses.mit;
    platforms = platforms.unix;
    mainProgram = "oc-search";
  };
}
