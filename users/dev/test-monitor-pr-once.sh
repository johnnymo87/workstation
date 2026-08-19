#!/usr/bin/env bash
# Guard: `monitor-pr.py --once` performs exactly ONE evaluation pass and never
# sleeps. The watchdog in the shepherding skill depends on this -- a wake that
# blocks for a full budget defeats the point of sleeping in the first place.
set -euo pipefail

SCRIPT="assets/opencode/skills/shepherding-pull-requests/monitor-pr.py"
[ -f "$SCRIPT" ] || { echo "FAIL: $SCRIPT not found (run from repo root)"; exit 1; }

stub=$(mktemp -d)
trap 'rm -rf "$stub"' EXIT

# `gh` stub: enough shape for get_pr_info / check_ci / reviews / threads.
# CI reports pending, which is the idle path -- the one that would sleep.
# GraphQL reviewThreads returns empty nodes with pageInfo to satisfy pagination check.
printf '#!%s\n' "$(command -v bash)" > "$stub/gh"
cat >> "$stub/gh" <<'STUB'
case "$*" in
  *"pr checks"*) echo '[{"name":"build","state":"IN_PROGRESS","bucket":"pending"}]' ;;
  *"pr view"*) echo '{"number":1,"url":"https://github.com/o/r/pull/1","baseRefName":"main","headRefName":"topic","author":{"login":"someone"}}' ;;
  *graphql*) echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}}' ;;
  *) echo '[]' ;;
esac
STUB
chmod +x "$stub/gh"

start=$(date +%s)
set +e
# Explicitly pass `--lgtm-bound no` for determinism (avoids depending on ~/projects/lgtm/lgtm.yml)
out=$(PATH="$stub:$PATH" python3 "$SCRIPT" --once --lgtm-bound no 1 2>&1)
code=$?
set -e
elapsed=$(( $(date +%s) - start ))

fail=0

if ! grep -q -- "--- iteration 1 ---" <<<"$out"; then
  echo "FAIL: no iteration ran"; fail=1
fi

if grep -q -- "--- iteration 2 ---" <<<"$out"; then
  echo "FAIL: --once ran more than one iteration"; fail=1
fi

if [ "$elapsed" -ge 10 ]; then
  echo "FAIL: --once slept (${elapsed}s); it must not"; fail=1
fi

# Idle CI must surface as the still-waiting code, not a false 'done'.
if [ "$code" -ne 3 ]; then
  echo "FAIL: expected exit 3 (still waiting) on pending CI, got $code"; fail=1
fi

# The trailing guidance must not tell a watchdog wake to re-invoke in a loop.
if grep -q "Re-invoke this script to keep polling" <<<"$out"; then
  echo "FAIL: --once printed the polling-loop guidance"; fail=1
fi

[ "$fail" -eq 0 ] || { echo "--- output ---"; echo "$out"; exit 1; }
echo "PASS: monitor-pr.py --once is single-pass, non-sleeping, exit-3 on idle"
