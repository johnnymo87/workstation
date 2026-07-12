# OpenCode session switcher: semantic-state-aware fuzzy navigation

**Date:** 2026-07-12
**Status:** Draft (design) — pending adversarial review
**Repos touched:** `workstation` (opencode plugin bundle, oc-auto-attach, nvim
config, statusline), later `lgtm` (fallback tagging, optional)

## Motivation

The current opencode multiplexer is nvim tabs (each running `opencode attach`)
inside tmux windows, with `tabby.nvim` scraping `b:term_title` for tab labels
(`assets/nvim/lua/user/tabby.lua`). Two pain points:

1. **Navigation at scale.** When busy, a few dozen nvim tabs stack up in a
   window; the horizontal tabline is painful to scan/navigate. A vertical
   sidebar would be crowded too — the real fix at "few dozen" is *fuzzy search*,
   which we already have wired (`telescope` + `fzy_native`,
   `assets/nvim/lua/user/telescope.lua:37`).
2. **No semantic state.** `tabby.lua` approximates agent state by scraping the
   terminal title and special-casing OpenCode clearing it during compaction.
   Fragile. OpenCode exposes real state on its event bus.

This design was prompted by evaluating [herdr](https://herdr.dev/), a productized
agent multiplexer. Conclusion: herdr solves the *generic* version of a problem we
have already solved the *opencode-specific* way we actually need (Nix, serve
pool, swarm, lgtm). We steal the two ideas worth stealing — **semantic agent
state** and **per-agent status breakdown** — and build them opencode-native,
because we have privileged access to opencode's event bus that herdr (a generic
PTY wrapper) does not.

## What we are building

A **fuzzy session switcher** in telescope that:

- lists opencode sessions with **semantic state at a glance** (working / blocked
  / idle) and idle-age,
- **jumps** a selection to the right tmux window + nvim buffer, or **attaches**
  it fresh if detached,
- searches **titles** (current working set) or **contents** (full history),
- **groups by project** and **scopes by tmux session** (so `lgtm` noise is out
  by default),
- feeds a **statusline** count and (later) a **per-session notifier**.

## Non-goals / YAGNI

- **block-until-done** primitive (herdr's `wait agent-status`) — dropped.
- **cross-host jump** — the registry reserves a `host` field, but v1 is
  same-host (cloudbox first).
- **multi-agent-per-buffer** — one `opencode attach` per buffer, as today.
- **mobile switcher** — deferred (herdr's mobile-first UI is later on our
  roadmap).
- **DELETE-ing sessions** — unchanged; history stays unbounded, pruning stays
  occasional. We *measure* the lifecycle, we don't change it.
- **project→directory routing** in oc-auto-attach — a separable follow-on (see
  "Related follow-ons"); the picker's project label is kept abstract to be
  forward-compatible.

## Architecture

Hub-and-spoke. One producer, several consumers.

```
opencode-serve (plugin) ──writes──► state snapshot  ◄──merge── nvim registry
                                          │                    (location)
        ┌─────────────────────────────────┼──────────────────────────┐
        ▼                                 ▼                          ▼
 telescope picker              statusline counts            Telegram notifier
 (jump / attach / search)      (⧗2 ●1 ambient)              (per-session topic)
```

### 1. State source — an opencode plugin (extension of existing bundle)

We already ship an opencode plugin bundle (`assets/opencode/plugins/`) and the
self-compact plugin already consumes bus events — `self-compact-impl.ts:210`
narrows `session.status` idle today. The plugin host runs *inside serve* and sees
every session's events for free. So the state source is a small extension of a
bundle we already maintain, **not** a new SSE-subscribing daemon.

Event → state mapping (verify exact event names against
`~/projects/opencode/packages/opencode/src` during implementation):

| opencode bus event            | derived activity state |
|-------------------------------|------------------------|
| `message.part.updated` (streaming) | `working`         |
| `permission.asked`            | `blocked`              |
| `permission.replied`          | back to `working`     |
| `session.status` = idle       | `idle`                |

There is no intrinsic "done" in opencode; we do not invent one (see State model).

### 2. State model — attachment × activity (two axes)

The key realization: **attachment and activity are orthogonal.** Today "open
tab" conflates "I'm watching it" with "it's still mine." We split them:

- **Activity** (from the plugin): `working` / `blocked` / `idle`.
- **Attachment** (from the registry): `attached` (a live `opencode attach`
  buffer exists) / `detached` (none).

The 2×3 grid:

|              | working              | blocked                    | idle                 |
|--------------|----------------------|----------------------------|----------------------|
| **attached** | watching it work     | needs input, I'm here      | paused, window open  |
| **detached** | running headless     | blocked, I walked away     | done / prune candidate |

`detached + working` (running headless) is exactly herdr's headline feature — we
get it as a side effect.

**"Open vs closed" is the attachment axis.** A live terminal buffer = attached =
open; `:bdelete` (which kills the attach job) = detached = closed. Same muscle
memory as closing a tab, `s/tab/buffer/`. The server-side session is never
touched.

### 3. Registry & lifecycle

The registry maps `sessionID → { host, tmuxSession, tmuxWindow, nvimSocket,
buffer }`, owned by the nvim side:

- **Write on attach:** extend `oc_auto_attach.open()`
  (`assets/nvim/lua/user/oc_auto_attach.lua`) — it already has `sid`/`dir` and
  stamps `b:oc_session_id` (line 47). Add: `$TMUX_PANE` → `#{session_name}` and
  `#{window_name}`, `v:servername` (nvim socket), buffer id.
- **Remove on close:** a `TermClose` / `BufDelete` autocmd removes the entry.

This makes "open vs closed" **authoritative and real-time**, which *fixes the
nightly-reset bug* the user described ("captures things I believe I already
closed"): today `reset-workspace` infers open-ness after the fact from lossy
state; with the registry it reads an authoritative map. (Confirm exact reset
integration point against `pkgs/reset-workspace`.)

### 4. Snapshot store / IPC

**v1: atomic JSON snapshot file.** The plugin writes
`~/.local/share/opencode/session-state.json` on each transition and appends
transitions to `session-state.log` (for the notifier). Consumers read the file;
the picker merges it with the registry file at read time. Rationale: refreshed on
every transition (freshness is a non-issue), no new listening port to supervise
(we have been burned by wedged serves), trivially debuggable with `cat`.

**Documented upgrade path (not built):** a tiny socket/HTTP server inside the
plugin, for live push instead of file polling — mirrors the FTS5 upgrade note in
the `searching-sessions` skill. Recorded so we do not lose the idea.

Per-session snapshot fields (at least): `sessionID`, `title`, `state`,
`lastActivity` (for idle-age + recency sort), `space` (sticky last-known tmux
session name), `project` (sticky last-known tmux window name), `directory`,
`origin`-fallback classification.

### 5. Jump-or-attach

Picker selection resolves the registry entry and:

- **attached** → `tmux select-pane`/`select-window` to the window, then
  `nvim --server <socket> --remote-expr` to focus the buffer.
- **detached** (no entry) → attach fresh via the existing `oc_auto_attach` path.

So the picker is a unified "resume anything," open or closed.

## Search modes

Two modes mirroring existing muscle memory (`<leader>ff` / `<leader>fg`):

| | **Title mode** (default) | **Content mode** (toggle) |
|---|---|---|
| Analog | `find_files` | `live_grep` |
| Corpus | working set (bounded) | all sessions (`opencode.db` `part.data`) |
| Speed | instant | `instr()` scan, ~seconds (as `oc-search`) |
| State glyph | yes | yes (joined from snapshot) |
| Answers | "jump to something I'm working on" | "find the session where I did X" |

Content mode reuses the `oc-search` corpus
(`~/.local/share/opencode/opencode.db`, `part.data` JSON) and its
`--types`/`--all` scope. A content hit → sessionID → the same jump-or-attach. Do
not blend the two into one ranked list — relevance gets muddy.

## Scope & grouping

Two tmux levels, two axes:

- **Scope = tmux session (dynamic).** The `space` field is the *last-known tmux
  session name* (`main`, `lgtm`, `scratch`, …). The picker default filters to
  "session == the one I'm attached to now" (usually `main`). Dynamic — any future
  daemon routing to its own tmux session gets its own bucket for free. No
  hardcoded enum. Sticky/persisted so it survives detach.
- **Grouping = tmux window = project.** The `project` field is the *last-known
  tmux window name* (oc-auto-attach sets `-n "$window_name"`). The picker groups
  by it by default.

### lgtm boundary

lgtm (`~/projects/lgtm`) is a PR-review daemon that dispatches headless opencode
sessions, already routed to a dedicated `lgtm` tmux session via `--tmux-session
lgtm` (`docs/plans/2026-06-04-lgtm-dedicated-tmux-session-design.md`). So its
sessions get `space = lgtm` for free and are **excluded from the default scope**.

For **detached** lgtm sessions we never observed attached, a durable fallback
classifier: `session.directory` matching `**/.worktrees/pr-<N>`
(`lgtm/src/worktree.ts:114`). If that path convention ever changes, lgtm can
stamp an explicit marker — not built now.

Facets: default = current session (`main`); `lgtm only` (serves the existing
`following-up-on-a-review` lgtm skill as a keystroke); `all`. Also a quick
`blocked only` triage facet, and attachment facets `attached/detached/all`.

## Display (telescope, flat + fuzzy)

Telescope has no native collapsible tree, so group visually while staying
flat/fuzzy:

```
[herdr]     ● llm-proxy · blocked
[herdr]     ⟳ herdr     · working
[qmp]       · qmp       · idle 2h
```

- Entries prefixed `[project]`, default-sorted clustered by project, then by
  state priority (`blocked` → `working` → `idle`), then ascending idle-age.
- Fuzzy matching runs over `project + title`: typing a project name clusters to
  that space; typing a session name still finds it across everything.
- Idle-age is a dim suffix and doubles as prune radar.
- **Default scope is bounded**: attached + recently-active (last ~N hours).
  Ancient idle sessions drop out of the default view (reachable via content mode
  / an `all` facet), so the picker never crowds regardless of how many
  never-deleted sessions exist.

## Preview pane (input / results / preview)

Uniform intent — "what is this session about, where did it leave off?":

- **Header (always):** `title · state glyph · idle-age · space · project ·
  directory`.
- **Title-mode body:** transcript **tail** from `opencode.db` (last user prompt +
  last assistant text). One code path for both attached and detached (answers
  "what does a detached session preview?" — the readable last exchange, not raw
  JSON).
- **Content-mode body:** the matching part with surrounding context (like
  `live_grep`).

**Documented enhancement (not v1):** for attached sessions, preview the live
terminal buffer's current screen instead of the DB tail.

## Statusline

A lualine/statusline component reads the snapshot and shows ambient counts, e.g.
`⧗2 ●1` (blocked/working). Trivial once the snapshot exists — folded into
Phase 1.

## Rollout (phased, cloudbox first)

Cloudbox hosts the serve pool + swarm + lgtm, so it goes first. Same-host only in
v1.

- **Phase 1 (MVP):** plugin state snapshot + transition log → nvim registry
  writer → telescope **title** picker (state glyphs, sort, scope/project
  grouping, attachment filters, jump-or-attach) → statusline counts.
- **Phase 2:** content-search mode over `opencode.db`.
- **Phase 3:** Telegram **forum-topic** notifier (one topic per session, fires on
  `working→blocked` / other transitions) — replaces today's single-channel
  firehose.
- **Later / documented, not built:** live-buffer preview, mobile switcher,
  cross-host jump, socket/HTTP snapshot upgrade, oc-auto-attach project routing.

## Open questions / verification items

1. **Exact event names/shapes.** Confirm `message.part.updated`,
   `permission.asked`/`permission.replied`, `session.status` payloads (esp. how
   to distinguish streaming from a one-off part update) in
   `~/projects/opencode/packages/opencode/src`. Debounce rapid working↔idle
   flicker.
2. **Does the plugin see `session.directory`?** Needed for the lgtm fallback
   classifier and preview header. If not on the event, look it up via the local
   HTTP API (`GET /session/<id>`).
3. **Snapshot write concurrency.** Multiple serve processes in the pool → do they
   share one plugin host / one snapshot file, or one per serve? Define the
   canonical path and an atomic-write + merge strategy that tolerates N writers.
4. **Registry staleness.** nvim crash / tmux kill without `TermClose` → stale
   entries. Need a reconcile (e.g. verify pane/socket liveness at read time, or
   expiry).
5. **Reset integration.** Exact hook in `pkgs/reset-workspace` to consume the
   registry instead of inferring open-ness.
6. **Content-mode → sessionID mapping** and jump for a session whose window no
   longer exists (attach fresh in current window? which project?).

## Related follow-ons (separable)

- **oc-auto-attach project routing:** a `project → directories` map so a
  multi-codebase project's sessions land in one tmux window regardless of cwd
  (today it matches cwd/descendant). Enables true multi-codebase grouping; the
  picker's abstract `project` label is forward-compatible with it.
- **Fixing residual nightly-reset "already closed" bugs** using the authoritative
  registry.
