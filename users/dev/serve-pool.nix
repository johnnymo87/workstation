# Single source of truth for the mn9r M5 opencode serve pool.
#
# Imported by the serve units (NixOS system on cloudbox; systemd.user on
# devbox/crostini; launchd on macOS) AND by the pigeon-daemon config on every
# host, so the pool's ports, HTTP endpoints, and serve ids are all derived from
# ONE per-host list and can never drift.
#
# DM5-4 (serve_id <-> endpoint-index alignment): pigeon mints `serve-<i>` from
# PIGEON_SERVE_ENDPOINTS order (route-registry seedServes). So the serve bound
# to the i-th port MUST set OPENCODE_SERVE_ID=serve-<i>, and the endpoint list
# pigeon sees MUST carry that port at index i. Generating ports -> endpoints ->
# serveIds here from a single list guarantees that invariant. A misalignment
# silently breaks lease acquire (assignment.desired_serve_id mismatch ->
# fail-open, no lease), so this file is the drift firewall.
#
# DM5-3 (per-device K): cloudbox 4, devbox 2, crostini 1, macOS 2. Base port
# 4096 = serve-0 so a K=1 host is ~= today's single serve and the existing
# :4096 consumers (pigeon OPENCODE_URL, lgtm, TUIs) keep working until M7.
let
  endpointsFor = ports: map (p: "http://127.0.0.1:${toString p}") ports;
  serveIdsFor = ports: builtins.genList (i: "serve-${toString i}") (builtins.length ports);
  mk = ports: {
    inherit ports;
    endpoints = endpointsFor ports;
    # CSV in port order == serve-id order (PIGEON_SERVE_ENDPOINTS format).
    endpointsCsv = builtins.concatStringsSep "," (endpointsFor ports);
    serveIds = serveIdsFor ports;
    k = builtins.length ports;
    basePort = builtins.head ports; # serve-0; ~= the old single serve.
  };
in
rec {
  # DM5-3 pool sizing; DM5-4 numbering (base 4096 = serve-0).
  portsByHost = {
    cloudbox = [ 4096 4097 4098 4099 ]; # K=4 (40G cap -> ~9G/serve)
    devbox = [ 4096 4097 ]; # K=2 (10G cap -> ~4.5G/serve)
    crostini = [ 4096 ]; # K=1 (Chromebook; trivial pool, still routed)
    darwin = [ 4096 4097 ]; # K=2
  };

  # Resolved descriptor per host, e.g. forHost.cloudbox =
  #   { ports endpoints endpointsCsv serveIds k basePort }.
  forHost = builtins.mapAttrs (_: mk) portsByHost;

  # DM5-1 routing DB: a serve's OPENCODE_ROUTING_DB and pigeon's
  # PIGEON_DAEMON_DB_PATH must be the SAME file. NOTE: pigeon-daemon.db is
  # pigeon's UNIFIED daemon DB (swarm messaging + outbox + routing all in one
  # file, src/storage/*.ts + src/routing/*.ts), so the routing DB is NOT a
  # dedicated file we can freely relocate — it must be pigeon's actual daemon DB
  # or we'd orphan pigeon's swarm/outbox state. The path therefore lives at the
  # consumer (it's pigeon's existing WorkingDirectory/data path per host), not
  # here; serve-pool.nix owns only the drift-critical ports/endpoints/serveIds.

  inherit endpointsFor serveIdsFor;
}
