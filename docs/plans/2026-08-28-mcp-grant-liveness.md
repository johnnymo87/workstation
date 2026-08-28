# MCP grant liveness: the one-turn delay and the recurring drop

**Date:** 2026-08-28
**Status:** fix shipped for the recurring drop; proposal only for the one-turn delay
**Source read:** opencode `v1.18.18` (the pinned `upstreamVersion` in
`users/dev/home.base.nix`), checked out read-only at `/tmp/opencode/oc-1.18.18`.
One fork patch overlaps: `opencode-patched/patches/serve-lease.patch` inserts
`checkLeaseDeadline(sessionID)` as the first statement of `runLoop`'s `while`
loop, immediately after the `sessions.get` snapshot cited below. It changes none
of the semantics here, but it lands on exactly the lines the proposed upstream
fix would touch, so that patch must be authored against the fork, not vanilla.

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
- **Only gated servers are eligible** — see "Blast radius" below. This is the
  safety property of the whole design, not an optimisation.
- **A resolved connect is not a successful connect.** `MCP.create` swallows a
  failed handshake into a *status* (`mcp/index.ts` `create()`), the route returns
  a bare `true` regardless (`handlers/mcp.ts:75-85`), and the hey-api SDK
  defaults to `ThrowOnError=false` so even a 5xx resolves. The hook therefore
  re-reads the status map after connecting and only counts `connected` as
  success. Without that, the backoff below would be unreachable code and a
  permanently broken server would respawn `npx` on every user message.
- **Fast path.** If nothing eligible is disconnected the hook returns without
  reading the session row; if the host has no gated server configured at all
  (devbox has no slack) it returns after one call. Note this does *not* fire in
  the cold case that matters — slack ships `enabled: false`, so on a fresh
  instance it reads `disabled` and the session row *is* read. Honest steady-state
  cost: two loopback HTTP calls per user message on a host with slack
  configured, one on a host without.
- **Bounded and backed off.** 5 s on the reads, 60 s on a connect (stdio servers
  shell out to `npx`/`uvx`), and a 60 s cooldown per server after a failure so a
  broken server is not retried on every message.
- **One connect per directory.** Concurrent turns in the same directory share an
  in-flight promise rather than spawning two clients.

### Blast radius, and why eligibility is gate-derived

The plugin invents no grants — but "it only acts on existing grants" is *not*
the same as "blast radius unchanged", and an earlier draft of this document said
so wrongly. Grants never expire, and reconnecting is per-**directory**. So an
unrestricted version of this plugin would re-activate every stale grant on the
box: one message to a months-old session (a `swarm_schedule` wake is enough)
would connect that server for its whole directory, and would keep doing so —
defeating the serve restart, the `POST /config` dispose, *and* a human's
explicit `disconnect`, which are today the only ways out.

Measured on this box, read-only:

```
$ sqlite3 -readonly ~/.local/share/opencode/opencode.db \
    "select count(*) from session where permission like '%datadog_%';
     select count(*) from session where permission like '%pagerduty_%';
     select count(distinct directory) from session
       where permission like '%datadog_%' or permission like '%pagerduty_%';"
85
1
22
```

`datadog_*` and `pagerduty_*` are **not** in the `tools` deny gate, and their
tool schemas make Vertex Gemini 400 the *entire* request
(`.opencode/skills/opencode-agents/SKILL.md`). Auto-reconnecting them would
wedge every Gemini turn in 22 directories, permanently.

Hence eligibility is derived from the global gate, not from the grant: a server
may be auto-reconnected only if config denies `<name>_*` globally
(`assets/opencode/opencode.base.json` → `tools`, or an equivalent `permission`
deny). For a gated server, `resolveTools` strips the tools again from any
co-directory session lacking its own allow rule, so exposure stays
session-scoped and the reconnect is genuinely blast-radius-neutral. For an
ungated server it is not, so the plugin refuses.

Today that set is exactly `{slack, slack-ro}`. **Opting a server in is one edit:
add `"<name>_*": false` to the `tools` map** — which is the same edit that makes
its exposure session-scoped in the first place, so the two cannot drift apart.
Atlassian is deliberately *not* eligible yet for that reason; gating it is a
separate, independently reviewable change.

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

205 → 237 tests, 10 files, 0 skipped (30 new in
`test/mcp-autoconnect.test.ts`, plus 2 the loader-contract suite generates for
the newly deployed file). The worktree ships no `node_modules`; `npm ci` in
`assets/opencode/plugins` first, or run the `plugin-vitest` flake check, which
supplies them. `test/plugin-loader-contract.test.ts`
picks the new file up automatically (it discovers deployed plugins by grepping
`xdg.configFile."opencode/plugins/..."` out of `users/dev/opencode-config.nix`)
and asserts it survives a replica of opencode's v1.18.18 plugin loader — which
is what makes the `internals` named export safe.

Not verified live: reconnect-after-serve-restart. That needs a serve restart,
and the pool is shared with other people's in-flight work.

Two things to know before looking for evidence:

- **Deploying the file is not enough.** opencode binds plugins to an app
  *instance* at instance-creation time, so a `home-manager switch` that does not
  restart the serves leaves this plugin inert for every directory a serve has
  already touched (established by the S0 diagnosis in
  `docs/plans/2026-07-12-opencode-session-switcher-plan.md:1061-1067`; same trap,
  and the reason that plan records a standing "restart the pool when
  `assets/opencode/plugins/**` changes" requirement).
- **The log line does not land in `opencode.log`.** A plugin's `console.error`
  goes to the serve's stderr, i.e. journald — the same S0 diagnosis records
  that checking `opencode.log` alone is a false clear. Confirmed here: zero
  `[session-state]` lines exist in `opencode.log` as real log records.

So the observation point is the next natural restart (the 8-hourly
`update-opencode-patched` auto-merge, or the nightly reset), and the command is:

```bash
journalctl --user -u 'opencode-serve@*' --since '-1h' | grep mcp-autoconnect
```

Expected: a session holding a `slack_*` grant regains its tools on its next
prompt with no manual step, and the journal carries
`[mcp-autoconnect] reconnected MCP server "slack" for ses_… in <dir>`.
