# em-history-shell: the workstation half of eternal-machinery's history shell

The design, the protocol and the client live in eternal-machinery (private):
`docs/plans/2026-11-03-q101-5-history-shell-phase2-impl.md` (bead
`eternal-machinery-qpmfc.101.5`; read its "Plan review resolutions", which override its
slices). This page records what this repo owns and the rules for keeping the two in step.

## What this repo owns

| Piece | Where |
|---|---|
| The server (protocol v1, stdlib Python) | `pkgs/em-history-shell/server.py` |
| Its package: bwrap, the tools environment and the seccomp blob, all by store path | `pkgs/em-history-shell/default.nix` |
| The unit tests, run by `checks.aarch64-linux.em-history-shell-unit` | `pkgs/em-history-shell/test_server.py` |
| The probe, to run with sudo before the rebuild | `pkgs/em-history-shell/probe.sh` (installed as `em-history-shell-probe`) |
| User `em-history-shell` (uid/gid 2100), the socket, the instance template, the history-root ACL | `hosts/devbox/em-history-shell.nix` |

EM owns the client, the protocol text and the escape suite. The suite tests the
deployed server black-box, through the socket.

## Why the store path is the proof

The package embeds the bwrap, the tools closure and the seccomp program as store paths,
and its own path as `server`. Every answer carries `server`; `ping` also returns
`seccomp_sha256`. EM's boot gate proves the escape suite for one `server` path, and its
client refuses an answer from any other. So a change to the tools, the policy or the
server changes the path and forces a re-proof, with no extra bookkeeping here.

## Copies that must stay in step with EM

EM is private, so this repo cannot import from it. Three things are copies:

- `pkgs/em-history-shell/seccomp_policy.py` is EM `nix/history_shell_seccomp.py`,
  byte for byte below its header. The built blob had the same sha256 as EM's own
  build on 2026-11-03; EM's suite compares them on every run, via `ping`.
- The tool list in `default.nix` is EM `nix/history-shell.nix`'s `tools`.
- `server.py` ports `scripts/tec/history_shell.py`: `_NAME`, `parse_view`,
  `view_mounts`, `check_mounts`, `build_argv`, the limits and `execute`. Its header
  lists the deliberate differences (no `systemd-run`, `oom_score_adj`, kill on
  disconnect, the root rule). `probe.sh` repeats the argv in shell.

Change a copy and its source in the same pair of PRs.

## Not in this slice

Persistent per-agent scratch (resolution 5): no scratch mount, no quota. A later bead
carries it.

## Rolling it out

1. `P=$(nix build --no-link --print-out-paths .#em-history-shell)`, then
   `sudo "$P/bin/em-history-shell-probe"`. It must end with "hardening as written
   works". If it names props, change them in `hosts/devbox/em-history-shell.nix`.
2. `sudo nixos-rebuild switch --flake .#devbox` (creates the user, the directory and
   the ACL, and starts the socket).
3. As dev, ping it:
   `python3 -c 'import socket as s; c=s.socket(s.AF_UNIX); c.connect("/run/em-history-shell/sock"); c.sendall(b"{\"v\":1,\"op\":\"ping\"}\n"); print(c.recv(4096).decode())'`
   answers `"ok":true` with the `server` path and the service user's uid (2100).
