#!/usr/bin/env bash
# Step 3 sampler (workstation-9b3o): why does one cloudbox serve member balloon?
# Read-only. Appends one TSV row per serve per tick to samples.tsv.
set -u
export PATH=/run/current-system/sw/bin:/usr/bin:/bin
SQ=/nix/store/p3iz4w8ng3azif27cphwr26074bivii1-sqlite-3.51.2-bin/bin/sqlite3
RDB=/home/dev/projects/pigeon/packages/daemon/data/pigeon-daemon.db
# v2 schema (2026-08-03, S1/workstation-vpid): adds main_swap_kb. Rotated to a
# new file rather than appending a column to samples.tsv, so neither file ever
# has two different column counts. samples.tsv remains the S1 evidence as-is.
#
# SCOPE WARNING, the defect S1 was built on: threads/fds/inotify_*/rss_kb/
# main_swap_kb are read from /proc/MainPID and describe the MAIN PROCESS ONLY.
# anon/file/slab/pagetables/swap/mem_bytes come from the CGROUP and cover every
# process in the unit, including LSP and MCP children. Do not compare across
# those two scopes without saying which you mean.
OUT=/home/dev/s3-sampling/samples-v2.tsv
TS=$(date +%s)

if [ ! -s "$OUT" ]; then
  printf 'ts\tport\tserve_id\tpid\tboot\tmem_bytes\trss_kb\tmain_swap_kb\tthreads\tfds\tinotify_fds\tinotify_watches\tnotify_debounce\tassign_total\tassign_active_1h\tassign_active_10m\tanon\tfile\tslab\tpagetables\tswap\tmem_high\tactive_file\n' > "$OUT"
fi

# session assignments per serve id, from pigeon's routing DB (read-only handle).
ASSIGN=$("$SQ" "file:$RDB?mode=ro" "PRAGMA busy_timeout=5000;
  SELECT desired_serve_id || ' ' || count(*) || ' '
      || sum(last_active_at > (strftime('%s','now')-3600)*1000) || ' '
      || sum(last_active_at > (strftime('%s','now')-600)*1000)
  FROM session_assignment GROUP BY desired_serve_id;" 2>/dev/null)

i=0
for p in 4096 4097 4098 4099; do
  sid="serve-$i"; i=$((i+1))
  pid=$(systemctl show "opencode-serve@$p" -p MainPID --value 2>/dev/null)
  mem=$(systemctl show "opencode-serve@$p" -p MemoryCurrent --value 2>/dev/null)
  boot=$(systemctl show "opencode-serve@$p" --timestamp=unix -p ActiveEnterTimestamp --value 2>/dev/null)
  boot=${boot#@}
  [ -n "$pid" ] && [ "$pid" != 0 ] || continue
  rss=$(awk '/^VmRSS:/{print $2}' "/proc/$pid/status" 2>/dev/null)
  msw=$(awk '/^VmSwap:/{print $2}' "/proc/$pid/status" 2>/dev/null)
  thr=$(awk '/^Threads:/{print $2}' "/proc/$pid/status" 2>/dev/null)
  fds=$(ls "/proc/$pid/fd" 2>/dev/null | wc -l)
  inof=$(ls -l "/proc/$pid/fd" 2>/dev/null | grep -c inotify)
  inow=$(cat "/proc/$pid/fdinfo/"* 2>/dev/null | grep -c '^inotify')
  deb=$(cat "/proc/$pid/task/"*/comm 2>/dev/null | grep -c 'notify-rs debou')
  cg=/sys/fs/cgroup$(awk -F: '{print $3}' "/proc/$pid/cgroup" 2>/dev/null | head -1)
  anon=$(awk '/^anon /{print $2}' "$cg/memory.stat" 2>/dev/null)
  fil=$(awk '/^file /{print $2}' "$cg/memory.stat" 2>/dev/null)
  afil=$(awk '/^active_file /{print $2}' "$cg/memory.stat" 2>/dev/null)
  slab=$(awk '/^slab /{print $2}' "$cg/memory.stat" 2>/dev/null)
  pgt=$(awk '/^pagetables /{print $2}' "$cg/memory.stat" 2>/dev/null)
  swp=$(cat "$cg/memory.swap.current" 2>/dev/null)
  hi=$(cat "$cg/memory.high" 2>/dev/null)
  line=$(printf '%s\n' "$ASSIGN" | awk -v s="$sid" '$1==s{print $2" "$3" "$4}')
  at=$(echo "$line" | awk '{print $1+0}'); a1=$(echo "$line" | awk '{print $2+0}'); a10=$(echo "$line" | awk '{print $3+0}')
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$TS" "$p" "$sid" "$pid" "$boot" "$mem" "$rss" "${msw:-}" "$thr" "$fds" "$inof" "$inow" "$deb" "$at" "$a1" "$a10" \
    "${anon:-}" "${fil:-}" "${slab:-}" "${pgt:-}" "${swp:-}" "${hi:-}" "${afil:-}" >> "$OUT"
done
