# MCP grant liveness: the one-turn delay and the recurring drop

**Date:** 2026-08-28
**Status:** fix shipped for the recurring drop; proposal only for the one-turn delay
**Source read:** opencode `v1.18.18` (the pinned `upstreamVersion` in
`users/dev/home.base.nix`), checked out read-only at `/tmp/opencode/oc-1.18.18`.
No fork patch touches any of the code paths below (`patches/serve-lease.patch`
edits `session/prompt.ts` far from the lines cited here).

## The two complaints

1. **One-turn delay.** After `oc-mcp-enable <session> slack`, the `slack_*`
   tools are unusable until the session's *next* prompt.
2. **Recurring drop.** The same session loses its Slack tools repeatedly over
   hours and needs re-enabling again and again.

They have different causes. (2) is fixed here. (1) is not fixable from this
repo; the exact upstream patch is written out below.

## Evidence that (2) is real and frequent

`session.permission` is durable, so every manual re-enable leaves a permanent
fingerprint — a duplicate `slack_*` allow rule. Counting them in the live DB
(read-only):

```
$ sqlite3 -readonly ~/.local/share/opencode/opencode.db \
    "select id, datetime(time_updated/1000,'unixepoch'),
            (length(permission)-length(replace(permission,'slack','')))/5
     from session where permission like '%slack%' order by 3 desc limit 5;"
ses_013ba282effehU3p6IZT0jwY0I|2026-08-11 22:43:33|6
ses_0269d8f78ffeWspTehH3yF8mch|2026-08-09 00:31:10|5
ses_028306b90ffe7mcC7iDgr3T22p|2026-08-27 23:56:30|3
ses_fe5acc12bffeHYK3oETBRGTh7j|2026-08-20 21:44:59|3
ses_fcc0c581affedDMDsvdytx9QxT|2026-08-28 05:42:58|3
```

Six identical grants on one session. The grant never expired — the *connection*
did, six times.

## Root cause

Granting an MCP server to a running session is two operations with two
different lifetimes. `pkgs/oc-mcp-enable/default.nix` already documents the
split; what follows is where each half actually lives.

### Half 1 — the connection is per-directory process memory

`POST /mcp/<name>/connect` → `MCP.connect` → `createAndStore`
(`packages/opencode/src/mcp/index.ts:648`), which writes into a `State` held by
`InstanceState.make` (`mcp/index.ts:492`). `InstanceState` is a
`ScopedCache` keyed by **directory** (`effect/instance-state.ts:31-50`), and the
cache entry is invalidated by `disposeInstance(directory)`
(`effect/instance-registry.ts:10`), whose finalizer closes every MCP client and
SIGTERMs its stdio child (`mcp/index.ts:531-553`).

Instance disposal is *not* only a serve restart. Every one of these drops the
connection for the whole directory:

| Trigger | Path |
|---|---|
| serve process exit / restart | `InstanceStore` scope finalizer → `disposeAll` |
| `POST /config` (config update) | `handlers/config.ts:20` `markInstanceForDisposal` |
| `POST /instance/dispose` | `handlers/instance.ts:25` |
| project/worktree reload | `handlers/project.ts:28` `markInstanceForReload` |
| worktree path no longer canonical | `worktree/index.ts:397,417` `disposeDirectory` |

Nothing reconnects afterwards, because the config ships the servers as
`"enabled": false` — and `enabled: false` is exactly the branch that skips
`create()` during instance boot (`mcp/index.ts:514`). So a fresh instance comes
up with `status: "disabled"` and no client, while the session's permission row
still says `slack_*: allow`. **That silent mismatch is complaint (2).**

### Half 2 — the permission grant is durable, but read once per turn

`PATCH /session/<id>` writes `session.permission` to SQLite
(`session/session.ts:780` `setPermission`). `Session.get` re-reads the row and
builds a **fresh object** every call (`session/session.ts:542`) — there is no
shared mutable session object.

And `runLoop` snapshots it **once, before the step loop**:

```ts
// session/prompt.ts:1081-1088
const runLoop = Effect.fn("SessionPrompt.run")(function* (sessionID) {
  const ctx = yield* InstanceState.context
  let structured: unknown
  let step = 0
  const session = yield* sessions.get(sessionID).pipe(Effect.orDie)   // <-- once

  while (true) {
```

That snapshot is what gates the tool list, at `session/llm/request.ts:208`:

```ts
function resolveTools(input) {
  const disabled = Permission.disabled(
    Object.keys(input.tools),
    Permission.merge(input.agent.permission, input.permission ?? []),  // stale
  )
  return Record.filter(input.tools, (_, k) => input.user.tools?.[k] !== false && !disabled.has(k))
}
```

The global gate in `assets/opencode/opencode.base.json`

```json
"tools": { "slack_*": false, "slack-ro_*": false }
```

becomes `config.permission["slack_*"] = "deny"` (`config/config.ts:553-563`),
which lands in `agent.permission` — so `Permission.disabled` strips every
`slack_*` tool unless a **later** rule allows it, and the only later rule is the
stale `session.permission`. **That is complaint (1).**

Note what is *not* the cause: the tool set itself is rebuilt on **every step**,
not once per turn — `SessionTools.resolve` is called inside the `while (true)`
loop (`session/prompt.ts:1226`) and reads `mcp.tools()` live from
`InstanceState` (`session/tools.ts:390`). A mid-turn *connect* is therefore
already visible to the next step. Only the *permission* half is frozen.

## The fix that shipped: `assets/opencode/plugins/mcp-autoconnect.ts`

`session.permission` is already the durable, per-session record of "this session
was granted `<name>`". Read it back at the start of each turn and reconnect
whatever is granted but not connected.

The hook is `chat.message`, and the choice is entirely about ordering:

```
prompt()                                        session/prompt.ts:1052
  createUserMessage()
     plugin.trigger("chat.message", ...)        session/prompt.ts:1000   <-- hook
  loop() -> runLoop()                           session/prompt.ts:1081
     const session = sessions.get(...)          <-- permission snapshot
     while (true) { SessionTools.resolve(...) } <-- tool set, per step
```

`plugin.trigger` is awaited (`plugin/index.ts:292`), so the reconnect completes
*before* the snapshot and before step 1 resolves tools. The reconnected server
is therefore usable in the **current** turn, not the next one. An `event` hook
would be fire-and-forget and would race that snapshot.

Properties, each covered by a test in `test/mcp-autoconnect.test.ts`:

- **Grant detection is exact-string on `<name>_*`.** That is the literal shape
  both grant paths emit (`oc-mcp-enable`'s `build_permission_json`, and
  `opencode-launch --mcp`'s prompt `tools` map, which `prompt.ts:1063` converts
  to the same rule). It deliberately does not reimplement `Wildcard.match`, so
  it only ever acts on rules our own tooling wrote.
- **Revocation is honoured for free** — last matching rule wins, mirroring
  `Permission.evaluate`'s `findLast`, so `oc-mcp-enable --revoke` stops the
  reconnect.
- **It never rejects.** `plugin.trigger` wraps hooks in `Effect.promise`, where
  a rejected promise is a *defect* that kills the turn. A reconnect that cannot
  happen must degrade to "no Slack this turn", never to "your prompt died".
- **Fast path first.** `client.mcp.status()` is an in-process map read; if every
  configured server is already connected the hook returns without even reading
  the session row. That is the steady state on a warm serve.
- **Bounded and backed off.** 5 s on the reads, 60 s on a connect (stdio servers
  shell out to `npx`/`uvx`), and a 60 s cooldown per server after a failure so a
  broken server is not retried on every message.
- **One connect per directory.** Concurrent turns in the same directory share an
  in-flight promise rather than spawning two clients.

### Blast radius

Unchanged from today. The plugin only ever calls `connect` for a server the
session was *already* granted by a human running `oc-mcp-enable` (or
`opencode-launch --mcp`); it invents no grants. It does inherit the existing
per-directory property that connecting for one session connects for every
session in that directory — but that is what `oc-mcp-enable` already did, and
co-directory sessions without an allow rule still have the tools stripped by
`resolveTools`.

## What is left: complaint (1), the one-turn delay

The remaining delay is one line in upstream. `session` is snapshotted before the
loop but used only inside it, so moving the read inside makes a mid-turn `PATCH`
visible on the very next step:

```diff
--- a/packages/opencode/src/session/prompt.ts
+++ b/packages/opencode/src/session/prompt.ts
@@ runLoop
   const ctx = yield* InstanceState.context
   let structured: unknown
   let step = 0
-  const session = yield* sessions.get(sessionID).pipe(Effect.orDie)
 
   while (true) {
+    const session = yield* sessions.get(sessionID).pipe(Effect.orDie)
     yield* status.set(sessionID, { type: "busy" })
```

Cost is one indexed SQLite row read per step, on a path that is about to make an
LLM call. It would belong in `johnnymo87/opencode-patched` as a new patch, not
here. **Not done in this branch**, because it cannot be validated without
restarting a serve, and this box has many live sessions.

Two alternatives were considered and rejected:

- **Drop `"slack_*": false` from the global `tools` gate.** With
  `"permission": {"*": "allow"}` in the base config, `Permission.disabled`
  would then strip nothing, and a mid-turn *connect* alone would make the tools
  live immediately — no permission PATCH involved, no staleness. But that gate
  is the only thing stopping co-directory sessions and subagents from seeing
  another session's Slack tools, so this trades the annoyance for a real
  isolation loss.
- **Pre-grant `slack_*` to every session at launch.** Makes the connection the
  sole gate and gives up least-privilege for no benefit the plugin does not
  already deliver.

With the plugin in place the residual delay is **once per session**, at the
moment of the first grant — not once per serve restart, several times a day.

## Follow-ups not taken

- `oc-mcp-enable` appends its allow rule unconditionally, which is why the
  duplicates above accumulate. Harmless (last-match-wins), but it would be
  cheap to skip the PATCH when an identical trailing rule already exists.
- `assets/opencode/skills/slack-mcp-setup/SKILL.md` still describes `--mcp` as
  a per-turn fold; `opencode-launch/SKILL.md` already corrects that. Both are
  updated for the reconnect behaviour in this branch.

## Verification

```
cd assets/opencode/plugins
npx tsc --noEmit
node_modules/.bin/vitest run
```

205 → 225 tests, 10 files, 0 skipped (18 new in
`test/mcp-autoconnect.test.ts`, plus 2 the loader-contract suite generates for
the newly deployed file). `test/plugin-loader-contract.test.ts`
picks the new file up automatically (it discovers deployed plugins by grepping
`xdg.configFile."opencode/plugins/..."` out of `users/dev/opencode-config.nix`)
and asserts it survives a replica of opencode's v1.18.18 plugin loader — which
is what makes the `internals` named export safe.

Not verified live: reconnect-after-serve-restart. That needs a serve restart,
and the pool is shared with other people's in-flight work. The next natural
restart (the 8-hourly `update-opencode-patched` auto-merge, or the nightly
reset) is the observation point: a session holding a `slack_*` grant should
regain its tools on its next prompt with no manual step, and
`~/.local/share/opencode/log/opencode.log` should carry
`[mcp-autoconnect] reconnected MCP server "slack"`.
