# Shell fragment for pigeon-daemon's start script on every machine
# (hosts/{cloudbox,devbox}/configuration.nix, users/dev/home.darwin.nix).
# Place it after the alarm webhook is exported and before the daemon's exec.
#
# Why (pigeon-odrg): the daemon loads better-sqlite3, a native module built for
# one Node ABI. A system switch that bumps pkgs.nodejs changes the daemon's
# node without any pigeon deploy; on 2026-11-25 cloudbox's 26.05 switch did,
# and the daemon crash-looped 54 times (ERR_DLOPEN_FAILED) until someone ran
# `npm rebuild better-sqlite3` by hand. pigeon's scripts/deploy-daemon.sh
# already rebuilt a mismatched binary, but only on a deploy.
#
# So every start runs pigeon's scripts/ensure-native-modules.sh (the same check
# deploy-daemon.sh uses) under the daemon's own node: ~0.1s when it loads; when
# it does not, one `npm rebuild better-sqlite3`, which usually COMPILES (no
# prebuilt binary exists for every new node; ~1 min on cloudbox). That is why
# the build tools are passed: the units' PATH has none, and putting them on
# the unit's `path` would leak them into the tmux panes pigeon spawns (see the
# note on cloudbox's `path`). They reach the rebuild only.
#
# Only exit 3 from the script means "better-sqlite3 does not load and the
# rebuild failed (or already failed for this node)". Any other failure means
# the script itself broke (a bad edit on pigeon main, say); that must not stop
# the daemon, so it warns and starts it anyway, as before this existed.
#
# A failed rebuild posts once to the #alerts webhook, latches in
# ~/.local/state/pigeon/native-rebuild-failed so later starts fail fast instead
# of recompiling, and exits 78; the systemd units list 78 in
# RestartPreventExitStatus, so they stop restarting and show as failed. launchd
# has no such setting and keeps restarting the Mac's agent, cheaply, latched.
# The latch clears itself once node_modules loads, or for a different node.
#
# Missing script (a checkout older than pigeon-odrg): warn and start anyway.
#
# POSIX sh: the Mac's agent runs this under /bin/sh.
#
# buildTools: what node-gyp needs that the service's PATH lacks. The NixOS
# default was measured on cloudbox (it fails without sed and grep too). The Mac
# passes [] because the agent's PATH already has /usr/bin, whose Command Line
# Tools compiled it from a launchd-like env (measured 2026-11-26, ~25s); nix's
# darwin toolchain would add ~1.4 GiB to the agent's closure for nothing.
{ pkgs, repo, buildTools ? [ pkgs.python3 pkgs.gnumake pkgs.stdenv.cc pkgs.gnused pkgs.gnugrep ] }:
let
  buildArg = pkgs.lib.optionalString (buildTools != [ ])
    "--build-path ${pkgs.lib.makeBinPath buildTools} ";
in ''
  ensure_native="${repo}/scripts/ensure-native-modules.sh"
  if [ -x "$ensure_native" ]; then
    ensure_rc=0
    "$ensure_native" --node-dir ${pkgs.nodejs}/bin --repo "${repo}" ${buildArg}\
      --latch "$HOME/.local/state/pigeon/native-rebuild-failed" --alarm || ensure_rc=$?
    case "$ensure_rc" in
      0) ;;
      3) exit 78 ;;
      *) echo "pigeon-daemon: $ensure_native failed unexpectedly (exit $ensure_rc); starting anyway" >&2 ;;
    esac
  else
    echo "pigeon-daemon: $ensure_native missing; starting without the native-module check" >&2
  fi
''
