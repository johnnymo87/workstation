#!@bash@
# em-history-shell-probe: does bubblewrap still work under the hardening that
# hosts/devbox/em-history-shell.nix puts on the service? Run it BEFORE the rebuild:
#
#     P=$(nix build --no-link --print-out-paths .#em-history-shell)   # as yourself
#     sudo "$P/bin/em-history-shell-probe"
#     "$P/bin/em-history-shell-probe" --dry-run                        # prints the commands
#
# It needs no service, no user and no rebuild: each run is a transient
# `systemd-run --wait --pipe -p DynamicUser=yes -p <props>` unit that starts the SAME
# bwrap argv the server builds (server.py build_argv) around a stand-in history view,
# and runs a tool smoke test inside it: python3, rg, jq, a fork, /proc, the view.
# Seeing `true` run is not enough: the sandbox can start and the tools still fail.
#
# What it prints, one line per run:
#   NONE      only DynamicUser: bwrap works on this host at all (if not, nothing below
#             means anything: user namespaces or the seccomp program are the problem)
#   ALL       every prop of the unit: THIS is the verdict for the service as written
#   +<prop>   NONE plus that one prop: which props break bwrap by themselves
#   -<prop>   ALL minus that one prop: which prop to drop when ALL fails
# The "candidate" props are the ones the unit leaves OFF (ProtectKernelTunables,
# ProtectProc, ProcSubset, ...): they are run only as +<prop>, to show why.
#
# The stand-in view is under /run, not /tmp: with PrivateTmp the unit gets its own
# /tmp, so a view made there would be invisible and PrivateTmp would be blamed for it.
#
# --user runs the matrix in your user manager instead of as root (no DynamicUser, no
# sudo). It is only INDICATIVE: the unit is then already inside a user namespace, so
# bwrap's own userns is nested, which the real service does not have, and two props
# (CapabilityBoundingSet, ProtectHome) cannot be tested that way. Use it to check the
# script, not to decide.
#
# Keep PROPS in step with serviceConfig in hosts/devbox/em-history-shell.nix.
set -euo pipefail
# systemd-run comes from the running system (it must match the running systemd).
PATH="@coreutils@/bin:$PATH"

CONFIG='@config@'
JQ='@jq@'
DRY=0
USER_MODE=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY=1 ;;
    --user) USER_MODE=1 ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d'; exit 0 ;;
    *) echo "unknown argument: $arg (try --help)" >&2; exit 2 ;;
  esac
done

if [ "$DRY" = 0 ] && [ "$USER_MODE" = 0 ] && [ "$(id -u)" != 0 ]; then
  echo "run me with sudo (DynamicUser units need root), or use --dry-run / --user" >&2
  exit 2
fi

BWRAP=$("$JQ" -r .bwrap "$CONFIG")
TOOLS=$("$JQ" -r .tools "$CONFIG")
SECCOMP=$("$JQ" -r .seccomp "$CONFIG")
mapfile -t CLOSURE < <("$JQ" -r '.closure[]' "$CONFIG")

STAND_BASE=/run
[ "$USER_MODE" = 0 ] || STAND_BASE=${XDG_RUNTIME_DIR:-/tmp}
if [ "$DRY" = 1 ]; then
  STAND_IN=$STAND_BASE/em-hs-probe.DRYRUN
else
  STAND_IN=$(mktemp -d "$STAND_BASE/em-hs-probe.XXXXXX")
  trap 'rm -rf "$STAND_IN"' EXIT
  mkdir -p "$STAND_IN/agent-history/jonathan/warrior" "$STAND_IN/agent-history/livia/son"
  : > "$STAND_IN/agent-history/.agent-history-root"
  echo '{"turn":1,"text":"hello from the stand-in view"}' \
    > "$STAND_IN/agent-history/jonathan/warrior/2026-01-01.jsonl"
  # A DynamicUser has to be able to read it, like the ACL lets the service user.
  chmod -R a+rX "$STAND_IN"
fi
VIEW="$STAND_IN/agent-history/jonathan/warrior"

# The hardening of the unit, one prop per element. DynamicUser stands in for
# User=em-history-shell; the socket (StandardInput) is not part of the sandbox.
PROPS=(
  'PrivateTmp=yes'
  'PrivateDevices=yes'
  'PrivateNetwork=yes'
  'ProtectSystem=strict'
  'ProtectHome=tmpfs'
  'NoNewPrivileges=yes'
  'CapabilityBoundingSet='
  'RestrictNamespaces=user mnt pid net ipc uts cgroup'
  'SystemCallFilter=@system-service @mount sethostname'
  'SystemCallErrorNumber=EPERM'
  'SystemCallArchitectures=native'
  'MemoryMax=384M'
  'MemorySwapMax=0'
  'TasksMax=48'
  'CPUQuota=100%'
  'ReadOnlyPaths=-/var/lib/eternal-machinery'
)
if [ "$USER_MODE" = 1 ]; then
  # A user manager cannot drop capabilities (exit 218), and ProtectHome=tmpfs hides
  # /run/user, where the user-mode stand-in view lives: neither says anything about
  # the service. Both stay in the root run.
  kept=()
  for prop in "${PROPS[@]}"; do
    case "$prop" in CapabilityBoundingSet=|ProtectHome=*) ;; *) kept+=("$prop") ;; esac
  done
  PROPS=("${kept[@]}")
fi
# Left OFF in the unit. Each is run alone, to show what it does to bwrap's --proc.
CANDIDATES=(
  'ProtectKernelTunables=yes'
  'ProtectProc=invisible'
  'ProcSubset=pid'
  'ProtectControlGroups=yes'
  'ProtectKernelModules=yes'
  'RestrictAddressFamilies=AF_UNIX'
  'LockPersonality=yes'
  'MemoryDenyWriteExecute=yes'
  'RestrictSUIDSGID=yes'
)

# The tool smoke test, run by bash inside the sandbox. It prints PROBE-OK last.
SMOKE='set -e
python3 -c "import json,sys; print(sum(range(10)))" >/dev/null
rg --version >/dev/null
test "$(echo "{\"a\":7}" | jq .a)" = 7
x=$(echo forked | cat); test "$x" = forked
( : ) & wait
ls /proc/self/status >/dev/null
grep -q "^Seccomp:.2" /proc/self/status
head -c 20 /history/jonathan/warrior/2026-01-01.jsonl >/dev/null
echo hi > /scratch/f; test "$(cat /scratch/f)" = hi
test ! -e /history/livia
echo PROBE-OK'

# server.py build_argv, in shell. Keep in step with it.
bwrap_argv() {
  BWRAP_ARGV=(
    "$BWRAP" --unshare-user --unshare-pid --unshare-net --unshare-ipc --unshare-uts
    --unshare-cgroup --disable-userns --die-with-parent --new-session --clearenv
    --cap-drop ALL --seccomp 3
  )
  local path
  for path in "${CLOSURE[@]}"; do BWRAP_ARGV+=(--ro-bind "$path" "$path"); done
  BWRAP_ARGV+=(
    --symlink "$TOOLS/bin" /bin --proc /proc --dev /dev
    --size 67108864 --tmpfs /scratch --size 16777216 --tmpfs /tmp
    --dir /history --ro-bind "$VIEW" /history/jonathan/warrior
    --remount-ro / --remount-ro /dev
    --setenv PATH /bin --setenv HOME /scratch --setenv TMPDIR /tmp
    --setenv LANG C.UTF-8 --setenv PYTHONNOUSERSITE 1 --setenv PYTHONDONTWRITEBYTECODE 1
    --chdir /scratch -- /bin/bash --noprofile --norc -c "$SMOKE"
  )
}
bwrap_argv

# DynamicUser=yes implies PrivateTmp, ProtectSystem=strict and ProtectHome=read-only.
# A run that does not name one of them turns it off, so that +X and -X mean what they say.
IMPLIED=(PrivateTmp ProtectSystem ProtectHome)

# run_one LABEL PROP... : one transient unit.
RESULTS=()
run_one() {
  local label=$1; shift
  local head=(systemd-run --wait --pipe --collect --quiet --expand-environment=no)
  if [ "$USER_MODE" = 1 ]; then head+=(--user); else head+=(-p DynamicUser=yes); fi
  local prop name given
  for name in "${IMPLIED[@]}"; do
    given=0
    for prop in "$@"; do
      case "$prop" in "$name"=*) given=1 ;; esac
    done
    [ "$given" = 1 ] || head+=(-p "$name=no")
  done
  for prop in "$@"; do head+=(-p "$prop"); done
  # fd 3 is the seccomp program, as in the server; the unit's bash opens it for bwrap.
  local cmd=("${head[@]}" -- @bash@ -c 'exec 3<"$1"; shift; exec "$@"' probe "$SECCOMP" "${BWRAP_ARGV[@]}")
  if [ "$DRY" = 1 ]; then
    printf '# %s\n' "$label"
    printf '%q ' "${head[@]}"
    printf -- '-- bash -c <open fd 3> probe %q <bwrap argv>\n' "$SECCOMP"
    return 0
  fi
  local out last rc=0
  out=$("${cmd[@]}" 2>&1) || rc=$?
  last=$(printf '%s\n' "$out" | tail -n 1)
  if [ "$rc" = 0 ] && [ "$last" = PROBE-OK ]; then
    printf '%-52s OK\n' "$label"
    RESULTS+=("$label=OK")
  else
    [ "$rc" != 0 ] || rc=99
    printf '%-52s FAIL rc=%s  %s\n' "$label" "$rc" "${last:0:110}"
    RESULTS+=("$label=FAIL")
  fi
}

if [ "$DRY" = 1 ]; then
  echo "# bwrap argv (each run below passes it after the systemd-run words):"
  printf '#   %q\n' "${BWRAP_ARGV[@]}"
  echo
fi
run_one NONE
run_one ALL "${PROPS[@]}"
for prop in "${PROPS[@]}" "${CANDIDATES[@]}"; do
  run_one "+$prop" "$prop"
done
for i in "${!PROPS[@]}"; do
  rest=("${PROPS[@]:0:$i}" "${PROPS[@]:$((i + 1))}")
  run_one "-${PROPS[$i]}" "${rest[@]}"
done

[ "$DRY" = 0 ] || exit 0
echo
verdict() {  # verdict LABEL -> OK|FAIL|?
  local r
  for r in "${RESULTS[@]}"; do
    if [ "${r%=*}" = "$1" ]; then echo "${r##*=}"; return; fi
  done
  echo '?'
}
echo "NONE: $(verdict NONE)   ALL: $(verdict ALL)"
if [ "$(verdict NONE)" != OK ]; then
  echo "bwrap does not work here even without hardening: fix that first (user namespaces? the seccomp program?)."
  exit 1
fi
if [ "$(verdict ALL)" = OK ]; then
  echo "The unit's hardening as written works. Rebuild."
  exit 0
fi
echo "The unit's hardening as written BREAKS the sandbox. Props that fail alone (+) or whose removal fixes ALL (-):"
for r in "${RESULTS[@]}"; do
  case "$r" in
    +*=FAIL) echo "  breaks alone:  ${r%=*}" ;;
    -*=OK)   echo "  drop to fix:   ${r%=*}" ;;
  esac
done
exit 1
