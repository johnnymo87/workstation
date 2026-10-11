# Self-hosted GitHub Actions runners for johnnymo87/eternal-machinery.
#
# Declarative NixOS containers, each running one non-ephemeral runner (default
# labels: self-hosted, Linux, plus the host architecture, e.g. ARM64 on devbox,
# X64 on gamebox, plus em-ci). The eternal-machinery workflow
# (.github/workflows/ci.yml) routes its heavy jobs here when the repo variable
# HEAVY_RUNNER (or a PR label / dispatch input) says so; otherwise they stay on
# GitHub-hosted runners. ci.yml is moving to request ["self-hosted","em-ci"]
# (docs/plans/2026-10-11-em-ci-gamebox-design.md §5).
#
# Spec: eternal-machinery docs/plans/2026-10-07-ci-self-hosted-plan.md, "PR-2".
# Beads: eternal-machinery-0oycj (epic), -0oycj.4 (this module).
# Fallback runbook (stop routing here): eternal-machinery
# docs/runbooks/ci-self-hosted.md -- set the repo variable FORCE_HOSTED=true.
#
# WHY CONTAINERS. The CI suites start their own Postgres on 127.0.0.1:5434,
# which is exactly where devbox's live eternal-machinery stack listens. Each
# container has a private network namespace, so its loopback 5434 is its own
# and the host's is unreachable (the host's 127.0.0.1 is not routable from a
# veth). The isolation is against accidents, not hostile code: the repo is
# the owner's own, and the runner never runs as `dev`.
#
# DISK. Container roots live under /var/lib/nixos-containers. With stateDevice
# set (devbox's 30 GB Volume), container writes (workspace, caches, private
# /tmp) cannot fill root; only the host nix-daemon's store growth (devenv
# closures) lands on root, governed by nix.gc/min-free. With stateDevice = null
# (gamebox), container roots share the root filesystem, so both container
# writes and host store growth land on root. The watchdog below guards against
# root running out in either mode.
#
# RESOURCES. Each container is capped at `cpus` CPUs and `memoryMax` RAM. Builds
# that the host nix-daemon performs on a container's behalf run in nix-daemon's
# cgroup and are NOT covered by these caps; they are bounded only by the host's
# max-jobs/cores. Accepted risk: the closures substitute from public caches.
#
# GC ROOTS. devenv registers indirect GC roots for its shell under the job's
# workspace. Inside a container that path is not the host's path, so host GC
# treats the root as dangling and may collect the closure between runs. The
# cost is a re-download, not a failure.
#
# RUNNER VERSION. GitHub stops queueing jobs to a runner more than 30 days
# behind the latest release, and the NixOS module disables auto-update. The
# package therefore comes from nixpkgs-unstable, which tracks releases more
# closely than the stable channel. MONTHLY BUMP: check
#   gh api repos/actions/runner/releases --jq '.[0].tag_name'
# against `nix eval --raw .#nixosConfigurations.{devbox,gamebox}.config.containers.em-ci-1.config.services.github-runners.em-ci.package.version`
# and if the runner is behind, `nix flake update nixpkgs-unstable` (note this
# also rebuilds gamebox's Sunshine locally (CUDA), so lift gamebox's nix-daemon
# cap for that switch:
#   sudo systemctl set-property --runtime nix-daemon MemoryMax=infinity CPUQuota=
# ), check the runner version on both hosts and rebuild both.
# If unstable has not caught up yet, override only this package.
#
# VERIFY after a deploy (see the bead for the full list):
#   gh api repos/johnnymo87/eternal-machinery/actions/runners \
#     --jq '.runners[]|.name+" "+.status'                      # both online
#   sudo nixos-container run em-ci-1 -- curl -sm3 10.233.71.1:5434; echo $?  # must fail
#   sudo nixos-container run em-ci-1 -- runuser -u em-ci -- cat /run/em-ci/pat  # denied
{ config, lib, pkgs, nixpkgs-unstable, devenvPkg, ... }:

let
  cfg = config.services.em-ci-runners;
  inherit (lib) mkOption mkEnableOption mkIf types;

  runnerPkg = nixpkgs-unstable.legacyPackages.${pkgs.stdenv.hostPlatform.system}.github-runner;

  # Fixed so files on the container state filesystem (stateDevice, else root)
  # keep a stable owner across rebuilds. Not used by anything on the host
  # (verified with getent at authoring time).
  ciUid = 2001;

  patInContainer = "/run/em-ci/pat";

  containerConfig = name: r: { ... }: {
    system.stateVersion = "25.11";

    # The host nix-daemon (bind-mounted socket) does the actual work; these
    # are client-side settings for `nix` and devenv inside the container.
    nix.settings.experimental-features = [ "nix-command" "flakes" ];

    # The devenv venv pip-installs generic-Linux wheels with native binaries
    # (ruff, for one). As on the devbox host, nix-ld supplies the loader;
    # without it they exit 127 "Could not start dynamically linked executable".
    programs.nix-ld.enable = true;

    # DNS. By default a container copies the host's resolv.conf, i.e. the
    # Hetzner resolvers 185.12.64.1/.2. Measured from devbox on 2026-10-08,
    # those dropped about half of all queries (dig: ~5/10 timeouts on each)
    # while 1.1.1.1 and 9.9.9.9 answered 10/10. glibc then waits its 5 s
    # retry timeout, and Erlang/Mix give up first: `mix deps.get` / hex
    # install failed with `{inet6,[inet6],nxdomain}` (httpc reports the
    # IPv6 error after the IPv4 fallback also failed). Bead
    # eternal-machinery-0oycj.11. CI makes many uncached lookups (nsncd does
    # not cache), so it also stops adding to the host's own resolver load.
    # Hetzner is left out entirely: as a third server with `rotate` it still
    # cost a 2 s timeout on about a third of lookups. The egress fence allows
    # public destinations, so no fence change.
    networking.useHostResolvConf = false;
    networking.nameservers = cfg.nameservers;
    networking.resolvconf.extraOptions = [ "timeout:2" "attempts:3" ];

    users.groups.em-ci.gid = ciUid;
    users.users.em-ci = {
      isSystemUser = true;
      uid = ciUid;
      group = "em-ci";
      home = "/var/lib/em-ci";
    };

    # /home stays empty: eternal-machinery's devenv.nix keys behaviour off
    # /home/dev existing, and prepare-workspace.sh refuses to run if it does.
    systemd.tmpfiles.rules = [
      "d /var/lib/em-ci       0750 em-ci em-ci -"
      "d /var/lib/em-ci/work  0750 em-ci em-ci -"
      "d /var/lib/em-ci/cache 0750 em-ci em-ci -"
    ];

    services.github-runners.em-ci = {
      enable = true;
      package = runnerPkg;
      # The unstable package supports only node24 (upstream dropped node20);
      # the stable module's default asks for both.
      nodeRuntimes = [ "node24" ];
      url = "https://github.com/johnnymo87/eternal-machinery";
      # Explicit and distinct: the module defaults the name to the attr name,
      # which is the same in both containers and would collide.
      name = "${cfg.namePrefix}-em-ci-${toString r.n}";
      # Default labels (self-hosted, Linux, plus host arch: ARM64 on devbox,
      # X64 on gamebox) plus this one. ci.yml currently asks for
      # ["self-hosted","em-ci","ARM64"] and is moving to request
      # ["self-hosted","em-ci"] (docs/plans/2026-10-11-em-ci-gamebox-design.md §5).
      extraLabels = [ "em-ci" ];
      # A config or token change re-registers under the same name.
      replace = true;
      ephemeral = false;
      tokenFile = patInContainer;
      user = "em-ci";
      group = "em-ci";
      # On disk (container state filesystem: stateDevice, else root), not the
      # default tmpfs RuntimeDirectory. The module wipes workDir on every service
      # start: one cold job per restart.
      workDir = "/var/lib/em-ci/work";

      extraEnvironment = {
        EM_CI_RUNNER = "1";
        EM_CI_CACHE_DIR = "/var/lib/em-ci/cache";
        EM_CI_CPUS = toString cfg.cpus;
      };

      extraPackages = (with pkgs; [
        bash gawk gnused gnugrep coreutils findutils diffutils procps
        util-linux which file
        git gnutar gzip zstd xz curl jq
        python3
        # test/bin/test_shutdown-all.sh runs outside devenv shell and uses
        # real perl processes as daemon fixtures.
        perl
      ]) ++ [ devenvPkg ];

      serviceOverrides = {
        # Warm caches (ccache, pip, npm, mix/hex) live outside the workDir wipe.
        ReadWritePaths = [ "/var/lib/em-ci/cache" ];
        # The module's ProtectHome=yes makes /home mode 000, so eternal-
        # machinery's devenv.nix `builtins.pathExists "/home/dev"` gets EACCES,
        # which Nix throws on (only ENOENT reads as false) and devenv reports
        # as an unrelated "restricted setting" warning. tmpfs keeps /home
        # hidden but makes the lookup a clean ENOENT.
        ProtectHome = "tmpfs";
        # The container is the isolation boundary. Unprivileged user + mount
        # namespaces are needed by eternal-machinery's sandboxed shell test
        # (test/bin/test_prepare-workspace.sh) and by Chromium's sandbox in
        # the frontend tests. Same list as the module minus "~@mount".
        RestrictNamespaces = false;
        SystemCallFilter = lib.mkForce [
          "~@clock"
          "~@cpu-emulation"
          "~@module"
          "~@obsolete"
          "~@raw-io"
          "~@reboot"
          "~capset"
          "~setdomainname"
          "~sethostname"
        ];
      };
    };
  };
in
{
  options.services.em-ci-runners = {
    enable = mkEnableOption "eternal-machinery self-hosted runner containers";
    runners = mkOption {
      type = types.attrsOf (types.submodule {
        options = {
          n = mkOption {
            type = types.int;
            description = "Runner index number for container and runner naming (e.g. 1 -> <prefix>-em-ci-1).";
          };
          hostAddress = mkOption {
            type = types.str;
            description = "IPv4 address on the host side of the container veth pair.";
          };
          localAddress = mkOption {
            type = types.str;
            description = "IPv4 address on the container side of the veth pair.";
          };
        };
      });
      description = "Container name -> addressing. Names <= 11 chars (ve-<name>) and must match em-ci-* (egress fence pattern).";
    };
    namePrefix = mkOption {
      type = types.str;
      description = "GitHub runner name prefix, e.g. devbox -> devbox-em-ci-1.";
    };
    cpus = mkOption {
      type = types.ints.positive;
      description = "Number of CPU cores allocated to each container (systemd CPUQuota = cpus * 100%).";
    };
    memoryMax = mkOption {
      type = types.str;
      description = "Maximum memory allocated to each container (systemd MemoryMax, e.g. '6G').";
    };
    stateDevice = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Block device path mounted at /var/lib/nixos-containers for container state, or null to share root.";
    };
    externalInterface = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "NAT egress interface; null masquerades on every out-interface.";
    };
    nameservers = mkOption {
      type = types.listOf types.str;
      default = [ "1.1.1.1" "9.9.9.9" "1.0.0.1" ];
      description = "DNS nameservers configured inside each runner container.";
    };
    patSecret = mkOption {
      type = types.str;
      default = "em_ci_runner_pat";
      description = "Name of sops.secrets entry holding the GitHub runner PAT (host must import sops-nix).";
    };
    watchdogMinFreeGiB = mkOption {
      type = types.ints.positive;
      default = 10;
      description = "Minimum free GiB on the host root filesystem before the disk watchdog stops all runner containers.";
    };
    pauseFlag = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "If set, container units carry ConditionPathExists=!<flag> (used by gamebox's streaming pause).";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.runners != { };
        message = "services.em-ci-runners.runners must be non-empty when enabled.";
      }
    ];

    # Dedicated block device for container state (when configured, e.g. devbox's
    # 30 GB Volume). nofail so a missing device never blocks boot; the
    # RequiresMountsFor below keeps containers from starting on root then.
    fileSystems."/var/lib/nixos-containers" = lib.mkIf (cfg.stateDevice != null) {
      device = cfg.stateDevice;
      fsType = "ext4";
      options = [ "nofail" ];
    };

    # Runner registration PAT: fine-grained, eternal-machinery only,
    # Administration read/write, no expiry. root-only; bind-mounted read-only
    # into each container, where only the module's root ExecStartPre reads it.
    #
    # ROTATION. The bind mount pins the file the sops symlink pointed at when
    # the container started, so a new value only reaches a container that is
    # restarted (restarting just the runner service re-reads the OLD file).
    # restartUnits does that on the next switch; it interrupts running jobs.
    sops.secrets.${cfg.patSecret} = {
      owner = "root";
      group = "root";
      mode = "0400";
      restartUnits = map (name: "container@${name}.service") (lib.attrNames cfg.runners);
    };

    networking.nat = {
      enable = true;
      internalInterfaces = map (name: "ve-${name}") (lib.attrNames cfg.runners);
      externalInterface = cfg.externalInterface;
    };

    containers = lib.mapAttrs (name: r: {
      autoStart = true;
      privateNetwork = true;
      inherit (r) hostAddress localAddress;
      bindMounts.${patInContainer} = {
        hostPath = config.sops.secrets.${cfg.patSecret}.path;
        isReadOnly = true;
      };
      config = containerConfig name r;
    }) cfg.runners;

    systemd.services = (lib.mapAttrs' (name: _: lib.nameValuePair "container@${name}" {
      unitConfig = lib.mkMerge [
        (lib.mkIf (cfg.stateDevice != null) {
          RequiresMountsFor = [ "/var/lib/nixos-containers" ];
        })
        (lib.mkIf (cfg.pauseFlag != null) {
          ConditionPathExists = "!${cfg.pauseFlag}";
        })
      ];
      requires = [ "em-ci-egress-fence.service" ];
      after = [ "em-ci-egress-fence.service" ];
      # systemd-nspawn mounts a tmpfs on the container's /tmp by default, which
      # would charge every job's temp files to the configured memory cap. Keep
      # /tmp on the container root, i.e. on the container state filesystem.
      environment.SYSTEMD_NSPAWN_TMPFS_TMP = "0";
      serviceConfig = {
        CPUQuota = "${toString (cfg.cpus * 100)}%";
        MemoryMax = cfg.memoryMax;
        CPUWeight = 50;
        IOWeight = 20;
      };
    }) cfg.runners) // {
      # EGRESS FENCE. NAT alone lets a container reach anything the host can
      # route to, and hosts often have more than loopback (e.g. on devbox: Docker
      # publishes ports on 0.0.0.0, such as the BoldCo Supabase stack on
      # 54321-54327, and DNATs traffic for ANY local address -- including this
      # veth's host side -- into its bridges via FORWARD, never touching the
      # INPUT firewall; Tailscale's ts-forward chain also ACCEPTs toward the
      # tailnet ahead of everything).
      #
      # So drop, in mangle PREROUTING (before Docker's nat DNAT and before any
      # FORWARD chain), every packet from a runner container addressed to the
      # host itself (any local address) or to a private/CGNAT/link-local/loopback
      # range. Public internet egress is all CI needs: GitHub, caches, the
      # Hetzner resolvers. IPv4 only; the containers have no IPv6 address.
      #
      # A dedicated service, NOT networking.firewall.extraCommands: the NixOS
      # firewall runs its stop commands on every reload and on a failed start,
      # which would open a window (or leave it open). Nothing else touches this
      # chain (the firewall manages only nixos-fw-rpfilter in mangle; Docker and
      # Tailscale manage their own chains). The service never removes the fence.
      #
      # Fail-closed: a blanket DROP for the container interfaces goes in FIRST
      # and comes out only after the fence is rebuilt, hooked and verified. Any
      # failure leaves the blanket DROP (no egress at all) and the containers,
      # which Require this unit, do not start.
      #
      # Verify after any edit:
      #   sudo iptables -t mangle -S PREROUTING | grep em-ci
      #   sudo nixos-container run em-ci-1 -- curl -sm3 http://10.233.71.1:54321; echo $?   # 28 (dropped)
      #   sudo nixos-container run em-ci-1 -- curl -sIm5 https://api.github.com | head -1     # HTTP/2 200
      em-ci-egress-fence = {
        description = "Egress fence for em-ci runner containers";
        wantedBy = [ "multi-user.target" ];
        after = [ "firewall.service" ];
        path = [ pkgs.iptables ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          set -euo pipefail
          ipt() { iptables -w -t mangle "$@"; }
          blanket=(PREROUTING -i ve-em-ci-+ -j DROP)
          hook=(PREROUTING -i ve-em-ci-+ -j em-ci-egress)

          # 1. Close everything while we work. Position 1, ahead of the hook.
          ipt -C "''${blanket[@]}" 2>/dev/null || ipt -I "''${blanket[@]:0:1}" 1 "''${blanket[@]:1}"

          # 2. (Re)build the fence chain; harmless while the blanket is first.
          ipt -N em-ci-egress 2>/dev/null || true
          ipt -F em-ci-egress
          ipt -A em-ci-egress -m addrtype --dst-type LOCAL -j DROP
          for net in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 169.254.0.0/16 127.0.0.0/8; do
            ipt -A em-ci-egress -d "$net" -j DROP
          done
          ipt -C "''${hook[@]}" 2>/dev/null || ipt -I "''${hook[@]:0:1}" 2 "''${hook[@]:1}"

          # 3. Verify, then open.
          [ "$(ipt -S em-ci-egress | grep -c -- '-j DROP')" -eq 7 ]
          ipt -C "''${hook[@]}"
          ipt -D "''${blanket[@]}"
          echo "em-ci egress fence installed"
        '';
      };

      # Hard disk guard for the host's ROOT filesystem. With stateDevice set
      # (e.g. devbox's 30 GB Volume), container writes cannot fill root, but
      # host nix store growth for CI closures can. With stateDevice = null
      # (e.g. gamebox), container roots share the root filesystem and the
      # watchdog guards against both container writes and host nix store growth.
      # Stops all containers, which fails their in-flight jobs; GitHub shows
      # them failed or queued. They stay stopped until someone starts them again:
      #   sudo systemctl start container@em-ci-1 container@em-ci-2
      # Exits non-zero when it fires so the unit shows failed. Telegram
      # alerting hooks in with bead eternal-machinery-0oycj.5.
      em-ci-disk-watchdog = {
        description = "Stop em-ci runner containers when root disk is low";
        serviceConfig.Type = "oneshot";
        path = [ pkgs.coreutils pkgs.systemd ];
        script = ''
          avail_kib=$(df --output=avail -k / | tail -n 1 | tr -d ' ')
          min_kib=$(( ${toString cfg.watchdogMinFreeGiB} * 1024 * 1024 ))
          if [ "$avail_kib" -lt "$min_kib" ]; then
            echo "<2>em-ci watchdog: root free $(( avail_kib / 1024 / 1024 )) GiB < ${toString cfg.watchdogMinFreeGiB} GiB; stopping em-ci runner containers"
            systemctl stop ${lib.concatMapStringsSep " " (n: "container@${n}.service") (lib.attrNames cfg.runners)}
            exit 1
          fi
        '';
      };
    };

    systemd.timers.em-ci-disk-watchdog = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "5min";
        OnUnitActiveSec = "5min";
      };
    };
  };
}
