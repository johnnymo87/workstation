# Self-hosted GitHub Actions runners for johnnymo87/eternal-machinery.
#
# Two declarative NixOS containers, em-ci-1 and em-ci-2, each running one
# non-ephemeral runner (labels: self-hosted, Linux, ARM64, em-ci). The
# eternal-machinery workflow (.github/workflows/ci.yml) routes its heavy jobs
# here when the repo variable HEAVY_RUNNER (or a PR label / dispatch input)
# says so; otherwise they stay on GitHub-hosted runners.
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
# DISK. Both container roots live under /var/lib/nixos-containers, which is
# the dedicated 30 GB Hetzner Volume `em-ci` (id 107073920). Everything a job
# writes -- workspace, caches, its private /tmp -- is on that Volume and
# cannot fill devbox's root disk. What still lands on root is the host
# nix-daemon's store growth (devenv closures), governed by nix.gc/min-free.
# The watchdog below is the hard stop for that.
#
# RESOURCES. Each container is capped at 4 CPUs and 6 GiB. Builds that the
# host nix-daemon performs on a container's behalf run in nix-daemon's cgroup
# and are NOT covered by these caps; they are bounded only by the host's
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
# against `nix eval --raw .#nixosConfigurations.devbox.config.containers.em-ci-1.config.services.github-runners.em-ci.package.version`
# and if the runner is behind, `nix flake update nixpkgs-unstable` (note this
# also moves gamebox's Sunshine), rebuild, and confirm both runners are Online.
# If unstable has not caught up yet, override only this package.
#
# VERIFY after a deploy (see the bead for the full list):
#   gh api repos/johnnymo87/eternal-machinery/actions/runners \
#     --jq '.runners[]|.name+" "+.status'                      # both online
#   sudo nixos-container run em-ci-1 -- curl -sm3 10.233.71.1:5434; echo $?  # must fail
#   sudo nixos-container run em-ci-1 -- runuser -u em-ci -- cat /run/em-ci/pat  # denied
{ config, lib, pkgs, nixpkgs-unstable, devenvPkg, ... }:

let
  # One /30 per container: host side .1/.5, container side .2/.6.
  runners = {
    em-ci-1 = { n = 1; hostAddress = "10.233.71.1"; localAddress = "10.233.71.2"; };
    em-ci-2 = { n = 2; hostAddress = "10.233.71.5"; localAddress = "10.233.71.6"; };
  };

  runnerPkg = nixpkgs-unstable.legacyPackages.${pkgs.stdenv.hostPlatform.system}.github-runner;

  # Fixed so files on the Volume keep a stable owner across rebuilds. Not used
  # by anything on the host (verified with getent at authoring time).
  ciUid = 2001;

  patInContainer = "/run/em-ci/pat";

  # Root free space below this stops both containers (ends in-flight jobs).
  watchdogMinFreeGiB = 10;

  containerConfig = name: r: { ... }: {
    system.stateVersion = "25.11";

    # The host nix-daemon (bind-mounted socket) does the actual work; these
    # are client-side settings for `nix` and devenv inside the container.
    nix.settings.experimental-features = [ "nix-command" "flakes" ];

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
      name = "devbox-em-ci-${toString r.n}";
      # Default labels (self-hosted, Linux, ARM64) plus this one; ci.yml asks
      # for ["self-hosted","em-ci","ARM64"].
      extraLabels = [ "em-ci" ];
      # A config or token change re-registers under the same name.
      replace = true;
      ephemeral = false;
      tokenFile = patInContainer;
      user = "em-ci";
      group = "em-ci";
      # On disk (the Volume), not the default tmpfs RuntimeDirectory. The
      # module wipes workDir on every service start: one cold job per restart.
      workDir = "/var/lib/em-ci/work";

      extraEnvironment = {
        EM_CI_RUNNER = "1";
        EM_CI_CACHE_DIR = "/var/lib/em-ci/cache";
        EM_CI_CPUS = "4";
      };

      extraPackages = (with pkgs; [
        bash gawk gnused gnugrep coreutils findutils diffutils procps
        util-linux which file
        git gnutar gzip zstd xz curl jq
        python3
      ]) ++ [ devenvPkg ];

      serviceOverrides = {
        # Warm caches (ccache, pip, npm, mix/hex) live outside the workDir wipe.
        ReadWritePaths = [ "/var/lib/em-ci/cache" ];
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
  # The 30 GB Volume. nofail so a missing Volume never blocks boot; the
  # RequiresMountsFor below keeps the containers from starting on root then.
  fileSystems."/var/lib/nixos-containers" = {
    device = "/dev/disk/by-id/scsi-0HC_Volume_107073920";
    fsType = "ext4";
    options = [ "nofail" ];
  };

  # Runner registration PAT: fine-grained, eternal-machinery only,
  # Administration read/write, no expiry. root-only; bind-mounted read-only
  # into each container, where only the module's root ExecStartPre reads it.
  sops.secrets.em_ci_runner_pat = {
    owner = "root";
    group = "root";
    mode = "0400";
  };

  networking.nat = {
    enable = true;
    internalInterfaces = map (name: "ve-${name}") (lib.attrNames runners);
    externalInterface = "enp1s0";
  };

  containers = lib.mapAttrs (name: r: {
    autoStart = true;
    privateNetwork = true;
    inherit (r) hostAddress localAddress;
    bindMounts.${patInContainer} = {
      hostPath = config.sops.secrets.em_ci_runner_pat.path;
      isReadOnly = true;
    };
    config = containerConfig name r;
  }) runners;

  systemd.services = (lib.mapAttrs' (name: _: lib.nameValuePair "container@${name}" {
    unitConfig.RequiresMountsFor = [ "/var/lib/nixos-containers" ];
    serviceConfig = {
      CPUQuota = "400%";
      MemoryMax = "6G";
      CPUWeight = 50;
      IOWeight = 20;
    };
  }) runners) // {
    # Hard disk guard for devbox's ROOT filesystem (the Volume cannot fill
    # root, but host nix store growth for CI closures can). Stops both
    # containers, which fails their in-flight jobs; GitHub shows them failed
    # or queued. They stay stopped until someone starts them again:
    #   sudo systemctl start container@em-ci-1 container@em-ci-2
    # Exits non-zero when it fires so the unit shows failed. Telegram
    # alerting hooks in with bead eternal-machinery-0oycj.5.
    em-ci-disk-watchdog = {
      description = "Stop em-ci runner containers when root disk is low";
      serviceConfig.Type = "oneshot";
      path = [ pkgs.coreutils pkgs.systemd ];
      script = ''
        avail_kib=$(df --output=avail -k / | tail -n 1 | tr -d ' ')
        min_kib=$(( ${toString watchdogMinFreeGiB} * 1024 * 1024 ))
        if [ "$avail_kib" -lt "$min_kib" ]; then
          echo "<2>em-ci watchdog: root free $(( avail_kib / 1024 / 1024 )) GiB < ${toString watchdogMinFreeGiB} GiB; stopping em-ci runner containers"
          systemctl stop ${lib.concatMapStringsSep " " (n: "container@${n}.service") (lib.attrNames runners)}
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

  # Local `mix credo` diff runs leave /tmp/credo-diff-<ts> checkouts behind
  # (~2 GB/day). Age out their contents after a day; the empty dirs remain.
  systemd.tmpfiles.rules = [
    "e /tmp/credo-diff-* - - - 1d"
  ];
}
