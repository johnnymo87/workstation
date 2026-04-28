# Design: Fix frozen attach TUIs (workstation-gsi)

Status: Draft, ready to plan
Date: 2026-04-28
Bead: workstation-gsi (P1, OPEN)

## Problem

Restored opencode attach TUIs render NO new updates after restoration. TUI display stays
frozen at pre-restore state even while session is fully alive server-side. User-impact:
"dead in the water" — users can interact with restored sessions ONLY via the
Telegram → pigeon → opencode-serve bridge; the in-tmux nvim TUI itself is unusable.

## Root cause (confirmed via systematic debugging + live experiment 2026-04-28)

The TUI's event-filter at `packages/opencode/src/cli/cmd/tui/context/event.ts:28`
silently drops session events when `event.directory !== project.instance.directory()`.

`project.instance.directory()` is sourced from `sdk.client.path.get({ workspace })`. With
no directory hint, opencode-serve's middleware falls back to `process.cwd()` — which
on cloudbox is `/home/dev` (set by `WorkingDirectory=/home/dev` in
`/etc/systemd/system/opencode-serve.service`). Bus.publish unconditionally emits to
GlobalBus with `event.directory = InstanceState.directory` = the actual session's
directory (e.g., `/home/dev/projects/workstation`). The two never match. Events are
silently dropped at line 28. TUI never re-renders. Frozen.

End-to-end causal chain (10 hops) is documented in the bead description.

### Empirical evidence

- **SSE works**: 25-second SSE capture during `opencode run --attach ...` showed full
  event flow (`session.created`, `session.updated`, `message.updated`,
  `message.part.updated`, `session.status` busy/idle, `session.error`).
- **Live experiment** 2026-04-28 ~10:50:
  - **A**: bare tmux + `opencode attach <url> --session <session_in_/home/dev>` (no
    `--dir`) → **renders correctly** (control). User-confirmed.
  - **B**: bare tmux + `opencode attach <url> --session <session_in_workstation>` (no
    `--dir`) → **frozen** (test). User-confirmed.
  - **C**: bare tmux + `opencode attach <url> --session <session_in_workstation>
    --dir /home/dev/projects/workstation` → **renders correctly**. User-confirmed.
- **Natural data point**: `ses_22a51d67effe9LMwebaY8mKbSN` (lgtm-spawned, in
  `/home/dev/projects/mono/.worktrees/pr-2884`) was already frozen as observed by
  user. Attach process spawn args confirmed via ps: `opencode attach
  http://127.0.0.1:4096 --session ses_22a51d67e...` — no `--dir`.

### Disproven hypotheses (from original bead)

- H1: opencode-serve doesn't broadcast events to /event SSE — WRONG. SSE emits
  perfectly. Original "8s of silence" evidence was shorter than the 10s heartbeat
  interval and predates active session traffic.
- H2: SSE filter excludes by sessionID — WRONG. /event is unfiltered global stream.
- H3: One of the 5 opencode-patched fork patches breaks SSE — WRONG. None touch
  event.ts or SSE pipeline.
- H4: Race — attach client SSE registers before session preloaded — WRONG. Filter is
  permanent dispatch decision, not startup race.
- H5 (this debugging session): standalone TUI competing for the session causes the
  freeze — WRONG. User-confirmed timeline: original attach TUI was frozen FIRST
  (only opencode-serve and attach client in play); user spawned `opencode -s sid`
  AFTERWARD to recover usability.

### Upstream issue status

- **#22588**: cross-instance agent messages dropped via workspace-filter early-return
  bug at `event.ts:25`. Different code branch (workspace), proposed fix doesn't help
  our case.
- **#11522** (CLOSED, v1.1.48): SSE events not emitted on global /event when `--dir`
  is used. Empirically NOT reproduced on 1.14.28 — Test C with `--dir` rendered
  correctly. So #11522 is either fixed or doesn't apply to our setup.
- **#5380, #8981, #11046**: about `opencode attach --dir` issues with REMOTE servers
  (different host than where directories live). Not applicable to our localhost case.

## Fix plan (Option C: ship both A and B together)

### Fix A: Workflow fix (immediate, deploy via home-manager)

Modify `assets/nvim/lua/user/oc_auto_attach.lua` and `pkgs/oc-auto-attach/default.nix`
to spawn `opencode attach <url> --session <sid> --dir <session.directory>` instead of
the current `opencode attach <url> --session <sid>`.

**Where**:

`assets/nvim/lua/user/oc_auto_attach.lua:40-46`:
```lua
vim.fn.jobstart({
  "opencode", "attach", opts.url,
  "--session", opts.sid,
}, {
  term = true,
  cwd = opts.dir,
})
```

becomes:
```lua
vim.fn.jobstart({
  "opencode", "attach", opts.url,
  "--session", opts.sid,
  "--dir", opts.dir,
}, {
  term = true,
  cwd = opts.dir,
})
```

(`opts.dir` is already the session's directory, validated as a real directory at
line 26-29.)

`pkgs/oc-auto-attach/default.nix`: review / update the comment header at line 12
that says `# `opencode attach --session` cwd-mismatch bugs.` to reflect the new
understanding (the dir mismatch was inside the TUI's event filter, not the attach
client itself).

**Pros**:
- Tiny diff (1 line of lua + comment update).
- No opencode-patched maintenance burden.
- Survives opencode upgrades cleanly.
- Restored TUIs work immediately on next reset.

**Cons**:
- Doesn't fix manual `opencode attach <url> --session <sid>` invocations from a
  cwd that doesn't match the session's directory.

**Verification plan**:
1. `nix run home-manager -- switch --flake .#cloudbox`.
2. `pkill -f 'opencode attach.*ses_22a51d67'` to kill the existing frozen lgtm
   attach (the user can then re-trigger lgtm or wait for the next /reset to test
   organically).
3. Wait for next `oc-auto-attach` invocation (or trigger one via `lgtm` re-run).
4. User confirms the new attach TUI renders updates.

### Fix B: opencode-patched 6th patch (durable, follow-up)

Add `~/projects/opencode-patched/patches/attach-session-directory.patch` that
makes the TUI's event filter session-aware.

**Three possible patch points** (need to pick one based on least-invasive design):

- **B1**: Patch `cli/cmd/tui/context/event.ts` to also accept events whose
  `event.directory` matches the navigated session's directory. Requires the TUI
  context to know "the current session" — currently event.ts only has access to
  `project.instance.directory()`. Would need to thread session context into useEvent
  or read it from the route store.

- **B2**: Patch `cli/cmd/tui/context/project.tsx:36-47` so that `sync()` passes the
  current-session's directory as a hint when calling `path.get({ workspace,
  directory })`. Requires the SDK client to support a directory parameter on
  `path.get()` (currently it only sends header/query if SDK was constructed with
  `directory`). Or, simpler: read session.directory from the route store and call
  `sdk.client.path.get({ workspace }, { headers: { 'x-opencode-directory': ... } })`.

- **B3**: Patch `cli/cmd/tui/routes/session/index.tsx:184-220` so that after the
  session.get returns, also update SDK directory dynamically. Currently SDK
  directory is set once at construction and not mutable.

**Recommendation**: B2 is cleanest semantically (re-fetch path with the right
context per-session). But all three need design care to not break workspace mode
(which has its own directory logic that might disagree with session.directory).

**Pros**:
- Fixes ALL attach scenarios, including manual `opencode attach <url> --session <sid>`
  from any cwd.
- One source-of-truth fix; no workflow knowledge required.

**Cons**:
- Another patch to maintain through opencode upgrades.
- Need careful design to avoid breaking workspace mode.
- 5-line minimum, possibly more.

**Verification plan**:
1. Rebuild `opencode-patched` with the new patch applied.
2. Update `users/dev/home.base.nix` to point to the new opencode-patched release/sha
   (auto-update workflow may handle this if we push an opencode-patched release; or
   we can pin to a local build for testing first).
3. `nix run home-manager -- switch --flake .#cloudbox`.
4. Test manually: `opencode attach http://127.0.0.1:4096 --session
   ses_in_some_subdir` from `/home/dev` (no --dir). Should render.
5. Test C re-do (with --dir): should still render.
6. User-orchestrator session through Telegram should also render in TUI.

### Order of operations

1. **Today**: Implement and deploy Fix A. Restored TUIs from oc-auto-attach work
   immediately.
2. **Soon (separate session)**: Implement Fix B as opencode-patched patch. Submit PR
   to anomalyco/opencode if that fork accepts upstream contributions.

## Out of scope

- workstation-io7 (oc-auto-attach window-name shorthand) — separate UX bug, not
  related to freeze.
- workstation-dfx (nvim treesitter init error) — separate blocker for nvim-helper
  load; orthogonal to the attach freeze.
- The standalone-TUI `opencode -s sid` mode is unaffected (it bypasses opencode-serve
  entirely via in-process worker + RPC bridge to `http://opencode.internal`). No fix
  needed there.

## Risks

- **A interaction with #11522**: empirically not reproduced on 1.14.28 (Test C
  worked). Risk is low. If a future opencode upgrade reintroduces #11522, Fix A
  would break and we'd need to back it out or implement Fix B fast.
- **Rate-limit clutter**: my SSE-emission verification experiment surfaced an
  Anthropic API rate-limit error ("Third-party apps now draw from your extra usage,
  not your plan limits"). This affects the user's day-to-day work but is orthogonal
  to the attach-freeze bug and should be addressed separately if it persists.
