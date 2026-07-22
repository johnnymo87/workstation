#!/usr/bin/env bash
# Unit tests for oc-pool-attach classify_oc_invocation pure helper.
# Run: bash test.sh

set -o errexit -o nounset -o pipefail

# ---- helpers under test (mirror of default.nix) -----------------------------

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
        sid="${a#--session=}"; have_session=1; shift ;;
      -s*)
        if [ "$have_session" -eq 1 ]; then printf 'PASSTHROUGH\t\t\n'; return 0; fi
        sid="${a#-s}"; have_session=1; shift ;;
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

split_classification() {
  local c="$1"
  verb="${c%%$'\t'*}"
  c="${c#*$'\t'}"
  sid="${c%%$'\t'*}"
  project="${c#*$'\t'}"
}

# ---- test infrastructure ----------------------------------------------------

assert_eq() {
  local expected="$1" actual="$2" msg="$3"
  if [ "$expected" = "$actual" ]; then
    printf 'PASS  %s\n' "$msg"
  else
    printf 'FAIL  %s\n        expected: %s\n        actual:   %s\n' "$msg" "$expected" "$actual"
    exit 1
  fi
}

# ---- test cases -------------------------------------------------------------

T() { assert_eq "$1" "$(classify_oc_invocation "${@:2}")" "classify: ${*:2}"; }
T $'NEW\t\t'                                 # bare opencode
T $'NEW\t\tmyproj'          myproj
T $'NEW\t\t./serve'         ./serve          # dir named serve != exact subcommand 'serve'
T $'NEW\t\trunfoo'          runfoo
T $'RESUME\tses_abc\t'      -s ses_abc
T $'RESUME\tses_abc\t'      --session ses_abc
T $'RESUME\tses_abc\t'      --session=ses_abc
T $'RESUME\tses_abc\t'      -sses_abc
T $'RESUME\tses_abc\tproj'  proj -s ses_abc       # trailing -s after a positional
T $'RESUME\tses_abc\tproj'  -s ses_abc proj
for sc in completion acp mcp attach run debug providers auth agent upgrade uninstall serve web models stats export import github pr session plugin plug db; do
  T $'PASSTHROUGH\t\t' "$sc"
done
T $'PASSTHROUGH\t\t'        -- proj          # -- terminator: conservative passthrough
T $'PASSTHROUGH\t\t'        --model X
T $'PASSTHROUGH\t\t'        -m X
T $'PASSTHROUGH\t\t'        --agent build
T $'PASSTHROUGH\t\t'        --prompt hi
T $'PASSTHROUGH\t\t'        --port 5000
T $'PASSTHROUGH\t\t'        --hostname 0.0.0.0
T $'PASSTHROUGH\t\t'        -c
T $'PASSTHROUGH\t\t'        --continue
T $'PASSTHROUGH\t\t'        --pure
T $'PASSTHROUGH\t\t'        -h
T $'PASSTHROUGH\t\t'        -v
T $'PASSTHROUGH\t\t'        -s ses_abc --model Y   # resume token + incompatible flag
T $'PASSTHROUGH\t\t'        -s                     # -s with no value
T $'PASSTHROUGH\t\t'        -s bad!sid             # sid fails ^ses_[A-Za-z0-9_-]+$
T $'PASSTHROUGH\t\t'        proj1 proj2            # >1 positional -> ambiguous

# ---- split_classification tests ---------------------------------------------
# Regression guard: `read -r verb sid project` with IFS=$'\t' collapses the
# empty middle field of "NEW<TAB><TAB><project>" (tab is IFS-whitespace), which
# silently dropped <project>. split_classification must preserve empty fields.
verb=""; sid=""; project=""
S() { split_classification "$2"; assert_eq "$1" "$verb|$sid|$project" "split: $3"; }
S 'NEW||'             "$(classify_oc_invocation)"            "bare -> empty sid+project"
S 'NEW||myproj'       "$(classify_oc_invocation myproj)"     "NEW project preserved (the read-collapse bug)"
S 'RESUME|ses_abc|'   "$(classify_oc_invocation -s ses_abc)" "RESUME sid, empty project"
S 'RESUME|ses_abc|proj' "$(classify_oc_invocation proj -s ses_abc)" "RESUME sid + project"
S 'PASSTHROUGH||'     "$(classify_oc_invocation run)"        "PASSTHROUGH -> empty sid+project"

# ---- parse_serve_url tests --------------------------------------------------
fallback_url="http://127.0.0.1:4096"
if command -v jq >/dev/null 2>&1; then
  route_body='{"sessionId":"ses_x","serveId":"serve-1","apiBase":"http://127.0.0.1:4097","eventUrl":"http://127.0.0.1:4097/event?session_ids=ses_x"}'
  assert_eq "http://127.0.0.1:4097" "$(parse_serve_url "$route_body" "$fallback_url")" \
    "parse_serve_url: valid GET /route body -> apiBase (owning serve)"
  place_body='{"ok":true,"session_id":"ses_x","serve_id":"serve-2","api_base":"http://127.0.0.1:4098","event_url":"http://127.0.0.1:4098/event?session_ids=ses_x"}'
  assert_eq "http://127.0.0.1:4098" "$(parse_serve_url "$place_body" "$fallback_url")" \
    "parse_serve_url: valid POST /place body -> api_base (owning serve)"
  assert_eq "$fallback_url" "$(parse_serve_url '{"api_base":null}' "$fallback_url")" \
    "parse_serve_url: api_base null -> fallback"
  assert_eq "$fallback_url" "$(parse_serve_url '{"api_base":""}' "$fallback_url")" \
    "parse_serve_url: api_base empty string -> fallback"
  assert_eq "$fallback_url" "$(parse_serve_url "" "$fallback_url")" \
    "parse_serve_url: empty body -> fallback"
  assert_eq "$fallback_url" "$(parse_serve_url "not json at all" "$fallback_url")" \
    "parse_serve_url: non-JSON body -> fallback"
  assert_eq "$fallback_url" "$(parse_serve_url '{"sessionId":"ses_x"}' "$fallback_url")" \
    "parse_serve_url: JSON without apiBase -> fallback"
  assert_eq "$fallback_url" "$(parse_serve_url '{"apiBase":null}' "$fallback_url")" \
    "parse_serve_url: apiBase null -> fallback"
  assert_eq "$fallback_url" "$(parse_serve_url '{"apiBase":""}' "$fallback_url")" \
    "parse_serve_url: apiBase empty string -> fallback"
else
  printf 'SKIP  parse_serve_url tests (jq not on PATH)\n'
fi

# ---- production-source check (default.nix) -----------------------------------
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
default_nix="$script_dir/default.nix"
if [ -f "$default_nix" ]; then
  if grep -q 'parse_serve_url()' "$default_nix"; then
    printf 'PASS  source defines parse_serve_url\n'
  else
    printf 'FAIL  source defines parse_serve_url\n        not found in: %s\n' "$default_nix"; exit 1
  fi

  if grep -q 'classify_oc_invocation()' "$default_nix"; then
    printf 'PASS  source defines classify_oc_invocation\n'
  else
    printf 'FAIL  source defines classify_oc_invocation\n        not found in: %s\n' "$default_nix"; exit 1
  fi

  if grep -q 'split_classification()' "$default_nix"; then
    printf 'PASS  source defines split_classification\n'
  else
    printf 'FAIL  source defines split_classification\n        not found in: %s\n' "$default_nix"; exit 1
  fi

  # Regression guard: must NOT parse the classifier output with `read` + IFS=tab
  # (collapses the empty middle field, dropping <project>).
  if grep -q "IFS=\$'\\\\t' read" "$default_nix"; then
    printf 'FAIL  source parses classify output with IFS=tab read (drops empty project field)\n        in: %s\n' "$default_nix"; exit 1
  else
    printf 'PASS  source avoids IFS=tab read for classify output\n'
  fi

  if grep -q 'PIGEON_DAEMON_URL' "$default_nix"; then
    printf 'PASS  source honors PIGEON_DAEMON_URL\n'
  else
    printf 'FAIL  source honors PIGEON_DAEMON_URL\n        not found in: %s\n' "$default_nix"; exit 1
  fi

  if grep -q 'POST "\$PIGEON_DAEMON_URL/place"' "$default_nix"; then
    printf 'FAIL  source still contains pigeon POST /place (should be dropped)\n        found in: %s\n' "$default_nix"; exit 1
  else
    printf 'PASS  source does not contain pigeon POST /place\n'
  fi

  if grep -q 'FRONTDOOR_URL=' "$default_nix"; then
    printf 'PASS  source defines FRONTDOOR_URL\n'
  else
    printf 'FAIL  source defines FRONTDOOR_URL\n        not found in: %s\n' "$default_nix"; exit 1
  fi

  if grep -q '"\$FRONTDOOR_URL/session' "$default_nix"; then
    printf 'PASS  source references "$FRONTDOOR_URL/session"\n'
  else
    printf 'FAIL  source references "$FRONTDOOR_URL/session"\n        not found in: %s\n' "$default_nix"; exit 1
  fi

  if grep -q '"\$OPENCODE_URL/session' "$default_nix"; then
    printf 'FAIL  source still references old "$OPENCODE_URL/session"\n        found in: %s\n' "$default_nix"; exit 1
  else
    printf 'PASS  source does not reference old "$OPENCODE_URL/session"\n'
  fi

  if grep -q 'attach' "$default_nix" && grep -q -- '--session' "$default_nix" && grep -q -- '--dir' "$default_nix"; then
    printf 'PASS  source runs attach with --session and --dir\n'
  else
    printf 'FAIL  source runs attach with --session and --dir\n        not found in: %s\n' "$default_nix"; exit 1
  fi

  if grep -q '\[ -t 0 \]' "$default_nix"; then
    printf 'PASS  source has stdin guard [ -t 0 ]\n'
  else
    printf 'FAIL  source has stdin guard [ -t 0 ]\n        not found in: %s\n' "$default_nix"; exit 1
  fi

  if grep -q 'POOL_K' "$default_nix"; then
    printf 'PASS  source gates on POOL_K\n'
  else
    printf 'FAIL  source gates on POOL_K\n        not found in: %s\n' "$default_nix"; exit 1
  fi

  if grep -q 'frontdoor_reachable' "$default_nix"; then
    printf 'PASS  source defines/calls frontdoor_reachable\n'
  else
    printf 'FAIL  source defines/calls frontdoor_reachable\n        not found in: %s\n' "$default_nix"; exit 1
  fi

  if grep -q '"\$FRONTDOOR_URL/healthz"' "$default_nix"; then
    printf 'PASS  source probes "$FRONTDOOR_URL/healthz"\n'
  else
    printf 'FAIL  source probes "$FRONTDOOR_URL/healthz"\n        not found in: %s\n' "$default_nix"; exit 1
  fi

  if grep -q 'ses_poolprobe' "$default_nix"; then
    printf 'FAIL  source still contains ses_poolprobe hack\n        found in: %s\n' "$default_nix"; exit 1
  else
    printf 'PASS  source does not contain ses_poolprobe hack\n'
  fi

  if grep -q '/route?session_id=' "$default_nix"; then
    printf 'PASS  source queries /route?session_id= for read-only discovery\n'
  else
    printf 'FAIL  source queries /route?session_id= for read-only discovery\n        not found in: %s\n' "$default_nix"; exit 1
  fi

  if grep -q 'original_args' "$default_nix"; then
    printf 'PASS  source uses original_args fallbacks\n'
  else
    printf 'FAIL  source uses original_args fallbacks\n        not found in: %s\n' "$default_nix"; exit 1
  fi
else
  printf 'SKIP  production-source check (default.nix not next to test)\n'
fi

echo "all oc-pool-attach tests passed"
