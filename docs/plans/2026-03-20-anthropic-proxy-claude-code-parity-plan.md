# Anthropic Proxy Claude Code Parity Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Update the managed Anthropic proxy/plugin so OAuth exchange, refresh, and message requests match the most relevant Claude Code v2.1.80 behavior identified in `ex-machina-co/opencode-anthropic-auth` PR `#13`.

**Architecture:** Keep the existing managed `plugin.ts` plus local proxy server, but split outbound request shaping by flow. OAuth exchange and refresh move to `platform.claude.com` with `axios/1.13.6`, while Anthropic API calls continue through the local proxy with Claude Code style message shaping, updated version constants, billing injection, and prompt rewriting.

**Tech Stack:** TypeScript running under Bun, managed OpenCode plugin files in `assets/opencode/plugins/anthropic-oauth-proxy/`, Nix-managed service/docs, live verification with `home-manager`, `systemctl --user`, and `opencode`.

---

### Task 1: Add route-specific user-agent and OAuth endpoint parity in the proxy

**Files:**
- Modify: `assets/opencode/plugins/anthropic-oauth-proxy/index.ts`
- Test: `assets/opencode/plugins/anthropic-oauth-proxy/index.test.ts`

**Step 1: Write the failing test**

Add tests that prove:

- `/oauth/exchange` forwards to `https://platform.claude.com/v1/oauth/token` with `User-Agent: axios/1.13.6`
- `/oauth/refresh` forwards to `https://platform.claude.com/v1/oauth/token` with `User-Agent: axios/1.13.6`
- `/v1/messages` still forwards to `https://api.anthropic.com/v1/messages` with `User-Agent: claude-code/2.1.80`

```ts
it("uses axios user-agent for oauth exchange", async () => {
  // send /oauth/exchange through createProxyHandler
  // inspect upstream request URL and headers
})

it("uses claude-code user-agent for messages", async () => {
  // send /v1/messages through createProxyHandler
  // inspect upstream request headers
})
```

**Step 2: Run test to verify it fails**

Run: `bun test assets/opencode/plugins/anthropic-oauth-proxy/index.test.ts`

Expected: FAIL because the proxy still uses one global user-agent policy and `console.anthropic.com` defaults.

**Step 3: Write minimal implementation**

In `index.ts`:

- change the console base default from `https://console.anthropic.com` to `https://platform.claude.com`
- add route-aware user-agent selection helpers rather than `applyUserAgent()` using one value for all requests
- keep `claude-code/2.1.80` for message requests
- use `axios/1.13.6` for exchange and refresh requests

**Step 4: Run test to verify it passes**

Run: `bun test assets/opencode/plugins/anthropic-oauth-proxy/index.test.ts`

Expected: PASS.

**Step 5: Commit**

```bash
git add assets/opencode/plugins/anthropic-oauth-proxy/index.ts assets/opencode/plugins/anthropic-oauth-proxy/index.test.ts
git commit -m "fix: match auth flow user agents in anthropic proxy"
```

### Task 2: Update plugin OAuth URLs, scopes, and exchange deduplication

**Files:**
- Modify: `assets/opencode/plugins/anthropic-oauth-proxy/plugin.ts`
- Test: `assets/opencode/plugins/anthropic-oauth-proxy/plugin.test.ts`

**Step 1: Write the failing test**

Add tests that prove:

- authorize URLs use `platform.claude.com` for the console path
- redirect URI is `https://platform.claude.com/oauth/code/callback`
- scope string matches the expanded v2.1.80 scope set
- duplicate concurrent `exchange()` calls with the same code result in one outbound proxy call

```ts
it("uses platform.claude.com callback and scopes", async () => {
  // authorize and inspect url params
})

it("deduplicates concurrent exchange calls", async () => {
  // invoke callback twice concurrently
  // expect one fetch to /oauth/exchange
})
```

**Step 2: Run test to verify it fails**

Run: `bun test assets/opencode/plugins/anthropic-oauth-proxy/plugin.test.ts`

Expected: FAIL because the plugin still uses old URLs, old scopes, and non-deduplicated exchange.

**Step 3: Write minimal implementation**

In `plugin.ts`:

- migrate authorize and redirect URL generation to `platform.claude.com`
- update the OAuth scopes to `org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload`
- normalize exchange payload generation around the new redirect URI
- add an in-memory pending-promise guard for duplicate exchange calls with the same code

**Step 4: Run test to verify it passes**

Run: `bun test assets/opencode/plugins/anthropic-oauth-proxy/plugin.test.ts`

Expected: PASS.

**Step 5: Commit**

```bash
git add assets/opencode/plugins/anthropic-oauth-proxy/plugin.ts assets/opencode/plugins/anthropic-oauth-proxy/plugin.test.ts
git commit -m "fix: update anthropic oauth flow for platform parity"
```

### Task 3: Align billing/version constants and Anthropic system-prompt rewriting

**Files:**
- Modify: `assets/opencode/plugins/anthropic-oauth-proxy/index.ts`
- Modify: `assets/opencode/plugins/anthropic-oauth-proxy/billing.ts`
- Modify: `assets/opencode/plugins/anthropic-oauth-proxy/request-shape.ts`
- Test: `assets/opencode/plugins/anthropic-oauth-proxy/billing.test.ts`
- Test: `assets/opencode/plugins/anthropic-oauth-proxy/request-shape.test.ts`
- Test: `assets/opencode/plugins/anthropic-oauth-proxy/index.test.ts`

**Step 1: Write the failing test**

Add tests that prove:

- billing headers now use version `2.1.80`
- billing injection still happens only on `/v1/messages`
- text system blocks rewrite `OpenCode` -> `Claude Code` and `opencode` -> `Claude`
- non-text blocks are unchanged

```ts
it("builds a 2.1.80 billing header", () => {
  expect(buildBillingHeader(...)).toContain("cc_version=2.1.80.")
})

it("rewrites system prompt text blocks for anthropic messages", () => {
  // expect OpenCode wording rewritten in text blocks only
})
```

**Step 2: Run test to verify it fails**

Run: `bun test assets/opencode/plugins/anthropic-oauth-proxy/billing.test.ts assets/opencode/plugins/anthropic-oauth-proxy/request-shape.test.ts assets/opencode/plugins/anthropic-oauth-proxy/index.test.ts`

Expected: FAIL because current defaults are still `2.1.76` and prompt rewriting is not implemented.

**Step 3: Write minimal implementation**

Implement:

- `2.1.80` defaults in proxy config and billing helpers
- a pure helper in `request-shape.ts` that rewrites only Anthropic text system blocks
- message-path-only application of that helper inside `index.ts`, alongside billing injection and optional cache stripping

**Step 4: Run test to verify it passes**

Run the same tests.

Expected: PASS.

**Step 5: Commit**

```bash
git add assets/opencode/plugins/anthropic-oauth-proxy/index.ts assets/opencode/plugins/anthropic-oauth-proxy/billing.ts assets/opencode/plugins/anthropic-oauth-proxy/request-shape.ts assets/opencode/plugins/anthropic-oauth-proxy/billing.test.ts assets/opencode/plugins/anthropic-oauth-proxy/request-shape.test.ts assets/opencode/plugins/anthropic-oauth-proxy/index.test.ts
git commit -m "feat: align anthropic message shaping with claude code"
```

### Task 4: Refresh docs and verification instructions

**Files:**
- Modify: `.opencode/skills/anthropic-oauth-proxy/SKILL.md`
- Modify: `AGENTS.md`
- Modify: `docs/plans/2026-03-20-anthropic-proxy-claude-code-parity-design.md`

**Step 1: Write the failing test**

List the facts that docs must now state:

- auth exchange and refresh use `platform.claude.com`
- auth-path user-agent differs from message-path user-agent
- the proxy now targets Claude Code parity around v2.1.80

**Step 2: Run test to verify it fails**

Read the current docs and confirm they do not yet mention the new auth-path split.

Expected: FAIL.

**Step 3: Write minimal implementation**

Update docs and operator guidance to reflect the new route-specific parity behavior and how to verify it in logs.

**Step 4: Run test to verify it passes**

Re-read the updated docs.

Expected: PASS.

**Step 5: Commit**

```bash
git add .opencode/skills/anthropic-oauth-proxy/SKILL.md AGENTS.md docs/plans/2026-03-20-anthropic-proxy-claude-code-parity-design.md
git commit -m "docs: document anthropic proxy auth path parity"
```

### Task 5: Apply on devbox and verify the live auth flow

**Files:**
- Verify: `assets/opencode/plugins/anthropic-oauth-proxy/plugin.ts`
- Verify: `assets/opencode/plugins/anthropic-oauth-proxy/index.ts`
- Verify: `users/dev/anthropic-oauth-proxy.nix`

**Step 1: Write the failing test**

Define the live verification expectations:

- `home-manager switch --flake .#dev` succeeds
- `anthropic-oauth-proxy.service` is running
- proxy logs show `axios/1.13.6` on `/oauth/exchange` and `/oauth/refresh`
- proxy logs show `claude-code/2.1.80` on `/v1/messages`
- Anthropic login and a real `opencode run` request succeed

**Step 2: Run test to verify it fails**

Run the current live verification before the fix.

```bash
home-manager switch --flake .#dev
systemctl --user restart anthropic-oauth-proxy.service
systemctl --user status anthropic-oauth-proxy.service --no-pager
opencode run "say hello in five words" --model anthropic/claude-opus-4-6
```

Expected: FAIL with the current refresh/exchange `429` behavior or stale request shaping.

**Step 3: Write minimal implementation**

Apply Tasks 1-4 and re-apply Home Manager.

**Step 4: Run test to verify it passes**

Run:

```bash
nix run home-manager -- switch --flake .#dev
systemctl --user restart anthropic-oauth-proxy.service
systemctl --user status anthropic-oauth-proxy.service --no-pager
journalctl --user -u anthropic-oauth-proxy.service --no-pager -n 50
opencode providers login
opencode run "say hello in five words" --model anthropic/claude-opus-4-6
```

Expected: PASS, with logs showing route-specific user-agent behavior and successful Anthropic auth/use.

**Step 5: Commit**

```bash
git add assets/opencode/plugins/anthropic-oauth-proxy users/dev/anthropic-oauth-proxy.nix .opencode/skills/anthropic-oauth-proxy/SKILL.md AGENTS.md
git commit -m "fix: restore anthropic oauth proxy compatibility"
```
