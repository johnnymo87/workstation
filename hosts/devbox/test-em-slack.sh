#!/usr/bin/env bash
# Tests for em-slack.sh (slack_send, shared by the three em-* monitors), with a
# fake curl: no network. Runs in the nix sandbox (flake check em-slack-tests).
# shellcheck disable=SC2016
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
pass=0; fail=0
check() { if eval "$2"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; fi; }

bash_bin=$(command -v bash)
hook='https://hooks.slack.com/services/T0AAA/B0BBB/sEcReT123'

setup() { # fresh sandbox per case
  S=$(mktemp -d); export CREDENTIALS_DIRECTORY=$S/cred EM_SLACK_OWNER_ID=U0OWNER1
  unset PIGEON_SLACK_NOTIFY_OWNER
  mkdir -p "$CREDENTIALS_DIRECTORY" "$S/bin"
  echo "$hook" >"$CREDENTIALS_DIRECTORY/slack_webhook"
  # Fake curl: records argv (one arg per line) and stdin; fails while $S/down exists.
  cat >"$S/bin/curl" <<EOF
#!$bash_bin
printf '%s\n' "\$@" >>"$S/curl.args"
cat >>"$S/curl.in"
[ ! -e "$S/down" ] || exit 22
EOF
  chmod +x "$S/bin/curl"
}
# Each send runs in a fresh `set -euo pipefail` bash, as writeShellApplication
# would run it, with the fake curl first on PATH.
send() { # $1: text. Sets rc.
  rc=0
  PATH="$S/bin:$PATH" "$bash_bin" -c 'set -euo pipefail; . "$1"; slack_send "$2"' _ "$here/em-slack.sh" "$1" \
    2>"$S/err" || rc=$?
}
payload() { # the --data-binary argument curl received
  awk 'p { print; exit } $0 == "--data-binary" { p = 1 }' "$S/curl.args"
}

# 1. The happy path.
setup; send 'em-ci (CI runners): problem
- 2 job(s) queued >= 20 min & <idle>'
check "delivers: exit 0" '[ "$rc" -eq 0 ]'
check "webhook URL reaches curl on stdin only" \
  'grep -qx "url = \"$hook\"" "$S/curl.in" && ! grep -q "sEcReT123" "$S/curl.args" && ! grep -q "hooks.slack.com" "$S/curl.args"'
check "posts JSON" 'grep -qx "Content-Type: application/json" "$S/curl.args" && payload | jq -e . >/dev/null'
check "no mention by default (no pushes, D7)" '[ "$(payload | jq -r .text | head -n 1)" = "em-ci (CI runners): problem" ]'
check "escapes & < > (Slack markup), keeps newlines" \
  '[ "$(payload | jq -r .text | sed -n 2p)" = "- 2 job(s) queued &gt;= 20 min &amp; &lt;idle&gt;" ]'
check "no link or media unfurls" '[ "$(payload | jq -c "[.unfurl_links, .unfurl_media]")" = "[false,false]" ]'
check "fails on HTTP errors, keeping Slack's error body" 'grep -qx -- "--fail-with-body" "$S/curl.args" && ! grep -qx -- "-o" "$S/curl.args"'

# 2. Delivery failure is a non-zero return.
setup; touch "$S/down"; send "x"
check "curl failure: non-zero" '[ "$rc" -ne 0 ]'

# 3. The credential must be a hooks.slack.com webhook, or nothing is sent.
for bad in 'https://example.com/services/T0/B0/x' 'http://hooks.slack.com/services/T0/B0/x' \
           'https://hooks.slack.com.evil.example/services/T0/B0/x' 'https://hooks.slack.com/services/T0/B0/x"' \
           'https://hooks.slack.com/services/T0/B0/x
url = "https://example.com/"' ''; do
  setup; printf '%s\n' "$bad" >"$CREDENTIALS_DIRECTORY/slack_webhook"; send "x"
  check "rejects webhook credential [$bad]" '[ "$rc" -ne 0 ] && [ ! -e "$S/curl.args" ] && grep -q "not a https://hooks.slack.com" "$S/err"'
done
setup; printf '%s \r\n\n' "$hook" >"$CREDENTIALS_DIRECTORY/slack_webhook"; send "x"
check "a pasted trailing space/CR is trimmed" '[ "$rc" -eq 0 ] && grep -qx "url = \"$hook\"" "$S/curl.in"'
setup; rm "$CREDENTIALS_DIRECTORY/slack_webhook"; send "x"
check "missing credential: non-zero, nothing sent" '[ "$rc" -ne 0 ] && [ ! -e "$S/curl.args" ]'

# 4. PIGEON_SLACK_NOTIFY_OWNER=1 mentions the owner first; without a usable
#    owner id it refuses (a post meant to push that pushes nobody is silent).
setup; PIGEON_SLACK_NOTIFY_OWNER=1 send "a & b"
check "notify on: mentions the owner first" '[ "$rc" -eq 0 ] && [ "$(payload | jq -r .text)" = "<@U0OWNER1> a &amp; b" ]'
for v in 0 yes true; do
  setup; PIGEON_SLACK_NOTIFY_OWNER=$v send "x"
  check "notify [$v] is not 1: no mention" '[ "$rc" -eq 0 ] && [ "$(payload | jq -r .text)" = "x" ]'
done
for bad in '' 'jonathan' 'U0OWNER1> <!channel'; do
  setup; PIGEON_SLACK_NOTIFY_OWNER=1 EM_SLACK_OWNER_ID=$bad send "x"
  check "notify on: rejects owner id [$bad]" '[ "$rc" -ne 0 ] && [ ! -e "$S/curl.args" ]'
done
setup; EM_SLACK_OWNER_ID='' send "x"
check "notify off: no owner id needed" '[ "$rc" -eq 0 ] && [ "$(payload | jq -r .text)" = "x" ]'

[ "$fail" -eq 0 ] || { echo "FAILED $fail"; exit 1; }
echo "ALL PASS ($pass assertions)"
