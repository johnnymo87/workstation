---
name: understanding-workspace-reset
description: Use when acting as the morning recommendation agent after a nightly workspace reset (it runs headless from ~, outside the workstation repo), or when debugging from any project why an opencode session did or didn't land in /tmp/reset-workspace-last-manifest.txt. For the full mechanism and operations, defer to the workstation repo-local `resetting-workspace` skill.
---

# Understanding Workspace Reset (consumer view)

Thin, system-wide companion to the workstation repo-local skill
**`resetting-workspace`**
(`~/projects/workstation/.opencode/skills/resetting-workspace/SKILL.md`), which
is the canonical, in-depth reference (nightly systemd unit, cgroup-survival
self-detach, capture internals, maintenance, caveats).

This skill exists only because the **morning recommendation agent runs headless
from `~`**, where that repo-local skill is NOT auto-discovered. Keep this for the
load-bearing facts you need from outside the repo; read the repo-local one when
you need depth or are changing the reset machinery.

## Load-bearing facts

- **The manifest == the live tabs in your `main` tmux session**, snapshotted the
  instant `reset-workspace` ran. It is NOT "all sessions" and NOT "all TUIs."
- The opencode API has **no openness signal**: `GET /session/<id>` returns
  title/dir/cost/timestamps with no attached/live flag, and `GET /session` lists
  every persisted session (within retention), not open ones. **The manifest is
  the only authority on what was open** — you cannot reconstruct it from the API.
- **Reopen with `oc-auto-attach --tmux-session main <sid>`.** Always pass
  `--tmux-session main`: the agent is headless (not attached to tmux), so a bare
  invocation drops the tab into whatever session tmux deems "current" instead of
  reliably in `main`.

## "Why isn't my session in the manifest?" checklist

A session is excluded if it was any of:
1. **Headless** — `opencode serve` / API-only, or `opencode-launch` on a
   headless host where its auto-attach to `main` is silently skipped.
2. A TUI in a **non-`main`** tmux session (e.g. lgtm review tabs launch with
   `--tmux-session lgtm`).
3. An **orphaned** attach client — pane was killed, process reparented to init,
   so it's under no `main` pane.
4. Present only if a `=main` session existed at snapshot time; otherwise the
   whole manifest is empty by design.
5. Captured but **deleted** afterward → now returns `NotFoundError` (a true
   blind spot; you can't recover what it was).

Corollary for the two launch paths:
- `oc-auto-attach <sid>` defaults to `--tmux-session main`, so it lands in `main`
  and **is** captured next reset (unless you override to another session).
- `opencode-launch` creates a **headless** session *and* auto-fires
  `oc-auto-attach --tmux-session main`, so on a graphical host it gets a `main`
  TUI and **is** captured; on a headless host it is **not**.

## Morning recommendation agent runbook

The full prompt is baked into `reset-workspace`. In order:
1. Read `/tmp/reset-workspace-last-manifest.txt` (one sid per line). Missing or
   empty → message "Nightly reset complete, no sessions to recommend." and exit.
2. Enrich each sid: `GET /session/<sid>` for title/dir/last-update; optionally
   `GET /session/<sid>/message` to judge mid-task vs wrapped-up.
3. Send a short, opinionated, **project-grouped, numbered** Telegram message
   calling out finished (PR landed / question resolved) vs mid-flight work.
4. Ask via the question tool; accept free-form (`1,3,5`, `all`, `none`,
   `the mono ones`).
5. For each chosen sid: `oc-auto-attach --tmux-session main <sid>`, run
   **sequentially** — mono worktrees collapse to one `mono` nvim window and
   racing window/socket creation is flaky.
