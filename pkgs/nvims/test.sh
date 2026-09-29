#!/usr/bin/env bash
# unwired-test(workstation-3g4j): named there as wanting the same treatment as reset-workspace/test.sh; read that bead first, it records an attempt that was backed out.
# Unit + source-guard tests for nvims' RPC-server launch decision.
#
# workstation-8iqt: `nvims` keys its --listen socket on $TMUX_PANE
# (/tmp/nvim-<pane>.sock) and rm -f's that path before launching. But
# $TMUX_PANE is INHERITED by a parent nvim's :terminal children, so running
# `nvims` from inside an existing nvim computes the SAME socket path as the
# live parent and rm -f UNLINKS the parent's still-open socket -- orphaning it
# (process alive, socket path gone, unreachable by oc-auto-attach). The fix:
# a nested nvims (detected via $NVIM resolving to a live socket) must NOT claim
# the pane socket; it defers to nvim's default server instead.
#
# Mirrors the pure nvim_listen_plan helper and exercises it, then greps
# default.nix so a source-level regression trips before deploy. Mirror of the
# convention in pkgs/reset-workspace/test.sh and pkgs/opencode-launch/test.sh.
#
# Run: bash test.sh
set -o errexit -o nounset -o pipefail

# ---- helper under test (mirror of default.nix) ------------------------------
# nvim_listen_plan <in_tmux> <nested> <sock_state>: decide how `nvims` should
# start nvim's RPC server. Pure (all environment/filesystem state passed as
# args) so it is unit-testable without tmux, nvim, or a real socket.
#
#   in_tmux      "1" if $TMUX_PANE is set (we have a deterministic pane key)
#   nested       "1" if running inside a LIVE parent nvim's :terminal (its
#                $NVIM resolves to a live socket). A nested nvims must NOT claim
#                the pane socket -- clobbering it (rm -f) orphans the parent.
#   sock_state   "" (nothing at the pane path), "stale" (socket file nobody
#                answers on), "live" (an nvim answers -- e.g. the same pane id
#                in a SECOND tmux server; pane ids are per-server)
#
# Prints exactly one token:
#   DEFAULT          exec nvim                        (no --listen injection)
#   LISTEN           exec nvim --listen <sock>        (path free)
#   RM_THEN_LISTEN   rm -f <sock>; exec nvim --listen (stale file from a
#                                                      SIGKILL'd previous nvim)
nvim_listen_plan() {
  local in_tmux="$1" nested="$2" sock_state="$3"
  if [ "$in_tmux" != "1" ]; then printf 'DEFAULT\n'; return; fi
  if [ "$nested" = "1" ]; then printf 'DEFAULT\n'; return; fi
  case "$sock_state" in
    stale) printf 'RM_THEN_LISTEN\n' ;;
    live)  printf 'DEFAULT\n' ;;
    *)     printf 'LISTEN\n' ;;
  esac
}

fail=0
check() { # check <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "ok: $1"; else
    echo "FAIL: $1"; echo "  expected: [$2]"; echo "  actual:   [$3]"; fail=1; fi
}

# Outside tmux: never inject --listen, regardless of other state.
check "no tmux -> DEFAULT (no sock)"        "DEFAULT" "$(nvim_listen_plan "" "" "")"
check "no tmux -> DEFAULT (sock present)"    "DEFAULT" "$(nvim_listen_plan "" "" "stale")"
check "no tmux -> DEFAULT (even if nested)"  "DEFAULT" "$(nvim_listen_plan "" "1" "live")"

# In tmux, top-level (not nested): preserve the pre-fix behavior.
check "tmux, free path -> LISTEN"            "LISTEN"          "$(nvim_listen_plan "1" "" "")"
check "tmux, stale sock -> RM_THEN_LISTEN"   "RM_THEN_LISTEN"  "$(nvim_listen_plan "1" "" "stale")"
# Same pane id, live nvim behind it (a second tmux server reuses %0, %1, ...):
# must NOT rm the other server's editor socket.
check "tmux, live sock -> DEFAULT (do NOT evict another server's nvim)" \
  "DEFAULT" "$(nvim_listen_plan "1" "" "live")"

# In tmux, nested inside a live nvim: the regression guard. Must DEFAULT so we
# never rm -f / steal the parent's pane socket. This is the workstation-8iqt fix.
check "tmux, nested, free path -> DEFAULT"   "DEFAULT" "$(nvim_listen_plan "1" "1" "")"
check "tmux, nested, sock present -> DEFAULT (do NOT rm a live parent socket)" \
  "DEFAULT" "$(nvim_listen_plan "1" "1" "live")"

# ---- source guards (default.nix) --------------------------------------------
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
default_nix="$script_dir/default.nix"
want_grep() { # want_grep <desc> <fixed-string>
  if grep -qF -- "$2" "$default_nix"; then echo "ok: $1"; else
    echo "FAIL: $1"; echo "  not found in default.nix: $2"; fail=1; fi
}
if [ -f "$default_nix" ]; then
  want_grep "source defines nvim_listen_plan"          'nvim_listen_plan() {'
  want_grep "source documents the nesting-guard fix"   'workstation-8iqt'
  want_grep "source dispatches on the plan"            'nvim_listen_plan "$in_tmux"'
  want_grep "source probes liveness before rm"         '--remote-expr 1'
  want_grep "source only rm's on a confirmed refusal"  '*"connection refused"*'
  want_grep "source maps a live pane socket to DEFAULT" 'live)  printf '"'"'DEFAULT'
else
  echo "SKIP: source guards (default.nix not next to test)"
fi

[ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "SOME TESTS FAILED"; exit 1; }
