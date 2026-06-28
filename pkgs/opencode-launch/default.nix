{ pkgs }:

pkgs.writeShellApplication {
  name = "opencode-launch";
  # util-linux provides setsid (needed to fully detach the auto-attach child
  # process from the launcher). Without it, callers with a restricted PATH
  # (systemd units, the pigeon worker) hit "setsid: command not found" and
  # the auto-attach trigger silently no-ops.
  runtimeInputs = [ pkgs.curl pkgs.jq pkgs.util-linux ];
  text = ''
      OPENCODE_URL="''${OPENCODE_URL:-http://127.0.0.1:4096}"

      # Pigeon daemon discovery endpoint. In a K-serve pool, opencode-serve
      # processes don't share an in-memory event bus, MCP connections, or active
      # agent loop, so a session's prompt + MCP tools must go to the serve that
      # OWNS (runs) it. After we create the session we ask pigeon's
      # GET /route?session_id which serve that is. Default matches the
      # oc-auto-attach convention.
      PIGEON_DAEMON_URL="''${PIGEON_DAEMON_URL:-http://127.0.0.1:4731}"

      # parse_serve_url <route-json-body> <fallback-url>
      #
      # Extract .apiBase from a pigeon `GET /route` JSON body and print it.
      # Falls back to <fallback-url> whenever the body is empty, not JSON, or
      # .apiBase is absent/null/empty. Pure (no network): the caller does the
      # curl and hands the body in. The fallback guarantees that any pigeon
      # hiccup degrades to the pre-pool single-serve behavior, never worse.
      parse_serve_url() {
        local body="$1" fallback="$2" api
        api="$(printf '%s' "$body" | jq -r '.apiBase // empty' 2>/dev/null || true)"
        if [ -n "$api" ] && [ "$api" != "null" ]; then
          printf '%s\n' "$api"
        else
          printf '%s\n' "$fallback"
        fi
      }

      # resolve_model_id <catalog-json> <provider> <model-id>
      #
      # Resolve a (possibly bare) model id against a GET /config/providers
      # catalog body. Prints one of:
      #   - the resolved, fully-qualified model id (exact match, or a unique
      #     bare -> @version expansion) on success
      #   - "__SKIP__"      catalog empty/unparseable or provider absent ->
      #                     caller proceeds with the id as-given (degrade)
      #   - "__NONE__"      provider known but no model matches
      #   - "__AMBIGUOUS__:a@x,a@y"  a bare id maps to several @versions
      # Pure (no network): the caller does the curl and hands the body in.
      # Kept in lockstep with pkgs/opencode-launch/test.sh by a source-grep
      # guard in that test.
      resolve_model_id() {
        local catalog="$1" provider="$2" model="$3"
        # Empty body (the common degrade path: /config/providers unreachable)
        # makes jq exit 0 with no output, not an error -- map it to __SKIP__.
        [ -n "$catalog" ] || { printf '__SKIP__\n'; return 0; }
        printf '%s' "$catalog" | jq -r --arg prov "$provider" --arg m "$model" '
          ([.providers[]? | select(.id == $prov)] | first) as $p
          | if $p == null then "__SKIP__"
            else ($p.models | keys) as $keys
              | if ($keys | index($m)) then $m
                else [ $keys[] | select((. | sub("@.*"; "")) == $m) ] as $c
                  | if   ($c | length) == 0 then "__NONE__"
                    elif ($c | length) == 1 then $c[0]
                    else "__AMBIGUOUS__:" + ($c | join(",")) end
                end
            end' 2>/dev/null || printf '__SKIP__\n'
      }

      usage() {
        local exit_code="''${1:-1}"
        echo "Usage: opencode-launch [--model provider/model] [--mcp server] [directory] <prompt>"
        echo ""
        echo "Launch a headless opencode session."
        echo ""
        echo "Options:"
        echo "  -h, --help                     Show this help message"
        echo "  --model <provider/model>       Specify the model to run"
        echo "  --mcp <server>                 Enable an MCP server's tools (repeatable)"
        echo "  --tmux-session <name>          Auto-attach in this tmux session (default: main)"
        echo ""
        echo "Favorite Models:"
        echo "  - google-vertex/gemini-3.5-flash                  (Fast, reasoning-enabled)"
        echo "  - google-vertex-anthropic/claude-opus-4-7@default      (High reasoning via Vertex gateway)"
        echo "  - anthropic/claude-opus-4-7                       (Direct Claude 4.7 Opus)"
        echo "  - openai/gpt-5.5                                  (GPT 5.5)"
        echo ""
        echo "Examples:"
        echo "  opencode-launch ~/projects/pigeon \"fix the test\""
        echo "  opencode-launch \"fix the test\"  # uses current directory"
        echo "  opencode-launch --model google-vertex/gemini-3.5-flash \"run pytest and fix any errors\""
        echo "  opencode-launch --model google-vertex-anthropic/claude-opus-4-7@default ~/projects/pigeon \"review the PR\""
        echo "  opencode-launch --mcp slack ~/projects/pigeon \"summarize #incidents today\""
        exit "$exit_code"
      }

      build_mcp_tools_json() {
        printf '%s\n' "$@" | jq -R -s -c '
          split("\n") | map(select(. != "")) | unique | map({(. + "_*"): true}) | add // {}'
      }

      model_spec=""
      mcp_servers=()
      # Default the auto-attach target to the user's primary `main` tmux
      # session so headless launches (no $TMUX) land deterministically there
      # instead of whatever session tmux considers "current". --tmux-session
      # <name> overrides for dedicated background sessions (e.g. lgtm).
      tmux_session="main"
      while [ $# -gt 0 ]; do
        case "$1" in
          --model)
            if [ $# -lt 2 ] || [ -z "$2" ]; then
              echo "Error: --model requires provider/model" >&2
              exit 1
            fi
            model_spec="$2"
            shift 2
            ;;
          --model=*)
            model_spec="''${1#--model=}"
            if [ -z "$model_spec" ]; then
              echo "Error: --model requires provider/model" >&2
              exit 1
            fi
            shift
            ;;
          --mcp)
            if [ $# -lt 2 ] || [ -z "$2" ]; then
              echo "Error: --mcp requires a server name" >&2
              exit 1
            fi
            mcp_servers+=("$2")
            shift 2
            ;;
          --mcp=*)
            mcp_server="''${1#--mcp=}"
            if [ -z "$mcp_server" ]; then
              echo "Error: --mcp requires a server name" >&2
              exit 1
            fi
            mcp_servers+=("$mcp_server")
            shift
            ;;
          --tmux-session)
            if [ $# -lt 2 ] || [ -z "$2" ]; then
              echo "Error: --tmux-session requires a name" >&2
              exit 1
            fi
            tmux_session="$2"
            shift 2
            ;;
          --tmux-session=*)
            tmux_session="''${1#--tmux-session=}"
            if [ -z "$tmux_session" ]; then
              echo "Error: --tmux-session requires a name" >&2
              exit 1
            fi
            shift
            ;;
          -h|--help)
            usage 0
            ;;
          --)
            shift
            break
            ;;
          -*)
            echo "Error: unknown option: $1" >&2
            usage
            ;;
          *)
            break
            ;;
        esac
      done

      if [ $# -eq 0 ]; then
        usage
      elif [ $# -eq 1 ]; then
        directory="$PWD"
        prompt="$1"
      else
        directory="$1"
        shift
        prompt="$*"
      fi

      # Resolve ~ to $HOME
      directory="''${directory/#\~/$HOME}"

      if [ -n "$model_spec" ]; then
        model_provider="''${model_spec%%/*}"
        model_rest="''${model_spec#*/}"
        if [ "$model_provider" = "$model_spec" ] || [ -z "$model_provider" ] || [ -z "$model_rest" ]; then
          echo "Error: --model must be provider/model" >&2
          exit 1
        fi

        model_id="$model_rest"
        if [ -z "$model_id" ]; then
          echo "Error: --model must be provider/model" >&2
          exit 1
        fi
      fi

      # Health check
      if ! curl -sf "$OPENCODE_URL/global/health" >/dev/null 2>&1; then
        echo "Error: opencode serve is not reachable at $OPENCODE_URL" >&2
        echo "Check: systemctl status opencode-serve (Linux) or launchctl list | grep opencode (macOS)" >&2
        exit 1
      fi

      # Resolve a (possibly bare) --model id against the serve's catalog BEFORE
      # creating a session. prompt_async is ASYNC: an unregistered model id
      # (e.g. "google-vertex-anthropic/claude-opus-4-8", missing the required
      # "@default" suffix) returns HTTP 200 below and only dies later in the
      # agent loop (Die(ProviderModelNotFoundError)) -- after we've already
      # printed "Session launched". That is the silently-dead, no-response
      # session the user otherwise has to notice and nudge. Resolving up front
      # turns it into either an auto-correction (unique bare -> @version) or a
      # loud pre-launch error. Catalog config is global (same across the pool),
      # so OPENCODE_URL is fine here, before /route. Any catalog/jq/provider
      # hiccup degrades to the id as-given -- never worse than before.
      if [ -n "$model_spec" ]; then
        providers_body="$(curl -sf --max-time 5 "$OPENCODE_URL/config/providers" 2>/dev/null || true)"
        resolved_model="$(resolve_model_id "$providers_body" "$model_provider" "$model_id")"
        case "$resolved_model" in
          __SKIP__)
            : # catalog unavailable or provider absent -> proceed unchanged
            ;;
          __NONE__)
            echo "Error: model '$model_provider/$model_id' is not in this serve's catalog." >&2
            echo "Available '$model_provider' models:" >&2
            printf '%s' "$providers_body" | jq -r --arg prov "$model_provider" \
              '.providers[]? | select(.id == $prov) | .models | keys[] | "  " + $prov + "/" + .' >&2 2>/dev/null || true
            exit 1
            ;;
          __AMBIGUOUS__:*)
            echo "Error: --model '$model_provider/$model_id' is ambiguous (missing @version suffix). Candidates:" >&2
            printf '%s' "$providers_body" | jq -r --arg prov "$model_provider" --arg m "$model_id" \
              '.providers[]? | select(.id == $prov) | .models | keys[] | select((. | sub("@.*"; "")) == $m) | "  " + $prov + "/" + .' >&2 2>/dev/null || true
            echo "Re-run --model with the fully-qualified id." >&2
            exit 1
            ;;
          *)
            if [ "$resolved_model" != "$model_id" ]; then
              echo "Note: --model '$model_provider/$model_id' resolved to '$model_provider/$resolved_model'" >&2
              model_id="$resolved_model"
            fi
            ;;
        esac
      fi

      # Create session
      session_response=$(curl -sf -X POST "$OPENCODE_URL/session" \
        -H "x-opencode-directory: $directory") || {
        echo "Error: failed to create session" >&2
        exit 1
      }

      session_id=$(echo "$session_response" | jq -r '.id')
      if [ -z "$session_id" ] || [ "$session_id" = "null" ]; then
        echo "Error: no session ID in response: $session_response" >&2
        exit 1
      fi

      # Resolve which serve in the pool OWNS this session. Placement is a pure
      # rendezvous hash of the sid, so this is stable regardless of which serve
      # created the row above. We send the MCP-connect + prompt to this owner
      # so the agent loop, its MCP tools, and the TUI (which also resolves via
      # /route) all land on the same serve. Any failure degrades to
      # $OPENCODE_URL (the serve we created on), i.e. pre-pool behavior.
      route_body="$(curl -sf --connect-timeout 2 --max-time 3 \
        "$PIGEON_DAEMON_URL/route?session_id=$session_id" 2>/dev/null || true)"
      serve_url="$(parse_serve_url "$route_body" "$OPENCODE_URL")"

      mcp_tools_json='{}'
      if [ "''${#mcp_servers[@]}" -gt 0 ]; then
        for srv in $(printf '%s\n' "''${mcp_servers[@]}" | sort -u); do
          connect_code=$(curl -s -o /dev/null -w '%{http_code}' \
            -X POST "$serve_url/mcp/$srv/connect" \
            -H "x-opencode-directory: $directory")
          if [ "$connect_code" = "404" ]; then
            echo "Error: MCP server '$srv' is not configured on this host" >&2
            exit 1
          elif [ "$connect_code" != "200" ]; then
            echo "Error: failed to connect MCP server '$srv' (HTTP $connect_code)" >&2
            exit 1
          fi
        done
        mcp_tools_json=$(build_mcp_tools_json "''${mcp_servers[@]}")
      fi

      if [ -n "$model_spec" ]; then
        prompt_payload=$(jq -n \
          --arg p "$prompt" \
          --arg provider "$model_provider" \
          --arg model "$model_id" \
          --argjson tools "$mcp_tools_json" \
          '{parts: [{type: "text", text: $p}], model: {providerID: $provider, modelID: $model}}
           + (if ($tools | length) > 0 then {tools: $tools} else {} end)')
      else
        prompt_payload=$(jq -n \
          --arg p "$prompt" \
          --argjson tools "$mcp_tools_json" \
          '{parts: [{type: "text", text: $p}]}
           + (if ($tools | length) > 0 then {tools: $tools} else {} end)')
      fi

      # Send prompt to the owning serve (where the agent loop will run)
      curl -sf -X POST "$serve_url/session/$session_id/prompt_async" \
        -H "x-opencode-directory: $directory" \
        -H "Content-Type: application/json" \
        -d "$prompt_payload" >/dev/null || {
        echo "Error: failed to send prompt to session $session_id" >&2
        exit 1
      }

      # Auto-attach to nvim+tmux if we're on a host with a graphical workflow.
      # Fully detached so the launch returns immediately and Ctrl+C on the
      # launcher can't signal the child. Missing oc-auto-attach (e.g. cloudbox
      # headless) is silently tolerated. Log to /tmp/oc-auto-attach.log for
      # debuggability.
      if command -v oc-auto-attach >/dev/null 2>&1; then
        oc_attach_args=()
        if [ -n "$tmux_session" ]; then
          oc_attach_args+=(--tmux-session "$tmux_session")
        fi
        # ''${arr[@]+"..."} guards the empty-array expansion under `set -u`.
        setsid nohup oc-auto-attach ''${oc_attach_args[@]+"''${oc_attach_args[@]}"} "$session_id" </dev/null >>/tmp/oc-auto-attach.log 2>&1 & disown
      fi

      echo "Session launched: $session_id"
      echo "Directory: $directory"
      echo ""
      echo "Attach:  opencode attach $serve_url --session $session_id"
      echo "Kill:    curl -sf -X DELETE $serve_url/session/$session_id"
    '';
}
