# lgtm-sample: a Docker network for running untrusted PR-head code, and the two
# host firewall rules that make it safe to run (bead lgtm-oqw2.11.33; port plan
# docs/plans/2026-11-11-lgtm-mono-port-plan.md §8 "Live bazel sample" in
# johnnymo87/lgtm; approved by Jonathan 2026-11-18).
#
# The lgtm mono port's live bazel sample runs `bazel query` at a PR's head, so it
# executes code the PR chose (.bazelversion, tools/bazel, repository rules). It
# needs general egress (BuildBuddy and the package registries), but it must not
# reach either of two things that a plain container on cloudbox can reach today:
#
#   1. The host's own services. cloudbox runs NO host firewall (GCP's ingress
#      firewall only filters traffic from outside the VM), and a container can
#      connect to anything listening on the bridge gateway or on the VM's
#      internal IP: sshd, pigeon, the opencode serve pool, cfp, redis, ...
#      DOCKER-USER cannot stop that, because it sits in FORWARD and traffic to
#      the host itself goes through INPUT. So: INPUT drop for everything that
#      arrives on this network's bridge, which is why the bridge has a fixed
#      name. IPv6 is off on the network, and the same drop is installed for
#      IPv6 anyway, because the bridge still gets a link-local address.
#
#   2. The GCE metadata server (169.254.169.254:80), which hands out tokens for
#      the VM's default compute service account. This rule is for ALL forwarded
#      container traffic, not just this network: `docker build` steps and
#      testcontainers run on the default bridge and have the same reach. Port
#      53 to the same address stays open, because it is also cloudbox's DNS
#      resolver (/etc/resolv.conf), and containers on the default bridge use it
#      directly. Containers on `--network host` are the host and are not
#      covered; nothing here uses that for untrusted code.
#
# Checked before this landed (2026-11-18): no container on cloudbox used the
# metadata server. The aigateway forwards its caller's own Authorization header
# to Vertex rather than using ADC, and a conntrack snapshot showed no container flow to
# 169.254.169.254 other than DNS.
#
# Shape of the unit:
#   - Rules first, network second, so there is no moment at which the network
#     exists without its INPUT drop (iptables matches `-i` by name, so the rule
#     can exist before the bridge does).
#   - Idempotent: every rule is checked with -C before it is inserted, and the
#     network is created only when absent.
#   - An existing `lgtm-sample` network with the wrong bridge name or IPv6 on
#     FAILS the unit rather than being recreated: containers may be attached,
#     and the INPUT drop keys on the bridge name.
#   - No ExecStop. Stopping the unit (or docker) leaves the rules in place: a
#     firewall that comes down with a service restart fails open.
#   - Re-run on every docker start: `wantedBy = docker.service` pulls it in
#     whenever docker starts, including the stop+start pair that
#     switch-to-configuration issues for a changed docker.service (see the
#     aigateway unit's comment for why PartOf alone misses that case), and
#     `partOf` re-runs it on a plain `systemctl restart docker`. dockerd
#     recreates DOCKER-USER on start, but does not promise to keep its rules.
#
# Verifying it by hand: food-truck/mono's live-sample preflight, run from a
# container on lgtm-sample, must pass, and must FAIL after deleting any one of
# these rules; `systemctl restart lgtm-sample-network` puts it back.
{ config, pkgs, lib, ... }:

let
  docker = config.virtualisation.docker.package;
  iptables = pkgs.iptables;

  network = "lgtm-sample";
  bridge = "lgtm-sample0";
  metadata = "169.254.169.254";

  script = pkgs.writeShellScript "lgtm-sample-network" ''
    set -euo pipefail
    ipt=${iptables}/bin/iptables
    ip6t=${iptables}/bin/ip6tables
    dk=${docker}/bin/docker

    # ensure <tool> <chain> <rule...>: insert at the top unless already present.
    ensure() {
      local tool=$1 chain=$2
      shift 2
      if "$tool" -w -C "$chain" "$@" 2>/dev/null; then
        echo "present: $chain $*"
      else
        "$tool" -w -I "$chain" 1 "$@"
        echo "inserted: $chain $*"
      fi
    }

    # 1. Host services: drop everything that enters the host from the bridge.
    ensure "$ipt" INPUT -i ${bridge} -j DROP
    ensure "$ip6t" INPUT -i ${bridge} -j DROP

    # 2. Metadata HTTP, for all forwarded container traffic. dockerd creates
    #    DOCKER-USER on start; its absence means docker is not up, which is a
    #    failure, not something to paper over.
    if ! "$ipt" -w -n -L DOCKER-USER >/dev/null 2>&1; then
      echo "DOCKER-USER chain missing; is dockerd running with iptables on?" >&2
      exit 1
    fi
    ensure "$ipt" DOCKER-USER -d ${metadata}/32 -p tcp --dport 80 -j DROP

    # 3. The network.
    if "$dk" network inspect ${network} >/dev/null 2>&1; then
      got_bridge=$("$dk" network inspect ${network} \
        --format '{{index .Options "com.docker.network.bridge.name"}}')
      got_v6=$("$dk" network inspect ${network} --format '{{.EnableIPv6}}')
      if [ "$got_bridge" != ${bridge} ] || [ "$got_v6" != false ]; then
        echo "network ${network} exists with bridge='$got_bridge' ipv6=$got_v6;" \
          "expected bridge=${bridge} ipv6=false. Not recreating it (containers" \
          "may be attached): remove it by hand and restart this unit." >&2
        exit 1
      fi
      echo "present: network ${network} (bridge ${bridge}, ipv6 off)"
    else
      "$dk" network create --driver bridge --ipv6=false \
        -o com.docker.network.bridge.name=${bridge} ${network}
      echo "created: network ${network} (bridge ${bridge}, ipv6 off)"
    fi
  '';
in
{
  systemd.services.lgtm-sample-network = {
    description = "lgtm-sample docker network and its host firewall rules";
    after = [ "docker.service" ];
    requires = [ "docker.service" ];
    partOf = [ "docker.service" ];
    wantedBy = [ "docker.service" "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = script;
    };
  };
}
