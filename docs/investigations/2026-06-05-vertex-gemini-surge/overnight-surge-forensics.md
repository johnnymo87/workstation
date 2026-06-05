# Overnight Vertex/gemini-3.5-flash surge — forensic findings

**Host:** cloudbox (`$OPENCODE_HOSTNAME=cloudbox`, confirmed)
**Investigator window analyzed:** 2026-06-04 15:00 UTC → 2026-06-05 07:00 UTC
**Method:** read-only. systemd unit inspection (`systemctl cat`), `journalctl`,
process/tmux inspection, source reads of `~/projects/lgtm` + launcher scripts,
and read-only SQLite queries against `~/.local/share/opencode/opencode.db`
(`mode=ro`). Nothing was modified or installed.

> Note on clocks: `systemctl`/`ls` print **EDT (UTC-4)**; `journalctl` was run
> with `--utc`. The DB stores ms-epoch (queried in UTC). The surge window in
> EDT is 11:00 Jun-4 → 03:00 Jun-5.

---

## TL;DR

- **What process emitted the calls:** the persistent headless server
  **`opencode-serve.service`** (`opencode serve --port 4096`), running the
  installed **`opencode-patched-1.15.13.2`** binary → user-agent
  `opencode/1.15.13`, egress REDACTED. This single server backs *all*
  automated and attached sessions on the box.
- **What drove the work (automation, not a human):**
  1. **`lgtm-run.service`** — a systemd timer firing **every 10 min** all night
     (`OnCalendar=*:0/10`), spawning opus PR-review sessions that fan out
     **gemini-3.5-flash subagents** (`code-reviewer`, `spec-reviewer`) and
     read-only **gather** sessions (gather model is literally
     `google-vertex/gemini-3.5-flash`).
  2. **subagent-driven-development / plan-execution sessions** — opus `build`
     orchestrators fanning out `implementer` / `code-reviewer` / `spec-reviewer`
     subagents, all on the **global-default** model `gemini-3.5-flash`.
  3. **`compaction`** of long-running opus sessions (configured to run on
     `gemini-3.5-flash`), plus default "small"/title calls (no `small_model`
     override → they use the default gemini too).
- **Why 97k in the audit log but only ~2–6k in the DB:** a **gemini retry
  storm**. The DB recorded **6,017 total step-starts (all models)** overnight,
  of which gemini-model sessions were **2,033**. The audit log shows **~97,000
  gemini calls**. That 16–48× gap = provider/SDK-level **retries** (each a
  distinct `operation.id`) that failed before persisting a step — almost
  certainly gemini-3.5-flash quota/rate-limit exhaustion (opus goes through a
  different gateway/quota and reconciles 1:1, so it did not storm).
- **Why it stopped at 07:00 UTC:** not because work finished —
  **`nightly-restart-background.service` restarted `opencode-serve` at exactly
  07:00:07 UTC**, killing the looping sessions.

**Verdict: B is an AUTOMATED system, not normal interactive OpenCode.** It is a
scheduled PR-review daemon + subagent fan-out, amplified ~16–48× by a gemini
retry storm. It is **not** an A/B eval harness (that infra is stale, see below).

---

## Evidence

### 1. The emitting process: `opencode-serve.service`

`systemctl cat opencode-serve.service` → `ExecStart` runs
`opencode serve --port 4096 --hostname 127.0.0.1`, `HOME=/home/dev`, no
`XDG_DATA_HOME` override (so it writes the **same** `~/.local/share/opencode/`
DB as the interactive TUI), `Restart=always`, `MemoryMax=24G`.

Installed binary: `readlink -f $(which opencode)` →
`/nix/store/...-opencode-patched-1.15.13.2/bin/opencode`; `opencode --version` →
`1.15.13`. **Matches the surge UA `opencode/1.15.13`.**

`journalctl --utc -u opencode-serve.service` lifecycle + accounting:

```
Jun 04 17:31:25  Stopped...  Consumed 3h 6min CPU, 20G mem peak, 17.6G outgoing IP traffic
Jun 04 17:31:25  Started
Jun 05 07:00:07  Stopped...  Consumed 16h 29min CPU, 20G mem peak, 6.5G swap,
                              36.5G read, 130.2G written, 80.4G outgoing IP traffic
Jun 05 07:00:07  Started   (restarted by nightly-restart-background)
```

The 17:31→07:00 run pegged **>1 core for 13.5h wall (16h29m CPU)** and pushed
**80.4 GB outbound** — consistent with tens of thousands of large LLM requests
being re-sent. The previous run (→17:31) was also hot (3h CPU / 17.6 GB out),
so heavy load spanned ~15:00→07:00 across one restart.

Live process snapshot confirms this server is the hub: many
`opencode attach http://127.0.0.1:4096 --session ses_... --dir .../worktrees/pr-XXXX`
clients (the lgtm review worktrees) plus interactive TUIs; the heavy CPU lives
in `opencode-serve`, not the lightweight attach clients.

### 2. The drop at 07:00 UTC is a forced restart, not completion

`systemctl cat nightly-restart-background.{timer,service}`:
`OnCalendar=*-*-* 03:00:00` (ET) → fires 07:00 UTC. Journal:

```
Jun 05 07:00:03  Starting Nightly workspace reset (kill nvims, restart opencode-serve, respawn)...
Jun 05 07:00:07  opencode-serve.service: Started   (the restart)
Jun 05 07:00:11  nightly-restart-background.service: Finished
```

The surge "dropping to tens/hour at 07:00" coincides to the second with this
restart wiping the in-flight (retry-looping) sessions.

### 3. The automation: `lgtm-run.service` (every 10 minutes, all night)

`systemctl cat lgtm-run.{timer,service}`:
- `OnCalendar=*:0/10`, `Persistent=true`, `WorkingDirectory=/home/dev/projects/lgtm`,
  `Environment=OPENCODE_URL=http://127.0.0.1:4096`.
- ExecStart runs `node tsx src/index.ts` ("LGTM PR review cycle").

Source (`~/projects/lgtm/src`):
- `gather.ts:10` → `export const GATHER_MODEL = "google-vertex/gemini-3.5-flash";`
  (the exact surge model). `gather.ts:110-117` builds
  `opencode-launch --model google-vertex/gemini-3.5-flash --mcp slack-ro ...`.
- `dispatch.ts:11` → `REVIEW_MODEL = "google-vertex-anthropic/claude-opus-4-8@default";`
  (the **opus** that reconciles 1:1 with the DB).
- `opencode-launch` (read in full) does **not** spawn an isolated instance — it
  `POST`s `/session` + `/session/:id/prompt_async` to **:4096**, i.e. all this
  work runs inside `opencode-serve` and lands in the main DB.
- `gather.ts:199-210`: on a 120 s timeout lgtm tries to `DELETE` the stray
  gather session, but the code comment itself warns it can be "left burning
  tokens" if the session id wasn't parsed / the DELETE fails.

`journalctl --utc -u lgtm-run.service` overnight (22:00 Jun-4 → 07:30 Jun-5):
**57 cycles**, 6 gather launches, 3 timeouts, 1 error, 48 "Nothing to review."
So lgtm's *own* gather launches are few — the gemini volume is dominated by the
**opus reviews' subagents** + **retries**, not raw gather count.

### 4. DB attribution (read-only, `opencode.db`, 4.49 GB)

Sessions created in window, by `model` + `agent`:

| count | model | agent |
|------:|-------|-------|
| 34 | gemini-3.5-flash | **implementer** |
| 27 | gemini-3.5-flash | **code-reviewer** |
| 26 | claude-opus-4-8 | build (orchestrator) |
| 21 | gemini-3.5-flash | **spec-reviewer** |
|  9 | claude-opus-4-8 | explore |
|  8 | gemini-3.5-flash | build |
|  6 | claude-opus-4-8 | build |

The opus `build` top-level sessions (32 of them) are overwhelmingly titled
**"Review PR with .lgtm-review-prompt.md"** / "LGTM PR review" (lgtm dispatch),
plus a handful of dev sessions ("Forecast events JSON API design", "Upgrading
OpenCode to 1.16", "Fulfiller items polymorphic associations", PROJ-* work).
The gemini sessions are the `implementer`/`code-reviewer`/`spec-reviewer`
**subagents** these orchestrators fan out → confirms the
subagent-driven-development pattern on the default gemini model.

Directories: 68 gemini subagents in `/home/dev/projects/mono`, 14 in
`/home/dev/projects/workstation`, rest in `.worktrees/pr-XXXX` review trees.

**The decisive count — DB vs audit:**
- `step-start` parts overnight, **all sessions/models = 6,017**.
- `step-start` parts overnight in **gemini-model sessions = 2,033**
  (hourly peak 435 @ 04:00 UTC; most hours << 100 → matches the established
  "tens/hour").
- Audit log: **~97,000 gemini calls**.

→ **16–48× more audit calls than the DB ever recorded as completed steps.**
This is only explainable by **retries below the step-start/`service=llm`
persistence point** (a gemini retry storm), not by 97k distinct successful
calls. Opus has no such gap (separate quota/gateway) → reconciles 1:1, exactly
as established.

Dead-zone check (23:30 Jun-4 → 02:30 Jun-5, when *new* session creation was
~0 but the audit surge continued): the sessions still generating parts were a
handful of **long-lived opus `build` dev sessions** (PROJ-6244, "Prod→UAT
weekly reset", PROJ-4774, FBM e2e, PROJ-6234) plus a few gemini subagents and
one lgtm gather ("Enrich review context packet"). Sustained gemini calls with
~0 new sessions = a small set of persistent sessions retry-storming (their
gemini compaction/subagent calls hitting the exhausted gemini quota), not fresh
fan-out.

### 5. Ruled out

- **A/B eval harness on :4097** (`/tmp/opencode/abserve.log`,
  `ab_first_party_sid.txt`, `abtest-data/`): **stale — mtimes 2026-06-02**,
  three days before the surge. Not involved.
- **Manual overnight loop / hand-rolled harness:** `~/.bash_history` (only
  history present; no atuin/zsh/fish) shows **no** `for`/`while`/`xargs`/
  `parallel`/`opencode run`/`XDG_DATA_HOME`/`--data` loop. Just 622 bare
  `opencode` and 82 `oc-auto-attach` lines (interactive). No manual harness.
- **A separate data dir hiding the calls:** `opencode-serve` uses the default
  `~/.local/share/opencode` (no XDG override), same DB the analysis used. The
  calls aren't "in another DB" — they're retries that never persisted.
- **No cron** (`crontab` absent); no `--user` timers; the only relevant system
  timers are `lgtm-run` (10 min) and `nightly-restart-background` (03:00 ET).

---

## (a) Most-supported identification of the launcher

**Primary:** `opencode-serve.service` (the `:4096` headless server,
`opencode-patched-1.15.13.2`) is the process that made the calls. The *work* it
was running overnight, in order of contribution:

1. **`lgtm-run.service`** (systemd timer, every 10 min, unattended all night) —
   opus PR-review sessions that fan out **gemini-3.5-flash** `code-reviewer` /
   `spec-reviewer` subagents + read-only gather sessions. This is the only
   thing guaranteed to run continuously overnight with no human present.
2. **Subagent-driven-development sessions** — opus `build` orchestrators
   spawning `implementer`/`code-reviewer`/`spec-reviewer` gemini subagents
   (default model), e.g. the "Task N … @implementer subagent" sessions in
   `~/projects/workstation` and dev sessions in `~/projects/mono`.
3. **`compaction` (gemini) + default small/title calls** of the long-lived opus
   sessions that stayed alive through the dead zone.

**Amplifier (the real reason the number is 97k):** a **gemini-3.5-flash retry
storm** — quota/rate-limit exhaustion causing ~16–48× retry inflation of a
modest ~2–6k logical-call baseline.

### Ranked hypotheses (if you want it as a list)
1. **(strongest)** lgtm review daemon + subagent fan-out on the default gemini
   model, amplified by a gemini retry/quota storm — fits the model, the UA, the
   timing (10-min cadence + 07:00 restart cutoff), the resource burn, and the
   DB-vs-audit gap. ✅
2. Long-running autonomous opus dev sessions' gemini compaction storming against
   the same exhausted quota (explains sustained calls during the new-session
   dead zone). ✅ contributing
3. A/B eval harness — **rejected** (stale since Jun-2).
4. Manual loop/harness — **rejected** (no such command in history).

## (b) Verdict

**Automated, not normal interactive OpenCode.** The traffic is generated by a
persistent headless server driven by a 10-minute systemd timer (lgtm) plus
agentic subagent fan-out on the global-default gemini model, with the raw count
inflated ~16–48× by a gemini retry storm. A human typing in a TUI does not
produce 6–7k calls/hour sustained across a midnight dead zone, and the surge
ends precisely at a scheduled service restart.

## (c) Forward-capture proposal (NOT installed — proposal only)

Goal: durably attribute the *next* surge. Two log signals matter and live in
`~/.local/share/opencode/log/<ISO-start>.log` (a **new file per server start**,
and the dir is wiped on restart/cleanup — which is why this window's logs are
gone):

- `service=llm` lines (logical calls + attribution). Real format on this box:
  `INFO ... service=llm providerID=anthropic modelID=claude-opus-4-8 session.id=ses_... small=false agent=build mode=primary stream`
- **error/retry lines** (e.g. `RESOURCE_EXHAUSTED`, `429`, retry/abort) — needed
  because `service=llm` logs *logical* calls (~2–6k), **not** the ~97k retries;
  to catch a retry storm you must also capture the provider error lines.

**Minimal durable capture** — a tiny always-on follower that re-tails the newest
log file across restarts and appends matching lines to a path *outside* the
cleanup/worktree/cache scope (`~/.local/state/...`):

```bash
#!/usr/bin/env bash
# opencode-llm-audit: append attributable LLM + retry lines to a kept file.
set -euo pipefail
OUT=/home/dev/.local/state/opencode-llm-audit/llm.log
mkdir -p "$(dirname "$OUT")"
cd /home/dev/.local/share/opencode/log
while :; do
  newest=$(ls -1t ./*.log 2>/dev/null | head -1) || true
  [ -z "${newest:-}" ] && { sleep 2; continue; }
  stdbuf -oL tail -n0 -F "$newest" 2>/dev/null \
    | stdbuf -oL grep -E 'service=llm|RESOURCE_EXHAUSTED|status=429|retry|AbortError' \
    >> "$OUT" &
  tail_pid=$!
  # swap to a newer log file when opencode-serve restarts
  while :; do
    sleep 5
    cur=$(ls -1t ./*.log 2>/dev/null | head -1) || true
    [ "${cur:-}" != "$newest" ] && { kill "$tail_pid" 2>/dev/null || true; break; }
  done
done
```

Wire-up (matching this repo's idiom; all proposals, nothing applied):
- A `systemd` service (system service mirroring `opencode-serve.service`, or a
  `--user` service) running the script above, `Restart=always`.
- A `logrotate` stanza on `~/.local/state/opencode-llm-audit/llm.log`
  (e.g. daily, `rotate 14`, `compress`) so it can't grow unbounded.
- **Place output under `~/.local/state`** (verify it is excluded from the
  nightly-restart/disk-cleanup scope before relying on it).

With this in place, the next surge is attributable in seconds: group captured
`service=llm` lines by `modelID`/`agent`/`session.id` to see *who* is calling,
and the co-captured `RESOURCE_EXHAUSTED`/`429`/`retry` lines reveal whether the
volume is real work or (as here) a retry storm.

Optional hardening (separate change): set an explicit `small_model` and a
non-gemini `compaction` model, and/or cap provider retries, so a gemini quota
hiccup can't silently 48×-amplify into ~97k calls again.
