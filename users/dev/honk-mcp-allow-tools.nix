# honkd `--mcp-allow-tools` arguments, shared by every host that runs honkd
# (cloudbox, devbox, macOS). Interpolate the result into honkd's command line:
#   ${import ./honk-mcp-allow-tools.nix { inherit lib; }}
# A host whose MCP catalog has no `datadog` entry (devbox) passes
# `datadog = false`, or honkd warns at every start that the allowlist names a
# server it cannot find.
#
# honkd passes each list to goose as the extension's `available_tools`. goose
# drops every other tool of the server from the session's tool list and
# refuses calls to it (honk#50). It is an ALLOWLIST: a tool a server upgrade
# adds stays hidden until it is listed here.
#
# Changing a list narrows sessions only when the server is next enabled in
# them (honkd re-adds a server whose stored allowlist differs). Sessions that
# already have it keep the old list until then; re-enable it there by hand.
#
# This bounds what a goose model is offered and can call. It is not
# containment: an agent with a shell can still read the token file.
#
# slack-ro (bead workstation-5q5l): `slack-ro` is not read-only.
# slack-mcp-server registers channel join/leave/mark and user-group
# create/update tools unconditionally (no env gate), and only posting/uploading
# are gated off. Jonathan's call (2026-11-22): close that on goose only, since
# we are moving there. opencode's `slack-ro` still exposes them on purpose.
# Measured against slack-mcp-server 1.3.0-pr334+hostguard on 2026-11-22
# (tools/list, readOnlyHint=true for every tool below).
#
# datadog (bead honk-9qf.15.17): the catalog's datadog URL asks for
# `?toolsets=all`, which is 531 tools. Enabling it pushed a Gemini (Neon)
# goose session past Gemini's 512 function declarations per request, and the
# session died. Jonathan's call (2026-11-25): leave the opencode config alone
# (opencode is going away) and narrow it on the goose side. The list is the
# read-only part of Datadog's default `core` toolset (the URL without
# `toolsets`): monitors, logs, metrics, traces/spans, events, dashboards,
# incidents, hosts, notebooks, RUM. Measured with tools/list against
# https://mcp.us3.datadoghq.com/v1/mcp on 2026-11-25: core is 37 tools, 28
# with readOnlyHint=true once the three `_dd_*` "do-not-call" tools are left
# out. Eight read-only tools from other toolsets (error tracking, monitor
# groups, downtimes, SLOs, service health) are added, for 36 in all. A worker
# that needs a write tool (monitor create/update) or another toolset gets it
# added here.
{ lib, datadog ? true }:
let
  slackRoReadTools = [
    "attachment_get_data"
    "channels_list"
    "channels_me"
    "conversations_history"
    "conversations_replies"
    "conversations_search_messages"
    "conversations_unreads"
    "usergroups_list"
    "users_search"
  ];

  # readOnlyHint=false in slack-mcp-server. Listing one of these above would
  # quietly reopen the gap, so evaluation fails instead.
  slackWriteTools = [
    "conversations_add_message"
    "conversations_join"
    "conversations_leave"
    "conversations_mark"
    "file_upload"
    "usergroups_create"
    "usergroups_me"
    "usergroups_update"
    "usergroups_users_update"
  ];

  datadogReadTools = [
    "aggregate_events"
    "aggregate_rum_events"
    "aggregate_spans"
    "analyze_datadog_logs"
    "ask_widget_expert"
    "execute_code"
    "get_change_stories"
    "get_datadog_dashboard"
    "get_datadog_incident"
    "get_datadog_metric"
    "get_datadog_metric_context"
    "get_datadog_notebook"
    "get_datadog_trace"
    "get_widget_reference"
    "list_datadog_skills"
    "load_datadog_skill"
    "search_datadog_dashboards"
    "search_datadog_entities"
    "search_datadog_events"
    "search_datadog_hosts"
    "search_datadog_incidents"
    "search_datadog_logs"
    "search_datadog_metrics"
    "search_datadog_monitors"
    "search_datadog_notebooks"
    "search_datadog_rum_events"
    "search_datadog_sdk"
    "search_datadog_spans"
    # Read-only tools from outside core (toolsets=all), for error triage,
    # monitor status and service health.
    "analyze_datadog_error_tracking_errors"
    "apm_get_service_health"
    "get_datadog_error_tracking_issue"
    "list_downtimes"
    "monitor_groups_search"
    "search_datadog_error_tracking_issues"
    "search_datadog_slos"
    "validate_monitor_definition"
  ];

  # The core toolset's tools with readOnlyHint=false. execute_code_write can
  # delete Datadog resources.
  datadogWriteTools = [
    "create_datadog_notebook"
    "delete_datadog_notebook"
    "edit_datadog_notebook"
    "execute_code_write"
    "recover_datadog_notebook"
    "upsert_datadog_dashboard"
  ];

  slackReopened = lib.intersectLists slackRoReadTools slackWriteTools;
  datadogReopened = lib.intersectLists datadogReadTools datadogWriteTools;

  flag = server: tools: "--mcp-allow-tools ${server}=${lib.concatStringsSep "," tools}";
in
assert lib.assertMsg (slackReopened == [ ])
  "honk-mcp-allow-tools.nix: slack-ro allowlist contains write tools: ${lib.concatStringsSep ", " slackReopened}";
assert lib.assertMsg (datadogReopened == [ ])
  "honk-mcp-allow-tools.nix: datadog allowlist contains write tools: ${lib.concatStringsSep ", " datadogReopened}";
lib.concatStringsSep " " (
  [ (flag "slack-ro" slackRoReadTools) ]
  ++ lib.optional datadog (flag "datadog" datadogReadTools)
)
