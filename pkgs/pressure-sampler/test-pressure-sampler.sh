#!/usr/bin/env bash
# Behavioural suite for pkgs/pressure-sampler.
#
# WHY THIS EXISTS. The sampler hardcoded the serve cgroups at
# system.slice/system-opencode*.slice. The serves later moved to a root-level
# /opencode.slice. The OLD cgroup still exists and is EMPTY, so the glob kept
# matching, `[ -d ]` kept succeeding, and the sampler recorded a serve-slice row
# of zeros every 16 seconds for weeks without ever erroring. On 2026-09-16 the
# serve rows read 20-25 MB while the four live serves held 19.0 GB, and no
# per-serve row had been emitted at all since the move.
#
# That is the failure this suite is built around: NOT "does it crash on a bad
# path" but "does it notice when it is reading a cgroup that is real, readable,
# and not the one we mean". A test that only checked for errors would have
# passed throughout.
#
# The sampler is driven through its real env seams (PRESSURE_SAMPLER_CGROUP_ROOT,
# _PROC_ROOT, _DIR) against a fabricated cgroup tree, so the bytes under test are
# the bytes that ship.
set -o nounset
set -o pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; shift || true; for l in "$@"; do printf '      %s\n' "$l"; done; }

sampler="${PRESSURE_SAMPLER_BIN:-}"
if [ -z "$sampler" ]; then
  sampler="$(command -v pressure-sampler || true)"
fi
[ -n "$sampler" ] || { echo "FAIL: no pressure-sampler binary (set PRESSURE_SAMPLER_BIN)"; exit 1; }

# --- fake /proc ----------------------------------------------------------------------------------
# The sampler reads host-level fields before it ever reaches a cgroup. Without
# these it exits early and every cgroup assertion below would vacuously pass.
mkproc() {
  local p="$1"
  mkdir -p "$p/pressure"
  cat > "$p/meminfo" <<'EOF'
MemTotal:       65690184 kB
MemAvailable:   51200000 kB
SwapTotal:      32768000 kB
SwapFree:       29000000 kB
EOF
  printf 'cpu  100 0 200 900 0 0 0 0 0 0\n' > "$p/stat"
  for f in cpu memory io; do
    printf 'some avg10=0.00 avg60=0.00 avg300=0.00 total=1234\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=567\n' \
      > "$p/pressure/$f"
  done
}

# --- fake cgroup helpers -------------------------------------------------------------------------
mkcg() { # <dir> <memory.current> [io.stat rbytes]
  local d="$1" cur="$2" rb="${3:-}"
  mkdir -p "$d"
  printf '%s' "$cur"  > "$d/memory.current"
  printf '%s' "max"   > "$d/memory.max"
  printf 'anon %s\nfile 1024\n' "$cur" > "$d/memory.stat"
  printf 'max 7\noom_kill 0\n' > "$d/memory.events"
  printf 'usage_usec 42\n' > "$d/cpu.stat"
  if [ -n "$rb" ]; then
    printf '259:0 rbytes=%s wbytes=9 rios=1 wios=1\n' "$rb" > "$d/io.stat"
  fi
}

# PATH IS DELIBERATELY EMPTY, and this is the most important line in the file.
#
# An earlier revision of this harness prepended /run/current-system/sw/bin. That
# hid a defect strictly worse than the one the suite was written for: serve
# discovery used `find`, findutils was not in the package's runtimeInputs, and
# the user manager's PATH is systemd's own bin directory and nothing else. The
# shipped binary therefore reported "no serves" on every tick with four serves
# running, and this suite was green the whole time -- it proved the SCRIPT works
# when find is available, never that the BINARY can find find.
#
# writeShellApplication prepends runtimeInputs to PATH inside the script, so a
# correct package needs nothing from the caller. `env -i` with an empty PATH is
# what makes that a tested property instead of an assumption.
run_sampler() { # <cgroup root> <out dir> -> prints stderr to $tmpdir/err
  local cgroot="$1" outdir="$2"
  mkdir -p "$outdir"
  env -i \
    PRESSURE_SAMPLER_DIR="$outdir" \
    PRESSURE_SAMPLER_CGROUP_ROOT="$cgroot" \
    PRESSURE_SAMPLER_PROC_ROOT="$tmpdir/proc" \
    HOME="$tmpdir" \
    PATH=/var/empty \
    "$sampler" 2>"$tmpdir/err"
}

# Every row must have exactly as many fields as the header. emit_blank builds its
# width from COLS and the host row hand-counts 26 format specifiers; neither was
# pinned, so changing either silently produced a ragged file that only a reader
# would discover, months later, as mis-shifted columns.
assert_width() { # <tsv> <label>
  local f="$1" label="$2"
  if awk -F'\t' 'NR==1{n=NF; next} NF!=n{print NR": "NF" fields, want "n; bad=1} END{exit bad+0}' "$f"; then
    ok "every row has the header's field count ($label)"
  else
    bad "ragged rows: field count differs from the header ($label)"
  fi
}

# Column lookup by NAME, never by position. The file is a positional TSV with a
# header, and reading it as key=value returns a confident empty result rather
# than an error -- which is exactly how the p99 disk numbers were missed on
# 2026-09-16. Any test that hardcodes a column index inherits that trap.
field() { # <tsv> <subject> <column-name>
  local f="$1" subj="$2" col="$3"
  awk -F'\t' -v subj="$subj" -v col="$col" '
    NR==1 { for (i=1;i<=NF;i++) if ($i==col) c=i; next }
    $2==subj { print (c ? $c : "NOCOL"); exit }
  ' "$f"
}
subjects() { awk -F'\t' 'NR>1{print $2}' "$1" | sort -u | tr '\n' ' '; }

mkproc "$tmpdir/proc"

# =================================================================================================
# 1. Serves at the CURRENT location are found.
# =================================================================================================
root1="$tmpdir/cg1"; out1="$tmpdir/out1"
mkcg "$root1" 100 1000
mkcg "$root1/opencode.slice" 20000000000
mkcg "$root1/opencode.slice/opencode-serve.slice" 19000000000
mkcg "$root1/opencode.slice/opencode-serve.slice/opencode-serve@4096.service" 5000000000
mkcg "$root1/opencode.slice/opencode-serve.slice/opencode-serve@4097.service" 4000000000
run_sampler "$root1" "$out1"
tsv1="$(find "$out1" -name 'pressure-v2-*.tsv' | head -1)"
if [ -z "$tsv1" ]; then
  bad "sampler produced no output file at all"
else
  subs="$(subjects "$tsv1")"
  if grep -q 'serve ' <<<"$subs"; then
    ok "per-serve rows are emitted for serves at /opencode.slice"
  else
    bad "no per-serve rows for the CURRENT serve location" "subjects: $subs"
  fi
  got="$(field "$tsv1" serve mem_current)"
  if [ "$got" = "5000000000" ] || [ "$got" = "4000000000" ]; then
    ok "per-serve mem_current reflects the real cgroup ($got)"
  else
    bad "per-serve mem_current wrong" "got: '$got' want 5000000000 or 4000000000"
  fi
  got="$(field "$tsv1" serve-slice mem_current)"
  if [ "$got" = "19000000000" ]; then
    ok "serve-slice row reads the REAL parent slice"
  else
    bad "serve-slice mem_current wrong" "got: '$got' want 19000000000"
  fi
  assert_width "$tsv1" "serves present"
  # Nothing should be said when everything is found. Without this, a warning
  # that fired unconditionally would still satisfy the missing-serve assertion.
  if [ -s "$tmpdir/err" ]; then
    bad "sampler warned on stderr despite finding serves" "stderr: $(cat "$tmpdir/err")"
  else
    ok "sampler is silent on stderr when serves are found"
  fi
fi

# =================================================================================================
# 2. THE REGRESSION. An empty legacy cgroup must not win over the live one.
#    This is the exact production failure: both paths exist, the legacy one is
#    readable and empty, and the sampler reported it for weeks.
# =================================================================================================
root2="$tmpdir/cg2"; out2="$tmpdir/out2"
mkcg "$root2" 100 1000
mkcg "$root2/system.slice" 1
mkcg "$root2/system.slice/system-opencode\\x2dserve.slice" 34463744   # the ghost: real, readable, empty
mkcg "$root2/opencode.slice" 20000000000
mkcg "$root2/opencode.slice/opencode-serve.slice" 19000000000
mkcg "$root2/opencode.slice/opencode-serve.slice/opencode-serve@4096.service" 5000000000
run_sampler "$root2" "$out2"
tsv2="$(find "$out2" -name 'pressure-v2-*.tsv' | head -1)"
if [ -z "$tsv2" ]; then
  bad "no output in ghost-cgroup scenario"
else
  got="$(field "$tsv2" serve-slice mem_current)"
  if [ "$got" = "34463744" ]; then
    bad "GHOST REGRESSION: sampler reported the empty legacy slice" \
        "got 34463744 (the ghost) instead of 19000000000 (the live slice)" \
        "this is the 2026-09-16 production bug"
  elif [ "$got" = "19000000000" ]; then
    ok "live slice wins over an empty legacy slice (the ghost regression)"
  else
    bad "serve-slice mem_current unexpected in ghost scenario" "got: '$got'"
  fi
  if grep -q 'serve ' <<<"$(subjects "$tsv2")"; then
    ok "per-serve rows still emitted when a ghost slice is present"
  else
    bad "ghost slice suppressed the per-serve rows"
  fi
fi

# =================================================================================================
# 3. Legacy-only layout is still sampled.
#    NOT because "devbox has not moved" -- the sampler is wired only in
#    home.cloudbox.nix and devbox does not run it. Kept because the layout was
#    real and a host restored from an older generation would present it.
# =================================================================================================
root3="$tmpdir/cg3"; out3="$tmpdir/out3"
mkcg "$root3" 100 1000
mkcg "$root3/system.slice" 1
mkcg "$root3/system.slice/system-opencode\\x2dserve.slice" 8000000000
mkcg "$root3/system.slice/system-opencode\\x2dserve.slice/opencode-serve@4096.service" 8000000000
run_sampler "$root3" "$out3"
tsv3="$(find "$out3" -name 'pressure-v2-*.tsv' | head -1)"
if [ -n "$tsv3" ] && grep -q 'serve ' <<<"$(subjects "$tsv3")"; then
  ok "legacy system.slice layout is still sampled"
else
  bad "legacy layout no longer produces per-serve rows"
fi

# =================================================================================================
# 4. NO serve cgroup anywhere must be LOUD, not silent.
#    Silence is the failure mode that cost us the series; absence of serves has
#    to be visible in the data, not inferable from the lack of rows.
# =================================================================================================
root4="$tmpdir/cg4"; out4="$tmpdir/out4"
mkcg "$root4" 100 1000
run_sampler "$root4" "$out4"
tsv4="$(find "$out4" -name 'pressure-v2-*.tsv' | head -1)"
if [ -z "$tsv4" ]; then
  bad "sampler produced nothing when no serves exist (host rows should still emit)"
else
  subs4="$(subjects "$tsv4")"
  errtxt="$(cat "$tmpdir/err" 2>/dev/null || true)"
  if grep -q 'serve-missing' <<<"$subs4"; then
    ok "a missing serve cgroup is recorded IN the series (serve-missing row)"
  else
    bad "missing serve cgroup left no trace in the TSV" "subjects: $subs4"
  fi
  # Match the LITERAL message. `grep -qi serve` also passes on a bash crash
  # ("serve_cgs: unbound variable") or a permissions error, i.e. it would call
  # the script working at the moment it broke.
  if grep -q 'no opencode-serve@\*\.service cgroup under' <<<"$errtxt"; then
    ok "a missing serve cgroup warns on stderr with its literal message"
  else
    bad "missing serve cgroup produced no recognisable stderr warning" "stderr: '$errtxt'"
  fi
  assert_width "$tsv4" "serve-missing marker"
  if grep -q 'host ' <<<"$subs4"; then
    ok "host rows still emitted when serves are absent"
  else
    bad "absence of serves suppressed host rows too" "subjects: $subs4"
  fi
fi

# =================================================================================================
# 5. bazel-slice io_rbytes is populated when io.stat exists.
#    It was blank in production because the io controller was never enabled in
#    user@1000.service, so bazel.slice had no io.stat to read. Enabling
#    IOAccounting (workstation-o5s1.4) creates it; this pins that the sampler
#    actually reads it once present.
# =================================================================================================
root5="$tmpdir/cg5"; out5="$tmpdir/out5"
uid="$(id -u)"
mkcg "$root5" 100 1000
mkcg "$root5/user.slice" 1
mkcg "$root5/user.slice/user-$uid.slice" 1
mkcg "$root5/user.slice/user-$uid.slice/user@$uid.service" 1
mkcg "$root5/user.slice/user-$uid.slice/user@$uid.service/bazel.slice" 7000000000 123456789
run_sampler "$root5" "$out5"
tsv5="$(find "$out5" -name 'pressure-v2-*.tsv' | head -1)"
if [ -n "$tsv5" ]; then
  got="$(field "$tsv5" bazel-slice io_rbytes)"
  if [ "$got" = "123456789" ]; then
    ok "bazel-slice io_rbytes is read from io.stat when present"
  else
    bad "bazel-slice io_rbytes not read" "got: '$got' want 123456789"
  fi
else
  bad "no output in bazel io.stat scenario"
fi

# =================================================================================================
# 6. RETENTION ACTUALLY DELETES. This is the assertion that would have caught the
#    six-week silent failure: the sweep is `find ... -delete 2>/dev/null || true`,
#    findutils was not in runtimeInputs, and the missing binary was swallowed by
#    the very error handling meant to make the sweep harmless. On 2026-09-16
#    ~/metrics still held 11 files older than RETENTION_DAYS=30, back to 08-06.
#
#    Note this asserts a SIDE EFFECT on the filesystem, not a log line. The log
#    said nothing, which is exactly why it went unnoticed for six weeks.
# =================================================================================================
root6="$tmpdir/cg6"; out6="$tmpdir/out6"
mkcg "$root6" 100 1000
mkdir -p "$out6"
old_file="$out6/pressure-v2-2020-01-01.tsv"
new_file="$out6/pressure-v2-2029-01-01.tsv"
printf 'stale\n' > "$old_file"
printf 'fresh\n' > "$new_file"
touch -d '60 days ago' "$old_file"
touch "$new_file"
run_sampler "$root6" "$out6"
if [ -e "$old_file" ]; then
  bad "retention did not delete a file older than RETENTION_DAYS" \
      "this is the findutils-missing failure: the sweep cannot run, and" \
      "2>/dev/null || true hides it"
else
  ok "retention deletes files older than RETENTION_DAYS"
fi
if [ -e "$new_file" ]; then
  ok "retention leaves recent files alone"
else
  bad "retention deleted a RECENT file"
fi

# =================================================================================================
# 7. ATTACH TUIs (bead workstation-o5s1.13). tmux puts every spawned pane in its own
#    transient tmux-spawn-<uuid>.scope directly under the user manager. On
#    2026-09-17 those scopes held 10.35 GB across 38 TUIs -- the single largest
#    identifiable consumer under user@1000.service -- with MemoryMax=infinity and
#    no presence in any time series. The 2026-09-15 host swap jump of 11.43 GB
#    could not be attributed because of exactly this blind spot: serves (<=0.35 GB)
#    and bazel (<=0.27 GB) were both measurably pinned at their caps, and the
#    ~10.8 GB remainder came from a population nothing sampled.
# =================================================================================================
root7="$tmpdir/cg7"; out7="$tmpdir/out7"
uid7="$(id -u)"
umgr7="$root7/user.slice/user-$uid7.slice/user@$uid7.service"
mkcg "$root7" 100 1000
mkcg "$root7/user.slice" 1
mkcg "$root7/user.slice/user-$uid7.slice" 1
mkcg "$umgr7" 1
mkcg "$umgr7/tmux-spawn-e621090f-77a0-4213-9326-5046b50791a5.scope" 6357421056
mkcg "$umgr7/tmux-spawn-5fd961ee-c739-4613-9e14-7c9aa348b293.scope" 1514139648
# NESTED. tmux sets each pane scope's Slice= from the tmux SERVER's slice
# (compat/systemd.c, sd_pid_get_user_slice), falling back to app-tmux.slice when
# the server was started from outside the user session -- which is exactly what
# oc-auto-attach does via pigeon-daemon.service (User=dev, /system.slice/...),
# and what tmux.devbox.nix does by running the server as a user service. A
# depth-1 glob finds NOTHING in that arrangement, and because absence here is
# deliberately silent, nobody would ever be told.
mkcg "$umgr7/app.slice" 1
mkcg "$umgr7/app.slice/app-tmux.slice" 1
mkcg "$umgr7/app.slice/app-tmux.slice/tmux-spawn-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.scope" 900000000
run_sampler "$root7" "$out7"
tsv7="$(find "$out7" -name 'pressure-v2-*.tsv' | head -1)"
if [ -z "$tsv7" ]; then
  bad "no output in tmux-scope scenario"
else
  subs7="$(subjects "$tsv7")"
  if grep -q 'tmux-scope' <<<"$subs7"; then
    ok "tmux pane scopes are sampled at all"
  else
    bad "tmux-spawn scopes are not sampled" "subjects: $subs7"
  fi
  n7=$(awk -F'\t' '$2=="tmux-scope"' "$tsv7" | wc -l)
  if [ "$n7" -eq 3 ]; then
    ok "one row per tmux-spawn scope, including nested ones (got $n7)"
  else
    bad "wrong number of tmux-scope rows" "got $n7, want 3 (one is nested under app-tmux.slice)"
  fi
  got="$(field "$tsv7" tmux-scope mem_current)"
  if [ "$got" = "6357421056" ] || [ "$got" = "1514139648" ]; then
    ok "tmux-scope mem_current reflects the real cgroup ($got)"
  else
    bad "tmux-scope mem_current wrong" "got: '$got'"
  fi
  # The detail column must identify WHICH scope, or the rows cannot be told
  # apart and per-TUI growth is invisible.
  d7=$(awk -F'\t' '$2=="tmux-scope"{print $3}' "$tsv7" | sort -u | wc -l)
  if [ "$d7" -eq 3 ]; then
    ok "each tmux-scope row is identified by its own scope in the detail column"
  else
    bad "tmux-scope rows are not distinguishable" "distinct detail values: $d7, want 3"
  fi
  if awk -F'\t' '$2=="tmux-scope"{if($3 !~ /^tmux-spawn-.*\.scope$/) bad=1} END{exit bad+0}' "$tsv7"; then
    ok "tmux-scope detail is the bare scope name, not a path"
  else
    bad "tmux-scope detail is not a bare scope name"
  fi
  # The aggregate. This is what makes the silence in scenario 8 survivable:
  # compare the user-manager total against the sum of its sampled children, and
  # a growing residual says an unsampled population exists. Without it, "no tmux
  # panes" and "tmux moved somewhere we do not look" are indistinguishable --
  # which is the exact failure this suite exists for.
  if grep -q 'user-manager' <<<"$subs7"; then
    ok "a user-manager aggregate row is emitted"
  else
    bad "no user-manager aggregate row; silence about children becomes undetectable"
  fi
  assert_width "$tsv7" "tmux scopes"
fi

# =================================================================================================
# 8. NO TUIs must be SILENT. This is the deliberate opposite of the serve case,
#    and it is pinned so nobody makes it symmetrical "for consistency". Zero
#    attach TUIs is a legitimate state -- nobody has a tmux pane open -- whereas
#    zero serves means the pool is down or we are reading the wrong cgroup. A
#    marker here would fire constantly and train everyone to ignore markers.
# =================================================================================================
root8="$tmpdir/cg8"; out8="$tmpdir/out8"
uid8="$(id -u)"
mkcg "$root8" 100 1000
mkcg "$root8/user.slice" 1
mkcg "$root8/user.slice/user-$uid8.slice" 1
mkcg "$root8/user.slice/user-$uid8.slice/user@$uid8.service" 1
mkcg "$root8/opencode.slice" 1
mkcg "$root8/opencode.slice/opencode-serve.slice" 1
mkcg "$root8/opencode.slice/opencode-serve.slice/opencode-serve@4096.service" 5000000000
run_sampler "$root8" "$out8"
tsv8="$(find "$out8" -name 'pressure-v2-*.tsv' | head -1)"
if [ -n "$tsv8" ]; then
  subs8="$(subjects "$tsv8")"
  if grep -q 'tmux' <<<"$subs8"; then
    bad "absence of tmux panes emitted some tmux-ish row" \
        "zero panes is a legitimate state; a marker here is noise, not signal" \
        "subjects: $subs8"
  else
    ok "absence of attach TUIs is silent in the series (no marker)"
  fi
  if grep -qi 'tmux' <<<"$(cat "$tmpdir/err" 2>/dev/null || true)"; then
    bad "absence of TUIs warned on stderr" "stderr: $(cat "$tmpdir/err")"
  else
    ok "absence of attach TUIs is silent on stderr"
  fi
fi

# --- summary -------------------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -eq 0 ]; then
  printf 'ALL PASS (%d assertions)\n' "$PASS"
  exit 0
fi
exit 1
