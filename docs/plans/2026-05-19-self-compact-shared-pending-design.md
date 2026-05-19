# Self-Compact Shared Pending Design

## Problem

`self_compact_and_resume` queues a resumption prompt in a plugin-local `Map`, then triggers manual compaction when the session goes idle. Durable diagnostics showed a failed run where:

- `tool.execute` stashed the prompt with `pendingSize=1`.
- `onStatus` promoted the entry and called `/summarize` with `pendingSize=1`.
- `session.compacted` was observed by a self-compact handler with `pendingSize=0` and no matching key.
- `/prompt_async` was never attempted.

This proves the queued prompt and the compaction event can live in different self-compact plugin instances inside the same serve process. A plugin-local pending map is therefore the wrong storage boundary.

## Decision

Use a process-wide pending map stored on `globalThis` under a `Symbol.for(...)` key. Every self-compact plugin instance in the process will read and write the same `Map<string, PendingResume>`.

This is the smallest fix for the observed failure: it preserves the current three-stage flow, keeps the state in memory, and avoids changing opencode's bus or instance routing.

## Alternatives

1. **Process-wide shared map.** Minimal code and directly addresses the observed cross-instance split. It does not survive process restart, which matches the current in-memory behavior.
2. **Disk-backed pending store.** More robust across restarts, but adds serialization, cleanup, and stale-state handling for a case that current behavior does not promise to support.
3. **Patch opencode routing or bus delivery.** Potentially deeper root fix, but broader and riskier because plugin instance and bus scoping are core opencode behavior.

## Implementation

- Export a helper that returns the shared pending map.
- Replace `new Map<string, PendingResume>()` in the plugin factory with the shared helper.
- Keep existing stale-entry eviction in `tool.execute`.
- Keep durable diagnostics until the fix is verified in a live compaction.

## Testing

Add a regression test that simulates two plugin instances:

- Instance A stashes a resumption prompt through the shared map.
- Instance B handles `session.compacted` using a separately obtained shared map.
- The test must prove `callPromptAsync` receives the stashed prompt and the shared entry is cleared.

Existing tests for single-instance behavior, durable diagnostics, `/summarize`, and `/prompt_async` must continue to pass.
