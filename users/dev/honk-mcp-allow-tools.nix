# honkd `--mcp-allow-tools` (and datadog's `--mcp-query-override`) arguments, shared by every host that runs honkd
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
# datadog (beads honk-9qf.15.17, honk-yc7.1): the catalog's datadog URL asks
# for `?toolsets=all`, 531 tools, which pushed a Gemini (Neon) goose session
# past Gemini's 512 function declarations per request. Jonathan's call
# (2026-11-25): leave the opencode config alone (opencode is going away) and
# narrow it on the goose side, from what Claude actually used.
#
# The usage: every datadog_* tool call in cloudbox's opencode.db, 3,660 calls
# in 239 sessions (2026-03-09 .. 2026-10-09). From 2026-07-14 opencode saw all
# 531 tools; in that window Claude called 34 distinct tools (2,647 calls), ~97%
# of them in `core`, and never a write tool. Full ranked table: bead
# honk-yc7.1. So:
#   - `--mcp-query-override datadog:toolsets=...` asks Datadog for only the
#     toolsets the list below draws from: 88 tools instead of 531, so mcp-remote
#     fetches 0.2 MB of tool definitions instead of 1.4 MB.
#   - The allowlist is the read-only tools of those toolsets that were used, or
#     that stand in for one: `search_datadog_entities` replaced
#     `search_datadog_services` (15 calls); the incident pair is kept for
#     on-call although no session needed it. Added from usage: ddsql_run_query
#     (ddsql), find_datadog_database_instances (dbm). Dropped as never called
#     in 3,660 calls: aggregate_rum_events, ask_widget_expert,
#     get_widget_reference, get_datadog_notebook, apm_get_service_health,
#     list_downtimes. Left out though seen once or twice, mostly failing:
#     kubernetes, security schemas, audit trail, feature flags.
# Measured with tools/list against https://mcp.us3.datadoghq.com/v1/mcp on
# 2026-11-25 (readOnlyHint=true for every tool listed). A worker that needs a
# write tool or another toolset gets it added here, and its toolset added to
# datadogToolsets.
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
    # core
    "aggregate_events"
    "aggregate_spans"
    "analyze_datadog_logs"
    "execute_code"
    "get_change_stories"
    "get_datadog_dashboard"
    "get_datadog_incident"
    "get_datadog_metric"
    "get_datadog_metric_context"
    "get_datadog_trace"
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
    # alerting
    "monitor_groups_search"
    "search_datadog_slos"
    "validate_monitor_definition"
    # error-tracking
    "analyze_datadog_error_tracking_errors"
    "get_datadog_error_tracking_issue"
    "search_datadog_error_tracking_issues"
    # ddsql
    "ddsql_run_query"
    # dbm
    "find_datadog_database_instances"
  ];

  # The toolsets datadogReadTools comes from (Datadog's names). `core` is not
  # implied once others are named.
  datadogToolsets = [ "core" "alerting" "error-tracking" "ddsql" "dbm" ];

  # Every tool with readOnlyHint=false in datadogToolsets (15 of their 88).
  # execute_code_write can delete Datadog resources.
  datadogWriteTools = [
    "create_datadog_monitor"
    "create_datadog_notebook"
    "create_datadog_published_analysis"
    "ddsql_upsert_saved_query"
    "delete_datadog_notebook"
    "delete_datadog_published_analysis"
    "edit_datadog_notebook"
    "execute_code_write"
    "manage_datadog_error_tracking_issue_comments"
    "manage_datadog_error_tracking_issue_links"
    "recover_datadog_notebook"
    "update_datadog_error_tracking_issue"
    "update_datadog_monitor"
    "update_datadog_published_analysis"
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
  ++ lib.optionals datadog [
    (flag "datadog" datadogReadTools)
    "--mcp-query-override datadog:toolsets=${lib.concatStringsSep "," datadogToolsets}"
  ]
)
