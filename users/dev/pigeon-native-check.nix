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
{ pkgs, repo }:
let
  buildPath = pkgs.lib.makeBinPath [
    pkgs.python3
    pkgs.gnumake
    pkgs.stdenv.cc
    pkgs.gnused
    pkgs.gnugrep
  ];
in ''
  ensure_native="${repo}/scripts/ensure-native-modules.sh"
  if [ -x "$ensure_native" ]; then
    "$ensure_native" --node-dir ${pkgs.nodejs}/bin --repo "${repo}" \
      --build-path ${buildPath} \
      --latch "$HOME/.local/state/pigeon/native-rebuild-failed" --alarm || exit 78
  else
    echo "pigeon-daemon: $ensure_native missing; starting without the native-module check" >&2
  fi
''
