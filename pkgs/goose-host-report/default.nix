{ writeShellApplication
, python3
, gh
, coreutils
, goose-link ? null
}:

writeShellApplication {
  name = "goose-host-report";
  runtimeInputs = [
    python3
    gh
    coreutils
  ] ++ (if goose-link != null then [ goose-link ] else [ ]);
  text = ''
    exec ${python3}/bin/python3 ${./goose_host_report.py} "$@"
  '';
}
