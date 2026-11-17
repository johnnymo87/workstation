# Test-only Postgres for eternal-machinery (devbox), beside the live stack's.
#
# WHY THIS EXISTS (eternal-machinery bead kdubj.89, design
# docs/plans/2026-11-17-test-postgres-isolation-design.md in that repo):
# every worktree's `mix test` used the live stack's Postgres on :5434
# (max_connections 100). A full suite holds 33 connections and the live stack
# about 30, so on 2026-11-17 three suites in three worktrees took the server
# to "too many clients" during a live window. Tests now get a cluster of their
# own on :5444, and the live one never sees them.
#
# - Disposable data: fsync, synchronous_commit and full_page_writes are off.
#   The data directory is on disk (~/.local/share), NOT the /run/user tmpfs:
#   on 2026-07-10 a 3 GB tmpfs filled and broke every `systemd-run --user`.
# - Matches the live cluster where tests can notice: locale C, UTF8,
#   timezone GMT, Postgres 16 with pgvector (the migrations need btree_gist,
#   which is contrib).
# - Trust auth, 127.0.0.1 and a private socket only. The test configs send
#   user postgres with password postgres, which trust accepts.
# - EM_TEST_PGPORT is how eternal-machinery's test config finds it
#   (config/test.exs applies it after the app configs). Since kdubj.89 the
#   repo's own default is 5444 too; the variable covers worktrees cut before
#   that change. PGPORT stays the live 5434 (devenv sets it, the live tooling
#   reads it). CI never sees this file: its jobs run their own Postgres.
# - Each worktree's partition database is created on first use, as before:
#   MIX_TEST_PARTITION=<name> MIX_ENV=test mix ecto.create / ecto.migrate.
# - Recovery: fsync is off, so a hard crash can leave a data directory that
#   will not start (a clean stop or reboot is fine). Nothing here holds data:
#   systemctl --user stop em-test-postgres;
#   rm -rf ~/.local/share/eternal-machinery/test-pg;
#   systemctl --user start em-test-postgres; then each partition is created again.
{ config, pkgs, lib, isDevbox, ... }:

let
  port = 5444;
  pg = pkgs.postgresql_16.withPackages (ps: [ ps.pgvector ]);
  dataDir = "${config.home.homeDirectory}/.local/share/eternal-machinery/test-pg";

  # initdb once. A user unit's PATH has no coreutils, so every tool is named
  # by store path. A directory without PG_VERSION is either new or a failed
  # initdb, so it is cleared and made again (it never holds data then).
  initScript = pkgs.writeShellScript "em-test-postgres-init" ''
    set -eu
    if [ ! -s "${dataDir}/PG_VERSION" ]; then
      ${pkgs.coreutils}/bin/rm -rf "${dataDir}"
      ${pkgs.coreutils}/bin/mkdir -p "${dataDir}"
      ${pg}/bin/initdb -D "${dataDir}" -U postgres --auth=trust \
        --encoding=UTF8 --locale=C --no-sync
    fi
  '';
in
lib.mkIf isDevbox {
  home.sessionVariables.EM_TEST_PGPORT = toString port;

  systemd.user.services.em-test-postgres = {
    Unit = {
      Description = "eternal-machinery test-only Postgres (port ${toString port})";
      # No start limit: a restart loop that gives up would leave every
      # worktree's tests failing with connection refused until someone looks.
      StartLimitIntervalSec = 0;
      # A switch that moves the Postgres store path would otherwise restart it
      # and cut every running suite's connections. Keep the running one, as
      # opencode-serve@ does; it picks up a new build at its next restart.
      X-SwitchMethod = "keep-old";
    };
    Service = {
      Type = "simple";
      RuntimeDirectory = "em-test-postgres";
      ExecStartPre = "${initScript}";
      ExecStart = lib.concatStringsSep " " [
        "${pg}/bin/postgres"
        "-D ${dataDir}"
        "-p ${toString port}"
        "-k %t/em-test-postgres"
        "-c listen_addresses=127.0.0.1"
        "-c max_connections=400"
        "-c shared_buffers=128MB"
        "-c fsync=off"
        "-c synchronous_commit=off"
        "-c full_page_writes=off"
        "-c timezone=GMT"
        "-c log_statement=none"
      ];
      # Postgres's smart shutdown waits for clients; a test VM left running
      # would hold a stop for good.
      KillSignal = "SIGINT";
      TimeoutStopSec = 30;
      Restart = "always";
      RestartSec = 5;
      # Measured 2026-11-17: about 75 MB after a full suite, 5 to 10 MB per
      # busy backend. A cap keeps a runaway from touching the live stack.
      MemoryMax = "6G";
    };
    Install = {
      WantedBy = [ "default.target" ];
    };
  };
}
