#!/usr/bin/env bash
# Hermetic tests for assets/opencode/skills/reading-jsm-portal-requests/jsm-write.sh.
#
# A fake `curl` on PATH serves fixture JSON keyed by method + URL and records
# argv, stdin and any request body, so the tests pin what matters for a helper
# that writes under the human's name:
#   - nothing is POSTed without --send (dry run prints the payload)
#   - the token never appears in argv (stdin via --config -)
#   - option fields are sent as {"id": ...}, resolved from their label
#   - unknown fields, unknown options and missing required fields are refused
#     before any write
#   - an open request with the same summary blocks a second create (exit 6),
#     matched exactly, without relying on searchTerm
#   - comments are posted public, with the body file verbatim
#
# Run: bash users/dev/test-jsm-write.sh
set -o errexit -o nounset -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../../assets/opencode/skills/reading-jsm-portal-requests/jsm-write.sh"
[ -f "$SCRIPT" ] || { echo "FAIL: cannot find $SCRIPT" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/fx"

# ---- fake curl ---------------------------------------------------------------
# Fixture: $FX/<METHOD>_<url with non-alnum -> _>; sibling .code = HTTP status.
printf '#!%s\n' "$BASH" > "$work/bin/curl"
cat >> "$work/bin/curl" <<'EOF'
set -o nounset
out=/dev/stdout; wfmt=""; url=""; method=GET
printf '%s\n' "$*" >> "$FX/argv.log"
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  a="${args[$i]}"
  case "$a" in
    -o) i=$((i + 1)); out="${args[$i]}" ;;
    -w) i=$((i + 1)); wfmt="${args[$i]}" ;;
    -X) i=$((i + 1)); method="${args[$i]}" ;;
    --data-binary) i=$((i + 1)); f="${args[$i]#@}"; cat "$f" > "$FX/body.json" ;;
    https://*) url="$a" ;;
  esac
done
cat >> "$FX/stdin.log"
[ "$method" = GET ] || printf '%s %s\n' "$method" "$url" >> "$FX/writes.log"
name="${method}_$(printf '%s' "$url" | sed 's/[^A-Za-z0-9]/_/g')"
code=200
[ -f "$FX/$name.code" ] && code="$(cat "$FX/$name.code")"
if [ -f "$FX/$name" ]; then cat "$FX/$name" > "$out"; else code=404; printf '{"errorMessage":"no fixture"}' > "$out"; fi
[ -n "$wfmt" ] && printf '%s' "$code"
exit 0
EOF
chmod +x "$work/bin/curl"

SITE="example.atlassian.net"
A="https://$SITE/rest/servicedeskapi"
fx() { # fx <METHOD> <url> <code> <body>
  local name; name="$1_$(printf '%s' "$2" | sed 's/[^A-Za-z0-9]/_/g')"
  printf '%s' "$4" > "$work/fx/$name"
  [ "$3" = 200 ] || printf '%s' "$3" > "$work/fx/$name.code"
}

fx GET "$A/servicedesk/5/requesttype?limit=100" 200 \
  '{"isLastPage":true,"values":[{"id":"11","name":"Access request"},{"id":"12","name":"Other"}]}'
FIELDS='{"requestTypeFields":[
  {"fieldId":"summary","name":"Brief description","required":true,"jiraSchema":{"type":"string"},"validValues":[]},
  {"fieldId":"customfield_9","name":"Applications","required":false,"jiraSchema":{"type":"option"},
   "validValues":[{"value":"301","label":"AppOne"},{"value":"302","label":"GitHub"}]},
  {"fieldId":"customfield_8","name":"Teams","required":false,"jiraSchema":{"type":"array","items":"option"},
   "validValues":[{"value":"401","label":"Red"}]},
  {"fieldId":"customfield_7","name":"Due","required":false,"jiraSchema":{"type":"date"},"validValues":[]},
  {"fieldId":"description","name":"Description","required":false,"jiraSchema":{"type":"string"},"validValues":[]}]}'
fx GET "$A/servicedesk/5/requesttype/11/field" 200 "$FIELDS"
OWNED="$A/request?requestOwnership=OWNED_REQUESTS&requestStatus=OPEN_REQUESTS&serviceDeskId=5"
fx GET "$OWNED&start=0&limit=50" 200 \
  '{"size":1,"isLastPage":false,"values":[{"issueKey":"ABC-1","summary":"Something else","_links":{"web":"w1"}}]}'
fx GET "$OWNED&start=1&limit=50" 200 \
  '{"size":1,"isLastPage":true,"values":[{"issueKey":"ABC-2","summary":"Already: filed (here)","_links":{"web":"https://example.atlassian.net/servicedesk/customer/portal/5/ABC-2"}}]}'
fx POST "$A/request" 201 \
  '{"issueKey":"ABC-9","_links":{"web":"https://example.atlassian.net/servicedesk/customer/portal/5/ABC-9"}}'
fx GET "$A/request/ABC-9" 200 '{"issueKey":"ABC-9","_links":{"web":"https://example.atlassian.net/servicedesk/customer/portal/5/ABC-9"}}'
fx POST "$A/request/ABC-9/comment" 201 '{"id":"555","public":true}'

TOKEN="tok-SECRET-123"
run() { # run <args...>; sets $out, $err, $rc
  : > "$work/fx/argv.log"; : > "$work/fx/stdin.log"; : > "$work/fx/writes.log"; rm -f "$work/fx/body.json"
  set +o errexit
  out="$(cd "$work" && PATH="$work/bin:$PATH" FX="$work/fx" ATLASSIAN_SITE="$SITE" ATLASSIAN_EMAIL="me@example.com" \
         ATLASSIAN_API_TOKEN="$TOKEN" bash "$SCRIPT" "$@" 2>"$work/err")"
  rc=$?
  set -o errexit
  err="$(cat "$work/err")"
}

pass_n=0
ok()   { printf 'PASS  %s\n' "$1"; pass_n=$((pass_n + 1)); }
oops() { printf 'FAIL  %s\n' "$1" >&2; printf -- '--- stdout\n%s\n--- stderr\n%s\n' "$out" "$err" >&2; exit 1; }
has()  { grep -qF -- "$1" <<<"$out"; }
nowrites() { [ ! -s "$work/fx/writes.log" ] || oops "$1: nothing written"; }
printf 'Line one with "quotes" and a $dollar.\n\nLine three.\n' > "$work/desc.txt"

# 1. types and fields are GETs
run types 5
[ "$rc" -eq 0 ] && has $'11\tAccess request' || oops "types lists ids and names"
run fields 5 11
[ "$rc" -eq 0 ] && has "customfield_9" && has "GitHub" && has "required" || oops "fields lists fields and options"
nowrites "types/fields"
ok "types and fields list ids, names and option labels, GET only"

# 2. create without --send is a dry run with the shaped payload
run create 5 11 --summary "New thing" --description-file desc.txt --field customfield_9=GitHub --field customfield_8=Red
[ "$rc" -eq 0 ] || oops "dry run exits 0 (got $rc)"
nowrites "dry run"
grep -qi 'dry run' <<<"$err" || oops "dry run says so"
[ "$(jq -r '.requestFieldValues.customfield_9.id' <<<"$out")" = 302 ] || oops "option label resolved to {id}"
[ "$(jq -r '.requestFieldValues.customfield_8[0].id' <<<"$out")" = 401 ] || oops "array option sent as [{id}]"
[ "$(jq -r '.requestFieldValues.description' <<<"$out")" = "$(cat "$work/desc.txt")" ] || oops "description verbatim"
[ "$(jq -r '.serviceDeskId + "/" + .requestTypeId' <<<"$out")" = 5/11 ] || oops "desk and type in payload"
ok "create without --send: dry run, option label -> {id}, array -> [{id}], description verbatim"

# 3. create --send posts once, token on stdin, prints key and portal link
run create 5 11 --summary "New thing" --description-file desc.txt --field customfield_9=302 --send
[ "$rc" -eq 0 ] || oops "--send exits 0 (got $rc)"
has $'ABC-9\thttps://example.atlassian.net/servicedesk/customer/portal/5/ABC-9' || oops "prints key and portal link"
[ "$(grep -c . "$work/fx/writes.log")" -eq 1 ] && grep -q "^POST $A/request$" "$work/fx/writes.log" || oops "exactly one POST to /request"
[ "$(jq -r '.requestFieldValues.customfield_9.id' "$work/fx/body.json")" = 302 ] || oops "option id accepted as-is"
if grep -qF -- "$TOKEN" "$work/fx/argv.log"; then oops "token absent from argv"; fi
grep -qF -- "$TOKEN" "$work/fx/stdin.log" || oops "token on stdin"
ok "create --send: one POST, key and portal link printed, token only on stdin"

# 4. duplicate open request (exact summary, found on page 2) blocks create
run create 5 11 --summary "Already: filed (here)" --send
[ "$rc" -eq 6 ] || oops "duplicate exits 6 (got $rc)"
grep -qF 'ABC-2' <<<"$err" || oops "duplicate names the existing key"
nowrites "duplicate"
if grep -q 'searchTerm' "$work/fx/argv.log"; then oops "duplicate check does not rely on searchTerm"; fi
ok "duplicate open request blocks create, found by exact summary across pages"

# 5. bad input is refused before any write
run create 5 11 --summary "X" --field customfield_99=1 --send
[ "$rc" -eq 2 ] && grep -q 'customfield_99 is not a field' <<<"$err" || oops "unknown field refused"
run create 5 11 --summary "X" --field customfield_9=Nope --send
[ "$rc" -eq 2 ] && grep -q 'Nope is not an option' <<<"$err" || oops "unknown option refused"
run create 5 11 --summary "X" --field customfield_7=2026-01-01 --send
[ "$rc" -eq 2 ] && grep -q 'does not shape' <<<"$err" || oops "unshaped type refused"
run create 5 11 --summary "   " --send
[ "$rc" -eq 2 ] || oops "blank summary refused"
run create 5 11 --summary "X" --description-file missing.txt --send
[ "$rc" -eq 2 ] || oops "missing description file refused (got $rc)"
nowrites "bad input"
ok "unknown field, unknown option, unshaped type, blank summary, missing file: exit 2, no write"

# 6. HTTP 400 from the desk maps to 8 with its message
fx POST "$A/request" 400 '{"errorMessage":"Field Applications is invalid"}'
run create 5 11 --summary "New thing" --send
[ "$rc" -eq 8 ] && grep -q 'Field Applications is invalid' <<<"$err" || oops "400 -> 8 with message"
fx POST "$A/request" 403 '{"errorMessage":"You cannot raise requests here"}'
run create 5 11 --summary "New thing" --send
[ "$rc" -eq 9 ] || oops "403 -> 9 (got $rc)"
ok "HTTP 400 -> 8 with the desk's message; 403 -> 9"

# 7. comment: dry run, then a public POST with the body verbatim
run comment ABC-9 --body-file desc.txt
[ "$rc" -eq 0 ] && [ "$(jq -r .public <<<"$out")" = true ] || oops "comment dry run shows a public payload"
nowrites "comment dry run"
run comment ABC-9 --body-file desc.txt --send
[ "$rc" -eq 0 ] && has "comment 555 on https://example.atlassian.net/servicedesk/customer/portal/5/ABC-9" || oops "comment --send prints id and link"
grep -q "^POST $A/request/ABC-9/comment$" "$work/fx/writes.log" || oops "POST to /request/KEY/comment"
[ "$(jq -r .body "$work/fx/body.json")" = "$(cat "$work/desc.txt")" ] && [ "$(jq -r .public "$work/fx/body.json")" = true ] ||
  oops "body verbatim, public true"
run comment NOPE-1 --body-file desc.txt --send
[ "$rc" -eq 7 ] || oops "comment on unknown request exits 7 (got $rc)"
nowrites "comment on unknown request"
ok "comment: dry run, then public POST with body verbatim; unknown request refused before writing"

# 8. usage and env
run
[ "$rc" -eq 2 ] || oops "no args exits 2"
run create 5 abc --summary X
[ "$rc" -eq 2 ] || oops "non-numeric type id exits 2"
set +o errexit
PATH="$work/bin:$PATH" FX="$work/fx" ATLASSIAN_SITE="" ATLASSIAN_EMAIL="" ATLASSIAN_API_TOKEN="" \
  bash "$SCRIPT" types 5 >/dev/null 2>&1; rc=$?
set -o errexit
[ "$rc" -eq 3 ] || oops "missing env exits 3 (got $rc)"
ok "usage -> 2; missing env -> 3"

echo "ALL PASS ($pass_n checks, test-jsm-write)"
