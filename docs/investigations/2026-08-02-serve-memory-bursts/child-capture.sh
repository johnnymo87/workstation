#!/usr/bin/env bash
# S1 (workstation-vpid): per-PROCESS capture for serve memory bursts.
#
# Why this exists, and why it is not the escalation the roadmap originally
# declared. S1 established that burst memory lives in the serve unit's CHILD
# processes (LSP + MCP servers), not in the main opencode process: at ignition
# 2026-08-02 19:51:40 cgroup resident anon rose +2.11 GiB while the main pid's
# RSS was FLAT and swap was still 0. The pre-declared escalation -- JS stacks
# from the main process via the Bun inspector -- would therefore have profiled
# the wrong address space.
#
# The original sampler (sample.sh) reads threads/fds/rss from /proc/MainPID
# while reading anon/swap/pagetables from the cgroup. Those two surfaces answer
# different questions, and conflating them is what produced the roadmap's
# "allocated 28 GiB without opening a thread or fd" clue. That statement is
# true of the main process ONLY.
#
# This script closes the gap: on any serve over THRESHOLD_G it writes one row
# per process in the cgroup, including VmSwap (which sample.sh never recorded,
# and whose absence is the one confound S1 could not fully retire).
#
# Threshold is 6G, not 8G, deliberately. The observed ramp was 5.8 G per 15s
# tick WHILE memory.high was throttling the allocator. With the band gone a
# burst can cross 8G, hit the 14G MemoryMax, be OOM-killed and fall back to
# baseline inside a single timer interval -- capturing nothing. Baselines are
# 2.1-3.4G, so 6G is margin without noise.
#
# If a burst does outrun this, the kernel OOM killer dumps a full per-process
# RSS/swap table to the kernel log on the way out: `journalctl -k` around the
# kill is a second, free attribution instrument for exactly the episode this
# script would miss.
#
# Read-only. No writes outside OUT/STAMP.
set -u
export PATH=/run/current-system/sw/bin:/usr/bin:/bin

THRESHOLD_G=${THRESHOLD_G:-6}
OUT=${OUT:-/home/dev/s3-sampling/child-capture.tsv}
COOLDOWN=${COOLDOWN:-300}
STAMPDIR=/home/dev/s3-sampling/.child-capture-stamps
TS=$(date +%s)
mkdir -p "$STAMPDIR"

if [ ! -s "$OUT" ]; then
  printf 'ts\tport\tcg_anon\tcg_swap\tcg_pgtbl\tpid\tppid\tis_main\trss_kb\tswap_kb\tthreads\tcomm\tcmdline\n' > "$OUT"
fi

# Cooldown is PER PORT. A single global stamp would let one serve sitting above
# threshold suppress a different serve's fresh ignition -- the one sample most
# worth having.
for p in 4096 4097 4098 4099; do
  main=$(systemctl show "opencode-serve@$p" -p MainPID --value 2>/dev/null)
  [ -n "$main" ] && [ "$main" != 0 ] || continue
  cg=/sys/fs/cgroup$(systemctl show "opencode-serve@$p" -p ControlGroup --value 2>/dev/null)
  [ -r "$cg/memory.stat" ] || continue

  anon=$(awk '/^anon /{print $2}' "$cg/memory.stat" 2>/dev/null)
  pgtbl=$(awk '/^pagetables /{print $2}' "$cg/memory.stat" 2>/dev/null)
  swap=$(cat "$cg/memory.swap.current" 2>/dev/null)
  [ -n "${anon:-}" ] && [ -n "${swap:-}" ] || continue

  # Judge demand on anon+swap, never memory.current (it includes page cache).
  over=$(awk -v a="$anon" -v s="$swap" -v t="$THRESHOLD_G" \
    'BEGIN{print ((a+s)/1073741824 >= t) ? 1 : 0}')
  [ "$over" = 1 ] || continue

  stamp="$STAMPDIR/$p"
  if [ -s "$stamp" ]; then
    last=$(cat "$stamp" 2>/dev/null || echo 0)
    [ $((TS - last)) -lt "$COOLDOWN" ] && continue
  fi
  echo "$TS" > "$stamp"

  while read -r pid; do
    [ -n "$pid" ] || continue
    [ -r "/proc/$pid/status" ] || continue
    rss=$(awk '/^VmRSS:/{print $2}' "/proc/$pid/status" 2>/dev/null)
    vsw=$(awk '/^VmSwap:/{print $2}' "/proc/$pid/status" 2>/dev/null)
    thr=$(awk '/^Threads:/{print $2}' "/proc/$pid/status" 2>/dev/null)
    ppid=$(awk '/^PPid:/{print $2}' "/proc/$pid/status" 2>/dev/null)
    comm=$(tr -d '\t' < "/proc/$pid/comm" 2>/dev/null)
    cmd=$(tr '\0\t\n' '   ' < "/proc/$pid/cmdline" 2>/dev/null | cut -c1-200)
    ismain=0; [ "$pid" = "$main" ] && ismain=1
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$TS" "$p" "$anon" "$swap" "${pgtbl:-}" "$pid" "${ppid:-}" "$ismain" \
      "${rss:-}" "${vsw:-}" "${thr:-}" "${comm:-}" "${cmd:-}" >> "$OUT"
  done < "$cg/cgroup.procs"
done
exit 0
