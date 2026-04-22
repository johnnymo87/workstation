# Auto-Attach Launched OpenCode Sessions to nvim+tmux

**Status:** Design — awaiting implementation plan.
**Date:** 2026-04-22
**Author:** dev (with OpenCode brainstorm)

## Problem

Launching a new OpenCode session via `opencode-launch` (CLI) or pigeon's
`/launch` (Telegram) creates a session on the local `opencode serve`, but
nothing surfaces it visually. The user has to either:

- Type `opencode -s ses_FOO` (which spawns an isolated TUI worker that does
  not subscribe to opencode-serve's event bus — see the parallel investigation
  in this conversation), or
- Type `opencode attach http://127.0.0.1:4096 --session ses_FOO` (which does
  subscribe, but is a mouthful and requires copying the session id around).

Either way it is manual ceremony. The user wants launched sessions to
automatically appear as a new tab in the right nvim instance, inside the right
tmux window.

## Constraints (from brainstorming)

- **Trigger scope:** only `opencode-launch` and pigeon `/launch`. Sessions
  the user starts manually with bare `opencode` are out of scope (they
  already have a TUI).
- **Surface:** new nvim tab, in the matching project's nvim, running
  `opencode attach` in a terminal buffer. Reuses the existing tabby.lua tab
  labelling (reads `b:term_title` set by OpenCode TUI to "OC | <title>").
- **Channel:** per-nvim Unix sockets via `nvim --listen`, with a
  deterministic socket path keyed on tmux pane id. Same pattern as the old
  `nvims()` shell function in dotfiles.
- **Project-key collapse:** sessions whose cwd is
  `~/projects/<P>/.worktrees/<W>/...` collapse to the same nvim as cwd
  `~/projects/<P>/...`. There is one nvim per project, period.
- **Always project-root nvim:** never prefer a worktree-specific nvim over
  the project-root one, even if a more specific match exists.
- **Full magic:** if no nvim is open for the project, the trigger creates a
  new tmux window with `nvims` and proceeds.
- **Sessions outside `~/projects/`:** create a new tmux window named after
  the cwd basename, with nvim, and proceed.

## Architecture

```
opencode-launch (bash)         pigeon launch-ingest (TS)
        │                              │
        │  POST /session              │  createSession + sendPrompt
        ▼                              ▼
                  opencode serve
        │                              │
        └──────────────┬───────────────┘
                       │  oc-auto-attach $session_id  (background)
                       ▼
              ┌────────────────────────┐
              │ oc-auto-attach (bash)  │
              │  • GET /session/<id>   │  → wait until directory present
              │  • compute project key │  (collapse worktrees)
              │  • find/create tmux    │  tmux new-window -P -F '#{pane_id}'
              │    window with nvims   │
              │  • compute socket path │  /tmp/nvim-${pane_id}.sock
              │  • probe RPC ready     │  pcall(require, ...) over RPC
              │  • RPC: open(opts)     │
              └───────────┬────────────┘
                          │  nvim --server <sock> --remote-expr
                          │      'luaeval("require(\"oc_auto_attach\").open(_A)",
                          │               {sid=..., dir=..., url=...})'
                          ▼
              ┌────────────────────────┐
              │ oc_auto_attach.lua     │
              │  open(opts):           │
              │   tabnew               │
              │   jobstart(argv,       │
              │     {term=true,        │
              │      cwd=opts.dir})    │  ← exact session.directory
              └────────────────────────┘
```

There is no opencode plugin in this design. The two launch entry points
already exist and are exactly the moments the user wants to react to —
shifting the trigger out to a plugin would require distinguishing
"launched" sessions from "TUI-started" sessions on the bus, which is
extra work for no gain given the scope cut.

## Components

### 1. `nvims` real executable (not a shell function)

**Location:** `pkgs/nvims/` as a `pkgs.writeShellApplication`, on PATH
via `home.packages`.

**Why a real script and not a shell function:** `tmux new-window 'nvims'`
runs the command via a fresh shell that may or may not have sourced our
bash init (interactive vs. non-interactive). A shell function won't be
visible there. A binary on PATH always works.

```bash
# pkgs/nvims/nvims.sh
#!/usr/bin/env bash
set -o errexit
set -o nounset
set -o pipefail

key="${TMUX_PANE#%}"        # %3 -> 3 ; pane ids start with %
if [ -z "$key" ]; then
  key="${RANDOM}-$$"        # outside tmux, fall back
fi
sock="/tmp/nvim-${key}.sock"

# Honor any --listen flag the caller passed; otherwise inject ours.
exec nvim --listen "$sock" "$@"
```

The user trains the muscle memory `nvims` instead of `nvim` inside tmux.
Outside tmux, falls back to a per-PID socket so it still works.

`$TMUX_PANE` (e.g. `%17`) is the tmux pane id, documented as unique and
unchanged for the life of the pane and passed to child processes via the
environment. Reading it from outside is trivial:
`tmux list-panes -a -F '#{pane_id} ...'`.

### 2. `oc-auto-attach <session-id>` script

**Location:** `pkgs/oc-auto-attach/oc-auto-attach.sh`, packaged as a Nix
package and added to `home.packages`. Runtime inputs: `curl`, `jq`,
`tmux`, `coreutils` (for `timeout`), and the patched `opencode` (only
indirectly — we call `nvim --server`, not opencode).

**Behavior:**

1. **Look up session metadata with bounded retries.**
   `curl -s http://127.0.0.1:4096/session/<id>` → JSON with `directory`.
   - Retry up to ~2s total, polling, requiring HTTP 200 AND a
     non-empty `.directory`.
   - On timeout, log and exit 0 (don't fail the launcher).
   - Rationale: there are reports that `opencode attach --session`
     can exit immediately if the session is not yet ready in the
     server's status map, even after `POST /session` returned. The
     readiness probe is cheap insurance.
2. **Compute project key for editor routing.**
   - If `directory` matches `^${HOME}/projects/([^/]+)(/.*)?$`, project
     key is `${HOME}/projects/$1`. Worktree paths
     (`/.worktrees/<W>/...`) collapse here automatically because
     `$1` captures the project name regardless of what comes after.
   - Otherwise fall back to the literal `directory`. Window name is
     `basename "$directory"`.
   - **Important:** the project key is used ONLY to pick which nvim
     window to talk to. The `opencode attach` process itself runs
     with `cwd = session.directory` (the exact directory from `GET
     /session/<id>`). This split avoids known OpenCode `attach
     --session` cwd-mismatch and cross-project-leakage bugs.
3. **Find or create the tmux window.**
   - Walk `tmux list-panes -a -F '#{session_name}|#{window_index}|#{pane_id}|#{pane_current_path}|#{pane_current_command}|#{pane_pid}'`.
   - Match: a pane whose `pane_current_path` equals the project key
     (or starts with it for worktree-collapse), AND whose
     `pane_current_command` is `nvim`.
   - If multiple matches, prefer the one whose `pane_current_path` ==
     project key exactly (project-root nvim) over any deeper match.
   - If no match: create a new tmux window AND capture its pane id in
     one shot:
     ```bash
     new_pane="$(tmux new-window -d -P -F '#{pane_id}' \
       -c "$project_key" -n "$window_name" "$(command -v nvims)")"
     ```
     The `-P -F '#{pane_id}'` form returns the new pane id directly,
     no polling needed for window creation.
4. **Compute socket path.** `/tmp/nvim-${pane_id#%}.sock`.
5. **Wait for the nvim RPC server to be ready.**
   ```bash
   timeout 5 bash -c '
     until [ -S "$1" ] && \
           nvim --server "$1" --remote-expr \
             "luaeval(\"pcall(require, \\\"oc_auto_attach\\\")\")" \
             >/dev/null 2>&1
     do :; done
   ' _ "$sock"
   ```
   This proves both the socket file exists AND the helper module is
   loaded. (For an existing nvim, this returns instantly. For a
   freshly spawned one, it waits for nvim to finish booting.)
6. **Open the tab via the helper.**
   ```bash
   nvim --server "$sock" --remote-expr \
     "luaeval('require(\"oc_auto_attach\").open(_A)', \
              {sid='$session_id', dir='$session_dir', \
               url='$OPENCODE_URL'})"
   ```
   The helper (see component 3) handles `tabnew + jobstart(argv,
   {term=true, cwd=...})` so we get clean argv quoting and per-job
   cwd without shell-string parsing. We hard-validate `$session_id`
   matches `^ses_[A-Za-z0-9]+$` before interpolating.

### 3. nvim Lua helper

**Location:** `assets/nvim/lua/user/oc_auto_attach.lua`. Loaded by the
existing nvim init (alongside `user.tabby`, `user.telescope`, etc.).

```lua
-- assets/nvim/lua/user/oc_auto_attach.lua
local M = {}

--- Open a new tab with `opencode attach` running in a terminal buffer.
--- @param opts table { sid: string, dir: string, url: string }
--- @return integer 1 (so --remote-expr has something to print)
function M.open(opts)
  vim.schedule(function()
    vim.cmd.tabnew()
    vim.b.oc_session_id = opts.sid
    vim.b.oc_session_dir = opts.dir
    vim.fn.jobstart({
      "opencode", "attach", opts.url,
      "--session", opts.sid,
    }, {
      term = true,
      cwd = opts.dir,
    })
  end)
  return 1
end

return M
```

`vim.schedule` lets the `--remote-expr` call return immediately while
the tab/job creation runs on Nvim's main loop. `jobstart` with
`term = true` is the modern equivalent of `:terminal`, with the
benefit that we pass an argv list (no shell quoting of `--session`)
and an explicit `cwd` per the editor-routing-vs-process-cwd split.

### 4. nvim init wiring

`assets/nvim/init.lua` (or wherever modules are required) gains:
```lua
require("user.oc_auto_attach")
```
just like `user.tabby` is already wired. The require returns the
module so `:lua require("user.oc_auto_attach").open(...)` works
externally — and so the readiness probe (`pcall(require, ...)`)
returns `[true, <module>]`.

### 5. Wire into `opencode-launch`

The `opencode-launch` script lives at
`users/dev/home.base.nix` (see the `opencode-launch = pkgs.writeShellApplication { ... }`
let-binding around line 7). It gains a final line just before the
"Session launched" echo:

```bash
oc-auto-attach "$session_id" >/dev/null 2>&1 &
disown
```

Backgrounded so the launch returns immediately. The user gets the
session id printed (existing behaviour) AND the nvim tab pops up
shortly after.

If `oc-auto-attach` is not on PATH (e.g. older host), the launch still
succeeds.

### 6. Wire into pigeon `/launch`

`packages/daemon/src/worker/launch-ingest.ts`, after the
`sendPrompt` succeeds, spawns `oc-auto-attach $session.id` detached:

```ts
import { spawn } from "child_process";
// ...
spawn("oc-auto-attach", [session.id], {
  stdio: "ignore",
  detached: true,
}).unref();
```

Wrapped in a try/catch with an `ENOENT` swallow so missing
`oc-auto-attach` (e.g. on cloudbox where there's no graphical workflow)
doesn't break `/launch`.

### 7. Skill update

Add or update `assets/opencode/skills/opencode-launch/SKILL.md` to:

- Document the auto-attach behaviour.
- Mention the `nvims` requirement (i.e. you must use `nvims` not
  `nvim` for this to work).
- Note that auto-attach only fires for `opencode-launch` and
  pigeon `/launch`, not bare `opencode`.

Also update `opencode-send`'s skill briefly to note that **attach via
`opencode attach`** is preferred over `opencode -s` when subscribing
to a serve-owned session, because of the in-process worker isolation
(this is the "side quest" insight from the parent conversation).

## Edge cases & decisions

| Case | Resolution |
|---|---|
| Session cwd outside `~/projects/` | Create new tmux window named after cwd basename, with nvims. |
| Project-root nvim not open | Create new tmux window in project root with nvims, proceed. |
| Both project-root and worktree nvim open | Always pick project-root (per stated preference). |
| nvim socket is stale | Skip that match, try next. If no live match, fall back to creating a new window. |
| Race: attach before opencode serve has registered the session | Retry session metadata lookup with backoff (5×200ms). |
| User runs `nvim` instead of `nvims` | No socket, so `oc-auto-attach` skips the match and falls back to creating a new tmux window. We document `nvims`. |
| Cloudbox / headless host | `oc-auto-attach` not installed → pigeon swallows ENOENT, opencode-launch's `&` swallows the error. No-op. |
| Multiple tmux clients (mosh + local) | Both see the new tab/window. Fine. |

## Out of scope

- Auto-attach for bare `opencode` sessions. Out by user decision.
- Auto-attach for swarm cross-session messages (those don't create new
  sessions, just deliver prompts to existing ones).
- Auto-detach when a session ends. Tab stays for review; user closes it.
- Cross-machine auto-attach (e.g. attaching a session that lives on
  cloudbox). Local only.
- Smart focus: should we `tmux select-window` to the new tab? Probably
  not by default — the user may be focused on something else. Could be
  a `--focus` flag on `oc-auto-attach` if desired later.

## Verification (before implementing)

ChatGPT consult (`/tmp/research-launch-auto-attach-answer.md`) confirmed
several assumptions and surfaced two design corrections (now applied
above). Remaining things to spot-check at the top of the implementation
plan:

1. `$TMUX_PANE` is set in the env when bash invokes `nvims`. (Doc
   confirms it's exported to children — but verify on this host with
   `tmux list-panes -a -F '#{pane_id} #{pane_pid}'` matched against
   actual nvim processes' env.)
2. `nvim --server <sock> --remote-expr 'luaeval("...")'` runs and
   prints a value. (Smoke-test with a hello-world Lua module.)
3. `pane_current_command` reads as `nvim` for our setup. **Already
   verified** (see brainstorming session) — `tmux list-panes -a` shows
   `%1|nvim|/home/dev/projects/workstation` for every project window.
4. `GET /session/<id>` returns the session's `directory`. **Already
   verified** in code: `packages/opencode/src/session/session.ts:66,90`
   exposes `directory: row.directory`.
5. Worktree paths collapse correctly with the regex
   `^${HOME}/projects/([^/]+)(/.*)?$`. (Smoke-test with two paths:
   `~/projects/pigeon/foo` and
   `~/projects/pigeon/.worktrees/feature-x/foo`. Both should yield
   project key `~/projects/pigeon`.)
6. `tmux new-window -P -F '#{pane_id}'` returns the new pane id on
   our tmux version. (Quick check: `tmux new-window -d -P -F
   '#{pane_id}' 'sleep 1'` should print `%N`.)
7. `jobstart({...}, {term=true, cwd='...'})` actually runs opencode
   in a terminal buffer with the right cwd, and `b:term_title` gets
   set to `OC | <title>` (so tabby labels the tab).

## Risks

- **nvim Lua injection.** The session id and dir end up inside a Lua
  string in `--remote-expr`. Session ids are `^ses_[A-Za-z0-9]+$` —
  hard-validate before interpolation. Session dirs come from
  `GET /session/<id>` which is server-validated, but we still escape
  single-quotes defensively (or pass values through a Lua table
  literal where strings are properly quoted, as in the design).
  Same hygiene for `tmux new-window -c`.
- **Tmux window proliferation.** If the user often launches sessions
  in odd directories, the "create new window" fallback may spam
  windows. Mitigation: dedup on window-name (don't create a new
  window if one with the same `window_name` already exists in the
  current tmux session). Add in v1 — cheap.
- **Pigeon coupling.** Adding `spawn("oc-auto-attach")` to pigeon is a
  small platform-coupling. Mitigated by ENOENT swallow. Worth a
  comment in the source.
- **OpenCode `attach` readiness race.** ChatGPT flagged that
  `opencode attach --session` has been observed to exit immediately
  if the session isn't yet ready in the server's status map, even
  after `POST /session` returned. Mitigated by the
  `GET /session/<id>` poll in step 1 of `oc-auto-attach`. If we
  still see flakiness, the next escalation is a small retry wrapper
  inside the terminal job.
- **OpenCode `attach` cwd bugs.** ChatGPT noted there are reports of
  cwd-mismatch and cross-project leakage in `attach --session`.
  Mitigated by passing `cwd = session.directory` (exact, not
  collapsed) to `jobstart`.

## Approval gate

Once the user signs off on this design, the next step is to invoke the
`writing-plans` skill to produce `2026-04-22-launch-auto-attach-plan.md`.
