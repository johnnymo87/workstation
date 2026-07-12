# OpenCode session switcher: semantic-state-aware fuzzy navigation

**Date:** 2026-07-12
**Status:** Design — revised after adversarial review; **all open questions
verified against source (2026-07-12)**. Ready for implementation planning.
**Repos touched:** `workstation` (opencode plugin bundle, nvim config), later
`lgtm` (fallback tagging, optional)

> **Revision note (post-review).** The first draft assumed one plugin host per
> serve seeing all sessions, a single shared snapshot file, and a write-side
> location registry. Adversarial review (fable-5, 2026-07-12) showed all three
> were unsound on this fleet. This revision replaces them with: **per-instance
> heartbeated state files** (topology-correct), **DB-as-base-list + state-as-
> overlay** (survives wedged serves), and **read-time nvim-socket discovery**
> (no registry, no nightly staleness). See "Changes from draft 1" at the end.

## Motivation

The current opencode multiplexer is nvim tabs (each running `opencode attach`)
inside tmux windows/sessions, with `tabby.nvim` scraping `b:term_title` for tab
labels (`assets/nvim/lua/user/tabby.lua`). Two pain points:

1. **Navigation at scale.** When busy, a few dozen nvim tabs stack up; the
   horizontal tabline is painful to navigate. A sidebar would be crowded too —
   the real fix at "few dozen" is *fuzzy search*, already wired (`telescope` +
   `fzy_native`, `assets/nvim/lua/user/telescope.lua:37`).
2. **No semantic state.** `tabby.lua` approximates agent state by scraping the
   terminal title, special-casing OpenCode clearing it during compaction.
   Fragile. OpenCode publishes real state on its event bus.

Prompted by evaluating [herdr](https://herdr.dev/). Conclusion: herdr solves the
*generic* version of a problem we've already solved the *opencode-specific* way
we need (Nix, serve pool, swarm, lgtm). We steal the two ideas worth stealing —
**semantic agent state** and **per-agent status breakdown** — and build them
opencode-native, since we have privileged bus access herdr (a generic PTY
wrapper over a pool it doesn't own) cannot have.

## What we are building

A telescope **fuzzy session switcher** that:

- lists opencode sessions with **semantic state** (working / blocked / idle /
  retry / error) and idle-age;
- **jumps** a selection to the right tmux session/window + nvim buffer, or
  **attaches** it fresh if detached;
- searches **titles** (recency-bounded working set) or **contents** (full
  history);
- **groups by project**, **scopes by tmux session**, but never hides a
  **blocked** session;
- later feeds a **statusline** count and a **per-session notifier**.

## Fleet facts this design must respect (verified)

- Cloudbox runs **K=4** serves (`users/dev/serve-pool.nix:36`); devbox K=2,
  crostini K=1, darwin K=2.
- **Serves do NOT share an in-memory event bus** (`pkgs/oc-auto-attach/default.nix:31`);
  a session's turns stream only from the serve running its loop. Sessions can
  **migrate serves** mid-life (serve-lease, `users/dev/home.base.nix:127`).
- The opencode **plugin host is per-`InstanceState`, i.e. one per (serve process
  × directory)** — plugin + bus are instance-scoped
  (`~/projects/opencode/packages/opencode/src/plugin/index.ts:119`,
  `bus/index.ts:65`). A plugin instance sees only its directory's sessions on its
  serve. `ctx.directory` is available to the plugin (`assets/opencode/plugins/self-compact.ts:48`).
- `nvims` keys each nvim `--listen` socket on `$TMUX_PANE` at
  `/tmp/nvim-<pane>.sock` (`pkgs/nvims/test.sh:4`); ~10 are live on cloudbox now.
  Caveat: `$TMUX_PANE` is inherited by nested nvim `:terminal` children
  (`pkgs/nvims/test.sh:6`) — discovery must tolerate that.
- `oc_auto_attach.open()` already stamps `b:oc_session_id` (and dir) on every
  attach buffer (`assets/nvim/lua/user/oc_auto_attach.lua:47`).
- Session transcripts: global SQLite `~/.local/share/opencode/opencode.db`
  (project→session→message→part, content in `part.data`); `oc-search` greps it.

## Non-goals / YAGNI

- block-until-done primitive — dropped.
- cross-host jump — v1 same-host (cloudbox first).
- multi-agent-per-buffer — one attach per buffer.
- mobile switcher — deferred.
- DELETE-ing sessions — unchanged; history stays unbounded.
- a write-side location registry — **rejected** (see §3).
- oc-auto-attach project→directory routing — separable follow-on.

## Architecture

**DB is the source of truth for "what sessions exist"; the state overlay answers
"what are they doing right now"; nvim-socket discovery answers "where are they
open."** Three independent, individually-truthful reads, joined at picker-open.

```
opencode.db  ──base list (recency-bounded)──►┐
                                             ├─ join ─► telescope picker ─► jump/attach
state overlay (per-instance files) ──state──►┤            (+ statusline later)
nvim sockets (/tmp/nvim-*.sock) ──location──►┘
```

No component can wedge the others: a stale/missing overlay entry ⇒ state
`unknown`; a dead socket ⇒ session is simply `detached`; the DB is always
authoritative for existence.

### 1. State overlay — an opencode plugin, per-instance heartbeated files

Extend the existing plugin bundle (`assets/opencode/plugins/`). The `event` hook
is fed by `bus.subscribeAll()` (`plugin/index.ts:247`); our self-compact plugin
already consumes `session.status` idle (`self-compact-impl.ts:203-221`), proving
the pipe.

**Because the host is per-(serve × directory) with no shared bus, there is no
single writer.** Each plugin instance owns **its own file**:

- Path: `~/.local/share/opencode/session-state.d/<serve-id>-<dirhash>.json`
  (unique per writer). Never a shared file (a shared file with atomic whole-file
  writes = deterministic clobber, since each writer holds only a partial view).
- Each file: `{ pid, serve, directory, heartbeat, sessions: { <sid>: { state,
  pendingPermissions:[reqId], pendingQuestions:[qId], lastActivity, updatedAt } } }`.
- **Heartbeat:** the plugin touches `heartbeat` on a timer even with no events.
- **Teardown:** on `InstanceDisposed` (`bus/index.ts:65`) / process-exit
  finalizer, tombstone/remove the file.

**Read-time merge:** union all files; per-sessionID keep newest `updatedAt`
(handles serve-lease migration where two serves briefly hold the same sid);
**discard entries whose `pid` is dead or whose `heartbeat` is older than T** —
those become `unknown`, never their last-claimed state. This is what keeps a
wedged serve (the fleet's documented failure mode; see `monitoring-serve-pool`)
from showing a frozen `working` forever.

**Heartbeat / liveness parameters (decided):** plugin refreshes `heartbeat`
every **15 s**; readers treat an entry as `unknown` if `heartbeat` age > **45 s**
(3×) **or** its `pid` is dead. Dead-PID check is done reader-side (Lua) via
`vim.uv.kill(pid, 0)` (libuv, portable across NixOS/macOS/crostini — avoid
`/proc`, which is Linux-only and darwin is a target). This covers process death
and full event-loop wedge (the canary's failure mode). **Residual limitation:** a
*partial* wedge where the timer still fires but the agent loop is stuck keeps
heartbeating with stale state; secondary signal is a claimed-`working` entry
whose `updatedAt` is implausibly old. Documented, not fully solvable here.

Event → state mapping (names verified in
`~/projects/opencode/packages/opencode/src`):

| bus event | state |
|---|---|
| `session.status` = `busy` (`session/status.ts`, published `prompt.ts`/`run-state.ts:63`) | `working` |
| `session.status` = `idle` (`run-state.ts:61,81`) | `idle` — **also clears blocked** |
| `session.status` = `retry` (`status.ts:12-27`) | `retry` (glyph; folds into working) |
| `permission.asked` / `.replied` (`permission/index.ts:70-78,177-204`) | add/remove from pending-permission **set** → `blocked` while non-empty |
| `question.asked` / `.replied` / `.rejected` (`question/index.ts:90-92`) | add/remove from pending-question **set** → `blocked` while non-empty |
| `session.error` (`session/session.ts:360-368`) | `error` |

Notes: **do not use `message.part.updated`** for working — `session.status`
busy/idle is the clean run-boundary signal, no streaming-vs-one-off ambiguity,
no debounce needed. `permission.asked` fires only *after* auto-approve rules fail
(`permission/index.ts:177-204`), so no blocked-flicker on auto-approved tools.
Abort-while-pending publishes `idle` but never `.replied`, so `idle` must clear
the pending sets or blocked ghosts persist.

**`session.status` payload (verified `session/status.ts:8-31`):** `{ sessionID,
status }` where `status` is a union discriminated on `type` ∈
`busy` | `idle` | `retry`. `retry` carries `{ attempt, message, next, action? }`
(`next` = backoff timing → retry glyph). Crucially, `SessionStatus.set(idle)`
**deletes** the session from opencode's own in-memory map and re-publishes the
deprecated `session.idle` too (`status.ts:80-83`). So **"absent from the status
map" ≡ idle** in opencode's model — our overlay mirrors this: store only
busy/retry, treat missing as idle, and layer permission/question/error sets on
top. This dovetails with "missing overlay entry ⇒ not-working."

### 2. State model — attachment × activity (two axes)

- **Activity** (overlay): `working` / `blocked` / `idle` / `retry` / `error` /
  `unknown`.
- **Attachment** (socket discovery, §3): `attached` / `detached`.

|              | working | blocked | idle |
|--------------|---------|---------|------|
| **attached** | watching it work | needs input, I'm here | paused, window open |
| **detached** | running headless | **blocked, walked away** | done / prune candidate |

`detached + blocked` is the single most important cell — a swarm worker needing
input while I'm elsewhere. The scope rules (§5) must never hide it.
"Open vs closed" = the attachment axis: live buffer = open; `:bdelete` = closed.
The server session is never touched.

**Subagents:** Task subagents are real sessions with `parentID`
(`session/session.ts:215,543`) emitting their own status/permission events.
**Roll child state up into the parent row and filter children from the list** —
so a subagent's blocking permission surfaces on its parent, but children don't
flood the picker. **`parentID` isn't on the `session.status` event, but it IS a
first-class DB column `parent_id`** (`session/session.ts:80,119`; also
`Session.children()` at `:476`), so the picker's base-list query already selects
it for free — no extra API call. **Rollup rule:** base list = roots (`parent_id
IS NULL`); fold each root's descendants' worst state into a *secondary* glyph on
the root (a child-blocked shows as "child needs input", NOT masqueraded as the
root's own blocked); a root pierces scope as `blocked` if it or any descendant is
blocked.

### 3. Location — read-time nvim-socket discovery (no registry)

A write-side registry fails open on every ungraceful nvim death, and the nightly
reset kills all nvims (`resetting-workspace`) — so a registry would be 100% stale
every morning. Instead, **discover at picker-open**:

1. glob `/tmp/nvim-*.sock`;
2. fire one `nvim --server <sock> --remote-expr` per socket **in parallel, with
   `</dev/null`** (the tty-probe corruption gotcha, `oc-auto-attach/default.nix:470-475`),
   returning `[{ oc_session_id, buffer, tabpage }]` from that nvim's buffers;
3. derive tmux location from the socket's pane id:
   `tmux display -p -t %<pane> '#{session_name} #{window_name}'`.

Dead sockets fail the RPC and are skipped ⇒ **staleness is structurally
impossible**, attachment is always truthful, and the reset "already-closed" bug
is fixed more authoritatively than a registry (which would itself need
reconciling). ~tens of ms across ~10 sockets. Deletes draft open questions #4/#5.

**No dedup needed (verified).** `nvims` already prevents a nested nvim (an
`nvim` run inside another nvim's `:terminal`, which inherits `$TMUX_PANE`) from
claiming the pane socket — it defers to nvim's default server
(`nvim_listen_plan` → `DEFAULT`, fix `workstation-8iqt`,
`pkgs/nvims/test.sh:36-41,58-62`). So `/tmp/nvim-<pane>.sock` is **one per pane,
top-level nvim only** — exactly the nvims that host attach buffers. Discovery
just globs, RPCs each, and skips failures. Nightly reset `pkill -9`s nvims,
which can leave **stale socket *files*** behind; those refuse connections and are
naturally treated as dead.

### 4. Jump-or-attach

- **attached** → if the target is in another tmux **session**, `tmux
  switch-client -t <session>` (not just `select-window`); then `select-window`
  and `nvim --server <sock> --remote-expr` (with `</dev/null`) to focus the
  buffer/tabpage from discovery.
- **detached** → attach fresh via the existing `oc_auto_attach` path.
- **directory gone** (lgtm prunes `.worktrees/pr-<N>` after merge) — **resolved,
  simpler than feared.** `attach.ts:58-67` does `process.chdir(--dir)` and, on
  failure, **catches and passes the dir string through** ("If the directory
  doesn't exist locally (remote attach), pass it through"). Attach does *not*
  crash on a deleted dir, and because the passed-through string equals the
  session's stored directory, the TUI event-filter is *satisfied* (no freeze —
  the freeze only happens when `--dir` is absent and defaults to `/home/dev`).
  The only real blockers are on *our* side: `oc_auto_attach.lua:35`'s
  `isdirectory==0` reject, and `jobstart`'s `cwd = dir`. **Fix:** for
  picker-resume, relax the guard and spawn attach with process **`cwd = $HOME`**
  (or collapsed project root) while still passing **`--dir <original stored dir
  string>`**. One live smoke-test recommended to confirm `validateSession` + TUI
  end-to-end. This is the flagship content-mode "find that old review" flow.

## Search modes

Two modes mirroring `<leader>ff` / `<leader>fg`:

| | **Title** (default) | **Content** (toggle) |
|---|---|---|
| Corpus | recency-bounded working set (DB) | all sessions (`opencode.db` `part.data`) |
| Speed | instant | `instr()` scan (as `oc-search`) |
| State glyph | yes | yes (overlay join) |

Content mode reuses the `oc-search` corpus and `--types`/`--all` scope; a hit →
sessionID → the same jump-or-attach (incl. directory-gone fallback). Never blend
the two into one ranked list.

**DB access (verified):** there is **no `sqlite3` on PATH**; `oc-search` opens the
DB via a **Nix-store sqlite3 binary** with `file:$DB?mode=ro`
(`~/.local/bin/oc-search:105`). The picker's DB helper must likewise depend on
`pkgs.sqlite` and open read-only, adding `PRAGMA busy_timeout` (4 serves write
concurrently; `mode=ro` + WAL makes concurrent reads safe — `oc-search` proves
it). **The DB is ~13 GB**, so the recency-bounded base-list query must be
indexed/`LIMIT`ed (`ORDER BY time_updated DESC LIMIT n`), never a scan.

## Scope & grouping

- **Scope = tmux session (dynamic).** Sessions carry a **sticky tag** (`space` =
  last-known tmux session name; `project` = last-known tmux window name). Default
  filter = `space == current tmux session` (usually `main`) **∪ untagged** —
  because headless-launched sessions (swarm workers, morning agent) have no tmux
  history and must not vanish. **A `blocked`/`error` session always shows
  regardless of scope** (state pierces scope).
- **Grouping = tmux window = project.** Group by `project`.

**Sticky tags are a named, nvim-side/picker-owned store** (`session-tags.json`),
NOT plugin fields (the plugin has no tmux knowledge). Updated whenever discovery
sees an attached session; `directory`-based fallback classification otherwise.

### lgtm boundary

lgtm routes its reviews to a dedicated `lgtm` tmux session
(`docs/plans/2026-06-04-lgtm-dedicated-tmux-session-design.md`), so they get
`space = lgtm` and fall outside the default scope. Durable fallback for
never-attached/detached lgtm sessions: `session.directory` matching
`**/.worktrees/pr-<N>` (`lgtm/src/worktree.ts:~114`). Facets: default (`main` ∪
untagged, + always-blocked), `lgtm only` (serves the existing
`following-up-on-a-review` skill), `all`, plus `blocked only` and
`attached/detached/all`.

## Display (telescope, flat + fuzzy)

```
[herdr]  ● llm-proxy · blocked
[herdr]  ⟳ herdr     · working
[qmp]    · qmp       · idle 2h
```

Entries prefixed `[project]`, sorted clustered by project → state priority
(`blocked`/`error` → `retry` → `working` → `idle`) → ascending idle-age. Fuzzy
matches over `project + title`. Idle-age is a dim prune-radar suffix.
`lastActivity` falls back to the DB session `time_updated` when the overlay is
missing (plugin-restart amnesia).

## Preview pane

- **Header (always):** `title · state glyph · idle-age · space · project · dir`.
- **Title-mode body:** transcript **tail** from `opencode.db` (last user prompt +
  last assistant text) — one path for attached and detached; readable, not raw
  JSON.
- **Content-mode body:** matching part + surrounding context.
- **Enhancement (not v1):** live terminal-buffer screen for attached sessions.

## Statusline

Ambient counts (`⧗2 ●1`). **Deferred until overlay staleness handling exists** —
a statusline confidently showing `●1` from a wedged serve is worse than none.
When built, cache on the existing 3s timer (`tabby.lua:144-148`), don't parse
JSON per render.

## Rollout (phased, cloudbox first, same-host)

- **Phase 1 (MVP, reduced scope):**
  (a) per-instance heartbeated state files + read-time merge (§1);
  (b) read-time nvim-socket discovery (§3);
  (c) telescope **title** picker: DB base list + state overlay + discovery,
  grouping/scope with blocked-pierces-scope, jump-or-attach incl. directory-gone
  fallback.
  Cut from Phase 1: statusline, registry (deleted entirely), sticky-space beyond
  the trivial tags file. Every component is independently truthful.
- **Phase 2:** content-search mode.
- **Phase 3:** Telegram forum-topic notifier (tails `session-state` transitions;
  fires on `working→blocked`), replacing the single-channel firehose.
- **Later / documented:** live-buffer preview, statusline (post-staleness),
  mobile, cross-host, socket/HTTP overlay push, oc-auto-attach project routing.

## Considered & rejected

- **Single shared snapshot file** — deterministic clobber under N per-instance
  writers with partial views (§1).
- **Write-side location registry** — 100% stale every night; read-time discovery
  is strictly more truthful (§3).
- **`message.part.updated` for working** — needless flicker/debounce;
  `session.status` busy/idle is the clean signal (§1).
- **Poll `GET /session/status` only, skip the plugin** — the endpoint is
  instance-scoped by directory (`self-compact-impl.ts:412-441` polls it), so
  enumerating all state = (serves × directories) requests and risks lazily
  instantiating heavyweight instances on serves that don't own a session.
  Recorded to justify the plugin approach.

## Verification findings (all 5 draft-2 open questions resolved, 2026-07-12)

All resolved against `~/projects/opencode` source and the live cloudbox system.

1. **`--dir <deleted>` — RESOLVED (source), 1 smoke-test left.** `attach.ts:58-67`
   catches `chdir` failure and passes the dir string through; no crash, no freeze
   (string matches the session's stored dir, satisfying the event filter). Fix is
   ours: relax `oc_auto_attach.lua:35` and spawn with `cwd=$HOME` + `--dir
   <stored dir>`. One live end-to-end smoke-test recommended. See §4.
2. **Subagent rollup — RESOLVED (source).** `parent_id` is a DB column
   (`session/session.ts:80,119`); the base-list query gets it free. Roots =
   `parent_id IS NULL`; descendants' worst state folds into a secondary glyph;
   child-blocked pierces scope on the root. See §2.
3. **Heartbeat/liveness — DECIDED.** 15 s heartbeat, 45 s staleness threshold,
   `vim.uv.kill(pid,0)` for dead-PID (portable). Partial-wedge residual noted.
   See §1.
4. **`session.status` payload — RESOLVED (source).** Union on `type` ∈
   busy/idle/retry; `retry` carries `attempt/message/next/action?`; `idle`
   deletes from opencode's map ⇒ absent ≡ idle. See §1.
5. **Nested `$TMUX_PANE` sockets — RESOLVED (source).** `nvims` already prevents
   nested nvims from claiming a pane socket (`workstation-8iqt`), so sockets are
   one-per-pane top-level only; no dedup needed. See §3.

Remaining before "done" (not blockers to planning):
- the single live `--dir <deleted>` attach smoke-test (finding #1);
- exact interpretation of `retry.next` (epoch vs delay) — cosmetic, glyph only.

## Related follow-ons (separable)

- oc-auto-attach `project → directories` routing (true multi-codebase grouping).
- Consuming discovery in `pkgs/reset-workspace` to kill the residual
  "already-closed" inference.

## Changes from draft 1 (for the record)

1. Single snapshot file → **per-instance heartbeated files + read-time merge**
   (topology is per-(serve×directory), K=4, no shared bus).
2. Snapshot-as-primary-list → **DB-as-base-list + overlay** (survives wedged
   serves; staleness ⇒ unknown).
3. Write-side registry → **read-time nvim-socket discovery** (no nightly
   staleness; deletes 2 open questions).
4. State: dropped `message.part.updated`; added `question.*`, `retry`,
   `session.error`; `idle` clears blocked; pending **sets** not booleans.
5. Added **subagent roll-up + child filtering**.
6. Default scope now `current-space ∪ untagged`, and **blocked/error pierces
   scope** (was: could hide a detached blocked worker).
7. `space`/`project` moved out of plugin fields into a named nvim-side tags
   store.
8. Jump: `switch-client` for cross-session; **directory-gone fallback**;
   `</dev/null`.
9. Statusline deferred until staleness handling lands.
