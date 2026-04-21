# OpenCode multi-directory race triggers Anthropic "assistant message prefill" 400 — best fix?

## Keywords

opencode, sst/opencode, agent orchestration, headless serve, prompt_async,
Anthropic Vertex AI, claude-opus-4-7, "does not support assistant message
prefill", "must end with a user message", per-session lock, per-directory
state, Hono middleware, x-opencode-directory, Bun, AI SDK, swarm coordinator,
multi-agent.

## TL;DR

We run a small swarm of headless OpenCode sessions on one host (one
"coordinator" + four "worker" sessions, each in its own git worktree). The
workers send status pings to the coordinator over HTTP via a tiny `bash`
wrapper called `opencode-send`, which `POST`s to
`/session/<id>/prompt_async` on the local `opencode serve` (port 4096).

When two or more workers ping the coordinator within ~1 second of each other,
opencode opens **multiple concurrent LLM turns on the same session**, all
parented to the same incoming user message. The third turn then fails with:

```
APIError 400: This model does not support assistant message prefill.
The conversation must end with a user message.
```

We've traced the bug: opencode's "is this session already running" busy guard
is in a state map keyed by **directory**, not by session id. Each
`opencode-send` call sets `x-opencode-directory: $PWD`, so requests from
different worker worktrees resolve to **different `Instance` contexts** with
separate state maps, and the guard returns "not busy" for everyone except the
first caller.

We want a brain trust on (a) the "right" upstream fix, and (b) the cleanest
short-term workaround.

## Environment

- Host: NixOS devbox.
- `opencode` binary version: `1.14.19`.
- Source tree we're patching from: `johnnymo87/opencode-patched` fork, head
  commit `b312928e9 fix(tui): wait for model store before auto-submitting
  --prompt (#7476)` (recently rebased on upstream `sst/opencode`).
- `opencode serve` runs as a systemd service on `127.0.0.1:4096`, single
  process (Bun runtime, Hono HTTP server).
- Model: `google-vertex-anthropic/claude-opus-4-7@default` (Anthropic Claude
  on Google Vertex AI). The error string is Anthropic's, returned with
  HTTP 400 and `isRetryable: false`.
- Five sessions in play, all sharing the same `opencode serve` process and
  the same SQLite DB (`~/.local/share/opencode/opencode.db`):

  | Role          | Session id (suffix)                | Working directory                                           |
  |---------------|------------------------------------|-------------------------------------------------------------|
  | Coordinator   | `ses_24e8ff295…yV8o35YuK63g2u`    | `/home/dev/projects/mono`                                  |
  | Worker mono   | `ses_24e4c9b3e…oQgQNFIYDYm130`    | `/home/dev/projects/mono/.worktrees/COPS-6107`             |
  | Worker protos | `ses_24e4c9873…xUz2X45WnfIPob`    | `/home/dev/projects/protos/.worktrees/COPS-6107`           |
  | Worker FE     | `ses_24e4c9593…3amAM6XAaHGvp2`    | `/home/dev/projects/internal-frontends/.worktrees/COPS-6107`|
  | Worker dbt    | `ses_24e4c9321…yC4cOmdwqqCU0H`    | `/home/dev/projects/data_recipe/.worktrees/COPS-6107`      |

## What the workers do

Each worker is itself an OpenCode session running `bash` tool calls. To talk
to the coordinator, they shell out to:

```
opencode-send --cwd $PWD <coordinator-id> "[mono-baj.6 data_recipe] Online…"
```

`opencode-send` is a thin bash wrapper that does a pre-flight `GET
/session/<id>` then a `POST /session/<id>/prompt_async` with body
`{"parts":[{"type":"text","text":"…"}]}` and header `x-opencode-directory:
$PWD`.

The header value differs per worker because each worker `cd`s into its own
worktree before invoking `opencode-send`.

## Evidence the bug is real

Querying the SQLite store directly (timestamps in ms):

```
1776802867897 user
1776802867917 assistant  parent=user@1776802867897  cwd=protos/.worktrees/COPS-6107
1776802868582 assistant  parent=user@1776802867897  cwd=mono/.worktrees/COPS-6107
1776802870964 assistant  parent=user@1776802867897  cwd=mono                     (3 children, 3 cwds, 0 errors)
1776802871790 user
1776802872941 assistant  parent=user@1776802871790  cwd=mono
1776802873149 assistant  parent=user@1776802871790  cwd=protos/.worktrees/COPS-6107
1776802876315 assistant  parent=user@1776802871790  cwd=mono
1776802879082 assistant  parent=user@1776802871790  cwd=mono/.worktrees/COPS-6107
1776802880827 assistant  parent=user@1776802871790  cwd=mono   ERR: assistant message prefill
                                                              (5 children, 3 cwds, 1 error)
1776802939861 user
…
1776802947692 assistant  parent=user@1776802939861  cwd=mono/.worktrees/COPS-6107  ERR: prefill
1776802948871 assistant  parent=user@1776802939861  cwd=mono                       ERR: prefill
1776802958157 assistant  parent=user@1776802939861  cwd=data_recipe/.worktrees/COPS-6107
                                                              (6 children, 3 cwds, 2 errors)
```

Aggregate: in this one session, **every burst with ≥3 distinct cwds produced
either a corrupted message tree or a 400 from Anthropic.**

Failed assistant messages persist with `error.data` populated:

```json
{
  "role": "assistant",
  "modelID": "claude-opus-4-7@default",
  "providerID": "google-vertex-anthropic",
  "path": { "cwd": "/home/dev/projects/mono", … },
  "error": {
    "name": "APIError",
    "data": {
      "message": "This model does not support assistant message prefill. The conversation must end with a user message.",
      "statusCode": 400,
      "isRetryable": false,
      …
    }
  }
}
```

## What we believe is the root cause

OpenCode source files (commit `b312928e9`):

### 1. The per-session "busy" map is keyed by directory

`packages/opencode/src/session/prompt.ts`:

```ts
export namespace SessionPrompt {
  const state = Instance.state(           // <-- directory-scoped!
    () => {
      const data: Record<
        string,
        {
          abort: AbortController
          callbacks: {
            resolve(input: MessageV2.WithParts): void
            reject(reason?: any): void
          }[]
        }
      > = {}
      return data
    },
    async (current) => {
      for (const item of Object.values(current)) {
        item.abort.abort()
      }
    },
  )

  function start(sessionID: string) {
    const s = state()
    if (s[sessionID]) return        // <-- guard: return undefined if running
    const controller = new AbortController()
    s[sessionID] = { abort: controller, callbacks: [] }
    return controller.signal
  }

  export const loop = fn(LoopInput, async (input) => {
    const { sessionID, resume_existing } = input
    const abort = resume_existing ? resume(sessionID) : start(sessionID)
    if (!abort) {
      // already running: enqueue a callback and wait
      return new Promise<MessageV2.WithParts>((resolve, reject) => {
        const callbacks = state()[sessionID].callbacks
        callbacks.push({ resolve, reject })
      })
    }
    // …actually run the LLM loop, periodically draining state()[sessionID].callbacks
  })

  export const prompt = fn(PromptInput, async (input) => {
    const session = await Session.get(input.sessionID)
    await SessionRevert.cleanup(session)

    const message = await createUserMessage(input)   // ALWAYS inserts a user message
    await Session.touch(input.sessionID)
    …
    return loop({ sessionID: input.sessionID })
  })
}
```

### 2. `Instance.state` is keyed by `Instance.directory`

`packages/opencode/src/project/instance.ts`:

```ts
export const Instance = {
  async provide<R>(input: { directory: string; init?: () => Promise<any>; fn: () => R }) {
    const directory = Filesystem.resolve(input.directory)
    let existing = cache.get(directory)
    if (!existing) { existing = track(directory, boot({ directory, init: input.init })) }
    const ctx = await existing
    return context.provide(ctx, async () => input.fn())
  },
  state<S>(init: () => S, dispose?: (state: Awaited<S>) => Promise<void>): () => S {
    return State.create(() => Instance.directory, init, dispose)   // <-- root = directory
  },
  …
}
```

`packages/opencode/src/project/state.ts`:

```ts
export namespace State {
  const recordsByKey = new Map<string, Map<any, Entry>>()

  export function create<S>(root: () => string, init: () => S, dispose?) {
    return () => {
      const key = root()                         // <-- partitioning key
      let entries = recordsByKey.get(key)
      if (!entries) { entries = new Map(); recordsByKey.set(key, entries) }
      const exists = entries.get(init)
      if (exists) return exists.state as S
      const state = init()
      entries.set(init, { state, dispose })
      return state
    }
  }
}
```

### 3. The HTTP middleware resolves directory from `x-opencode-directory`

`packages/opencode/src/server/server.ts`:

```ts
.use(async (c, next) => {
  if (c.req.path === "/log") return next()
  const workspaceID = c.req.query("workspace") || c.req.header("x-opencode-workspace")
  const raw = c.req.query("directory") || c.req.header("x-opencode-directory") || process.cwd()
  const directory = Filesystem.resolve(/* decoded raw */)

  return WorkspaceContext.provide({
    workspaceID,
    async fn() {
      return Instance.provide({
        directory,
        init: InstanceBootstrap,
        async fn() { return next() },
      })
    },
  })
})
```

### 4. `prompt_async` fires `prompt` without awaiting

`packages/opencode/src/server/routes/session.ts`:

```ts
.post("/:sessionID/prompt_async", …, async (c) => {
  c.status(204)
  c.header("Content-Type", "application/json")
  return stream(c, async () => {
    const sessionID = c.req.valid("param").sessionID
    const body = c.req.valid("json")
    SessionPrompt.prompt({ ...body, sessionID })   // <-- not awaited
  })
})
```

### Putting it together

1. Worker A (cwd=`protos/.worktrees/...`) `POST`s `/session/<coord>/prompt_async`.
   Middleware resolves Instance("protos/...") and calls `SessionPrompt.prompt`.
   `start(sessionID)` finds nothing in `state()` (state is per-directory),
   inserts the entry for `protos/...`-instance, runs the loop, will start
   hitting Anthropic.
2. Worker B (cwd=`mono/.worktrees/...`) `POST`s the same session ~50 ms
   later. Middleware resolves Instance("mono/.worktrees/...") and calls
   `SessionPrompt.prompt`. **Different `Instance.directory` → different `state()`
   map → `start()` finds nothing → second concurrent loop starts.**
3. Worker C (cwd=`mono`) does the same. Third concurrent loop.
4. All three loops read from the same SQLite session, and each call to
   the model builds its `messages` array via `MessageV2.stream(sessionID)`.
   By the time loop #3 calls Anthropic, loops #1 and #2 have already
   committed their assistant messages. The array now ends with `assistant`,
   not `user`. Anthropic on Vertex 400s with the "prefill" error.

We have not directly inspected the Anthropic-bound payload but everything
about the symptom and source aligns.

## What we've verified vs. what we're hypothesizing

**Verified (from inspecting source + DB):**

- `SessionPrompt.state` is created via `Instance.state`.
- `Instance.state` keys by `Instance.directory` via `State.create`.
- HTTP middleware switches `Instance` per-request based on `x-opencode-directory`.
- `prompt_async` route invokes `SessionPrompt.prompt` without awaiting.
- The DB shows 3-6 assistant messages parented to a single user message,
  each with a different `path.cwd`, ending in 400s from Anthropic on the
  3rd-onwards turn.

**Hypothesized (haven't reproduced yet in isolation):**

- Loop #3's `MessageV2.stream` snapshot is what makes the array end with
  assistant. (Plausible, but conceivably the corruption is in how the
  AI SDK formats trailing tool calls — we haven't dumped the actual
  Anthropic request body.)
- The bug is purely the per-directory state keying. There may also be a
  smaller bug in how `prompt` always inserts a `createUserMessage` even when
  it should be queued.

## Specific questions for the brain trust

1. **Is "key the busy map by sessionID, not by directory" the right
   upstream fix?** If we change `SessionPrompt.state` from
   `Instance.state(() => …)` to a module-level `Map<sessionID,
   {abort,callbacks}>` (process-wide, not directory-scoped), what breaks?
   The session itself is owned by one project, but the same `opencode serve`
   process can serve many projects. We think a process-global map is fine;
   please pressure-test this.

2. **Or is the right fix at a different layer?** Options we can imagine:

   a. Make the HTTP route ignore `x-opencode-directory` for `prompt_async`
      and instead derive `Instance` from the session record (since each
      session already has a `directory` field stored in SQLite).

   b. Add a per-session `Mutex` (e.g. `async-mutex`) inside `prompt`/`loop`
      that's *not* `Instance`-scoped.

   c. In `prompt`, before `createUserMessage`, check a session-keyed flag
      and route into the existing queue if busy — instead of inserting a
      user message that races with in-flight ones.

   Which of these has the fewest knock-on effects on subagent dispatch,
   workspace router middleware, compaction, summarization, and TUI
   resumption? We'd like to ship something narrow.

3. **What's the cleanest workaround that requires NO opencode patch?**
   Our current best guess is "force every `opencode-send` invocation that
   targets the coordinator to use a single fixed `--cwd` (the coordinator's
   own directory)." We believe this collapses all calls into one `Instance`
   so the busy guard works and queued callbacks fire properly. Will this
   reliably eliminate the race, or are there additional non-directory-scoped
   sources of concurrency we're missing?

4. **Are queued callbacks even safe under our usage pattern?**
   The "queue" path enqueues a callback into `state()[sessionID].callbacks`
   and returns the next assistant message. If 4 callers queue while loop #1
   is mid-tool-call, do they each get the *next* assistant message, or do
   they share one? Skim of `loop` suggests they all get the same next
   `assistant` message and their *original* user-message inserts are still
   present, never replied-to. Does that itself silently corrupt the session?

5. **Anthropic's "assistant message prefill" rule:** does the Vertex
   route to Claude really forbid this, or is the rejection coming from
   the AI SDK trimming/normalising the messages array before it hits
   Anthropic? The error verbiage ("does not support assistant message
   prefill") sounds like Anthropic, but the model usually allows
   assistant prefill on `messages.create`. Could this be a Vertex-specific
   restriction? A Bedrock-style restriction? An AI SDK validation layer?
   We'd like to know whether retrying with a synthetic empty user message
   appended is a reasonable rescue strategy or a symptom of deeper drift.

6. **For multi-agent swarms on a single `opencode serve`,** is there a
   recommended topology? We have one coordinator session being addressed
   by ≥4 workers. Should each pair of "talker → coordinator" go through
   a dedicated outbox file/lock? Should the coordinator be reading a
   single inbox stream rather than receiving inbound `prompt_async`?
   What patterns are people using in practice for multi-Claude
   orchestration on a single OpenCode instance?

7. **Open-source coordination:** if we PR a fix to `sst/opencode`
   upstream (we can also land it in our `opencode-patched` fork
   immediately), what's the minimum reproduction case we should attach?
   Is a small bash test that fires N concurrent `prompt_async` requests
   against the same session with N different `x-opencode-directory`
   headers sufficient, or do reviewers tend to want a TS-level repro?

## Constraints

- We can patch and ship `johnnymo87/opencode-patched` ourselves on a
  same-day timeline (it auto-updates via GitHub Actions).
- We cannot move off Anthropic on Vertex (provider/model is fixed by org
  account).
- We cannot serialize work onto a single session — multi-agent
  orchestration is the whole point.
- We cannot drop the `x-opencode-directory` header globally; some other
  sessions rely on it for filesystem permission scoping.
- The fix needs to be small and reviewable; we don't want to refactor
  `Instance.state`'s keying model wholesale.

## Specific requests

- Please critique our root-cause reasoning and call out anything we got
  wrong.
- Please rank the proposed fixes by combination of correctness and blast
  radius.
- Please surface any prior `sst/opencode` issues, PRs, or discussions on
  multi-cwd / multi-prompt races, especially around `prompt_async`,
  `Instance.state`, or the busy guard.
- Please point to upstream Anthropic / Vertex documentation that confirms
  whether assistant-prefill is allowed in this configuration.
