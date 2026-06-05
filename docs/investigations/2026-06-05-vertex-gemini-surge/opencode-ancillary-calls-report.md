# OpenCode ancillary (non-conversation) LLM calls — investigation report

**Scope:** `packages/opencode/src` in this repo. Verified against tag **`v1.15.13`**
(the version you run) as well as the current working tree; the relevant code is
identical between them (checked `git show v1.15.13:…` for the key files).
**No source files were modified.**

---

## 0. TL;DR

- Every model request in opencode funnels through exactly two primitives:
  `llm.stream(...)` (`session/llm.ts:272` → AI SDK `streamText`) and
  `generateObject`/`streamObject` (`agent/agent.ts:451`/`:436`, agent-config gen only).
- On a **trivial single-turn build session**, the code emits exactly **one**
  ancillary call: **session-title generation**. Everything else (compaction,
  agent-gen, GitHub action) does not fire in that scenario.
- **The 1× claude-haiku-4-5 is the title call.** Title generation runs against the
  *session's* provider (`google-vertex-anthropic`) and the hidden hardcoded
  small-model priority list picks `claude-haiku-4-5` **regardless of your gemini
  default** (`provider/provider.ts:1785-1793`). Haiku is *not* in your config — it
  is hardcoded.
- **gemini-3.5-flash is your configured default** (`cfg.model`) and your
  `agent.compaction.model`. It reaches an **unrecorded** ancillary call through the
  **title-generation fallback**: when `getSmallModel(google-vertex)` finds no
  match in your catalog it falls back to the session's *own* model
  (`prompt.ts:268-269`) — i.e. `gemini-3.5-flash`. So the 2× gemini are title
  calls for gemini-default sessions (see §4 for the exact reconciliation and the
  one caveat).
- **Why invisible to oc-cost:** title results are written only to the `title`
  **session column** via `setTitle → patch` (`session.ts:727-728`); the title
  stream throws away every event except `textDelta` (`prompt.ts:285-289`), so the
  usage/finish event carrying cost is discarded and **no `message`/`part` row is
  ever created.** Your cost tool reads `message`/`part`, so it cannot see them.

---

## 1. The two model-resolution helpers

### 1a. `getSmallModel(providerID)` — used ONLY by title generation
`provider/provider.ts:1771-1827`

```
1774  if (cfg.small_model) { return getModel(parse(cfg.small_model)) }   // user override
1785  let priority = [
1786    "claude-haiku-4-5",
1787    "claude-haiku-4.5",
1788    "3-5-haiku",
1789    "3.5-haiku",
1790    "gemini-3-flash",
1791    "gemini-2.5-flash",
1792    "gpt-5-nano",
1793  ]
1794  if (providerID.startsWith("opencode"))       priority = ["gpt-5-nano"]
1797  if (providerID.startsWith("github-copilot")) priority = ["gpt-5-mini", "claude-haiku-4.5", ...priority]
1800  for (const item of priority) for (model of provider.models) if (model.includes(item)) return model
1826  return undefined   // nothing matched
```

Key facts:
- It searches the catalog of the **provider passed in** (the *session's* provider),
  not your default provider.
- The priority list is **hardcoded** and **claude-haiku-4-5 is first**. For a
  `google-vertex-anthropic` session this matches `claude-haiku-4-5@…` → **haiku**.
- `cfg.small_model` is clearly **unset** in your config: if it were set to gemini,
  the opus session's title would have used gemini, not haiku. It used haiku ⇒
  unset ⇒ priority path taken. **This is where haiku comes from.**
- `getSmallModel` is called from exactly **one** place: title generation
  (`prompt.ts:268`). (grep: no other caller in the tree.)

### 1b. `defaultModel()` — returns your `cfg.model`
`provider/provider.ts:1829-1861`

```
1831  if (cfg.model) return parseModel(cfg.model)     // => google-vertex/gemini-3.5-flash
1834  …else most-recently-used from ~/.local/share/opencode/state/model.json…
1853  …else first model of first provider…
```

So any feature that calls `provider.defaultModel()` resolves to
**gemini-3.5-flash** for you. (Callers: agent-config gen, plan tool, debug, ACP/
server session setup — none of which fire during a plain chat turn; see §3.)

---

## 2. Every ancillary (non-foreground) call site

| # | Purpose | Provider-call file:line | Model resolution | Persisted? (why visible/invisible) | Frequency |
|---|---------|-------------------------|------------------|------------------------------------|-----------|
| 1 | **Session title** | `session/prompt.ts:273-284` (`llm.stream`, `small:true`, `retries:2`); triggered at `prompt.ts:1294-1300` | `agents.get("title").model` (unset) → **`getSmallModel(sessionProviderID)`** → else session's own model `getModel(input.providerID, input.modelID)` (`prompt.ts:266-269`) | **NO message/part.** Written to `title` **session column** via `setTitle`→`patch` (`prompt.ts:298-300`, `session.ts:727-728`). Stream keeps only `textDelta` and drops usage (`prompt.ts:285-289`) → **cost never recorded.** | **Once per (non-child) session**, at `step===1`, only if title is still default and exactly one real user message exists (`prompt.ts:247-254`). Forked (`Effect.forkIn`). |
| 2 | **Compaction / summarize** | `session/compaction.ts:438-457` (`processors.create` → `processor.process` → `llm.stream` at `processor.ts:790`) | `agents.get("compaction").model` (**you set this = gemini-3.5-flash**) → else user-message model (`compaction.ts:383-386`) | **YES — recorded.** Creates an assistant message `summary:true, mode:"compaction"` (`compaction.ts:411-437`) + a `compaction` part; processor tracks tokens/cost. **Should be visible to oc-cost.** | Auto on context overflow (`prompt.ts:1322-1328`), post-turn `"compact"` result (`prompt.ts:1477+`), or manual `/compact`,`/summarize` (`server/.../handlers/session.ts:273-282`). **Does not fire on a trivial session.** |
| 3 | **Agent-config generation** | `agent/agent.ts:451` (`generateObject`) / `:436` (`streamObject`, OpenAI-OAuth only) | `input.model` (CLI `--model`) → else **`defaultModel()`** = gemini-3.5-flash (`agent.ts:389`) | **NO** — writes an agent config *file*, never a session message. | Only `opencode agent create` (`cli/cmd/agent.ts:132`). Not in normal chat. |
| 4 | **GitHub action: <40-char title** | `cli/cmd/github.ts:932→947` (`prompt.prompt`) | GitHub-action config model (`github.ts:951-954`) | YES — runs a full `prompt.prompt` turn → creates session messages. | Per `/oc` GitHub comment response (`github.ts:593,627,645,667`). CI only. |
| 5 | **GitHub action: no-text summary** | `cli/cmd/github.ts:995` (`prompt.prompt`, tools off) | GitHub-action config model | YES — full turn → session messages. | Only when the reply had no text. CI only. |

### Things that look ancillary but are NOT LLM calls (ruled out)
- **`SessionSummary.summarize`** (`session/summary.ts:101-128`): computes **git-diff
  stats only** (`computeDiff` → `snapshot.diffFull`). This is what populates the
  `summary_additions/deletions/files/diffs` **session columns** — **no model call,
  no cost.** Invoked at `prompt.ts:1413` (step===1, forked) and after each step.
  This is why you see populated `summary_*` columns with no attributed cost.
- **Built-in `summary` agent** (`PROMPT_SUMMARY`, `agent/agent.ts:266-280`): **defined
  but never invoked anywhere** in the tree (no `agents.get("summary")`). Dead/reserved.
- **No `countTokens` / embeddings request anywhere.** Token counts come from the
  streaming response metadata; overflow checks (`compaction.isOverflow`) are local math.
- **websearch/webfetch tools** hit external Exa/Parallel/HTTP endpoints, not your Vertex provider.
- `defaultModel()`/`getModel()` in `plan.ts`, `debug/agent.ts`, `share-next.ts`, ACP/server
  session setup resolve a model for bookkeeping or for the **foreground** turn — not ancillary.

---

## 3. The full call graph (so you can trust the enumeration)

- `llm.stream` callers (grep-verified): `processor.ts:790` (engine for foreground
  turns, subtasks, AND compaction) and `prompt.ts:273` (title). That's it.
- `processor.process`/`create` callers: `prompt.ts` foreground turn + subtasks
  (excluded), and `compaction.ts:443`.
- `generateObject`/`streamObject`: `agent/agent.ts` only.
- One `streamText` per turn — **no fallback model chain** in v1.15.13 (PR #27939
  "configurable fallback model chain" is still **open/unmerged**), so a turn never
  silently retries on a *different* model.

⇒ For a single-turn "reply READY, no tools" build session the only ancillary
provider request the code can emit is **title generation (one call)**.

---

## 4. Reconciling the controlled experiment (1× opus, 2× gemini-3.5-flash, 1× haiku)

Mapping each deduplicated Vertex call to code:

| Audit call | Source | Recorded? |
|------------|--------|-----------|
| 1× claude-opus-4-8 | The foreground conversation turn (`processor.ts:790`) | Yes — assistant message/part |
| 1× claude-haiku-4-5 | **Title generation** for the opus session: `getSmallModel("google-vertex-anthropic")` → hardcoded priority → `claude-haiku-4-5` (`provider.ts:1786`, `prompt.ts:268`) | **No** — `title` column only |
| 2× gemini-3.5-flash | **Title generation for gemini-default sessions** (see below) | **No** — `title` column only |

**Where the haiku comes from (definitive):** title generation, because the
hardcoded small-model priority puts `claude-haiku-4-5` first and the opus session's
provider (`google-vertex-anthropic`) has haiku in its catalog. Your gemini default
is irrelevant to this path — title resolves against the *session* provider, not the
global default.

**Where gemini-3.5-flash comes from:** it is your `cfg.model` default (and your
`agent.compaction.model`). It enters an **unrecorded** ancillary call via the title
path's final fallback:

```
prompt.ts:266-269
  mdl = ag.model
      ? getModel(ag.model)                                  // unset for you
      : (getSmallModel(input.providerID)                    // (a)
         ?? getModel(input.providerID, input.modelID))      // (b) <-- session's OWN model
```

For a session whose provider is `google-vertex` (your gemini default),
`getSmallModel("google-vertex")` walks `["claude-haiku-4-5", …, "gemini-3-flash",
"gemini-2.5-flash", "gpt-5-nano"]`. If your `google-vertex` catalog does **not**
contain `gemini-3-flash`/`gemini-2.5-flash` (likely — you run `gemini-3.5-flash`),
(a) returns `undefined` and the title falls back to **(b) = the session's own model
= `gemini-3.5-flash`**. That title call is unrecorded (column only) exactly like the
haiku one.

So **all three unrecorded calls are title-generation calls**, differing only because
`getSmallModel` resolves to a different model per session provider:
- opus/claude session → `claude-haiku-4-5` (priority hit) → the 1× haiku
- gemini-default session → priority miss → fallback to `gemini-3.5-flash` → the gemini calls

**Important caveat / the one thing to verify.** The code emits **exactly one** title
call per session (guarded at `prompt.ts:247-254`, fires once at `step===1`). The
opus test session therefore accounts for the **1× haiku only**. Two `gemini-3.5-flash`
calls require **two additional gemini-default sessions** (or compaction) to have been
active in the captured window — the single trivial session alone cannot produce them.
Most likely the window also captured title generation for ≥2 other new/untitled
gemini-default sessions (each emits one unrecorded `gemini-3.5-flash` title call), or
a `/compact`/auto-compaction that resolved to `gemini-3.5-flash`. Note compaction is
**recorded** (a `summary:true` assistant message, §2 row 2), so if your oc-cost shows
no gemini cost at all, the title path (unrecorded) is the better fit for the 2× gemini.

**To disambiguate against your data:**
1. `grep` the opencode server logs for the structured `LLM.run` log line
   (`session/llm.ts:90-93`, tags `small`, `agent`, `providerID`, `modelID`,
   `session.id`) — every ancillary call logs `agent=title`/`small=true` with its
   session id and model. This tells you exactly which sessions emitted the gemini titles.
2. In SQLite, list sessions whose `title` column is non-default but which have no
   `compaction`/`summary` message — those are title-only (unrecorded) gemini/haiku spends.
3. Confirm your `google-vertex` provider catalog lacks `gemini-3-flash`/`gemini-2.5-flash`
   (so the title fallback yields `gemini-3.5-flash`, not one of those).

---

## 5. Why these are invisible to message/part accounting

1. **Title** never creates a `message` or `part`. It calls `setTitle` →
   `patch(sessionID, { title })` → updates the **session row column** only
   (`session.ts:727-728`, `projectors.ts:` maps `title` to `SessionTable`). The
   stream is consumed as `Stream.filter(textDelta) → mkString` (`prompt.ts:285-289`),
   so the usage/cost-bearing `finish` event is **discarded**. No row ⇒ oc-cost
   (which sums `part`/`message` token+cost) cannot see it.
2. **`summary_*` columns** are git-diff stats (`summary.ts`), not an LLM result —
   they exist with **zero attributable LLM cost** by design.
3. **Compaction** *is* recorded (assistant message, `summary:true`) — so it is the
   one ancillary call that *should* be attributable; if it's missing from your tool,
   check whether oc-cost filters `summary` messages or treats `cost:0` rows.

**Volume implication:** title fires **once per new session**. A workflow that opens
many short sessions generates one untracked small/default-model call each — invisible
to message-based cost tooling, visible only in the Vertex audit log. That is the
structural reason your audit-log totals exceed your DB-derived totals.

---

## 6. Relevant `anomalyco/opencode` issues & PRs

### Title / small-model selection (directly relevant)
- **#25344** (open) — *Auto-title generation silently fails when provider has no small model.* The `getSmallModel` miss path.
- **#30662** (open) — *Auto session title generation fails for opencode provider models (smallOptions missing provider config).*
- **#26181** (open) — *Title generation fails from unavailable gpt-5-nano fallback and possible variant leakage into OpenAI small_model.*
- **#20269** (open) — *Session title generation fails silently since v1.3.3 — effort parameter leaks into small model call.*
- **#29734** (open) — *Session title generation silently fails with no fallback or logging.*
- **#23114** (open) — *Session title agent generates title from injected memory/system context rather than actual user message.*
- **#25456** (open) — *Configurable thinking mode for session title generation (default non-thinking).*
- **#23085** (open) — *small_model request reuses x-session-affinity from main chat.*
- **#16207** (open) — *Specify small_model per provider.*
- **#23016** (open) — *support disable small_model for serve mode.*
- **#8609** (open) — *Misleading documentation / incorrect behaviour about small_model.*
- **#29639** (open) — *Clarify `model`/`small_model` syntax is `{provider}/{model}`.*

### PRs touching this exact code
- **#27405** (**merged**) — *fix(provider): make small model fallback optional.*
- **#27390** (**merged**) — *cleanup: make smallOptions rely on variants.*
- **#20582 / #20323** (closed) — *prevent model options / variant effort leaking into the small-model (title) call.*
- **#29735** (closed) — *add fallback models for session title generation.*
- **#20499** (closed) — *truncate first user message as session title when no title model configured.*
- **#27939** (**open, not merged**) — *feat(session): add configurable fallback model chain* (confirms no multi-model fallback ships in v1.15.13).
- **#22824** (merged) — *low reasoning effort for GitHub Copilot gpt-5* (small-model effort handling).

### Cost / accuracy (context for the observability gap)
- **#17223** (open) — *Cost tracking ($ Spent) does not work for custom provider models.*
- **#27091** (open) — *Billing issue when switching models mid-session.*
- **#30706** (open) — *v2 SessionRunner publishes Step.Ended.cost:0; Copilot refresh drops Anthropic cache-write pricing.*
- **#26213** (open) — *API Proxy Returns cost:"0" and Dashboard Not Tracking Usage.*
- **#15903 / #29909 / #27904** — cost/token-count display features.

> No existing issue specifically reports "title/auxiliary model calls are omitted
> from local cost accounting because they're stored as a session column, not a
> message." That appears to be a reportable gap (the title-failure issues above are
> the closest neighbors).
