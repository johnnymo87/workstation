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
echo "all oc-pool-attach classify tests passed"
