#!/usr/bin/env bash
# Read a Jira Service Management request through the servicedesk CUSTOMER API,
# which works when you are only a portal customer of the service desk (the
# platform API, the Atlassian MCP and nvim :FetchJiraTicket all answer 404).
#
# Usage:
#   jsm-request.sh <KEY | portal link | browse link> [--attachments DIR]
#   jsm-request.sh --list [open|closed|all]      # requests you raised
#
# Prints Markdown: status, request fields, every PUBLIC comment oldest first
# (the latest reply is LAST), and the attachment list. Read-only: every call is
# a GET. Credentials go to curl on stdin (--config -), never on argv.
#
# Requires: curl, jq. Environment: ATLASSIAN_SITE, ATLASSIAN_EMAIL,
# ATLASSIAN_API_TOKEN (exported on cloudbox and macOS by home-manager).
#
# Exit: 0 ok; 2 usage or link not on $ATLASSIAN_SITE; 3 env missing;
#       4 HTTP 401/403; 5 other HTTP, transport or bad JSON; 7 HTTP 404.
set -o errexit -o nounset -o pipefail

usage() { sed -n '6,8p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

[ $# -ge 1 ] || usage
for v in ATLASSIAN_SITE ATLASSIAN_EMAIL ATLASSIAN_API_TOKEN; do
  [ -n "${!v:-}" ] || { echo "jsm-request: $v is not set" >&2; exit 3; }
done
SITE="$ATLASSIAN_SITE"
BASE="https://$SITE"
API="$BASE/rest/servicedeskapi"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# get <url> <outfile>: GET with auth from stdin; returns per the exit table.
get() {
  local code esc
  esc="$ATLASSIAN_EMAIL:$ATLASSIAN_API_TOKEN"
  esc="${esc//\\/\\\\}"; esc="${esc//\"/\\\"}"
  code="$(printf 'user = "%s"\n' "$esc" |
    curl -sS --config - -L -H 'Accept: application/json' -o "$2" -w '%{http_code}' "$1")" ||
    { echo "jsm-request: transport error on $1" >&2; return 5; }
  case "$code" in
    2??) return 0 ;;
    401|403) echo "jsm-request: HTTP $code on $1 (token invalid, or no portal access)" >&2; return 4 ;;
    404) return 7 ;;
    *) echo "jsm-request: HTTP $code on $1" >&2; return 5 ;;
  esac
}

# getjson <url> <outfile>: get, then insist the body is JSON.
getjson() {
  get "$1" "$2" || return
  jq -e . "$2" >/dev/null 2>&1 || { echo "jsm-request: non-JSON response from $1" >&2; return 5; }
}

if [ "$1" = "--list" ]; then
  case "${2:-open}" in
    open) st=OPEN_REQUESTS ;; closed) st=CLOSED_REQUESTS ;; all) st=ALL_REQUESTS ;; *) usage ;;
  esac
  start=0
  while :; do
    getjson "$API/request?requestOwnership=OWNED_REQUESTS&requestStatus=$st&start=$start&limit=50" "$tmp/l.json" ||
      exit $?
    jq -r '.values[] | "- \(.issueKey) [\(.currentStatus.status)] \(.createdDate.iso8601[0:10]) \(.summary)\n  \(._links.web)"' "$tmp/l.json"
    [ "$(jq -r '.isLastPage' "$tmp/l.json")" = true ] && break
    start=$((start + $(jq '.size' "$tmp/l.json")))
    [ "$start" -lt 5000 ] || { echo "jsm-request: stopped at 5000 requests" >&2; break; }
  done
  exit 0
fi

arg="$1"; shift
dl=""
while [ $# -gt 0 ]; do
  case "$1" in
    --attachments) [ $# -ge 2 ] || usage; dl="$2"; shift 2 ;;
    *) usage ;;
  esac
done

# Accept a bare key, a portal link or a browse link (on this site only).
case "$arg" in
  https://*)
    host="${arg#https://}"; host="${host%%/*}"
    [ "$host" = "$SITE" ] || {
      echo "jsm-request: link is on $host, but the token is for $SITE; it cannot read that site" >&2; exit 2; }
    path="${arg#https://"$host"}"; path="${path%%[?#]*}"
    key="${path##*/}"
    ;;
  *) key="$arg" ;;
esac
[[ "$key" =~ ^[A-Za-z][A-Za-z0-9_]*-[0-9]+$ || "$key" =~ ^[0-9]+$ ]] ||
  { echo "jsm-request: '$arg' does not name a request key" >&2; exit 2; }

rc=0; getjson "$API/request/$key?expand=requestType" "$tmp/r.json" || rc=$?
if [ "$rc" -eq 7 ]; then
  echo "jsm-request: $key is not a portal request you can see (HTTP 404). It may be an ordinary Jira issue (use the Atlassian MCP), a request raised by someone else who did not add you as a participant, or a typo." >&2
  exit 7
fi
[ "$rc" -eq 0 ] || exit "$rc"

jq -r '
  "# \(.issueKey): \(.summary)",
  "",
  "- Status: \(.currentStatus.status) (\(.currentStatus.statusCategory), since \(.currentStatus.statusDate.iso8601))",
  "- Request type: \(.requestType.name // "?")",
  "- Raised: \(.createdDate.iso8601) by \(.reporter.displayName // "?")",
  "- Portal: \(._links.web)",
  "",
  "## Request fields",
  "",
  (.requestFieldValues[] | select(.fieldId != "summary") |
    "### \(.label)\n\n\(if (.value|type) == "string" then .value else (.value|tojson) end)\n")
' "$tmp/r.json"

echo "## Public comments (oldest first; the latest reply is last)"
echo
start=0; n=0
while :; do
  getjson "$API/request/$key/comment?public=true&internal=false&start=$start&limit=100" "$tmp/c.json" || exit $?
  jq -r '.values[] | select(.public == true) |
    "### \(.author.displayName // "?") at \(.created.iso8601) (comment \(.id))\n\n\(.body)\n"' "$tmp/c.json"
  size="$(jq '.size' "$tmp/c.json")"; n=$((n + size))
  [ "$(jq -r '.isLastPage' "$tmp/c.json")" = true ] && break
  [ "$size" -gt 0 ] || { echo "jsm-request: empty comment page before the last; stopping" >&2; exit 5; }
  start=$((start + size))
  [ "$start" -lt 10000 ] || { echo "jsm-request: stopped at 10000 comments" >&2; exit 5; }
done
[ "$n" -gt 0 ] || echo "(none)"
echo

echo "## Attachments"
echo
start=0; : > "$tmp/att.tsv"
while :; do
  getjson "$API/request/$key/attachment?start=$start&limit=100" "$tmp/a.json" || exit $?
  jq -r '.values[] | [.filename, .mimeType, (.size|tostring), ._links.content] | @tsv' "$tmp/a.json" >> "$tmp/att.tsv"
  [ "$(jq -r '.isLastPage' "$tmp/a.json")" = true ] && break
  size="$(jq '.size' "$tmp/a.json")"
  [ "$size" -gt 0 ] || break
  start=$((start + size))
  [ "$start" -lt 2000 ] || break
done
if [ ! -s "$tmp/att.tsv" ]; then echo "(none)"; exit 0; fi
while IFS=$'\t' read -r name mime size url; do
  echo "- $name ($mime, $size bytes)"
done < "$tmp/att.tsv"

[ -n "$dl" ] || exit 0
mkdir -p "$dl"
while IFS=$'\t' read -r name mime size url; do
  case "$url" in "$BASE"/*) ;; *) echo "jsm-request: skipping $name: content link is off-site" >&2; continue ;; esac
  safe="$(basename -- "$name")"; safe="${safe//[^A-Za-z0-9._-]/_}"
  case "$safe" in ""|.|..) safe="attachment" ;; esac
  get "$url" "$dl/$safe" || exit $?
  echo "saved $dl/$safe" >&2
done < "$tmp/att.tsv"
