# transform.ts patch triage — v1.17.13 → v1.18.18

Read-only research. Source: `/home/dev/projects/opencode` (origin = anomalyco/opencode).
All apply tests run in throwaway detached worktrees at `v1.18.18`, removed afterwards.
Tags: `v1.17.13` = 10c894bdee, `v1.18.18` = 31406ccc51.

## Verdict table

| Patch | Verdict | Confidence | Reason |
|---|---|---|---|
| `opus5-adaptive-thinking.patch` | **DROP-upstream** | High | Upstream commit `2b2aacc939` ("fix(provider): generalize Claude adaptive thinking (#38757)"), first tag **v1.18.5**, is our patch verbatim (hunks 1+2 reverse-apply cleanly against v1.18.18). Matches the patch's own SUNSET note. |
| `cache-thinking-skip.patch` | **KEEP-clean** | High | `applyCaching()` body byte-identical at v1.18.18; no upstream reasoning-skip. `git apply --check` succeeds (hunk #1 at 389, offset +14). |
| `gemini-empty-parts.patch` | **KEEP-rebase** | High | All three *source* hunks apply (gemini.ts offsets +2, transform.ts offset +36); only the `transform.test.ts` append hunk fails — appended-at-EOF anchor moved (file grew 4118 → 5668 lines). |

## 1. `cache-thinking-skip.patch` (#17883)

### a) Upstream at v1.18.18? NO.
v1.18.18 `packages/opencode/src/provider/transform.ts:391-402`:

```ts
if (shouldUseContentOptions) {
  const lastContent = msg.content[msg.content.length - 1]
  if (
    lastContent &&
    typeof lastContent === "object" &&
    lastContent.type !== "tool-approval-request" &&
    lastContent.type !== "tool-approval-response"
  ) {
```

Identical to v1.17.13 (only shifted 375 → 391). No `reasoning` skip. Searches:
- `git log origin/dev --oneline --grep=17883` → empty.
- No commit in `v1.17.13..v1.18.18` touches `applyCaching` (diff hunk boundaries are `@@ -215` and `@@ -430`; `applyCaching` sits between them, untouched).

### b) Applies? YES, clean.
```
Checking patch packages/opencode/src/provider/transform.ts...
Hunk #1 succeeded at 389 (offset 14 lines).
```

### c) Restructuring around the anchor
`applyCaching` itself unchanged. Two nearby changes that matter *semantically*, not textually:

1. **New gate on the call site** (`message()`, v1.18.18:470-485). Upstream added:
   ```ts
   const usesAnthropicAutomaticCaching =
     options.cacheControl !== undefined &&
     (model.api.npm === "@ai-sdk/anthropic" || model.api.npm === "@ai-sdk/google-vertex/anthropic")
   ...  && !usesAnthropicAutomaticCaching
   ```
   So when a caller passes `cacheControl`, native-Anthropic and Vertex-Anthropic skip
   `applyCaching` entirely and our patch is inert for those. It remains live for every
   other route into `applyCaching` (openrouter, openai-compatible proxies, copilot,
   alibaba, `api.id.includes("claude")` shims) — i.e. the class of provider that
   *does* take the content-level branch (`shouldUseContentOptions` excludes
   providerID `anthropic` and bedrock outright).
2. `+12` lines (`isKimiFamily`) and `+24` lines (new `sdkKey` cases) above → the +14
   net offset. Nothing else.

### d) Verdict
**KEEP-clean** — behavior absent upstream, patch applies with offset only. Confidence: high.
Residual risk (low): the upstream automatic-caching gate narrows the blast radius, so a
regression test that exercised the patch via a native-Anthropic model *with* `cacheControl`
would now bypass it. Verify against a Vertex-Anthropic / openai-compatible model instead.

## 2. `gemini-empty-parts.patch` (PR #28669)

### a) Upstream at v1.18.18? NO.
- `packages/llm/src/protocols/gemini.ts` is **byte-identical** between v1.17.13 and
  v1.18.18 (`git diff --stat` over the two tags returns nothing for that path). None of
  the three `if (parts.length === 0) parts.push({ text: "" })` guards exist upstream
  (`contents.push` sites at 214/225/247/284, all unguarded).
- transform.ts has no `@ai-sdk/google` / `@ai-sdk/google-vertex` block in
  `normalizeMessages`. Only the `@ai-sdk/anthropic` (line 170) and
  `@ai-sdk/amazon-bedrock` (line 198) empty-part filters, both pre-existing.
- `git log v1.17.13..v1.18.18 -S'parts.length === 0'` → empty.
  `git log origin/dev --grep=28669` → empty (that number is fork-side, not an upstream
  commit-message token, so absence is weak evidence on its own — the source read above
  is the strong evidence).
- The existing upstream tests at `transform.test.ts:2270-2340` ("keeps non-text/reasoning
  parts even if text parts are empty", etc.) use `anthropicModel` and the bedrock model
  only; nothing covers Gemini.

### b) Applies? PARTIALLY.
```
packages/llm/src/protocols/gemini.ts       hunks 1-3 succeeded (offset 2)
packages/llm/test/provider/gemini.test.ts  clean
packages/opencode/src/provider/transform.ts hunk 1 succeeded at 222 (offset 36)
packages/opencode/test/provider/transform.test.ts  FAILS
  error: while searching for:
      expect(result).toEqual({ openaiCompatible: { reasoningEffort: "high" } })
    })
  })
  error: patch failed: packages/opencode/test/provider/transform.test.ts:4118
```
Cause: the patch appends a new `describe` at the old EOF (line 4118). Upstream added
+940 lines to that file; EOF is now 5668, and the tail is
`describe(... kimi ...)` ending with "does not set adaptive thinking for kimi on
openai-compatible". The former anchor
(`describe("ProviderTransform.providerOptions - ai-gateway-provider")`) is now at 5523
and is no longer the last block.

**Fix is trivial**: re-cut the test hunk against the new EOF (pure append; the added
`describe` has no dependency on surrounding code, and its model literal is `as any`
so the Provider.Model shape drift does not bite).

### c) Restructuring around the anchors
- `gemini.ts`: none at all.
- `transform.ts` insertion point (after the `@ai-sdk/amazon-bedrock` block, before
  `if (model.api.id.includes("claude"))`): structurally intact. The +36 offset comes
  entirely from additions *above* (`isKimiFamily`, 12 new `sdkKey` cases, and the
  Mistral-family predicate rewrite at old line 215 which now uses a hoisted
  `const modelID` + `["mistral","devstral","codestral","pixtral","mixtral"].some(...)`).
  Applied position 222 lands exactly between the bedrock filter and the claude scrub —
  the intended semantics.
- `transform.test.ts`: append-only growth; no restructure of the region we care about.

### d) Verdict
**KEEP-rebase** — source hunks fine, one test hunk needs its anchor moved to the new EOF.
Confidence: high.

## 3. `opus5-adaptive-thinking.patch` (PR #38757, local port)

### a) Upstream at v1.18.18? YES → DROP.
- Commit: **`2b2aacc939` "fix(provider): generalize Claude adaptive thinking (#38757)"**
- First containing tag: **`v1.18.5`** (`git tag --contains 2b2aacc939 --sort=creatordate | head -1`).
- v1.18.18:657-688 contains `anthropicUsesModernAdaptiveThinking` with the identical
  regex `/claude-(?:[a-z]+-)?(\d+)(?:[.-](\d{1,2}))?(?:[.@-]|$)/i`, the identical
  `if (!version) return true`, `anthropicOpus45`, and
  `anthropicOmitsThinking = anthropicUsesModernAdaptiveThinking`.
- Reverse-apply proof: `git apply --check -R` at v1.18.18 succeeds for hunks #1 and #2
  (the whole predicate rewrite) — i.e. the post-state matches upstream exactly.
- Matches the patch's documented SUNSET: "drop on the upstream bump to >= v1.18.5".
- Behavior sanity: `claude-opus-5` → regex major=5 > 4 → adaptive efforts
  `["low","medium","high","xhigh","max"]`, `anthropicOmitsThinking` true. The original
  400 ("use thinking.type.adaptive + output_config.effort") cannot recur.

### b) Applies? No — and correctly so.
```
error: while searching for:  function anthropicOpus47OrLater(apiId: string) { ...
error: patch failed: packages/opencode/src/provider/transform.ts:597
```
The pre-image no longer exists because upstream already made the change.

### c) Restructuring
Beyond adopting our predicate, upstream evolved the opus-4-5 body further than our port:
`variants()` now calls `anthropicOpus45Effort(model, effort)` (v1.18.18:1802) —
`{ thinking: { type: "enabled", budgetTokens: min(16_000, floor(limit.output/2 - 1)) }, effort }` —
where our patch's hunk #3 preserved the v1.17.13 `{ effort }` body. That is upstream's own
later refinement (a superset), so hunk #3 must **not** be re-applied; doing so would
regress opus-4-5 budget handling. Hunk #4 (comment wording "Claude 4.7+ defaults `display`
to \"omitted\"") is also already upstream at v1.18.18:1126.

### d) Verdict
**DROP-upstream** — `2b2aacc939`, first in v1.18.5, is our change verbatim. Confidence: high.

## e) Inter-patch interaction at v1.18.18

Only two patches survive, and they are **disjoint and order-independent**:

- `gemini-empty-parts` → `normalizeMessages`, transform.ts ~line 222.
- `cache-thinking-skip` → `applyCaching`, transform.ts ~line 389 (→ 424 after the
  gemini insertion's +35 lines).

Verified both orders in separate throwaway worktrees:
- gemini (src only) then cache-thinking-skip: `Hunk #1 succeeded at 424 (offset 49 lines)` → both apply.
- cache-thinking-skip then gemini: `Hunk #1 succeeded at 222 (offset 36 lines)` → both apply.

`apply.sh`'s current comment ("gemini-empty-parts must apply first") is *not* required at
v1.18.18 — but keeping the existing order costs nothing and is the tested path. Removing
`opus5-adaptive-thinking` from the `PATCHES` array does not disturb either (it was #24,
after both, and touches a different region).

## Could NOT determine

- **Runtime/type verification.** I only ran `git apply --check` / `git apply`; I did not
  run `bun test` or a typecheck on the patched tree (read-only scope, no build). Two things
  that only a build would catch: whether the gemini `normalizeMessages` block still
  typechecks against any v1.18.18 change to `ModelMessage` part typings (`part.text` narrowing
  on `text | reasoning`), and whether the appended Gemini tests pass under the new
  `ProviderTransform.message` gate logic.
- **Whether #17883 / #28669 were ever filed or fixed upstream under different wording.**
  `--grep` on those numbers returns nothing on `origin/dev`; I established absence from the
  v1.18.18 *source*, which is the load-bearing check, but I cannot rule out an equivalent fix
  landing after v1.18.18 on `dev`.
- **Whether the new `usesAnthropicAutomaticCaching` gate means any caller in our fork now
  passes `options.cacheControl`** — that depends on call sites outside transform.ts
  (session/prompt code) which were out of scope. If some fork code sets it, cache-thinking-skip
  becomes dead for native-Anthropic while staying live elsewhere.
