# bin/session-owns: the CLI face of session_owns.py, for the shell guards
# (disk-cleanup's GUARD 1b, git-work --prune-merged). The python guards in
# users/dev/disk-cleanup.nix paste the same file in as sessionOwnsPy, so there
# is exactly one definition of a live session (bd workstation-6w7i.19).
#
#   session-owns [--opencode-db P] [--opencode-missing free|unknown]
#                [--goose-db P] [--claims-dir D] [--active-seconds N] PATH
#
# Prints "session <who>", "free" or "unknown <why>"; exits 0, 1 or 2.
{ pkgs }:

pkgs.writeTextFile {
  name = "session-owns";
  executable = true;
  destination = "/bin/session-owns";
  text = ''
    #!${pkgs.python3}/bin/python3
  '' + builtins.readFile ./session_owns.py + ''


    if __name__ == "__main__":
        import sys
        sys.exit(main(sys.argv[1:]))
  '';
}
