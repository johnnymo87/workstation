#!/usr/bin/env bash
# Hermetic tests for assets/opencode/skills/reading-jsm-portal-requests/jsm-request.sh.
#
# A fake `curl` on PATH serves fixture JSON keyed by URL and records every
# invocation, so the tests can pin the properties that matter for a helper
# that holds the human's Atlassian token:
#   - GET only (no -X, --data, -d, -F, --json, -T on any call)
#   - the token never appears in curl's argv (it goes in on stdin via --config -)
#   - comments are paged OLDEST first to the end, so the latest reply is last
#     (the API has no ordering parameter; `limit=1` returns the FIRST comment)
#   - internal comments are never asked for or printed
#   - a portal or browse link is accepted, but only on $ATLASSIAN_SITE
#   - 404 / 401 map to distinct exit codes with a hint
#
# Run: bash users/dev/test-jsm-request.sh
set -o errexit -o nounset -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../../assets/opencode/skills/reading-jsm-portal-requests/jsm-request.sh"
[ -f "$SCRIPT" ] || { echo "FAIL: cannot find $SCRIPT" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/fx"

# ---- fake curl ---------------------------------------------------------------
# Fixture for a URL: $FX/<url with every non-alnum replaced by _>; optional
# sibling .code holds the HTTP status (default 200). Records argv (one line
# per call) to $FX/argv.log and stdin to $FX/stdin.log.
# Shebang from this bash's own path: the nix build sandbox has no /usr/bin/env.
printf '#!%s\n' "$BASH" > "$work/bin/curl"
cat >> "$work/bin/curl" <<'EOF'
set -o nounset
out=/dev/stdout; wfmt=""; url=""
printf '%s\n' "$*" >> "$FX/argv.log"
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  a="${args[$i]}"
  case "$a" in
    -o) i=$((i + 1)); out="${args[$i]}" ;;
    -w) i=$((i + 1)); wfmt="${args[$i]}" ;;
    https://*) url="$a" ;;
  esac
done
cat >> "$FX/stdin.log"
name="$(printf '%s' "$url" | sed 's/[^A-Za-z0-9]/_/g')"
code=200
[ -f "$FX/$name.code" ] && code="$(cat "$FX/$name.code")"
if [ -f "$FX/$name" ]; then cat "$FX/$name" > "$out"; else code=404; printf '{"errorMessage":"no fixture"}' > "$out"; fi
[ -n "$wfmt" ] && printf '%s' "$code"
exit 0
EOF
chmod +x "$work/bin/curl"

SITE="example.atlassian.net"
B="https://$SITE"
fx() { # fx <url> <code> <body>
  local name; name="$(printf '%s' "$1" | sed 's/[^A-Za-z0-9]/_/g')"
  printf '%s' "$3" > "$work/fx/$name"
  [ "$2" = 200 ] || printf '%s' "$2" > "$work/fx/$name.code"
}

REQ='{"issueId":"1001","issueKey":"ABC-7","serviceDeskId":"5","summary":"Need access to the thing",
 "requestType":{"name":"Access request"},
 "currentStatus":{"status":"Waiting for Customer","statusCategory":"INDETERMINATE","statusDate":{"iso8601":"2026-01-02T10:00:00-0500"}},
 "createdDate":{"iso8601":"2026-01-01T09:00:00-0500"},
 "reporter":{"displayName":"Requester Person"},
 "requestFieldValues":[{"fieldId":"summary","label":"Summary","value":"Need access to the thing"},
                       {"fieldId":"description","label":"Description","value":"Please grant *access*."},
                       {"fieldId":"customfield_1","label":"Applications","value":[{"value":"AppOne"}]}],
 "_links":{"web":"https://example.atlassian.net/servicedesk/customer/portal/5/ABC-7"}}'
fx "$B/rest/servicedeskapi/request/ABC-7?expand=requestType" 200 "$REQ"
fx "$B/rest/servicedeskapi/request/ABC-7/comment?public=true&internal=false&start=0&limit=100" 200 \
  '{"size":1,"start":0,"limit":100,"isLastPage":false,"values":[{"id":"11","public":true,"created":{"iso8601":"2026-01-01T10:00:00-0500"},"author":{"displayName":"Agent One"},"body":"FIRST reply"}]}'
fx "$B/rest/servicedeskapi/request/ABC-7/comment?public=true&internal=false&start=1&limit=100" 200 \
  '{"size":1,"start":1,"limit":100,"isLastPage":true,"values":[{"id":"12","public":true,"created":{"iso8601":"2026-01-02T10:00:00-0500"},"author":{"displayName":"Agent Two"},"body":"LATEST reply: please send the form"}]}'
fx "$B/rest/servicedeskapi/request/ABC-7/attachment?start=0&limit=100" 200 \
  '{"size":1,"isLastPage":true,"values":[{"filename":"../evil/shot.png","mimeType":"image/png","size":5,"_links":{"content":"https://example.atlassian.net/rest/servicedeskapi/request/1001/attachment/77"}}]}'
fx "$B/rest/servicedeskapi/request/1001/attachment/77" 200 'PNGDATA'
fx "$B/rest/servicedeskapi/request/NOPE-1?expand=requestType" 404 '{"errorMessage":"sd.portal.error.issue.not.found"}'
fx "$B/rest/servicedeskapi/request/BAD-1?expand=requestType" 401 '{"message":"Client must be authenticated"}'
fx "$B/rest/servicedeskapi/request/OTHER-1?expand=requestType" 403 '{"errorMessage":"You do not have permission to view this request."}'
# PART-1: comment page 2 fails, so nothing may be printed.
fx "$B/rest/servicedeskapi/request/PART-1?expand=requestType" 200 "${REQ//ABC-7/PART-1}"
fx "$B/rest/servicedeskapi/request/PART-1/comment?public=true&internal=false&start=0&limit=100" 200 \
  '{"size":1,"start":0,"limit":100,"isLastPage":false,"values":[{"id":"11","public":true,"created":{"iso8601":"x"},"author":{"displayName":"A"},"body":"PAGE ONE"}]}'
fx "$B/rest/servicedeskapi/request/PART-1/comment?public=true&internal=false&start=1&limit=100" 502 'bad gateway'
fx "$B/rest/servicedeskapi/request?requestOwnership=PARTICIPATED_REQUESTS&requestStatus=ALL_REQUESTS&start=0&limit=50" 200 \
  '{"size":0,"isLastPage":true,"values":[]}'
fx "$B/rest/servicedeskapi/request?requestOwnership=OWNED_REQUESTS&requestStatus=OPEN_REQUESTS&start=0&limit=50" 200 \
  '{"size":1,"isLastPage":true,"values":[{"issueKey":"ABC-7","summary":"Need access to the thing","currentStatus":{"status":"Waiting for Customer"},"createdDate":{"iso8601":"2026-01-01T09:00:00-0500"},"_links":{"web":"https://example.atlassian.net/servicedesk/customer/portal/5/ABC-7"}}]}'

TOKEN="tok-SECRET-123"
run() { # run <args...>; sets $out, $err, $rc
  : > "$work/fx/argv.log"; : > "$work/fx/stdin.log"
  set +o errexit
  out="$(PATH="$work/bin:$PATH" FX="$work/fx" ATLASSIAN_SITE="$SITE" ATLASSIAN_EMAIL="me@example.com" \
         ATLASSIAN_API_TOKEN="$TOKEN" bash "$SCRIPT" "$@" 2>"$work/err")"
  rc=$?
  set -o errexit
  err="$(cat "$work/err")"
}

pass_n=0
ok()   { printf 'PASS  %s\n' "$1"; pass_n=$((pass_n + 1)); }
oops() { printf 'FAIL  %s\n' "$1" >&2; printf -- '--- stdout\n%s\n--- stderr\n%s\n' "$out" "$err" >&2; exit 1; }
has()  { grep -qF -- "$1" <<<"$out"; }

# 1. read by key: header, status, fields, comments in order
run ABC-7
[ "$rc" -eq 0 ] || oops "read by key exits 0 (got $rc)"
has "# ABC-7: Need access to the thing" || oops "header names key and summary"
has "Waiting for Customer" || oops "status shown"
has "https://example.atlassian.net/servicedesk/customer/portal/5/ABC-7" || oops "portal link shown"
has "Please grant *access*." || oops "description field shown"
has "AppOne" || oops "non-string field shown"
first="$(grep -n 'FIRST reply' <<<"$out" | cut -d: -f1)"; last="$(grep -n 'LATEST reply' <<<"$out" | cut -d: -f1)"
[ -n "$first" ] && [ -n "$last" ] && [ "$first" -lt "$last" ] || oops "both comment pages read, oldest first, latest last"
has "../evil/shot.png" || oops "attachment listed"
ok "read by key: header, status, fields, paged comments oldest-first, attachments"

# 2. GET only, token never in argv, credentials go in on stdin
if grep -qE -- '(^| )(-X|--request|-d|--data[a-z-]*|-F|--form|--json|-T|--upload-file)( |$)' "$work/fx/argv.log"; then oops "GET only"; fi
if grep -qF -- "$TOKEN" "$work/fx/argv.log"; then oops "token absent from argv"; fi
grep -qF -- "$TOKEN" "$work/fx/stdin.log" || oops "token passed on stdin"
if grep -q 'internal=true' "$work/fx/argv.log"; then oops "never asks for internal comments"; fi
ok "GET only; token on stdin, never in argv; internal comments never requested"

# 3. portal link and browse link resolve to the key
run "https://$SITE/servicedesk/customer/portal/5/ABC-7"
[ "$rc" -eq 0 ] && has "# ABC-7:" || oops "portal link accepted"
run "https://$SITE/browse/ABC-7?focusedCommentId=12"
[ "$rc" -eq 0 ] && has "# ABC-7:" || oops "browse link accepted"
ok "portal and browse links resolve to the key"

# 3b. a portal home link names no request
run "https://$SITE/servicedesk/customer/portal/5"
[ "$rc" -eq 2 ] || oops "portal home link exits 2 (got $rc)"
ok "portal home link refused"

# 4. link on another site is refused before any call
run "https://other.atlassian.net/servicedesk/customer/portal/5/ABC-7"
[ "$rc" -eq 2 ] || oops "foreign site exits 2 (got $rc)"
[ ! -s "$work/fx/argv.log" ] || oops "foreign site makes no call"
ok "link on another site refused without a call"

# 5. not found / bad credentials
run NOPE-1
[ "$rc" -eq 7 ] || oops "404 exits 7 (got $rc)"
grep -qi 'not a service-desk request' <<<"$err" || oops "404 explains itself"
run BAD-1
[ "$rc" -eq 4 ] || oops "401 exits 4 (got $rc)"
run OTHER-1
[ "$rc" -eq 9 ] || oops "403 exits 9 (got $rc)"
grep -qi 'no permission' <<<"$err" || oops "403 explains itself"
ok "404 -> 7, 403 -> 9, 401 -> 4, each with its own hint"

# 6. attachments download into DIR with a sanitized name
dl="$work/dl"
run ABC-7 --attachments "$dl"
[ "$rc" -eq 0 ] || oops "--attachments exits 0 (got $rc)"
[ "$(cat "$dl/1-shot.png" 2>/dev/null)" = PNGDATA ] || oops "attachment saved as numbered basename in DIR"
[ ! -e "$work/evil" ] || oops "no path traversal"
grep -qE 'Accept: \*/\*.*attachment/77' "$work/fx/argv.log" || oops "download does not ask for JSON"
ok "--attachments saves numbered basenames into DIR, without a JSON Accept header"

# 6b. a failure on a later page prints nothing (no partial list that looks complete)
run PART-1
[ "$rc" -eq 5 ] || oops "later-page failure exits 5 (got $rc)"
[ -z "$out" ] || oops "later-page failure prints nothing on stdout"
ok "failure part-way prints nothing"

# 7. --list: requests you raised
run --list
[ "$rc" -eq 0 ] && has "ABC-7" && has "Waiting for Customer" || oops "--list shows owned open requests"
run --list all --participated
[ "$rc" -eq 0 ] && has "(none)" || oops "--list all --participated lists participated requests"
ok "--list shows your open requests; --participated and status filters"

# 8. usage and missing env
run
[ "$rc" -eq 2 ] || oops "no args exits 2 (got $rc)"
set +o errexit
PATH="$work/bin:$PATH" FX="$work/fx" ATLASSIAN_SITE="" ATLASSIAN_EMAIL="" ATLASSIAN_API_TOKEN="" \
  bash "$SCRIPT" ABC-7 >/dev/null 2>&1; rc=$?
set -o errexit
[ "$rc" -eq 3 ] || oops "missing env exits 3 (got $rc)"
ok "usage -> 2; missing env -> 3"

echo "ALL PASS ($pass_n checks, test-jsm-request)"
