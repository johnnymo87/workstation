# Scheduled swarm wake — design

**Status:** design / scope-only. Nothing implemented.
**Date:** 2026-07-31
**Requested by:** session `ses_049ab3796ffeUNA3fHLwWeKb1Q`, which is currently
mid-way through exactly the failure mode described below (holding a 13-hour
wait for a 09:15 UTC prod cron verification).
**Implementation target repo:** `~/projects/pigeon` (not workstation). This doc
lives in workstation only because that is where the requesting worktree is.

---

## 1. Problem

A session routinely ends a turn with "next checkpoint is in 13h" — waiting for a
daily cron in prod to fire so it can verify the effect. There is no mechanism for
a session to wake itself at a future time. In practice the thread is dropped: the
human has to remember, and usually doesn't.

The load-bearing observation: **a swarm message revives a session.** Pigeon
delivers by `POST /session/:id/prompt_async` against the owning serve
(`packages/daemon/src/opencode-client.ts:216-229`), which starts a fresh turn
with the session's persisted context. So "wake me at T" reduces to "deliver a
swarm message to session S at T".

Hard requirement: must survive the nightly 03:00 workspace reset **and** host
reboot. An in-memory timer is useless — the nightly unit restarts
`pigeon-daemon.service` as its very first action
(`hosts/cloudbox/configuration.nix:2171`).

---

## 2. Findings from existing code

### 2.1 Pigeon already is a durable, restart-proof scheduler — it just doesn't expose one

Everything a scheduler needs is already built and in production:

| Need | Existing mechanism | Cite |
|---|---|---|
| Durable store | SQLite, WAL, one file | `packages/daemon/src/storage/database.ts:36-64`; path `PIGEON_DAEMON_DB_PATH` → `/home/dev/projects/pigeon/packages/daemon/data/pigeon-daemon.db` (`hosts/cloudbox/configuration.nix:73,476`) |
| Poll loop | `SwarmArbiter.start(500)` — `setInterval` 500 ms | `packages/daemon/src/swarm/arbiter.ts:52-55`; started `index.ts:369-384` |
| **Future-dated readiness predicate** | `next_retry_at IS NULL OR next_retry_at <= ?` | `packages/daemon/src/storage/swarm-repo.ts:109-126` (`getReadyForTarget`), `:127-138` (`listTargetsWithReady`) |
| Delivery | `sendPrompt` → `prompt_async` w/ `x-opencode-directory` | `opencode-client.ts:216-229` |
| Retry + terminal | 10 attempts, backoff `[1s,2s,5s,15s,60s]` | `arbiter.ts:16-23,129-147` |
| Idempotency | `msg_id` PK + `ON CONFLICT(msg_id) DO NOTHING` | `swarm-repo.ts:79-100` |
| Restart safety | `markHandedOff` only after 2xx | `swarm-repo.ts:140`; `arbiter.ts:111-113` |
| Post-delivery verification | `DeliveryWatchdog` reads the transcript for the `msg_id` anchor | `swarm/delivery-watchdog.ts:173-182,640-645` |
| Human alerting | Telegram `notifier.sendPlainAlert` already injected into daemon subsystems | `index.ts:408,436,469,533` |
| Additive migration pattern | one-transaction ALTER + backfill | `storage/swarm-schema.ts:48-84` |

**The critical structural point:** because the "when" is a *column consulted by a
poll loop* rather than an armed timer, there is **no re-arm problem at all**.
Daemon restart, reset, reboot, restart storm — the row is still there and the
next 500 ms tick picks it up. Persistence and reboot-survival come for free.

### 2.2 What does *not* exist

Grepped `packages/`, `docs/`, `.opencode/`, `AGENTS.md`, `.beads/issues.jsonl`
for `deliver_at|deliverAt|scheduled|cron|delay|defer|ttl|expire|snooze|wake`:

- **No scheduling primitive of any kind on the swarm path.** No "send at T", no
  TTL, no expiry, no dead-letter table.
- `POST /swarm/send` has no field that could set a future time — `insert`
  hardcodes `next_retry_at = NULL` (`swarm-repo.ts:86-90`).
- `SWARM_RETENTION_MS = 7d` is declared (`swarm-schema.ts:3`) and
  `cleanupOlderThan` exists (`swarm-repo.ts:300-308`) but **nothing calls
  either** — swarm rows are currently never pruned. Relevant because a scheduler
  adds long-lived rows and I would otherwise be tempted to lean on retention.
- Pigeon cannot launch a session. `opencode-launch` is a workstation shell
  script (`pkgs/opencode-launch/default.nix`) and always `POST /session`, i.e.
  always a **new** id (`:368-374`); no flag accepts an id (`:147-229`).

### 2.3 Q2 (the crux): **session ids survive the nightly reset. Verified.**

This was the question most likely to invalidate the whole design. It doesn't.

Four independent lines of evidence:

1. **Nothing deletes sessions.** No `DELETE`/`DELETE /session` anywhere in
   `pkgs/reset-workspace/default.nix` (970 lines) or the nightly unit
   (`hosts/cloudbox/configuration.nix:2144-2183`). The only writes this repo makes
   to `opencode.db` are a WAL checkpoint (`users/dev/disk-cleanup.nix:286-300`)
   and a devbox-only `UPDATE message ...` phantom-busy sweeper
   (`users/dev/home.devbox.nix:1332-1343`, not deployed on cloudbox).
2. **Documented explicitly** — `.opencode/skills/resetting-workspace/SKILL.md:151-153`:
   "`reset-workspace` no longer DELETEs opencode sessions. Sessions accumulate in
   the DB across resets (today: ~1500 sessions)."
3. **The reattach path consumes an existing id and refuses to invent one.**
   `pkgs/oc-auto-attach/default.nix:250-257` requires exactly one `ses_...` arg;
   `:331` probes `GET $url/session/$sid`; `:358` gives up on 404. The morning
   agent prompt baked into the reset tells it to run
   `oc-auto-attach --tmux-session main <sid>` per manifest id
   (`pkgs/reset-workspace/default.nix:945`).
4. **Live proof.** A sid from this morning's manifest still resolved *after* the
   03:00 reset and after the 09:18 serve-pool bounce:
   `GET :4700/session/ses_04aba21d4ffe4jfqy6lF3UrGJK` → 200 with `directory` and
   original `time.created`.

Serve restarts don't change ids either: the session lives in the shared
`opencode.db`; only the *ownership* row moves, via
`~/projects/pigeon/packages/daemon/src/routing/router.ts:326-345`
(`reassignFromDeadServe` → `placeSession`). Pigeon re-resolves the owner on every
delivery attempt (`routing/client-factory.ts:19-28`), so a 13-hour-old target id
is resolved fresh at fire time.

**Conclusion: no indirection layer, alias table, or directory re-resolution is
needed. Address the raw session id.** What a reset destroys is TUIs and serve
processes, not sessions. A woken session with no TUI still runs its turn; a human
reattaches later with `oc-auto-attach --tmux-session main <sid>`.

Residual unknown (see §7): whether opencode core itself ever GCs old session rows.
Nothing in workstation sets a retention; empirically the DB only grows (13 GB,
~1500 sessions).

### 2.4 What the nightly reset actually does (ordered)

From `pkgs/reset-workspace/default.nix`, driven by
`hosts/cloudbox/configuration.nix:2144-2183` at `03:00`, `Persistent=true`:

0. `systemctl restart pigeon-daemon.service` (unit wrapper, `:2171`) — **pigeon
   dies first**, before reset-workspace starts.
1. `tmux kill-session -t '=lgtm'` (`:417-420`)
2. write manifest `/tmp/reset-workspace-last-manifest.txt` (`:679-686`) — live
   `main`-tmux-derived sids, one per line
3. `pkill -9 -u dev -x nvim` (`:733-742`) — takes TUIs with it
4. `systemctl restart opencode-serve-pool.target` (`:781-808`) — `partOf` fans
   out to all 4 serves (`hosts/cloudbox/configuration.nix:677`)
5. `opencode-launch "$HOME/morning" ...` (`:914-964`) — new session, new id

Implication for the design: at 03:00 the daemon restarts and every serve
restarts. A wake scheduled for 09:15 must be immune to both. A DB column is.
An `at(1)` job or a transient systemd timer arguably also survives, but see §5.

---

## 3. Recommended design

### 3.1 Placement: in the pigeon daemon, as two nullable columns on `swarm_messages`

Not a new table, not a new daemon, not a new state machine. A scheduled wake **is
a swarm message that isn't ready yet**, and pigeon's readiness predicate is
already time-based.

### 3.2 Schema (additive, follows `swarm-schema.ts:48-84`)

```sql
ALTER TABLE swarm_messages ADD COLUMN deliver_at INTEGER;  -- epoch ms, NULL = now
ALTER TABLE swarm_messages ADD COLUMN expires_at INTEGER;  -- epoch ms, NULL = never
ALTER TABLE swarm_messages ADD COLUMN cancelled_at INTEGER;
CREATE INDEX IF NOT EXISTS idx_swarm_scheduled
  ON swarm_messages(state, deliver_at);
```

No backfill needed (all NULL = current behaviour exactly).

**Deliberately a separate column from `next_retry_at`, not a reuse.** They mean
different things and the arbiter overwrites `next_retry_at` on every failed
attempt (`swarm-repo.ts:217-225`). Overloading it would make the first delivery
failure of a scheduled wake silently reschedule it to +1s, destroying the
scheduled semantics, and would make a 13-hour-pending row indistinguishable from
a stuck retry for any human or future alerting. Both predicates must hold:

```sql
AND (next_retry_at IS NULL OR next_retry_at <= ?)
AND (deliver_at    IS NULL OR deliver_at    <= ?)
```

applied in `getReadyForTarget` (`swarm-repo.ts:109-126`) and
`listTargetsWithReady` (`:127-138`). Two lines each. That is the entire
scheduling engine.

New terminal states alongside `handed_off`/`failed` (state union `swarm-repo.ts:16`):
`expired` and `cancelled`. Safe to add: `GET /swarm/inbox` filters to
`handed_off` only (`swarm-repo.ts:263`), so neither leaks into anyone's inbox.
Widen the `SwarmMessageRecord["state"]` union too, or `asRecord`'s cast lies.

### 3.3 API surface

**HTTP (daemon):**

- `POST /swarm/schedule` — same body as `/swarm/send` plus `at` **or** `after`,
  and optional `expires_in`. Returns `202 {accepted, msg_id, deliver_at, expires_at}`.
  Reuses the whole existing validation block (`app.ts:152-204`): `from` required,
  `ses_` shape check, close-tag rejection. Add: `deliver_at` must be in the future
  and within a sanity horizon (reject > 30 days — a typo'd year should 400, not
  lurk in the DB until 2027).
- `GET /swarm/scheduled?session=<sid>` — pending wakes where `from_session` or
  `to_session` matches. Needed because the woken agent must be able to see what it
  already has queued.
- `POST /swarm/scheduled/:msg_id/cancel` — sets `state='cancelled'`,
  `cancelled_at`. Only from the original `from_session` (the plugin fills `from`
  from `ctx.sessionID`, unspoofable — `swarm-send-tool.ts:295`).

**Plugin tools** (`opencode-plugin/src/index.ts:310-318`), two, not three:

- `swarm_schedule(to, at | after, message, kind?, priority?, expires_in?)`
- `swarm_scheduled(action: "list" | "cancel", msg_id?)`

Rationale for a distinct tool rather than an optional `at` on `swarm_send`: the
tool *description* is the discovery mechanism for the model. An agent that ends a
turn with "next checkpoint in 13h" will not find a buried optional parameter; it
will find a tool named `swarm_schedule`. Cost is ~1 extra tool in every session's
prompt — acceptable, and the description can be short.

`to` defaults to the calling session (self-wake is the dominant case). Cross-session
scheduling falls out for free.

### 3.4 Time parsing (Q5)

- `after`: duration string — `13h`, `90m`, `2d`. Unambiguous. **Preferred form,
  and what the tool description should push.**
- `at`: RFC3339 **with mandatory offset or `Z`** — `2026-08-01T09:20:00Z`.
- **Reject naive wall-clock** (`2026-08-01 09:20`) with a 400 that names the
  problem. Guessing a zone is how you get a wake that's an hour wrong twice a
  year. This is a machine-to-machine API; requiring an offset costs the caller
  nothing.
- No recurrence in v1. Cron-shaped needs belong in systemd timers or beads, and
  recurrence drags in DST-shifting wall-clock semantics that the above dodges.
- Stored as epoch ms UTC throughout, matching every other timestamp in the table.

### 3.5 Catch-up / staleness (Q3)

**Deliver late, but bounded, and tell the receiver how late.**

- `expires_at` defaults to `deliver_at + 6h` (configurable per-message via
  `expires_in`, and globally via env in the `config.ts:98-102` style).
- Sweeper in the arbiter tick: `state='queued' AND expires_at <= now` →
  `state='expired'`, log, and **Telegram alert** (§3.7).
- Delivered envelope carries the lateness so the agent can self-assess. Extend
  `EnvelopeFields` (`swarm/envelope.ts:1-12`, attrs built at `:56-67`):

  ```
  <swarm_message v="1" kind="wake.scheduled" from="ses_..." to="ses_..."
    msg_id="msg_..." priority="normal"
    scheduled_for="2026-08-01T09:20:00Z" delivered_late_ms="742000">
  ```

Rationale for not silently dropping: a wake that fires 3 h late for "verify the
09:15 run" is still useful — the run still happened, the evidence is still there.
A wake that fires 3 *days* late is noise and can be actively harmful (the agent
re-verifies a run that has since been superseded). 6 h is a guess; it is a knob,
and the `delivered_late_ms` attr means the agent can bail on its own even inside
the window. Do not make the agent guess — give it the number.

Caveat the skill must state: **`delivered_late_ms` measures delivery, not
processing.** A wake handed off on time but queued behind a 2 h blocking turn
reads as `delivered_late_ms≈0` while actually being *read* 2 h late. The agent
should compare `scheduled_for` against the actual wall clock (`date`) on receipt,
not trust the attr alone.

#### 3.5.1 For `wake.*`, `expires_at` is the ONLY terminal clock

**This is the correction that matters most.** As designed above, a wake would
still be governed by the arbiter's `MAX_ATTEMPTS = 10` with backoff
`[1s,2s,5s,15s,60s]` clamped (`arbiter.ts:16-23`) — a **total retry budget of
~324 seconds**. And "no healthy serve" *counts as an attempt*: `clientForSession`
returns `undefined` → plain `throw` (`arbiter.ts:90-93`) → not a
`PermanentDeliveryError` → `markRetry`, attempts+1 (`arbiter.ts:127-147`).

Now the collision. An agent that says "wake me in 13h" at ~14:00 gets
`deliver_at ≈ 03:00` — **exactly when the nightly unit restarts pigeon and then
bounces all four serves** (`hosts/cloudbox/configuration.nix:2171`;
`reset-workspace/default.nix:781-808`). Pigeon returns in ~5 s (`RestartSec=5`)
while the serves are still restarting and health-polling. If the pool takes more
than ~5.5 min to become routable, the wake burns its entire budget and goes
terminal `failed` — for a session that is perfectly healthy at 03:10.

§3.8's "restart storm is a non-event" covers *pigeon* being down (no attempts
burned, nothing polls). It does **not** cover pigeon-up + serves-down, which
burns the whole budget. A 5.4-minute retry budget against a 6-hour staleness
window is wildly asymmetric, and 03:00 is a *likely* wake time, not an edge case.

**Required change:** for `kind` matching `wake.*`:

- Routing unavailability (`NoHealthyServeError` / `clientForSession` undefined /
  directory-resolution failure) **does not increment `attempts`** — it is not a
  delivery failure, it is the delivery not having been attempted. Reschedule via
  `next_retry_at` and move on.
- `MAX_ATTEMPTS` does not apply; `expires_at` is the sole terminal clock. Then the
  design's own staleness window does exactly what §3.5 promises, and a wake that
  lands mid-reset simply delivers at 03:06 instead of dying.

Recovery from a routine nightly event must not require a human reading a Telegram
alert.

### 3.6 Missing / dead / compacted target (Q4)

**v1 does not relaunch. Say so plainly and alert instead.**

- Session ids survive resets (§2.3), and there is **no upstream GC** (confirmed by
  the human, 2026-07-31 — see §7.1), so "target gone" means "explicitly deleted"
  and is genuinely rare.
- Existing failure handling already covers dead targets: the watchdog's
  404-confirmed-by-second-serve path (`delivery-watchdog.ts:528-550`). Note that
  per §3.5.1 a `wake.*` message is **not** subject to `MAX_ATTEMPTS`; a truly dead
  target terminates via that 404 path or via `expires_at`.
- The existing terminal-failure notification sends a `delivery.failed` swarm
  message **back to the sender** (`swarm/notify-sender.ts:19-48`). For a self-wake
  that is a message to the session that just proved unreachable — **useless**.
  This is the single most important gap to close: for `kind` starting with
  `wake.`, terminal failure or expiry must additionally fire
  `notifier.sendPlainAlert` (Telegram), **with the wake payload inline** so the
  human gets the actual instruction, not just "delivery failed".
  **This must cover all four terminal paths, not just the arbiter's:**
  arbiter terminal (`arbiter.ts:129-135`), watchdog 404-confirmed
  (`delivery-watchdog.ts:528-550`), watchdog stuck-after-recovery (`:664-689`),
  watchdog max-requeues (`:742-752`). All four alert today, but generically and
  without the payload. Wiring only the arbiter leaves half the gap open.

**The woken session's working directory may be gone.** Reset Step 4 runs
`work --prune-merged` in `~/projects/mono` (`reset-workspace/default.nix:755-764`),
which prunes worktrees that are merged and clean — which is *precisely* the state
of "PR merged, wake me at 09:15 to verify the prod cron". The wake then fires into
a session whose `x-opencode-directory` no longer exists on disk. Session id stable
≠ session *environment* stable. Untested; at minimum the skill must say "a wake
from a launch-worktree session may find its cwd gone — the payload must not depend
on the worktree", and the schedule tool should ideally warn at schedule time if the
caller's directory is a prunable worktree.
- Relaunch-if-absent (`opencode-launch` from the daemon) is deferred. It means a
  system-level node service shelling out to a workstation script, a brand-new
  session id, and a fresh context that has none of the original session's state —
  so it is only useful if the payload is fully self-contained anyway. Which leads
  to:

**Payload must be self-contained.** The wake message must carry a durable pointer
— a beads id, a PR number, a file path — not "continue what you were doing". The
compaction case makes this non-optional: a session woken at 09:20 may have
compacted away the reason it scheduled the wake. Enforcement is weak by nature;
proposal:

- `swarm_schedule` tool description states the requirement in the imperative and
  gives a worked example.
- Optional `ref` field (e.g. `bd:workstation-abcd`) rendered as an envelope attr.
- Soft validation: 400 on payloads under ~40 chars (catches "check on it").

Mechanical enforcement of "is this self-contained?" is not possible. Stating that
honestly is better than a validator that pretends.

### 3.7 Failure visibility (Q7)

The motivating bug is a silent drop, so a scheduler that can itself silently drop
is worthless. Four layers, all reusing existing machinery:

1. **Telegram alert** on `expired` and on `failed` for `wake.*` kinds, with the
   payload inline (§3.6). `notifier.sendPlainAlert` is already injected into daemon
   subsystems (`index.ts:408,436,469,533`); the arbiter currently has no notifier
   and would need the same injection the watchdog got.
2. **Overdue-still-queued alert** — a scheduled row whose `deliver_at` passed by
   > 5 min while still `queued`. This catches "the delivery loop isn't running at
   all". **It must NOT live in the arbiter tick**, which is where §3.5's expiry
   sweeper naturally wants to go: a dead arbiter would mean a dead sweeper and no
   alert — self-monitoring by the possibly-dead component. Put it in the
   `DeliveryWatchdog` cycle, which runs on a separate 60 s interval and already has
   the notifier (`delivery-watchdog.ts:340-349`, `index.ts:533`).
3. **`POST /swarm/schedule` must 503 when the arbiter isn't started.** The arbiter
   and watchdog start only under `config.opencodeUrl || ingressRouter` gates
   (`index.ts:369,529`), while `POST /swarm/send` accepts 202 unconditionally
   (`app.ts:152-204`). A config regression would have the daemon cheerfully banking
   wakes it will never deliver — the motivating bug, rebuilt inside the fix.
4. **Partial watchdog reuse** — scheduled wakes become ordinary `handed_off` rows
   and get the anchor-in-transcript verification
   (`delivery-watchdog.ts:173-182,640-645`) and requeue for free. This is real
   hardening at no cost. **But the abort-blocking-turn escalation must be
   suppressed for `wake.*`** — see below. Earlier drafts of this doc called the
   whole watchdog "hardening obtained at zero cost". That was wrong.

#### 3.7.1 The watchdog's abort escalation must not apply to wakes

If a wake is delivered while the target is mid-turn, the prompt queues, the
watchdog sees it unverified, and if the blocking turn shows no part activity for
> `stuckAbortSilenceMs` (1 h default, `delivery-watchdog.ts:60`) it **aborts the
running turn** and redelivers (`:711-721,754-843`).

"Silent for 1 h" is satisfied by a single long-running tool call — `lastActivityOf`
only sees a part's `time.start` until the tool completes (`:221-253`). A 90-minute
build or a long poll qualifies. And wakes make this materially worse than the
status quo: they fire at scheduled times with zero regard for target state, at
hours when nobody is watching, and the sessions most likely to *use* wakes are
long-horizon autonomous sessions most likely to be inside long tool calls.

Net effect if left as-is: the reminder mechanism destroys the in-flight work it
was supposed to check up on. **For `wake.*`, alert-and-requeue only; no abort.**
(Or gate abort on `priority="urgent"`, which a wake should never default to.)
The verification/requeue half is the free hardening; the abort half is a
destructive intervention that a reminder does not justify.

Residual, accepted: the alert path is itself best-effort — `sendPlainAlert`
failures are caught-and-logged (`delivery-watchdog.ts:374-381`) and a daemon with
no notifier configured is silent (`index.ts:404-408`). Cheap partial close:
`GET /swarm/scheduled` should also surface recent **terminal** wake outcomes
(`expired`/`failed` since last reset), not just pending ones, so the morning agent
can report them. The DB is the durable record — use it.

### 3.8 Duplicates / restart storms (Q6)

Mostly already solved:

- `msg_id` PK + `ON CONFLICT DO NOTHING` (`swarm-repo.ts:79-100`); the plugin
  mints the id once and reuses it across its own retries
  (`swarm-send-tool.ts:76-78,145`).
- `markHandedOff` only after a 2xx (`arbiter.ts:111-113`), so a crash mid-delivery
  re-delivers rather than dropping. At-most-once is not achievable over
  `prompt_async`; at-least-once with an idempotent id is the right trade. **The
  skill must therefore say: a wake may arrive twice; make the action idempotent.**
- At-most-one in-flight per target (`arbiter.ts:37,70-81`) means a session with 5
  wakes firing at once gets them serialized, not 5 concurrent turns.
- **Restart storm is a non-event**: no timers to re-arm. `Restart=on-failure`,
  `RestartSec=5` (`hosts/cloudbox/configuration.nix:539-540`); each start just
  resumes polling. Worst case a crash loop delays a wake by the loop duration —
  which the staleness window (§3.5) then covers. Note this argument covers
  *pigeon* being down; pigeon-up-with-serves-down is a different and worse case,
  handled by §3.5.1.
- **State guards are missing today and must be added.** `markHandedOff` is an
  unconditional `UPDATE ... WHERE msg_id = ?` (`swarm-repo.ts:140-148`). A cancel
  landing between `getReadyForTarget` and the 2xx would deliver anyway *and*
  overwrite `cancelled` → `handed_off`. Narrow window, but the fix is one clause:
  `AND state = 'queued'`, then check `changes`. Same guard makes the
  expiry-vs-delivery race clean. Applies to `markExpired`/`markCancelled` too.
- One real hazard: a burst of wakes all scheduled for the same round hour. The
  per-target serialization handles same-target; cross-target it's 500 ms ticks
  against 4 serves. Fine at the expected volume (single digits/day).

---

## 4. What this does *not* solve

- **The TUI is not reopened.** The woken session runs its turn headless. The human
  sees it next time they run `oc-auto-attach`, or via the Telegram path. Adding
  auto-attach on wake means the daemon invoking `oc-auto-attach` (workstation
  script, needs tmux + a live `main` session) — deliberately out of scope.
- **Nothing forces the agent to actually schedule a wake.** The behavioural half
  is a skill change: `swarm-messaging` (or a new stanza) must say "if you are
  ending a turn on a future checkpoint, schedule the wake before you stop."
  Without that, the tool exists and never gets called. **This is at least as
  important as the code** and should ship in the same change.

---

## 5. Rejected alternatives

| Alternative | Why rejected |
|---|---|
| **`at(1)` spool + curl to pigeon** | On-disk and reboot-surviving, true. But `atd` isn't installed or enabled on cloudbox; it's a second delivery path with its own failure mode, no cancellation UX an agent can reach, no listing, no integration with the retry/watchdog hardening, and no visibility beyond mail-to-root nobody reads. Would reimplement §3.7 from scratch. |
| **`systemd-run --on-calendar` transient unit** | Transient units do **not** survive reboot. Fails the hard requirement outright. Persistent units would mean writing unit files at runtime from an agent's tool call — worse. |
| **A `.timer`/`.service` pair per wake, generated into the nix config** | Requires a rebuild per wake. Absurd latency and blast radius for "remind me in 13h". |
| **New dedicated scheduler daemon** | Duplicates SQLite, the poll loop, retry, envelope rendering, routing, and the watchdog — all of which pigeon has in production. Strictly more moving parts for strictly less hardening. |
| **Timer in the opencode plugin (in-session)** | The plugin lives in the serve process. Nightly reset restarts the whole pool (`reset-workspace/default.nix:781-808`); reboot kills it. Fatal for the exact 13-hour case that motivates this. |
| **Beads issue with a due date + a scanning cron** | bd has no delivery mechanism, so this still needs a poller that calls `swarm_send` — i.e. it's this design plus a second datastore. Beads remains the right place for the *work item*; the wake is the *delivery*, and the wake payload should reference the bead. Complementary, not alternative. |
| **Reuse `next_retry_at` instead of a new `deliver_at`** | The arbiter overwrites `next_retry_at` on every failed attempt (`swarm-repo.ts:217-225`), so the first transient failure would collapse a scheduled wake into an immediate retry. Also makes a pending wake indistinguishable from a stuck delivery in every operational query. |
| **Stable alias / indirection layer over session ids** | Would be mandatory if ids changed at reset. They don't (§2.3, verified four ways). Building the indirection anyway is speculative complexity on a verified-false premise. |

---

## 6. Implementation sketch

Ordered, each step independently testable. Pigeon's test idioms:
in-memory DB via `openStorageDb(":memory:")`, injected `fetchFn`/`nowFn`, drive
the arbiter with `processOnce()` (`.opencode/skills/swarm-development/SKILL.md:18-33`).

1. **Schema + repo** (`swarm-schema.ts`, `swarm-repo.ts`) — 3 columns, 1 index,
   readiness predicates, `listScheduled`, `markCancelled`, `markExpired`,
   `listExpired`. Tests: a row with future `deliver_at` is not returned by
   `getReadyForTarget`/`listTargetsWithReady` and *is* returned once `nowFn`
   advances past it. **~2h**
2. **Time parsing** — `parseSchedule({at, after})` → epoch ms; reject naive
   wall-clock, past times, > 30 d horizon. Pure function, table-driven tests. **~1h**
3. **Routes** (`app.ts`) — `POST /swarm/schedule`, `GET /swarm/scheduled`,
   `POST /swarm/scheduled/:id/cancel`. Reuse the existing validation block.
   Tests in the `swarm-routes.test.ts` style. **~2h**
4. **Wake retry semantics** (`arbiter.ts`) — §3.5.1. Classify routing/directory
   unavailability separately from delivery failure; for `wake.*`, don't increment
   `attempts` on it and don't apply `MAX_ATTEMPTS`. Tests: a wake whose target has
   no healthy serve for 20 min still delivers when the serve returns; a wake past
   `expires_at` does not. **~2h**
5. **Expiry sweeper + wake alerting** — sweep expired rows; inject `notifier` into
   the arbiter the way the watchdog has it (`index.ts:533,558`); wake-payload-inline
   alerts on **all four** terminal paths (§3.6). Overdue-still-queued check goes in
   the **watchdog** cycle, not the arbiter (§3.7 layer 2). `/swarm/schedule` returns
   503 when the arbiter isn't started (§3.7 layer 3). **~3h**
6. **Watchdog abort suppression for `wake.*`** (`delivery-watchdog.ts`) — §3.7.1.
   Keep verify + requeue, skip the abort escalation. Test: a `wake.*` message
   blocked by a silent-for-2h turn alerts and requeues but never calls abort. **~1h**
7. **Envelope attrs** (`envelope.ts`) — optional `scheduled_for`,
   `delivered_late_ms`, `ref`. Contract test: envelope shape for a non-scheduled
   message must be **byte-identical** to today's. **~1h**
8. **Plugin tools** (`opencode-plugin/src/`) — `swarm_schedule`,
   `swarm_scheduled`, mirroring `swarm-send-tool.ts` (retry, `msg_id` reuse, 401
   re-auth). **~3h**
9. **Skill update** (workstation) — `swarm-messaging` gains a "scheduling a
   wake" section: when to use it, the self-contained-payload rule, the beads-ref
   convention, "check the wall clock on receipt, don't trust `delivered_late_ms`",
   "wakes may arrive twice — be idempotent", "your worktree may be gone", a
   restraint clause, and the "don't end a turn on a future checkpoint without
   scheduling" imperative. **~1.5h**
10. **End-to-end verification** — schedule a wake `after=3m` to self; confirm the
    turn fires; then a `after=8h` scheduled *before* a manual
    `systemctl restart pigeon-daemon` **and** a serve-pool restart, confirming the
    row survives, does not burn attempts while the pool is down, and still fires.
    The reboot case can be argued from the SQLite properties rather than actually
    rebooting cloudbox. **~1.5h**

Also housekeeping during step 1: widen `SwarmMessageRecord["state"]`
(`swarm-repo.ts:16`) for the new states, or `asRecord`'s cast silently lies to
every consumer; and add `expired`/`cancelled` to `cleanupOlderThan`'s state list
(`swarm-repo.ts:300-308`) so they can eventually be pruned.

**Total: ~2 days.** Steps 1-3 alone (~5h) is a demo, not a shippable feature:
without steps 4-6 a wake scheduled for 03:00 dies in the nightly reset (§3.5.1)
and a wake can abort a live turn (§3.7.1). **Do not ship 1-3 alone** — that
reintroduces the silent-drop failure this exists to fix, inside the fix.

---

## 7. Open questions and risks

1. ~~**Upstream session retention.**~~ **RESOLVED 2026-07-31: there is no GC.**
   opencode retains sessions indefinitely; the "within retention" wording in
   `understanding-workspace-reset/SKILL.md:26` does not correspond to any actual
   collection. Combined with §2.3, a session id is a permanently valid address.
   The 30-day horizon cap in §3.3 stays anyway, as a typo guard (a fat-fingered
   year should 400, not lurk in the DB until 2027), not as a retention hedge.
2. **`SWARM_RETENTION_MS` is dead code** (`swarm-schema.ts:3`, `cleanupOlderThan`
   never called). Note the earlier draft of this doc claimed naive retention would
   delete pending wakes — **that was wrong**: `cleanupOlderThan` deletes only
   `state IN ('handed_off','failed')` (`swarm-repo.ts:300-308`), so queued rows are
   already excluded. The real gap is the opposite: new `expired`/`cancelled` rows
   match no cleanup clause and would accumulate forever. Extend the `IN` list when
   adding the states (folded into §6 step 1).
3. **DB file lives inside a git working directory**
   (`~/projects/pigeon/packages/daemon/data/`). Survives reboot, but a reclone or
   an aggressive clean loses every pending wake. Pre-existing risk, now with
   higher stakes.
4. **Storm risk from a "helpful" agent** scheduling wakes reflexively. The
   per-target serialization limits damage, but the skill guidance should include a
   restraint clause in the spirit of the existing message-economy section
   (`swarm-messaging/SKILL.md:47-77`).
5. **Does a queued `prompt_async` survive a lease handover mid-turn?** Not traced
   (`router.ts:326-345` read, `placeSession`/`ensureRouted` not fully). Low impact
   — pigeon re-resolves the owner per attempt and retries — but unverified.
6. **6 h default staleness window is a guess.** Should be revisited after a few
   real wakes.
7. **Behavioural adoption is the real risk.** The mechanism is ~2 days; getting
   agents to actually call it at the moment they'd otherwise drop the thread is the
   hard part, and is a prompt/skill problem, not a code problem.
8. **Cancel authorization is not "unspoofable".** The plugin fills `from` from
   `ctx.sessionID` (`swarm-send-tool.ts:295`), but the daemon's HTTP API only checks
   the bearer token — anything holding it can claim any `from`. Fine inside this
   single-user, loopback-bound trust boundary; just don't describe it as a security
   property. (Earlier draft did.)
9. **Behaviour of a woken session whose worktree was pruned is untested** (§3.6).
   Worth one deliberate experiment during step 10 rather than discovering it at
   03:00 some morning.

---

## 8. Bottom line

This is **easier than it looks**, for one specific reason: pigeon's delivery
readiness is already a time predicate over a durable SQLite row polled every
500 ms. "Scheduled wake" is that predicate with one more column. There is no
timer to persist and no timer to re-arm, which is exactly why it survives the
nightly reset and reboot.

The premise that could have killed it — session ids changing across the nightly
reset — was checked four ways and is false. Ids are stable, and (confirmed) never
garbage-collected. A session id is a permanently valid address.

The genuinely new work is not scheduling. It is **making the existing retry and
watchdog machinery behave correctly for a message whose sender is asleep and whose
urgency is low.** That machinery was built for live agent-to-agent chatter and has
the wrong temperament for wakes in three specific ways:

- a ~324 s retry budget vs. a 6 h staleness window, colliding with the 03:00 reset
  (§3.5.1) — a wake scheduled 13 h ahead at 14:00 lands *exactly* in the reset;
- an abort-the-blocking-turn escalation that a reminder does not justify (§3.7.1);
- a terminal-failure notification addressed to the sender, who for a self-wake is
  the session that just proved unreachable (§3.6).

Get those wrong and you have rebuilt the silent drop inside the scheduler.

---

## 9. Revision history

- **r1 (2026-07-31)** — initial design.
- **r2 (2026-07-31)** — after adversarial review (`adversarial-reviewer-fable`) and
  the human confirming no upstream session GC. Verdict was "approach right, home
  right, core mechanism claim true, but not implementable as written."
  Changes: added §3.5.1 (wake retry budget vs. reset collision — the severe one,
  missed in r1); §3.7.1 (watchdog abort suppression; r1 wrongly called the whole
  watchdog "hardening at zero cost"); §3.7 layers 2-3 (overdue check must live
  outside the arbiter; `/swarm/schedule` 503s when the arbiter isn't started);
  §3.6 wake alerting must cover all four terminal paths, not just the arbiter's;
  §3.6 pruned-worktree hazard; §3.8 `markHandedOff` state guard; §3.5
  `delivered_late_ms` measures delivery not processing; §7.1 resolved; §7.2
  corrected (r1's claim about retention deleting queued rows was wrong in the safe
  direction, but missed that `expired`/`cancelled` match no cleanup clause); §7.8
  "unspoofable" walked back. Effort 1.5 d → ~2 d.
  Citation errata fixed: inbox `handed_off` filter is `swarm-repo.ts:263` (not
  `:348`); state union is `swarm-repo.ts:16` (not `:101`).
