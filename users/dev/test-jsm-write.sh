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
#   - a transition moves only a request the human raised, only along a
#     transition the desk offers them, and only with --send
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
run create 5 11 --summary "  Already: filed (here) " --send
[ "$rc" -eq 6 ] || oops "summary is trimmed before the duplicate check (got $rc)"
ok "duplicate open request blocks create, found by exact summary across pages"

# 5. bad input is refused before any write
run create 5 11 --summary "X" --field customfield_99=1 --send
[ "$rc" -eq 2 ] && grep -q 'customfield_99 is not a field' <<<"$err" || oops "unknown field refused"
run create 5 11 --summary "X" --field customfield_9=Nope --send
[ "$rc" -eq 2 ] && grep -q 'Nope is not an option' <<<"$err" || oops "unknown option refused"
run create 5 11 --summary "X" --field customfield_7=2026-01-01 --send
[ "$rc" -eq 2 ] && grep -q 'does not shape' <<<"$err" || oops "unshaped type refused"
run create 5 11 --summary "X" --field customfield_9=GitHub --field customfield_9=AppOne --send
[ "$rc" -eq 2 ] && grep -q 'given twice' <<<"$err" || oops "repeated --field refused"
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

# 8. transitions / transition: own request only, offered transitions only, dry run first
ME='{"accountId":"acc-me"}'
fx GET "https://$SITE/rest/api/3/myself" 200 "$ME"
MINE='{"issueKey":"ABC-9","reporter":{"accountId":"acc-me"},"currentStatus":{"status":"Waiting for support"},"_links":{"web":"https://example.atlassian.net/servicedesk/customer/portal/5/ABC-9"}}'
fx GET "$A/request/ABC-9" 200 "$MINE"
fx GET "$A/request/ABC-9/transition?limit=50" 200 \
  '{"isLastPage":true,"values":[{"id":"921","name":"Escalate"},{"id":"931","name":"Cancel request"}]}'
fx GET "$A/request/XYZ-4" 200 '{"issueKey":"XYZ-4","reporter":{"accountId":"acc-other"},"_links":{"web":"w"}}'
fx GET "$A/request/XYZ-4/transition?limit=50" 200 '{"isLastPage":true,"values":[{"id":"931","name":"Cancel request"}]}'
fx POST "$A/request/ABC-9/transition" 204 ''
run transitions ABC-9
[ "$rc" -eq 0 ] && has $'931\tCancel request' || oops "transitions lists ids and names"
nowrites "transitions"
printf 'Handled elsewhere; thanks.\n' > "$work/why.txt"
run transition ABC-9 --to "cancel request" --comment-file why.txt
[ "$rc" -eq 0 ] && [ "$(jq -r .id <<<"$out")" = 931 ] || oops "transition dry run resolves the name (case-insensitive) to its id"
[ "$(jq -r .additionalComment.body <<<"$out")" = "$(cat "$work/why.txt")" ] || oops "comment file sent verbatim as additionalComment"
nowrites "transition dry run"
run transition ABC-9 --to Resolve --send
[ "$rc" -eq 11 ] && grep -qF 'Cancel request' <<<"$err" || oops "a transition the desk does not offer exits 11 and lists the offered ones"
nowrites "transition not offered"
run transition XYZ-4 --to 931 --send
[ "$rc" -eq 10 ] || oops "someone else's request exits 10 (got $rc)"
nowrites "someone else's request"
run transition ABC-9 --to 931 --send
[ "$rc" -eq 0 ] || oops "transition --send exits 0 on HTTP 204 (got $rc)"
[ "$(grep -c . "$work/fx/writes.log")" -eq 1 ] && grep -q "^POST $A/request/ABC-9/transition$" "$work/fx/writes.log" ||
  oops "exactly one POST to /request/KEY/transition"
[ "$(jq -r .id "$work/fx/body.json")" = 931 ] && [ "$(jq 'has("additionalComment")' "$work/fx/body.json")" = false ] ||
  oops "payload is the id alone when no comment is given"
has "ABC-9" && has "portal/5/ABC-9" || oops "prints the key, its status after the move, and the portal link"
if grep -qF -- "$TOKEN" "$work/fx/argv.log"; then oops "token absent from argv (transition)"; fi
grep -q 'not in the DONE category' <<<"$err" || oops "warns when the status after the move is not DONE"
run transition ABC-9 --to Escalate --send
[ "$rc" -eq 12 ] || oops "an offered move that is not a close exits 12 (got $rc)"
nowrites "escalate refused"
fx POST "$A/request/ABC-9/comment" 204 ''
run comment ABC-9 --body-file desc.txt --send
[ "$rc" -eq 5 ] || oops "a 204 outside transition is exit 5, not success (got $rc)"
fx POST "$A/request/ABC-9/comment" 201 '{"id":"555","public":true}'
ok "transition: own request only (10), offered only (11), closes only (12), dry run, one POST, 204 only there, DONE check"

# 9. usage and env
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
