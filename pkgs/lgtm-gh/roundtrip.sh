#!/usr/bin/env bash
# Round trip of the approval gate (lgtm-f6ue) against the LIVE lgtm on cloudbox.
#
# test.sh swaps the GATE PINS block for a sandbox, and the nix checks cannot
# reach /home/dev/projects/lgtm, so neither can prove the one thing that bricks
# every approve if it is wrong: that the pinned environment, handed to the REAL
# `lgtm --approval-policy`, comes back with payload.config.path/stateDir equal
# to the pins (lgtm-dwic item 6). This does: it runs the SHIPPED source, pin
# block and all, against the real lgtm checkout. Only `gh` is faked (so nothing
# is ever posted) and HOME is a temp dir (so the real ledger is not touched).
#
# It then feeds the ledger lines the wrapper wrote through lgtm's OWN reader,
# parseGateRefusals, because the reader drops invalid lines silently.
#
# Not a flake check (the sandbox has no lgtm checkout). Run on cloudbox before
# merging and after the home-manager switch:
#
#   bash pkgs/lgtm-gh/roundtrip.sh <mono-PR> <its live head, with a clear verdict> \
#     [<blocked mono-PR> <its head>]
#
# Finding a clear PR: an open food-truck/mono PR whose live head has a verdict
# file ~/.local/state/lgtm/verdicts/food-truck__mono-<N>-<head>.json, e.g.
#   gh pr list --repo food-truck/mono --json number,headRefOid \
#     -q '.[] | "\(.number) \(.headRefOid)"' | while read n h; do
#     [ -f ~/.local/state/lgtm/verdicts/food-truck__mono-$n-$h.json ] && echo "$n $h"; done
#
# Exit 77 (skip) when there is no lgtm checkout here.
set -o errexit -o nounset -o pipefail

pr="${1:?usage: roundtrip.sh <mono-PR> <clear-head>}"
clear_head="${2:?usage: roundtrip.sh <mono-PR> <clear-head>}"
lgtm_dir="/home/dev/projects/lgtm"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ ! -d "$lgtm_dir/node_modules/tsx" ]; then
  echo "SKIP  no lgtm checkout at $lgtm_dir"
  exit 77
fi
command -v node >/dev/null || { echo "FAIL  node not on PATH"; exit 1; }

pass=0
fail=0
assert_eq() {
  if [ "$1" = "$2" ]; then printf 'PASS  %s\n' "$3"; pass=$((pass + 1))
  else printf 'FAIL  %s\n        expected: %s\n        actual:   %s\n' "$3" "$1" "$2"; fail=$((fail + 1)); fi
}

sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT
export HOME="$sandbox/home"
mkdir -p "$HOME/.config/lgtm/tokens" "$sandbox/bin" "$sandbox/wt"
printf 'ghp_fake\n' > "$HOME/.config/lgtm/tokens/jamesvec.pat"
printf 'jamesvec\n' > "$sandbox/wt/.lgtm-reviewer"
record="$sandbox/gh-record"
cat > "$sandbox/bin/gh" <<EOF
#!$BASH
if [ "\$1" = api ] && [[ "\$2" =~ ^repos/[^/]+/[^/]+/pulls/[0-9]+\$ ]] && [ "\${3:-}" = --jq ]; then
  printf '%s\n' "\$FAKE_PR_LINE"; exit 0
fi
printf 'ARGS=%s\n' "\$*" > "$record"
printf '{"id":1}'
EOF
chmod +x "$sandbox/bin/gh"
export PATH="$sandbox/bin:$PATH"
cd "$sandbox/wt"
refusals="$HOME/.local/state/lgtm/gate-refusals.jsonl"
fake_head="$(printf 'b%.0s' $(seq 40))"

# 1. A clear mono head: allowed, and pinned to that head.
rm -f "$record"
FAKE_PR_LINE="$clear_head food-truck/mono" \
  bash "$script_dir/lgtm-gh.sh" api -X POST "repos/food-truck/mono/pulls/$pr/reviews" -f event=APPROVE >/dev/null 2>"$sandbox/err" \
  && rc=0 || rc=$?
assert_eq "0" "$rc" "live: clear mono#$pr is allowed (pins match lgtm's config echo)"
[ "$rc" -eq 0 ] || sed 's/^/        /' "$sandbox/err"
assert_eq "ARGS=api -X POST repos/food-truck/mono/pulls/$pr/reviews -f event=APPROVE -f commit_id=$clear_head" \
  "$(cat "$record" 2>/dev/null)" "live: the allowed APPROVE is pinned to the checked head"

# 2. The same PR at a head lgtm never checked: refused as plumbing, recorded.
rm -f "$record"
FAKE_PR_LINE="$fake_head food-truck/mono" \
  bash "$script_dir/lgtm-gh.sh" api -X POST "repos/food-truck/mono/pulls/$pr/reviews" -f event=APPROVE >/dev/null 2>"$sandbox/err" \
  && rc=0 || rc=$?
assert_eq "5" "$rc" "live: an unchecked head is refused with exit 5"
assert_eq "lgtm-gh: refusing to approve" "$(head -c 28 "$sandbox/err")" "live: the refusal starts with the marker"
assert_eq "no" "$([ -f "$record" ] && echo yes || echo no)" "live: nothing was sent"

# 3. An ungoverned repo: allowed, argv untouched.
rm -f "$record"
FAKE_PR_LINE="$fake_head blueapron/internal-frontends" \
  bash "$script_dir/lgtm-gh.sh" api -X POST repos/blueapron/internal-frontends/pulls/1/reviews -f event=APPROVE >/dev/null 2>"$sandbox/err" \
  && rc=0 || rc=$?
assert_eq "0" "$rc" "live: an ungoverned repo is allowed"
assert_eq "ARGS=api -X POST repos/blueapron/internal-frontends/pulls/1/reviews -f event=APPROVE" \
  "$(cat "$record" 2>/dev/null)" "live: ungoverned argv is untouched"

# 3b. Optionally, a BLOCKED head: lgtm's own policy refusal, exit 3.
if [ -n "${3:-}" ] && [ -n "${4:-}" ]; then
  rm -f "$record"
  FAKE_PR_LINE="$4 food-truck/mono" \
    bash "$script_dir/lgtm-gh.sh" api -X POST "repos/food-truck/mono/pulls/$3/reviews" -f event=APPROVE >/dev/null 2>"$sandbox/err" \
    && rc=0 || rc=$?
  assert_eq "3" "$rc" "live: blocked mono#$3 is refused as policy (exit 3)"
  assert_eq "no" "$([ -f "$record" ] && echo yes || echo no)" "live: nothing was sent for the blocked head"
  sed 's/^/        | /' "$sandbox/err"
fi

# 4. A wrapper fallback line too, so both writer shapes reach the reader.
FAKE_PR_LINE="$clear_head food-truck/mono" \
  bash "$script_dir/lgtm-gh.sh" pr review "$pr" --repo food-truck/mono --approve >/dev/null 2>&1 || true

# 5. lgtm's own reader accepts every line the wrapper wrote.
parsed="$(cd "$lgtm_dir" && node node_modules/tsx/dist/cli.mjs -e "
  import { readFileSync } from 'node:fs';
  import { parseGateRefusals } from './src/gateRefusalAlert.ts';
  const p = parseGateRefusals(readFileSync(process.argv[1], 'utf8'));
  console.log(p.records.length + ' ' + p.invalidLines);
" "$refusals")"
want_lines="$(wc -l < "$refusals" | tr -d ' ')"
assert_eq "$want_lines 0" "$parsed" "live: lgtm's parseGateRefusals reads every line, none invalid"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
echo "all lgtm-gh round-trip tests passed"
