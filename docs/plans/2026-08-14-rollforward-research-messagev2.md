# Research: message-v2 / retry / session / projector patches, v1.17.13 → v1.18.18

Date: 2026-08-14. Read-only research (no shared repo mutated).
Source: `/home/dev/projects/opencode` (origin = anomalyco/opencode).
v1.17.13 = `10c894bdee`, v1.18.18 = `31406ccc51`.
Throwaway worktree used: `/tmp/msgv2-scope-80503922` (v1.18.18 detached), `bun install --frozen-lockfile` ran there.

## PROCESS INCIDENT (read this)

My first worktree helper wrote its path to `/tmp/wtpath`. **A peer session on the same
roll-forward was already using that exact file name** (and the same `/tmp/oc1818.*`
mktemp prefix). `cat /tmp/wtpath` therefore returned the peer's worktree
`/tmp/wt-tr.xfMV`, and I applied 5 patches into *their* tree. By the time I tried to
reverse them (`git apply -R`, correct patches, reverse order) the peer had already
removed that worktree, so the damage was transient and is gone. No shared repo was
touched. **Lesson for any parallel researcher on this roll-forward: `/tmp/wtpath` and
`/tmp/oc1818.*` are contended names. Use a `$RANDOM`-suffixed path.**

Live worktrees observed at various points: `/tmp/oc1818.K39x`, `/tmp/oc1818.l6BZ`,
`/tmp/oc1818b.Fhar`, `/tmp/wt-tr{,2,3}.*` — at least 2 other sessions are working the
same cutover.

---

## Churn baseline

```
packages/opencode/src/session/message-v2.ts | 21 +++++----   <- db581e47a3 ONLY
packages/opencode/src/session/prompt.ts     |  3 +-
packages/opencode/src/session/retry.ts      | 67 ++++++++++++-------
packages/opencode/src/session/session.ts    |  4 +-
packages/core/src/session/projector.ts      |  0            (absent from diff)
packages/schema/src/v1/session.ts           |  0            (absent from diff)
```

`projector.ts` zero-churn is **real, not a move**: blob id is byte-identical at both
tags (`afa60dfa88d076c691780f20140d74194c8158ae`), the path exists at v1.18.18, and
`git log --follow v1.17.13..v1.18.18 -- packages/core/src/session/projector.ts` is
empty. Same for `packages/schema/src/v1/session.ts`.

`message-v2.ts`'s entire 21-line delta **is** db581e47a3. Nothing else touched that
file in the whole range.

## Relevant upstream commits

| sha | subject | first tag |
|---|---|---|
| `f929f8f100` | refactor(opencode): simplify retry error matching (#40694) | v1.18.14 |
| `61aefc0759` | fix(opencode): expand retryable error patterns (#40707) | v1.18.14 |
| `a54a693af2` | fix(opencode): use chronological message boundaries (#40991) | v1.18.15 |
| `db581e47a3` | fix(opencode): order legacy message loop by time (#40990) | v1.18.15 |
| `c78986831c` | fix(opencode): cap session retries with jitter (#41939) | v1.18.17 |

`a54a693af2` is db581e47a3's sibling: it rewrote `session.ts` fork's
`if (input.messageID && msg.info.id >= input.messageID) break` into a
`findIndex`+`slice`. Same "IDs are not monotonic for imported messages" theme.
It is in `session.ts` but nowhere near `createNext`.

---

## 1. tool-fix.patch — **KEEP-clean** (high confidence)

**(a) Not upstream.** v1.18.18 `toModelMessagesEffect` (lines ~274-380) has no
synthetic step-start injection; no `sawAbortedTool`-equivalent state; the only
`step-start` push is the pass-through at line 286. `git log --grep=16751` and
`-S'sawAbortedTool'` / `-S'synthetic step-start'` across `--all` hit only our own
fork commits (`9201deee9e`, `5de656855b`, `2034fabc7d`).

**Regression test run against plain upstream, per `patch-refresh.md`:** applied only
the patch's test hunk to v1.18.18 and ran it. **RED**:

```
error: Invalid interleaving: found "text" part after "tool-call" in the same assistant
message. ... Content types in this message: [text, tool-call, text, tool-call]
(fail) does not produce interleaved tool-call and text/reasoning in a single assistant
       block when step boundaries are missing
39 pass / 1 fail
```

With the source hunks restored: **40 pass / 0 fail**. Non-vacuous, still needed.

**(b) Applies.** `git apply` clean, all 3 source hunks + 1 test hunk, offset -497
(the patch was authored against a much larger v1.15/1.16-era file; git apply's context
search absorbs it, as it already does on v1.17.13).

```
Hunk #1 succeeded at 274 (offset -497 lines).
Hunk #2 succeeded at 298 (offset -497 lines).
Hunk #3 succeeded at 375 (offset -497 lines).
```

**(c) db581e47a3 collision: NONE.** db581e47a3 edits `latest()` and adds `isAfter()`
at file lines 578-608. tool-fix edits `toModelMessagesEffect` at 274-380. Different
functions, ~200 lines apart, no shared identifiers. Textual and semantic no-op
against each other.

**(d) Verdict: KEEP-clean.** High confidence.

## 2. compaction-bounded-load.patch — **KEEP-clean** (high confidence)

**(a) Not upstream, and the SUNSET condition is not met.**
v1.18.18 still has verbatim:

```ts
export const filterCompactedEffect = Effect.fnUntraced(function* (sessionID: SessionID) {
  return filterCompacted(yield* stream(sessionID))
})
```

`stream()` still materializes the whole session (pages 50 at a time to completion, no
early stop). `prompt.ts:1092` still calls `MessageV2.filterCompactedEffect(sessionID)`
unconditionally **inside the `while (true)` loop body**, with no memo/cache. So:
loop load is NOT bounded upstream, and prompt-loop-cache (#25367) is NOT revived.

**(b) Applies clean** on top of tool-fix:

```
Hunk #1 succeeded at 539 (offset -11 lines).
Hunk #2 succeeded at 619 (offset -11 lines).
test hunk succeeded at 1055 (offset 1 line).
```

The second hunk's trailing context is the single line
`// filterCompacted reorders messages for model consumption` — which is the **one line
of that comment block db581e47a3 did NOT rewrite**. Lucky, but real.

Tests green after apply: `messages-pagination.test.ts` **53 pass / 0 fail** (includes
the patch's own eager-vs-lazy equality assertion and the page-count bound),
`prompt.test.ts` **57 pass / 1 skip / 0 fail** (includes db581e47a3's new
"loop exits for a completed parent turn with nonmonotonic message IDs" test),
`message-v2.test.ts` **40 pass / 0 fail** (includes db581e47a3's three new
`latest()` tests). `bun --cwd packages/opencode typecheck` clean.

**(c) db581e47a3 interaction — the correctness question, worked through.**

Short answer: **no collision, and db581e47a3 makes `compactedWalk`'s assumption
*more* sound, not less.** Reasoning:

1. `compactedWalk()`'s "newest-first" does **not** come from `latest()`. It comes from
   the SQL in `MessageV2.page()`, which db581e47a3 did not touch:

   ```ts
   .orderBy(desc(MessageTable.time_created), desc(MessageTable.id))
   ```
   with keyset cursor
   ```ts
   const older = (row: Cursor) =>
     or(lt(time_created, row.time), and(eq(time_created, row.time), lt(id, row.id)))
   ```

   So the traversal order is lexicographic descending on **`(time_created, id)`**.

2. The patch's `filterCompactedEffect` paging loop is a **character-for-character copy
   of upstream `stream()`'s loop body** (same `page()` call, same `NotFoundError`
   catch, same `for (let i = items.length - 1; i >= 0; i--)` reverse-index walk, same
   `more`/`cursor` break), with the single addition of `if (walk.feed(item)) break paging`.
   Therefore the *sequence of messages the walk observes* is bit-identical to the
   prefix of what `stream()` would have produced. `feed()` is a pure prefix fold with
   early termination, and `finalizeCompacted()` sees only the collected prefix. Output
   is provably identical to `filterCompacted(stream(...))` — and the patch's own test
   asserts exactly that equality against a live DB.

3. `latest()` operates on the **output** of `filterCompacted`, i.e. downstream of the
   walk, on an array the walk has already finished producing and reordering. There is
   no data path from `latest()`/`isAfter()` back into the walk. So db581e47a3 cannot
   change what the walk collects.

4. The *semantic* point, which is the interesting one. Before db581e47a3 there was a
   latent **inconsistency between two orderings inside the same pipeline**:
   - the walk/pagination ordered by `(time_created, id)` desc;
   - `latest()` ordered by `id` alone.

   For imported / non-monotonic-ID sessions those two disagree, and a message the walk
   treated as "older than the boundary" could be picked by `latest()` as the newest
   turn. db581e47a3's `isAfter()` is
   ```ts
   info.time.created !== other.time.created ? info.time.created > other.time.created
                                            : info.id > other.id
   ```
   — i.e. **exactly the `page()` sort key**. Upstream has converged `latest()` onto the
   ordering `compactedWalk` was already relying on. The bounded walk is strictly safer
   after db581e47a3 than before it.

5. `filterCompacted`'s own boundary logic uses ID **equality** only
   (`msg.info.id === retain`, `part.tail_start_id`), never ID **comparison**, so the
   monotonic-ID assumption db581e47a3 removed was never load-bearing there.
   `finalizeCompacted`'s `findIndex`/`findLastIndex` are array-position based within
   the collected prefix. Both unaffected.

6. Bounded vs unbounded cannot differ even in principle: eager `filterCompacted` also
   `break`s at the boundary; the patch only avoids *fetching* past it.

   **One residual caveat I want on record:** the patch changes *when the DB is read*,
   not what is computed. If a session's `time_created` values are badly out of order
   with respect to compaction structure (e.g. an import that backdates
   post-compaction messages behind the boundary), the walk stops paging at the
   boundary and will never see them — but neither did the eager version, which
   `break`s at the same point. The behaviour is identical; it is upstream's boundary
   semantics that would be wrong in that scenario, not ours. **I am confident about
   the equivalence, and deliberately not making a claim about whether upstream's
   boundary semantics are correct for pathological imports.**

**(d) Verdict: KEEP-clean.** High confidence on both the textual apply and the
db581e47a3 non-interaction. SUNSET condition explicitly re-checked and NOT met.

## 3. retry-cap.patch — **DROP-upstream** (high confidence)

Upstream `c78986831c` "fix(opencode): cap session retries with jitter (#41939)",
first in **v1.18.17**, implements both halves of our patch:

```ts
export const RETRY_JITTER_FACTOR = 0.25
export const RETRY_MAX_RETRIES = 5
...
function exponential(attempt: number, random: number) {
  const base = RETRY_INITIAL_DELAY * Math.pow(RETRY_BACKOFF_FACTOR, attempt - 1)
  return Math.ceil(base + base * RETRY_JITTER_FACTOR * random)
}
...
if (!retry) return Cause.done(meta.attempt)
if (meta.attempt > RETRY_MAX_RETRIES) return Cause.done(meta.attempt)   // <-- ours, verbatim shape
```

The attempt-ceiling line is *mechanically identical* to ours (1-based `meta.attempt`,
`> CONST`, `Cause.done`). Differences, all in upstream's favour or neutral:

| | ours | upstream v1.18.18 |
|---|---|---|
| cap | `MAX_RETRIES = 8` | `RETRY_MAX_RETRIES = 5` (stricter) |
| jitter direction | downward, `ms * (1 - rand*0.2)` | upward, `ceil(base + base*0.25*rand)` |
| jitter scope | no-headers branch only | both header and no-header branches |
| 30s ceiling | preserved (downward-only) | preserved via `min(exponential, 30_000)` |
| testability | `Math.random()` inline | `delay(attempt, error, random = Math.random())` seam |

Upstream also expanded `retryable()` (`f929f8f100` + `61aefc0759`, v1.18.14) with
`RETRYABLE_MESSAGE_PATTERNS`, widening what retries — which makes the cap *more*
important, and it is present.

**(b) Does not apply** (expected — fully superseded). `patch -p1 --dry-run`:

```
packages/opencode/src/session/retry.ts:  Hunk #1 FAILED at 28.
                                         Hunk #2 FAILED at 62.
                                         Hunk #3 FAILED at 182.   (3/3 failed)
packages/opencode/test/session/retry.test.ts: Hunk #2 FAILED at 33. (1/3 failed)
```

Hunk #1 = the `MAX_RETRIES` / `RETRY_JITTER_RATIO` / `jitter()` block (upstream now
has its own constants + `exponential()` there). Hunk #2 = the `delay()` return
(upstream routes through `exponential()`). Hunk #3 = the `policy()` ceiling (upstream
already has the line). Test hunk #2 fails because upstream's test still asserts the
exact-value curve, but with the upward-jitter shape.

Upstream `retry.test.ts` runs green on v1.18.18 (part of the **63 pass / 0 fail** for
`session.test.ts` + `retry.test.ts`).

**(d) Verdict: DROP-upstream** — `c78986831c` (#41939), first tag **v1.18.17**.
High confidence.
**Optional follow-up, not a patch:** if 8 retries is genuinely wanted over 5, that is
a one-line constant change, not a reason to keep a 139-line patch whose test asserts
the opposite jitter direction.

## 4. createnext-readback.patch — **KEEP-rebase** (high confidence)

**(a) Not upstream.** v1.18.18 `createNext` still ends:
```ts
yield* events.publish(SessionV1.Event.Created, { sessionID: result.id, info: result })
return result
```
No read-back. The only v1.18.18 change to `session.ts` is `a54a693af2` in `fork`
(chronological boundary), ~170 lines away.

**(b) Applies textually clean:**
```
packages/opencode/src/session/session.ts:  Hunk #1 succeeded at 536 (offset -40 lines).
packages/opencode/test/session/session.test.ts: Hunk #1 succeeded at 282 (offset 37 lines).
```

**BUT IT DOES NOT TYPECHECK.** With the patch applied:

```
src/session/session.ts(917,7): error TS2719 / not assignable:
  Type 'Effect<Info, NotFoundError, never>' is not assignable to type 'Effect<Info, never, never>'.
    Type 'NotFoundError' is not assignable to type 'never'.
```

`Session.Interface.create` (session.ts:418) declares an error channel of `never`;
`get()` fails with `NotFoundError`; `return yield* get(result.id)` leaks it into
`create`'s signature at the `Service.of({...})` site. Reverting only this patch makes
`bun --cwd packages/opencode typecheck` clean, so the error is unambiguously ours.

**Verified fix (one word):**
```ts
return yield* get(result.id).pipe(Effect.orDie)
```
→ `packages/opencode` typecheck clean, `session.test.ts` **9 pass / 0 fail** including
the patch's own "create returns the durable row read back" assertion. `orDie` still
satisfies the patch's "fails loud on a lost write" intent (defect, not silent).

**Important, and I could not fully verify it:** `Session.Interface` and `get()` are
**byte-identical between v1.17.13 and v1.18.18** (the only session.ts churn is the
`fork` hunk). That strongly implies this type error is **pre-existing on the shipped
v1.17.13 patched build**, i.e. the patch has never typechecked and something in the
build path isn't gating on `packages/opencode typecheck`. I did not stand up a
v1.17.13 install to confirm (would need a second 5.7 GB `bun install`). Worth a
5-minute check by whoever owns the build, independent of this cutover.

**(d) Verdict: KEEP-rebase** — one-word fix (`.pipe(Effect.orDie)`); regenerate the
patch. High confidence.

## 5. sqlite-foreign-key-wrap.patch — **KEEP-clean** (high confidence)

**(a) Not upstream.** `projector.ts` is byte-identical between the tags; both upsert
sites still end `.run().pipe(Effect.orDie)`. Searched the whole range for the
behaviour moving elsewhere: `git log -S'SQLITE_CONSTRAINT_FOREIGNKEY'` and
`-S'FOREIGN KEY constraint failed'` over `v1.17.13..v1.18.18` return **nothing**.

**(b) Applies clean**, no offsets reported:
```
Checking patch packages/core/src/session/projector.ts...
Applied patch packages/core/src/session/projector.ts cleanly.
```

`bun --cwd packages/core typecheck` clean.

**(d) Verdict: KEEP-clean.** High confidence.

## 6. message-serve-provenance.patch — **KEEP-clean** (high confidence)

**(a) Not upstream.** No `serveId` stamping anywhere in the range
(`git log -S'serveId' v1.17.13..v1.18.18` empty). Both files it needs
(`packages/core/src/session/projector.ts`, `packages/schema/src/v1/session.ts`)
are zero-churn.

**(b) Applies clean** on top of sqlite-foreign-key-wrap:
```
Checking patch packages/core/src/session/projector.ts...
  Hunk #1 clean; Hunk #2 succeeded at 103 (offset 27 lines)   <- the +27 sqlite-foreign-key-wrap inserts
Checking patch packages/core/test/session/serve-provenance-gate.test.ts... clean
Checking patch packages/core/test/session/serve-provenance.test.ts... clean
Checking patch packages/schema/src/v1/session.ts... clean
```

Tests: `serve-provenance.test.ts` + `serve-provenance-gate.test.ts`
**16 pass / 0 fail**. `packages/core` and `packages/schema` typecheck clean.

Note the offset-27 is exactly the line count `sqlite-foreign-key-wrap`'s `foreign()`
helper adds above it — confirming the documented "disjoint hunks, ordered after it
regardless" claim is still accurate at v1.18.18.

**(d) Verdict: KEEP-clean.** High confidence.

---

## (e) Apply ordering among my patches

Two hard constraints, both same-file:

1. **`tool-fix` → `compaction-bounded-load`** (both `packages/opencode/src/session/message-v2.ts`).
   Verified applying in this order. Regions are genuinely disjoint (274-380 vs
   518-660), so it is *probably* order-independent, but apply.sh's documented order
   is verified and there is no reason to change it.
2. **`sqlite-foreign-key-wrap` → `message-serve-provenance`** (both
   `packages/core/src/session/projector.ts`). Verified; the second hunk's +27 offset
   comes from the first patch.

`createnext-readback` (session.ts) is independent of all of the above.
`retry-cap` is removed from the list entirely.

Current apply.sh positions (2, 17, 6, 28, 8) already satisfy both constraints. The
only edit needed to `PATCHES=()` is deleting `retry-cap`, plus the header-comment
bookkeeping (entry 4 → DROPPED section, citing `c78986831c` / #41939 / v1.18.17).

## Verification summary (all in /tmp/msgv2-scope-80503922, v1.18.18 + the 5 kept patches)

| check | result |
|---|---|
| `bun install --frozen-lockfile` | 4715 packages, ok |
| `packages/opencode` typecheck | clean (**after** the createnext `.pipe(Effect.orDie)` fix; 1 error without it) |
| `packages/core` typecheck | clean |
| `packages/schema` typecheck | clean |
| `test/session/message-v2.test.ts` | 40 pass / 0 fail |
| `test/session/messages-pagination.test.ts` | 53 pass / 0 fail |
| `test/session/prompt.test.ts` | 57 pass / 1 skip / 0 fail |
| `test/session/session.test.ts` | 9 pass / 0 fail |
| `test/session/retry.test.ts` (upstream, unpatched) | green |
| `packages/core/test/session/serve-provenance{,-gate}.test.ts` | 16 pass / 0 fail |
| tool-fix mutation check (src reverted, test kept) | 1 fail — patch non-vacuous |

## Could NOT determine

1. Whether `createnext-readback`'s type error is genuinely pre-existing on
   v1.17.13-patched. The evidence (identical `Interface` and `get()` at both tags) says
   yes, but I did not build a v1.17.13 tree to prove it. If yes, the release build is
   not gating on `packages/opencode typecheck` and that is a separate finding.
2. Whether upstream's compaction boundary semantics are correct for imported sessions
   whose `time_created` ordering conflicts with compaction structure. Out of scope —
   our bounded walk is *equivalent* to the eager one there, so it neither introduces
   nor fixes anything.
3. I did not run the full `packages/opencode` suite (only the five touched files) or
   any of the TUI/other-scope patches — out of scope.

## Cleanup

`/tmp/msgv2-scope-80503922` left in place with the 5 patches applied + the
`.pipe(Effect.orDie)` fix, in case whoever regenerates `createnext-readback.patch`
wants it. Remove with:

```bash
git -C /home/dev/projects/opencode worktree remove --force /tmp/msgv2-scope-80503922
```

Do **not** touch `/tmp/oc1818.*`, `/tmp/oc1818b.*` or `/tmp/wt-tr*` — those belong to
peer sessions.
