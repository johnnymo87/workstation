# honkd `--mcp-allow-tools` arguments, shared by every host that runs honkd
# (cloudbox, devbox, macOS). Interpolate the result into honkd's command line:
#   ${import ./honk-mcp-allow-tools.nix { inherit lib; }}
#
# Why (bead workstation-5q5l): `slack-ro` is not read-only. slack-mcp-server
# registers channel join/leave/mark and user-group create/update tools
# unconditionally (no env gate), and only posting/uploading are gated off.
# Jonathan's call (2026-11-22): close that on goose only, since we are moving
# there. opencode's `slack-ro` still exposes them on purpose.
#
# honkd passes this list to goose as the extension's `available_tools`. goose
# drops every other tool of the server from the session's tool list and
# refuses calls to it (honk#50). It is an ALLOWLIST: a tool a server upgrade
# adds stays hidden until it is listed here. Measured against
# slack-mcp-server 1.3.0-pr334+hostguard on 2026-11-22 (tools/list,
# readOnlyHint=true for every tool below).
#
# Changing this list narrows sessions only when slack-ro is next enabled in
# them (honkd re-adds a server whose stored allowlist differs). Sessions that
# already have it keep the old list until then; re-enable it there by hand.
#
# This bounds what a goose model is offered and can call. It is not
# containment: an agent with a shell can still read the token file.
{ lib }:
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

  reopened = lib.intersectLists slackRoReadTools slackWriteTools;
in
assert lib.assertMsg (reopened == [ ])
  "honk-mcp-allow-tools.nix: slack-ro allowlist contains write tools: ${lib.concatStringsSep ", " reopened}";
"--mcp-allow-tools slack-ro=${lib.concatStringsSep "," slackRoReadTools}"
