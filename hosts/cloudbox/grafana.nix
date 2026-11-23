# Grafana OSS on cloudbox (bead workstation-4si2.3, Phase 2).
#
# Design: docs/plans/2026-11-23-llm-spend-metrics-design.md
# Plan:   docs/plans/2026-11-23-grafana-p2-plan.md
#
# Security & architecture constraints:
#   * Loopback bind is explicit and guarded (via checks.cloudbox-grafana-exposure
#     in flake.nix) because cloudbox has a public IP and no NixOS firewall.
#   * The nixpkgs unit already has PrivateTmp=true (and ProtectSystem="full"), so
#     the frser plugin's sqlite temp files work during sorts/GROUP BY without
#     disk I/O errors.
#   * Datasource uses a read-only URI (pathOptions "mode=ro") + attachLimit 0.
#     attachLimit is load-bearing: mode=ro alone still allows ATTACH and
#     `VACUUM INTO '/tmp/x'`, i.e. copying out any SQLite file grafana can read.
#     block_list grafana.db stops a datasource being pointed at Grafana's own DB.
#   * busy_timeout(5000) in pathOptions: neither frser nor its modernc driver
#     sets one, so without it every panel query that lands in the writer's
#     commit window (every 5 min) fails instantly with SQLITE_BUSY. The other
#     direction is a known limit: a reader holding its SHARED lock for longer
#     than the writer's 30 s busy_timeout fails the llm-ledger run (and pages).
#     Real panels take well under a second; runaway Explore queries are the risk.
#   * A hot journal left by a crashed writer makes reads fail with
#     SQLITE_READONLY_ROLLBACK until the writer's next run rolls it back.
#   * Secrets are grafana-owned 0400. That is hygiene, not a boundary against
#     agents: dev has passwordless sudo and owns /var/lib/llm-ledger, so do not
#     put anything in Grafana on the assumption that agents cannot log in as
#     admin. Read the password with `sudo cat /run/secrets/grafana_admin_password`.
#   * Rotation: admin_password only applies when grafana.db is first created;
#     to change it later use `sudo -u grafana grafana cli --homepath
#     /var/lib/grafana admin reset-admin-password <new>` (and update sops to
#     match). Never rotate secret_key casually: it encrypts stored secure
#     fields, which become unreadable. Neither secret has restartUnits, so a
#     sops edit cannot rotate either as a side effect of a switch.
#   * External snapshot publishing (snapshots.raintank.io) is off: it would put
#     spend data and account names on the public internet.
#   * root_url is the Mac tunnel URL (http://127.0.0.1:3001/) so links Grafana
#     generates open through the Mac SSH tunnel.
{ config, pkgs, ... }:

{
  services.grafana = {
    enable = true;
    openFirewall = false; # Cloudbox has a public IP; never open Grafana firewall ports.
    declarativePlugins = [ pkgs.grafanaPlugins.frser-sqlite-datasource ];
    settings = {
      server = {
        http_addr = "127.0.0.1";
        http_port = 3000;
        protocol = "http";
        domain = "127.0.0.1";
        root_url = "http://127.0.0.1:3001/";
      };
      analytics = {
        reporting_enabled = false;
        check_for_updates = false;
        check_for_plugin_updates = false;
        feedback_links_enabled = false;
      };
      news.news_feed_enabled = false;
      security = {
        admin_password = "$__file{${config.sops.secrets.grafana_admin_password.path}}";
        secret_key = "$__file{${config.sops.secrets.grafana_secret_key.path}}";
        disable_gravatar = true;
      };
      users.allow_sign_up = false;
      snapshots.external_enabled = false;
      "plugin.frser-sqlite-datasource".block_list = "grafana.db";
    };
    provision = {
      enable = true;
      datasources.settings = {
        apiVersion = 1;
        datasources = [
          {
            name = "llm-ledger";
            uid = "llm-ledger";
            type = "frser-sqlite-datasource";
            access = "proxy";
            isDefault = true;
            editable = false;
            jsonData = {
              path = "/var/lib/llm-ledger/ledger.db";
              pathPrefix = "file:";
              pathOptions = "mode=ro&_pragma=busy_timeout(5000)";
              attachLimit = 0;
            };
          }
        ];
      };
    };
  };

  users.users.grafana.extraGroups = [ "llm-ledger" ];

  sops.secrets.grafana_admin_password = {
    owner = "grafana";
    group = "grafana";
    mode = "0400";
  };
  sops.secrets.grafana_secret_key = {
    owner = "grafana";
    group = "grafana";
    mode = "0400";
  };
}
