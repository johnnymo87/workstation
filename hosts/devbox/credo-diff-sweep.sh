# credo-diff-sweep: delete /tmp/credo-diff-<ts> checkouts older than
# CREDO_SWEEP_MAX_AGE_MIN. Rationale: hosts/devbox/credo-diff-sweep.nix.
# Tests: hosts/devbox/test-credo-diff-sweep.sh.

max_age_min=${CREDO_SWEEP_MAX_AGE_MIN:?}
dir=${CREDO_SWEEP_DIR:-/tmp}
now=${CREDO_SWEEP_NOW:-$(date +%s)}
cutoff=$(( now - max_age_min * 60 ))

# Age comes from the NAME, which credo stamps with the UTC creation time
# (credo-diff-YYYYmmddHHMMSS<usec>). atime/ctime are useless here: anything
# that reads the tree resets atime, which is why the old tmpfiles rule kept
# checkouts for up to two days. Unparseable names fall back to the
# directory's own mtime.
created_at() {
  local name=${1##*/} ts
  ts=${name#credo-diff-}
  if [[ $ts =~ ^([0-9]{4})([0-9]{2})([0-9]{2})([0-9]{2})([0-9]{2})([0-9]{2}) ]]; then
    date -u -d "${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-${BASH_REMATCH[3]} ${BASH_REMATCH[4]}:${BASH_REMATCH[5]}:${BASH_REMATCH[6]}" +%s 2>/dev/null && return
  fi
  stat -c %Y "$1"
}

removed=0; kib=0; failed=0
shopt -s nullglob
for d in "$dir"/credo-diff-*; do
  # Real directories we own only; never follow a symlink out of /tmp.
  [ -d "$d" ] && [ ! -L "$d" ] && [ -O "$d" ] || continue
  [ "$(created_at "$d")" -lt "$cutoff" ] || continue
  size=$(du -sk "$d" 2>/dev/null | cut -f1) || size=0
  # One undeletable checkout must not stop the rest of the sweep.
  if rm -rf -- "$d" 2>/dev/null; then
    removed=$(( removed + 1 )); kib=$(( kib + ${size:-0} ))
  else
    failed=$(( failed + 1 )); echo "<4>credo-diff-sweep: could not fully remove $d"
  fi
done
echo "credo-diff-sweep: removed $removed checkout(s) older than ${max_age_min} min, $(( kib / 1024 )) MiB"
# Non-zero so a persistently stuck checkout shows as a failed unit.
[ "$failed" -eq 0 ]
