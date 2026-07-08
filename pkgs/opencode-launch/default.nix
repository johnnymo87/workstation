{ pkgs }:

pkgs.writeShellApplication {
  name = "opencode-launch";
  # util-linux provides setsid (needed to fully detach the auto-attach child
  # process from the launcher). Without it, callers with a restricted PATH
  # (systemd units, the pigeon worker) hit "setsid: command not found" and
  # the auto-attach trigger silently no-ops.
  # git + coreutils back the --worktree path: the cleanup_worktree trap shells
  # out to `git`, and the worktree block uses `tail`. They're usually on the
  # ambient PATH, but pinning them keeps --worktree working under a restricted
  # PATH too. (The `work` helper itself is our own package, discovered on PATH
  # with a loud `command -v` guard.)
  runtimeInputs = [ pkgs.curl pkgs.jq pkgs.util-linux pkgs.git pkgs.coreutils ];
  text = ''
      OPENCODE_URL="''${OPENCODE_URL:-http://127.0.0.1:4096}"

      # Pigeon daemon discovery endpoint. In a K-serve pool, opencode-serve
      # processes don't share an in-memory event bus, MCP connections, or active
      # agent loop, so a session's prompt + MCP tools must go to the serve that
      # OWNS (runs) it. After we create the session we ask pigeon's
      # GET /route?session_id which serve that is. Default matches the
      # oc-auto-attach convention.
      PIGEON_DAEMON_URL="''${PIGEON_DAEMON_URL:-http://127.0.0.1:4731}"

      # parse_serve_url <place-or-route-json-body> <fallback-url>
      #
      # Extract the owning serve's base URL from a pigeon routing JSON body and
      # print it. Accepts BOTH shapes: `POST /place` returns `.api_base`
      # (snake_case) and `GET /route` returns `.apiBase` (camelCase). Falls back
      # to <fallback-url> whenever the body is empty, not JSON, or the field is
      # absent/null/empty. Pure (no network): the caller does the curl and hands
      # the body in. The fallback guarantees that any pigeon hiccup degrades to
      # the pre-pool single-serve behavior, never worse.
      parse_serve_url() {
        local body="$1" fallback="$2" api
        api="$(printf '%s' "$body" | jq -r '.api_base // .apiBase // empty' 2>/dev/null || true)"
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
        echo "Usage: opencode-launch [--model provider/model] [--mcp server] [--worktree slug] [directory] <prompt>"
        echo ""
        echo "Launch a headless opencode session."
        echo ""
        echo "Options:"
        echo "  -h, --help                     Show this help message"
        echo "  --model <provider/model>       Specify the model to run"
        echo "  --mcp <server>                 Enable an MCP server's tools (repeatable)"
        echo "  --worktree <slug>              Land the session in a fresh 'work' worktree"
        echo "                                 under <directory> (a git repo) instead of at"
        echo "                                 its root. Use for WRITABLE sessions so the"
        echo "                                 read-only-main guard is bypassed by design."
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
      worktree_slug=""
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
          --worktree)
            if [ $# -lt 2 ] || [ -z "$2" ]; then
              echo "Error: --worktree requires a slug" >&2
              exit 1
            fi
            worktree_slug="$2"
            shift 2
            ;;
          --worktree=*)
            worktree_slug="''${1#--worktree=}"
            if [ -z "$worktree_slug" ]; then
              echo "Error: --worktree requires a slug" >&2
              exit 1
            fi
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

      # --worktree: land this (writable) session in a fresh worktree instead of
      # the passed directory, so its git toplevel != the enrolled mono root and
      # the read-only-main guard is bypassed BY CONSTRUCTION (Phase 3.5). Done
      # HERE -- after the health + model checks, JUST BEFORE session create
      # (design M1a) -- so (a) a launch destined to fail on a bad model / down
      # serve never manufactures a worktree, and (b) the window between
      # worktree-create and launch-success (guarded by the cleanup trap below)
      # is as small as possible. Everything downstream keys off $directory, so
      # reassigning it is all that's needed -- the session, pool placement, MCP
      # connects, and the auto-attached TUI all follow.
      # Design: docs/plans/2026-07-08-worktree-guard-phase35-launch-integration-design.md
      launch_ok=0
      created_wt_path=""
      created_wt_repo=""
      # cleanup_worktree (armed on EXIT, design M1b): if we created a worktree
      # but the launch did not reach success (launch_ok=1), remove the worktree
      # and its branch so a failed launch never orphans one. No-op when
      # --worktree was not used (created_wt_path stays empty) or on success.
      cleanup_worktree() {
        if [ "$launch_ok" -eq 1 ]; then return 0; fi
        [ -n "$created_wt_path" ] || return 0
        [ -d "$created_wt_path" ] || return 0
        echo "Cleaning up worktree after failed launch: $created_wt_path" >&2
        local br
        br="$(git -C "$created_wt_path" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
        git -C "$created_wt_repo" worktree remove --force "$created_wt_path" >/dev/null 2>&1 || true
        if [ -n "$br" ] && [ "$br" != "HEAD" ]; then
          git -C "$created_wt_repo" branch -D "$br" >/dev/null 2>&1 || true
        fi
      }
      trap cleanup_worktree EXIT

      if [ -n "$worktree_slug" ]; then
        if ! command -v work >/dev/null 2>&1; then
          echo "Error: --worktree requires the 'work' helper on PATH (pkgs/git-work)" >&2
          exit 1
        fi
        worktree_repo="$directory"
        # `work` derives the repo root from $PWD and prints the new worktree path
        # on stdout (its logs go to stderr); its fetch is bounded + best-effort so
        # this never blocks/dies on the network. On ANY work failure (not a repo,
        # slug taken, origin/HEAD unset) we abort the launch loudly rather than
        # silently launching writable work at the root -- that silent fallback is
        # the exact bug Phase 3.5 closes.
        if ! wt_path="$( cd "$worktree_repo" && work "$worktree_slug" )"; then
          echo "Error: failed to create worktree '$worktree_slug' in $worktree_repo" >&2
          exit 1
        fi
        wt_path="$(printf '%s' "$wt_path" | tail -n1)"
        if [ -z "$wt_path" ] || [ ! -d "$wt_path" ]; then
          echo "Error: worktree creation did not yield a directory (slug '$worktree_slug')" >&2
          exit 1
        fi
        created_wt_path="$wt_path"
        created_wt_repo="$worktree_repo"
        directory="$wt_path"
        echo "Worktree: $directory" >&2
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

      # PLACE this session on a pool serve (HRW) and resolve its owner. This is
      # the placement-at-create fix (workstation-iwpj): `GET /route` is read-only
      # and 404s for a never-placed session, so the old passive lookup always
      # fell back to the anchor and EVERY first turn ran on serve-0 (the other
      # serves idled). `POST /place` runs pigeon's ensureRouted
      # (resolveRoute ?? placeSession), which writes the session_assignment +
      # lease via the rendezvous hash and returns the owning serve. We must place
      # BEFORE the first prompt: placing after a turn starts bumps
      # owner_generation and kills the in-flight run. We then send the
      # MCP-connect + prompt to this owner so the agent loop, its MCP tools, and
      # the TUI (which resolves via /route) all land on the same serve. Any
      # failure (pigeon down, no healthy serve) degrades to $OPENCODE_URL (the
      # serve we created on), i.e. pre-pool single-serve behavior -- never worse.
      place_body="$(curl -sf --connect-timeout 2 --max-time 3 \
        -X POST "$PIGEON_DAEMON_URL/place" \
        -H "Content-Type: application/json" \
        -d "{\"session_id\":\"$session_id\"}" 2>/dev/null || true)"
      serve_url="$(parse_serve_url "$place_body" "$OPENCODE_URL")"

      # Base tools map always denies `question`: a headless launch has no
      # attended user to answer it, so any subagent (or the primary itself)
      # calling question would otherwise hang forever, as happened in a
      # 4-hour stuck-session incident. This is folded in unconditionally
      # (not just when --mcp is used) and merged with any MCP tool entries
      # below, so the resulting tools map is NEVER empty.
      mcp_tools_json='{"question": false}'
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
        mcp_tools_json=$(build_mcp_tools_json "''${mcp_servers[@]}" | jq -c '. + {"question": false}')
      fi

      # The tools map is always non-empty (it always carries "question":
      # false at minimum), so it's always attached -- no length check needed.
      if [ -n "$model_spec" ]; then
        prompt_payload=$(jq -n \
          --arg p "$prompt" \
          --arg provider "$model_provider" \
          --arg model "$model_id" \
          --argjson tools "$mcp_tools_json" \
          '{parts: [{type: "text", text: $p}], model: {providerID: $provider, modelID: $model}, tools: $tools}')
      else
        prompt_payload=$(jq -n \
          --arg p "$prompt" \
          --argjson tools "$mcp_tools_json" \
          '{parts: [{type: "text", text: $p}], tools: $tools}')
      fi

      # Send prompt to the owning serve (where the agent loop will run)
      curl -sf -X POST "$serve_url/session/$session_id/prompt_async" \
        -H "x-opencode-directory: $directory" \
        -H "Content-Type: application/json" \
        -d "$prompt_payload" >/dev/null || {
        echo "Error: failed to send prompt to session $session_id" >&2
        exit 1
      }

      # Launch succeeded: session created, placed, and the prompt delivered.
      # Disarm the worktree cleanup trap so a successful --worktree launch keeps
      # its worktree (the auto-attach below is best-effort and must not trigger
      # cleanup if it no-ops).
      launch_ok=1

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
