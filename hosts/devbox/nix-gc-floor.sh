# nix-gc-floor: when devbox's root filesystem drops below a free-space trigger,
# garbage-collect DEAD store paths only, until free space reaches a target.
# Generations are never touched (that stays nix-gc.service's weekly job), so
# nothing live and no rollback target can be removed.
# Rationale and thresholds: hosts/devbox/nix-gc-floor.nix.
# Tests: hosts/devbox/test-nix-gc-floor.sh (stubs df and nix-store on PATH).

trigger_gib=${GC_FLOOR_TRIGGER_GIB:?}
target_gib=${GC_FLOOR_TARGET_GIB:?}
backoff_min=${GC_FLOOR_BACKOFF_MIN:?}
bypass_gib=${GC_FLOOR_BACKOFF_BYPASS_GIB:?}
min_useful_gib=${GC_FLOOR_MIN_USEFUL_GIB:?}
state=${STATE_DIRECTORY:?}
now=${GC_FLOOR_NOW:-$(date +%s)}
backoff_file=$state/backoff   # "<until-epoch> <free-KiB when armed>"
KiB_per_GiB=$((1024 * 1024))

avail_kib() {
  local v
  v=$(df --output=avail -k / | tail -n 1 | tr -d ' ')
  [[ $v =~ ^[0-9]+$ ]] || { echo "<3>nix-gc-floor: cannot read free space on / (got: $v)"; exit 2; }
  echo "$v"
}
gib() { echo $(( $1 / KiB_per_GiB )); }

before=$(avail_kib)
if [ "$before" -ge $(( trigger_gib * KiB_per_GiB )) ]; then
  rm -f "$backoff_file"
  exit 0
fi

# Backoff: skip while it holds, unless free space has dropped materially since
# it was armed -- new garbage (a finished flake check) is exactly what shows up
# as a drop, and is exactly what this unit exists to collect.
if [ -e "$backoff_file" ]; then
  read -r until armed_at <"$backoff_file"
  if [ "$now" -lt "$until" ] && [ "$before" -gt $(( armed_at - bypass_gib * KiB_per_GiB )) ]; then
    echo "nix-gc-floor: root free $(gib "$before") GiB < ${trigger_gib} GiB, but the last GC found almost nothing dead; backing off until $(date -d "@$until" '+%F %T' 2>/dev/null || echo "$until")"
    exit 0
  fi
fi

need_bytes=$(( (target_gib * KiB_per_GiB - before) * 1024 ))
echo "nix-gc-floor: root free $(gib "$before") GiB < ${trigger_gib} GiB; collecting up to $(( need_bytes / 1024 / 1024 / 1024 )) GiB of dead store paths"
# Local store, not NIX_REMOTE=daemon: the deleting happens in THIS unit's
# cgroup, where nix-gc-floor.nix's I/O limits apply. (devbox's root disk runs
# the `none` scheduler, so the daemon's idle I/O class would not protect
# anything.) --quiet: one summary line on stdout instead of a line per path.
report=$(nix-store --store local --quiet --gc --max-freed "$need_bytes")
echo "nix-gc-floor: nix-store: $report"
freed_mib=0
if [[ $report =~ ([0-9]+)(\.[0-9]+)?\ MiB\ freed ]]; then freed_mib=${BASH_REMATCH[1]}; fi

after=$(avail_kib)
echo "nix-gc-floor: GC freed $(( freed_mib / 1024 )) GiB; root free now $(gib "$after") GiB (was $(gib "$before"))"
# Judged on what the GC reports, not on the df delta, which concurrent writers
# can cancel out.
if [ "$freed_mib" -lt $(( min_useful_gib * 1024 )) ]; then
  echo "$(( now + backoff_min * 60 )) $after" >"$backoff_file"
  echo "<4>nix-gc-floor: under ${min_useful_gib} GiB was dead; the space is held outside the store's garbage. Backing off ${backoff_min} min, or until free space drops another ${bypass_gib} GiB"
else
  rm -f "$backoff_file"
fi
