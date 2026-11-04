# em-stack-monitor: Telegram alerts for the running EM stack

Bead: eternal-machinery-qpmfc.103.1 (EM repo). Scope decided 2026-11-04 by stall-watch for
Jonathan (recorded on the bead). EM prerequisite: eternal-machinery #1173 (`stack-health`
grades `503 session_not_found` as WARN, so an idle stack stops reading FAIL).

## What it does

Every 10 minutes a oneshot on devbox looks at the Eternal Machinery stack, if one is running,
and posts problems to the Telegram forum group's General topic through pigeon's bot. It
copies em-ci-monitor's contract: a standing problem set is announced once ("problem"),
repeated every 6 h ("STILL failing"), and followed by "resolved" when it clears. One-off
events are posted once.

### The gate: is a stack running?

A stack is a BEAM serving `127.0.0.1:4002`. Postgres alone is not one (tests share it on
5434, and `EM_MODE=db-only` runs it with no BEAM). If `:4002` refuses, the pass records
`nostack`. Problems still pending are dropped silently. If problems had been announced, one
line goes out ("stack stopped, no longer watching: ..."), so "problem" is never the last
word. When a stack comes back, problems are announced fresh. A BEAM crash with postgres up
reads like a shutdown, accepted. The orphan shape (postgres dead, BEAM serving) is caught.

The BEAM's mode comes from `/proc/<pid>/environ` (`EM_MODE`), the pid from `ss -tlnp` on
`:4002` (same user, so readable). Outside a `*-live` mode, `agentos DOWN` is expected and is
not a problem.

### Standing problems (problem / STILL / resolved)

Each has a stable key. Detail text (numbers, times) never goes into a key.

| Key | Source | Condition |
|---|---|---|
| `fail:<check>` | `bin/stack-health` | a line whose verdict is `FAIL`, `DOWN` or `DEAD_MANAGER` (except `agentos` outside a live mode) |
| `session_not_started` | `bin/stack-health` | the line `api WARN session <s> not started (HTTP 503 session_not_found ...` (EM #1173) in any mode but `manual-live`, which starts the session lazily. Every other mode, `sim`, `sim-reactive`, `reactive-live`, `autonomous-live`, starts it eagerly, so a session that never came up is a problem. An unknown mode alerts too (errs noisy, as the `agentos` rule does). The text names the session stack-health probed and the mode. |
| `monitor:blind` | `bin/stack-health` | no `SUMMARY:` line, or any `UNKNOWN` line while `:4002` answered: the monitor cannot see, so say so |
| `presence:<sid>` | `GET :4002/v1/presence` | `link == "offline"`, `last_close.cause == "server"`, and `wants_out == null` (it is an object `{why, at}` when the close was wanted). The text names `last_close.at`, `code`, and says when `idle` is true (TEC logs out an idle character). |
| `quarantine:<agent>` | `GET :4400/em/quiescence` | `agents[k].quarantined != null` (it is a reason string) |
| `gm_halt:<sid>` | `GET :4002/v1/sessions/<sid>/status` | `interlock.state` is `gm_halted` or `awaiting_ooc_reply`, `reason` is not `operator_halt`, and `halted_at` (strip the microseconds before `fromdateiso8601`) is 20+ min old. With no `halted_at` (`fence_halted`, `latch_unreadable`, a race), seen on 2 passes. The text names the reason and the speaker. Read only. |

`<sid>` ranges over the keys of `/v1/presence` (today `jonathan` and `livia`).

WARN lines never alert. UNKNOWN lines alert only as `monitor:blind`. Stuck recovery needs no key of its
own: stack-health FAILs on `recovering_for_s >= 600`, which comes through as
`fail:agentos`.

Source failures. Every source is graded on its own, and each pass records, per source,
one of three outcomes. *Answered*: it said something, including "nothing wrong" and
"not here" such as a 503 `session_not_found` on a session's status. *Gone*: connection
refused (curl rc 7) or HTTP 404, and for stack-health a complete run (it printed
`SUMMARY:`) that has no line for a check. *Failed*: a timeout, a reset, a 5xx other than
`session_not_found`, a 200 that does not parse, or a stack-health run without `SUMMARY:`.
Only a *failed* source is carried: a key that was active last pass, is missing now, and
whose source failed is carried forward with its stored text (the state keeps the text of
each active key), so one failed fetch neither drops a standing key nor sends a false
"resolved". A gone source clears its keys like any absent key (a stopped session, a
stopped AgentOS, a check that no longer exists).

- `fail:<check>`, `session_not_started`: carried when stack-health printed no `SUMMARY:` line,
  or that check (`api` for `session_not_started`) reads `UNKNOWN`;
- `monitor:blind`: never carried, it is derived from the stack-health output;
- `presence:<sid>`: carried while the presence fetch failed;
- `gm_halt:<sid>`: carried while the presence fetch failed, or while that session's status
  fetch failed;
- `quarantine:<agent>`: carried while the quiescence fetch failed. In a live mode (or an unknown one) a refused `:4400` counts as failed, not gone: AgentOS is meant to be up, so the 3-pass cap carries the quarantine until `fail:agentos` takes over. Outside a live mode it is gone.

There is no global "degraded" flag: quiescence never answers in sim modes. Carrying is
capped: at most 3 consecutive passes per key (state `carried: {key: n}`, reset whenever the
key is observed directly), so a source that fails 4 passes in a row resolves on the 4th like
any absent key. Debounce counts of such keys are carried too, unchanged, under the same cap
(past it the count is dropped).

Debounce: a `fail:*`, `session_not_started`, `monitor:blind`, `presence:*` or `quarantine:*` key alerts only once it has been seen on
2 passes in a row (one pass during a BEAM or AgentOS restart is normal). The pending set is
kept in the state directory. Resolve after 1 clean pass.

### Events (posted once, no "resolved")

From `/em/quiescence`, each agent's `recoveries` list (`{at, cause, detail}`, last hour,
in memory per AgentOS boot):

- a recovery whose `cause` contains `child_restart_failed`. Key
  `<boot_id>:<agent>:crf:<at of the newest such recovery>`.
- 3 or more recoveries for one agent in the list, not counting `child_restart_failed` ones
  (flapping). Key `<boot_id>:<agent>:flap:<at of the newest non-crf recovery>`.

A recovery stays in the list for an hour, so keying on its `at` makes the same recovery
the same event. A stuck heal retries every few minutes and keeps adding recoveries, so
each `<boot_id>:<agent>:<kind>` is also rate-limited: nothing is posted, or recorded,
while a seen key with that prefix is under 3600 s old (stack-health turns a stuck heal
into `fail:agentos` anyway).

All of a pass's messages go out as one Telegram message, so a failed send retried next pass
cannot duplicate part of it. Seen event keys are kept in the state directory (pruned after 2 h, so never inside the 1 h
rate window), so an AgentOS restart
(new `boot_id`) never replays old events. Single recoveries stay quiet: they are the system
fixing itself.

## How it runs

- `hosts/devbox/em-stack-monitor.nix` + `em-stack-monitor.sh`, bash + jq + curl, a
  `writeShellApplication` like em-ci-monitor.
- A system service with `User=dev` (stack-health lives in `/home/dev`, uses per-user
  `pgrep` and `/run/user/1000`, and reads postgres through the dev-owned binary). Hardening:
  `ProtectHome=read-only` (not tmpfs, the script must be readable), `ProtectSystem=strict`
  with `ReadWritePaths=/tmp` (stack-health's `mktemp`; without it every check reads UNKNOWN),
  `NoNewPrivileges`, `StateDirectory=em-stack-monitor`,
  `Environment=XDG_RUNTIME_DIR=/run/user/1000`. No `PrivateTmp` (stack-health scans
  `/tmp/devenv-*`) and no `PrivateNetwork` (it needs localhost and api.telegram.org). The unit
  runs dev-writable code as dev, so the hardening is light by nature.
- `runtimeInputs` include what stack-health needs: `python3`, `procps`, `gawk`, `iproute2`,
  `curl`, `jq`, coreutils, findutils, gnugrep, gnused. Without python3 every API check reads
  UNKNOWN, and without procps the manager check reads OK blind.
- Every source is graded on its own. A fetch that fails or a body that does not parse means
  "no data from that source" (for stack-health, `monitor:blind`), never an aborted pass.
- `bin/stack-health` runs from `/home/dev/projects/eternal-machinery` (the main checkout),
  `TimeoutStartSec=8min` (stack-health's own 200 s timeout, four or more 10 s fetches,
  Telegram's retries and a `/fail` ping add up to about 6.5 min). Its exit code is ignored. Each alert names the checkout's short
  `HEAD`, because nothing keeps that tree current. Lines are parsed with
  `^  (\S+)\s+(FAIL|DOWN|DEAD_MANAGER)\b`.
- Timer: `OnBootSec=10min`, `OnUnitActiveSec=10min`, `RandomizedDelaySec=30s`.
- Secrets by `LoadCredential`: `telegram_bot_token`, `telegram_chat_id` (pigeon's). The bot
  token and chat id reach curl only on stdin (`-K -`), never in argv.
- State is normalized at load, field by field: corrupt JSON, or valid JSON of the wrong
  shape, falls back to defaults and never kills a pass.
- Dead-man ping: behind `hcEnabled = false` in the nix `let`. When true it adds sops secret
  `em_stack_hc_ping_url` (root 0400) and its `LoadCredential`. The script pings only when
  `$CREDENTIALS_DIRECTORY/hc_ping_url` exists, with em-ci-monitor's contract (success after a
  pass that delivered, `/fail` on a delivery failure or a non-zero exit). Suggested check:
  period 10 m, grace 20 m.
- Dry run: `em-stack-monitor-dry-run` (prints the raw key set before debounce and the message
  it would send, sends nothing, writes no state).
- For tests, everything outside the script is injectable: `EM_STACK_FETCH_CMD` (given a URL,
  prints the HTTP code on line 1 and the body after it), `EM_STACK_GATE_CMD` (exit 0 when a
  stack is up), `EM_STACK_MODE_CMD` (prints `EM_MODE`), `EM_STACK_HEALTH_CMD`,
  `EM_STACK_TG_CMD` (reads the message on stdin), `EM_STACK_NOW`.

## Tests

`hosts/devbox/test-em-stack-monitor.sh`, a flake check `em-stack-monitor-tests` like
`em-ci-failover-tests` with the `ALL PASS (N assertions)` count pinned. Fixtures are captured from the
live stack (real field types) and served by a fake fetch, which can also answer 503 or
nothing. stack-health, the gate, the mode, Telegram and the clock are fakes too. Cases: no stack is
quiet and clears pending without "resolved", but sends one "stopped" line for announced problems;
a failing source (503, no answer, bad JSON) does not abort the pass; stack-health output for a
never-started session (deferred boot: INFO and WARN lines only, per EM #1173; a real capture)
raises no key in `manual-live` and `session_not_started` in sim, sim-reactive, reactive-live,
autonomous-live and an unknown mode (clearing when the session is up, carried without a `SUMMARY`); UNKNOWN reads as
`monitor:blind`; `agentos DOWN` in a sim mode is quiet; a wanted close (`wants_out` object) is
quiet; an `operator_halt` is quiet; a stuck `child_restart_failed` posts once an hour; a FAIL alerts only on its second pass; WARN and
UNKNOWN never alert; STILL after 6 h; resolved after a clean pass; presence server close
alerts, a wanted close does not; GM halt under 20 min quiet, over it alerts, a missing
`halted_at` alerts on the 2nd pass; `child_restart_failed` posts once and not again on the
next pass or an hour later (same `at`), a newer one inside the rate window neither posts nor is
recorded and one after it posts, seen events are kept 2 h; 3 recoveries post a flap once (same
rules); a new `boot_id` does not replay; a failed source carries its keys (presence timeout
during a standing GM halt, a status 502 or an unparsable 200, no `SUMMARY` while `fail:postgres`
stands, a standing check read `UNKNOWN`, quiescence down during a quarantine, a debounce count
surviving a failed pass) while a gone source clears them (status 503 `session_not_found`, 404 or
refused; `:4400` refused or 404; presence refused; a complete stack-health run with no line for a
check), the cap resolves on the 4th failed pass and resets when the key is observed, a debounce
count past the cap is dropped, and an answered "clear" still resolves; a refused `:4400` in manual-live (or unknown mode) is carried, not resolved; counts in state are non-negative integers (1.5 reads as 1, -3 as none); an empty signature with the stack up exits 1 and sends nothing; wrong-shape state (`{"keys":"x"}`, `{"pending":[1]}`, ...) does
not kill a pass; the Telegram token and chat id never appear in curl's argv; a Telegram failure
exits non-zero and records nothing.

## Rollout

1. Merge EM #1173 first, and pull the main checkout (`/home/dev/projects/eternal-machinery`),
   which is the stack-health the monitor runs.
2. Merge this, then `sudo nixos-rebuild switch --flake .#devbox` (Jonathan, or on his word).
3. `sudo systemctl start em-stack-monitor-dry-run` with the stack up, read the journal. It must
   print `mode: manual-live` (not `unknown`: an unknown mode means the BEAM's environment was
   unreadable, and `agentos DOWN` is then not suppressed in sim modes), and on a healthy stack the
   raw key set must be empty (in particular no `monitor:blind`). Run it both before the TEC
   session is started (deferred boot) and after.
4. The timer is on from the rebuild. If it is noisy, `sudo systemctl stop em-stack-monitor.timer`
   and tune.
5. For the dead-man ping: create a healthchecks.io check, add its ping URL to devbox sops as
   `em_stack_hc_ping_url`, set `hcEnabled = true`.
