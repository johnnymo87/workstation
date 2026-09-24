{ pkgs
, opencode-serve-auth-sh ? pkgs.callPackage ../opencode-serve-auth-sh { }
, oc-tags ? pkgs.callPackage ../oc-tags { }
}:

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
  # oc-tags backs --tag. It is PINNED rather than probed-for at runtime the way
  # pigeon's daemon has to probe (its systemd unit has a minimal PATH): being a
  # derivation is exactly what lets us skip that, so --tag behaves the same from
  # an interactive shell and from a systemd unit with a stripped PATH. The cost
  # is a build-time edge opencode-launch -> oc-tags, which adds no new failure
  # surface: both are already in the same shared package list
  # (users/dev/home.base.nix), so an oc-tags build failure already blocks every
  # host's home-manager switch. oc-tags is one pure-Python file, stdlib only.
  # $OC_TAGS_BIN overrides the resolved binary -- an escape hatch for pointing
  # at a checkout or a stub, not something any deployed config sets.
  # (Note pigeon's Telegram /launch does NOT go through this script -- it calls
  # createSession over HTTP directly, see launch-ingest.ts -- so --tag is not
  # reachable from a phone. Pigeon's own /tag command covers that.)
  runtimeInputs = [ pkgs.curl pkgs.jq pkgs.util-linux pkgs.git pkgs.coreutils oc-tags ];
  text = ''
      # shellcheck disable=SC1091  # sourced from a nix store path shellcheck cannot follow
      source "${opencode-serve-auth-sh}"
      serve_auth_load

      OPENCODE_URL="''${OPENCODE_URL:-http://127.0.0.1:4096}"
      FRONTDOOR_URL="''${FRONTDOOR_URL:-http://127.0.0.1:4700}"

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

      # resolve_pigeon_auth
      #
      # Resolves pigeon bearer auth token at call time from PIGEON_DAEMON_AUTH_TOKEN
      # env var, or if unset/empty, from PIGEON_DAEMON_AUTH_TOKEN_FILE (defaulting to
      # /run/secrets/pigeon_daemon_auth_token). Populates caller-scoped `pigeon_auth`
      # array with `-H "Authorization: Bearer <token>"` if non-empty, else empty array.
      resolve_pigeon_auth() {
        local token="''${PIGEON_DAEMON_AUTH_TOKEN:-}"
        token="$(printf '%s' "$token" | tr -d '[:space:]')"
        if [ -z "$token" ]; then
          local token_file="''${PIGEON_DAEMON_AUTH_TOKEN_FILE:-/run/secrets/pigeon_daemon_auth_token}"
          if [ -r "$token_file" ]; then
            token="$(cat "$token_file" 2>/dev/null || true)"
            token="$(printf '%s' "$token" | tr -d '[:space:]')"
          fi
        fi
        pigeon_auth=()
        if [ -n "$token" ]; then
          pigeon_auth=(-H "Authorization: Bearer $token")
        fi
      }

      # record_launch_prompt
      #
      # Tell the pigeon daemon "I am about to inject this exact text into this
      # session", so its /mirror route does not echo the launch prompt back into
      # Telegram as `🧑 <label> <prompt>` -- which reads as though a human typed
      # it. The daemon records sha256(text) in its injected_prompts table and
      # consumes one count the next time an identical user message arrives for
      # that session (pigeon-w36w).
      #
      # Reads caller-scoped `pigeon_auth`, so this MUST be called after
      # resolve_pigeon_auth. Under `set -u` an unset array expands to nothing
      # rather than erroring, so calling it too early would silently drop the
      # Authorization header and 401 -- which is why the call sites sit next to
      # prompt_async, well below the resolve_pigeon_auth at session-create time.
      #
      # We send the RAW TEXT and let the daemon hash it. Hashing here would mean
      # reproducing sha256 byte-for-byte from bash (printf-vs-echo trailing
      # newline, locale, jq's UTF-8 sanitisation), and a mismatch fails SILENTLY:
      # the prompt just echoes, with nothing anywhere saying why. Passing the
      # same "$prompt" string that goes into prompt_payload keeps one source of
      # truth for the bytes.
      #
      # Best-effort -- it must never fail a launch -- but deliberately NOT mute.
      # A 404 (daemon predates the route: the two repos deploy independently,
      # per machine), a 401 (token file unreadable) or a 400 (payload bug) are
      # real misconfigurations that are otherwise indistinguishable from success.
      # Only a connection failure (code 000, daemon down) is the designed
      # degrade, and only that stays quiet.
      record_launch_prompt() {
        local code
        code="$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 2 --max-time 3 \
          ''${pigeon_auth[@]+"''${pigeon_auth[@]}"} \
          -X POST "$PIGEON_DAEMON_URL/injected-prompts" \
          -H "Content-Type: application/json" \
          -d "$(jq -n --arg s "$session_id" --arg t "$prompt" '{sessionId: $s, text: $t}')" \
          2>/dev/null || true)"
        case "$code" in
          200) ;;
          000|"") ;;
          *) echo "Note: pigeon launch-prompt record returned HTTP $code; the launch prompt may echo into Telegram" >&2 ;;
        esac
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

      # validate_tag <tag>
      #
      # Accept a manual oc-tags tag; reject anything unsafe or meaningless as an
      # argv element handed to `oc-tags set`. Rules match pigeon's already-shipped
      # isValidTag (packages/worker/src/tag-command.ts,
      # packages/daemon/src/worker/tag-ingest.ts):
      #   - first character alphanumeric. That is what rules out the REAL hazard,
      #     argument injection: a tag starting with '-' would be read as a
      #     flag. Shell metacharacters are NOT the hazard -- we always pass
      #     argv, never build a command string.
      #   - remaining characters from [A-Za-z0-9._:/-], 64 characters max.
      #   - no "auto:" prefix (case-insensitive). oc-tags reserves that for its
      #     directory-derived fallback and rejects it at write time anyway, but
      #     failing HERE, before a session exists, beats a confusing failure
      #     after one is already live.
      # Kept in lockstep with pkgs/opencode-launch/test.sh by a source-grep guard
      # in that test.
      #
      # LC_ALL=C is load-bearing, not hygiene. Under the ambient en_US.UTF-8 the
      # bracket expression [A-Za-z0-9] matches accented letters, so `--tag épic`
      # would pass here, pass oc-tags' normalise_tag, and land in tags.db --
      # while pigeon's JS TAG_RE rejects the identical string. Two validators,
      # two answers, and a --help text that promises "letters, digits" and means
      # it only under one locale.
      validate_tag() {
        local t="$1"
        local LC_ALL=C
        [[ "$t" =~ ^[A-Za-z0-9][A-Za-z0-9._:/-]{0,63}$ ]] || return 1
        case "$(printf '%s' "$t" | tr '[:upper:]' '[:lower:]')" in
          auto:*) return 1 ;;
        esac
        return 0
      }

      # apply_session_tag
      #
      # Convert the freshly launched session from its directory-derived "auto:"
      # tag to the manual $tag. Reads caller-scoped $tag and $session_id.
      #
      # STRICTLY best-effort and deliberately LAST: the launch is the point, the
      # tag is bookkeeping. Losing a launch (or delaying its prompt) to a tag DB
      # write would be a strictly worse trade, so every failure path warns on
      # stderr and returns 0, and the whole call is bounded by `timeout`.
      #
      # Applying after the prompt costs nothing, because oc-tags attribution is
      # RETROACTIVE: report/top join opencode.db's cost rows against tags.db at
      # read time, so a tag written a second after the session started still
      # covers every dollar that session ever spends. There is no race to win by
      # tagging earlier -- only a launch to risk.
      #
      # Note the argv order: oc-tags takes the TAG first and the session id
      # second (cmd_set/build_parser in pkgs/oc-tags/oc_tags.py). Reversed, it
      # would happily tag the session "ses_..." and say so. `--` guards the
      # positional boundary even though validate_tag already rejects a leading
      # "-". oc-tags resolves the id to its ROOT session, which for a
      # just-created session is itself.
      #
      # Optional $1 is a suffix appended to oc-tags' success line, used by
      # inherit_launcher_tag to say where an inherited tag came from. It is
      # printed only on success, so a failed set never claims an inheritance.
      apply_session_tag() {
        local bin="''${OC_TAGS_BIN:-oc-tags}" suffix="''${1:-}" out rc=0 reason
        if ! command -v "$bin" >/dev/null 2>&1; then
          echo "Note: tag '$tag' not applied: '$bin' not found on PATH (session $session_id keeps its auto: tag)" >&2
          return 0
        fi
        out="$(timeout 10 "$bin" set -- "$tag" "$session_id" 2>&1)" || rc=$?
        if [ "$rc" -ne 0 ]; then
          # Report a REASON, not a dump. The two likeliest failures both hide
          # behind the naive `$out`: a `timeout` kill (rc 124) prints nothing at
          # all, and a locked tags.db (~15 concurrent sessions on this host)
          # prints a 20-line Python traceback whose only useful line is the last.
          if [ "$rc" -eq 124 ]; then
            reason="timed out after 10s"
          else
            reason="$(printf '%s' "$out" | tail -n1)"
            [ -n "$reason" ] || reason="exit $rc, no output"
          fi
          echo "Note: tag '$tag' not applied to $session_id: $reason" >&2
          echo "      Apply it by hand with: oc-tags set $tag $session_id" >&2
          return 0
        fi
        # Print oc-tags' OWN line rather than echoing back "$tag". oc-tags
        # lowercases via normalise_tag, so "--tag Billing-Job" is stored (and
        # charted) as "billing-job"; a self-reported "Tag: Billing-Job"
        # would name something the chart never shows.
        printf '%s%s\n' "$out" "$suffix"
        return 0
      }

      # is_inherit_optout <tag-arg>
      #
      # `--tag auto` (any case, exactly "auto") means "do not inherit the
      # launcher's tag; leave this session on its auto: fallback". It is
      # checked BEFORE validate_tag, which still rejects "auto:<anything>":
      # the bare word is an instruction, the prefix is oc-tags' namespace.
      is_inherit_optout() {
        [ "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" = "auto" ]
      }

      # inherit_launcher_tag
      #
      # A session launched BY a session (swarm workers, follow-ups) inherits
      # the launcher's tag, so it lands on its program's line on the chart
      # instead of an auto: fallback someone has to fix by hand later.
      # Design: docs/plans/2026-09-23-launch-tag-inheritance-design.md.
      #
      # The launcher is $OPENCODE_SESSION_ID. Only an EXPLICIT session tag is
      # inherited (`oc-tags which` column 4 == "session"): an auto: fallback
      # is not a tag anyone chose. Inheritance is a COPY -- a normal `oc-tags
      # set` -- so retagging the launcher later does not touch its children.
      #
      # Same contract as apply_session_tag, and runs at the same point (after
      # the prompt): best-effort, time-bounded, returns 0 on every path. A
      # missing binary, a non-zero exit, a timeout, an old 3-column oc-tags
      # or a tag that fails validate_tag each print a Note on stderr and leave
      # the child on auto:. kind dir/auto is the normal "nothing to inherit"
      # case and is silent. Success is LOUD: oc-tags' own line plus
      # "(inherited from <root>)", so a wrong inheritance is visible.
      #
      # Reads $OPENCODE_SESSION_ID and $session_id; sets caller-scoped $tag.
      # stderr of `which` is discarded: on success it may carry a benign
      # "opencode.db unreadable" warning, and on failure the exit code is the
      # reason. `--` keeps a hostile id from being read as a flag.
      inherit_launcher_tag() {
        local bin="''${OC_TAGS_BIN:-oc-tags}" launcher="''${OPENCODE_SESSION_ID:-}"
        local secs="''${OPENCODE_LAUNCH_TAG_WHICH_TIMEOUT:-4}"
        local out rc=0 reason line w_tag="" w_root="" w_kind=""
        [ -n "$launcher" ] || return 0
        if ! command -v "$bin" >/dev/null 2>&1; then
          echo "Note: tag not inherited from $launcher: '$bin' not found on PATH (session $session_id keeps its auto: tag)" >&2
          return 0
        fi
        out="$(timeout "$secs" "$bin" which -- "$launcher" 2>/dev/null)" || rc=$?
        if [ "$rc" -ne 0 ]; then
          if [ "$rc" -eq 124 ]; then
            reason="timed out after ''${secs}s"
          else
            reason="exit $rc"
          fi
          echo "Note: tag not inherited from $launcher: 'oc-tags which' failed ($reason); session $session_id keeps its auto: tag" >&2
          return 0
        fi
        line="''${out%%$'\n'*}"
        IFS=$'\t' read -r w_tag _ w_root w_kind _ <<<"$line" || true
        if [ -z "$w_kind" ]; then
          # An oc-tags older than the kind column prints 3 fields. It cannot
          # tell a session tag from an auto: fallback, so do not guess.
          echo "Note: tag not inherited from $launcher: 'oc-tags which' printed no kind column (oc-tags older than this launcher?)" >&2
          return 0
        fi
        case "$w_kind" in
          session) ;;
          dir|auto) return 0 ;;
          *)
            echo "Note: tag not inherited from $launcher: unknown tag kind '$w_kind'" >&2
            return 0
            ;;
        esac
        if ! validate_tag "$w_tag"; then
          echo "Note: tag not inherited from $launcher: its tag '$w_tag' is not a valid launch tag; session $session_id keeps its auto: tag" >&2
          return 0
        fi
        [ -n "$w_root" ] || w_root="$launcher"
        tag="$w_tag"
        apply_session_tag " (inherited from $w_root)"
      }

      usage() {
        local exit_code="''${1:-1}"
        echo "Usage: opencode-launch [--model provider/model] [--mcp server] [--worktree slug] [--tag tag] [directory] <prompt>"
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
        echo "  --tag <tag>                    Tag the session for oc-tags cost reporting."
        echo "                                 Every session ALWAYS has a tag, so this does"
        echo "                                 not create one from nothing -- it OVERRIDES the"
        echo "                                 directory-derived 'auto:' fallback with what"
        echo "                                 this session was launched to DO."
        echo "                                 Worth it most at a repo ROOT, where the"
        echo "                                 directory says nothing (auto:mono covers"
        echo "                                 unrelated work). With --worktree you already"
        echo "                                 get auto:<repo>/<slug>, which is often enough;"
        echo "                                 --tag earns its keep there when several"
        echo "                                 worktrees are one project and should add up to"
        echo "                                 a single line on the chart."
        echo "                                 Applied after the launch succeeds and never"
        echo "                                 fails it; tag attribution is retroactive."
        echo "                                 Without --tag, a launch from inside a session"
        echo "                                 (\$OPENCODE_SESSION_ID set) INHERITS that"
        echo "                                 session's tag -- but only an explicit session"
        echo "                                 tag, never an auto: fallback. The"
        echo "                                 inherited tag is printed with its source."
        echo "  --tag auto                     Do not inherit; keep the auto: fallback."
        echo "  --tmux-session <name>          Auto-attach in this tmux session (default: main)"
        echo "  --no-attach                    Do not open an attach TUI for this session."
        echo "                                 For automation that never reads one: each TUI"
        echo "                                 costs ~240 MB in an uncapped tmux scope and is"
        echo "                                 not reaped when the session ends. Also settable"
        echo "                                 as OPENCODE_LAUNCH_NO_ATTACH=1."
        echo ""
        echo "Favorite Models:"
        echo "  - google-vertex/gemini-3.8-flash                  (Fast, reasoning-enabled)"
        echo "  - google-vertex-anthropic/claude-opus-4-7@default      (High reasoning via Vertex gateway)"
        echo "  - anthropic/claude-opus-4-7                       (Direct Claude 4.7 Opus)"
        echo "  - openai/gpt-5.5                                  (GPT 5.5)"
        echo ""
        echo "Examples:"
        echo "  opencode-launch ~/projects/pigeon \"fix the test\""
        echo "  opencode-launch \"fix the test\"  # uses current directory"
        echo "  opencode-launch --model google-vertex/gemini-3.8-flash \"run pytest and fix any errors\""
        echo "  opencode-launch --model google-vertex-anthropic/claude-opus-4-7@default ~/projects/pigeon \"review the PR\""
        echo "  opencode-launch --mcp slack ~/projects/pigeon \"summarize #incidents today\""
        echo "  opencode-launch --tag billing-job ~/projects/mono \"port the last two callers\""
        exit "$exit_code"
      }

      build_mcp_tools_json() {
        printf '%s\n' "$@" | jq -R -s -c '
          split("\n") | map(select(. != "")) | unique | map({(. + "_*"): true}) | add // {}'
      }

      model_spec=""
      worktree_slug=""
      tag=""
      no_inherit=0
      mcp_servers=()
      # Default the auto-attach target to the user's primary `main` tmux
      # session so headless launches (no $TMUX) land deterministically there
      # instead of whatever session tmux considers "current". --tmux-session
      # <name> overrides for dedicated background sessions (e.g. lgtm).
      tmux_session="main"
      no_attach=0
      while [ $# -gt 0 ]; do
        case "$1" in
          --no-attach)
            no_attach=1
            shift
            ;;
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
          --tag)
            if [ $# -lt 2 ] || [ -z "$2" ]; then
              echo "Error: --tag requires a tag" >&2
              exit 1
            fi
            tag="$2"
            shift 2
            ;;
          --tag=*)
            tag="''${1#--tag=}"
            if [ -z "$tag" ]; then
              echo "Error: --tag requires a tag" >&2
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

      # `--tag auto` is the inheritance opt-out, not a tag: consume it here,
      # before validate_tag (which rejects auto:* and would reject nothing
      # useful about the bare word).
      if [ -n "$tag" ] && is_inherit_optout "$tag"; then
        no_inherit=1
        tag=""
      fi

      # Validate --tag up front -- before the health check, the session, and any
      # worktree. A typo must cost nothing; a tag rejected after a session exists
      # would leave a live session and a confusing oc-tags error.
      if [ -n "$tag" ]; then
        if ! validate_tag "$tag"; then
          echo "Error: invalid --tag '$tag'" >&2
          echo "A tag must start with a letter or digit and use only letters, digits, . _ : / - (64 chars max)." >&2
          echo "'auto:' is reserved for oc-tags' directory-derived fallback and cannot be set by hand." >&2
          exit 1
        fi
      fi

      # Health check
      if ! curl -sf "$FRONTDOOR_URL/global/health" >/dev/null 2>&1; then
        echo "Error: front door is unreachable at $FRONTDOOR_URL" >&2
        echo "Check: systemctl status opencode-frontdoor (the door) and opencode-serve-pool.target (the backends)" >&2
        exit 1
      fi

      # Resolve a (possibly bare) --model id against the serve's catalog BEFORE
      # creating a session. prompt_async is ASYNC: an unregistered model id
      # (e.g. "google-vertex-anthropic/claude-opus-5", missing the required
      # "@default" suffix) returns HTTP 200 below and only dies later in the
      # agent loop (Die(ProviderModelNotFoundError)) -- after we've already
      # printed "Session launched". That is the silently-dead, no-response
      # session the user otherwise has to notice and nudge. Resolving up front
      # turns it into either an auto-correction (unique bare -> @version) or a
      # loud pre-launch error. Catalog config is global (same across the pool),
      # so FRONTDOOR_URL is fine here, before /route. Any catalog/jq/provider
      # hiccup degrades to the id as-given -- never worse than before.
      if [ -n "$model_spec" ]; then
        providers_body="$(curl -sf --max-time 5 "$FRONTDOOR_URL/config/providers" 2>/dev/null || true)"
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
      session_response=$(curl -sf -X POST "$FRONTDOOR_URL/session" \
        -H "x-opencode-directory: $directory") || {
        echo "Error: failed to create session" >&2
        exit 1
      }

      session_id=$(echo "$session_response" | jq -r '.id')
      if [ -z "$session_id" ] || [ "$session_id" = "null" ]; then
        echo "Error: no session ID in response: $session_response" >&2
        exit 1
      fi

      # DISCOVER the owning serve for this session via a read-only lookup.
      # Phase 9 (2026-07-26) narrowed why this is still here. MCP connect and the
      # attach hint BOTH ride the front door now, so `serve_url` survives for
      # exactly ONE purpose: the `prompt_async` retry below, which fires only
      # after the door path has already failed. That is an `exempt-degrade` row
      # in docs/plans/2026-07-26-phase9-consumer-disposition.md (C7), not a
      # data-plane path. Any pigeon hiccup degrades it to `$OPENCODE_URL` (the
      # serve we created on) -- pre-pool single-serve behavior, never worse.
      resolve_pigeon_auth
      route_body="$(curl -sf --connect-timeout 2 --max-time 3 ''${pigeon_auth[@]+"''${pigeon_auth[@]}"} "$PIGEON_DAEMON_URL/route?session_id=$session_id" 2>/dev/null || true)"
      serve_url="$(parse_serve_url "$route_body" "$OPENCODE_URL")"

      # Base tools map always denies `question`: a headless launch has no
      # attended user to answer it, so any subagent (or the primary itself)
      # calling question would otherwise hang forever, as happened in a
      # 4-hour stuck-session incident. This is folded in unconditionally
      # (not just when --mcp is used) and merged with any MCP tool entries
      # below, so the resulting tools map is NEVER empty.
      mcp_tools_json='{"question": false}'
      if [ "''${#mcp_servers[@]}" -gt 0 ]; then
        for srv in $(printf '%s\n' "''${mcp_servers[@]}" | sort -u); do
          # Through the door, session-scoped. The old comment here claimed "the
          # front door denies MCP connect with 405 (it is per-serve state)" and
          # went direct to $serve_url. That was stale three ways: Phase 10 added
          # POST /session/{sessionID}/mcp/{name}/connect (class `session-path`,
          # routes.classification.ts:216), the TUI itself migrated to it, and the
          # bare route's denial is 403 not 405. We hold $session_id here, so the
          # session-scoped route is available and the door picks the owner.
          # Error semantics are preserved exactly: verified 2026-07-26 that a
          # missing server returns byte-identical 404 McpServerNotFoundError
          # through the door and direct to a serve.
          connect_code=$(curl -s -o /dev/null -w '%{http_code}' \
            --max-time 20 \
            -X POST "$FRONTDOOR_URL/session/$session_id/mcp/$srv/connect" \
            -H "x-opencode-directory: $directory")
          # Degrade, mirroring the prompt_async retry below. Without this, a pigeon
          # outage HARD-KILLS every --mcp launch: create can't place -> no sticky ->
          # the door sees a mutating request it refuses to send to a non-owner and
          # returns FABLE-S2 503 (proxy.ts:741-745) -> the `!= 200` branch exits 1.
          # The pre-Phase-9 code went direct to $serve_url and survived, so routing
          # this through the door without a degrade was a REGRESSION (found by
          # adversarial review after deploy, 2026-07-26). The prompt_async retry
          # below cannot cover it -- we exit before ever reaching it.
          # 503 specifically means "pigeon unavailable, refusing to guess an owner",
          # which is exactly when $serve_url's raw-anchor fallback is the right
          # target: a create-degraded session actually lives on the anchor.
          if [ "$connect_code" = "503" ]; then
            echo "Note: MCP connect via front door got 503 (pigeon down); retrying direct against $serve_url" >&2
            # frontdoor-exempt(C8): fires ONLY on a door 503 (pigeon down); without it every --mcp launch dies at connect
            connect_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
              ''${SERVE_AUTH_CURL_ARGS[@]+"''${SERVE_AUTH_CURL_ARGS[@]}"} \
              -X POST "$serve_url/mcp/$srv/connect" \
              -H "x-opencode-directory: $directory")
          fi
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

      # Send prompt to the front door (which routes to the owning serve where the agent loop will run).
      # Degrade (fable M2 #2): if the door rejects the prompt — notably a FABLE-S2 503 during a
      # full pigeon outage, when this session was create-degraded onto the anchor and never got a
      # lease — retry ONCE directly against $serve_url. serve_url was resolved via GET /route above:
      # a real owner when pigeon is up, or the $OPENCODE_URL anchor (= where a create-degraded
      # session actually lives) when pigeon is down. This restores the pre-pool "launch survives a
      # pigeon blip" behavior instead of hard-failing and orphaning the session.
      # --max-time is load-bearing on BOTH legs: a wedged serve otherwise parks the
      # launcher indefinitely (reset-workspace documents a curl parked 6+ hours on
      # this exact failure). The retry leg needs it most -- it targets a serve that
      # just failed through the door, i.e. the one most likely to be wedged.
      # Record BEFORE the injection, never after its response (pigeon-w36w).
      # prompt_async is non-idempotent and a --max-time 30 timeout may mean the
      # prompt WAS processed, so a record placed after the response would lose
      # the race to the very mirror event it exists to suppress.
      record_launch_prompt
      if ! curl -sf --max-time 30 -X POST "$FRONTDOOR_URL/session/$session_id/prompt_async" \
        -H "x-opencode-directory: $directory" \
        -H "Content-Type: application/json" \
        -d "$prompt_payload" >/dev/null; then
        echo "Note: prompt via front door failed; retrying directly against $serve_url" >&2
        # Record again before the SECOND injection, matching the daemon's own
        # rule that every injection gets its own count (injected_prompts is
        # counted, not single-use, precisely because retry-after-timeout
        # produces byte-identical re-injections). The door leg can time out
        # having actually been processed, in which case both legs land and two
        # counts are exactly right. If the door leg truly failed unprocessed we
        # strand one count instead: it suppresses at most one identical human
        # prompt in the same session within the 15-minute TTL, costing a single
        # 🧑 mirror line. Erring the other way costs a spurious echo of a
        # multi-KB launch prompt on every retry.
        record_launch_prompt
        # frontdoor-exempt(C7): post-door-failure degrade ONLY; fires after the FRONTDOOR_URL prompt above fails
        curl -sf --max-time 30 \
          ''${SERVE_AUTH_CURL_ARGS[@]+"''${SERVE_AUTH_CURL_ARGS[@]}"} \
          -X POST "$serve_url/session/$session_id/prompt_async" \
          -H "x-opencode-directory: $directory" \
          -H "Content-Type: application/json" \
          -d "$prompt_payload" >/dev/null || {
          echo "Error: failed to send prompt to session $session_id" >&2
          exit 1
        }
      fi

      # Launch succeeded: session created, placed, and the prompt delivered.
      # Disarm the worktree cleanup trap so a successful --worktree launch keeps
      # its worktree (the auto-attach below is best-effort and must not trigger
      # cleanup if it no-ops).
      launch_ok=1

      # should_auto_attach <no_attach_flag> <env_value> -> 0 = attach, 1 = skip.
      #
      # The env var exists so a wrapper or a systemd Environment= line can opt
      # out without touching the callee's argv. It is NOT because any caller is
      # unable to pass the flag -- an earlier version of this comment claimed
      # lgtm-run launches from the pigeon daemon and could not change its argv,
      # and both halves were false: lgtm-run is a systemd unit in this repo
      # (hosts/cloudbox/configuration.nix) and its argv is built by plain arrays
      # in lgtm/src/{dispatch,gather}.ts. Passing --no-attach there is the
      # cheaper fix and does not wait on a nixos-rebuild.
      #
      # Truthiness is an ALLOWLIST, not `[ -n "$VAR" ]`. A bare non-empty test
      # would make OPENCODE_LAUNCH_NO_ATTACH=0 disable attaching for every
      # launch on the box, which is the opposite of what anyone writing that
      # would mean. Mirrored in test.sh; the grep below keeps them in lockstep.
      should_auto_attach() {
        local flag="$1" env="''${2:-}"
        [ "$flag" = "1" ] && return 1
        case "$env" in
          1|true|TRUE|yes|YES|on|ON) return 1 ;;
        esac
        return 0
      }

      # Auto-attach to nvim+tmux if we're on a host with a graphical workflow.
      # Detached from the launcher's SHELL SESSION so the launch returns
      # immediately and Ctrl+C on the launcher can't signal the child.
      #
      # `setsid nohup` is deliberately sufficient here and no cgroup escape is
      # needed: oc-auto-attach is short-lived (it hands the session to tmux/nvim
      # and exits) and restarts no unit, so it never has to outlive a
      # `systemctl restart` of a cgroup it lives in. Do NOT copy this shape for
      # a job that restarts its own unit -- setsid/nohup do not leave the
      # cgroup, and such a job is killed mid-flight (bead workstation-4qvx; see
      # "Backgrounding Long-Running Processes" in assets/opencode/AGENTS.md and
      # the systemd-run re-exec in pkgs/reset-workspace/default.nix).
      #
      # Missing oc-auto-attach is silently tolerated. NOTE this is not the
      # cloudbox case, whatever the skill doc used to say: oc-auto-attach IS
      # installed there, and 108 attach TUIs were live on 2026-09-18.
      # Log to /tmp/oc-auto-attach.log for debuggability.
      #
      # `env -u OPENCODE_SESSION_ID` scrubs the LAUNCHER's session id. When
      # the launcher is an agent session, that id is in our env, and if this
      # attach is the one that (re)starts the tmux server -- the first attach
      # after a tmux server restart -- tmux captures it into its GLOBAL
      # environment. Every later pane then inherits a dead session's id, and a
      # human `opencode-launch` (or bare `oc-tags set`) from those panes would
      # silently inherit the wrong tag. The attach itself never needs it.
      # ''${arr[@]+"..."} guards the empty-array expansion under `set -u`.
      spawn_auto_attach() {
        setsid nohup env -u OPENCODE_SESSION_ID oc-auto-attach ''${oc_attach_args[@]+"''${oc_attach_args[@]}"} "$session_id" </dev/null >>/tmp/oc-auto-attach.log 2>&1 & disown
      }
      if ! should_auto_attach "$no_attach" "''${OPENCODE_LAUNCH_NO_ATTACH:-}"; then
        # Name WHICH one fired. A leaked env var would otherwise send whoever
        # is wondering where their pane went looking through argv.
        if [ "$no_attach" = "1" ]; then
          echo "Auto-attach: skipped (--no-attach)" >&2
        else
          echo "Auto-attach: skipped (OPENCODE_LAUNCH_NO_ATTACH=''${OPENCODE_LAUNCH_NO_ATTACH:-})" >&2
        fi
      elif command -v oc-auto-attach >/dev/null 2>&1; then
        oc_attach_args=()
        if [ -n "$tmux_session" ]; then
          oc_attach_args+=(--tmux-session "$tmux_session")
        fi
        spawn_auto_attach
      fi

      echo "Session launched: $session_id"
      echo "Directory: $directory"
      # tag_launched_session: an explicit --tag wins and no lookup is done;
      # otherwise, unless `--tag auto` opted out, inherit the launcher's
      # explicit session tag. Defined here, beside its only call, and after
      # launch_ok=1 on purpose (the source guards in test.sh pin that order).
      tag_launched_session() {
        if [ -n "$tag" ]; then
          apply_session_tag
        elif [ "$no_inherit" != "1" ] && [ -n "''${OPENCODE_SESSION_ID:-}" ]; then
          inherit_launcher_tag
        fi
        return 0
      }
      # LAST, and after the auto-attach hand-off above, so nothing about the
      # launch waits on a sqlite write. apply_session_tag prints oc-tags' own
      # confirmation on success and warns without failing otherwise.
      tag_launched_session
      echo ""
      # Attach hint rides the door, matching what oc-pool-attach/oc-auto-attach
      # actually do. Printing $serve_url here taught the human the pool's
      # internals and handed them a URL that breaks the moment the session
      # migrates to another serve.
      echo "Attach:  opencode attach $FRONTDOOR_URL --session $session_id"
      echo "Kill:    curl -sf -X DELETE $FRONTDOOR_URL/session/$session_id"
    '';
}
