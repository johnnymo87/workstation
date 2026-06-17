# OpenCode Server Multicore & Concurrency Investigation

**Date:** June 17, 2026  
**Host:** cloudbox  
**Environment:** NixOS, Bun, Node  
**Repository under investigation:** `~/projects/opencode` (HEAD `0b7038baa` / origin tip `10b6672be`)

---

## Executive Summary

Expecting `opencode serve` to distribute its workload across multiple CPU cores out-of-the-box is a **category error**. 

Under the hood, `opencode serve` runs as a **single JavaScript process** running on a **single event loop**. While the underlying Bun runtime is written in C++ and can utilize system threads for file-system operations or SQLite page operations, all of the server routing, Event-Sourcing stream evaluations, and agent-loop execution logic run on a single main thread. As a result, the entire server is fundamentally bottlenecked by a single CPU core.

This document analyzes why the server pegs 1–2 cores under ~30 attached clients, dissects the `MaxListenersExceededWarning` warning, evaluates concrete multi-core load distribution architectures (including clustering and proxying), and recommends immediate and long-term action items with specific code citations.

---

## 1. OpenCode Server Architecture & Concurrency Model

### Single Event Loop Execution
The entry point of the headless server is defined in:
* **`packages/opencode/src/cli/cmd/serve.ts:6-21`**

When `opencode serve` starts, it calls `Server.listen(opts)` and holds the process alive using Effect's `Effect.never`. The HTTP server is set up in:
* **`packages/opencode/src/server/server.ts:182-192`**

```typescript
function serverLayer(opts: { port: number; hostname: string }) {
  const server = createServer()
  // ...
  return Layer.mergeAll(
    NodeHttpServer.layer(() => server, { port: opts.port, host: opts.hostname, gracefulShutdownTimeout: "1 second" }),
    // ...
  )
}
```

This invokes a standard Node `node:http` `createServer` layer. Although executed using **Bun** as the JS runtime, it does *not* utilize `Bun.serve`'s multi-threaded clustering capabilities (like `reusePort`). It runs entirely inside Node's standard HTTP server abstraction, bound to the single-threaded event loop.

### Concurrency of Session Runs
All agent loops are executed in-process on this single thread. When a POST is sent to `promptAsync` or `/api/session/:sessionID/prompt` (e.g., from the `lgtm` PR-review daemon), it triggers the prompt handler defined in:
* **`packages/opencode/src/server/routes/instance/httpapi/handlers/session.ts:311-318`**

```typescript
    const promptAsync = Effect.fn("SessionHttpApi.promptAsync")(function* (ctx: {
      params: { sessionID: SessionID }
      payload: typeof PromptPayload.Type
    }) {
      yield* requireSession(ctx.params.sessionID)
      yield* promptSvc.prompt({ ...ctx.payload, sessionID: ctx.params.sessionID }).pipe(
        // ...
        Effect.forkIn(scope, { startImmediately: true }),
      )
      return HttpApiSchema.NoContent.make()
    })
```

The call to `promptSvc.prompt` is forked as a fiber within the server process runtime (`Effect.forkIn`). There are **no worker threads, child processes, or subprocesses** spawned for the active sessions; all concurrently executing sessions on the box run their thinking loops, tool calls, and workspace file-indexing operations within the *same* JavaScript thread.

### CPU-Heavy Workloads & Scaling Bottlenecks
Under ~30 concurrently attached TUI clients, the server saturates 1–2 CPU cores (pegging 100-160% CPU) due to two major bottlenecks:

#### A. O(N * M) Global Event Broadcasting & Stream Processing
Every TUI client attached via `opencode attach` establishes a Server-Sent Events (SSE) stream at `/event` to receive live updates.
* **`packages/opencode/src/server/routes/instance/httpapi/handlers/event.ts:35`**
```typescript
const unsubscribe = yield* events.listen((event) => Effect.sync(() => Queue.offerUnsafe(queue, event)))
```
This registers a global event listener for *every* attached client. Whenever any session on the server publishes an event, it is pushed into the unbounded queue of **every single attached client**, regardless of whether they own that session or project.

Each client's individual stream then wakes up, evaluates the JS, runs a directory/workspace filter, and discards the event if it doesn't match:
```typescript
    const stream = Stream.fromQueue(queue).pipe(
      Stream.filter(
        (event) =>
          event.location?.directory === instance.directory &&
          (event.location.workspaceID === undefined || event.location.workspaceID === workspaceID),
      ),
      // ...
```
In a system with $N$ attached clients generating $M$ events (from active thinking/tool loops), this creates an $O(N \times M)$ JS processing storm on a single CPU core, resulting in major event loop congestion and heavy garbage collection.

#### B. `project copy refresh` Subprocess Spawning (A 1.17.x Regression)
In the newer 1.17.x line (introduced via PR #30139 on June 2, 2026), on every location/instance boot (including TUI reconnects), the server fires:
* **`packages/core/src/project/copy.ts:126-144`** (`ProjectCopy.refreshAfterBoot`)
* **`packages/core/src/project/copy.ts:233-288`** (`refresh()`)

This function queries all directories, runs `fs.isDir` with **unbounded concurrency**, and spawns a `git worktree list` **subprocess** for *each directory* with **unbounded concurrency**:
```typescript
// packages/core/src/project/copy.ts
const list = yield* directories.list(projectID)
// Spawns subprocesses concurrently for every directory!
```
Under a thundering-herd reconnect of ~61 clients, this fires a massive storm of concurrent refreshes and git subprocesses, completely blocking the JS event loop, ballooning RSS to ~20GB, and causing a total server wedge.

---

## 2. Load Distribution Options Across Cores

Because `opencode serve` is single-threaded, spreading its load across multiple cores requires a multi-process or clustering approach. The table below ranks and evaluates these options:

### Ranked Concrete Options & Tradeoffs

| Rank | Strategy | Feasibility / Compatibility | Tradeoffs |
|---|---|---|---|
| **1** | **Subprocess-per-session (Private Worker Model)** | **High Compatibility** (Native) | **Pros:** Keeps the web server lightweight and responsive; isolates memory/CPU of heavy LLM sessions onto their own subprocesses.<br>**Cons:** Requires robust IPC/socket connection to stream events back to the parent web server's client SSE router. |
| **2** | **Reverse Proxy with Sticky Routing (e.g., Caddy/Nginx)** | **Medium Compatibility** (Requires Sync Hook) | **Pros:** Distributes HTTP traffic and SSE streams across $K$ independent instances of `opencode serve` running on ports $P_1, \dots, P_K$.<br>**Cons:** **Breaks event streaming.** Since event buses (`GlobalBus` and `EventV2` PubSub) are memory-only inside each process, Process A cannot broadcast thinking updates to a TUI attached to Process B without a shared pub/sub backend (e.g., Redis or SQLite triggers). |
| **3** | **Bun/Node Native Clustering (`worker_threads` / `cluster`)** | **Low Compatibility** (High Fork Maintenance) | **Pros:** Bun/Node-native cluster allows port sharing across child processes.<br>**Cons:** Multi-process database lock contentions on the shared `opencode.db` SQLite database, and still requires synchronizing the in-memory event PubSub across cluster workers. |

### Architectural Conclusion
Running multiple independent `opencode serve` processes behind a reverse proxy is **fundamentally incompatible** with OpenCode's current design because the streaming event bus (`GlobalBus` and `EventV2` PubSub) is entirely **in-memory**. A TUI attached to process $A$ would appear frozen/wedged if the session's active agent loop was running on process $B$.

The most native, compatible path is **Subprocess-per-session** (spawning an isolated child process when starting a session run), but this requires substantial upstream changes to synchronize event streams between the child process and the main serve process.

---

## 3. Dissecting the CPU-Spin & MaxListenersExceededWarning

### Is the warning a known leak?
No. The `MaxListenersExceededWarning (EventTarget memory leak, 11 listeners)` is **not** an actual memory leak, but rather an unconfigured default warning threshold.

`GlobalBus` is a global instance of `GlobalBusEmitter`, which extends Node's `EventEmitter`:
* **`packages/opencode/src/bus/global.ts:11-22`**
```typescript
class GlobalBusEmitter extends EventEmitter<{
  event: [GlobalEvent]
}> { ... }
export const GlobalBus = new GlobalBusEmitter()
```

Every time a client connects to the `/event` stream, it registers a listener on `GlobalBus` to detect instance disposal:
* **`packages/opencode/src/server/routes/instance/httpapi/handlers/event.ts:50-59`**
```typescript
      return Effect.acquireRelease(
        Effect.sync(() => GlobalBus.on("event", listener)),
        () => Effect.sync(() => GlobalBus.off("event", listener)),
      )
```

Node's `EventEmitter` has a default limit of **10** concurrent listeners. Because `GlobalBus` is a global singleton, having **11 or more concurrently attached clients** immediately triggers Node's warning:
```
(node:12345) MaxListenersExceededWarning: Possible EventEmitter memory leak detected. 
11 event listeners added to [GlobalBusEmitter]. Use emitter.setMaxListeners() to increase limit
```

### Is there a fix on origin?
No. There are **zero calls** to `setMaxListeners` on `GlobalBus` anywhere in the repository (including origin tip `10b6672be`). The warning remains a latent false-positive that alarms system monitoring whenever 11+ clients attach.

---

## 4. Workstation systemd Unit Analysis

The `opencode-serve` systemd unit is defined in:
* **`hosts/cloudbox/configuration.nix:490-609`**

```nix
  systemd.services.opencode-serve = {
    description = "OpenCode headless serve";
    wantedBy = [ "multi-user.target" ];
    # ...
    serviceConfig = {
      Type = "simple";
      User = "dev";
      Group = "dev";
      WorkingDirectory = "/home/dev";
      ExecStart = "${pkgs.writeShellScript "opencode-serve-start" ''
        # ...
        exec /home/dev/.nix-profile/bin/opencode serve --port 4096 --hostname 127.0.0.1
      ''}";
      MemoryMax = "40G";
      MemoryHigh = "32G";
      OOMScoreAdjust = "500";
      Restart = "always";
      RestartSec = 10;
    };
  };
```

### Key Service Properties
1. **Single Instance, Single Process:** The unit starts exactly one `opencode serve` instance bound to port `4096`. There are no multi-process or cluster wrappers configured.
2. **Heavy Resource Allocation:** It is configured with `MemoryHigh = "32G"` and `MemoryMax = "40G"`, allowing the single JS process to balloon (the 1.17.x thundering-herd reconnect pushed memory to 19.6 GB RSS).
3. **No Thread/CPU Pinning:** The unit contains no CPU limits or core affinity masks (e.g., `CPUAffinity`). It is left to the Linux scheduler, which is forced to squeeze the entire concurrent load of the JS event loop onto a single CPU core.

---

## 5. Recommended Next Steps

To harden the workstation's headless server and avoid CPU saturation/wedging, we recommend the following phased mitigations:

### Step 1: Mitigate the $O(N \times M)$ Event Broadcasting Churn (Upstream Patch)
Instead of pushing all global events into the stream queues and filtering them inside JS stream fibers, filter them **before offering to the queue** in `packages/opencode/src/server/routes/instance/httpapi/handlers/event.ts:35`:

```typescript
// Change this:
const unsubscribe = yield* events.listen((event) => Effect.sync(() => Queue.offerUnsafe(queue, event)))

// To this:
const unsubscribe = yield* events.listen((event) => {
  if (
    event.location?.directory === instance.directory &&
    (event.location.workspaceID === undefined || event.location.workspaceID === workspaceID)
  ) {
    return Effect.sync(() => Queue.offerUnsafe(queue, event))
  }
  return Effect.void
})
```
This single change prevents waking up JS fibers and performing heap allocations for irrelevant events on other sessions, reducing event-loop pressure from $O(N \times M)$ to $O(M_{\text{local}})$.

### Step 2: Silence the False-Positive Leak Warning
In `packages/opencode/src/bus/global.ts`, increase or disable the default warning limit on the global emitter:
```typescript
export const GlobalBus = new GlobalBusEmitter()
GlobalBus.setMaxListeners(100) // Increase threshold to 100 for multi-session hosts
```

### Step 3: Implement Debouncing & Concurrency Limits for `project copy refresh`
File an upstream PR to patch `packages/core/src/project/copy.ts:238`:
* Replace `{ concurrency: "unbounded" }` with a capped concurrency limit (e.g., `{ concurrency: 4 }`).
* Debounce or deduplicate the boot refresh per `projectID` so multiple reconnecting TUIs for the same project coalesce into a single refresh execution.

### Step 4: Continue Using the Paced TUI Restore Mitigation
Avoid bulk-restoring dozens of clients simultaneously. The paced restoration script `~/restore-work-sessions.sh` (which spaces opens with a 5s gap and a health check gate) is the single most effective operational defense against triggering thundering-herd wedges on the box today.
