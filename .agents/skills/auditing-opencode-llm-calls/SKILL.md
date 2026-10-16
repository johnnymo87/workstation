---
name: auditing-opencode-llm-calls
description: Use when investigating an opencode or Vertex/gemini LLM call surge on cloudbox, attributing LLM traffic by agent/model/session, or querying/debugging the durable LLM audit log.
---

# Auditing OpenCode LLM Calls (cloudbox)

## Overview

cloudbox runs an always-on follower that captures `opencode-serve`'s `service=llm`
attribution lines plus provider error/quota signals to a durable file, so the
*next* call surge is attributable in seconds. Installed declaratively by
`users/dev/opencode-llm-audit.nix`.

## Why a custom follower (the non-obvious gotcha)

opencode keeps only the newest 10 log files (`packages/core/src/util/log.ts`,
`const keep = 10`) and runs `cleanup()` on **every** process start (every TUI
attach). The long-lived `opencode-serve` log is the *oldest* file → it gets
`fs.unlink()`'d while serve keeps writing to the now-**deleted inode** via its
open fd. So "tail the newest `*.log`" captures only short-lived TUI-client logs
(which contain **no** `service=llm` lines) and misses the serve log entirely.

The follower instead locates the running `opencode serve` process and tails the
fd it holds open on its (possibly deleted) log file via `/proc/<pid>/fd/<n>`,
using `tail --pid=<serve> --follow=descriptor` so it self-terminates and
re-attaches when serve restarts.

## Where things live

| Thing | Path / command |
|-------|----------------|
| Output log | `~/.local/state/opencode-llm-audit/llm.log` (outside disk-cleanup + nightly-restart scope) |
| Follower script | `~/.local/bin/opencode-llm-audit` |
| Service | `opencode-llm-audit.service` (user, `Restart=always`) |
| Rotation | `opencode-llm-audit-logrotate.{service,timer}` (daily, rotate 14, compress, copytruncate) |
| Nix source | `users/dev/opencode-llm-audit.nix` (+ import in `users/dev/home.nix`) |
| Forensic background | `docs/investigations/2026-06-05-vertex-gemini-surge/overnight-surge-forensics.md` §(c) |

## Querying the audit log

```bash
OUT=~/.local/state/opencode-llm-audit/llm.log
# who/what: calls grouped by agent + model
grep -o 'service=llm .*' "$OUT" | grep -oP 'modelID=\S+|agent=\S+' | paste - - | sort | uniq -c | sort -rn
# retry-storm detector: a single session.id spiking
grep -oP 'session\.id=\S+' "$OUT" | sort | uniq -c | sort -rn
# provider error / quota signals
grep -E 'RESOURCE_EXHAUSTED|status=429|Too Many Requests|Overloaded|Rate Limited|AbortError' "$OUT"
```

Attribution line format:
`INFO <ts> service=llm providerID=<p> modelID=<m> session.id=ses_<...> small=<bool> agent=<name> mode=<mode> stream`

## Operating / debugging

- `systemctl --user ...` from a non-login shell needs `export XDG_RUNTIME_DIR=/run/user/$(id -u)` first.
- Health: `journalctl --user -u opencode-llm-audit -n 20` → expect `attached to serve=<pid> via /proc/<pid>/fd/<n>`.
- After editing the Nix module, apply: `nix run home-manager -- switch --flake .#cloudbox` (the file must be `git add`-ed — flakes ignore untracked files).
- Self-healing: if the follower's `tail`/`grep` dies it re-attaches within ~5s; on serve restart, `tail --pid` exits and it re-attaches to the new serve PID.

## Scope / limits

Captures opencode's *logical* calls + opencode-level retries (`processor.ts`
wraps the stream in `Effect.retry(SessionRetry.policy)`, so each retry re-emits a
`service=llm` line). The deeper SDK/gateway retries that inflated the June 2026
surge ~16–48× to ~97k live **below** opencode's logging — get those from
Vertex/gateway-side metrics, not from this log.
