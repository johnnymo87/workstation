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
# HER SKILLS FOLDER (protocol v2, EM bead qpmfc.18.16.49.2.14, character memory spec
# 3.5) is the one thing a command may change, and only through the server's copy in,
# copy out (pkgs/em-history-shell/server.py). The skills roots live in ${base}/skills-own,
# OWNED BY THIS SERVICE (dev reads them through an ACL and never writes there; a reviewed
# skill reaches her folder through the socket's `sync` op). The unit's ReadWritePaths
# is that folder and nothing else. Each instance gets its own small tmpfs
# (TemporaryFileSystem, `--skills-work`) where her folder is copied in for the command;
# its size is a hard cap, charged to the instance's memory.
#
# NOT YET: persistent per-agent scratch (EM resolution 5). Scratch is a per-command
# tmpfs inside bwrap, as in phase 1; there is no scratch mount and no quota.
#
# BEFORE THE REBUILD run the probe (it needs no user and no unit):
#   P=$(nix build --no-link --print-out-paths .#em-history-shell)
#   sudo "$P/bin/em-history-shell-probe"
# It runs this unit's hardening props, one at a time and all together, around the real
# bwrap argv and a tool smoke test, and says which props break the sandbox. If
# it fails, change the props below (it names them) before switching.
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
  # The service's own folder of skills roots (one per history root, then one folder
  # per character name key). Made by tmpfiles; the server makes what is below it.
  skillsOwn = "${base}/skills-own";
  # Where each instance copies her folder in, a tmpfs of its own (see TemporaryFileSystem).
  skillsWork = "/run/em-skills";

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
    # Other users' processes are hidden from the service, so a command that got out of
    # bwrap still could not read their command lines or environments. The sudo probe
    # passed it on 2026-11-03, alone and in ALL.
    ProtectProc = "invisible";
    # The rest of the probe's candidates that passed as root on 2026-11-03, alone and
    # in ALL: none of them touches what bwrap or the tools inside it need.
    ProtectControlGroups = true;
    ProtectKernelModules = true;
    LockPersonality = true;
    MemoryDenyWriteExecute = true;
    RestrictSUIDSGID = true;
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
    # Her skills folders: the only place on disk the service writes. More specific
    # than the ReadOnlyPaths above, so it wins there.
    ReadWritePaths = [ "-${skillsOwn}" ];
    # The work space of one "edit" run: her folder is copied here and bound at
    # /skills/own. size is a hard cap on what a command can write there and is charged
    # to MemoryMax; nr_inodes caps files and folders. The server's own caps (2000 files,
    # 4096 files and folders, 8 MiB) sit below both with room to spare: tmpfs takes at least a 4 KiB page per
    # file, so the largest folder the caps allow needs about 16 MiB, and a tmpfs left
    # with under 256 KiB free counts as full and keeps nothing.
    TemporaryFileSystem = [
      "${skillsWork}:size=24M,nr_inodes=4200,mode=0700,uid=${toString serviceId},gid=${toString serviceId}"
    ];

    # Left OFF on purpose, each for a measured reason (probe.sh shows them):
    #  - RestrictAddressFamilies: bwrap's --unshare-net sets up loopback over
    #    AF_NETLINK; any list that omits it breaks every command.
    #  - ProtectKernelTunables: bwrap mounts a fresh /proc inside its pid namespace, and
    #    the kernel refuses that while the unit's own /proc is overmounted
    #    ("Can't mount proc"). Measured by the probe.
    #  - ProcSubset=pid: bwrap reads /proc/sys/kernel/overflowuid to set up its user
    #    namespace, and ProcSubset=pid hides /proc/sys. Measured by the sudo probe.
  };

  allowedUid = config.users.users.dev.uid;

  # sha256 of the settings that make up the sandbox's outer wall: the instance's
  # serviceConfig without ExecStart, the socket's socketConfig, and the three ExecStart
  # arguments that matter (--allowed-uid, --base and --skills-work). Passed to the server as
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
        inherit allowedUid base skillsWork;
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
    # Her skills folders: the service's, readable by dev (AgentOS reads her folder to
    # build her index). The default entry is what every folder the server makes inherits.
    "d ${skillsOwn} 0750 ${user} ${user} -"
    "a+ ${skillsOwn} - - - - user:dev:r-X,default:user:dev:r-X"
    # The mount point of each instance's TemporaryFileSystem: systemd does not make it,
    # and a missing one fails the instance at NAMESPACE (measured with the probe).
    "d ${skillsWork} 0700 root root -"
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
        "--skills-work ${skillsWork}"
        "--unit-digest ${unitDigest}"
      ];
    } // serviceConfigBase;
  };
}
