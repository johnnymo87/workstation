{ writeShellApplication
, python3
, gh
, git
, nix
, curl
, jq
, util-linux
, systemd
, sqlite
, goose-link
}:

writeShellApplication {
  name = "goose-cutover";
  runtimeInputs = [
    python3
    gh
    git
    nix
    curl
    jq
    util-linux
    systemd
    sqlite
    goose-link
  ];
  text = ''
    exec ${python3}/bin/python3 ${./goose_cutover.py} "$@"
  '';
}
