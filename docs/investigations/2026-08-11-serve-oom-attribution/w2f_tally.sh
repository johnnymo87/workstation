#!/usr/bin/env bash
# workstation-yvxh.14 (W2f): clean tally of ACTUAL oom kills.
# A kill is "oom-kill:constraint=" (carries oom_memcg) paired with
# "Out of memory: Killed process". Everything else in the journal --
# "invoked oom-killer" (an attempt) and "no killable processes" (a failed
# attempt) -- is NOT a kill and must not be counted as one.
set -uo pipefail
F=/tmp/opencode/w2f_oom.txt

echo "=== window ==="
head -1 "$F" | cut -c1-25
tail -1 "$F" | cut -c1-25

echo
echo "=== line taxonomy (why the raw grep count is misleading) ==="
printf '  invoked oom-killer (attempt)      : %s\n' "$(grep -c 'invoked oom-killer' "$F")"
printf '  no killable processes (failed)    : %s\n' "$(grep -c 'no killable processes' "$F")"
printf '  oom-kill:constraint (REAL kill)   : %s\n' "$(grep -c 'oom-kill:constraint' "$F")"
printf '  Killed process (REAL kill)        : %s\n' "$(grep -c 'Out of memory: Killed process' "$F")"

echo
echo "=== REAL kills by day ==="
grep 'oom-kill:constraint' "$F" | cut -c1-10 | sort | uniq -c

echo
echo "=== REAL kills by victim cgroup (collapsed) ==="
grep 'oom-kill:constraint' "$F" | grep -oP 'oom_memcg=\K[^,]+' | sed \
  -e 's#.*/oc-agent\.slice/.*#AGENT-SCOPE (my own bash tool calls)#' \
  -e 's#.*bazel\.slice.*#BAZEL (user builds)#' \
  -e 's#.*opencode-serve@\([0-9]*\).*#PRODUCTION SERVE \1#' \
  | sort | uniq -c | sort -rn

echo
echo "=== PRODUCTION SERVE kills only: full detail ==="
grep 'oom-kill:constraint' "$F" | grep 'opencode-serve@' | cut -c1-20,100-260

echo
echo "=== was a serve actually restarted? (independent of journal grep) ==="
for p in 4096 4097 4098 4099; do
  printf '  serve@%s NRestarts=%s ActiveEnter=%s\n' "$p" \
    "$(systemctl show "opencode-serve@$p.service" -p NRestarts --value 2>/dev/null)" \
    "$(systemctl show "opencode-serve@$p.service" -p ActiveEnterTimestamp --value 2>/dev/null)"
done
