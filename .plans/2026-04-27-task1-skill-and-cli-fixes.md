# Task 1: Skill + CLI fixes for swarm-messaging mental model

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Correct four pieces of misinformation in the `swarm-messaging` and `opencode-send` skills, and upgrade `opencode-send --list` to show sessions across ALL projects (not just the calling cwd's project).

**Architecture:** Three changes:
1. Edit `assets/opencode/skills/swarm-messaging/SKILL.md` — add health-check snippet with correct port, clarify pigeon's pre-flight resolves typos despite raw 204s, document `handed_off_at` as the positive delivery signal.
2. Edit `assets/opencode/skills/opencode-send/SKILL.md` — same corrections + replace the "wrappers hide sessions" mental model with the truth (per-project filtering on `:4096`).
3. Edit `users/dev/home.base.nix` — change `opencode-send --list` to call `GET /experimental/session` (cross-project) instead of `GET /session` (project-scoped).

After Nix rebuild + home-manager switch, the skills auto-deploy to `~/.config/opencode/skills/` and the new `opencode-send` lands in `~/.local/bin/`.

**Tech Stack:** Markdown (skills), bash + curl + jq (CLI), Nix home-manager (deployment).

---

## Verified facts (do not re-investigate)

These were established in the brainstorming phase via direct probes against the
running daemon. Don't rebuild assumptions from scratch.

- **Pigeon health endpoint:** `GET http://127.0.0.1:4731/health` returns
  `{"ok":true,"service":"pigeon-daemon"}`. The default port is hardcoded as
  `DEFAULT_PORT = 4731` in
  `~/projects/pigeon/packages/daemon/src/config.ts`. `$PIGEON_DAEMON_URL`
  overrides.
- **High ports `:41367/:41609/:41821` are TUI internal servers** (each
  `opencode` TUI process opens one for its own embedded client). Their
  `/session`, `/global/health`, `/openapi.json` all return 404. Pigeon
  doesn't talk to them; `--list` doesn't talk to them. Only `:4096`
  (the `opencode serve --port 4096` process, pid 2692107 in this
  workspace's snapshot) speaks the REST API.
- **`GET /session` is filtered to `Instance.project.id`** which is derived
  from the request's `x-opencode-directory` header. Verified at
  `~/projects/opencode/packages/opencode/src/session/session.ts:702-744`
  (function `list`, which conditions on `eq(SessionTable.project_id,
  project.id)`).
- **`GET /experimental/session`** is the cross-project endpoint. Verified
  at `~/projects/opencode/packages/opencode/src/server/routes/instance/experimental.ts:326-383`
  (operationId `experimental.session.list`, calls `Session.listGlobal`
  which omits the project_id condition). Returns up to 100 sessions
  across all projects by default; supports `?directory=`, `?roots=`,
  `?start=`, `?cursor=`, `?search=`, `?limit=`, `?archived=`.
- **Pigeon's arbiter rejects typos.** Before posting, it calls
  `registry.resolve(target)` which does `GET /session/<id>` (line 88 of
  `~/projects/pigeon/packages/daemon/src/swarm/arbiter.ts`); 404 throws,
  which the arbiter treats as a delivery error → schedules retry with
  backoff `[1, 2, 5, 15, 60]s`, MAX_ATTEMPTS=10. So a typo'd id
  eventually surfaces as a `failed` row, just slowly.
- **`handed_off_at` is the positive delivery signal.** Set by
  `storage.swarm.markHandedOff` immediately after a successful
  `opencode-client.sendPrompt` returns 2xx. Verified at
  `~/projects/pigeon/packages/daemon/src/swarm/arbiter.ts:103`. Visible
  via `GET /swarm/inbox?session=<your_id>` — see
  `~/projects/pigeon/packages/daemon/src/app.ts:172` for the JSON shape.

---

## Task 1: Patch `swarm-messaging` skill

**Files:**
- Modify: `/home/dev/projects/workstation/assets/opencode/skills/swarm-messaging/SKILL.md`

**Step 1: Read the current file**

```bash
cat /home/dev/projects/workstation/assets/opencode/skills/swarm-messaging/SKILL.md
```

**Step 2: Add a "Verifying pigeon is up" subsection at the top of "Sending"**

Insert this block immediately after the `## Sending` header and before the
existing `pigeon-send <to-session-id> "your message"` example:

````markdown
### First, verify pigeon is reachable

```bash
curl -sf "${PIGEON_DAEMON_URL:-http://127.0.0.1:4731}/health"
# expected: {"ok":true,"service":"pigeon-daemon"}
```

If this fails, the daemon isn't running — `pigeon-send` will exit 1 with
"daemon unreachable" before queuing your message. The default port is
`4731` (set in pigeon's `config.ts` as `DEFAULT_PORT`). Override with
`$PIGEON_DAEMON_URL`.

````

**Step 3: Append a "Verifying delivery" section after the existing Replay section**

After the `## Replay` block, before `## Don'ts`, add:

````markdown
## Verifying Delivery

`pigeon-send` prints `Queued msg_<id> -> ses_<target>` after the daemon
accepts the message into SQLite (HTTP 202). That confirms **acceptance**,
not delivery. To confirm **delivery to the receiving opencode session**,
inspect the inbox:

```bash
curl -sf "${PIGEON_DAEMON_URL:-http://127.0.0.1:4731}/swarm/inbox?session=$TARGET_SESSION_ID&limit=5" | jq '.messages[] | {msg_id, handed_off_at, payload: (.payload | .[0:80])}'
```

A non-null `handed_off_at` (Unix ms timestamp) means the arbiter
successfully POSTed `prompt_async` and the receiving opencode-serve
returned 2xx. This is the positive delivery signal; treat it as
proof-of-delivery.

If `handed_off_at` is null after several seconds, the arbiter is
retrying. Backoff schedule is `[1s, 2s, 5s, 15s, 60s]`, max 10 attempts.
Common causes:

- Target session id is wrong → `registry.resolve` returns 404 → retries
  exhaust → row stays in `pending` then flips to `failed`.
- opencode-serve at `:4096` is down → all targets stall.
- Target session lives in a different opencode-serve instance (not on
  `:4096`). Pigeon only talks to `:4096`; sessions owned by other
  serves are unreachable.

````

**Step 4: Update the "Don'ts" section to fix the prompt_async warning**

Find the existing "Don'ts" bullet about `prompt_async` and replace with:

```markdown
- **Don't** talk to `opencode serve`'s `/session/<id>/prompt_async` directly
  for cross-session messaging. That route races (concurrent calls from
  different `x-opencode-directory` headers bypass the per-session busy
  guard, producing 400 "does not support assistant message prefill" from
  Anthropic — see `docs/plans/2026-04-21-opencode-prefill-fix-design.md`
  for the full root cause). Always go through `pigeon-send` (or
  `opencode-send` which auto-routes). Note that `prompt_async` returns 204
  for ANY id (real or fake) on the direct path; pigeon's arbiter does its
  own pre-flight `GET /session/<id>` before posting, so typos surface as
  a retry-then-fail in the daemon (not silently dropped).
```

**Step 5: Verify the file is well-formed**

```bash
grep -c "^## " /home/dev/projects/workstation/assets/opencode/skills/swarm-messaging/SKILL.md
# expected: original count + 1 (the new "Verifying Delivery" section)
```

**Step 6: Commit**

```bash
cd /home/dev/projects/workstation
git add assets/opencode/skills/swarm-messaging/SKILL.md
git commit -m "skills(swarm-messaging): correct pigeon health/delivery/typo guidance"
```

---

## Task 2: Patch `opencode-send` skill

**Files:**
- Modify: `/home/dev/projects/workstation/assets/opencode/skills/opencode-send/SKILL.md`

**Step 1: Read the file** (skim — about 175 lines).

```bash
cat /home/dev/projects/workstation/assets/opencode/skills/opencode-send/SKILL.md
```

**Step 2: Update "Finding The Session ID" section**

Find the section starting `## Finding The Session ID` and replace its
intro paragraph + the `--list` output snippet with:

````markdown
## Finding The Session ID

`opencode-send --list` prints local sessions across **all projects**, sorted
by last-updated (uses `GET /experimental/session` which is the cross-project
endpoint):

```
ID                                UPDATED     DIRECTORY                                 TITLE
ses_268183fceffep6ViEE20s5XWc8    3m          /home/dev                                 PDF code extraction from page 2
ses_272a9b9b8ffeVBXCz6SQmsJF4l    1h          /home/dev/projects/pigeon                 Implement opencode-send CLI
ses_24e8ff295ffeyV8o35YuK63g2u    2d          /home/dev/projects/mono                   Coordinator: COPS-6107 swarm
```

By default the list returns up to 100 sessions, ordered by most-recent
update across the entire local opencode database (one row per
`session_id`, not per project).

> **Why not `GET /session`?** That endpoint exists but is filtered to the
> single project derived from the request's `x-opencode-directory` header.
> If you ran `opencode-send --list` from `/home/dev/projects/workstation`
> you'd only see sessions whose owning project also resolves to that
> directory's project — typically a tiny subset. The cross-project
> endpoint is the right thing for a "who else is around?" query.
````

**Step 3: Add a "Pigeon Reachability" subsection under Quick Start**

Insert after the existing Quick Start block, before the `## Two Paths,
One CLI` header:

````markdown
### Verify pigeon is up before relying on auto-route

```bash
curl -sf "${PIGEON_DAEMON_URL:-http://127.0.0.1:4731}/health"
# expected: {"ok":true,"service":"pigeon-daemon"}
```

If this fails, `opencode-send` silently falls through to the legacy
`--direct` path. The output line tells you which path was taken
(`Queued ...` = pigeon, `Sent to ...` = direct).

````

**Step 4: Update the "Gotchas" prompt_async bullet**

Find the bullet that starts `**`POST /session/<id>/prompt_async\` returns
204 for any id**` and replace with:

```markdown
- **`POST /session/<id>/prompt_async` returns 204 for any id** (real or
  fake). The direct path catches typos via a pre-flight `GET /session/<id>`
  (404 → exit 1). The pigeon path also catches them, but indirectly:
  the arbiter's `registry.resolve()` does the same pre-flight, throws on
  404, and surfaces it as a retry-then-fail (max 10 attempts, ~85s of
  backoff). Either way, typos don't silently disappear — the difference
  is latency.
```

**Step 5: Add a "Verifying Delivery" subsection (mirror of swarm-messaging skill)**

After the existing "Receiving Side" section and before "Attaching to a
Pigeon-Routed Session", insert:

````markdown
## Verifying Delivery

Auto-route prints `Queued msg_<id> -> ses_<target>` on success. That's
acceptance into pigeon's SQLite, not delivery to the receiving session.
To confirm delivery, query the daemon:

```bash
curl -sf "${PIGEON_DAEMON_URL:-http://127.0.0.1:4731}/swarm/inbox?session=$TARGET_SESSION_ID&limit=5" \
  | jq '.messages[] | {msg_id, handed_off_at, payload: (.payload | .[0:80])}'
```

`handed_off_at: <timestamp>` (non-null) means the receiving opencode-serve
accepted the prompt. Treat that as proof-of-delivery. Null after several
seconds means the arbiter is still retrying — `--direct` path delivered
synchronously so the same data is unavailable there. See
`swarm-messaging` skill for the longer treatment.

````

**Step 6: Update Design Notes table**

In the existing `## Design Notes` table, replace the "Discovery" row:

```markdown
| Discovery | `--list` via `GET /experimental/session` | Cross-project list; the project-scoped `GET /session` would only show sessions belonging to the calling cwd's project, which is usually wrong for swarm coordination. |
```

**Step 7: Commit**

```bash
cd /home/dev/projects/workstation
git add assets/opencode/skills/opencode-send/SKILL.md
git commit -m "skills(opencode-send): correct --list semantics, pigeon health, typo behavior"
```

---

## Task 3: Update `opencode-send --list` to use `/experimental/session`

**Files:**
- Modify: `/home/dev/projects/workstation/users/dev/home.base.nix` (the heredoc that defines the `opencode-send` script — search for `--list`).

**Step 1: Find the script in home.base.nix**

```bash
grep -n "opencode-send\|GET.*session\|--list" /home/dev/projects/workstation/users/dev/home.base.nix | head -20
```

The script is defined as a `home.file` or via `pkgs.writeShellScript`. The
relevant block is the `mode == "list"` branch that calls `curl -sf -m 10
"$OPENCODE_URL/session"`.

**Step 2: Locate the exact line**

The line to change reads (in the deployed bash script — your task is to
find the equivalent in the Nix heredoc that generates it):

```bash
json="$( "$CURL" -sf -m 10 "$OPENCODE_URL/session" )" || {
```

**Step 3: Change the URL to `/experimental/session`**

Replace with:

```bash
# Cross-project list. /session would be filtered to the project derived
# from x-opencode-directory which is almost never what we want.
json="$( "$CURL" -sf -m 10 "$OPENCODE_URL/experimental/session?limit=100" )" || {
```

(Keep everything else — the jq pipeline, the column-printing `while read`
loop — unchanged. The response shape is `Session.GlobalInfo[]` which
includes `id`, `directory`, `title`, `time.updated` — same fields the
existing renderer uses.)

**Step 4: Verify the fields match**

`Session.GlobalInfo` and `Session.Info` differ in some fields, but the
ones the renderer uses (`id`, `directory`, `title`, `time.updated`) are
present in both. Verify by hitting both endpoints and comparing the keys
of the first row:

```bash
curl -sf "http://127.0.0.1:4096/session" -H "x-opencode-directory: /home/dev" | jq '.[0] | keys' | head
curl -sf "http://127.0.0.1:4096/experimental/session?limit=1" -H "x-opencode-directory: /home/dev" | jq '.[0] | keys' | head
# both should include: directory, id, time, title
```

**Step 5: Apply via home-manager**

```bash
nix run home-manager -- switch --flake /home/dev/projects/workstation#dev
```

Expected: succeeds, prints "switched to generation N" (where N > current).

**Step 6: Smoke test the new `--list`**

```bash
~/.local/bin/opencode-send --list | wc -l
# expected: > 5 (was 2 before — header + one session in /home/dev project)

~/.local/bin/opencode-send --list | awk '{print $3}' | sort -u | wc -l
# expected: > 1 (multiple distinct directories, was 1 before)
```

If both numbers grew → fix is working. If `--list` exits 1 (e.g.
`/experimental/session` not exposed on this opencode-serve version),
revert and file an issue against `opencode-patched`.

**Step 7: Commit + push**

```bash
cd /home/dev/projects/workstation
git add users/dev/home.base.nix
git commit -m "feat(opencode-send): use /experimental/session for --list (cross-project)"

# Then close out the work session per the AGENTS.md "Landing the Plane" protocol:
git pull --rebase
git push
git status  # MUST show "up to date with origin"
```

---

## Out of scope (explicitly NOT in this plan)

- **The prefill 400 fix** — that's a separate plan
  (`task2-prefill-fix.md`).
- **Pigeon talking to multiple opencode-serve instances** — the high
  ports are TUI internal servers, not separate REST APIs. Multi-serve
  routing isn't a real problem.
- **Adding pigeon-side state checks (idle-before-deliver)** — would be
  redundant with the upstream Instance fix; YAGNI.
- **Changing `--list` output format** — current format works; just
  change the data source.

## Risk and rollback

- **Risk: `/experimental/session` is gated by version.** If a future
  opencode upgrade renames or removes the endpoint, `--list` breaks. This
  is acceptable since the endpoint has been stable since v1.14.x and
  fallback is a one-line revert.
- **Rollback:** `git revert <commit>` and re-run `home-manager switch`.
- **Skill changes are pure docs.** Even if the CLI change is reverted,
  the corrected skill text remains accurate (the per-project filtering
  story is true regardless of which endpoint we hit).
