# pressure-sampler: a long-format time series of memory AND stall pressure for the
# things that decide whether this box "runs well".
#
# WHY THIS EXISTS, AND WHY IT IS NOT THE S2 SAMPLER
#
# ~/s3-sampling/sample.sh answers "how much memory does a serve hold". That is one
# of three questions worth asking, and not the one a user notices:
#
#   1. does the box LOCK UP          -> OOM kills, memory.events, memory pressure
#   2. does anything RUN SLOW        -> PSI stall time, attributed per cgroup
#   3. is the box RIGHT-SIZED        -> sustained peak utilisation vs capacity
#
# Only (1) is answerable from memory bytes. (2) needs PSI, which nothing here
# captured before this: /proc/pressure/* and the per-cgroup *.pressure files were
# unread. (3) needs a long enough series of both to see the high-water mark.
#
# The first PSI reading taken on this host (2026-08-06 08:4xZ) already made the
# point: all four serves sat at cpu/memory `some avg10` = 0.00 while bazel.slice
# was at io some 1.95/3.85 and the host at io full avg300 2.20%. The box's stall
# was IO, and it was bazel's -- invisible to every instrument we had.
#
# DELIBERATELY A SEPARATE FILE AND TIMER from the S2 series. S2's observation
# window runs to 2026-08-09 22:37Z and its verdict depends on an unbroken series;
# samples.tsv/-v2/-v3 already differ in column count and meaning, and adding a
# fourth shape mid-window is how that becomes unreadable. Do not merge these until
# S2 closes.
#
# WHY AN EXTERNAL OBSERVER RATHER THAN INSTRUMENTING THE BAZEL SHIM
#
# The obvious way to get per-build peaks is to have pkgs/bazel-scope record them
# when the build finishes. It cannot: the shim's happy path `exec`s into
# systemd-run, so the shim process is gone for the whole build. Recovering an
# "after" would mean dropping that exec and hand-forwarding signals and exit
# codes -- on the critical path of every build the user runs. Sampling the scopes
# from outside costs the build exactly nothing and cannot break it.
#
# The tradeoff is honest and worth stating: memory.peak is monotonic within a
# scope's life, so the last sample before a scope is torn down IS its peak as of
# that instant, but a build shorter than the sample interval is missed entirely
# and a peak reached in the final seconds is undercounted. This measures the
# distribution of build demand, not a guaranteed per-build maximum.
#
# READING THE SERIES -- three traps, all of them live here
#
#  a) COUNTERS ARE PER CGROUP INSTANCE. PSI totals, cpu.stat and memory.events all
#     reset when a cgroup is destroyed and recreated -- which happens on every
#     serve restart and on the nightly reset. A negative delta means a NEW EPOCH,
#     not negative stall. Never sum across one.
#  b) SLICE COUNTERS ARE LIFETIME AND HIERARCHICAL. A slice outlives its children,
#     so its numbers include long-dead ones. Measured 2026-08-06: the serve slice
#     read peak=42.14G and oom_kill=4 while all four live leaves read 0 -- those
#     four kills are the 08-03/04 ones, from cgroups that no longer exist, on a box
#     up 86 days. That 42.14G is a high-water mark from SOME instant under an older
#     regime. Do NOT size an aggregate cap from it; use forward deltas of this
#     series instead. This is why ev_max_local/ev_oom_local are recorded too:
#     for bazel.slice, `max` mixes its own 16G cap with children hitting their 10G
#     one (931513 vs 645632 local when first measured), and only the local counter
#     separates them.
#  c) HOST cpu_full_us IS DEFINED AS ALWAYS ZERO. /proc/pressure/cpu has no
#     meaningful `full` at system level. The column exists for shape; ignore it.
#     Per-cgroup cpu.pressure `full` IS meaningful.
#
# PSI MEASURES WAITING, NOT BUSYNESS -- so cpu_usage_us is recorded alongside it.
# A 16-core box at 90% utilisation with no contention has near-zero CPU pressure
# and looks identical to an idle one. Right-sizing needs both: pressure says "it
# hurt", utilisation says "how much of what we pay for was used". Measured while
# writing this: load 30.11 on 16 cores with cpu some avg10=35%.
#
# WHY `kernel` IS RECORDED, not just anon+file: memory.current = anon + file +
# kernel exactly (verified on a live serve cgroup), and the residual is not small.
# On 2026-08-06 :4098 read 14.00G with anon 1.40G and file 6.82G -- leaving ~5.78G
# that the first schema simply could not name, on a cgroup whose whole cap is 14G.
# A third of a serve's footprint being unattributable defeats the point. `slab`,
# `pagetables` and `shmem` are a breakdown OF kernel (not additional to it) and are
# recorded for diagnosis: heavy build IO inflates dentry/inode slab, and that is
# charged to whichever cgroup faulted it in.
#
# io.stat IS ABSENT UNDER user@1000: its cgroup.subtree_control is `cpu memory
# pids`, with no `io` delegated, so bazel scopes report no IO bytes and those
# columns stay empty for them. They populate for the host and the system.slice
# cgroups. Since this box's dominant stall IS io, delegating the io controller is
# worth doing -- tracked separately.
{ lib, writeShellApplication, coreutils, gawk }:

writeShellApplication {
  name = "pressure-sampler";
  runtimeInputs = [ coreutils gawk ];
  text = ''
    set -o errexit
    set -o nounset
    set -o pipefail

    OUT_DIR="''${PRESSURE_SAMPLER_DIR:-$HOME/metrics}"
    CGROUP_ROOT="''${PRESSURE_SAMPLER_CGROUP_ROOT:-/sys/fs/cgroup}"
    PROC_ROOT="''${PRESSURE_SAMPLER_PROC_ROOT:-/proc}"
    RETENTION_DAYS="''${PRESSURE_SAMPLER_RETENTION_DAYS:-30}"

    mkdir -p "$OUT_DIR"
    TS=$(date -u +%s)
    OUT="$OUT_DIR/pressure-v2-$(date -u -d "@$TS" +%Y-%m-%d).tsv"

    # Schema version is in the FILENAME, not just here: samples.tsv/-v2/-v3 taught
    # us that a series whose shape changed silently becomes unreadable later.
    COLS="ts	subject	detail	mem_current	mem_peak	mem_max	anon	file	kernel	slab	pagetables	shmem	swap	ev_max	ev_oom_kill	ev_max_local	ev_oom_local	cpu_usage_us	cpu_some_us	cpu_full_us	mem_some_us	mem_full_us	io_some_us	io_full_us	io_rbytes	io_wbytes"
    if [ ! -f "$OUT" ]; then
      printf '%s\n' "$COLS" > "$OUT"
    fi

    # PSI `total=` is a monotonic microsecond counter of stall time. It is the
    # field worth recording: avg10/60/300 are derived conveniences that cannot be
    # re-aggregated over an arbitrary window, whereas two totals and a timestamp
    # give exact stall time between any two samples.
    psi_total() { # <file> <some|full>
      [ -r "$1" ] || { printf '%s' ""; return 0; }
      awk -v want="$2" '$1==want":" || $1==want {
        for (i=2;i<=NF;i++) if ($i ~ /^total=/) { sub(/^total=/,"",$i); print $i; exit }
      }' "$1" 2>/dev/null || printf '%s' ""
    }

    cgfield() { # <file> -- whole-file scalar
      [ -r "$1" ] && tr -d '\n' < "$1" || printf '%s' ""
    }

    statfield() { # <memory.stat> <key>
      [ -r "$1" ] && awk -v k="$2" '$1==k{print $2; exit}' "$1" || printf '%s' ""
    }

    cpu_usage() { # <cgroup> -> cpu.stat usage_usec
      [ -r "$1/cpu.stat" ] && awk '$1=="usage_usec"{print $2; exit}' "$1/cpu.stat" || printf '%s' ""
    }

    # io.stat is per-device (one line per maj:min); sum the field across devices.
    io_bytes() { # <cgroup> <rbytes|wbytes>
      [ -r "$1/io.stat" ] || { printf '%s' ""; return 0; }
      awk -v k="$2" '{for(i=2;i<=NF;i++){split($i,a,"=");if(a[1]==k)t+=a[2]}} END{if(t=="")print "";else print t}' "$1/io.stat" 2>/dev/null || printf '%s' ""
    }

    evfield() { # <memory.events> <key>
      [ -r "$1" ] && awk -v k="$2" '$1==k{print $2; exit}' "$1" || printf '%s' ""
    }

    emit_cgroup() { # <subject> <detail> <cgroup path>
      local subj="$1" detail="$2" cg="$3"
      [ -d "$cg" ] || return 0
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$TS" "$subj" "$detail" \
        "$(cgfield "$cg/memory.current")" \
        "$(cgfield "$cg/memory.peak")" \
        "$(cgfield "$cg/memory.max")" \
        "$(statfield "$cg/memory.stat" anon)" \
        "$(statfield "$cg/memory.stat" file)" \
        "$(statfield "$cg/memory.stat" kernel)" \
        "$(statfield "$cg/memory.stat" slab)" \
        "$(statfield "$cg/memory.stat" pagetables)" \
        "$(statfield "$cg/memory.stat" shmem)" \
        "$(cgfield "$cg/memory.swap.current")" \
        "$(evfield "$cg/memory.events" max)" \
        "$(evfield "$cg/memory.events" oom_kill)" \
        "$(evfield "$cg/memory.events.local" max)" \
        "$(evfield "$cg/memory.events.local" oom_kill)" \
        "$(cpu_usage "$cg")" \
        "$(psi_total "$cg/cpu.pressure" some)" \
        "$(psi_total "$cg/cpu.pressure" full)" \
        "$(psi_total "$cg/memory.pressure" some)" \
        "$(psi_total "$cg/memory.pressure" full)" \
        "$(psi_total "$cg/io.pressure" some)" \
        "$(psi_total "$cg/io.pressure" full)" \
        "$(io_bytes "$cg" rbytes)" \
        "$(io_bytes "$cg" wbytes)"
    }

    {
      # ---- host ------------------------------------------------------------
      # MemAvailable is the honest capacity number for right-sizing: MemFree
      # excludes reclaimable page cache and reads as alarmingly low on a box
      # doing heavy build IO, which is exactly when someone would misread it.
      mem_total=$(awk '/^MemTotal:/{print $2*1024; exit}' "$PROC_ROOT/meminfo")
      mem_avail=$(awk '/^MemAvailable:/{print $2*1024; exit}' "$PROC_ROOT/meminfo")
      swap_used=$(awk '/^SwapTotal:/{t=$2} /^SwapFree:/{f=$2} END{print (t-f)*1024}' "$PROC_ROOT/meminfo")
      # Host CPU busy time in microseconds, from /proc/stat: total jiffies minus
      # idle+iowait, scaled by USER_HZ (100 on this kernel). Same units as a
      # cgroup's cpu.stat usage_usec, so host and cgroup rows are comparable.
      cpu_busy_us=$(awk '/^cpu /{idle=$5+$6; tot=0; for(i=2;i<=NF;i++) tot+=$i; printf "%d", (tot-idle)*10000; exit}' "$PROC_ROOT/stat")
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$TS" "host" "-" \
        "$(( mem_total - mem_avail ))" "" "$mem_total" "" "" "" "" "" "" "$swap_used" "" "" "" "" \
        "$cpu_busy_us" \
        "$(psi_total "$PROC_ROOT/pressure/cpu" some)" \
        "$(psi_total "$PROC_ROOT/pressure/cpu" full)" \
        "$(psi_total "$PROC_ROOT/pressure/memory" some)" \
        "$(psi_total "$PROC_ROOT/pressure/memory" full)" \
        "$(psi_total "$PROC_ROOT/pressure/io" some)" \
        "$(psi_total "$PROC_ROOT/pressure/io" full)" \
        "$(io_bytes "$CGROUP_ROOT" rbytes)" \
        "$(io_bytes "$CGROUP_ROOT" wbytes)"

      # ---- opencode serves -------------------------------------------------
      for cg in "$CGROUP_ROOT"/system.slice/system-opencode*.slice/opencode-serve@*.service; do
        [ -d "$cg" ] || continue
        port="''${cg##*@}"; port="''${port%%.service}"
        emit_cgroup "serve" "$port" "$cg"
      done
      # The parent slice: workstation-le0a wants an aggregate cap here and it is
      # still MemoryMax=infinity, so record what the aggregate actually reaches.
      for cg in "$CGROUP_ROOT"/system.slice/system-opencode*.slice; do
        [ -d "$cg" ] && emit_cgroup "serve-slice" "-" "$cg"
      done

      # ---- bazel -----------------------------------------------------------
      uid=$(id -u)
      bslice="$CGROUP_ROOT/user.slice/user-$uid.slice/user@$uid.service/bazel.slice"
      emit_cgroup "bazel-slice" "-" "$bslice"
      for cg in "$bslice"/*.scope; do
        [ -d "$cg" ] || continue
        scope="''${cg##*/}"
        # Name the build by its workspace. The bazel server renames itself to
        # `bazel(<workspace>)`, so this needs no bazel invocation and takes no
        # client lock. A scope with no server yet reports "-".
        ws="-"
        if [ -r "$cg/cgroup.procs" ]; then
          while read -r pid; do
            [ -n "$pid" ] || continue
            cmd=$(tr '\0' ' ' < "$PROC_ROOT/$pid/cmdline" 2>/dev/null) || continue
            case "$cmd" in
              "bazel("*) ws="''${cmd%%)*})"; break ;;
            esac
          done < "$cg/cgroup.procs" || true
        fi
        emit_cgroup "bazel-scope" "$scope|$ws" "$cg"
      done
    } >> "$OUT"

    # Daily files, pruned. ~10 rows/tick at 15s is ~8MB/day; unbounded that is a
    # disk problem within a quarter, and this box has had disk pressure before.
    find "$OUT_DIR" -maxdepth 1 -name 'pressure-v*-*.tsv' -mtime "+$RETENTION_DAYS" -delete 2>/dev/null || true
  '';

  meta = with lib; {
    description = "Sample memory + PSI stall pressure for serves, bazel scopes, and the host";
    platforms = platforms.linux;
  };
}
