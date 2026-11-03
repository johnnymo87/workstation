# em-history-shell: where eternal-machinery's `shell_execute` commands run, as a
# different user than the one that runs AgentOS (EM bead qpmfc.101.5, phase 2).
#
#   AgentOS (dev) --unix socket--> em-history-shell@<n>.service (user em-history-shell)
#                                    --> bubblewrap --> the model's command
#
# WHY: phase 1 ran the model-written commands as `dev` inside bubblewrap. A sandbox
# escape then lands as dev, with the whole home. Here it lands as a system user that
# cannot see /home and can read only the agent history files.
#
# SHAPE
#   - Socket-activated, Accept=yes: one service instance per connection, so every
#     command gets its own cgroup. The caps live on the instance (MemoryMax, TasksMax,
#     CPUQuota), and KillMode=control-group sweeps whatever is left when it ends.
#     There is no systemd-run inside: the instance cgroup is the cap.
#   - Only dev may connect (SocketUser/SocketMode here, and the server checks
#     SO_PEERCRED against the same uid). Whoever can talk to the socket can already
#     read the files, so the client may name its own view; the model controls only the
#     command text. The server validates every field (pkgs/em-history-shell/server.py).
#   - bwrap stays inside the service: views differ per request, and bwrap keeps the
#     pid/net/ipc/uts/cgroup unshare and the seccomp filter that EM's escape suite
#     tests. This unit is the outer wall; it is allowed to be loose where bwrap needs it.
#
# THE HISTORY ROOT is /var/lib/eternal-machinery (dev:dev 0750), with a default ACL
# that gives the service group r-X on everything dev creates below it, so a new
# account's history is readable with no change here. Not under /home: +x on /home/dev
# would expose every 0644 file in it by name. Not setgid: dev's chmod strips S_ISGID
# when dev is not in the group.
#
# NOT YET: persistent per-agent scratch (EM resolution 5). Scratch is a per-command
# tmpfs inside bwrap, as in phase 1; there is no scratch mount and no quota.
#
# BEFORE THE REBUILD run the probe (it needs no user and no unit):
#   P=$(nix build --no-link --print-out-paths .#em-history-shell)
#   sudo "$P/bin/em-history-shell-probe"
# It runs this unit's hardening props, one at a time and all together, around the real
# bwrap argv and a tool smoke test, and says which props break the sandbox. If
# it fails, change the props below (it names them) before switching. Also note its
# "+ProtectProc=invisible" and "+ProcSubset=pid" lines: they are off in the unit, and
# if they say OK, adopting ProtectProc=invisible is a follow-up.
#
# Design and the EM side: docs/plans/2026-11-03-em-history-shell.md.
{ config, lib, pkgs, ... }:

let
  server = pkgs.callPackage ../../pkgs/em-history-shell { };

  # Fixed ids, not DynamicUser: the history files carry an ACL for this group, and
  # ACLs name numeric ids that must be stable. 2100 is unused on devbox (em-ci
  # is 2001, nixbld is 30000+, the system users are below 1000).
  serviceId = 2100;

  base = "/var/lib/eternal-machinery";
  user = "em-history-shell";

  socketConfig = {
    Accept = "yes";
    SocketUser = "dev";
    SocketMode = "0600";
    # At most this many commands at once (each is capped at 384M, 48 tasks).
    MaxConnections = 16;
    # No TriggerLimit* lines, on purpose. Hitting a socket's trigger limit puts the
    # socket unit in the failed state, and only a restart (sudo) brings it back. With
    # Accept=yes the default poll limit throttles a client in a loop instead and
    # the socket stays up.
  };

  # The service's settings except ExecStart (which carries the digest, so it cannot be
  # part of it).
  serviceConfigBase = {
    User = user;
    Group = user;
    # Accept=yes hands the connected socket to the instance as fd 0 (and 1).
    StandardInput = "socket";
    StandardOutput = "socket";
    StandardError = "journal";
    SyslogIdentifier = "em-history-shell";
    Environment = [ "PYTHONDONTWRITEBYTECODE=1" ];

    # The caps of one command, as in phase 1 (these were a systemd-run scope's).
    MemoryMax = "384M";
    MemorySwapMax = 0;
    TasksMax = 48;
    CPUQuota = "100%";
    # Backstop for the server's own 30 s kill and its reap waits.
    RuntimeMaxSec = 60;
    # If the kernel OOM-kills the command (the server sets oom_score_adj=1000 on
    # it), do not take the whole instance down with it: the server is still there
    # to answer, and its answer says what happened.
    OOMPolicy = "continue";
    KillMode = "control-group";

    # --- the wall around bwrap ---------------------------------------------------
    ProtectSystem = "strict";
    # tmpfs, not "yes": "yes" makes /home mode 000, which callers see as EACCES.
    # (Also hides /root and /run/user.)
    ProtectHome = "tmpfs";
    PrivateTmp = true;
    PrivateDevices = true;
    PrivateNetwork = true;
    NoNewPrivileges = true;
    # bwrap runs in a user namespace it makes itself, where it has every capability
    # regardless of this set; the service needs none in the host namespace.
    CapabilityBoundingSet = "";
    # bwrap's own unshare flags, nothing else.
    RestrictNamespaces = [ "user" "mnt" "pid" "net" "ipc" "uts" "cgroup" ];
    # An ALLOW list, deliberately not the em-ci-runners.nix deny list: that one has
    # ~capset, and bwrap needs capset. @system-service has clone, unshare, setns,
    # capset, prctl (the seccomp load) and the setuid family; @mount adds mount,
    # umount2, pivot_root and chroot; sethostname is for --unshare-uts.
    # EPERM, not SIGSYS: a syscall missing here must show up as an error message in
    # the probe/journal, not as a killed command.
    SystemCallFilter = [ "@system-service" "@mount" "sethostname" ];
    SystemCallErrorNumber = "EPERM";
    SystemCallArchitectures = "native";
    # The history files are read through the ACL; ProtectSystem=strict already makes
    # them read-only, this says so (and "-" lets the unit run before the dir exists,
    # so the server can answer "no such root" instead of the unit failing).
    ReadOnlyPaths = [ "-${base}" ];

    # Left OFF on purpose, each for a measured reason (probe.sh shows them):
    #  - RestrictAddressFamilies: bwrap's --unshare-net sets up loopback over
    #    AF_NETLINK; any list that omits it breaks every command.
    #  - ProtectKernelTunables: bwrap mounts a fresh /proc inside its pid namespace, and
    #    the kernel refuses that while the unit's own /proc is overmounted
    #    ("Can't mount proc"). Measured by the probe.
    #  - ProtectProc, ProcSubset: left off until the probe has run as root. A --user run
    #    passes both, but that one is only indicative. If the sudo probe's
    #    "+ProtectProc=invisible" line says OK, adopt ProtectProc=invisible in a
    #    follow-up (it hides other users' processes from the service). It is not worth
    #    a broken sandbox, so nothing is assumed here.
  };

  allowedUid = config.users.users.dev.uid;

  # sha256 of the settings that make up the sandbox's outer wall: the instance's
  # serviceConfig without ExecStart, the socket's socketConfig, and the two ExecStart
  # arguments that matter (--allowed-uid and --base). Passed to the server as
  # --unit-digest and put on every answer as "unit_digest", so a client that proved one
  # unit can tell it from a changed one without reading systemd. The rest of ExecStart
  # is left out: it carries the digest itself, and the server path is the answer's
  # "server" already. The unit's [Unit] section, the user and the tmpfiles rules are
  # not covered.
  unitDigest = builtins.hashString "sha256" (
    builtins.toJSON {
      service = serviceConfigBase;
      socket = socketConfig;
      args = {
        inherit allowedUid base;
      };
    }
  );
in
{
  users.groups.${user}.gid = serviceId;
  users.users.${user} = {
    isSystemUser = true;
    uid = serviceId;
    group = user;
    description = "Runs the model-written commands of eternal-machinery's history shell";
  };

  systemd.tmpfiles.rules = [
    "d ${base} 0750 dev dev -"
    # a+ adds to the ACL (a plain `a` would replace it). The default entry is
    # what the agent-history* directories dev creates below inherit.
    "a+ ${base} - - - - group:${user}:r-X,default:group:${user}:r-X"
  ];

  systemd.sockets.em-history-shell = {
    description = "em-history-shell socket (only dev may connect)";
    wantedBy = [ "sockets.target" ];
    listenStreams = [ "/run/em-history-shell/sock" ];
    inherit socketConfig;
  };

  systemd.services."em-history-shell@" = {
    description = "em-history-shell: one sandboxed command (%i)";
    # Failed instances (an OOM kill, a crash) would otherwise stay loaded until
    # someone resets them. [Unit] section, not [Service].
    unitConfig.CollectMode = "inactive-or-failed";
    serviceConfig = {
      ExecStart = lib.concatStringsSep " " [
        "${server}/bin/em-history-shell-server"
        "--allowed-uid ${toString allowedUid}"
        "--base ${base}"
        "--unit-digest ${unitDigest}"
      ];
    } // serviceConfigBase;
  };
}
