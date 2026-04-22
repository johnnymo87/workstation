# Launch Auto-Attach Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make `opencode-launch` and pigeon `/launch` automatically open the new session as a tab in the right project's nvim, inside the right tmux window.

**Architecture:** Per-tmux-pane Unix sockets via `nvim --listen "/tmp/nvim-${TMUX_PANE#%}.sock"` (deterministic, discoverable). A bash orchestrator (`oc-auto-attach`) resolves the new session's directory, picks the right nvim by collapsing worktree paths to project root, creates a tmux window if none exists, then RPCs into nvim via `nvim --server <sock> --remote-expr 'luaeval(...)'` to invoke a tiny Lua helper. The helper does `tabnew + jobstart(argv, {term=true, cwd=<exact session dir>})`. Both launchers fire `oc-auto-attach <id> &` after creating the session; missing `oc-auto-attach` is tolerated (ENOENT swallowed) so headless hosts (cloudbox) keep working.

**Tech Stack:** bash, nvim Lua, tmux, Nix (`writeShellApplication`), home-manager, TypeScript (pigeon edit).

**Design doc:** `docs/plans/2026-04-22-launch-auto-attach-design.md`

**Repo paths:**
- Workstation: `/home/dev/projects/workstation` (in-place on `main`).
- Pigeon: `/home/dev/projects/pigeon`.

---

## Pre-flight: Verification spikes (no commits)

Run these spike tests at the top of execution to confirm assumptions. Each is < 30s. If any fails, STOP and discuss before continuing.

### Spike 1: `$TMUX_PANE` is set and matches `tmux list-panes`

Run from inside an nvim terminal in any tmux pane:
```bash
echo "TMUX_PANE=$TMUX_PANE"
tmux list-panes -a -F '#{pane_id} #{pane_pid} #{pane_current_command} #{pane_current_path}' | grep "$TMUX_PANE"
```
Expected: `TMUX_PANE=%N`, the matching `tmux list-panes` row appears, and the row shows `nvim` as the current command and the project root as the path.

### Spike 2: `nvim --server` `--remote-expr` round-trip

Pick a live nvim (e.g. one of the panes from spike 1). Without using `nvim --listen` (you can use the auto-listen socket exposed at `:echo v:servername` from inside a different nvim, or just spin up a throwaway):
```bash
# Throwaway:
mkdir -p /tmp/nvim-spike
nvim --headless --listen /tmp/nvim-spike/sock -c 'lua _G.spike = function(x) return x .. " back" end' &
# Wait for socket
timeout 5 bash -c 'until [ -S /tmp/nvim-spike/sock ]; do :; done'
nvim --server /tmp/nvim-spike/sock --remote-expr 'luaeval("_G.spike(_A)", "hello")'
# Cleanup
pkill -f 'listen /tmp/nvim-spike/sock' || true
rm -rf /tmp/nvim-spike
```
Expected: prints `hello back` to stdout.

### Spike 3: `tmux new-window -d -P -F '#{pane_id}'` returns the pane id

```bash
new_pane="$(tmux new-window -d -P -F '#{pane_id}' 'bash -c "while true; do sleep 1; done"')"
echo "new pane: $new_pane"
tmux list-panes -a -F '#{pane_id}' | grep -F "$new_pane"
tmux kill-pane -t "$new_pane"
```
Expected: prints a `%N` and grep finds it.

### Spike 4: `GET /session/<id>` returns `directory`

```bash
# Use a known existing session id from `opencode-send --list`
sid="$(curl -s http://127.0.0.1:4096/session | jq -r '.[0].id')"
curl -s "http://127.0.0.1:4096/session/$sid" | jq -r '.directory'
```
Expected: prints a real path like `/home/dev/projects/pigeon`.

### Spike 5: `jobstart({term=true, cwd=...})` works in nvim

In any open nvim, run:
```vim
:lua vim.cmd.tabnew(); vim.fn.jobstart({"bash","-lc","echo cwd=$PWD; sleep 5"}, {term=true, cwd="/tmp"})
```
Expected: new tab opens, terminal shows `cwd=/tmp` and stays open for 5s.

If all five spikes pass, proceed to Task 1.

---

## Task 1: `nvims` Nix package

**Files:**
- Create: `pkgs/nvims/default.nix`
- Modify: `users/dev/home.base.nix` (add to `localPkgs` overlay or import directly, then add to `home.packages`)

**Step 1: Inspect existing pkgs structure**

Run: `ls /home/dev/projects/workstation/pkgs/`
Expected: shows `beads/`, `dd-cli/`, `gws/`, `pinentry-op/` (and possibly others). Pick the simplest one as a template.

Run: `cat /home/dev/projects/workstation/pkgs/dd-cli/default.nix | head -30` (or similar) to see the packaging style.

**Step 2: Write the test (manual verification spec)**

Since this is a tiny shell wrapper, no automated test framework. The "test" is a documented manual check:

After `home-manager switch`:
```bash
which nvims                    # → /nix/store/.../bin/nvims (NOT empty)
TMUX_PANE='%99' nvims --version | head -1   # → "NVIM v0.x..."
ls -la /tmp/nvim-99.sock 2>/dev/null         # → socket created (after nvim init)
```

Capture this expected output as a comment in the package's `default.nix`.

**Step 3: Write `pkgs/nvims/default.nix`**

```nix
{ pkgs }:

pkgs.writeShellApplication {
  name = "nvims";
  runtimeInputs = [ pkgs.neovim ];
  text = ''
    # nvims: nvim with a deterministic --listen socket keyed on tmux pane id.
    # Outside tmux, falls back to a per-PID socket.
    #
    # The socket path is /tmp/nvim-${TMUX_PANE#%}.sock (e.g. %17 -> /tmp/nvim-17.sock)
    # so external tools (like oc-auto-attach) can compute it from
    # `tmux list-panes -F '#{pane_id}'`.
    #
    # If the user passes their own --listen, we honor it and skip our injection.

    listen=""
    if [ -n "''${TMUX_PANE:-}" ]; then
      key="''${TMUX_PANE#%}"
      listen="/tmp/nvim-''${key}.sock"
    else
      listen="/tmp/nvim-''${RANDOM}-$$.sock"
    fi

    # If caller already passed --listen, don't override.
    for arg in "$@"; do
      case "$arg" in
        --listen|--listen=*) exec nvim "$@" ;;
      esac
    done

    exec nvim --listen "$listen" "$@"
  '';
}
```

**Step 4: Wire it into `home.base.nix`**

Find the `home.packages` block (`grep -n 'home.packages' users/dev/home.base.nix`) and the `let` block that defines `opencode-launch`. Add a sibling let-binding:
```nix
nvims = pkgs.callPackage ../../pkgs/nvims { };
```
Then add `nvims` to the `home.packages` list (alongside `opencode-launch` around line 201).

**Step 5: Apply and verify**

Run:
```bash
cd /home/dev/projects/workstation
nix run home-manager -- switch --flake .#dev
which nvims
```
Expected: `which nvims` prints a `/nix/store/.../bin/nvims` path.

**Step 6: Smoke-test inside tmux**

In a fresh tmux pane:
```bash
echo "$TMUX_PANE"
nvims --version | head -1
# In another shell:
ls /tmp/nvim-*.sock
```
Expected: a socket named `/tmp/nvim-<pane-num-without-percent>.sock` exists. Quit nvim, socket disappears.

**Step 7: Commit**

```bash
git add pkgs/nvims/default.nix users/dev/home.base.nix
git commit -m "feat(pkgs): add nvims wrapper with deterministic --listen socket

Wraps nvim with --listen /tmp/nvim-\${TMUX_PANE#%}.sock so external
tools can compute the socket path from tmux pane id. Outside tmux,
falls back to a per-PID socket.

Used by oc-auto-attach (next commit) to RPC into the right nvim."
```

---

## Task 2: nvim Lua helper module

**Files:**
- Create: `assets/nvim/lua/user/oc_auto_attach.lua`
- Modify: `assets/nvim/init.lua` (add `require("user.oc_auto_attach")`)

**Step 1: Inspect existing user modules**

Run: `ls /home/dev/projects/workstation/assets/nvim/lua/user/` and `cat /home/dev/projects/workstation/assets/nvim/init.lua` to see how other modules are structured and required.

**Step 2: Write `assets/nvim/lua/user/oc_auto_attach.lua`**

```lua
-- oc_auto_attach.lua
--
-- External RPC entrypoint for oc-auto-attach (see pkgs/oc-auto-attach).
-- Called from outside via:
--
--   nvim --server <sock> --remote-expr \
--     'luaeval("require(\"user.oc_auto_attach\").open(_A)",
--              {sid="ses_...", dir="/abs/path", url="http://127.0.0.1:4096"})'
--
-- The dir field MUST be the exact session.directory from
-- `GET /session/<id>` (NOT the collapsed project root). This avoids known
-- `opencode attach --session` cwd-mismatch bugs.

local M = {}

--- Open a new tab with `opencode attach` running in a terminal buffer.
--- @param opts table  { sid: string, dir: string, url: string }
--- @return integer 1  (so --remote-expr has something to print)
function M.open(opts)
  vim.schedule(function()
    -- Defensive: validate fields.
    if type(opts) ~= "table" then return end
    if type(opts.sid) ~= "string" or not opts.sid:match("^ses_[A-Za-z0-9]+$") then
      vim.notify("oc_auto_attach: invalid sid", vim.log.levels.ERROR)
      return
    end
    if type(opts.dir) ~= "string" or opts.dir == "" then
      vim.notify("oc_auto_attach: invalid dir", vim.log.levels.ERROR)
      return
    end
    if type(opts.url) ~= "string" or opts.url == "" then
      vim.notify("oc_auto_attach: invalid url", vim.log.levels.ERROR)
      return
    end

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

**Step 3: Wire into init**

Find the line in `assets/nvim/init.lua` that does `require("user.tabby")` (or similar). Add right after:
```lua
require("user.oc_auto_attach")
```

**Step 4: Apply and verify**

Run: `nix run home-manager -- switch --flake .#dev` (deploys nvim assets via home.file).

In an existing nvim, source the new module:
```vim
:lua print(vim.inspect(require("user.oc_auto_attach")))
```
Expected: prints a table with an `open` function.

**Step 5: End-to-end test inside one nvim**

In an nvim, find an active session id (`:!opencode-send --list`), then call:
```vim
:lua require("user.oc_auto_attach").open({sid="ses_REAL_ID_HERE", dir="/home/dev/projects/pigeon", url="http://127.0.0.1:4096"})
```
Expected: a new tab opens with `opencode attach ...` running. Tab label (via tabby) shows the session title once the TUI sets `b:term_title`.

Close the test tab with `:tabclose` after confirming.

**Step 6: Commit**

```bash
git add assets/nvim/lua/user/oc_auto_attach.lua assets/nvim/init.lua
git commit -m "feat(nvim): add oc_auto_attach Lua helper

Exposes M.open({sid, dir, url}) for external RPC callers (oc-auto-attach
in the next commit). Uses jobstart with explicit cwd=opts.dir to dodge
known opencode attach --session cwd-mismatch bugs.

Validates sid against ^ses_[A-Za-z0-9]+\$ before interpolation."
```

---

## Task 3: `oc-auto-attach` Nix package — skeleton + session lookup

**Files:**
- Create: `pkgs/oc-auto-attach/default.nix`
- Create (effectively): the script body lives in `text = ...` of `default.nix`. Optionally split into a separate `.sh` file referenced by the nix expression — pick whichever matches existing pkgs style.

This is a multi-step package, so we split it into Tasks 3, 4, 5. Task 3 is just the skeleton + session lookup with retries.

**Step 1: Inspect template package**

Run: `cat /home/dev/projects/workstation/pkgs/dd-cli/default.nix` (or the closest analogue) for the writeShellApplication style with non-trivial logic.

**Step 2: Write `pkgs/oc-auto-attach/default.nix` (skeleton)**

```nix
{ pkgs }:

pkgs.writeShellApplication {
  name = "oc-auto-attach";
  runtimeInputs = with pkgs; [
    curl
    jq
    tmux
    coreutils      # timeout
    neovim         # nvim --server
  ];
  text = ''
    # oc-auto-attach <session-id>
    #
    # Auto-attach a launched OpenCode session to the right project's nvim,
    # inside tmux. See docs/plans/2026-04-22-launch-auto-attach-design.md.
    #
    # Behavior:
    #   1. Wait for the session to be visible at GET /session/<id> with
    #      a non-empty .directory.
    #   2. Compute project key (collapse ~/projects/<P>/.worktrees/<W>/...
    #      -> ~/projects/<P>).
    #   3. Find or create the matching tmux window with nvim.
    #   4. Compute the nvim socket from the pane id.
    #   5. Wait for nvim RPC + helper module to be ready.
    #   6. RPC into nvim to open a new tab with `opencode attach`.
    #
    # Any failure logs to stderr and exits 0 (we don't want to break the
    # launcher on display issues).

    OPENCODE_URL="''${OPENCODE_URL:-http://127.0.0.1:4096}"

    log() {
      printf '[oc-auto-attach] %s\n' "$*" >&2
    }

    if [ $# -ne 1 ]; then
      log "usage: oc-auto-attach <session-id>"
      exit 0
    fi
    sid="$1"

    # Hard-validate session id before any shell interpolation.
    if ! [[ "$sid" =~ ^ses_[A-Za-z0-9]+$ ]]; then
      log "invalid session id: $sid"
      exit 0
    fi

    # Step 1: wait for session to be visible with a non-empty directory.
    session_dir=""
    if ! session_dir="$(timeout 5 bash -c '
      sid="$1"
      url="$2"
      while :; do
        body="$(curl -sf "$url/session/$sid" 2>/dev/null || true)"
        dir="$(printf "%s" "$body" | jq -r ".directory // empty" 2>/dev/null || true)"
        if [ -n "$dir" ] && [ "$dir" != "null" ]; then
          printf "%s" "$dir"
          exit 0
        fi
      done
    ' _ "$sid" "$OPENCODE_URL")"; then
      log "session $sid not ready after 5s; giving up"
      exit 0
    fi

    if [ -z "$session_dir" ]; then
      log "session $sid has no directory; giving up"
      exit 0
    fi

    log "session $sid dir=$session_dir"

    # TODO (Task 4): project key + tmux window discovery
    # TODO (Task 5): RPC into nvim
  '';
}
```

**Step 3: Wire into `home.base.nix`**

Add `oc-auto-attach = pkgs.callPackage ../../pkgs/oc-auto-attach { };` to the `let` block, and add `oc-auto-attach` to `home.packages`.

**Step 4: Apply and smoke-test session lookup**

```bash
nix run home-manager -- switch --flake .#dev
which oc-auto-attach
sid="$(curl -s http://127.0.0.1:4096/session | jq -r '.[0].id')"
oc-auto-attach "$sid"
```
Expected: stderr shows `[oc-auto-attach] session ses_... dir=/home/dev/projects/...`. No tmux/nvim work yet (TODOs).

```bash
oc-auto-attach ses_doesnotexist1234567890
```
Expected: stderr shows `session ses_doesnotexist... not ready after 5s; giving up`, exit 0.

```bash
oc-auto-attach 'rm -rf /'
```
Expected: stderr shows `invalid session id`, exit 0. (Confirms the regex guard.)

**Step 5: Commit**

```bash
git add pkgs/oc-auto-attach/default.nix users/dev/home.base.nix
git commit -m "feat(pkgs): add oc-auto-attach skeleton with session lookup

Hard-validates sid, polls GET /session/<id> with a 5s timeout for
non-empty .directory, logs and exits 0 on any failure (so launchers
don't break). Tmux + nvim RPC follow in subsequent commits."
```

---

## Task 4: `oc-auto-attach` — project-key collapse + tmux window discovery

**Files:**
- Modify: `pkgs/oc-auto-attach/default.nix`

**Step 1: Add a small bash test harness**

Before extending the script, write a one-off bash test for the project-key regex. Save to `pkgs/oc-auto-attach/test-project-key.sh`:

```bash
#!/usr/bin/env bash
# Quick test for the project-key collapse logic.
# Run: bash test-project-key.sh

set -o errexit -o nounset -o pipefail

# Mirror the regex from default.nix
project_key() {
  local dir="$1"
  local home_re="${HOME//\//\\/}"
  if [[ "$dir" =~ ^${HOME}/projects/([^/]+)(/.*)?$ ]]; then
    printf '%s/projects/%s\n' "$HOME" "${BASH_REMATCH[1]}"
  else
    printf '%s\n' "$dir"
  fi
}

assert_eq() {
  local expected="$1" actual="$2" msg="$3"
  if [ "$expected" = "$actual" ]; then
    printf 'PASS  %s\n' "$msg"
  else
    printf 'FAIL  %s\n        expected: %s\n        actual:   %s\n' "$msg" "$expected" "$actual"
    exit 1
  fi
}

assert_eq "$HOME/projects/pigeon"          "$(project_key "$HOME/projects/pigeon")"                                     "project root"
assert_eq "$HOME/projects/pigeon"          "$(project_key "$HOME/projects/pigeon/foo/bar")"                             "subdir"
assert_eq "$HOME/projects/pigeon"          "$(project_key "$HOME/projects/pigeon/.worktrees/feature-x")"                "worktree root"
assert_eq "$HOME/projects/pigeon"          "$(project_key "$HOME/projects/pigeon/.worktrees/feature-x/foo/bar")"        "worktree subdir"
assert_eq "$HOME/projects/workstation"     "$(project_key "$HOME/projects/workstation/.worktrees/launch-auto-attach")"  "another project worktree"
assert_eq "/tmp/foo"                        "$(project_key "/tmp/foo")"                                                  "non-project path"
assert_eq "$HOME"                          "$(project_key "$HOME")"                                                     "bare home"
echo "all project-key tests passed"
```

Run: `bash pkgs/oc-auto-attach/test-project-key.sh`
Expected: all PASS.

**Step 2: Replace the Task 3 TODOs with project-key + tmux discovery**

Edit `pkgs/oc-auto-attach/default.nix`, replacing the `# TODO (Task 4): ...` block with:

```bash
    # Step 2: compute project key for editor routing.
    # Collapse ~/projects/<P>/(/.worktrees/<W>)?(/.*)? -> ~/projects/<P>.
    if [[ "$session_dir" =~ ^''${HOME}/projects/([^/]+)(/.*)?$ ]]; then
      project_key="''${HOME}/projects/''${BASH_REMATCH[1]}"
      window_name="''${BASH_REMATCH[1]}"
    else
      project_key="$session_dir"
      window_name="$(basename "$session_dir")"
    fi
    log "project_key=$project_key window_name=$window_name"

    # Step 3: find an existing tmux pane that's running nvim with cwd
    # equal to (or a descendant of) project_key. Prefer exact match.
    pane_id=""
    while IFS='|' read -r p_id p_cmd p_path; do
      [ "$p_cmd" = "nvim" ] || continue
      if [ "$p_path" = "$project_key" ]; then
        pane_id="$p_id"
        break  # exact match wins
      fi
      if [[ "$p_path" == "$project_key"/* ]] && [ -z "$pane_id" ]; then
        pane_id="$p_id"  # remember as fallback, keep looking for exact
      fi
    done < <(tmux list-panes -a -F '#{pane_id}|#{pane_current_command}|#{pane_current_path}' 2>/dev/null || true)

    if [ -n "$pane_id" ]; then
      log "matched existing pane $pane_id"
    else
      # Create a new tmux window with nvims. -P -F gives us the pane id.
      if ! command -v tmux >/dev/null 2>&1; then
        log "no tmux available; cannot create new window"
        exit 0
      fi
      # Are we inside a tmux session at all? If not, there's no useful place
      # to put the window. (oc-auto-attach is meaningful only in a graphical
      # tmux+nvim workflow.)
      if [ -z "''${TMUX:-}" ] && ! tmux has-session 2>/dev/null; then
        log "no tmux server running; skipping"
        exit 0
      fi
      nvims_path="$(command -v nvims || true)"
      if [ -z "$nvims_path" ]; then
        log "nvims not found on PATH; skipping"
        exit 0
      fi
      pane_id="$(tmux new-window -d -P -F '#{pane_id}' \
        -c "$project_key" -n "$window_name" "$nvims_path" 2>/dev/null || true)"
      if [ -z "$pane_id" ]; then
        log "tmux new-window failed; giving up"
        exit 0
      fi
      log "created new pane $pane_id (window $window_name)"
    fi

    # Step 4: compute socket path.
    sock="/tmp/nvim-''${pane_id#%}.sock"
    log "socket=$sock"

    # TODO (Task 5): readiness probe + RPC
```

**Step 3: Apply and smoke-test discovery**

```bash
nix run home-manager -- switch --flake .#dev
# Use a session in a project where you have an nvim open:
sid="$(curl -s http://127.0.0.1:4096/session | jq -r '.[0].id')"
oc-auto-attach "$sid"
```
Expected: stderr shows `matched existing pane %N` and `socket=/tmp/nvim-N.sock`. No tab is opened yet.

Test the create-window fallback by launching a session in a project you don't have open:
```bash
opencode-launch ~/projects/internal-frontends "echo hello"   # pick any project without a nvim window
```
Run `oc-auto-attach <new-sid>` (or rely on the wired-in call from Task 6 once we get there). Expected: a new tmux window appears with nvims running, and stderr logs `created new pane %N`.

Test "non-project" path:
```bash
opencode-launch /tmp "echo hi"
```
Expected: a new tmux window named `tmp` appears (window_name = basename).

**Step 4: Commit**

```bash
git add pkgs/oc-auto-attach/default.nix pkgs/oc-auto-attach/test-project-key.sh
git commit -m "feat(oc-auto-attach): project-key collapse + tmux pane discovery

Worktree paths (~/projects/<P>/.worktrees/<W>/...) collapse to the
project-root nvim. Exact pane_current_path match wins; descendant
match is the fallback. Falls back to creating a new tmux window with
nvims when no match exists, capturing the pane id via
tmux new-window -P -F '#{pane_id}'.

Includes a standalone test harness for the regex
(test-project-key.sh)."
```

---

## Task 5: `oc-auto-attach` — readiness probe + RPC into nvim

**Files:**
- Modify: `pkgs/oc-auto-attach/default.nix`

**Step 1: Replace the Task 4 TODO with the RPC steps**

Append (replacing `# TODO (Task 5): ...`):

```bash
    # Step 5: wait until the nvim RPC server is ready AND the helper
    # module has been required.
    if ! timeout 5 bash -c '
      sock="$1"
      until [ -S "$sock" ] && \
            nvim --server "$sock" --remote-expr \
              "luaeval(\"select(1, pcall(require, \\\"user.oc_auto_attach\\\")) and 1 or 0\")" \
              2>/dev/null | grep -qx 1
      do :; done
    ' _ "$sock"; then
      log "nvim at $sock not ready (or helper not loaded) after 5s; giving up"
      exit 0
    fi
    log "nvim at $sock is ready"

    # Step 6: invoke the helper. We build a Lua table literal carefully:
    # session_dir comes from server (trusted-ish but escape single quotes),
    # sid is regex-validated, url is from env or default.
    # Lua single-quoted strings: ' -> \047 escape, but easier: use [[ ... ]]
    # via vim.fn.escape. Simplest robust pattern: encode as JSON with jq,
    # decode with vim.json.decode on the nvim side.
    payload="$(jq -nc \
      --arg sid "$sid" \
      --arg dir "$session_dir" \
      --arg url "$OPENCODE_URL" \
      '{sid:$sid, dir:$dir, url:$url}')"

    # luaeval receives _A as the second arg. We pass the JSON string and
    # decode it inside Lua to bulletproof against quoting.
    expr="luaeval(\"require('user.oc_auto_attach').open(vim.json.decode(_A))\", $(printf '%s' "$payload" | jq -Rs '.'))"

    if ! nvim --server "$sock" --remote-expr "$expr" >/dev/null 2>&1; then
      log "nvim RPC call failed; giving up"
      exit 0
    fi

    log "tab opened in pane $pane_id for $sid"
```

**Step 2: Apply and end-to-end test**

```bash
nix run home-manager -- switch --flake .#dev
# Verify a fresh launch + auto-attach round-trip:
opencode-launch ~/projects/pigeon "echo hello world"
# (or run oc-auto-attach manually with the printed sid if Task 6 isn't wired yet)
```

Expected:
- Within ~1s, a new tab appears in the pigeon nvim window.
- The tab's terminal shows `opencode attach http://127.0.0.1:4096 --session ses_...` connecting and rendering the TUI.
- Once the TUI renders, the tabby tab label updates to `OC | <session title>`.
- The session is fully live — type into it, observe responses.

**Step 3: Stress / edge tests**

Run with a non-existent project:
```bash
opencode-launch /tmp/scratch "echo a"
```
Expected: a brand new tmux window named `scratch` opens with nvims, and the auto-attach tab opens inside it.

Run with a worktree:
```bash
mkdir -p ~/projects/pigeon/.worktrees/test-auto-attach
opencode-launch ~/projects/pigeon/.worktrees/test-auto-attach "echo from worktree"
```
Expected: the auto-attach tab appears in the *project-root* pigeon nvim (not a new window for the worktree).

**Step 4: Commit**

```bash
git add pkgs/oc-auto-attach/default.nix
git commit -m "feat(oc-auto-attach): nvim readiness probe + RPC handoff

Bounded 5s timeout waits for both socket existence and the helper
module being require-able. Then RPCs into nvim with a
JSON-encoded payload (decoded via vim.json.decode on the nvim side)
to dodge all shell-quoting hazards in the session id, dir, and url."
```

---

## Task 6: Wire `oc-auto-attach` into `opencode-launch`

**Files:**
- Modify: `users/dev/home.base.nix` (the `opencode-launch` writeShellApplication block, around line 7-72)

**Step 1: Edit the launcher**

Find the block ending with the final `echo` lines. Before the `echo "Session launched: ..."`, add:
```bash
      # Auto-attach to nvim+tmux if we're on a host with a graphical workflow.
      # Backgrounded so the launch returns immediately. Missing oc-auto-attach
      # (e.g. cloudbox headless) is silently tolerated by the launcher itself.
      if command -v oc-auto-attach >/dev/null 2>&1; then
        oc-auto-attach "$session_id" >/dev/null 2>&1 &
        disown
      fi
```

**Step 2: Apply and verify**

```bash
nix run home-manager -- switch --flake .#dev
opencode-launch ~/projects/pigeon "tab opened automatically? round-trip test"
```
Expected: stdout still prints `Session launched: ses_...`, AND within ~1s a new tab appears in the pigeon nvim with the live attach.

Verify the launcher returns promptly (doesn't block on auto-attach):
```bash
time opencode-launch ~/projects/pigeon "timing test"
```
Expected: real time < 1s (the curl roundtrip + minor overhead). The auto-attach work happens in the background.

**Step 3: Commit**

```bash
git add users/dev/home.base.nix
git commit -m "feat(opencode-launch): trigger auto-attach in the background

After the session is created, fire \`oc-auto-attach \$session_id &\` so
the matching nvim+tmux opens a tab without manual ceremony. Gated on
\`command -v oc-auto-attach\` so headless hosts (cloudbox) keep working
exactly as before."
```

---

## Task 7: Wire `oc-auto-attach` into pigeon `/launch`

**Files:**
- Modify: `/home/dev/projects/pigeon/packages/daemon/src/worker/launch-ingest.ts`
- Possibly: a unit test if there's one for `launch-ingest`.

**Step 1: Inspect existing test**

Run: `cat /home/dev/projects/pigeon/packages/daemon/test/launch-ingest.test.ts`
Identify how the test stubs `opencodeClient` and what assertions look like.

**Step 2: Write a failing test for the new spawn behavior**

Add to `launch-ingest.test.ts`:

```ts
it("spawns oc-auto-attach with the session id after sendPrompt", async () => {
  const spawnCalls: Array<[string, string[], unknown]> = [];
  // Stub child_process.spawn for this test. (How: depends on existing test's
  // injection mechanism. If launch-ingest doesn't take a spawn factory,
  // we'll need to add one in step 3 and pass a stub here.)

  const opencodeClient = {
    healthCheck: async () => true,
    createSession: async () => ({ id: "ses_test123" }),
    sendPrompt: async () => {},
  };
  const replies: string[] = [];
  const sendTelegramReply = async (_chatId: string, text: string) => { replies.push(text); };

  await ingestLaunchCommand({
    commandId: "cmd1",
    directory: "~/projects/pigeon",
    prompt: "hello",
    chatId: "chat1",
    opencodeClient: opencodeClient as any,
    sendTelegramReply,
    spawn: (cmd, args) => { spawnCalls.push([cmd, args, undefined]); return { unref: () => {} } as any; },
  });

  expect(spawnCalls).toEqual([["oc-auto-attach", ["ses_test123"], undefined]]);
});

it("swallows ENOENT when oc-auto-attach is missing", async () => {
  const opencodeClient = {
    healthCheck: async () => true,
    createSession: async () => ({ id: "ses_test123" }),
    sendPrompt: async () => {},
  };
  const sendTelegramReply = async () => {};

  // spawn throws synchronously with ENOENT-like error
  const spawn = () => { const err: any = new Error("ENOENT"); err.code = "ENOENT"; throw err; };

  // Should not throw:
  await expect(
    ingestLaunchCommand({
      commandId: "cmd2",
      directory: "~/projects/pigeon",
      prompt: "hello",
      chatId: "chat1",
      opencodeClient: opencodeClient as any,
      sendTelegramReply,
      spawn: spawn as any,
    })
  ).resolves.toBeUndefined();
});
```

**Step 3: Run tests, verify they fail**

```bash
cd /home/dev/projects/pigeon
npm test -- launch-ingest
```
Expected: both new tests FAIL (spawn isn't invoked; the function doesn't accept a `spawn` parameter yet).

**Step 4: Implement: extend `LaunchCommandInput` with `spawn` factory and call it**

Edit `packages/daemon/src/worker/launch-ingest.ts`:

```ts
import { spawn as nodeSpawn, type ChildProcess } from "child_process";
// ...

export interface LaunchCommandInput {
  commandId: string;
  directory: string;
  prompt: string;
  chatId: string;
  machineId?: string;
  opencodeClient: OpencodeClient;
  sendTelegramReply: (chatId: string, text: string, entities?: TgEntity[]) => Promise<void>;
  /** Injected for tests; defaults to node child_process.spawn. */
  spawn?: (cmd: string, args: string[], opts?: any) => ChildProcess;
}

export async function ingestLaunchCommand(input: LaunchCommandInput): Promise<void> {
  // ... existing body ...

  try {
    const session = await opencodeClient.createSession(directory);
    await opencodeClient.sendPrompt(session.id, directory, prompt);
    console.log(`[launch-ingest] session started sessionId=${session.id} directory=${directory}`);

    // Auto-attach: best-effort, fire-and-forget. If oc-auto-attach is not
    // installed (e.g. cloudbox), swallow ENOENT silently.
    try {
      const spawnFn = input.spawn ?? nodeSpawn;
      const child = spawnFn("oc-auto-attach", [session.id], {
        stdio: "ignore",
        detached: true,
      });
      child.unref?.();
    } catch (err: unknown) {
      const code = (err as { code?: string })?.code;
      if (code !== "ENOENT") {
        console.warn(`[launch-ingest] auto-attach spawn failed:`, err);
      }
    }

    // ... existing sendTelegramReply call ...
  } catch (error) {
    // ... existing catch ...
  }
}
```

**Step 5: Run tests, verify they pass**

```bash
npm test -- launch-ingest
```
Expected: both new tests PASS, no existing tests broken.

**Step 6: End-to-end test via Telegram (manual)**

From your Telegram chat with the bot:
```
/launch pigeon "auto-attach round-trip via telegram"
```
Expected: usual Telegram confirmation message, AND a new tab in the pigeon nvim within ~1s.

**Step 7: Commit (in pigeon repo)**

```bash
cd /home/dev/projects/pigeon
git add packages/daemon/src/worker/launch-ingest.ts packages/daemon/test/launch-ingest.test.ts
git commit -m "feat(launch-ingest): trigger oc-auto-attach after sendPrompt

After the session is created and the prompt is dispatched, fire
\`oc-auto-attach <session-id>\` as a detached background process so
the matching nvim+tmux opens a tab without manual ceremony.

Wraps spawn in a try/catch that swallows ENOENT so hosts without
oc-auto-attach (cloudbox, anywhere headless) keep working exactly
as before. Tests inject a spawn factory."
```

---

## Task 8: Window-name dedup (small follow-up)

**Files:**
- Modify: `pkgs/oc-auto-attach/default.nix`

**Step 1: Add the dedup logic**

In Step 2's "create new tmux window" branch, before calling `tmux new-window`, check whether a window with the same name already exists in the current tmux session and reuse the first nvim pane in it if so.

```bash
      # If a window with this name already exists in the current tmux
      # session, prefer reusing it over creating yet another window.
      existing_pane="$(tmux list-panes -t ":${window_name}" -F '#{pane_id}|#{pane_current_command}' 2>/dev/null \
        | awk -F'|' '$2=="nvim" {print $1; exit}' || true)"
      if [ -n "$existing_pane" ]; then
        pane_id="$existing_pane"
        log "reusing existing window $window_name pane $pane_id"
      else
        # ... existing nvims_path / tmux new-window block ...
      fi
```

**Step 2: Smoke-test**

Manually create a window named `scratch` with nvim:
```bash
tmux new-window -n scratch -c /tmp 'nvims'
opencode-launch /tmp "first scratch session"
opencode-launch /tmp "second scratch session"
```
Expected: both tabs land in the same `scratch` window, no duplicate windows created.

**Step 3: Commit**

```bash
git add pkgs/oc-auto-attach/default.nix
git commit -m "fix(oc-auto-attach): reuse existing window with same name

Avoids tmux window proliferation when launching multiple sessions in
the same non-projects directory (e.g. /tmp). The existing-pane
discovery already handles ~/projects/* well via project_key matching
on pane_current_path."
```

---

## Task 9: Skill updates

**Files:**
- Modify: `assets/opencode/skills/opencode-launch/SKILL.md`
- Modify: `assets/opencode/skills/opencode-send/SKILL.md`

**Step 1: Read the current opencode-launch skill**

Run: `cat /home/dev/projects/workstation/assets/opencode/skills/opencode-launch/SKILL.md`

**Step 2: Add an "Auto-attach" section to opencode-launch SKILL**

Insert (after "What This Does" or similar):

```markdown
## Auto-Attach to nvim+tmux

If you're on a host with `oc-auto-attach` installed (devbox, macOS — anywhere
graphical), `opencode-launch` automatically opens the new session as a tab
in the matching project's nvim, inside tmux. No manual `opencode attach`
needed.

How it picks the nvim:
- Reads the session's directory from `GET /session/<id>`.
- Collapses worktree paths: `~/projects/<P>/.worktrees/<W>/...` →
  `~/projects/<P>`. Sessions in worktrees land in the project-root nvim.
- Finds the tmux pane running `nvim` whose `pane_current_path` matches.
- If no match: creates a new tmux window in the project root with `nvims`.

For this to work, you must run nvim via `nvims` (not `nvim`) inside tmux.
`nvims` is a wrapper that injects `--listen /tmp/nvim-${TMUX_PANE#%}.sock`
so external tools can find your nvim. See `nvims --help` (or read
`pkgs/nvims/default.nix`).

Cloudbox and other headless hosts skip auto-attach silently — `opencode-launch`
checks for `command -v oc-auto-attach` and no-ops if missing.
```

**Step 3: Add a "Use `opencode attach`, not `opencode -s`" note to opencode-send SKILL**

Insert (e.g. under "Receiving Side" or as a new "Attaching from another terminal" subsection):

```markdown
## Attaching to a Pigeon-Routed Session

When attaching to a session that's owned by `opencode serve` (which is the case
for any session reached by pigeon's auto-route), use `opencode attach`, not
`opencode -s`:

```bash
opencode attach http://127.0.0.1:4096 --session ses_FOO
```

`opencode -s ses_FOO` spawns a NEW worker process with its own in-process
server and an isolated event bus. It loads the session row from the shared
SQLite at startup but never receives live updates from the long-running
`opencode serve` — meaning swarm messages, prompt_async deliveries, and
remote prompts won't appear until you quit and reopen the TUI.

`opencode attach` is a thin client that subscribes to opencode-serve's `/event`
SSE stream, so everything flows live.

If you use `opencode-launch`, you don't need to attach manually — see the
auto-attach section in the `opencode-launch` skill.
```

**Step 4: Commit**

```bash
cd /home/dev/projects/workstation
git add assets/opencode/skills/opencode-launch/SKILL.md assets/opencode/skills/opencode-send/SKILL.md
git commit -m "docs(skills): document auto-attach + opencode attach vs -s

opencode-launch now auto-attaches launched sessions to nvim+tmux on
hosts with oc-auto-attach installed. Document the behavior and the
requirement to use \`nvims\` instead of \`nvim\`.

Also flag the trap that \`opencode -s ses_FOO\` does NOT subscribe
to opencode-serve's event bus, so pigeon-delivered messages don't
appear live. Use \`opencode attach\` instead."
```

---

## Task 10: Final integration sweep

**Step 1: Verify all artifacts deployed**

```bash
which nvims oc-auto-attach
ls /tmp/nvim-*.sock 2>/dev/null   # one per nvims-running pane
nvim --server "$(ls /tmp/nvim-*.sock | head -1)" --remote-expr 'luaeval("(require\"user.oc_auto_attach\") and 1 or 0")'
```
Expected: both binaries on PATH; sockets exist; the luaeval prints `1`.

**Step 2: Three end-to-end scenarios**

1. **Existing project nvim:**
   ```bash
   opencode-launch ~/projects/pigeon "scenario 1: existing project nvim"
   ```
   Verify: tab appears in pigeon's nvim window.

2. **Worktree collapse:**
   ```bash
   opencode-launch ~/projects/pigeon/.worktrees/feature-x "scenario 2: worktree"
   ```
   (Create the worktree first if it doesn't exist: `git -C ~/projects/pigeon worktree add ...`.)
   Verify: tab appears in the SAME pigeon nvim window as scenario 1, NOT a new window.

3. **No project nvim, full magic fallback:**
   ```bash
   # Pick a project you don't have open in tmux. Confirm with `tmux list-windows`.
   opencode-launch ~/projects/data-infra "scenario 3: full magic"
   ```
   Verify: a new tmux window appears named `data-infra`, with nvims running, and the auto-attach tab inside.

4. **Telegram round-trip:**
   ```
   /launch lgtm "scenario 4: telegram"
   ```
   Verify: usual Telegram message, AND auto-attach tab appears.

**Step 3: Verify cloudbox is not broken (if applicable)**

If you have ssh access to cloudbox:
```bash
ssh cloudbox "command -v oc-auto-attach || echo not-installed"
ssh cloudbox "opencode-launch ~/projects/pigeon 'cloudbox no-op test'"
```
Expected: `not-installed` (we didn't add oc-auto-attach to cloudbox), but the launch itself succeeds and prints the session id.

**Step 4: Push everything**

Both repos:
```bash
cd /home/dev/projects/workstation
git pull --rebase && git push

cd /home/dev/projects/pigeon
git pull --rebase && git push
```

**Step 5: Verify with `git status`**

```bash
cd /home/dev/projects/workstation && git status   # clean, "up to date with origin"
cd /home/dev/projects/pigeon && git status        # same
```

---

## Done criteria

- [ ] Spike 1-5 all pass.
- [ ] `which nvims` and `which oc-auto-attach` both resolve.
- [ ] Lua module loads in nvim (`pcall(require, "user.oc_auto_attach")` returns true).
- [ ] Three local scenarios + Telegram scenario all open the expected tab in the expected window.
- [ ] Worktree paths collapse to project-root nvim (not a new window per worktree).
- [ ] Cloudbox launch (or any headless host) succeeds without auto-attach interference.
- [ ] Both repos pushed to origin.
- [ ] No `sleep` introduced anywhere.
