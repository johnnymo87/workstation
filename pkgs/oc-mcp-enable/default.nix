{ pkgs }:

# oc-mcp-enable -- grant (or revoke) an MCP server's tools on an ALREADY-RUNNING
# opencode session, without relaunching it.
#
# Why this exists: `opencode-launch --mcp X` can only enable an MCP server at
# LAUNCH time. A swarm worker that is already running and mid-task cannot be
# granted Slack (or Jira, or PagerDuty) without killing it and losing its
# context. This closes that gap.
#
# How it works (both steps are required, and they are DIFFERENT scopes -- see
# the security/scope notes in the skill doc):
#
#   1. POST /session/<id>/mcp/<server>/connect
#      Spawns/attaches the MCP client. The resulting state lives in opencode's
#      per-DIRECTORY InstanceState on the OWNING serve process -- the sessionID
#      in the path is a routing key (it tells the front door which serve owns
#      the session, and supplies the directory). Connecting alone is what puts
#      the server's tools into the candidate tool set for the next prompt.
#
#   2. PATCH /session/<id>  {"permission": [{permission:"<server>_*",
#                                            pattern:"*", action:"allow"}]}
#      Session-scoped and persistent. Without it the tools are still VISIBLE to
#      the model but every call falls through to the default `ask` action, which
#      in a headless session blocks forever waiting for a human. The PATCH
#      handler MERGES (appends) into the existing ruleset -- unlike the
#      deprecated `tools` map on a prompt body, which REPLACES it wholesale.
#      Later rules win (findLast), which is also what makes --revoke work.
#
# The grant takes effect on the session's NEXT prompt (tools are resolved per
# message), which is exactly the swarm case: enable, then swarm_send.
pkgs.writeShellApplication {
  name = "oc-mcp-enable";
  runtimeInputs = [ pkgs.curl pkgs.jq pkgs.coreutils ];
  text = ''
      FRONTDOOR_URL="''${FRONTDOOR_URL:-http://127.0.0.1:4700}"

      usage() {
        local exit_code="''${1:-1}"
        echo "Usage: oc-mcp-enable [--revoke] <session-id> <server> [<server>...]"
        echo "       oc-mcp-enable --status <session-id>"
        echo ""
        echo "Grant an MCP server's tools to an ALREADY-RUNNING opencode session."
        echo "Takes effect on that session's NEXT prompt (e.g. the next swarm_send)."
        echo ""
        echo "Options:"
        echo "  -h, --help      Show this help message"
        echo "  --revoke        Deny <server>_* on this session instead of granting."
        echo "                  Session-scoped only: it does NOT disconnect the server,"
        echo "                  because the connection is shared by every session in the"
        echo "                  same directory on the same serve."
        echo "  --status        Print the serve's MCP connection status plus the"
        echo "                  session's current permission ruleset, and exit."
        echo ""
        echo "Examples:"
        echo "  oc-mcp-enable ses_abc123 slack-ro     # read-oriented slack"
        echo "  oc-mcp-enable ses_abc123 slack        # READ + WRITE (can post!)"
        echo "  oc-mcp-enable --revoke ses_abc123 slack"
        echo "  oc-mcp-enable --status ses_abc123"
        exit "$exit_code"
      }

      # build_permission_json <action> <server>...
      #
      # Emit a PermissionV1.Ruleset (a JSON array of
      # {permission, pattern, action}) granting or denying the whole `<server>_*`
      # tool family for each server. Pure (no network) so it is unit-testable;
      # kept in lockstep with pkgs/oc-mcp-enable/test.sh by a source-grep guard
      # in that test.
      #
      # The `_*` suffix mirrors opencode's MCP tool naming
      # (mcp/catalog.ts: sanitize(server) + "_" + sanitize(tool)). sanitize only
      # rewrites chars outside [a-zA-Z0-9_-], so a hyphenated server name like
      # `slack-ro` keeps its hyphen and `slack-ro_*` is the correct pattern.
      build_permission_json() {
        local action="$1"
        shift
        printf '%s\n' "$@" | jq -R -s -c --arg action "$action" '
          split("\n")
          | map(select(. != ""))
          | unique
          | map({permission: (. + "_*"), pattern: "*", action: $action})'
      }

      revoke=0
      status_only=0
      while [ $# -gt 0 ]; do
        case "$1" in
          --revoke) revoke=1; shift ;;
          --status) status_only=1; shift ;;
          -h|--help) usage 0 ;;
          --) shift; break ;;
          -*) echo "Error: unknown option: $1" >&2; usage ;;
          *) break ;;
        esac
      done

      if [ $# -lt 1 ]; then
        usage
      fi
      session_id="$1"
      shift

      case "$session_id" in
        ses_*) : ;;
        *) echo "Error: '$session_id' does not look like a session id (expected ses_...)" >&2; exit 1 ;;
      esac

      if [ "$status_only" -eq 0 ] && [ $# -lt 1 ]; then
        echo "Error: at least one <server> is required" >&2
        usage
      fi

      # Health check the door before anything else, so a down door reads as a
      # down door rather than as a mysterious 000 from the first real call.
      if ! curl -sf --max-time 5 "$FRONTDOOR_URL/global/health" >/dev/null 2>&1; then
        echo "Error: front door is unreachable at $FRONTDOOR_URL" >&2
        echo "Check: systemctl status opencode-frontdoor (the door) and opencode-serve-pool.target (the backends)" >&2
        exit 1
      fi

      # Resolve the session (existence check + directory). Every route below is
      # class `session-path`, so the door needs pigeon to name the owning serve;
      # a 503 here means pigeon is down. We deliberately do NOT fall back to a
      # raw serve the way opencode-launch does: the launcher may assume the
      # anchor because it just CREATED the session there, but an arbitrary
      # already-running session can live on any pool member and guessing would
      # silently target the wrong process.
      sess_body_file="$(mktemp)"
      trap 'rm -f "$sess_body_file"' EXIT
      sess_code="$(curl -s -o "$sess_body_file" -w '%{http_code}' --max-time 10 \
        "$FRONTDOOR_URL/session/$session_id")"
      case "$sess_code" in
        200) : ;;
        404)
          echo "Error: session '$session_id' not found" >&2
          exit 1
          ;;
        503)
          echo "Error: the front door cannot resolve the owning serve for '$session_id' (HTTP 503)." >&2
          echo "This usually means the pigeon daemon is down. Check: systemctl status pigeon-daemon" >&2
          exit 1
          ;;
        *)
          echo "Error: failed to look up session '$session_id' (HTTP $sess_code)" >&2
          exit 1
          ;;
      esac
      directory="$(jq -r '.directory // empty' <"$sess_body_file")"

      print_status() {
        echo "Session:    $session_id"
        echo "Directory:  ''${directory:-<unknown>}"
        echo ""
        echo "MCP servers (connection state is per-directory on the owning serve):"
        curl -s --max-time 15 "$FRONTDOOR_URL/session/$session_id/mcp" \
          -H "x-opencode-directory: $directory" \
          | jq -r 'to_entries[] | "  \(.key): \(.value.status)"' 2>/dev/null \
          || echo "  (unavailable)"
        echo ""
        echo "Session permission ruleset (later rules win):"
        curl -s --max-time 10 "$FRONTDOOR_URL/session/$session_id" \
          | jq -r '(.permission // []) | if length == 0 then "  (none)"
                   else (.[] | "  \(.action) \(.permission) [\(.pattern)]") end' 2>/dev/null \
          || echo "  (unavailable)"
      }

      if [ "$status_only" -eq 1 ]; then
        print_status
        exit 0
      fi

      servers=("$@")

      if [ "$revoke" -eq 0 ]; then
        for srv in $(printf '%s\n' "''${servers[@]}" | sort -u); do
          # --max-time is generous: connecting spawns the MCP server process
          # (several of ours are `npx -y ...`, which may hit the network on a
          # cold cache) and then completes an initialize + tools/list round trip.
          connect_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 90 \
            -X POST "$FRONTDOOR_URL/session/$session_id/mcp/$srv/connect" \
            -H "x-opencode-directory: $directory")"
          case "$connect_code" in
            200)
              echo "Connected MCP server '$srv'"
              ;;
            404)
              echo "Error: MCP server '$srv' is not configured on this host" >&2
              exit 1
              ;;
            503)
              echo "Error: front door could not route the connect for '$srv' (HTTP 503; pigeon down?)" >&2
              exit 1
              ;;
            *)
              echo "Error: failed to connect MCP server '$srv' (HTTP $connect_code)" >&2
              exit 1
              ;;
          esac
        done
      fi

      action="allow"
      [ "$revoke" -eq 1 ] && action="deny"
      permission_json="$(build_permission_json "$action" "''${servers[@]}")"

      patch_body="$(jq -n --argjson perm "$permission_json" '{permission: $perm}')"
      patch_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
        -X PATCH "$FRONTDOOR_URL/session/$session_id" \
        -H "x-opencode-directory: $directory" \
        -H "Content-Type: application/json" \
        -d "$patch_body")"
      if [ "$patch_code" != "200" ]; then
        echo "Error: failed to set permissions on session '$session_id' (HTTP $patch_code)" >&2
        if [ "$revoke" -eq 0 ]; then
          echo "The MCP server(s) are connected but the session cannot call them without a permission rule." >&2
        fi
        exit 1
      fi

      if [ "$revoke" -eq 1 ]; then
        echo "Denied ''${servers[*]} tools on session $session_id"
        echo "Note: the MCP server stays CONNECTED (shared per-directory); only this session is denied."
      else
        echo "Granted ''${servers[*]} tools to session $session_id"
        echo "Takes effect on that session's NEXT prompt (e.g. the next swarm_send)."
      fi
    '';
}
