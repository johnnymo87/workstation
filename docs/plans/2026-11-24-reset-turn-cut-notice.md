# reset-workspace: tell sessions whose turn the reset cut (workstation-dg6)

**Bead:** workstation-dg6 ("reset-workspace / nightly reset can kill sessions with
in-flight questions"). Related: workstation-gwd (closed), workstation-6w7i.16 (goose
program: goose-serve restart without ending in-flight turns, all restart causes).

## Problem

The nightly reset (03:00 ET = 08:00Z, `nightly-restart-background.service` ->
`reset-workspace --yes`) restarts the opencode serve pool (Step 5) and
`goose-serve.service` (Step 6). Any turn running at that moment dies:

- **opencode**: the turn's LLM loop lives only in the serve's memory. The assistant
  message stays `time.completed = NULL`; the phantom-busy sweeper labels it 30+ min
  later; stall-watch then sees a `swept` session. A pending `question` tool call is
  lost with it (in-memory registry), and an answer arriving later is rejected
  ("reply for unknown request"). Nobody re-prompts the agent: a worker mid-task
  just stops.
- **goose**: honkd answers the in-flight prompt `stopReason: cancelled`,
  `_meta.honk.reason: upstream_restart`, records `lastError.kind = interrupted`, and
  (by design) never resends. pigeon tells the *human* "goose restarted and the turn
  was cancelled" for pigeon-originated turns. The *agent* is never told; it sits
  idle until something else prompts it.

Live-window runners work around this by making no tool calls 07:58-08:03Z.

## Options (from the bead) and what is built

1. Refuse/wait to reset while a question is open -- **ruled out** (a forgotten
   question blocks every reset).
2. Synthetic "session was reset" message for anything pending -- **built**, and
   widened from "pending questions" to "any turn in flight", on both harnesses.
3. Persist question state so a restart is harmless -- **not built**. Persisting the
   question registry alone does not help: the agent loop that would consume the
   answer is a promise in the dead process, so a rehydrated question would accept
   an answer that nothing reads. Making it work means patching opencode to turn a
   late answer into a tool result *and* restart the loop -- a deep opencode-patched
   change, while devbox is leaving opencode (eng-agent-platform#475). Option 2 gets
   the same outcome (the agent re-asks the same question; we hand it the text) at
   the cost of the human possibly answering twice. Revisit only if cloudbox stays on
   opencode long-term and the double-answer cost shows up.

## Design

New stdlib-only Python tool `pkgs/turn-cut-notice` (`turn-cut-notice`), called by
reset-workspace. Three subcommands, all **non-fatal to the reset** (reset-workspace
logs a WARNING on non-zero exit and carries on; every external call is bounded by a
timeout):

- `snapshot-opencode --db PATH --live-invocation-ids ID,ID --out FILE`
  Run immediately before Step 5's pool restart. Read-only (`mode=ro`) query of
  opencode.db: top-level sessions (`parent_id IS NULL`, not archived, updated in the
  last 24h) whose **latest message** is an assistant message with no
  `time.completed` and no `error`, stamped `serve.invocationId` in the set of the
  pool units' current systemd `InvocationID`s -- i.e. a turn that a serve we are
  about to kill is running right now (same provenance stall-watch uses). Rows from a
  serve that died earlier are excluded: this reset did not cut them, and the
  notice would lie. If no invocation id could be read, fall back to "message row
  updated in the last 30 min". Also: latest message is a **user** message created in
  the last 10 min (accepted, not yet started). For each hit, collect any `question`
  tool part still `running` on that message and its question texts. Subagent
  sessions are skipped: their parent's `task` call is what was cut, and the parent
  is notified.
- `snapshot-goose --out FILE` (uses `honk list --json`)
  Run immediately before Step 6's goose-serve restart. Every session with
  `running: true`. No honk/honkd -> empty snapshot with a log line.
- `notify --snapshot FILE [--snapshot FILE] --cut-at EPOCH`
  Run at the end (new Step 7), after both restarts are healthy. For each snapshot
  entry:
  - opencode: re-check the message is still incomplete (a turn that finished in the
    sub-second gap before the restart is skipped); send to its `ses_` id.
  - goose: map goose's native id (`20261124_2`) to pigeon's `gse_` id through pigeon
    `GET /sessions` (`backend_session_id`). A session pigeon does not know (a bare
    `honk chat` session nobody registered) cannot be messaged; logged, skipped --
    its viewer already shows the interruption.
  - Delivery is pigeon `POST /swarm/send` (`from: reset-workspace`,
    `kind: reset.turn_cut`), the same route lgtm-shepherd uses to wake sessions. One
    route for both harnesses; pigeon owns retries, queueing behind a busy turn and
    goose delivery through honkd.
  - Cap 30 notices per run (most recent first); the rest are logged.
  - Sessions whose owner already retries a cut run are left to it, because a
    notice would start a second run of the same work: stall-watch coordinators
    (cwd under `stall-watch/coord-sessions/` or title `stallwatch-*`; stall-watch
    keeps a cancelled run's wake and retries it next tick, and a coordinator's
    reply lands in the human's chat) and lgtm review dispatches (pigeon
    `GET /session-origin` says `lgtm`; lgtm's watchdog re-dispatches a dead
    review). An unreadable origin notifies anyway.
  - The literal `</swarm_message>` in agent-written question text is defanged, or
    pigeon would refuse the whole notice.

The notice says: when and why the turn was cut; that running tool calls may or may
not have completed; the lost question text, if any, and to re-ask it; to check
before redoing anything with side effects (push, post, send, merge); to continue
the task; and that reset-workspace is not a session, so no reply is owed to it.

The snapshot files are kept at `$XDG_STATE_HOME/reset-workspace/turn-cut-*.json`
(last run only) for forensics, and the log lines go to the reset's journal.

### Why reset-workspace and not honkd / opencode

- The reset is the one restart whose cause and moment we know, and it is in
  workstation. honkd's "never auto-resend" is a deliberate design decision of the
  goose program; the general answer for every goose-serve restart (upgrade, crash,
  goose-cutover) stays with workstation-6w7i.16. `turn-cut-notice` is reusable by
  goose-cutover (L3a, workstation-6w7i.27.3) if that program wants it.
- No serve, honkd or pigeon change: deploys with the next home-manager switch.

## Not covered

- Standalone `opencode` TUIs (not pool serves): no pool invocation id, not detected.
- A permission prompt pending in goose or opencode: covered by the generic notice
  only (no prompt text).
- An answer the human gave to a question after the restart is still rejected; the
  agent re-asks.
- A reset that dies in the pool health poll after issuing the restart: the turns
  were cut but Step 7 never runs (the pool is down, so nothing could receive the
  messages anyway). The snapshot stays in `$XDG_STATE_HOME/reset-workspace/`.
- A turn whose loop crashed earlier inside a serve that stayed up: it is stamped
  with a live InvocationID, so it is told it was cut at reset time. The prompt to
  continue is still right; only the stated time is wrong.
- Goose entries are not re-checked before sending (honkd has no cheap
  per-session "re-prompted since" signal); a session re-prompted in the ~20 s
  between its restart and Step 7 gets a notice queued behind that turn.
- Non-reset restarts (canary SIGKILL, OOM, deploys): unchanged (6w7i.16 for goose;
  the phantom-busy sweeper + stall-watch for opencode).

## Verification

- `pkgs/turn-cut-notice/test_turn_cut_notice.py`: hermetic unittest (temp sqlite
  fixtures shaped like opencode.db, a fake `honk` on PATH, a loopback fake pigeon),
  wired as `checks.turn-cut-notice`.
- `pkgs/reset-workspace/test-turn-cut.sh` drives the real helpers extracted from the
  built reset-workspace against fake `turn-cut-notice`/`honk`/`systemctl`: every
  failure is non-fatal, arguments are right, and the call sites keep their order
  (snapshot < restart < record; notify after both restarts). Wired as
  `checks.reset-workspace-turn-cut-tests`.
- Live: after the first nightly that deploys it, `journalctl -u
  nightly-restart-background --since 03:00` shows the snapshot counts and
  notices sent; a session busy at 03:00 receives a `reset.turn_cut` message.
