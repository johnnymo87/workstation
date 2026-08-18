{ pkgs }:

# oc-throwaway-serve -- boot a GENUINELY isolated throwaway `opencode serve`,
# and prove the isolation by measurement before handing it to you.
#
# WHY THIS EXISTS (incident 2026-08-14, cloudbox).
#
# The hand-rolled recipe everyone used --
#
#     XDG_DATA_HOME=$(mktemp -d) opencode serve --port <scratch>
#
# -- does NOT isolate the database, and fails silently. opencode's
# Database.path() consults $OPENCODE_DB FIRST and returns it verbatim when
# absolute, BEFORE Global.Path.data (the only thing XDG_DATA_HOME feeds) is
# read. users/dev/home.base.nix exports OPENCODE_DB as a session variable on
# purpose (it defeats the channel-suffixed opencode-<channel>.db default that
# would otherwise split-brain a from-source build away from the pool), so EVERY
# shell and every child process inherits it. Result: logs, config, state and
# storage go to the scratch dir -- the scratch logfile appears exactly where you
# expect, so it LOOKS isolated -- while reads and writes go to the production
# database. On 2026-08-14 a "throwaway" serve mutated three rows of a live
# session that way, and the verification query, run against the untouched copy,
# returned a clean-looking "0 rows" FALSE GREEN.
#
# The lesson of that incident is not "remember one more variable". It is
# VERIFY BY MEASUREMENT: the operator believed the isolation held, and the only
# thing that settled it was /proc/<pid>/fd. So this wrapper does both --
# constructs the environment correctly AND asserts, from the kernel's view of
# the process's open file descriptors, that the serve holds no handle on the
# protected database. If it does, the serve is killed before it can be sent a
# single request.
#
# Defence in depth, not redundancy: the db-isolation-guard patch
# (opencode-patched) makes opencode itself refuse this configuration, and this
# wrapper makes the correct configuration the easy one and re-checks the
# outcome. Either alone would have prevented the incident; the wrapper also
# covers a not-yet-deployed binary, and the guard also covers hand-rolled
# invocations that never use the wrapper.
pkgs.writeShellApplication {
  name = "oc-throwaway-serve";
  runtimeInputs = [ pkgs.coreutils pkgs.curl pkgs.sqlite pkgs.gnugrep pkgs.procps ];
  text = ''
    PROTECTED_DB="''${OC_THROWAWAY_PROTECTED_DB:-$HOME/.local/share/opencode/opencode.db}"
    SERVE_BIN="''${OC_THROWAWAY_SERVE_BIN:-opencode}"
    READY_TIMEOUT="''${OC_THROWAWAY_READY_TIMEOUT:-60}"

    usage() {
      cat <<'USAGE'
    Usage: oc-throwaway-serve [--copy-db] [--port N] [--dir PATH] [--keep] [-- <extra serve args>]

    Boot an isolated throwaway `opencode serve` whose database, logs, config,
    state and cache all live under a fresh scratch directory, then PROVE the
    isolation from /proc/<pid>/fd before printing its URL.

    Options:
      --copy-db      Seed the scratch DB from a consistent online snapshot of the
                     protected DB (sqlite VACUUM INTO; read-only on the source,
                     safe against the live pool). Default: start empty.
      --port N       Port to bind (default: a free ephemeral port).
      --dir PATH     Scratch directory to use (default: mktemp -d).
      --keep         Leave the serve running and exit; print the PID and the
                     teardown command. Default: run in the foreground and tear
                     down on Ctrl-C.
      -h, --help     This message.

    Environment:
      OC_THROWAWAY_SERVE_BIN       opencode binary to run (default: opencode).
                                   Point this at a freshly built dist binary to
                                   validate a candidate build.
      OC_THROWAWAY_PROTECTED_DB    DB that must NOT be opened
                                   (default: ~/.local/share/opencode/opencode.db).
    USAGE
    }

    copy_db=0
    port=""
    scratch=""
    keep=0
    extra=()
    while [ $# -gt 0 ]; do
      case "$1" in
        --copy-db) copy_db=1; shift ;;
        --port) port="$2"; shift 2 ;;
        --dir) scratch="$2"; shift 2 ;;
        --keep) keep=1; shift ;;
        -h|--help) usage; exit 0 ;;
        --) shift; extra=("$@"); break ;;
        *) echo "oc-throwaway-serve: unknown argument: $1" >&2; usage >&2; exit 64 ;;
      esac
    done

    # ---- the isolation measurement (the whole point) -------------------------

    # fd_targets <pid>: every path this process currently holds open, from the
    # kernel's own view. Not a claim about what we THINK it opened.
    fd_targets() {
      local pid="$1"
      # readlink over /proc/<pid>/fd/*; a racing fd close is not an error.
      for fd in /proc/"$pid"/fd/*; do
        readlink "$fd" 2>/dev/null || true
      done
    }

    # violations <protected-db>: filter a list of fd targets on stdin down to the
    # ones that touch the protected database. Matches the WAL and shm sidecars
    # too: a process holding only opencode.db-wal is still writing production.
    # Pure (stdin -> stdout), so pkgs/oc-throwaway-serve/test.sh can pin it.
    violations() {
      local protected="$1"
      grep -F -e "$protected" || true
    }

    assert_isolated() {
      local pid="$1" found
      found="$(fd_targets "$pid" | violations "$PROTECTED_DB")"
      if [ -n "$found" ]; then
        echo "" >&2
        echo "FATAL: the throwaway serve (pid $pid) has the PROTECTED database open:" >&2
        printf '  %s\n' "$found" >&2
        echo "" >&2
        echo "This is the 2026-08-14 failure mode: XDG_DATA_HOME redirects logs/config/state" >&2
        echo "but NOT the database, because an absolute \$OPENCODE_DB wins in Database.path()." >&2
        echo "Killing it now, before it can be sent a request." >&2
        kill -9 "$pid" 2>/dev/null || true
        exit 3
      fi
    }

    # ---- scratch environment --------------------------------------------------

    if [ -z "$scratch" ]; then
      scratch="$(mktemp -d /tmp/oc-throwaway.XXXXXX)"
    fi
    mkdir -p "$scratch"/{home,data,config,state,cache}
    db="$scratch/data/opencode/opencode.db"
    mkdir -p "$(dirname "$db")"

    if [ "$copy_db" = 1 ]; then
      if [ ! -f "$PROTECTED_DB" ]; then
        echo "oc-throwaway-serve: --copy-db: no such database: $PROTECTED_DB" >&2
        exit 66
      fi
      echo "oc-throwaway-serve: snapshotting $PROTECTED_DB -> $db (VACUUM INTO, read-only on the source)"
      # VACUUM INTO takes a consistent snapshot without blocking or modifying the
      # live database -- unlike `cp`, which can capture a torn page set when the
      # pool is mid-write, and unlike `.backup` on a busy WAL DB, which restarts.
      sqlite3 "file:$PROTECTED_DB?mode=ro" "VACUUM INTO '$db'"
    fi

    if [ -z "$port" ]; then
      # Probe for a port nobody answers on, rather than guessing one that might
      # be a pool member's (4096-4099) or the front door's (4700).
      for _ in $(seq 1 50); do
        cand=$(( 40000 + RANDOM % 20000 ))
        if ! (exec 3<>/dev/tcp/127.0.0.1/"$cand") 2>/dev/null; then
          port="$cand"
          break
        fi
      done
      if [ -z "$port" ]; then
        echo "oc-throwaway-serve: could not find a free port in 50 tries" >&2
        exit 65
      fi
    fi

    # The scrub list is not decoration. OPENCODE_SERVE_ID + OPENCODE_ROUTING_DB
    # let a throwaway hijack a live pool routing slot (2026-07-25 incident, now
    # fenced in serve.ts); OPENCODE_SERVE_EXPECTED_{PORT,PID} are that fence's
    # arming variables and are meaningless off a pool member; OPENCODE_DB is the
    # one this whole wrapper exists for and is set explicitly below.
    echo "oc-throwaway-serve: scratch=$scratch port=$port db=$db"
    setsid env \
      -u OPENCODE_SERVE_ID \
      -u OPENCODE_ROUTING_DB \
      -u OPENCODE_SERVE_EXPECTED_PORT \
      -u OPENCODE_SERVE_EXPECTED_PID \
      -u OPENCODE_URL \
      HOME="$scratch/home" \
      XDG_DATA_HOME="$scratch/data" \
      XDG_CONFIG_HOME="$scratch/config" \
      XDG_STATE_HOME="$scratch/state" \
      XDG_CACHE_HOME="$scratch/cache" \
      OPENCODE_DB="$db" \
      OPENCODE_DISABLE_CHANNEL_DB=1 \
      "$SERVE_BIN" serve --port "$port" --hostname 127.0.0.1 "''${extra[@]}" \
      > "$scratch/serve.log" 2>&1 &
    pid=$!

    cleanup() {
      kill "$pid" 2>/dev/null || true
    }
    [ "$keep" = 1 ] || trap cleanup EXIT INT TERM

    # Measure DURING startup as well as after readiness: a serve that opens the
    # protected DB and then fails to listen must still be caught.
    deadline=$(( SECONDS + READY_TIMEOUT ))
    ready=0
    while [ "$SECONDS" -lt "$deadline" ]; do
      if ! kill -0 "$pid" 2>/dev/null; then
        echo "oc-throwaway-serve: serve exited before becoming ready. Log:" >&2
        tail -20 "$scratch/serve.log" >&2
        exit 4
      fi
      assert_isolated "$pid"
      if curl -sS -o /dev/null --max-time 2 "http://127.0.0.1:$port/global/health" 2>/dev/null; then
        ready=1
        break
      fi
      sleep 0.5
    done

    if [ "$ready" != 1 ]; then
      echo "oc-throwaway-serve: serve did not answer on 127.0.0.1:$port within ''${READY_TIMEOUT}s. Log:" >&2
      tail -20 "$scratch/serve.log" >&2
      exit 5
    fi

    # Final check after the DB layer is definitely up: readiness is the moment
    # the handles exist, so this is the measurement that matters most.
    assert_isolated "$pid"

    # ...and the positive half: it must be holding the SCRATCH database. An
    # isolated-but-not-actually-running-on-our-DB serve would pass a pure
    # "no production handle" check vacuously.
    if ! fd_targets "$pid" | grep -qF "$db"; then
      echo "FATAL: serve holds no handle on the scratch database ($db)." >&2
      echo "The isolation check above would have been VACUOUSLY green. Killing it." >&2
      kill -9 "$pid" 2>/dev/null || true
      exit 6
    fi

    echo "oc-throwaway-serve: VERIFIED isolated (pid $pid)"
    echo "  url:      http://127.0.0.1:$port"
    echo "  database: $db"
    echo "  log:      $scratch/serve.log"
    echo "  fds on the protected DB: none (measured via /proc/$pid/fd)"

    if [ "$keep" = 1 ]; then
      echo "  teardown: kill $pid && rm -rf $scratch"
      exit 0
    fi

    echo "  (Ctrl-C to tear down)"
    wait "$pid"
  '';
}
