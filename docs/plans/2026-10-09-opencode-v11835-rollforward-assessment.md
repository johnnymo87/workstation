# opencode v1.18.18 -> v1.18.35 roll-forward: assessment

Status: ASSESSMENT COMPLETE (2026-10-09). **Recommendation: do not upgrade now.**
Bead: workstation-z1fw
Prior roll-forward (the template for this one): `docs/plans/2026-08-14-opencode-118-rollforward-research.md`, bead workstation-l60f

## Question asked

What changed between what we run and latest upstream, is upgrading worth it, and
how much work is it to reapply / drop our patches.

## Ground truth (pinned)

| Thing | Value |
|---|---|
| We run | `opencode-patched-1.18.18.5` (`/nix/store/qcanqk51b5v8zss7mhhan2l1r02kmbfx-...`) |
| Upstream base | `v1.18.18` = `31406ccc51b4bd2a4e1e086b2bcaa5f7f804f26d` (2026-08-13) |
| Latest upstream | `v1.18.35` = `53d1eabb61e21162157817bf677da0a4ad3332e3` (2026-10-06) |
| Range | 458 commits, 637 files, +42531 / -12290 |
| Patch series | 30 live patches (33 numbered, 3 tombstoned) in `opencode-patched@origin/main` (`ef55b9d`) |
| bun pin | 1.4.0 (held; see "bun" below) |

**Tags have NOT moved.** Local and upstream SHAs match for both tags. The
"tag MOVED" lines in the failed CI runs were the *script text* being echoed in
the step group header; the actual outcome was
`::warning::No expected_sha pinned` — the dispatcher passed `expected_sha=""`.
Bead assumption (1) was wrong on this point. The real CI failure was `vim.patch`.

## Answer 1: the re-port cost is ~15 minutes, not a project

The triage that produced "5 patches FAIL, 4 need 3-way" was **methodologically
wrong**: it checked each patch standalone against a pristine tree. `apply.sh`
applies an *ordered series*, and many patches target files that earlier patches
create or pre-modify (`tui/src/util/sse.ts` and `cli/cmd/attach.ts` do not
exist upstream at all — `attach-route-resolve.patch` creates them).

Re-run in `apply.sh` order with plain `git apply` (what CI does), verified three
times independently (two subagents + directly):

**27 of 30 apply byte-clean. 3 fail.**

| Patch | Verdict | Cause | Effort |
|---|---|---|---|
| `sse-cancel-rejection` | **DROP (mandatory)** | Upstream `69c172e8a7` (#44944) is byte-identical to ours; `reader.cancel(err).catch(() => {})` present at `core/src/aisdk.ts:38` and `provider/provider.ts:49`. Its own sunset clause fires. | delete + tombstone |
| `vim` | TRIVIAL | `29f07e0c69` (#51414) changed `tui/src/app.tsx:66` from `import open from "open"` to `import { openUrl } from "@opencode-ai/core/open"`. That line is pure *context* in our import hunk. Hunks #2/#3 and all 11 `prompt/index.tsx` hunks apply clean. | 1 context line, ~5 min |
| `registry-port-fence` | TRIVIAL | `55c54d14b8` (#46644) dropped `--conditions=browser` from four `Bun.spawn` lines in the **test helper** `test/lib/cli-process.ts`. All production hunks apply clean. | 4 line edits, ~5 min |

Do **not** lean on `git apply -3` for `vim`: it only works out of series order,
and fails with `does not match index` once `attach-route-resolve` dirties
`app.tsx`. Regenerate the hunk.

A fixed `registry-port-fence` was left at
`/tmp/opencode/fix/registry-port-fence.fixed.patch` (ephemeral; regenerate if gone).

Verification depth reached: full stack applied on v1.18.35 + `bun install
--frozen-lockfile`, then `packages/tui` `tsgo --noEmit` clean and `bun test`
**334 pass / 1 skip / 0 fail** across 53 files, including every patch-carried
test (`vim-motions`, `scroll-target`, `reconcile-bound`, `util/sse`,
`door-scope`). No binary was built and no runtime behavior was field-verified.

## Answer 2: upstream subsumed exactly ONE patch

`sse-cancel-rejection` (2 lines). That is the entire maintenance saving.

The structural reason the upgrade is cheap is also the reason it is empty:
**20 of the 23 source files our patches touch are byte-identical between the two
tags** — `core/src/event.ts`, `core/src/catalog.ts`, `core/src/project/copy.ts`,
`core/src/database/database.ts`, `core/src/flag/flag.ts`,
`opencode/src/bus/global.ts`, `opencode/src/cli/cmd/serve.ts`,
`opencode/src/cli/cmd/attach.ts`, `httpapi/handlers/event.ts`,
`httpapi/groups/session.ts`, `httpapi/handlers/session.ts`,
`tui/src/context/{sdk,sync}.tsx`, `tui/src/util/sse.ts`,
`llm/src/protocols/gemini.ts`, `schema/src/v1/session.ts`, and more.

Spot-confirmed NOT subsumed, by content at v1.18.35:
- `event-log-gate` — unconditional `insert(EventTable)` still at `core/src/event.ts:337`, no gate.
- `available-cache` — `grep -c cachedInvalidateWithTTL core/src/catalog.ts` = **0**; `/api/model` still recomputes per call.
- `compaction-bounded-load` — `message-v2.ts:587` still `filterCompacted(yield* stream(sessionID))`, full-history materialization per loop iteration.

Every other patch was checked and found not subsumed. All the failure modes that
have actually bitten us (ProjectCopy reconnect-storm wedge, jsdiff CPU pin,
compaction full-history load, catalog herd, phantom-busy orphan, attach SSE
connection leak) remain ours alone.

## Answer 3: is it worth it? No, not yet

`packages/core/src` gained **118 net inserted lines across 15 files**.
`packages/llm/src` and `packages/schema/src` are byte-identical. 319 of the 458
commits are `packages/console` (167), `packages/web` (152) and `packages/stats`
(67) — the don't-care set. `git log --grep` for leak|memory|hang|crash|oom|
freeze|stall|perf over the range returns **only console/stats hits**: zero
crash/hang/leak/perf fixes in the serve/session/TUI path.

What is genuinely there:

1. **Anthropic thinking `blockBinding`** (`3f39a329c3`, `9a71624d2d`,
   `68abdce1a0`) — the one substantive gain. Claude 5.1+ binds each thinking
   signature to the system prompt + tool list + messages above it and rejects
   the request when that prefix changes, which is what compaction and per-step
   system-prompt re-render do. Reaches our default
   `google-vertex-anthropic/claude-opus-5-5@default`. **Preventive, not
   curative:** 411 MB of serve logs show zero prefix-mismatch rejections today.
2. **`b04697366f`** — 5-minute default `headerTimeout`. Our `anthropic`,
   `google-vertex` and `google-vertex-anthropic` providers set `chunkTimeout`
   but leave `headerTimeout` unset, so this converts an unbounded header stall
   into a bounded retryable error (`HeaderTimeoutError` is `isRetryable: true`,
   `message-v2.ts:669`). **We can have this today by setting `headerTimeout` in
   `opencode.json` — no upgrade required.**
3. `9b0dd36cda` ignore malformed model costs (stops `NaN` cost reaching
   assistant rows; we define several custom models), `b471c2b449` MCP browser
   launcher rejection, `765ae641d7` tool-call `time.start` reset (cosmetic).

What *looked* relevant and is **inert against our actual config** (each checked,
not assumed): `4eb29a64f0` chunk-timeout default (all four providers set it
explicitly; explicit wins at `provider.ts:98`), the four retry-breadth commits
(`40282c1d4d`, `e0b9e68a68`, `71d08e94d5`, `57fa34f235` — zero trigger strings
in our logs), `361a71ffad` Vertex REP routing (we pin explicit local-proxy
`baseURL`s), `3a4c253969` textVerbosity scoping, the four Codex/ChatGPT-limit
commits (filter early-returns unless `auth.type === "oauth"`; ours is an API
key to codex-lb), `b72b50006b` legacy migration recovery (our
`__drizzle_migrations` already has `name`; all 38 migrations recorded).

Also worth knowing: **nothing in this range touches `@opentui/*`** (pinned
`0.4.5` at both tags). The upgrade contains nothing for the TUI leak work.

## Risks if we do upgrade

1. **The `@ai-sdk` dependency jump is the largest unreviewed surface**, and it
   sits directly on the streaming path of both providers we use:
   `@ai-sdk/google-vertex` 4.0.128 -> **4.0.181** (53 releases),
   `@ai-sdk/provider-utils` 4.0.23 -> 4.0.51, `@ai-sdk/anthropic` 3.0.82 ->
   3.0.111, plus three new patched deps (`anthropic`, `amazon-bedrock`,
   `openai`) and one removed (`@ff-labs/fff-bun`). Nothing in the opencode log
   tells us what moved inside it. 118 lines of `core/src` is not worth this.
2. **`03afae5b95` (#45421) routes every config load through
   `ConfigV2Compat.lower()`**, which *throws* on a v2 `permissions` key and
   *silently drops* non-builtin `lsp` entries lacking `extensions`. Verified
   by reading `lower()` that our 647-line config clears it (keys are singular
   v1 `agent`/`plugin`/`provider`/`permission`; all 14 `mcp` entries use
   `enabled`; `lsp` is `{kotlin-ls: {disabled: true}}`, kept by the
   `disabled === true` branch), and no v2-shaped keys exist in any
   `opencode.json*` under `/home/dev/projects`. Not executed. **Gate any
   cutover on booting one serve against the real config.**
3. DB: **zero schema risk.** `packages/core/src/database/migration/` is
   identical at both tags. `d8bf79225f` (#42444) is net positive for us — it
   gates `Workspace.list`/`startWorkspaceSyncing` behind
   `experimentalWorkspaces`, which we keep off.
4. SDK surface moves 1 line in `sdk.gen.ts` and 11 in `types.gen.ts`
   (`ProviderConfig` timeouts, `GlobalUpgradeData.target` now required) — all
   disjoint from our hand-carried hunks. **Do not regenerate the SDK
   wholesale**: it would silently delete the `mcpStatus`/`mcpConnect`/
   `mcpDisconnect` client methods and the only symptom is the TUI MCP dialog
   failing at runtime (`apply.sh:590-593`).
5. Build path unchanged: `packages/opencode/script/build.ts` still exists and
   the workflow already `cd`s there. Its only change is darwin codesigning.

## bun: the pin stays at 1.4.0 either way

Checked 2026-10-09:
- `anomalyco/opencode#44946` "bump embedded Bun to 1.4.2" — **OPEN**
- `anomalyco/opencode#48397` "fix(core): break filesystem cycle in compiled prompts" — **OPEN**
- `#50439` "break filesystem search import cycle" — MERGED 2026-09-21, but it is
  a *different* cycle and does not address the compiled-prompt crash
- upstream `packageManager` at v1.18.35 is still `bun@1.3.14`
- `oven-sh/bun#42837` is CLOSED but is scoped to an Android/Bionic regression,
  not our case

**So v1.18.35 does NOT unlock bun 1.4.2.** Bead assumption (3) resolved: no.
One upside — once upstream carries #44944, dropping our backport is safe at any
bun version, which retires the pin-coupling warning in the patch-32 header.

## Recommendation

**Leave the fork on v1.18.18.** Take the one real win without upgrading: set
`headerTimeout` on `anthropic`, `google-vertex` and `google-vertex-anthropic` in
`opencode.json` (no rebuild).

Flip to "do it now" on any of these triggers:
- Anthropic thinking-signature / prefix-mismatch rejections start appearing on
  opus-5-5 (grep serve logs for `inputTransformations` or signature rejections)
- we need a bun >= 1.4 pin for an unrelated reason
- an upstream fix we actually want lands past v1.18.35, forcing us through this
  range anyway

When that happens, the recipe is: drop `sse-cancel-rejection`, fix one context
line in `vim`, fix four lines in `registry-port-fence`, pin `expected_sha`
properly this time, and gate on a real agent turn per platform (never a
`--version` smoke) plus a boot against the real config.
