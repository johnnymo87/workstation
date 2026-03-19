# Anthropic OAuth Proxy Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a local Anthropic OAuth proxy plus replacement Anthropic auth plugin so `opencode-cached` can use Anthropic OAuth through a maintainable shim instead of a growing fork patch.

**Architecture:** Run `opencode-cached` with built-in default plugins disabled, load a local Anthropic replacement plugin, and have that plugin route Anthropic OAuth traffic through a small local proxy. The proxy emits structured logs and supports feature flags for Claude Code style `User-Agent`, billing marker injection, and optional cache-marker stripping.

**Tech Stack:** TypeScript or Bun/Node service, local config/env vars, GitHub issue evidence, existing local OpenCode install for manual verification.

**Upstream Context:** `anomalyco/opencode` currently has open Anthropic OAuth breakage reports (`#17910`, `#18267`, `#18265`) and has already merged PR `#18186`, which removes built-in Anthropic OAuth support. Plan on a local workaround, not an imminent upstream restoration.

---

### Task 1: Identify the cleanest local integration point

**Files:**
- Inspect: `../opencode-cached/README.md`
- Inspect: `../opencode/`
- Create: `docs/plans/2026-03-19-anthropic-oauth-proxy-notes.md` (optional scratch notes if needed)

**Step 1: Write the failing test**

There is no code yet, so first define the expected routing contract in a small notes file or test scaffold: OpenCode must be able to target a local proxy for Anthropic without changing unrelated providers.

**Step 2: Run test to verify it fails**

Run the minimal repro command you currently use with Anthropic OAuth and confirm traffic still goes directly upstream.

Expected: request bypasses local proxy or there is no local proxy target yet.

**Step 3: Write minimal implementation**

Choose one integration path:

- replacement plugin + wrapper/config, if supported
- config-only provider base URL override, if supported
- minimal patch only for routing, if routing cannot be configured externally

Document the chosen path before building the proxy.

**Step 4: Run test to verify it passes**

Run the same repro and confirm Anthropic traffic reaches the local plugin/proxy entrypoint.

Expected: proxy logs one inbound Anthropic request.

**Step 5: Commit**

```bash
git add docs/plans/2026-03-19-anthropic-oauth-proxy-plan.md docs/plans/2026-03-19-anthropic-oauth-proxy-design.md
git commit -m "docs: plan anthropic oauth proxy workaround"
```

### Task 2: Scaffold the replacement plugin and proxy skeleton

**Files:**
- Create: `../anthropic-oauth-proxy/package.json`
- Create: `../anthropic-oauth-proxy/src/index.ts`
- Create: `../anthropic-oauth-proxy/src/config.ts`
- Create: `../anthropic-oauth-proxy/src/log.ts`
- Create: `../anthropic-oauth-proxy/src/plugin.ts`
- Create: `../anthropic-oauth-proxy/README.md`
- Test: `../anthropic-oauth-proxy/src/index.test.ts`
- Test: `../anthropic-oauth-proxy/src/plugin.test.ts`

**Step 1: Write the failing test**

Write a test proving the plugin can load for provider `anthropic`, forward Anthropic requests to the proxy, and that the proxy classifies requests as `usage`, `refresh`, or `messages` while emitting structured log records without secrets.

```ts
it("logs request class and status without secrets", async () => {
  // send synthetic request through proxy
  // expect structured log fields: type, path, status
  // expect no access token or refresh token in output
})
```

**Step 2: Run test to verify it fails**

Run: `bun test ../anthropic-oauth-proxy/src/index.test.ts`

Expected: FAIL because plugin/proxy and logging code do not exist yet.

**Step 3: Write minimal implementation**

Add a local plugin plus proxy server that forwards requests upstream and logs only safe metadata.

**Step 4: Run test to verify it passes**

Run: `bun test ../anthropic-oauth-proxy/src/index.test.ts`

Expected: PASS with a log entry containing request type and status and a plugin path that targets the proxy.

**Step 5: Commit**

```bash
git add ../anthropic-oauth-proxy
git commit -m "feat: add anthropic oauth proxy skeleton"
```

### Task 3: Add Claude Code style User-Agent override

**Files:**
- Modify: `../anthropic-oauth-proxy/src/index.ts`
- Modify: `../anthropic-oauth-proxy/src/config.ts`
- Test: `../anthropic-oauth-proxy/src/index.test.ts`

**Step 1: Write the failing test**

Write a test proving that when the feature flag is enabled, forwarded requests use `User-Agent: claude-code/<version>` for usage, refresh, and message paths.

```ts
it("overrides user-agent when enabled", async () => {
  // forward request through proxy
  // inspect upstream request headers
  // expect claude-code style user agent
})
```

**Step 2: Run test to verify it fails**

Run: `bun test ../anthropic-oauth-proxy/src/index.test.ts -t "overrides user-agent when enabled"`

Expected: FAIL because original headers are still forwarded unchanged.

**Step 3: Write minimal implementation**

Add a config flag and inject the Claude Code style `User-Agent` only when enabled.

**Step 4: Run test to verify it passes**

Run the same test.

Expected: PASS.

**Step 5: Commit**

```bash
git add ../anthropic-oauth-proxy/src
git commit -m "feat: add claude-code user-agent override"
```

### Task 4: Add billing marker experiment

**Files:**
- Modify: `../anthropic-oauth-proxy/src/index.ts`
- Create: `../anthropic-oauth-proxy/src/billing.ts`
- Test: `../anthropic-oauth-proxy/src/billing.test.ts`
- Test: `../anthropic-oauth-proxy/src/index.test.ts`

**Step 1: Write the failing test**

Write one unit test for the derived marker format and one integration test proving the marker is injected only when enabled.

```ts
it("creates deterministic billing marker from configured salt inputs", () => {
  expect(createBillingMarker(sampleRequest)).toMatch(/^x-anthropic-billing-header:/)
})

it("injects billing marker only when enabled", async () => {
  // expect marker present only with flag on
})
```

**Step 2: Run test to verify it fails**

Run: `bun test ../anthropic-oauth-proxy/src/billing.test.ts ../anthropic-oauth-proxy/src/index.test.ts`

Expected: FAIL because billing helper does not exist.

**Step 3: Write minimal implementation**

Implement deterministic marker generation and guarded injection. Keep all constants isolated for easy rollback.

**Step 4: Run test to verify it passes**

Run the same tests.

Expected: PASS.

**Step 5: Commit**

```bash
git add ../anthropic-oauth-proxy/src
git commit -m "feat: add billing marker experiment"
```

### Task 5: Add OAuth cache-marker stripping experiment

**Files:**
- Modify: `../anthropic-oauth-proxy/src/index.ts`
- Create: `../anthropic-oauth-proxy/src/request-shape.ts`
- Test: `../anthropic-oauth-proxy/src/request-shape.test.ts`

**Step 1: Write the failing test**

Write a test proving that OAuth request bodies have Anthropic cache markers removed when the feature flag is enabled, while non-Anthropic or disabled cases are left untouched.

```ts
it("strips anthropic cache markers only when enabled", () => {
  // expect cacheControl/cache_control removed from relevant system blocks
})
```

**Step 2: Run test to verify it fails**

Run: `bun test ../anthropic-oauth-proxy/src/request-shape.test.ts`

Expected: FAIL because request rewriting is not implemented.

**Step 3: Write minimal implementation**

Add a pure request-shape helper that removes only the known cache marker fields we want to test.

**Step 4: Run test to verify it passes**

Run the same test.

Expected: PASS.

**Step 5: Commit**

```bash
git add ../anthropic-oauth-proxy/src
git commit -m "feat: add oauth cache marker stripping"
```

### Task 6: Add a manual verification script and matrix

**Files:**
- Create: `../anthropic-oauth-proxy/scripts/run-matrix.ts`
- Modify: `../anthropic-oauth-proxy/README.md`
- Test: manual verification against live OAuth setup

**Step 1: Write the failing test**

Define the expected experiment matrix in the README:

- baseline
- user-agent only
- user-agent + billing
- user-agent + billing + cache-strip

State what result counts as improvement for each endpoint class.

**Step 2: Run test to verify it fails**

Run the manual matrix without the script.

Expected: no consistent way to compare feature combinations.

**Step 3: Write minimal implementation**

Add a helper script that runs named scenarios and prints which toggles were active.

**Step 4: Run test to verify it passes**

Run: `bun run ../anthropic-oauth-proxy/scripts/run-matrix.ts`

Expected: a clear scenario list and instructions for live verification.

**Step 5: Commit**

```bash
git add ../anthropic-oauth-proxy/scripts ../anthropic-oauth-proxy/README.md
git commit -m "docs: add anthropic proxy verification matrix"
```

### Task 7: Verify end-to-end behavior with live Anthropic OAuth

**Files:**
- Use: `../anthropic-oauth-proxy/README.md`
- Use: local OpenCode config pointing Anthropic traffic at proxy

**Step 1: Write the failing test**

Pick one real repro for each request class:

- `/api/oauth/usage` returning `429`
- token refresh failure path
- one minimal Claude model request

Document current baseline results first.

**Step 2: Run test to verify it fails**

Run the baseline scenario.

Expected: reproduce the existing failure.

**Step 3: Write minimal implementation**

Enable one feature flag at a time in this order:

1. `User-Agent`
2. billing marker
3. cache-marker stripping

Record what changed after each step.

**Step 4: Run test to verify it passes**

Re-run the same repro after each flag change.

Expected: identify which mutation changes the failing behavior.

**Step 5: Commit**

```bash
git add ../anthropic-oauth-proxy/README.md
git commit -m "docs: record anthropic oauth proxy findings"
```

### Task 8: Optional tiny routing patch if plugin/config routing is impossible

**Files:**
- Modify: `../opencode-cached/patches/caching.patch`
- Modify: `../opencode-cached/README.md`
- Test: local patched build of `opencode-cached`

**Step 1: Write the failing test**

Document the exact routing limitation preventing config-only proxy usage.

**Step 2: Run test to verify it fails**

Attempt config-only routing and confirm Anthropic traffic still cannot be redirected.

Expected: failure to target local proxy.

**Step 3: Write minimal implementation**

Add the smallest possible patch that only redirects Anthropic base URL or headers required to reach the local proxy. Do not add auth fingerprint logic here.

**Step 4: Run test to verify it passes**

Build patched `opencode-cached` and confirm Anthropic traffic reaches the proxy.

Expected: PASS.

**Step 5: Commit**

```bash
git add ../opencode-cached/patches/caching.patch ../opencode-cached/README.md
git commit -m "feat: route anthropic traffic through local proxy"
```
