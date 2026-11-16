#!/usr/bin/env bash
# Read a Jira Service Management request through the servicedesk CUSTOMER API,
# which works when you are only a portal customer of the service desk (the
# platform API, the Atlassian MCP and nvim :FetchJiraTicket all answer 404).
#
# Usage:
#   jsm-request.sh <KEY | portal link | browse link> [--attachments DIR]
#   jsm-request.sh --list [open|closed|all] [--participated]
#
# Prints Markdown: status, request fields, every PUBLIC comment oldest first
# (the latest reply is LAST), and the attachment list. Nothing is printed
# unless every page was read. Read-only: every call is a GET. Credentials go
# to curl on stdin (--config -), never on argv.
#
# Requires: curl, jq (the deployed copy is wrapped with both on PATH).
# Environment: ATLASSIAN_SITE, ATLASSIAN_EMAIL, ATLASSIAN_API_TOKEN.
#
# Exit: 0 ok; 2 usage or link not on $ATLASSIAN_SITE; 3 env missing;
#       4 HTTP 401 (token refused); 5 other HTTP, transport, bad JSON or an
#       incomplete listing; 7 HTTP 404; 9 HTTP 403 (no permission).
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

# get <url> <outfile> [accept]: GET with auth from stdin; returns per the exit
# table. curl does not resend `user` credentials to another host on a redirect.
get() {
  local code esc
  esc="$ATLASSIAN_EMAIL:$ATLASSIAN_API_TOKEN"
  esc="${esc//\\/\\\\}"; esc="${esc//\"/\\\"}"
  code="$(printf 'user = "%s"\n' "$esc" |
    curl -sS --config - -L -H "Accept: ${3:-application/json}" -o "$2" -w '%{http_code}' "$1")" ||
    { echo "jsm-request: transport error on $1" >&2; return 5; }
  case "$code" in
    2??) return 0 ;;
    401) echo "jsm-request: HTTP 401 on $1: the token was refused (expired or revoked)" >&2; return 4 ;;
    403) return 9 ;;
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
  shift
  st=OPEN_REQUESTS; own=OWNED_REQUESTS
  while [ $# -gt 0 ]; do
    case "$1" in
      open) st=OPEN_REQUESTS ;; closed) st=CLOSED_REQUESTS ;; all) st=ALL_REQUESTS ;;
      --participated) own=PARTICIPATED_REQUESTS ;;
      *) usage ;;
    esac
    shift
  done
  start=0; : > "$tmp/out"
  while :; do
    rc=0; getjson "$API/request?requestOwnership=$own&requestStatus=$st&start=$start&limit=50" "$tmp/l.json" || rc=$?
    [ "$rc" -eq 0 ] || { [ "$rc" -eq 9 ] || [ "$rc" -eq 7 ] && echo "jsm-request: listing refused (HTTP 403/404)" >&2; exit "$rc"; }
    jq -r '.values[] | "- \(.issueKey) [\(.currentStatus.status)] \(.createdDate.iso8601[0:10]) \(.summary)\n  \(._links.web)"' "$tmp/l.json" >> "$tmp/out"
    [ "$(jq -r '.isLastPage' "$tmp/l.json")" = true ] && break
    size="$(jq '.size' "$tmp/l.json")"
    [ "$size" -gt 0 ] || { echo "jsm-request: empty page before the last; listing incomplete" >&2; exit 5; }
    start=$((start + size))
    [ "$start" -lt 5000 ] || { echo "jsm-request: more than 5000 requests; listing incomplete" >&2; exit 5; }
  done
  [ -s "$tmp/out" ] && cat "$tmp/out" || echo "(none)"
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
    [[ "$key" =~ ^[A-Za-z][A-Za-z0-9_]*-[0-9]+$ ]] ||
      { echo "jsm-request: '$arg' does not end in a request key (a portal home link names none)" >&2; exit 2; }
    ;;
  *) key="$arg" ;;
esac
# A bare number is accepted as the request's issue id.
[[ "$key" =~ ^[A-Za-z][A-Za-z0-9_]*-[0-9]+$ || "$key" =~ ^[0-9]+$ ]] ||
  { echo "jsm-request: '$arg' does not name a request key" >&2; exit 2; }

rc=0; getjson "$API/request/$key?expand=requestType" "$tmp/r.json" || rc=$?
if [ "$rc" -eq 7 ]; then
  echo "jsm-request: $key is not a service-desk request (HTTP 404): an ordinary Jira issue (the Atlassian MCP reads those, if you can see it) or a typo." >&2
  exit 7
fi
if [ "$rc" -eq 9 ]; then
  echo "jsm-request: $key is a request you have no permission to view (HTTP 403): someone else raised it and you are not a participant." >&2
  exit 9
fi
[ "$rc" -eq 0 ] || exit "$rc"

# Everything goes to $tmp/out and is printed only once every page has been
# read, so a failure part-way never leaves a partial list that looks complete.
exec 3>&1 1>"$tmp/out"

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
  [ "$size" -gt 0 ] || { echo "jsm-request: empty comment page before the last" >&2; exit 5; }
  start=$((start + size))
  [ "$start" -lt 10000 ] || { echo "jsm-request: more than 10000 comments" >&2; exit 5; }
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
  [ "$size" -gt 0 ] || { echo "jsm-request: empty attachment page before the last" >&2; exit 5; }
  start=$((start + size))
  [ "$start" -lt 2000 ] || { echo "jsm-request: more than 2000 attachments" >&2; exit 5; }
done
if [ ! -s "$tmp/att.tsv" ]; then
  echo "(none)"
else
  while IFS=$'\t' read -r name mime size url; do
    echo "- $name ($mime, $size bytes)"
  done < "$tmp/att.tsv"
fi

exec 1>&3 3>&-
cat "$tmp/out"

[ -n "$dl" ] && [ -s "$tmp/att.tsv" ] || exit 0
mkdir -p "$dl"
n=0
while IFS=$'\t' read -r name mime size url; do
  n=$((n + 1))
  case "$url" in "$BASE"/*) ;; *) echo "jsm-request: skipping $name: content link is off-site" >&2; continue ;; esac
  safe="$(basename -- "$name")"; safe="${safe//[^A-Za-z0-9._-]/_}"
  case "$safe" in ""|.|..) safe="attachment" ;; esac
  # Numbered, so two attachments with one name (or a reused DIR) never collide.
  dest="$dl/$n-$safe"
  get "$url" "$dest" '*/*' || { echo "jsm-request: download of $name failed" >&2; exit 5; }
  echo "saved $dest" >&2
done < "$tmp/att.tsv"
