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
#   * Datasource uses a read-only URI (pathOptions="mode=ro") + attachLimit 0
#     (disables ATTACH DATABASE) + block_list grafana.db (prevents targeting
#     Grafana's own database).
#   * Secrets are owned by grafana 0400 so agents running as dev cannot read them.
#   * root_url is the Mac tunnel URL (http://127.0.0.1:3001/) so links Grafana
#     generates open through the Mac SSH tunnel.
{ config, pkgs, ... }:

{
  services.grafana = {
    enable = true;
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
              pathOptions = "mode=ro";
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
    restartUnits = [ "grafana.service" ];
  };
  sops.secrets.grafana_secret_key = {
    owner = "grafana";
    group = "grafana";
    mode = "0400";
    restartUnits = [ "grafana.service" ];
  };
}
