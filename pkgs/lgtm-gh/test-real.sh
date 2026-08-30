#!/usr/bin/env bash
# Behavioural tests against the REAL shipped lgtm-gh binary.
#
# The sibling test.sh drives a COPY of the resolution logic, which flake.nix
# is careful to say is not production coverage: writeShellApplication prepends
# its runtimeInputs to PATH, so a fake `gh` on PATH loses to the pinned real
# one and the shipped wrapper cannot be intercepted from outside.
#
# This suite closes that gap for the artifact-ledger behaviour by building the
# wrapper with `pkgs.gh` OVERRIDDEN by a stub, so the binary under test is the
# one that ships, byte for byte, and the only substituted thing is the CLI it
# wraps. Every assertion here therefore exercises production.
#
# Usage: test-real.sh /nix/store/...-lgtm-gh/bin/lgtm-gh
set -o errexit -o nounset -o pipefail

wrapper="${1:?usage: test-real.sh <path-to-lgtm-gh>}"

pass=0
fail=0

assert_eq() {
  local expected="$1" actual="$2" msg="$3"
  if [ "$expected" = "$actual" ]; then
    printf 'PASS  %s\n' "$msg"; pass=$((pass + 1))
  else
    printf 'FAIL  %s\n        expected: %s\n        actual:   %s\n' "$msg" "$expected" "$actual"
    fail=$((fail + 1))
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" msg="$3"
  if grep -qF "$needle" <<<"$haystack"; then
    printf 'PASS  %s\n' "$msg"; pass=$((pass + 1))
  else
    printf 'FAIL  %s\n        wanted substring: %s\n        in:               %s\n' "$msg" "$needle" "$haystack"
    fail=$((fail + 1))
  fi
}

sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT

export HOME="$sandbox/home"
mkdir -p "$HOME/.config/lgtm/tokens"
printf 'ghp_krosantostoken\n' > "$HOME/.config/lgtm/tokens/Krosantos.pat"
chmod 600 "$HOME/.config/lgtm/tokens/Krosantos.pat"

worktree="$sandbox/worktree"
mkdir -p "$worktree"
cd "$worktree"
printf 'Krosantos\n' > "$worktree/.lgtm-reviewer"

ledger="$HOME/.local/state/lgtm/review-artifacts.jsonl"
export GH_RECORD="$sandbox/gh-record"

ledger_lines() { [ -f "$ledger" ] && wc -l < "$ledger" || echo 0; }

# 1. Identity still resolves and args still pass through verbatim, on the
#    ordinary (exec) path. If the ledger work broke this, nothing else matters.
rm -f "$GH_RECORD"
"$wrapper" pr review --approve 123 >/dev/null
assert_eq "GH_TOKEN=ghp_krosantostoken" "$(sed -n 1p "$GH_RECORD")" \
  "real binary: non-review call threads the resolved PAT"
assert_eq "ARGS=pr review --approve 123" "$(sed -n 2p "$GH_RECORD")" \
  "real binary: non-review call passes args verbatim"
assert_eq "0" "$(ledger_lines)" "real binary: non-review call records nothing"

# 2. A review POST records id, kind and acting login.
rm -f "$ledger"
FAKE_GH_BODY='{"id":998877,"state":"COMMENTED"}' \
  "$wrapper" api -X POST repos/food-truck/mono/pulls/42/reviews -f event=COMMENT >/dev/null
assert_eq "1" "$(ledger_lines)" "real binary: review POST writes exactly one line"
assert_eq "998877" "$(jq -r .id < "$ledger")" "real binary: records the artifact id"
assert_eq "review" "$(jq -r .kind < "$ledger")" "real binary: kind=review"
assert_eq "Krosantos" "$(jq -r .login < "$ledger")" "real binary: records acting login"

# 3. stdout replayed byte-for-byte. The agent parses this response; a wrapper
#    that mangles it breaks review posting itself.
out="$(FAKE_GH_BODY='{"id":11,"body":"hi"}' \
  "$wrapper" api -X POST repos/food-truck/mono/pulls/42/reviews -f event=COMMENT)"
assert_eq '{"id":11,"body":"hi"}' "$out" "real binary: stdout passed through verbatim"

# 4. Failure preserves gh's exit code and records nothing. An artifact that was
#    never created must not be claimed; every id it could match is someone else's.
rm -f "$ledger"
FAKE_GH_RC=22 FAKE_GH_BODY='{"message":"Validation Failed"}' \
  "$wrapper" api -X POST repos/food-truck/mono/pulls/42/reviews -f event=COMMENT >/dev/null && rc=0 || rc=$?
assert_eq "22" "$rc" "real binary: failed POST preserves gh exit code"
assert_eq "0" "$(ledger_lines)" "real binary: failed POST records nothing"

# 5. Unparseable response never fails the call, and stays unrecorded -- which
#    downstream reads as a human. Failing toward human is the design rule.
rm -f "$ledger"
err="$(FAKE_GH_BODY='not json at all' \
  "$wrapper" api -X POST repos/food-truck/mono/pulls/42/reviews -f event=COMMENT 2>&1 1>/dev/null)" && rc=0 || rc=$?
assert_eq "0" "$rc" "real binary: unparseable response still succeeds"
assert_contains "$err" "reads as human" "real binary: warns and names the safe direction"
assert_eq "0" "$(ledger_lines)" "real binary: unparseable response records nothing"

# 6. A GET against a review endpoint is a read, not an artifact.
rm -f "$ledger"
FAKE_GH_BODY='{"id":555}' "$wrapper" api repos/food-truck/mono/pulls/42/reviews >/dev/null
assert_eq "0" "$(ledger_lines)" "real binary: GET on review endpoint records nothing"

# 7. `gh api` implies POST once a field is present. The prompt tells agents to
#    reply to threads in exactly that form, so an -X-only test would miss them.
rm -f "$ledger"
FAKE_GH_BODY='{"id":4242}' \
  "$wrapper" api repos/food-truck/mono/pulls/comments/77/replies -f body=ack >/dev/null
assert_eq "4242" "$(jq -r .id < "$ledger")" "real binary: implicit POST (-f, no -X) recorded"
assert_eq "reply" "$(jq -r .kind < "$ledger")" "real binary: replies endpoint -> kind=reply"

# 8. Misconfiguration still hard-errors before any gh call.
rm -f "$worktree/.lgtm-reviewer"
err="$("$wrapper" api -X POST repos/food-truck/mono/pulls/42/reviews -f event=COMMENT 2>&1 1>/dev/null)" && rc=0 || rc=$?
assert_eq "1" "$rc" "real binary: missing .lgtm-reviewer still exits 1"
assert_contains "$err" "missing" "real binary: missing .lgtm-reviewer names the problem"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
echo "all lgtm-gh real-binary tests passed"
