# #em-alerts: where the em-* monitors (em-ci-monitor, em-ci-failover,
# em-stack-monitor) post, in the devbox Slack workspace ("pigeon devbox").
#
# They post through the "em-alerts" Slack app's incoming webhook, which can post
# to that one channel and nothing else. They hold no pigeon credential (the
# daemon bearer, or the Telegram bot token they used before): pigeon bead
# pigeon-4ogz.9, which folds pigeon-lenr.4. Spec: pigeon
# docs/plans/2026-11-20-slack-transport-design.md section 8 (D8).
#
# Each monitor's .nix prepends `script` (em-slack.sh, which defines slack_send)
# to its own script, loads the webhook as credential slack_webhook, and sets
# `env` (below). Posts @-mention the owner, and so push to his phone, only when
# notifyOwner is true. It is false: spec D7 (revised by pigeon design PR #231)
# starts with no pushes at all, and #em-alerts has no per-channel override.
#
# Rotating the webhook: re-install the em-alerts app on api.slack.com/apps (it
# issues a new URL, the old one keeps working until removed), put the new URL in
# secrets/devbox.yaml as em_alerts_slack_webhook, rebuild devbox.
{ config, lib, ... }:

{
  options.devbox.emAlerts = {
    notifyOwner = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Prefix every #em-alerts post with an @-mention of ownerId (a push).";
    };
    ownerId = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      # Jonathan in the devbox workspace (T0CLL1EQAM6); pigeon-4ogz.7 notes.
      default = "U0CKTGLSULR";
      description = "Slack user id the em-* monitors @-mention in #em-alerts.";
    };
    env = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      readOnly = true;
      description = "Environment em-slack.sh reads; merged into each monitor unit.";
    };
    script = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = builtins.readFile ./em-slack.sh;
      description = "em-slack.sh, prepended to each monitor's script.";
    };
  };

  config.devbox.emAlerts.env = {
    PIGEON_SLACK_NOTIFY_OWNER = if config.devbox.emAlerts.notifyOwner then "1" else "0";
    EM_SLACK_OWNER_ID = config.devbox.emAlerts.ownerId;
  };

  config.sops.secrets.em_alerts_slack_webhook = {
    owner = "root";
    group = "root";
    mode = "0400";
  };
}
