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
, openssh
, goose-link
, driftAlert ? null
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
    openssh
    goose-link
  ];
  text = ''
    ${if driftAlert != null then ''export GOOSE_CUTOVER_ALERT="${driftAlert}"'' else ""}
    exec ${python3}/bin/python3 ${./goose_cutover.py} "$@"
  '';
}
