#!/usr/bin/env bash
# For each (grep-flags, pattern) actually used in the 3 unwired files, assert the
# OLD pipeline form and the NEW here-string form agree on exit status across a
# spread of input shapes -- including the shapes where <<< is known to differ
# (empty string; no trailing newline; embedded blank lines).
set -uo pipefail
mism=0; cases=0
try() {  # try <flags> <pat> <input>
  local flags="$1" pat="$2" V="$3" o n
  printf '%s\n' "$V" | grep $flags -- "$pat" >/dev/null 2>&1; o=$?
  grep $flags -- "$pat" <<<"$V" >/dev/null 2>&1; n=$?
  cases=$((cases+1))
  if [ "$o" != "$n" ]; then echo "MISMATCH flags=$flags pat=[$pat] input=[${V:0:40}] old=$o new=$n"; mism=1; fi
}
while IFS=$'\t' read -r flags pat; do
  [ -z "$flags" ] && continue
  for inp in "" "$pat" "prefix
$pat
suffix" "nothing here" "$pat trailing" "
$pat" "a

b"; do
    try "$flags" "$pat" "$inp"
  done
done <<'PATS'
-q	kill-session -t '=lgtm'
-q	kill -TERM
-q	sock_reaped
-q	nvim_exited
-q	state" = Z
-q	pkill -9 -u dev -x nvim
-q	tmux 
-q	expected members (3)
-q	no stray active serve units
-q	octest-serve@2.service
-q	WAIT:
-q	still not up at the deadline
-qi	LoadState
-q	NON-DEFAULT SEAMS
PATS
echo "checked $cases (pattern,input) pairs across 14 patterns"
[ "$mism" = 0 ] && echo "EQUIVALENT: old and new forms agree on every case" || echo "DIVERGENCE FOUND"
exit "$mism"
