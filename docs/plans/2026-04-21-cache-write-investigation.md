# OpenCode Cache-Write Cost Investigation

> **Status:** Investigation complete. Mitigation pending external consult.
> **Date:** 2026-04-21
> **Companion artifacts:**
> - Consult question: `/tmp/research-opencode-cache-write-cost-question.md` (13.5 KB, also archived at `docs/plans/2026-04-21-cache-write-consult-question.md`)
> - Consult answer (when received): `/tmp/research-opencode-cache-write-cost-answer.md`
> - oc-cost tool: `pkgs/oc-cost/`

## Why this exists

`oc-cost --days 30` revealed that **cache writes cost more than cache reads in absolute dollars** ($867 vs $848 over 30 days), despite reads being 92% of input-token volume. The 12.5× write premium ($6.25 vs $0.30 per MTok for Opus) inverts the dollar split. We investigated to find the structural causes and quantify each.

## What we found

### Headline: TTL expiry and per-turn tail-shift dominate

After splitting cache-write events by **inter-message gap within the same session**:

| Inter-message gap | Events | Cache-write tokens | Avg/event | Likely cause | $ at Opus rate |
|---|---:|---:|---:|---|---:|
| < 1 min (steady-state turns) | 19,721 | 46.1M | 2,337 | tail-shift policy (every turn refreshes) | $288 |
| 5m–1h (TTL expired) | **505** | **54.2M** | **107,233** | **5-minute ephemeral cache TTL expired during pause** | **$338** |
| ≥ 1h (long pause) | 161 | 22.1M | 137,060 | full prefix re-write | $138 |
| First msg in a session | 844 | 8.9M | 10,521 | prefix never warm | $56 |
| 1m–5m (within TTL but slow) | 976 | 8.5M | 8,720 | mostly tail-shift | $53 |

**Two buckets dominate (~72% of cache-write cost):**
1. **TTL expiry** (~$338/30d). Sessions naturally pause for 5m+ between bursts; the 5-minute ephemeral cache expires; next turn pays a full prefix re-write.
2. **Tail-shift policy** (~$288/30d). Upstream `applyCaching` in `provider/transform.ts:217-218` does `system.slice(0,2)` + `non_system.slice(-2)`, placing cache_control on the LAST 2 non-system messages every turn. Every assistant turn moves both tail breakpoints to fresh content, forcing a small (~2.3k token) write.

### Hypothesis review (revised from Phase 1 investigator report)

| # | Hypothesis | Original ranking | Revised after empirical verification |
|---|---|---|---|
| H1 | "Last 2 messages" breakpoint policy → tail-shift writes every turn | Top | **Confirmed.** ~19,721 events, ~$288 over 30 days. Patch (opencode-cached) does NOT address this. |
| H4 | High session count amplifies writes (subagent spawning) | Second | **Overstated.** Primary sessions = 14% of sessions but 77% of cost ($1576 of $2044). Subagent contribution (23%) is real but secondary. |
| H2 | Tool order instability cache-busts the prefix | Third | **Already mitigated** by opencode-cached patch (`sortTools: true` for anthropic). Without the patch we'd be paying more. |
| H3 | `Today's date: ${new Date().toDateString()}` in system prompt → daily invalidation | Fourth | **Essentially nonexistent.** Only 1 within-5-minute midnight-crossing event in 30 days. Sessions reliably pause through midnight; TTL would expire the cache anyway. **Don't bother fixing this.** |
| H5 | Provider-side hash sensitivity (umbrella) | Fifth | Conceptually right but not actionable; reduces to H1+H2+H3. |

### Primary vs subagent split (shipped in `oc-cost --by-kind`)

| Kind | Sessions | Msgs | Avg msgs | Avg duration | Cost |
|---|---:|---:|---:|---:|---:|
| primary | 117 | 11,919 | 102 | **23 hours** | $1,576 (77%) |
| subagent | 728 | 10,323 | 14 | **3.4 min** | $468 (23%) |

Primary sessions dominate. Long-tail H1 fixes will hit them most.

## Code locations (verified by reading)

### Upstream (`~/projects/opencode`, branch `dev`, head ~`8751f48a7`)

- `packages/opencode/src/provider/transform.ts:216-265` — `applyCaching()`. The `slice(-2)` policy is here.
- `packages/opencode/src/session/llm.ts:99-160` — assembles `system: string[]` and maps to `[{role: "system", content: x}]` for the SDK. Only first 2 system messages get cached (`applyCaching` slices to 2).
- `packages/opencode/src/session/system.ts:48-66` — `environment()` builds the env block. Line 59: `Today's date: ${new Date().toDateString()}` (the H3 culprit, but H3 is dead per data).
- `packages/opencode/src/session/prompt.ts:1473-1494` — assembles `system` array before passing to `handle.process`.
- `packages/opencode/src/tool/registry.ts:103-154` — tool registration. MCP tool ordering is async-race-dependent in upstream (H2).

### Patched (`~/projects/opencode-cached`, branch `main`)

- `patches/caching.patch` (2294 lines) — single patch derived from upstream PR #5422 by @ormandj. Adds `ProviderConfig` namespace with per-provider cache config.
- Key behavioral changes vs upstream:
  1. Caps breakpoints via `breakpointsApplied >= maxBreakpoints` counter (anthropic: `maxBreakpoints: 4`)
  2. **Adds a 5th cache_control marker** on the last tool definition in `prompt.ts` (in a different code path, doesn't consult the counter)
  3. Sorts tool entries alphabetically when `sortTools: true` (mitigates H2)
- Patch keeps the `slice(0, 2)` / `slice(-2)` selection policy unchanged.

### Distribution (`~/projects/opencode-patched`, branch `main`)

- Two patches: `caching.patch` (fetched at build time from `opencode-cached@main` via `apply.sh`) + `vim.patch` (60 KB, vim keybindings, no overlap with caching path).
- Built by `johnnymo87/opencode-patched` GitHub releases.
- Cloudbox runs `opencode 1.14.19` from `~/.nix-profile/bin/opencode` → `/nix/store/...-opencode-patched-1.14.19/bin/opencode`. Workstation flake at `users/dev/home.base.nix` defines this.

## What we shipped during this investigation

| Commit | Description |
|---|---|
| `92a9c65` | feat(oc-cost): add gemini-3.1-pro-preview pricing — was previously `(no rate)` and excluded; now visible. Caveat in README about Google's token-hour storage billing not being captured. |
| `b8f3714` | feat(oc-cost): add `--by-kind` flag — splits primary vs subagent. Adds `query_by_kind`, `query_by_model_and_kind`, new section in text + JSON output. 5 new tests, total 39. |

Both pushed to origin/main, signed (SSH ED25519), `oc-cost` 0.1.0 deployed via `nix run home-manager -- switch --flake .#cloudbox`.

## What's pending (in priority order)

### 0. Wait for ChatGPT consult to unblock (user-gated)

The chatgpt-relay queue is backed up. **User explicitly asked:** "Don't immediately resend the chatgpt question, I'll let you know when it's unblocked."

The consult question is at:
- **Primary location:** `/tmp/research-opencode-cache-write-cost-question.md` (may not survive reboot)
- **Archive:** `docs/plans/2026-04-21-cache-write-consult-question.md` (survives via git)

When unblocked, run:
```bash
ask-question -f /tmp/research-opencode-cache-write-cost-question.md \
             -o /tmp/research-opencode-cache-write-cost-answer.md \
             -t 1500000
```

(If `/tmp` was wiped, copy back from `docs/plans/2026-04-21-cache-write-consult-question.md`.)

The question asks about:
- **Q1 (the big one):** Best breakpoint placement strategy. Five candidate designs (Anchor-on-Nth, Anchor-on-stable-boundary, Tail-only-when-cold, 1-hour TTL, hybrid).
- **Q2:** Is the patched code's 5th `cache_control` marker silently dropped or 400'd by Anthropic?
- **Q3:** Does `@ai-sdk/anthropic` pass through `cacheControl: { type: "ephemeral", ttl: "1h" }`? (If yes — quick win.)
- **Q4:** What are we missing?

### 1. After consult: implement H1 mitigation in opencode-cached

User's confirmed plan (in priority order chosen during this session):
- **#3 (H3 fix):** Investigated → not worth doing. H3 is empirically nonexistent.
- **#5 (subagent telemetry):** ✅ shipped (`b8f3714`)
- **Consult ChatGPT** with the question above → in progress, awaiting unblock
- **#2 (H1 fix):** Implement chosen breakpoint placement strategy in `~/projects/opencode-cached/patches/caching.patch`. The exact design will be informed by ChatGPT's response. Most likely:
  - **Quick win first** (if Q3 confirms): change `cacheControl: { type: "ephemeral" }` → `cacheControl: { type: "ephemeral", ttl: "1h" }` on the system+tools breakpoints. Estimated savings: most of the $338 TTL-expiry bucket, possibly $200-300/month.
  - **Bigger redesign:** change tail breakpoint policy. Lower confidence about exact design until consult returns.

### 2. Sunset opportunities and red flags to watch for

- The 5th cache_control marker bug (Q2) — the patch may already be wasting one breakpoint silently. If Anthropic 400s on it, we'd see errors in opencode logs (not visible to oc-cost which only sees the DB).
- PR #5422 in upstream `sst/opencode` — the source of `caching.patch`. If/when merged, the patch carrier becomes redundant. Periodically check `gh pr view 5422 --repo sst/opencode`.
- Issue #5224 in upstream — system prompt cache invalidation. Adjacent topic.

## User preferences expressed in this session

- **Working directly on `main`** across multiple machines. Just `git pull --rebase` then push. Don't worry about coordinating with parallel Claude sessions.
- **Push protocol:** AGENTS.md "Landing the Plane" — commit + pull --rebase + push, verify "up to date with origin/main".
- **`stash@{0}` is critical** — datadog-mcp-cli removal + opencode-config tweak WIP. Was lost once during this session and recovered via `git fsck --unreachable`. Do not drop it.
- **No 4 (don't open a discussion upstream yet).** User wants to fix locally first, evaluate, then decide whether to upstream.
- **Yes 1 (Gemini pricing) — done.**
- **Yes 2 (H1 fix) — pending consult.**
- **Yes 3 (H3 fix) — investigated and rejected on data.**
- **Yes 5 (subagent telemetry) — done.**
- **Yes (expand brain trust with ChatGPT consult) — drafted and awaiting unblock.**

## Verification commands (sanity check before next batch)

```bash
# State
cd /home/dev/projects/workstation
git status                       # must show: up to date with origin/main, clean
git log --oneline -5             # last commit should be be175cc or later
git stash list | head -3         # stash@{0} must be the WIP one

# oc-cost works
oc-cost --days 30 --by-kind | tail -10
# expects: Primary vs Subagent table with primary ~$1576 / subagent ~$468

# Tests
python3 -m unittest pkgs/oc-cost/test_oc_cost.py 2>&1 | tail -3
# expects: Ran 39 tests in 0.0Xs / OK

# Workstation home is up to date
nix-info --host-os 2>&1 | head -3   # cloudbox; just sanity
```
