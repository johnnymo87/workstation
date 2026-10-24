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
#      the server's tools into the candidate tool set for the next step.
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
# The grant takes effect on the session's NEXT STEP (next model call), even
# mid-turn: the run loop re-reads session.permission and the connected MCP
# tools every step (opencode-patched permission-refresh-per-step.patch,
# >= 1.18.18-patched.5). Before that patch a busy session kept the ruleset it
# started the run with, so a grant after an earlier --revoke was invisible
# until the run ended. Task subagents never see it: a child copies only its
# parent's deny/external_directory rules at creation, not allows.
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
        echo "Takes effect on that session's next step, even mid-turn (not in its Task subagents)."
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

      # door_503_cause <response-body-file>
      #
      # A 503 from the front door is NOT one condition. The door emits it for
      # (a) its own first-byte timeout, (b) a wedged target serve, and (c) pigeon
      # being unavailable for a mutating route -- and they need different
      # responses. Name the one the door actually reported instead of guessing.
      # 2026-10-22: every atlassian connect hit (a) because Atlassian's remote
      # MCP was slow, the old message said "pigeon down?", and the agent went
      # around the MCP with REST calls. Pigeon was healthy throughout.
      door_503_cause() {
        local msg
        msg="$(jq -r '.message // empty' <"$1" 2>/dev/null || true)"
        case "$msg" in
          *"did not send response headers in time"*)
            echo "the front door gave up waiting for the owning serve to answer (its first-byte timeout)."
            echo "For an MCP connect this means the MCP server was slow to start or its upstream is slow -- NOT that pigeon is down."
            ;;
          *wedged*)
            echo "the owning serve failed the front door's health probe (wedged). See the monitoring-serve-pool skill."
            ;;
          *pigeon*)
            echo "pigeon is unavailable, so the front door cannot name the owning serve. Check: systemctl status pigeon-daemon"
            ;;
          "")
            echo "the front door returned 503 with no explanation."
            ;;
          *)
            echo "the front door said: $msg"
            ;;
        esac
      }

      # Printed after every failure to make a server available. An agent that
      # cannot get an MCP server tends to reach for whatever credentials are in
      # its environment instead; that route is not sanctioned.
      mcp_unavailable_footer() {
        echo "The '$1' MCP server is NOT available to this session. Do not work around it by calling the" >&2
        echo "service's API directly (curl/REST with credentials from the environment). Stop and report this" >&2
        echo "error to the human." >&2
      }

      # Printed when the requested MCP server is not configured, but the catalog
      # of available servers was successfully retrieved.
      mcp_unknown_footer() {
        echo "A misspelled or unknown MCP server name is a caller error: retry with one of the listed" >&2
        echo "names; only if the intended server is genuinely absent, report to the human. Do not work" >&2
        echo "around it by calling the service's API directly (curl/REST with credentials from the" >&2
        echo "environment)." >&2
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
      # class `session-path`, so the door needs pigeon to name the owning serve.
      # We deliberately do NOT fall back to a
      # raw serve the way opencode-launch does: the launcher may assume the
      # anchor because it just CREATED the session there, but an arbitrary
      # already-running session can live on any pool member and guessing would
      # silently target the wrong process.
      sess_body_file="$(mktemp)"
      connect_body_file="$(mktemp)"
      catalog_body_file="$(mktemp)"
      trap 'rm -f "$sess_body_file" "$connect_body_file" "$catalog_body_file"' EXIT
      sess_code="$(curl -s -o "$sess_body_file" -w '%{http_code}' --max-time 10 \
        "$FRONTDOOR_URL/session/$session_id")"
      case "$sess_code" in
        200) : ;;
        404)
          echo "Error: session '$session_id' not found" >&2
          exit 1
          ;;
        503)
          echo "Error: could not look up session '$session_id' (HTTP 503): $(door_503_cause "$sess_body_file")" >&2
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
          : >"$connect_body_file"
          connect_code="$(curl -s -o "$connect_body_file" -w '%{http_code}' --max-time 90 \
            -X POST "$FRONTDOOR_URL/session/$session_id/mcp/$srv/connect" \
            -H "x-opencode-directory: $directory" || true)"
          case "$connect_code" in
            200) : ;;
            404)
              echo "Error: MCP server '$srv' is not configured on this host" >&2
              : >"$catalog_body_file"
              catalog_code="$(curl -s -o "$catalog_body_file" -w '%{http_code}' --max-time 15 \
                "$FRONTDOOR_URL/session/$session_id/mcp" \
                -H "x-opencode-directory: $directory" || true)"
              suggestion=""
              if [ "$catalog_code" = "200" ]; then
                suggestion="$(jq -r --arg s "$srv" '
                  (if type == "object" then [to_entries[] | select(.value | type == "object") | .key] | sort else [] end) as $all |
                  ($all | map(select((. != $s) and (ascii_downcase | startswith($s | ascii_downcase))))) as $prefix |
                  ($all | map(select((. != $s) and (ascii_downcase | contains($s | ascii_downcase)) and (ascii_downcase | startswith($s | ascii_downcase) | not)))) as $contain |
                  ($prefix + $contain) as $matches |
                  if ($all | length) == 0 then empty
                  elif ($matches | length) > 0 then "did you mean: " + ($matches | join(", "))
                  else "configured servers: " + ($all | join(", "))
                  end
                ' <"$catalog_body_file" 2>/dev/null || true)"
              fi
              if [ -n "$suggestion" ]; then
                echo "$suggestion" >&2
                mcp_unknown_footer
              else
                mcp_unavailable_footer "$srv"
              fi
              exit 1
              ;;
            503)
              echo "Error: connecting MCP server '$srv' failed (HTTP 503): $(door_503_cause "$connect_body_file")" >&2
              mcp_unavailable_footer "$srv"
              exit 1
              ;;
            000)
              echo "Error: no answer within 90s while connecting MCP server '$srv' (the server or its upstream is hanging)" >&2
              mcp_unavailable_footer "$srv"
              exit 1
              ;;
            *)
              echo "Error: failed to connect MCP server '$srv' (HTTP $connect_code): $(head -c 300 "$connect_body_file")" >&2
              mcp_unavailable_footer "$srv"
              exit 1
              ;;
          esac

          # HTTP 200 does NOT mean connected. The serve answers 200 `true` even
          # when the server ends in status `failed` (measured 2026-10-22: 200
          # after 48s, status `failed: Failed to get tools`), so read the
          # resulting state back. Granting on a failed connect would hand the
          # session an allow rule for tools that do not exist and report success.
          srv_state="$(curl -s --max-time 15 "$FRONTDOOR_URL/session/$session_id/mcp" \
            -H "x-opencode-directory: $directory" \
            | jq -r --arg s "$srv" '.[$s] // {} | "\(.status // "unknown")\t\(.error // "")"' 2>/dev/null \
            || printf 'unknown\t')"
          srv_status="''${srv_state%%$'\t'*}"
          srv_error="''${srv_state#*$'\t'}"
          case "$srv_status" in
            connected)
              echo "Connected MCP server '$srv'"
              ;;
            unknown)
              # Could not READ the state (status call failed, or no entry).
              # That is not evidence the connect failed, so grant -- a rule
              # for tools that turn out not to exist is inert -- but do not
              # claim success either.
              echo "Warning: connect for MCP server '$srv' returned 200 but its state could not be read back." >&2
              echo "Check with: oc-mcp-enable --status $session_id" >&2
              ;;
            *)
              detail=""
              [ -n "$srv_error" ] && detail=" ($srv_error)"
              echo "Error: MCP server '$srv' did not connect: status=$srv_status$detail" >&2
              case "$srv_status" in
                needs_auth|needs_client_registration)
                  echo "It needs (re-)authentication, which only the human can do; see the server's setup skill." >&2
                  ;;
              esac
              mcp_unavailable_footer "$srv"
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
        echo "Takes effect on that session's next step, even mid-turn (not in its Task subagents)."
      fi
    '';
}
