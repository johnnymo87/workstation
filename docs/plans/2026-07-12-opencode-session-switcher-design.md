# OpenCode session switcher: semantic-state-aware fuzzy navigation

**Date:** 2026-07-12
**Status:** Draft (design) — **revised after adversarial review**
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
flood the picker. `parentID` isn't on the event; look it up via DB / `GET
/session/<id>`.

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

### 4. Jump-or-attach

- **attached** → if the target is in another tmux **session**, `tmux
  switch-client -t <session>` (not just `select-window`); then `select-window`
  and `nvim --server <sock> --remote-expr` (with `</dev/null`) to focus the
  buffer/tabpage from discovery.
- **detached** → attach fresh via the existing `oc_auto_attach` path.
- **directory gone** (lgtm prunes `.worktrees/pr-<N>` after merge;
  `oc_auto_attach.lua:35` hard-rejects a missing dir, and attach without a
  matching `--dir` freezes the TUI per the `event.ts` filter) → **fallback:
  preview-only, or attach with an explicit "directory gone" notice** (verify TUI
  behavior under a deleted `--dir` before promising attach). This path matters:
  it's exactly the content-mode "find that old review" flow.

## Search modes

Two modes mirroring `<leader>ff` / `<leader>fg`:

| | **Title** (default) | **Content** (toggle) |
|---|---|---|
| Corpus | recency-bounded working set (DB) | all sessions (`opencode.db` `part.data`) |
| Speed | instant | `instr()` scan (as `oc-search`) |
| State glyph | yes | yes (overlay join) |

Content mode reuses the `oc-search` corpus and `--types`/`--all` scope; a hit →
sessionID → the same jump-or-attach (incl. directory-gone fallback). Never blend
the two into one ranked list. Set `busy_timeout` on any DB read (4 serves write
concurrently; `oc-search` proves it's viable).

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

## Open questions / verification items

1. **`--dir <deleted>` TUI behavior** — confirm what attach does with a pruned
   directory before promising any attach (vs preview-only) in the directory-gone
   fallback (§4).
2. **Subagent rollup detail** — cheapest reliable `parentID` lookup (DB vs API)
   and the roll-up rule (does a child `blocked` mark the parent `blocked`, or a
   distinct "child-blocked" glyph?).
3. **Heartbeat interval T** and dead-PID detection portability across the pool.
4. **`session.status` payload shape** — confirm exact discriminant for
   busy/idle/retry and where `retry` backoff timing lives, for the retry glyph.
5. **Nested-`$TMUX_PANE` sockets** — ensure discovery dedupes/handles a parent
   nvim and its `:terminal` child sharing a pane key (`nvims/test.sh:6`).

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
