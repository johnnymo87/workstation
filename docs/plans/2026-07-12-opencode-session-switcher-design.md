# OpenCode session switcher: semantic-state-aware fuzzy navigation

**Date:** 2026-07-12
**Status:** Design — revised after adversarial review; open questions verified
against source (2026-07-12); **reconciled with the front-door topology
(2026-07-30)**. Ready for implementation planning.

> **Prior-art consult (2026-07-30, ChatGPT deep research; full answer archived at
> `/tmp/research-agent-session-switcher-answer.md`).** Checked whether this
> already exists. **The category now does** — an agent-session-level tool class
> shipped while we designed (ccmux, Claude Code Agent View, Agent Deck, Agent of
> Empires, workmux, tmux-agent-sidebar, agterm). **Our identity model does not.**
> Nearly all of them define an agent session as *one managed PTY/pane/process*;
> we define it as *one durable logical conversation with 0..N attachments that
> migrates between headless servers*. Nothing released combines logical sessions
> independent of PTYs + authoritative permission/question state +
> detached-but-actionable + jump-or-attach + global transcript search. Verdict:
> **own the registry, steal the peripheral work.** Consequences folded in below:
> four real bugs (§1 snapshot, §1 ordering, §4 TOCTOU, §4 client identity), a new
> `attention` axis (§2), and the join moving out of Lua (§Architecture). See
> "Prior art" at the end for the taxonomy and what to steal from whom.
>
> **Front-door reconciliation (2026-07-30).** Between this design and its
> implementation, the serve pool was put behind a single front door
> (`docs/plans/2026-07-12-serve-reverse-proxy-{design,plan}.md`,
> `2026-07-26-frontdoor-spine.md`). Net effect on this design: **small**, because
> it was already port-agnostic. The switcher's three reads (DB, overlay file,
> nvim sockets) touch no serve endpoint at all. One coupling changed —
> attach/resume now goes to the **door** — and one new *constraint* applies (the
> opacity grep-guard). Both folded in below.
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

### Front-door facts (added 2026-07-30)

- **The door is the only address.** `FRONTDOOR_URL`, default
  `http://127.0.0.1:4700` (`pkgs/oc-auto-attach/default.nix:31`,
  `users/dev/home.base.nix:1176`). All 20/20 live attach TUIs run against `:4700`.
  **Never write `:4096` in a shipped consumer.**
- **Opacity is mechanically enforced.** `users/dev/test-frontdoor-opacity.sh`
  scans shipped consumers — including **`pkgs/*/default.nix`**, which will cover
  this design's `oc-session-list` — and fails *closed* on any serve-addressing
  site (`SITE_RE` matches literal `(127.0.0.1|localhost):409[0-9]`, `${OPENCODE_URL}/`,
  `attach …$OPENCODE_URL`, and endpoint env exports) unless an inline
  `frontdoor-exempt(<ROW>)` marker cites a real row of
  `docs/plans/2026-07-26-phase9-consumer-disposition.md`.
- **Pigeon is token-gated** (Stage 1, 2026-07-27): anonymous `GET :4731/route` →
  401. This design must not call `/route`; it doesn't need to.
- **Serve token (Stage 2) is OPEN** (`workstation-km5f`): serves will require
  `Authorization: Bearer` on every route except `/global/health`.
- **Pre-placement is a real step** (`C6`): `oc-auto-attach` resolves
  `/route`→`/place` *before* attaching to the door, so the door's first
  `/event?session_ids=` lands on the owning serve instead of drift-reconnecting.
  Consumers that resume a session must not skip it (see §4).

**Design invariant this buys us: the switcher is HTTP-free except for attach.**
State comes from the plugin's own file, location from nvim sockets, metadata from
the DB — no serve calls, no `/route`, no `GET /session/<id>`. So Stage 2's serve
token, and any future re-shaping of the pool, **cannot break it**. Keep it that
way: if a future need for session metadata appears, take it from the DB, not HTTP.

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

**The join does NOT live in Lua (revised 2026-07-30).** The consult's strongest
architectural note: *the picker should be a frontend; it must not own session
identity, state reduction, or reconciliation* — otherwise Neovim becomes part of
the correctness boundary. It recommended a socket **daemon**; we deliberately
reject a daemon (the fleet's wedged-serve history is exactly why this design has
none). **Synthesis:** keep the no-daemon property, but move the merge/join out of
the Lua picker and into **`oc-session-list`** (§Task 6), which already shells
read-only. One tested join implementation, callable by *two* thin frontends:

```
oc-session-list --with-state   ← does base-list + overlay merge + discovery join
        ├── telescope picker (nvim-native: focuses a known buffer directly)
        └── fzf/tmux client    (recovery + use outside nvim)
```

The fzf client is not Phase 1 scope, but the seam must exist from the start or it
never will.

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

**BUG FIX 1 — event-only reconstruction is broken at startup (2026-07-30).**
A plugin instance that starts *while a permission is already pending* never sees
the `asked` event, so that session reports `idle` **forever** — precisely when it
is blocked on us. (ccmux documents this exact blind spot for OpenCode.) The
correct pattern is **snapshot-then-subscribe**: on plugin init, take a
**snapshot of currently-pending permissions/questions**, seed the state map from
it, and only then apply events. Verify what's readable in-process (the
`Permission`/`Question` InstanceState maps are the authority); if a snapshot is
genuinely unavailable, that is a Phase-1 blocker to solve, not a nice-to-have —
without it every serve restart silently loses blocked-ness. Re-snapshot after any
gap/reconnect.

**BUG FIX 2 — wall-clock newest-wins is wrong across migration (2026-07-30).**
Serve-lease can move a session between serves, so two files may hold the same
sid. Ordering by `updatedAt` (wall clock) lets a **delayed `idle` from the old
owner overwrite `blocked` from the new owner** — losing exactly the state we care
most about. The original fix — order by `(owning-epoch, revision)` where epoch is
the writer's process start time — was itself wrong and is **superseded**; see
finding #8. Boot order is not ownership order, and `revision` is per-writer so it
does not compare across processes at all.

**RESOLVED — ownership is answered by a read-time join, not by an epoch
(2026-07-31, finding #8).** Per-sessionID winner selection is:

1. **Live overlay whose `serveId` == pigeon's `session_assignment.desired_serve_id`
   wins outright.** The router names the current owner directly; nothing in the
   overlay needs to encode a generation.
2. Else **freshest `lastActivity` among live overlays** (wall-clock, one machine,
   one clock — comparable across processes in a way `revision` is not).
3. Else `unknown: true` from the freshest dead entry.

`revision` stays **intra-file only** (change detection, write suppression) and must
never be compared across files.

**Read-time merge:** union all files; per-sessionID keep the winner by the rule
above; **entries whose `pid` is dead or whose `heartbeat` is older than T** are
emitted as `unknown` with pending sets cleared — never their last-claimed state,
and never dropped. This is what keeps a wedged serve (the fleet's documented
failure mode; see `monitoring-serve-pool`) from showing a frozen `working`
forever.

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
- **Attention** (added 2026-07-30): `seen` / `unseen`.

**Why a third axis.** `idle` conflates four different things: finished
successfully, waiting for my next prompt, process vanished, and *done work I
haven't reviewed yet*. Keeping "have I looked at this since it last changed"
separate is what stops **completed-but-unreviewed** work from disappearing into a
pile of ordinary idle sessions — a better answer to the original "how do I know
what I'm still working on vs. done" question than overloading attachment. Display
model: `activity: idle · outcome: completed · attention: unseen`. Mark `seen`
when the session is focused via the picker (or is the current buffer). This is
cheap: one timestamp per session in the tags store, compared against
`lastActivity`.

**`blocked` is authoritative from pending-interaction records, not from
`session.status`.** Precedence: unresolved permission/question → `blocked`; else
error → `error`; else retry → `retry`; else busy → `working`; else `idle`.

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

**Attachment must join `oc_auto_attach.status(sid)` (added 2026-07-30).**
`oc_auto_attach.lua` now tracks per-session attach health — `running` / `failed`
/ `exited` / `unknown` (`:25-33`, `:56`, `:75-102`) — and renames a dead buffer
`[FAILED] <sid>` while **leaving `b:oc_session_id` set** (`:62`). So a buffer
alone is NOT proof of a live attach: a crashed attach would otherwise be reported
`attached`, and the picker would "jump" you to a dead terminal. `rpc.snapshot()`
runs inside the target nvim, so it must return
`require("user.oc_auto_attach").status(sid)` alongside each hit; treat
`failed`/`exited` as **detached** (optionally surfaced as an `attach-failed`
glyph, since it's actionable: resume will fix it).

### 4. Jump-or-attach

**BUG FIX 3 — time-of-check/time-of-use (2026-07-30).** A row can be correct when
rendered and stale when selected (pane closed, buffer replaced, window renamed,
session migrated, state flipped). **On accept, re-resolve the session UUID
against live state** (re-run discovery for that one sid + re-read the overlay);
never act on the target embedded in the displayed row.

**BUG FIX 4 — focusing the wrong tmux client (2026-07-30).** With several
attached clients, a bare `switch-client` can move an unrelated client or leave
the invoking terminal unchanged. **Capture the invoking client** (`tmux display
-p '#{client_name}'` at picker-open) and target it explicitly (`switch-client -c
<client> -t %<pane>`). The operation is *"focus attachment A for client C"*, not
*"switch to session S"*. Distinguish the cases: buffer in the current client /
pane attached in another client / detached pane / no attachment — they may
warrant different behavior.

- **attached** → re-resolve (fix 3), then, targeting the invoking client (fix 4):
  if the target is in another tmux **session**, `tmux switch-client -c <client>
  -t %<pane>`; then `nvim --server <sock> --remote-expr` (with `</dev/null`) to
  focus the buffer/tabpage. If the session's buffer is in **this** nvim already,
  just focus it — no tmux round-trip.
- **detached** → **shell out to the packaged `oc-auto-attach` binary**, do NOT
  call the Lua `M.open()` directly. Rationale (front-door, 2026-07-30): the shell
  wrapper owns the health probe, the `/route`→`/place` **pre-placement** (`C6`),
  the `$FRONTDOOR_URL` attach target, and the settle logic. Calling the Lua entry
  point directly would bypass pre-placement and invite a door drift-reconnect,
  and would re-implement the door URL in a second place. Keeping the switcher
  *upstream* of oc-auto-attach also keeps it out of the opacity guard's scope
  entirely.
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

1. **`--dir <deleted>` — SMOKE-TESTED 2026-07-30: attach OK, *turns hang*.**
   Source reading was half right. `attach.ts:58-67` does catch the `chdir` failure
   and pass the dir string through: **the TUI opens, no crash, and the event
   filter is satisfied** (the stored-dir string matches, so history renders and
   server-side changes stream). But a session whose directory is gone **cannot
   complete a turn.**

   Controlled A/B on cloudbox through the front door (`:4700`), same model
   (Claude Opus 5), same prompt, same attach path, same timing — only the
   directory differs:

   | fixture | attach | turn |
   |---|---|---|
   | dir deleted (`ses_049cc1d7…`) | TUI opens, streams | `completed=false`, `parts=0`, `error=null` after **4 min** |
   | dir exists (`ses_049c8e60…`, control) | TUI opens, streams | `completed=true`, `parts=3`, text `OK` in **<40 s** |

   The failure mode is the dangerous one: **it hangs silently.** No error on the
   assistant message, nothing rendered in the TUI, no timeout. Two consequences:

   - **Task 10's attach branch for directory-gone sessions becomes preview-only /
     read-only.** Offer "open read-only" + an explicit "directory is gone" notice;
     do not present it as a resumable session. Re-rooting (attach at `$HOME` or a
     replacement dir) is the only path back to a working session — a follow-on.
   - **Our state model must not trust `working` from such a session.** A prompted
     directory-gone session emits busy and then never idles, so it would render
     `working` forever — an immortal phantom row. Treat "dir missing" as a
     first-class row condition that *overrides* the activity glyph rather than
     something the reducer can infer from events. (Cheap: the join already stats
     the dir for display; reuse that.)
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
- exact interpretation of `retry.next` (epoch vs delay) — cosmetic, glyph only.

### 6. BUG FIX 1's snapshot source — RESOLVED 2026-07-30 (was the Phase-1 blocker)

The startup pending-snapshot has a source, and it is **not** the plugin SDK.

- The plugin SDK exposes only `postSessionIdPermissionsPermissionId` (respond).
  There is no list/get — verified by grepping the installed
  `@opencode-ai/sdk/dist/gen`. ccmux hit exactly this and documented the
  resulting hole (`docs/agent-adapters.md:116`: a pending permission is invisible
  if ccmux starts while OpenCode is already waiting).
- The **server HTTP API has what the SDK lacks.** From the live OpenAPI doc:
  - `GET /api/permission/request` → `v2.permission.request.list`
  - `GET /api/question/request` → `v2.question.request.list`
  - plus per-session `GET /api/session/{sessionID}/permission` and `…/question`.

  ~~The two `…/request` endpoints are **global**, so one call seeds every pending
  prompt across the fleet. Verified live: both return `200` with
  `{"location":…,"data":[]}`.~~

  **CORRECTED 2026-07-30 (adversarial review). The above was wrong, and the
  "verification" was theatre: an empty `data: []` cannot distinguish a global list
  from a scoped one. It was cited as if it could.**

  These endpoints are **directory/instance-scoped**, not global. Settled by
  probing with the parameter rather than by observing an empty result:

  ```
  GET /api/permission/request                                    → location.directory = /home/dev  (serve default)
  GET /api/permission/request?location[directory]=/home/dev/projects/workstation
                                                                 → location.directory = /home/dev/projects/workstation
  ```

  The scope **moves with the parameter**. Confirmed in source: an instance-context
  middleware resolves `store.load({ directory })` and `Permission.list()` returns
  that instance's in-memory `pending`. `v2.permission.request.list` declares a
  `location` query param in the live OpenAPI.

  **Do not "iterate roots" to recover a fleet view.** That is the same hazard this
  design already rejected for `/session/status` polling: `InstanceStore.load`
  *creates* an instance on miss, so iterating roots through the door lazily
  instantiates heavyweight instances fleet-wide. Worse, the door routes each GET to
  **one** serve while pending state lives in per-serve memory — so even a correct
  `location` can land on the wrong serve.
- Not SQLite: the `permission` table is a project-level ACL (`action`/`resource`),
  not pending prompts, and is empty; the `event` table is empty too. Pending
  prompt state is in-memory in the serve process, exposed only over HTTP.

**Consequence for Task 3 (revised): each plugin instance seeds ITSELF.** The
correct scope was never fleet-global — it is exactly the scope the plugin's own
overlay file already owns: its own serve, its own `ctx.directory`, queried
in-process via `ctx.serverUrl`. This is *cheaper* than the original plan: no door
round-trip, no opacity-guard exposure, no wrong-serve routing, no root iteration.

**Also reconsider what the seed is FOR.** The startup-blindness premise is weaker
than assumed for an *in-process* observer. The plugin loads at instance creation;
permissions are created by turns, i.e. after init. And a serve restart *destroys*
pending state (it is in-memory), so a post-restart "blocked" would be a lie —
there is no dialog left to answer. ccmux's documented blind spot is an **external**
observer starting late; our observer shares the state's lifetime.

So the seed's real value is **drift repair, not startup**. Prefer a periodic
in-process reconcile (~60 s, fire-and-forget) over a one-shot boot seed. This also
defuses the seed-vs-stream race below.

**Race hazard if the seed is kept as-is (built code, `session-state-impl.ts`).**
`seedFromSnapshot` is replace-authoritative for named sessions. Snapshot taken at
T1, `permission.asked p2` applied at T2, response lands at T3 ⇒ p2 is **dropped**;
symmetrically a permission replied between T1 and T3 is **resurrected** and pins
the row to `blocked` until the next idle. The earlier note that "the reducer
already merges by `(epoch, revision)`" was hand-waving — the seed does not
participate in that ordering at all, and stomps `revision` to 0. Fix: accept a
snapshot only for sessions with **no event-derived entry yet**, or make it
union-only. Tracked as a Task 3 prerequisite.

### 7. Version skew in every "verified in source" claim (2026-07-30)

**All source citations in this document were verified against `~/projects/opencode`
at 1.15.10. The deployed fleet is 1.17.13.6 and auto-updates every 8 hours.** Two
minors of drift, and this exact trap has already burned us once: the sq1v
investigation re-verified against the deployed binary and found the stale-tree
conclusion was *wrong on deployed*.

This includes Task 1's load-bearing payload asymmetry (`asked→id`,
`replied→requestID`), which is marked "do not re-spike". Treat it as
version-stamped, not eternal.

**Required before Task 3 wires the real event bus:** capture one real
permission ask/reply and one busy/idle cycle **from the deployed fleet** and commit
them as fixtures. The plan's own risk section already demands fixture tests from
captured event sequences; Task 1 shipped with hand-written fixtures only. Any
future "verified" claim in this doc must name the version it was verified against.

**CLEARED 2026-07-31 (commit `e91548f`).** Fixtures captured from deployed
1.17.13 and committed at `assets/opencode/plugins/test/fixtures/deployed-events.json`.
**Every Task 1 assumption survived**, verified two independent ways:

*Schema, read out of the shipped bundle* (stronger than a consumer read — see the
false alarm below):

| event | schema on deployed |
|---|---|
| `permission.asked` | `PermissionRequest.fields` → `id` **required** |
| `permission.replied` | `{sessionID, requestID, reply}` — no `id` |
| `question.asked` | `QuestionRequest.fields` → `id` **required** |
| `question.replied` | `{sessionID, requestID, answers}` |
| `question.rejected` | `{sessionID, requestID}` |
| `session.status` | `{sessionID, status:{type}}`, union exactly `{busy, idle, retry}` |

The status union was confirmed **at the emitter** (`SessionProcessor` only ever
calls `set({type:"busy"|"idle"|"retry"})`), not inferred from a consumer's
branches. `permission.rejected` does **not** exist; the reducer correctly omits it.

*Live capture* through the front-door event stream: a real session driven to
busy/idle, then a real question ask/reply round trip. The captured pair is the
whole hazard in one observation — same prompt, two field names:

```
question.asked   {"id":        "que_fb8a13dad001MOPaPSthQ456WM", ...}
question.replied {"requestID": "que_fb8a13dad001MOPaPSthQ456WM", ...}
```

**Near-miss worth recording.** Reading the TUI's `session.deleted` branch showed
`properties.info.id`, which looked like a fourth key-mismatch against the plan's
`properties.sessionID`. It was a false alarm: the *schema* is
`{sessionID, info}` and the single publish site sets both — the TUI just happens
to read `info.id`. **A consumer's choice of field is not evidence about the
payload's shape.** Check the schema and the publish site.

**Deployed also emits a bare `session.idle` alongside `session.status{idle}`.**
The reducer handles only the latter and no-ops on the former; now asserted.

**Seeding: the door-side snapshot is unusable — positive control, 2026-07-31.**
With a question provably pending, the *same* query against the *same* directory:

| endpoint | result |
|---|---|
| `GET :4700/question?directory=…` (front door) | `[]` |
| `GET :4097/question?directory=…` (owning serve) | the pending question |

An empty list alone would have proved nothing (the trap this project already fell
into once). Paired with the owning-serve control it is decisive: seed **in-process
from this serve**, never through the door. Related: the door **refuses mutations**
outright (`forbidden_through_frontdoor` — "mutates per-process/single-process
state"), so replying/aborting requires the owning serve, resolved via
`session_assignment.desired_serve_id` → `serve_instance.endpoint`.

**Watch-item:** the deployed revision exposes `POST /api/session/{id}/permission`
(v2 create). Unused today, but if anything ever creates permissions out-of-band,
"pending ⇒ busy" breaks and *idle-clears-pending starts eating real blocks*.

**Landmine inherited from ccmux (`plugin.js:279-286`):** do **not** `await` the
seed during plugin init. Those handlers are served in-process by a runtime whose
state isn't ready until plugin init returns; awaiting deadlocks opencode boot.
Fire-and-forget, and let the reducer accept a late snapshot — but note the seed
does **not** participate in any cross-file ordering (that was the hand-waving
corrected above); the late-snapshot fix is the "no event-derived entry yet" rule.

### 8. Ownership resolved: pigeon's `desired_serve_id`, not an epoch (2026-07-31)

Verified against the deployed fleet and the pigeon source, file:line.

**A real fencing token exists, but not in opencode.** opencode exposes nothing
usable: the plugin context is exactly `{client, project, worktree, directory,
experimental_workspace, serverUrl, $}` (`packages/opencode/src/plugin/index.ts:149-164`),
the event hook **strips** the durable `seq` (same file, :255), and there is no
server-identity endpoint (`/global/health` returns only `{healthy, version}`).

Routing lives in **pigeon**, in its own sqlite DB at `process.env.OPENCODE_ROUTING_DB`
(verified live):

- `session_assignment(session_id PK, directory_key, desired_serve_id,
  owner_generation, state, last_active_at, updated_at)` —
  `pigeon/packages/daemon/src/routing/route-schema.ts:17-25`.
- `owner_generation` bumps **only on a genuine move** (`router.ts:197-202`);
  pigeon's own README:37 states "monotonic so a stale-generation zombie can never
  reacquire, even after expiry."
- Placement is **rendezvous/HRW hash of the session id** (`rendezvous.ts:4-7`),
  *not* of the directory — `directory_key` is stored but never used in the
  decision. Perturbed by health filtering, a bounded-load skip (≥25 active
  assignments, `config.ts:91`), and a 30 s sticky pin, so migration is real.
- Live: **150 of 548** assignment rows have `owner_generation > 1` — ~27% of
  sessions have migrated at least once. The conflict machinery earns its keep.

**`owner_generation` is not load-bearing for us.** It is a fencing token for
*writers acquiring leases*; the reader acquires nothing. The reader's question is
"who owns this now", and `desired_serve_id` **is** that answer, written in the
same row and the same transaction as the generation bump. Overlays cannot carry a
generation anyway (the plugin has no access to it), so comparing generations
reader-side would compare nothing.

**The coverage gap: the causal argument was right, the join key was wrong
(corrected 2026-07-31 by adversarial review).** The tempting argument runs: a
session appears in two overlays *iff* it was hosted by two serves *iff* something
moved it *iff* pigeon placed it — which is exactly what creates the row, so
no-row ⇒ never migrated ⇒ nothing to arbitrate. Every link in that chain holds.
**It still gives the wrong answer, because the row pigeon creates is not keyed by
the session being arbitrated.** Placement uses `routingSid` = **the ROOT of the
session tree** (`opencode-frontdoor/src/resolve.ts:17-19`, `place.ts:251`), so
`session_assignment.session_id` only ever holds root ids — while overlay maps are
keyed by the event's `sessionID`, which includes children (a subagent's
`permission.asked` carries the *child* sid).

Measured on the live pair of databases: **8,634 sessions, 4,600 of them children;
548 assignment rows; exactly 2 children have a row.** So ~53% of all sessions
would have fallen through to bare wall-clock ordering — the very rule BUG FIX 2
declared broken. Not a phantom, and not an edge.

**Fix: resolve to the root before joining.** The reader builds
`owners[sid] = desired_serve_id_of(rootOf(sid))`, walking `session.parent_id` in
opencode's own DB — which the reader already opens for the base list, so the
linkage is free. `mergeOverlays` stays pure and simply requires `owners` to be
keyed by *every* sid it should arbitrate.

Lesson worth keeping: this is the second time in this project that a clean causal
chain passed review while a **key mismatch** hid inside it. Check what the
identifier *is*, not just that the causality holds.

**Reading pigeon's sqlite is acceptable here** (same machine, same user, both
repos ours) with guardrails: open `mode=ro` — **never `immutable=1`**, the DB is
WAL and live-written, and immutable would yield silently stale/corrupt reads —
`busy_timeout` ~100 ms, and catch *everything* (missing file, lock, `no such
table/column`) by proceeding as if zero assignment rows. One `SELECT` of the whole
548-row table per render, not N× `GET /route` (500 sequential HTTP calls on an
interactive picker, and it dies when pigeon is down; the sqlite read survives a
stopped pigeon). If the schema churns twice, escalate to a bulk `GET /assignments`
endpoint. Insurance: a schema-contract test **in pigeon's repo** asserting
`session_assignment` still has `session_id` / `desired_serve_id`, commented
"externally consumed by oc-session-list".

**Consequences for the build:** overlay entries carry `serveId`
(`process.env.OPENCODE_SERVE_ID`, verified live e.g. `serve-2`) instead of a boot
epoch; cross-file ordering uses `lastActivity`; `revision` is demoted to
intra-file use; and the writer should **evict sessions idle > 30–60 min** from its
overlay (absence ≡ idle, since the DB base-list already carries every session),
which shrinks the stale-zombie surface structurally rather than by guesswork.

**Absence is a positive claim (D1, adversarial review).** Rule 1 must be
*owner-authoritative*: if a **live** owner file **for the session's directory**
exists but does not mention the session, the merge emits **nothing** (absent ≡
idle) rather than falling through to rule 2. Without that, a session that was
blocked when it migrated leaves a stranded entry on the old serve — non-empty
pending set, so idle-eviction deliberately skips it; no further events, so it
never changes; the serve stays up, so the file stays live — and once the true
owner's entry goes plain-idle and is pruned, rule 2 crowns the frozen `blocked`
**permanently**, advertising a block nobody can service. Note one serve writes one
overlay file *per directory*, so the owner file must be matched on
`(serveId, directory)`, not `serveId` alone.

**Degraded-routing window (D3, accepted + documented).** When pigeon is
unreachable the front door forwards to the **anchor** (serve-0) and writes no row
(`resolve.ts:52-60,77-86`, `place.ts:248` → `pigeon-degraded`). The routing DB
stays perfectly readable, so rule 1 keeps confidently preferring the now-stale
`desired_serve_id` over serve-0's live truth for the whole outage — the sqlite
read surviving a stopped pigeon is exactly what makes the reader *wrong* rather
than *degraded*. Bounded (heals on re-place) and display-only. If it bites,
downgrade rule 1 to advisory when the door reports `degraded`.

**Make degradation visible (D5).** The catch-all that turns a failed routing-DB
read into an empty owner map silently reverts the merge to wall-clock-newest-wins
— i.e. the pre-fix behaviour, with no operator signal. `oc-session-list` must
surface a `joinDegraded` flag. Also: overlay JSON needs a **schema version field**;
the reader must validate entry shape before merging, since a version-skewed writer
can emit entries missing `pendingPermissions` and crash the picker.

Residual, accepted: during the window after pigeon flips `desired_serve_id` but
before the new owner's plugin has written an entry, rule 2 shows the old owner's
last-known state — a wrong glyph for seconds, on a display surface. Pid-reuse can
also make a dead pid look live; cosmetic. Statistical note: the "150/548 rows have
`owner_generation` > 1" figure is over *placed roots*, not all sessions — fine as
motivation, not citable as a fleet-wide session rate.

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

## Prior art (consult 2026-07-30) — what exists, what to steal

**Taxonomy.** The useful dividing line is *not* project-vs-session; it is
**carrier-bound vs logical conversation**:

| Category | Primary identity | Examples | Our fit |
|---|---|---|---|
| Project/workspace switchers | directory / worktree / tmux session | tmux-sessionizer, sesh, tmux-sessionx, Zellij session manager | wrong layer |
| PTY-bound agent managers | agent process in a pane/tab | **ccmux**, herdr, Agent Deck, Agent of Empires, tmux-agent-sidebar, agterm | close UI, wrong identity model |
| Logical conversation supervisors | conversation survives terminals/processes | **Claude Code Agent View**; this design | correct layer |

**ccmux** (`github.com/epilande/ccmux`) — closest open-source implementation, and
already consumes real OpenCode events (`session.status` busy/retry/idle,
`permission.asked/replied`). **Decisive mismatch:** its session is
pane/process-backed, and when one OpenCode server hosts several logical sessions
it **folds them into a single row** — which is exactly our K=4-serves-hosting-many
-sessions topology; its own docs note input-injection then becomes ambiguous.
**Steal, don't adopt:** picker/row model, notifications, tmux target resolution,
previews, sidebar. (Gated by the Task 0.5 spike.)

### Task 0.5 spike result (2026-07-30): **KEEP OUR PLAN** — decided, do not re-litigate

Read at `/tmp/opencode/ccmux`. Rule was "≥4 YES *and* Q1+Q2 YES ⇒ extend". Q1 **NO**,
Q2 **PARTIAL** ⇒ keep our plan. Extending ccmux means replacing its identity
spine, not adding an adapter.

| # | Question | Verdict | Evidence |
|---|---|---|---|
| 1 | One server → N independent rows? | **NO** | `derivePaneTrackedSessionId()` keys rows `` `${agentType}_${paneToken}` `` (`src/daemon/sessions.ts:34-38`) into `Map<string,Session>` (`:165`, written `:411`). The N→1 fold is deliberate: `aggregateOpenCodeMarkers` (`adapters/opencode/aggregate.ts:17-56`), wired `plugin-adapter.ts:187-201`; stated as design in `docs/agent-adapters.md:112`. |
| 2 | Row with no TTY at all? | **PARTIAL** | Paneless rows exist only as a bespoke `"background"` mode fed exclusively by Claude's own roster/state files (`types/session.ts:17`, `sessions.ts:423-462`, `sources/claude-background.ts`). For marker-based agents, no pane ⇒ no row: `if (!pane) return null` (`plugin-adapter.ts:203-211`), `daemon/index.ts:750-753`. Docs: "OpenCode launched outside a tmux pane is out of scope" (`agent-adapters.md:113`). |
| 3 | Arbitrary `focus-or-attach(session_id)` on select? | PARTIAL | Hardcoded 2-branch `activateItem()` (`tui/App.tsx:213-231`); seam exists (`AgentDef` already holds a function field, `lib/agents.ts:112`) but no hook. |
| 4 | Attachments as a collection? | **NO** | `tmuxPane: string \| null` — singular (`types/session.ts:128`), ~15 call sites branch on `!session.tmuxPane`. Ownership is inverted: the pane *names* the session. |
| 5 | External transcript-search provider? | PARTIAL | Agent-gated file parser, `if (agentType !== "claude" && !== "codex") return null` (`daemon/transcript-search.ts:207-209`); clean daemon `/search` boundary, but OpenCode gets nothing today. |
| 6 | `question.*` + pending snapshot? | **YES** | Marker shape already there (`plugins/opencode/plugin.js:246-267`); only the state enum needs widening (`daemon/session-markers.ts:21`); `AttentionType` already includes `"question"` (`types/session.ts:69`). |

**The finding that most validates this design:** ccmux carries a
`Session.ambiguousWait` flag (`types/session.ts:192-204`) that **disables its own
headline feature** — notification Approve/Deny — whenever more than one
server-side session is waiting behind one pane, because "a keystroke lands on
whichever dialog the pane currently renders." That is empirical, shipped proof
that pane-identity cannot express our topology. Session-identity makes that whole
bug class structurally impossible. Also note ccmux's plugin already writes **one
marker file per OpenCode session id** (`plugin.js:66-68`) — the per-session data
exists upstream; only ccmux's registry collapses it.

**Techniques to steal** (referenced from Tasks 9-11):

1. **Focus-or-attach with window-name dedupe** — `tui/utils/tmux.ts:258-330`
   (`openDedupedCommandWindow`): `list-windows -a` → switch if a live named window
   exists, else `new-window -n <name>` where the command *is* the pane process (no
   shell wrapper — a lingering shell poisons name-dedupe, rationale at `:250-257`).
   Directly reusable for Task 10.
2. **Client-agnostic tmux targeting** — pick the most-recently-active client by
   `#{client_activity}` (`lib/tmux-client.ts:46-70`), then
   `switch-client -c <tty> -t <pane>`, with `display-popup -c <tty>` for paneless
   rows (`daemon/notify-jump.ts:44-67`). Confirms BUG FIX 4. Also
   `resolveLaunchPane` **re-resolves per action rather than caching** — confirms
   BUG FIX 3 (TOCTOU).
3. **Notification safety tokens** — dual staleness stamps `statusChangedAt` +
   monotonic `attentionGeneration` (`types/session.ts:145-154`); a press whose
   tokens mismatch is 409'd and re-notified instead of blind-keystroked; undelivered
   reply text is quoted back without Enter. Best-in-class "don't answer a prompt
   that moved" — adopt if we ever answer from the picker.
4. **Preview capture** — `capture-pane -e -t <pane> -p -S-<n>` that *throws* on a
   dead pane instead of returning `""` (`tui/utils/tmux.ts:16-38`); pane flash via
   per-pane `window-style` so it never steals focus (`:110-170`). Task 11.
5. **Row/search model** — responsive column budgeting
   (`components/session-columns.ts:76-132`), tiered match ranking
   `identity > cwd > prompt > pane > transcript` that reports *why* a row matched
   (`utils/grouping.ts:34-60`), asymmetric snippet window (lead 24 / trail 136) so
   the match isn't clipped (`transcript-search.ts:26-32`). Task 9.
6. **Inbox-style attention** — `unread/read/null` kept orthogonal to status
   (`daemon/attention-tracker.ts:14-31`). Independent arrival at our
   `attention: seen/unseen` axis; copy the transition rules.

**Safety note for any future "answer from the picker":** OpenCode's permission
dialog has no absolute selector — only Left/Right move the highlight, digits/Tab
are inert, and Escape interrupts the whole turn and strands the session in
`working` (`lib/agents.ts:645-667`). Deny is `Right Right Enter`. A leading space
defuses `/` but **not** `!` (OpenCode trims it and enters shell mode, where Enter
*executes*) — inherit their `unsafeReplyPattern` `/^\s*!/`. Further reason to use
the structured reply API, never keystrokes.

**Claude Code Agent View** (`code.claude.com/docs/en/agent-view`) — the strongest
*product* precedent and independent validation: it models semantic state
(working / needs-input / idle / completed / failed / stopped) **separately** from
process status (alive / exited-restartable / sleeping), promotes needs-input to
the top, and keeps background conversations attachable later. Claude-only, no
tmux/nvim routing, no transcript DB — but it confirms the two-axis split and the
"blocked even when nothing is attached" requirement.

**herdr** — genuinely agent-aware with a substantial socket API (enumerate/focus
workspaces·tabs·panes, `pane.report_agent` for externally-reported authoritative
state, custom global views that could express "current workspace + blocked
anywhere"). **But its object is a pane**: `pane.report_agent`/`report_agent_session`
are keyed by `pane_id`, so a logical session with **no herdr pane** is not a
first-class agent. Adopt herdr only if we want herdr as our multiplexer; it does
not remove the registry work.

**workmux** (`github.com/raine/workmux`) — its OpenCode plugin maps permission
*and* structured-question events to a waiting state and back; good reference for
our reducer. Also a warning: it has already broken on **OpenCode event-name
drift** → put OpenCode decoding behind a versioned adapter emitting our own small
internal schema, with fixture tests from captured event sequences.

**gentle-agent-state** — state-normalization substrate (agent events → states for
tmux/Zellij surfaces); reference for the adapter idea.

**Rejected as bases:** `sesh` (composable at shell level but contributes only
list-composition; `sesh connect` doesn't understand our targets), `tmux-sessionx`
(no general custom-row protocol), Zellij (viable plugin host, but only if we're
migrating multiplexers anyway).

**Further failure modes flagged (beyond the 4 fixed inline):** never answer a
blocked session by injecting keystrokes into a shared pane (target the session id
via the structured response API); attach may not replay a pending interaction, so
show it from our own state and ideally answer without attaching; don't delete a
logical session just because its last attachment vanished; for the 13 GB
transcript DB use FTS5/a real index + debounce + top-K rather than repeated
`LIKE` scans (already our documented Phase-2 upgrade path).
