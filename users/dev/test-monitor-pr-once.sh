#!/usr/bin/env bash
# Guard: `monitor-pr.py --once` performs exactly ONE evaluation pass and never
# sleeps. The watchdog in the shepherding skill depends on this -- a wake that
# blocks for a full budget defeats the point of sleeping in the first place.
set -euo pipefail

SCRIPT="assets/opencode/skills/shepherding-pull-requests/monitor-pr.py"
[ -f "$SCRIPT" ] || { echo "FAIL: $SCRIPT not found (run from repo root)"; exit 1; }

stub=$(mktemp -d)
trap 'rm -rf "$stub"' EXIT

# Helper to generate a `gh` stub for a given CI payload and PR state.
# GraphQL reviewThreads returns empty nodes with pageInfo to satisfy pagination check.
make_stub() {
  local ci_json="$1"
  local pr_state="$2"

  printf '#!%s\n' "$(command -v bash)" > "$stub/gh"
  cat >> "$stub/gh" <<STUB
case "\$*" in
  *"pr checks"*) cat <<'CI_EOF'
$ci_json
CI_EOF
  ;;
  *"pr view"*) cat <<'PR_EOF'
{"number":1,"url":"https://github.com/o/r/pull/1","state":"$pr_state","baseRefName":"main","headRefName":"topic","author":{"login":"someone"}}
PR_EOF
  ;;
  *graphql*) echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}}' ;;
  *) echo '[]' ;;
esac
STUB
  chmod +x "$stub/gh"
}

fail=0

# Case 1: CI pending, PR open, no reviews -> exit 4 (CI moving / not yet settled)
make_stub '[{"name":"build","state":"IN_PROGRESS","bucket":"pending"}]' "OPEN"
start=$(date +%s)
set +e
out=$(PATH="$stub:$PATH" python3 "$SCRIPT" --once --lgtm-bound no 1 2>&1)
code=$?
set -e
elapsed=$(( $(date +%s) - start ))

if ! grep -q -- "--- iteration 1 ---" <<<"$out"; then
  echo "FAIL [case 1]: no iteration ran"; fail=1
fi

if grep -q -- "--- iteration 2 ---" <<<"$out"; then
  echo "FAIL [case 1]: --once ran more than one iteration"; fail=1
fi

if [ "$elapsed" -ge 10 ]; then
  echo "FAIL [case 1]: --once slept (${elapsed}s); it must not"; fail=1
fi

if [ "$code" -ne 4 ]; then
  echo "FAIL [case 1]: expected exit 4 (CI moving) on pending CI, got $code"; fail=1
fi

if grep -q "Re-invoke this script to keep polling" <<<"$out"; then
  echo "FAIL [case 1]: --once printed the polling-loop guidance"; fail=1
fi

# Case 2: CI green, PR open, no reviews, --lgtm-bound yes -> exit 3 (waiting on reviewer approval)
make_stub '[{"name":"build","state":"SUCCESS","bucket":"pass"}]' "OPEN"
start=$(date +%s)
set +e
out=$(PATH="$stub:$PATH" python3 "$SCRIPT" --once --lgtm-bound yes 1 2>&1)
code=$?
set -e
elapsed=$(( $(date +%s) - start ))

if ! grep -q -- "--- iteration 1 ---" <<<"$out"; then
  echo "FAIL [case 2]: no iteration ran"; fail=1
fi

if grep -q -- "--- iteration 2 ---" <<<"$out"; then
  echo "FAIL [case 2]: --once ran more than one iteration"; fail=1
fi

if [ "$elapsed" -ge 10 ]; then
  echo "FAIL [case 2]: --once slept (${elapsed}s); it must not"; fail=1
fi

if [ "$code" -ne 3 ]; then
  echo "FAIL [case 2]: expected exit 3 (waiting on reviewer) on green CI with lgtm-bound yes, got $code"; fail=1
fi

if grep -q "Re-invoke this script to keep polling" <<<"$out"; then
  echo "FAIL [case 2]: --once printed the polling-loop guidance"; fail=1
fi

# Case 3: PR state CLOSED -> exit 2, stdout/stderr mentions closed without merging
make_stub '[{"name":"build","state":"SUCCESS","bucket":"pass"}]' "CLOSED"
start=$(date +%s)
set +e
out=$(PATH="$stub:$PATH" python3 "$SCRIPT" --once --lgtm-bound no 1 2>&1)
code=$?
set -e
elapsed=$(( $(date +%s) - start ))

if [ "$code" -ne 2 ]; then
  echo "FAIL [case 3]: expected exit 2 on closed PR, got $code"; fail=1
fi

if ! grep -qi "closed without merging" <<<"$out"; then
  echo "FAIL [case 3]: expected output to mention 'closed without merging', got: $out"; fail=1
fi

# Case 4: PR state MERGED -> exit 0, stdout/stderr mentions merged / complete
make_stub '[{"name":"build","state":"SUCCESS","bucket":"pass"}]' "MERGED"
start=$(date +%s)
set +e
out=$(PATH="$stub:$PATH" python3 "$SCRIPT" --once --lgtm-bound no 1 2>&1)
code=$?
set -e
elapsed=$(( $(date +%s) - start ))

if [ "$code" -ne 0 ]; then
  echo "FAIL [case 4]: expected exit 0 on merged PR, got $code"; fail=1
fi

if ! grep -qi "merged" <<<"$out"; then
  echo "FAIL [case 4]: expected output to mention 'merged', got: $out"; fail=1
fi

[ "$fail" -eq 0 ] || { echo "--- output ---"; echo "$out"; exit 1; }
echo "PASS: monitor-pr.py --once correctly handles moving CI (exit 4), waiting on reviewer (exit 3), closed PR (exit 2), and merged PR (exit 0)"
