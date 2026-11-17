#!/usr/bin/env bash
# Raise a Jira Service Management request, or add a public comment to one, as
# the human (a portal customer), through the servicedesk CUSTOMER API.
#
# Usage:
#   jsm-write.sh types   <desk>                       # request types (GET)
#   jsm-write.sh fields  <desk> <type>                # a type's fields and options (GET)
#   jsm-write.sh create  <desk> <type> --summary TEXT --description-file FILE [--field ID=VALUE]... [--send]
#   jsm-write.sh comment <KEY> --body-file FILE [--send]
#   jsm-write.sh transitions <KEY>                    # moves the desk offers you (GET)
#   jsm-write.sh transition  <KEY> --to NAME|ID [--comment-file FILE] [--send]
#
# <desk> is the service desk id (the N in /servicedesk/customer/portal/N);
# <type> is a request type id from `types`. Without --send nothing is
# written: the JSON that would be sent is printed. `create` refuses when one
# of your open requests on <desk> already has the same summary, so re-running
# after a lost response does not raise a duplicate. --field VALUE for an
# option field is its label (as `fields` prints it) or its id. `transition`
# (e.g. "Cancel request", "Resolve") refuses a request someone else raised
# any move the desk does not offer you, and any move whose name is not a
# close (cancel, close, resolve, withdraw, done); it never forces a status.
#
# Requires: curl, jq (the deployed copy is wrapped with both on PATH).
# Environment: ATLASSIAN_SITE, ATLASSIAN_EMAIL, ATLASSIAN_API_TOKEN.
# Credentials go to curl on stdin (--config -), never on argv.
#
# Exit: 0 ok (or dry run); 2 usage or bad field; 3 env missing; 4 HTTP 401;
#       5 other HTTP, transport or bad JSON; 6 duplicate open request;
#       7 HTTP 404; 8 HTTP 400 (the desk rejected the fields); 9 HTTP 403;
#       10 not a request you raised; 11 that transition is not offered to you;
#       12 that transition is not a close or cancel.
set -o errexit -o nounset -o pipefail

usage() { sed -n '6,11p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
die() { local rc="$1"; shift; echo "jsm-write: $*" >&2; exit "$rc"; }

[ $# -ge 2 ] || usage
for v in ATLASSIAN_SITE ATLASSIAN_EMAIL ATLASSIAN_API_TOKEN; do
  [ -n "${!v:-}" ] || die 3 "$v is not set"
done
API="https://$ATLASSIAN_SITE/rest/servicedeskapi"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# call <METHOD> <url> <outfile> [bodyfile]: returns per the exit table.
# A 400's errorMessage is printed so the caller sees why.
call() {
  local code esc
  local -a extra=()
  esc="$ATLASSIAN_EMAIL:$ATLASSIAN_API_TOKEN"
  esc="${esc//\\/\\\\}"; esc="${esc//\"/\\\"}"
  [ "$1" = GET ] || extra=(-X "$1" -H 'Content-Type: application/json' --data-binary "@$4")
  code="$(printf 'user = "%s"\n' "$esc" |
    curl -sS --config - -H 'Accept: application/json' "${extra[@]}" -o "$3" -w '%{http_code}' "$2")" ||
    { echo "jsm-write: transport error on $1 $2" >&2; return 5; }
  case "$code" in
    204) [ "${ALLOW_204:-0}" = 1 ] || { echo "jsm-write: unexpected HTTP 204 (no body) on $2" >&2; return 5; }; return 0 ;;
    2??) jq -e . "$3" >/dev/null 2>&1 || { echo "jsm-write: non-JSON response from $2" >&2; return 5; }; return 0 ;;
    400) echo "jsm-write: HTTP 400 on $2: $(jq -r '.errorMessage // .' "$3" 2>/dev/null || cat "$3")" >&2; return 8 ;;
    401) echo "jsm-write: HTTP 401 on $2: the token was refused (expired or revoked)" >&2; return 4 ;;
    403) echo "jsm-write: HTTP 403 on $2: $(jq -r '.errorMessage // empty' "$3" 2>/dev/null)" >&2; return 9 ;;
    404) echo "jsm-write: HTTP 404 on $2: no such service desk, request type or request" >&2; return 7 ;;
    *) echo "jsm-write: HTTP $code on $2" >&2; return 5 ;;
  esac
}

isnum() { [[ "$1" =~ ^[0-9]+$ ]] || die 2 "'$1' is not a numeric id"; }
checkfile() { [ -f "$1" ] && [ -s "$1" ] || die 2 "$1 is missing or empty"; }

cmd="$1"; shift
case "$cmd" in
types)
  [ $# -eq 1 ] || usage; isnum "$1"
  call GET "$API/servicedesk/$1/requesttype?limit=100" "$tmp/t.json" || exit $?
  [ "$(jq -r .isLastPage "$tmp/t.json")" = true ] || die 5 "more than 100 request types; listing incomplete"
  jq -r '.values[] | "\(.id)\t\(.name)"' "$tmp/t.json"
  ;;

fields)
  [ $# -eq 2 ] || usage; isnum "$1"; isnum "$2"
  call GET "$API/servicedesk/$1/requesttype/$2/field" "$tmp/f.json" || exit $?
  jq -r '.requestTypeFields[] |
    "\(.fieldId)\t\(if .required then "required" else "optional" end)\t\(.jiraSchema.type)\(if .jiraSchema.items then "<\(.jiraSchema.items)>" else "" end)\t\(.name)",
    (.validValues[]? | "    \(.value)\t\(.label)")' "$tmp/f.json"
  ;;

create)
  [ $# -ge 2 ] || usage; desk="$1"; type="$2"; shift 2; isnum "$desk"; isnum "$type"
  summary=""; descf=""; send=0; echo '{}' > "$tmp/given.json"
  while [ $# -gt 0 ]; do
    case "$1" in
      --summary) [ $# -ge 2 ] || usage; summary="$2"; shift 2 ;;
      --description-file) [ $# -ge 2 ] || usage; descf="$2"; shift 2 ;;
      --field) [ $# -ge 2 ] && [[ "$2" == ?*=* ]] || usage
        [ "$(jq --arg k "${2%%=*}" 'has($k)' "$tmp/given.json")" = false ] || die 2 "--field ${2%%=*} given twice"
        jq --arg k "${2%%=*}" --arg v "${2#*=}" '.[$k] = $v' "$tmp/given.json" > "$tmp/g2" || die 5 "could not record --field $2"
        mv "$tmp/g2" "$tmp/given.json"
        shift 2 ;;
      --send) send=1; shift ;;
      *) usage ;;
    esac
  done
  # Trimmed, as Jira stores it, so the duplicate guard compares like with like.
  summary="${summary#"${summary%%[![:space:]]*}"}"; summary="${summary%"${summary##*[![:space:]]}"}"
  [ -n "$summary" ] || die 2 "--summary is required"
  jq --arg s "$summary" '.summary = $s' "$tmp/given.json" > "$tmp/g2" || die 5 "could not record --summary"
  mv "$tmp/g2" "$tmp/given.json"
  if [ -n "$descf" ]; then
    checkfile "$descf"
    [ "$(jq 'has("description")' "$tmp/given.json")" = false ] || die 2 "description given twice"
    jq --rawfile d "$descf" '.description = $d' "$tmp/given.json" > "$tmp/g2" || die 2 "could not read $descf"
    mv "$tmp/g2" "$tmp/given.json"
  fi

  # Shape each value by the type's own field list; refuse anything it does not know.
  call GET "$API/servicedesk/$desk/requesttype/$type/field" "$tmp/f.json" || exit $?
  jq -n --slurpfile f "$tmp/f.json" --slurpfile g "$tmp/given.json" \
     --arg desk "$desk" --arg type "$type" '
    ($f[0].requestTypeFields | map({key: .fieldId, value: .}) | from_entries) as $defs
    | $g[0] as $given
    | ([$defs[] | select(.required and ($given[.fieldId] == null)) | .fieldId]) as $missing
    | if ($missing | length) > 0 then error("required field(s) not given: \($missing | join(", "))") else . end
    | {serviceDeskId: $desk, requestTypeId: $type, requestFieldValues: (
        $given | with_entries(
          .key as $k | .value as $v | ($defs[$k] // error("\($k) is not a field of request type \($type)")) as $d
          | (if ($d.validValues | length) > 0 then
               ([$d.validValues[] | select(.label == $v or .value == $v) | .value][0]
                 // error("\($v) is not an option of \($k) (\($d.name))")) as $id
               | if $d.jiraSchema.type == "array" then [{id: $id}] else {id: $id} end
             elif $d.jiraSchema.type == "string" then $v
             else error("\($k) has type \($d.jiraSchema.type), which this helper does not shape") end) as $out
          | .value = $out))}' > "$tmp/payload.json" 2> "$tmp/jqerr" ||
    die 2 "$(sed 's/^jq: error (at <unknown>): //' "$tmp/jqerr")"

  # Duplicate guard: an open request of yours on this desk with this exact
  # summary. Not searchTerm: a full summary with punctuation in it matches nothing.
  start=0; : > "$tmp/dups"
  while :; do
    call GET "$API/request?requestOwnership=OWNED_REQUESTS&requestStatus=OPEN_REQUESTS&serviceDeskId=$desk&start=$start&limit=50" "$tmp/l.json" || exit $?
    jq -r --arg s "$summary" '.values[] | select(.summary == $s) | "\(.issueKey) \(._links.web)"' "$tmp/l.json" >> "$tmp/dups"
    [ "$(jq -r .isLastPage "$tmp/l.json")" = true ] && break
    size="$(jq .size "$tmp/l.json")"; [ "$size" -gt 0 ] || die 5 "empty page before the last in the duplicate check"
    start=$((start + size)); [ "$start" -lt 1000 ] || die 5 "duplicate check did not finish"
  done
  [ ! -s "$tmp/dups" ] || die 6 "an open request of yours already has this summary: $(head -1 "$tmp/dups"). Comment on it instead."

  if [ "$send" -eq 0 ]; then
    jq . "$tmp/payload.json"
    echo "jsm-write: dry run; nothing sent. Add --send to raise it." >&2
    exit 0
  fi
  rc=0; call POST "$API/request" "$tmp/r.json" "$tmp/payload.json" || rc=$?
  [ "$rc" -ne 5 ] || echo "jsm-write: the request may still have been raised; run jsm-request.sh --list before retrying" >&2
  [ "$rc" -eq 0 ] || exit "$rc"
  jq -r '"\(.issueKey)\t\(._links.web)"' "$tmp/r.json"
  ;;

comment)
  key="$1"; shift; bodyf=""; send=0
  [[ "$key" =~ ^[A-Za-z][A-Za-z0-9_]*-[0-9]+$ ]] || die 2 "'$key' is not a request key"
  while [ $# -gt 0 ]; do
    case "$1" in
      --body-file) [ $# -ge 2 ] || usage; bodyf="$2"; shift 2 ;;
      --send) send=1; shift ;;
      *) usage ;;
    esac
  done
  [ -n "$bodyf" ] || die 2 "--body-file is required"
  checkfile "$bodyf"
  jq -n --rawfile b "$bodyf" '{body: $b, public: true}' > "$tmp/payload.json" || die 2 "could not read $bodyf"
  # Confirms the request exists and is yours to see before anything is sent.
  call GET "$API/request/$key" "$tmp/r.json" || exit $?
  if [ "$send" -eq 0 ]; then
    jq . "$tmp/payload.json"
    echo "jsm-write: dry run; nothing sent to $key. Add --send to post it." >&2
    exit 0
  fi
  rc=0; call POST "$API/request/$key/comment" "$tmp/c.json" "$tmp/payload.json" || rc=$?
  [ "$rc" -ne 5 ] || echo "jsm-write: the comment may still have been posted; read $key with jsm-request.sh before retrying (a retry is NOT refused)" >&2
  [ "$rc" -eq 0 ] || exit "$rc"
  jq -r --arg w "$(jq -r '._links.web' "$tmp/r.json")" '"comment \(.id) on \($w)"' "$tmp/c.json"
  ;;

transitions)
  key="$1"; [ $# -eq 1 ] || usage
  [[ "$key" =~ ^[A-Za-z][A-Za-z0-9_]*-[0-9]+$ ]] || die 2 "'$key' is not a request key"
  call GET "$API/request/$key/transition?limit=50" "$tmp/t.json" || exit $?
  [ "$(jq -r .isLastPage "$tmp/t.json")" = true ] || die 5 "more than 50 transitions; listing incomplete"
  jq -r '.values[] | "\(.id)\t\(.name)"' "$tmp/t.json"
  [ "$(jq '.values | length' "$tmp/t.json")" -gt 0 ] || echo "jsm-write: $key offers you no transitions" >&2
  ;;

transition)
  key="$1"; shift; to=""; bodyf=""; send=0
  [[ "$key" =~ ^[A-Za-z][A-Za-z0-9_]*-[0-9]+$ ]] || die 2 "'$key' is not a request key"
  while [ $# -gt 0 ]; do
    case "$1" in
      --to) [ $# -ge 2 ] || usage; to="$2"; shift 2 ;;
      --comment-file) [ $# -ge 2 ] || usage; bodyf="$2"; shift 2 ;;
      --send) send=1; shift ;;
      *) usage ;;
    esac
  done
  [ -n "$to" ] || die 2 "--to is required (a name or id from 'transitions $key')"
  [ -z "$bodyf" ] || checkfile "$bodyf"
  # Only a request the human raised: its reporter must be the token's owner.
  call GET "$API/request/$key" "$tmp/r.json" || exit $?
  call GET "https://$ATLASSIAN_SITE/rest/api/3/myself" "$tmp/me.json" || exit $?
  me="$(jq -r '.accountId // empty' "$tmp/me.json")"
  [ -n "$me" ] && [ "$(jq -r '.reporter.accountId // empty' "$tmp/r.json")" = "$me" ] ||
    die 10 "$key was not raised by you; this helper only moves your own requests"
  call GET "$API/request/$key/transition?limit=50" "$tmp/t.json" || exit $?
  id="$(jq -r --arg t "$to" '[.values[] | select(.id == $t or (.name | ascii_downcase) == ($t | ascii_downcase)) | .id][0] // empty' "$tmp/t.json")"
  [ -n "$id" ] || die 11 "'$to' is not offered on $key; offered: $(jq -r '[.values[] | "\(.id) \(.name)"] | if length == 0 then "none" else join(", ") end' "$tmp/t.json")"
  name="$(jq -r --arg id "$id" '.values[] | select(.id == $id) | .name' "$tmp/t.json")"
  [[ "${name,,}" =~ cancel|close|resolve|withdraw|done ]] ||
    die 12 "'$name' is not a close or cancel; this helper only closes requests"
  if [ -n "$bodyf" ]; then
    jq -n --arg id "$id" --rawfile b "$bodyf" '{id: $id, additionalComment: {body: $b}}' > "$tmp/payload.json" || die 2 "could not read $bodyf"
  else
    jq -n --arg id "$id" '{id: $id}' > "$tmp/payload.json"
  fi
  if [ "$send" -eq 0 ]; then
    jq . "$tmp/payload.json"
    echo "jsm-write: dry run; $key not moved (now: $(jq -r '.currentStatus.status // "?"' "$tmp/r.json")). Add --send to move it." >&2
    exit 0
  fi
  rc=0; ALLOW_204=1 call POST "$API/request/$key/transition" "$tmp/x.json" "$tmp/payload.json" || rc=$?
  [ "$rc" -ne 5 ] || echo "jsm-write: the request may still have moved; read $key with jsm-request.sh before retrying" >&2
  [ "$rc" -eq 0 ] || exit "$rc"
  status="?"; cat="?"
  if call GET "$API/request/$key" "$tmp/r2.json"; then
    status="$(jq -r '.currentStatus.status // "?"' "$tmp/r2.json")"; cat="$(jq -r '.currentStatus.statusCategory // "?"' "$tmp/r2.json")"
  fi
  [ "$cat" = DONE ] || echo "jsm-write: $key moved, but its status '$status' is not in the DONE category; it may still be open" >&2
  printf '%s\t%s\t%s\n' "$key" "$status" "$(jq -r '._links.web' "$tmp/r.json")"
  ;;

*) usage ;;
esac
