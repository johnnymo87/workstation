# nix-gc-floor: when devbox's root filesystem drops below a free-space trigger,
# garbage-collect DEAD store paths only, through nix-daemon, until free space
# reaches a target. Generations are never touched (that stays nix-gc.service's
# weekly job), so nothing live and no rollback target can be removed.
# Rationale and thresholds: hosts/devbox/nix-gc-floor.nix.
# Tests: hosts/devbox/test-nix-gc-floor.sh (stubs df and nix-store on PATH).

trigger_gib=${GC_FLOOR_TRIGGER_GIB:?}
target_gib=${GC_FLOOR_TARGET_GIB:?}
backoff_min=${GC_FLOOR_BACKOFF_MIN:?}
min_useful_gib=${GC_FLOOR_MIN_USEFUL_GIB:?}
state=${STATE_DIRECTORY:?}
now=${GC_FLOOR_NOW:-$(date +%s)}
backoff_file=$state/backoff-until

avail_kib() {
  local v
  v=$(df --output=avail -k / | tail -n 1 | tr -d ' ')
  [[ $v =~ ^[0-9]+$ ]] || { echo "<3>nix-gc-floor: cannot read free space on / (got: $v)"; exit 2; }
  echo "$v"
}
gib() { echo $(( $1 / 1024 / 1024 )); }

before=$(avail_kib)
if [ "$before" -ge $(( trigger_gib * 1024 * 1024 )) ]; then
  rm -f "$backoff_file"
  exit 0
fi

if [ -e "$backoff_file" ] && [ "$now" -lt "$(cat "$backoff_file")" ]; then
  echo "nix-gc-floor: root free $(gib "$before") GiB < ${trigger_gib} GiB, but the last GC found almost nothing dead; backing off until $(date -d "@$(cat "$backoff_file")" '+%F %T' 2>/dev/null || cat "$backoff_file")"
  exit 0
fi

need_bytes=$(( (target_gib * 1024 * 1024 - before) * 1024 ))
echo "nix-gc-floor: root free $(gib "$before") GiB < ${trigger_gib} GiB; collecting up to $(( need_bytes / 1024 / 1024 / 1024 )) GiB of dead store paths"
# NIX_REMOTE=daemon: the daemon does the deleting, at its batch CPU / idle I/O
# scheduling (hosts/devbox/configuration.nix), so the GC yields to sshd and
# interactive sessions. Run as root without it, nix-store would open the store
# directly and do the I/O at this unit's own priority.
# --quiet: one summary line instead of a journal line per deleted path.
NIX_REMOTE=daemon nix-store --quiet --gc --max-freed "$need_bytes"

after=$(avail_kib)
freed=$(( after > before ? after - before : 0 ))
echo "nix-gc-floor: freed $(gib "$freed") GiB; root free now $(gib "$after") GiB"
if [ "$freed" -lt $(( min_useful_gib * 1024 * 1024 )) ]; then
  # Little was dead, so the space is held by something a store GC cannot reach
  # (projects, caches, a live devenv). Re-scanning every tick would only add
  # I/O on an already-tight disk, so wait before trying again.
  echo $(( now + backoff_min * 60 )) >"$backoff_file"
  echo "<4>nix-gc-floor: under ${min_useful_gib} GiB was dead; the space is held outside the store's garbage. Backing off ${backoff_min} min"
else
  rm -f "$backoff_file"
fi
