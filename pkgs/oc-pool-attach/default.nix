{ pkgs, opencode, k }:

pkgs.writeShellApplication {
  name = "oc-pool-attach";
  runtimeInputs = [ pkgs.curl pkgs.jq pkgs.gnugrep pkgs.coreutils ];
  text = ''
    classify_oc_invocation() {
      local subcmds="completion acp mcp attach run debug providers auth agent upgrade uninstall serve web models stats export import github pr session plugin plug db"
      local sid="" project="" have_session=0 positionals=0 first_pos_checked=0 a
      while [ $# -gt 0 ]; do
        a="$1"
        case "$a" in
          --) printf 'PASSTHROUGH\t\t\n'; return 0 ;;
          -s|--session)
            shift
            if [ $# -eq 0 ] || [ -z "$1" ] || [ "$have_session" -eq 1 ]; then printf 'PASSTHROUGH\t\t\n'; return 0; fi
            sid="$1"; have_session=1; shift ;;
          --session=*)
            if [ "$have_session" -eq 1 ]; then printf 'PASSTHROUGH\t\t\n'; return 0; fi
            sid="''${a#--session=}"; have_session=1; shift ;;
          -s*)
            if [ "$have_session" -eq 1 ]; then printf 'PASSTHROUGH\t\t\n'; return 0; fi
            sid="''${a#-s}"; have_session=1; shift ;;
          --model|-m|--agent|--prompt|--port|--hostname|--mdns|--cors|-c|--continue|--fork|--pure|-h|--help|-v|--version|--print-logs|--log-level) printf 'PASSTHROUGH\t\t\n'; return 0 ;;
          --model=*|--agent=*|--prompt=*|--port=*|--hostname=*|--cors=*|--log-level=*|--mdns=*) printf 'PASSTHROUGH\t\t\n'; return 0 ;;
          -*) printf 'PASSTHROUGH\t\t\n'; return 0 ;;
          *)
            if [ "$first_pos_checked" -eq 0 ]; then
              first_pos_checked=1
              for sc in $subcmds; do [ "$a" = "$sc" ] && { printf 'PASSTHROUGH\t\t\n'; return 0; }; done
            fi
            positionals=$((positionals+1)); project="$a"; shift ;;
        esac
      done
      [ "$positionals" -gt 1 ] && { printf 'PASSTHROUGH\t\t\n'; return 0; }
      if [ "$have_session" -eq 1 ]; then
        printf '%s' "$sid" | grep -Eq '^ses_[A-Za-z0-9_-]+$' || { printf 'PASSTHROUGH\t\t\n'; return 0; }
        printf 'RESUME\t%s\t%s\n' "$sid" "$project"; return 0
      fi
      printf 'NEW\t\t%s\n' "$project"; return 0
    }

    parse_serve_url() {
      local body="$1" fallback="$2" api
      api="$(printf '%s' "$body" | jq -r '.api_base // .apiBase // empty' 2>/dev/null || true)"
      if [ -n "$api" ] && [ "$api" != "null" ]; then
        printf '%s\n' "$api"
      else
        printf '%s\n' "$fallback"
      fi
    }

    # split_classification <classify-output>: split the TAB-delimited
    # "verb<TAB>sid<TAB>project" line from classify_oc_invocation into the
    # verb/sid/project globals. Hand-rolled instead of `read -r` because `read`
    # with IFS=$'\t' collapses consecutive tabs (tab is IFS-whitespace), which
    # would silently drop <project> from a "NEW<TAB><TAB><project>" line and make
    # `opencode <project>` open $PWD instead. Parameter expansion keeps empties.
    split_classification() {
      local c="$1"
      verb="''${c%%$'\t'*}"
      c="''${c#*$'\t'}"
      sid="''${c%%$'\t'*}"
      project="''${c#*$'\t'}"
    }

    OPENCODE_URL="''${OPENCODE_URL:-http://127.0.0.1:4096}"
    FRONTDOOR_URL="''${FRONTDOOR_URL:-http://127.0.0.1:4700}"
    PIGEON_DAEMON_URL="''${PIGEON_DAEMON_URL:-http://127.0.0.1:4731}"
    POOL_K="${toString k}"
    REAL_OPENCODE="${opencode}/bin/opencode"
    original_args=("$@")
    selfhost() { exec "$REAL_OPENCODE" "''${original_args[@]+"''${original_args[@]}"}"; }

    # Self-host (today's behavior) unless pooling applies: only pool on hosts with
    # a real pool (K>=2; M4), and never on piped/non-TTY stdin since `attach`
    # cannot consume a piped prompt (M5).
    [ "$POOL_K" -ge 2 ] 2>/dev/null || selfhost
    [ -t 0 ] || selfhost

    split_classification "$(classify_oc_invocation "$@")"
    [ "$verb" = "PASSTHROUGH" ] && selfhost

    frontdoor_reachable() {
      local code
      code="$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 2 --max-time 3 \
        "$FRONTDOOR_URL/healthz" 2>/dev/null || true)"
      [ -n "$code" ] && [ "$code" != "000" ]
    }

    if [ "$verb" = "NEW" ]; then
      frontdoor_reachable || selfhost
      curl -sf --max-time 5 "$FRONTDOOR_URL/global/health" >/dev/null 2>&1 || selfhost
      dir_in="''${project:-$PWD}"
      dir_in="''${dir_in/#\~/$HOME}"
      [ -d "$dir_in" ] || selfhost
      dir_in="$(cd "$dir_in" && pwd)" || selfhost
      resp="$(curl -sf -X POST "$FRONTDOOR_URL/session" -H "x-opencode-directory: $dir_in" 2>/dev/null || true)"
      sid="$(printf '%s' "$resp" | jq -r '.id // empty' 2>/dev/null || true)"
      [ -n "$sid" ] || selfhost
      dir="$(printf '%s' "$resp" | jq -r '.directory // empty' 2>/dev/null || true)"
      [ -n "$dir" ] || dir="$dir_in"
      # The door placed this session at create, so a read-only GET /route resolves the owner;
      # any hiccup degrades serve_url to $OPENCODE_URL — never worse.
      route="$(curl -sf --connect-timeout 2 --max-time 3 "$PIGEON_DAEMON_URL/route?session_id=$sid" 2>/dev/null || true)"
      serve_url="$(parse_serve_url "$route" "$OPENCODE_URL")"
      exec "$REAL_OPENCODE" attach "$serve_url" --session "$sid" --dir "$dir"
    fi

    if [ "$verb" = "RESUME" ]; then
      body="$(curl -s -o - -w $'\n%{http_code}' --connect-timeout 2 --max-time 3 "$FRONTDOOR_URL/session/$sid" 2>/dev/null || true)"
      code="''${body##*$'\n'}"
      body="''${body%$'\n'*}"
      [ "$code" = "200" ] || selfhost
      dir="$(printf '%s' "$body" | jq -r '.directory // empty' 2>/dev/null || true)"
      [ -n "$dir" ] || selfhost
      # A RESUME of a session that was never placed (e.g. a pre-cutover session)
      # resolves to $OPENCODE_URL (anchor); post-cutover every session is door-created (placed),
      # so this is the transitional edge only.
      route="$(curl -sf --connect-timeout 2 --max-time 3 "$PIGEON_DAEMON_URL/route?session_id=$sid" 2>/dev/null || true)"
      serve_url="$(parse_serve_url "$route" "$OPENCODE_URL")"
      exec "$REAL_OPENCODE" attach "$serve_url" --session "$sid" --dir "$dir"
    fi

    selfhost
  '';
}
