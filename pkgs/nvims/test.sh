#!/usr/bin/env bash
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
# nvim_listen_plan <in_tmux> <nested> <sock_exists>: decide how `nvims` should
# start nvim's RPC server. Pure (all environment/filesystem state passed as
# args) so it is unit-testable without tmux, nvim, or a real socket.
#
#   in_tmux      "1" if $TMUX_PANE is set (we have a deterministic pane key)
#   nested       "1" if running inside a LIVE parent nvim's :terminal (its
#                $NVIM resolves to a live socket). A nested nvims must NOT claim
#                the pane socket -- clobbering it (rm -f) orphans the parent.
#   sock_exists  "1" if the target pane socket path already exists (as a socket)
#
# Prints exactly one token:
#   DEFAULT          exec nvim                        (no --listen injection)
#   LISTEN           exec nvim --listen <sock>        (path free)
#   RM_THEN_LISTEN   rm -f <sock>; exec nvim --listen (stale file from a
#                                                      SIGKILL'd previous nvim)
nvim_listen_plan() {
  local in_tmux="$1" nested="$2" sock_exists="$3"
  if [ "$in_tmux" != "1" ]; then printf 'DEFAULT\n'; return; fi
  if [ "$nested" = "1" ]; then printf 'DEFAULT\n'; return; fi
  if [ "$sock_exists" = "1" ]; then printf 'RM_THEN_LISTEN\n'; else printf 'LISTEN\n'; fi
}

fail=0
check() { # check <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "ok: $1"; else
    echo "FAIL: $1"; echo "  expected: [$2]"; echo "  actual:   [$3]"; fail=1; fi
}

# Outside tmux: never inject --listen, regardless of other state.
check "no tmux -> DEFAULT (no sock)"        "DEFAULT" "$(nvim_listen_plan "" "" "")"
check "no tmux -> DEFAULT (sock present)"    "DEFAULT" "$(nvim_listen_plan "" "" "1")"
check "no tmux -> DEFAULT (even if nested)"  "DEFAULT" "$(nvim_listen_plan "" "1" "1")"

# In tmux, top-level (not nested): preserve the pre-fix behavior.
check "tmux, free path -> LISTEN"            "LISTEN"          "$(nvim_listen_plan "1" "" "")"
check "tmux, stale sock -> RM_THEN_LISTEN"   "RM_THEN_LISTEN"  "$(nvim_listen_plan "1" "" "1")"

# In tmux, nested inside a live nvim: the regression guard. Must DEFAULT so we
# never rm -f / steal the parent's pane socket. This is the workstation-8iqt fix.
check "tmux, nested, free path -> DEFAULT"   "DEFAULT" "$(nvim_listen_plan "1" "1" "")"
check "tmux, nested, sock present -> DEFAULT (do NOT rm a live parent socket)" \
  "DEFAULT" "$(nvim_listen_plan "1" "1" "1")"

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
else
  echo "SKIP: source guards (default.nix not next to test)"
fi

[ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "SOME TESTS FAILED"; exit 1; }
