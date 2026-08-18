#!/usr/bin/env bash
# unwired-test(workstation-le0a): run by hand after any deploy that changes the
# serve units' Slice=. Not in `nix flake check` -- it inspects the LIVE cgroup
# hierarchy of a running pool, which a build sandbox does not have.
#
# WHY THIS EXISTS AS A SCRIPT RATHER THAN A NOTE
#
# Attaching `Slice=` to the serve units without restarting them in the same
# deploy silently DELETES the per-serve memory limits: systemd re-realizes the
# units as members of the new slice while the processes stay in the old one,
# `memory` drops out of the old slice's cgroup.subtree_control, and
# memory.max/memory.swap.max cease to exist. All four serves then run with no
# limit at all. That happened on 2026-08-02 and was reverted in PR #264.
#
# The reason it went unnoticed is the important part: `systemctl show` reported
# the configured values perfectly the whole time. It reports what the unit ASKS
# for, not what the kernel is ENFORCING, and the failure mode here is a missing
# file. An instrument that cannot express the failure cannot detect it. So the
# limit assertions below read cgroupfs and nothing else.
#
# WHY THE CGROUP PATH IS DISCOVERED RATHER THAN HARDCODED (2026-08-12)
#
# The first version of this script hardcoded
#     SLICE_DIR=/sys/fs/cgroup/system.slice/opencode-serve.slice
# and that path CANNOT EVER EXIST, so the script would have failed on a
# perfectly correct deploy -- and the runbook says to revert on failure, so a
# good change would have been reverted for a bad reason.
#
# systemd derives a slice's PARENT from the dashes in its own name: `a-b.slice`
# nests inside `a.slice`. So `opencode-serve.slice` lives under `opencode.slice`
# (`/sys/fs/cgroup/opencode.slice/opencode-serve.slice`), NOT under system.slice,
# even though the units in it are system services. Putting it under system.slice
# would require naming the unit `system-opencode\x2dserve.slice`, with the dash
# escaped so it is not read as a hierarchy separator. Both are legal; the point
# is that the layout follows the NAME, and a hand-written path silently encodes
# a guess about it.
#
# So we discover the truth instead, from /proc/<MainPID>/cgroup -- where the
# process ACTUALLY is. That is also the strictly better instrument for this
# specific incident: the 2026-08-02 failure WAS a divergence between where the
# unit said the process was and where it really was, so a check that derives
# its path from systemd's opinion could not have seen it. /proc cannot lie about
# this.
#
# WHY MEMBERSHIP IS DECLARED RATHER THAN OBSERVED (workstation-ixw7, 2026-08-17)
#
# Every assertion used to iterate `list-units --state=active`, so a serve that
# was dead was simply absent from the set, not asserted over, and therefore
# unable to fail. On 2026-08-12 serve 4096 lost its first start to the
# `database is locked` race (workstation-wmrt) and systemd restarted it 10s
# later; the verifier ran inside that window and printed
#     PASS: active units: opencode-serve@4097 opencode-serve@4098 opencode-serve@4099
#     ==== 9 passed, 0 failed ====
# Three serves, exit 0. A pool at 75% strength recorded as a clean verification.
#
# So the EXPECTED set now comes from the pool target's ConsistsOf (the inverse of
# the services' PartOf=), and a member that is missing is a named FAIL. Verified
# empirically before relying on it: a STOPPED unit is still listed in ConsistsOf
# (LoadState=loaded, ActiveState=inactive), which is exactly what makes it usable
# as a declared-membership source. Note ConsistsOf order is NOT deterministic
# (the real pool returns 4096 4098 4099 4097), so everything here sorts.
#
# TWO-SIDED, because the drift runs both ways. The sweeper's discovery loop in
# configuration.nix guards an expected list AND a running glob for this reason.
# `restartIfChanged = false` on the serve units makes "config deployed but pool
# not yet bounced" a NORMAL state on this host, so a unit dropped from
# serve-pool.nix can still be running with its old config -- and, in the
# slice-migration failure class this script exists for, possibly with no memory
# limit. That stray is invisible to an expected-set-only check, so we also assert
# no ACTIVE serve unit is absent from the target.
#
# WHY IT WAITS INSTEAD OF FAILING FAST (the same 847ec73 trap, one level up)
#
# The naive version of this fix -- ActiveState != active is a FAIL -- would have
# been a WORSE bug than the one it fixes. The `database is locked` race is a
# FIRST-START race between four serves contending for one opencode.db, so its
# probability is concentrated at the moment all four start together: the pool
# bounce, i.e. the deploy step immediately before this script runs. Strict
# failure would therefore tell the operator to revert good deploys routinely,
# and a revert is another bounce, which kills every live session. A false FAIL
# here is more expensive than a false PASS.
#
# So a member that is merely not-yet-up is a SOFT failure and we re-run the whole
# pass until it settles or the deadline expires. A member that is `failed`, or
# whose LoadState is not `loaded`, will not self-heal and fails immediately.
# Re-running the WHOLE pass (rather than tracking per-unit state) also means a
# member that passes and then dies mid-script re-enters the wait instead of
# producing torn output.
#
# WHAT THIS SCRIPT STILL CANNOT EXPRESS -- do not read a green run as more than
# it is:
#   * It is a SNAPSHOT. A member can die one second after a clean pass. The
#     settle-wait narrows that window, it does not close it. Comparing
#     InvocationID across a restart is the real fix (workstation-rl3k).
#   * "Deployed but not running the deployed config." With restartIfChanged =
#     false, a switch without a bounce leaves the OLD processes serving and this
#     script happily verifies them -- right answer, wrong entity in the time
#     dimension. Mitigated only by printing ActiveEnterTimestamp/NRestarts below
#     so an operator can eyeball "active since 3 days ago" after a deploy that
#     should have bounced.
#   * Units are not listeners. This proves a unit's MainPID sits in the right
#     cgroup under an enforced limit. It says nothing about what is actually
#     bound to :4096-4099; the port/PID fences in configuration.nix own that.
#
# Usage:  ./hosts/cloudbox/verify-serve-slice.sh [expected_per_serve] [expected_slice] [slice_unit]
#
# Test seams (all echoed in the summary line when non-default, so a pasted
# transcript cannot hide that the run was narrowed):
#   VERIFY_SYSTEMCTL        default: systemctl
#   VERIFY_POOL_TARGET      default: opencode-serve-pool.target
#   VERIFY_UNIT_GLOB        default: opencode-serve@*.service
#   VERIFY_SETTLE_DEADLINE  default: 60   (seconds; 0 disables waiting)
#   VERIFY_SETTLE_INTERVAL  default: 3    (seconds between passes)
# hosts/cloudbox/test-verify-serve-membership.sh drives these against a scratch
# user-level pool, which is how the failure branch is proven without stopping a
# production serve.
set -u

EXPECT_SERVE=${1:-15032385536}          # 14G. workstation-8rou (14G->10G) was
                                        # CLOSED as no-longer-motivated on
                                        # 2026-08-17: per-serve peak is ~1.2G, so
                                        # 10G buys nothing the 32G aggregate cap
                                        # does not already provide. 14G stands.
EXPECT_SLICE=${2:-34359738368}          # 32G
EXPECT_SLICE_UNIT=${3:-opencode-serve.slice}

POOL_TARGET=${VERIFY_POOL_TARGET:-opencode-serve-pool.target}
UNIT_GLOB=${VERIFY_UNIT_GLOB:-'opencode-serve@*.service'}
SETTLE_DEADLINE=${VERIFY_SETTLE_DEADLINE:-60}
SETTLE_INTERVAL=${VERIFY_SETTLE_INTERVAL:-3}
read -r -a SCTL <<< "${VERIFY_SYSTEMCTL:-systemctl}"

TMPD=$(mktemp -d) || exit 1
trap 'rm -rf "$TMPD"' EXIT
REPORT="$TMPD/report"

# Real cgroup dir of a PID, from /proc. cgroup2 lines look like `0::/system.slice/foo`.
pid_cgroup_dir() {
  local rel
  rel=$(sed -n 's|^0::||p' "/proc/$1/cgroup" 2>/dev/null) || return 1
  [ -n "$rel" ] || return 1
  printf '/sys/fs/cgroup%s' "$rel"
}

# Name-keyed property read. `systemctl show --value -p A,B` returns values in
# SYSTEMD's order, not the order requested, so positional parsing silently
# transposes fields -- the same class of bug as reporting a 32-hex InvocationID
# as a pid. Always key by name.
prop() { printf '%s\n' "$2" | awk -F= -v k="$1" '$1==k{sub("^" k "=","",$0); print; exit}'; }

# One full verification pass. Writes its human report to $REPORT and echoes
# "PASS FAIL HARD SOFT" on stdout. HARD failures will not self-heal; SOFT ones
# (a member not yet up) are what the settle-wait waits for.
run_pass() {
  local P=0 F=0 HARD=0 SOFT=0
  ok()       { echo "  PASS: $1"; P=$((P+1)); }
  bad_hard() { echo "  FAIL: $1"; F=$((F+1)); HARD=$((HARD+1)); }
  bad_soft() { echo "  WAIT: $1"; F=$((F+1)); SOFT=$((SOFT+1)); }

  {
    # ---- expected membership, declared by the pool target -------------------
    echo "== the pool target declares its members =="
    local tstate tload raw rc
    tstate=$("${SCTL[@]}" show "$POOL_TARGET" -p LoadState -p ActiveState --no-pager 2>/dev/null)
    rc=$?
    if [ $rc -ne 0 ]; then
      bad_hard "cannot query $POOL_TARGET (systemctl exit $rc)"
    fi
    tload=$(prop LoadState "$tstate")
    # `systemctl show` exits 0 for a unit that does not exist, so the exit code
    # above proves nothing on its own; LoadState is the load-bearing check.
    if [ "$tload" != "loaded" ]; then
      bad_hard "$POOL_TARGET LoadState=${tload:-<empty>} (expected loaded) — cannot determine expected membership"
    else
      ok "$POOL_TARGET is loaded"
    fi

    raw=$("${SCTL[@]}" show "$POOL_TARGET" --value -p ConsistsOf 2>/dev/null)
    rc=$?
    [ $rc -eq 0 ] || bad_hard "cannot read ConsistsOf of $POOL_TARGET (systemctl exit $rc)"

    local EXPECTED=""
    local u
    for u in $raw; do
      # shellcheck disable=SC2254 # UNIT_GLOB is intentionally a glob pattern
      case "$u" in $UNIT_GLOB) EXPECTED="$EXPECTED$u"$'\n' ;; esac
    done
    EXPECTED=$(printf '%s' "$EXPECTED" | sed '/^$/d' | sort)

    if [ -z "$EXPECTED" ]; then
      bad_hard "no units matching '$UNIT_GLOB' in $POOL_TARGET ConsistsOf — refusing to verify nothing"
      echo
      echo "==== $P passed, $F failed ===="
      printf '%s %s %s %s\n' "$P" "$F" "$HARD" "$SOFT" > "$TMPD/counts"
      return
    fi
    ok "expected members ($(printf '%s\n' "$EXPECTED" | wc -l | tr -d ' ')): $(printf '%s' "$EXPECTED" | tr '\n' ' ')"

    # ---- the other drift direction: an ACTIVE serve nobody declared ---------
    # `restartIfChanged = false` makes "deployed but not bounced" normal, so a
    # unit removed from serve-pool.nix can still be running with old config.
    local ACTIVE
    ACTIVE=$("${SCTL[@]}" list-units "$UNIT_GLOB" --no-legend --plain --state=active 2>/dev/null | awk '{print $1}' | sed '/^$/d' | sort)
    local stray
    stray=$(comm -13 <(printf '%s\n' "$EXPECTED") <(printf '%s\n' "$ACTIVE") | sed '/^$/d')
    if [ -n "$stray" ]; then
      for u in $stray; do
        bad_hard "$u is ACTIVE but not declared by $POOL_TARGET — stray serve, may predate the current config"
      done
    else
      ok "no stray active serve units outside $POOL_TARGET"
    fi

    # ---- per-member assertions, over the EXPECTED set ----------------------
    echo "== every DECLARED member is up, in $EXPECT_SLICE_UNIT, with an ENFORCED limit =="
    local SLICE_DIR="" ustate ls_ as_ ss_ mp nr aet port real parent leaf f v
    for u in $EXPECTED; do
      port=${u##*@}; port=${port%.service}

      ustate=$("${SCTL[@]}" show "$u" -p LoadState -p ActiveState -p SubState -p MainPID -p NRestarts -p ActiveEnterTimestamp --no-pager 2>/dev/null)
      ls_=$(prop LoadState "$ustate")
      as_=$(prop ActiveState "$ustate")
      ss_=$(prop SubState "$ustate")
      mp=$(prop MainPID "$ustate")
      nr=$(prop NRestarts "$ustate")
      aet=$(prop ActiveEnterTimestamp "$ustate")

      if [ "$ls_" != "loaded" ]; then
        bad_hard "$port: LoadState=${ls_:-<empty>} (expected loaded) — declared but not loadable"
        continue
      fi

      if [ "$as_" != "active" ]; then
        # `failed` will not self-heal (Restart=always means we only land here on
        # a start-limit trip or an admin stop); anything else may still be the
        # wmrt restart cycle in flight.
        if [ "$as_" = "failed" ] || [ "$ss_" = "failed" ]; then
          bad_hard "$port: $u is FAILED (ActiveState=$as_ SubState=$ss_ NRestarts=${nr:-?}) — will not self-heal"
        else
          bad_soft "$port: $u is ActiveState=$as_ SubState=$ss_ (NRestarts=${nr:-?}) — not up yet"
        fi
        continue
      fi

      # Informational, not an assertion: catches "deployed but never bounced"
      # (active since days ago) and post-wmrt healthy restarts (NRestarts>0).
      ok "$port: active since ${aet:-?} (NRestarts=${nr:-0})"

      if [ -z "$mp" ] || [ "$mp" = "0" ]; then bad_soft "$port: active but no MainPID yet"; continue; fi

      real=$(pid_cgroup_dir "$mp")
      if [ -z "$real" ]; then bad_soft "$port: cannot read /proc/$mp/cgroup (process may be exiting)"; continue; fi

      # Where the process actually lives, and which slice dir that implies.
      parent=$(dirname "$real")
      leaf=$(basename "$parent")
      if [ "$leaf" = "$EXPECT_SLICE_UNIT" ]; then
        ok "$port: MainPID $mp is really in $leaf"
      else
        bad_hard "$port: MainPID $mp is in '$leaf', expected '$EXPECT_SLICE_UNIT' (cgroup: $real)"
      fi

      # All members must agree on one slice, or the pool is split across two.
      if [ -z "$SLICE_DIR" ]; then SLICE_DIR=$parent
      elif [ "$SLICE_DIR" != "$parent" ]; then
        bad_hard "$port: pool is SPLIT across slices ($SLICE_DIR vs $parent)"
      fi

      # The limit, read from the cgroup the process is genuinely in.
      f="$real/memory.max"
      if [ ! -f "$f" ]; then
        bad_hard "$port: $f DOES NOT EXIST — this is the PR #264 failure; the serve is UNBOUNDED"
        continue
      fi
      v=$(cat "$f")
      [ "$v" = "$EXPECT_SERVE" ] && ok "$port: memory.max=$v" || bad_hard "$port: memory.max=$v expected $EXPECT_SERVE"
    done

    if [ -z "$SLICE_DIR" ]; then
      # No live member to derive the slice from. If members are merely still
      # coming up this is SOFT and the settle-wait will retry; the per-member
      # loop above has already recorded why.
      if [ "$SOFT" -gt 0 ]; then
        bad_soft "no member is up yet, so the slice dir cannot be determined"
      else
        bad_hard "could not determine the slice dir from any declared member"
      fi
      echo
      echo "==== $P passed, $F failed ===="
      printf '%s %s %s %s\n' "$P" "$F" "$HARD" "$SOFT" > "$TMPD/counts"
      return
    fi

    echo "== the slice delegates 'memory' to its children =="
    # Without this, per-serve memory.max files cannot exist no matter what the
    # unit says. This is the exact bit that got dropped in the 2026-08-02 incident.
    local SUB SMAX
    SUB=$(cat "$SLICE_DIR/cgroup.subtree_control" 2>/dev/null || echo "")
    case " $SUB " in
      *" memory "*) ok "cgroup.subtree_control has memory ($SUB)" ;;
      *) bad_hard "cgroup.subtree_control lacks memory ($SUB) — per-serve limits CANNOT be enforced" ;;
    esac

    echo "== the slice's own aggregate cap =="
    SMAX=$(cat "$SLICE_DIR/memory.max" 2>/dev/null || echo missing)
    if [ "$SMAX" = "$EXPECT_SLICE" ]; then
      ok "slice memory.max=$SMAX ($SLICE_DIR)"
    else
      bad_hard "slice memory.max=$SMAX expected $EXPECT_SLICE ($SLICE_DIR)"
    fi

    echo
    echo "==== $P passed, $F failed ===="
  } > "$REPORT" 2>&1

  printf '%s %s %s %s\n' "$P" "$F" "$HARD" "$SOFT" > "$TMPD/counts"
}

# ---- settle-wait ------------------------------------------------------------
START=$(date +%s)
ATTEMPTS=0
while :; do
  ATTEMPTS=$((ATTEMPTS+1))
  run_pass
  read -r P F HARD SOFT < "$TMPD/counts"

  [ "$F" -eq 0 ] && break          # clean pass
  [ "$HARD" -gt 0 ] && break       # will not self-heal; do not burn the deadline
  [ "$SETTLE_DEADLINE" -le 0 ] && break

  ELAPSED=$(( $(date +%s) - START ))
  [ $((ELAPSED + SETTLE_INTERVAL)) -gt "$SETTLE_DEADLINE" ] && break
  sleep "$SETTLE_INTERVAL"
done

cat "$REPORT"

if [ "$ATTEMPTS" -gt 1 ]; then
  echo "(settled over $ATTEMPTS passes, $(( $(date +%s) - START ))s of a ${SETTLE_DEADLINE}s deadline)"
fi
if [ "$SOFT" -gt 0 ]; then
  echo "NOTE: a member was still not up at the deadline. The workstation-wmrt"
  echo "      'database is locked' first-start race self-heals in ~10s; a member"
  echo "      still not active after ${SETTLE_DEADLINE}s is crash-looping instead."
  echo "      Check: journalctl -u <unit> -n 50 --no-pager"
fi

# Any non-default seam is named here, not only in the header: pasted transcripts
# get truncated from the top, and a narrowed run must not be able to look like a
# full one.
SEAMS=""
[ "${VERIFY_SYSTEMCTL:-systemctl}" != "systemctl" ] && SEAMS="$SEAMS systemctl='${VERIFY_SYSTEMCTL}'"
[ "$POOL_TARGET" != "opencode-serve-pool.target" ] && SEAMS="$SEAMS target=$POOL_TARGET"
[ "$UNIT_GLOB" != 'opencode-serve@*.service' ] && SEAMS="$SEAMS glob=$UNIT_GLOB"
[ "$SETTLE_DEADLINE" != "60" ] && SEAMS="$SEAMS deadline=${SETTLE_DEADLINE}s"
[ -n "$SEAMS" ] && echo "==== NON-DEFAULT SEAMS:$SEAMS ===="

[ "$F" -eq 0 ] || exit 1
