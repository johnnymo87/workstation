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
{ lib, writeShellApplication, coreutils, gawk, findutils }:

writeShellApplication {
  name = "pressure-sampler";
  # findutils is required by the retention sweep at the bottom of this script.
  # It was missing, and because that call ends in `2>/dev/null || true` the
  # failure was swallowed: retention had NEVER run. Found 2026-09-16 with 11
  # files older than RETENTION_DAYS=30 still present, back to 2026-08-06.
  #
  # The user manager's PATH is systemd's own bin directory and nothing else, and
  # this unit sets no Environment=, so anything not in runtimeInputs is simply
  # absent at runtime. Serve discovery below therefore uses bash globs rather
  # than find -- not to avoid this dependency, which retention needs anyway, but
  # because a discovery step that silently reports "nothing found" when its
  # tooling is missing is the same failure this file exists to stop.
  runtimeInputs = [ coreutils gawk findutils ];
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

    # A row with a subject and no measurements, used to record that something we
    # expected to find was ABSENT. Emitting nothing would be indistinguishable
    # from "it was there and idle", and that ambiguity is precisely what let the
    # ghost serve cgroup go unnoticed for weeks. Width is derived from COLS so it
    # cannot drift out of step with the schema.
    emit_blank() { # <subject> <detail>
      awk -v ts="$TS" -v s="$1" -v d="$2" -v cols="$COLS" '
        BEGIN {
          n = split(cols, a, "\t")
          printf "%s\t%s\t%s", ts, s, d
          for (i = 4; i <= n; i++) printf "\t"
          printf "\n"
        }'
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
      # LOCATE THE UNITS BY NAME. Do not hardcode the slice path.
      #
      # This previously globbed system.slice/system-opencode*.slice, which was
      # correct when written (PR #312) and silently wrong from the moment the
      # serves moved to a root-level opencode.slice. The old cgroup still EXISTS
      # and is EMPTY, so the glob kept matching, `[ -d ]` kept succeeding, and
      # every serve-slice row from the move until 2026-09-16 recorded zeros --
      # 20-25 MB against four serves actually holding 19.0 GB -- while no
      # per-serve row was emitted at all. Nothing errored, so nothing was
      # noticed, and the epic that needed this series (workstation-o5s1) found
      # it had no serve data for the incident it was trying to explain.
      #
      # A path that is real, readable, and wrong is the worst case for a
      # sampler: it fails the one way that produces confident, plausible,
      # useless numbers. Finding the units by name survives the next move, and
      # the parent slice is derived from where they actually are rather than
      # asserted a second time.
      # Bash globs, not `find`: this must not depend on anything being on PATH.
      # An earlier revision used `find` and was WORSE THAN THE BUG IT FIXED --
      # findutils was not in runtimeInputs, the user manager's PATH is systemd's
      # bin directory alone, so the shipped binary reported "no serves" on every
      # tick with four serves running. Verified by running the built binary
      # under `env -i PATH=/var/empty`. The suite missed it because the harness
      # prepended a populated PATH; it now runs the sampler with an empty one.
      #
      # Unmatched globs stay literal and are filtered by `[ -d ]`, so no
      # nullglob is needed. Depths 1-4 below the cgroup root cover the current
      # layout (opencode.slice/opencode-serve.slice/UNIT), the legacy one
      # (system.slice/system-opencode\x2dserve.slice/UNIT), and a future move
      # under the user manager (user.slice/user-1000.slice/user@1000.service/
      # X.slice/UNIT), which a maxdepth of 4 would have excluded.
      serve_cgs=()
      for cg in \
        "$CGROUP_ROOT"/opencode-serve@*.service \
        "$CGROUP_ROOT"/*/opencode-serve@*.service \
        "$CGROUP_ROOT"/*/*/opencode-serve@*.service \
        "$CGROUP_ROOT"/*/*/*/opencode-serve@*.service \
        "$CGROUP_ROOT"/*/*/*/*/opencode-serve@*.service; do
        [ -d "$cg" ] || continue
        serve_cgs+=("$cg")
      done

      if [ "''${#serve_cgs[@]}" -eq 0 ]; then
        emit_blank "serve-missing" "-"
        printf 'pressure-sampler: no opencode-serve@*.service cgroup under %s\n' "$CGROUP_ROOT" >&2
      else
        serve_parents=()
        for cg in "''${serve_cgs[@]}"; do
          port="''${cg##*@}"; port="''${port%%.service}"
          emit_cgroup "serve" "$port" "$cg"
          parent="''${cg%/*}"
          seen=0
          for p in ''${serve_parents[@]+"''${serve_parents[@]}"}; do
            [ "$p" = "$parent" ] && { seen=1; break; }
          done
          [ "$seen" -eq 0 ] && serve_parents+=("$parent")
        done
        # The parent slice: workstation-le0a wants an aggregate cap here and it is
        # still MemoryMax=infinity, so record what the aggregate actually reaches.
        for parent in ''${serve_parents[@]+"''${serve_parents[@]}"}; do
          emit_cgroup "serve-slice" "-" "$parent"
        done
      fi

      # ---- bazel -----------------------------------------------------------
      uid=$(id -u)
      umgr="$CGROUP_ROOT/user.slice/user-$uid.slice/user@$uid.service"
      bslice="$umgr/bazel.slice"
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

      # ---- user manager aggregate -----------------------------------------
      # The total for user@1000.service, so the sampled children can be checked
      # against it. The residual -- this total minus the children we sample --
      # is the only way anyone notices a population we are NOT sampling, which
      # on 2026-09-15 was the entire problem. It is also what makes the silent
      # absence of tmux rows below survivable: without this row, "no panes are
      # open" and "panes moved somewhere we do not look" are indistinguishable.
      emit_cgroup "user-manager" "-" "$umgr"

      # ---- tmux pane scopes (bead workstation-o5s1.13) ---------------------
      # tmux gives every spawned pane its own transient scope directly under the
      # user manager. On 2026-09-17 those scopes held 10.35 GB across 38 TUIs --
      # the largest identifiable consumer under user@1000.service -- with
      # MemoryMax=infinity and no presence in any time series.
      #
      # That blind spot is why the 2026-09-15 host swap jump of 11.43 GB could
      # not be attributed. The serves were measurably pinned at their 1G cap
      # (<=0.35 GB of the jump) and bazel at its 2G cap (<=0.27 GB), so ~10.8 GB
      # came from populations nothing sampled. Everything that WAS instrumented
      # had an alibi, which is the shape of an instrumentation gap rather than a
      # mystery.
      #
      # THESE PANES ARE ONE CANDIDATE, NOT THE ANSWER. At least two other
      # unsampled populations sit under the same user manager and could have
      # supplied that swap: app.slice (memory.swap.peak 5.57 GB) and
      # oc.slice/oc-agent.slice (swap.peak 2.00 GB, its cap; 21 oom_kills). A
      # 9.6 GB burst in eight minutes fits one agent bash command under a 10G
      # scope cap at least as well as it fits a pane leak. Sampling these rows
      # is what will let the NEXT such jump be attributed; it does not
      # retroactively convict anything. Rows for app.slice and oc-agent.slice
      # are the obvious follow-up and are tracked on workstation-o5s1.13.
      #
      # The scope name is tmux's, not ours -- nothing in this repo creates it --
      # so this matches a NAME PATTERN rather than a fixed path, and is emitted
      # one row per scope with the scope in `detail` so growth stays visible
      # after aggregation.
      #
      # NAMED FOR WHAT IT MEASURES, NOT FOR WHAT WE EXPECT TO FIND IN IT. These
      # are tmux PANE scopes: measured on 2026-09-17 they hold opencode attach
      # wrappers, and also nvim and bash. An earlier draft called the subject
      # "tui-scope", which would have quietly invited a future reader to report
      # "the TUIs use 16.79 GB" when some of that is an editor. A row labelled
      # with an assumption is how an instrument aimed at one subject gets read
      # as evidence about another.
      #
      # DELIBERATELY SILENT WHEN THERE ARE NONE, unlike the serve case above. No
      # attach TUI is a perfectly ordinary state -- nobody has a pane open -- so
      # a marker row would fire constantly and teach everyone to ignore markers.
      # Zero SERVES means the pool is down or we are reading the wrong cgroup,
      # which is worth shouting about. The asymmetry is the point; the test suite
      # pins both halves so neither gets "made consistent" later.
      # DEPTH MATTERS, and depth 1 alone is wrong. tmux sets each pane scope's
      # Slice= from the tmux SERVER's slice (compat/systemd.c, via
      # sd_pid_get_user_slice), falling back to app-tmux.slice when the server
      # was started from outside the user session. Two live paths do exactly
      # that: oc-auto-attach runs `tmux new-session` from pigeon-daemon.service
      # (User=dev, /system.slice/...), and tmux.devbox.nix runs the server as a
      # user service. Either puts every pane at
      # $umgr/app.slice/app-tmux.slice/tmux-spawn-*.scope instead. A depth-1
      # glob finds nothing there -- and since absence is deliberately silent
      # below, nobody would be told. That is the ghost-cgroup failure again,
      # one directory deeper.
      for cg in "$umgr"/tmux-spawn-*.scope \
                "$umgr"/*/tmux-spawn-*.scope \
                "$umgr"/*/*/tmux-spawn-*.scope; do
        [ -d "$cg" ] || continue
        emit_cgroup "tmux-scope" "''${cg##*/}" "$cg"
      done
    } >> "$OUT"

    # Daily files, pruned. This was "~10 rows/tick, ~8MB/day" when written; with
    # per-pane rows it is ~27 rows/tick today, measured at ~236 B per tmux row,
    # so each open pane costs ~1.3 MB/day and 17 panes adds ~22 MB/day. At 50
    # panes that is ~64 MB/day, i.e. ~2 GB over the 30-day retention -- fine
    # against 63G free, but worth re-checking if the pane count grows.
    # Sampler runtime also went 0.32s -> 0.92s at 17 scopes (~35 ms/scope).
    #
    # NOTE this retention sweep did not run at all until 2026-09-16: findutils
    # was missing from runtimeInputs and the failure was swallowed by
    # `2>/dev/null || true`. So this is the first change to add volume to a file
    # set that is actually being pruned.
    find "$OUT_DIR" -maxdepth 1 -name 'pressure-v*-*.tsv' -mtime "+$RETENTION_DAYS" -delete 2>/dev/null || true
  '';

  meta = with lib; {
    description = "Sample memory + PSI stall pressure for serves, bazel scopes, and the host";
    platforms = platforms.linux;
  };
}
