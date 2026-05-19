# Self-Compact Shared Pending Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make `self_compact_and_resume` deliver its queued resumption prompt even when compaction events are observed by a different plugin instance in the same serve process.

**Architecture:** Store pending resumption prompts in a process-wide `Map` on `globalThis` behind a `Symbol.for(...)` key. Each plugin factory invocation obtains the same shared map, while existing handlers keep their current responsibilities.

**Tech Stack:** TypeScript, Bun/Vitest, Nix-built opencode plugin bundle, home-manager deployment.

---

### Task 1: Add Shared Pending Regression Test

**Files:**
- Modify: `assets/opencode/plugins/test/self-compact.test.ts`

**Step 1: Write the failing test**

Add a test that gets the shared pending map twice, stashes through the first plugin path, and handles `session.compacted` through the second plugin path.

Expected test behavior:

```ts
const pendingA = getSharedPendingResumes()
const pendingB = getSharedPendingResumes()
expect(pendingB).toBe(pendingA)

await createSelfCompactTool({ pending: pendingA }).execute(
  { prompt: "resume across instances" },
  { sessionID: "ses_shared" },
)
pendingA.get("ses_shared")!.phase = "summarizing"

const callPromptAsync = vi.fn().mockResolvedValue(undefined)
await createOnCompacted({ pending: pendingB, callPromptAsync })({
  event: { type: "session.compacted", properties: { sessionID: "ses_shared" } },
})

expect(callPromptAsync).toHaveBeenCalledWith({
  sessionID: "ses_shared",
  text: "resume across instances",
})
expect(pendingA.has("ses_shared")).toBe(false)
```

**Step 2: Run test to verify it fails**

Run: `bun test assets/opencode/plugins/test/self-compact.test.ts`

Expected: FAIL because `getSharedPendingResumes` is not exported yet.

### Task 2: Implement Shared Pending Map

**Files:**
- Modify: `assets/opencode/plugins/self-compact-impl.ts`
- Modify: `assets/opencode/plugins/self-compact.ts`

**Step 1: Add helper**

Implement:

```ts
const SHARED_PENDING_KEY = Symbol.for("opencode.selfCompact.pendingResumes")

export function getSharedPendingResumes(): Map<string, PendingResume> {
  const g = globalThis as typeof globalThis & {
    [SHARED_PENDING_KEY]?: Map<string, PendingResume>
  }
  g[SHARED_PENDING_KEY] ??= new Map<string, PendingResume>()
  return g[SHARED_PENDING_KEY]
}
```

Place it after `PendingResume` is declared so the type is available.

**Step 2: Use helper in plugin factory**

Replace `new Map<string, PendingResume>()` in `assets/opencode/plugins/self-compact.ts` with `getSharedPendingResumes()` and import the helper.

**Step 3: Run unit tests**

Run: `bun test assets/opencode/plugins/test/self-compact.test.ts`

Expected: PASS.

### Task 3: Build And Deploy Bundle

**Files:**
- No source changes expected beyond Task 2.

**Step 1: Build plugin**

Run: `nix build .#self-compact-plugin`

Expected: build succeeds.

**Step 2: Apply home-manager on cloudbox**

Run: `home-manager switch --flake .#cloudbox`

Expected: activation succeeds.

**Step 3: Verify deployed bundle contains shared helper**

Run: `rg "opencode.selfCompact.pendingResumes|getSharedPendingResumes" ~/.config/opencode/plugins/self-compact.js`

Expected: matches in deployed bundle.

### Task 4: Record Evidence

**Files:**
- Modify: `.beads/issues.jsonl` via `bd update workstation-0de --notes ...`

**Step 1: Update bead**

Record root cause, chosen fix, test results, build results, and deployment status.

**Step 2: Do not commit unless explicitly requested**

This repository has a separate instruction to commit only when the user asks. Leave changes staged/unstaged according to current workflow and summarize exactly what changed.
