# Launch Tag Inheritance — Design

**Status:** approved 2026-09-23 (user + adversarial-reviewer-fable, approve-with-changes folded in)

> **Superseded in part (2026-09-24):** oc-tags directory rules were removed, so
> `oc-tags which` now reports kind `session` or `auto` only. The `dir` kind
> below is historical; the launcher still tolerates it from an older oc-tags.

## Goal

A session launched by something that carries an explicit oc-tags tag inherits
that tag, unless the launch passes a tag of its own. Swarm workers and
Telegram follow-ups then land on their program's tag instead of an `auto:`
fallback that someone has to clean up by hand later.

Two launch paths, both in scope:

- **pigeon `/launch` via Telegram**, which is the user's main path. Here the
  "launcher" is the session whose forum topic the `/launch` was typed in, or
  whose notification it swipe-replies to. The user confirmed they launch from
  topics and replies, not from General.
- **`opencode-launch` CLI** run by an agent session. Here the launcher is
  `$OPENCODE_SESSION_ID`.

## Rules (both paths)

1. Inherit only when the launcher's effective tag comes from an **explicit
   session tag**. Directory-glob tags and `auto:` fallbacks are never
   inherited. Globs describe a place rather than the work, and the `dir_tag`
   table is currently empty anyway.
2. An explicit `--tag <t>` always wins, and no lookup is done.
3. Opt-out differs per path, because `tagging-sessions` treats a mislabel as
   worse than an untagged session:
   - In `opencode-launch`, `--tag auto` means "do not inherit; leave this on
     the `auto:` fallback".
   - In Telegram there is **no opt-out syntax**; the user does not want to type
     one. Where the `/launch` is sent decides it. A `/launch` in a session's
     topic or swipe-reply inherits. A `/launch` in General has no context, so
     it does not.
4. Inheritance is **copy**, not link. The launch writes a normal
   `oc-tags set <tag> <child>`. Retagging the parent later does not touch its
   children. If per-child fix-ups start to hurt, we can revisit a link model
   (a `session_parent` table walked by `effective_tag`).
5. Everything is best-effort and happens after the prompt is sent. A failed
   lookup or set prints a note, and the child stays on `auto:`. It never
   fails, delays or redelivers the launch.
6. Inheritance is loud. Both paths name the tag and the session it came from.

## Part 0 — oc-tags: distinguish session from dir source

`effective_tag` (`pkgs/oc-tags/oc_tags.py:~190`) currently returns `manual`
for both a session tag and a dir glob. `oc-tags which` prints that value in
column 2, and pigeon's footer resolver (`tag-resolver.ts` `parseWhich`)
depends on `manual` staying `manual`. The two deploy separately, so renaming
the value would blank the footer during any version skew.

**Change (additive):** `which` gets a 4th TSV column, `kind`, with values
`session|dir|auto`. Column 2 is unchanged. `parseWhich` already accepts
lines with extra columns (`parts.length < 3`). Add tests for each kind.

This ships first, because both consumers depend on it. An old oc-tags prints
only 3 columns. Consumers must treat a missing column 4 as "don't inherit".

## Part A — opencode-launch

In `pkgs/opencode-launch/default.nix`:

- Parse `--tag auto` (case-insensitive, exactly `auto`) as `no_inherit=1`,
  before `validate_tag` runs. `validate_tag` still rejects `auto:*`.
- After the prompt is sent, where `apply_session_tag` runs today:
  - If there is no `--tag`, `no_inherit` is unset and `OPENCODE_SESSION_ID`
    is non-empty, run `timeout 4 oc-tags which -- "$OPENCODE_SESSION_ID"`.
  - If column 4 is `session`, run the tag through `validate_tag` and then
    `apply_session_tag`.
  - Print `Tag: <oc-tags line> (inherited from <root_sid>)`.
  - Every failure path (binary missing, non-zero exit, timeout, 3-column
    output, failed validation) prints a `Note:` and exits 0.
- **Scrub the stale id:** spawn `oc-auto-attach` with
  `env -u OPENCODE_SESSION_ID`. Without this, the first attach after a tmux
  server restart starts the tmux server with the agent's id in its global env.
  Every later pane then inherits a dead session's id, and a human
  `opencode-launch` from those panes would silently inherit the wrong tag.
- Tests (`pkgs/opencode-launch/test.sh`, fake `OC_TAGS_BIN`):
  - `which` returns kind `session` → tag inherited.
  - kind `dir` → not inherited.
  - kind `auto` → not inherited.
  - 3-column output → not inherited.
  - `which` exits non-zero → launch still succeeds.
  - `which` hangs → timeout path, launch still succeeds.
  - Explicit `--tag` → `which` is never called.
  - `--tag auto` → `which` is never called, nothing is tagged.
  - No `OPENCODE_SESSION_ID` → `which` is never called.
  - Inherited tag fails `validate_tag` → Note, launch succeeds.
  - The `oc-auto-attach` spawn env has no `OPENCODE_SESSION_ID`.
- Docs: usage text, the `--tag` section of the `opencode-launch` skill, and one
  line in the `tagging-sessions` skill.

## Part B — pigeon `/launch`

**Worker** (`packages/worker`):

- Extract a **silent** `findContextSession(db, env, message)` that returns
  `{sessionId, machineId} | null`. It tries a swipe-reply lookup first, then
  the forum topic, then the sessions row. It does not check
  `isMachineRecent` and sends no Telegram messages. `resolveReplySession`
  wraps it and keeps its existing error replies. `/launch` calls the silent
  version, so `/launch` in General behaves exactly as it does today.
- Set `inheritFromSessionId` in metadata only when all of these hold: there is
  no `--tag`, a context session was found, its machine
  equals the launch target machine (tags.db is per host), and the backend is
  not goose. The key is omitted when unset, following the existing
  `tag`/`backend` convention.
- The immediate ack adds "will inherit tag from ses_X unless --tag given".
  The human sees this before the daemon acts.
- `poll.ts` forwards `inheritFromSessionId`, omitted when unset.

**Daemon** (`packages/daemon`):

- Poller `LaunchMessage` gains an optional `inheritFromSessionId`. An old
  worker never sends it, and an old daemon ignores it. Either way the child
  just stays on `auto:`.
- `launch-ingest.ts`: after the prompt, if there is no tag and
  `inheritFromSessionId` passes `isValidSessionId`, run `oc-tags which <id>`
  with a 3s runner. Extend or export the existing `parseWhich` rather than
  writing a third parser. If kind is `session`, apply the tag through the
  existing `applyTag`.
- This whole block sits inside the same never-throw envelope as `applyTag`,
  because the runner rejects on timeout and a throw redelivers the launch as
  a duplicate session.
- The confirmation reply says `🏷 <tag> (inherited from ses_…)`.
- Tests cover:
  - Inherit when kind is `session`.
  - No inherit when kind is `dir`, `auto`, or the output has 3 columns.
  - An invalid id → `which` is never run.
  - `which` rejects or times out → no throw, the session is reported, no tag.
  - An explicit tag wins.
  - Worker: General-topic `/launch` sends no extra message.
  - Worker: machine mismatch → no key.
  - Worker: goose → no key.
  - Worker: `--tag` present → no key.

## Known and accepted

- **Copying loses provenance.** A wrong tag inherited across a swarm has to be
  fixed per child with `oc-tags set`.
- **Topic context is a proxy for intent.** A `/launch` typed in session X's
  topic is assumed to be related to X. The pre-action ack is the mitigation for Telegram; for unrelated work, launch from General.
- **A closed topic still resolves.** If a closed topic still maps to its
  session, the launch inherits that session's tag. That is intended.
- **Pre-existing:** a bare `oc-tags set <tag>` already defaults to
  `$OPENCODE_SESSION_ID`, so a stale id in the environment affects that too.
  Part A's scrub removes the main way the id goes stale.

## Rollout order

1. oc-tags column 4 (workstation), then home-manager switch.
2. Part A (workstation). Can ship in the same PR as step 1.
3. Pigeon worker and daemon (pigeon repo, separate PR). Both skew directions
   degrade to today's behavior.
