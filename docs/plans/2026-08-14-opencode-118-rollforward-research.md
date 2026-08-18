# opencode 1.17.13 -> 1.18.18 roll-forward: research

Status: RESEARCH IN PROGRESS (started 2026-08-14)
Driver bead: workstation-er3t (P0, opencode message-ID 48-bit wrap)
Related bead: pigeon-0k8m (P2, pigeon post-ack verification tripwire)

## Why we are doing this

opencode's ID generator packs `Date.now() * 0x1000` (~2^52.7) into a 6-byte
field (`packages/opencode/src/id/id.ts:60-69`). It wraps every 2^36 ms =
795.36 days. The 26th boundary fell at

    1786706395136 ms = 2026-08-14 07:19:55 EDT

Every ascending ID minted after that sorts BELOW every ID from the prior ~2.2
years. Consumers that used raw ID string ordering as a recency test therefore
broke, and any session holding pre-boundary history went MUTE: the prompt loop
exits at step 0, `session.idle shouldNotify=false`, no error, no notification.

Measured on cloudbox 2026-08-14: 10 human messages lost across 3 sessions
(ses_00a083d4, ses_01680e0d8, ses_02db91d4a). Sessions born after the boundary
are unaffected. Full evidence in bead workstation-er3t.

## The decisive finding

Upstream ALREADY FIXED the consumers, in

    db581e47a3  fix(opencode): order legacy message loop by time (#40990)
    authored 2026-08-07 (one week BEFORE the wrap)
    first release: v1.18.15

Two changes:

- `message-v2.ts` `latest()` now uses `isAfter(info, other)`, which compares
  `info.time.created` first and falls back to `info.id` only as a tiebreak.
- `prompt.ts` loop exit changed from `lastUser.id < lastAssistant.id` to
  `lastAssistant.parentID === lastUser.id` (identity, not ordering).

`id.ts` itself is UNCHANGED upstream -- the 48-bit truncation is still there and
will recur in ~795 days. Only the consumers were repaired.

We are on v1.17.13. Newest tag is v1.18.18. Hence: roll forward, do not patch.

DECISION (2026-08-14, user): roll forward to 1.18, re-evaluating each patch --
apply where justified, rewrite where necessary, drop where unnecessary. An
earlier plan to backport db581e47a3 onto 1.17 as a hotfix was DROPPED in favour
of this.

## Repo topology (do not confuse these)

| Repo | Path | Role |
|---|---|---|
| opencode | ~/projects/opencode | source checkout; remotes: `origin`=anomalyco/opencode (THE upstream), `fork`=johnnymo87/opencode, `upstream`=sst/opencode (NOT ours) |
| opencode-patched | ~/projects/opencode-patched | the patch series (`patches/*.patch` + `patches/apply.sh`), CI builds 4 platforms |
| workstation | ~/projects/workstation | pins the 4 release hashes in `users/dev/home.base.nix` |

IMPORTANT: `origin` is anomalyco, not sst. Check anomalyco refs. Local refs go
stale; `git fetch origin --tags` first.

Existing process docs, READ THESE BEFORE REBASING:
- `opencode-patched/.opencode/skills/patch-refresh.md` (refresh workflow, repo ownership)
- `opencode-patched/.github/workflows/check-sunset.yml` (detects patches now upstream)
- `opencode-patched/.opencode/skills/darwin-signing.md` (darwin zips must be ad-hoc codesigned or macOS SIGKILLs them)
- `workstation/docs/plans/2026-06-11-opencode-1.17-cutover-runbook.md` (the previous cutover; copy its shape)

## Scale of the jump

`git diff --stat v1.17.13..v1.18.18` = 1193 files, +341737 / -118069.

## Per-patch rebase-risk signal (computed, not guessed)

Churn is measured in the non-test files each patch touches, v1.17.13..v1.18.18.
Regenerate with /tmp/patchchurn.sh (also inlined at the bottom of this doc).

    PATCH                         FILES   ADDED DELETED  FLAGS
    attach-route-resolve              6      17       2   created:route.ts,sse.ts
    available-cache                   1       0       0   UNCHANGED
    bootstrap-disposed-filter         1      14       7
    cache-thinking-skip               1     358      61   *** transform.ts hotspot
    compaction-bounded-load           1      12       9
    createnext-readback               1       2       2
    event-cold-start-directory        1       0       0   UNCHANGED
    event-log-gate                    1       0       0   UNCHANGED
    event-session-scope               1       0       0   UNCHANGED
    gemini-empty-parts                2     358      61   *** transform.ts hotspot
    globalbus-maxlisteners            1       0       0   UNCHANGED
    message-serve-provenance          2       0       0   UNCHANGED
    opus5-adaptive-thinking           1     358      61   *** transform.ts hotspot
    plugin-loader-observability       1       2       0
    project-copy-debounce             1       1       1
    registry-port-fence               3       0       0   created:routing-lease.ts
    retry-cap                         1      37      30
    serve-lease                       5       2       1   created:routing-lease.ts,heartbeat.ts
    session-door-routes               5      11       4
    session-mcp-routes                4      11       4
    sqlite-foreign-key-wrap           1       0       0   UNCHANGED
    step-end-diff-bound               1       0       0   UNCHANGED
    tool-fix                          1      12       9
    tui-door-attach                   6      16       7   created:sse.ts
    tui-door-tests                    0       0       0   (tests only)
    tui-mcp-dialog                    4      14       7
    tui-reconcile-bound               4      14       7   created:reconcile.ts,sse.ts
    vim                              10      51       3   creates the whole vim/ dir

VERIFIED: every "GONE"/created file above is absent at BOTH v1.17.13 and
v1.18.18, i.e. the patch creates it. NO upstream file removal hits any patch.
Structural risk is therefore lower than the raw diffstat suggests.

Hotspot: `packages/opencode/src/provider/transform.ts` (+358/-61) is shared by
THREE patches (cache-thinking-skip, gemini-empty-parts, opus5-adaptive-thinking).
Second cluster: `packages/opencode/src/session/message-v2.ts` (+12/-9) shared by
tool-fix and compaction-bounded-load -- AND it is the file db581e47a3 rewrites,
so expect interaction there.

## Verdict taxonomy for the research pass

For each patch produce exactly one of:
- DROP-upstream   : behavior now in 1.18.18; delete patch + apply.sh entry
- KEEP-clean      : still needed, applies with no/whitespace conflict
- KEEP-rebase     : still needed, needs context fixups only
- REWRITE         : still needed, upstream restructured the area
- OBSOLETE-ours   : we no longer want it regardless of upstream

## Research findings (2026-08-14, four parallel explore agents)

Raw per-agent output: /tmp/research-transform.md, /tmp/research-messagev2.md,
/tmp/research-infra.md, /tmp/research-tui.md. Copy these into the repo before
they are swept from /tmp.

### Headline: the roll-forward is TRACTABLE

28 patches. 2 drop, 3 need rebasing, 23 apply clean.
Existing `apply.sh` ordering already satisfies every dependency -- NO reordering
needed.

CORRECTION (adversarial review): an earlier draft of this doc said the full
28-patch ordered run against pristine v1.18.18 saw "only vim fail". That is
WRONG. FOUR patches failed: the two expected drops (retry-cap, opus5), plus
`gemini-empty-parts` (test hunk only) and `vim`. The accurate statement is:
"of the 26 KEPT patches, only vim and gemini's test hunk fail." This matters
operationally because `apply.sh` EXITS ON FIRST FAILURE, unlike the research
loop that produced the table -- an executor trusting "only vim" would hit a wall
at the first dropped patch.

| Verdict | Count | Patches |
|---|---|---|
| DROP-upstream | 2 | opus5-adaptive-thinking, retry-cap |
| KEEP-rebase | 3 | gemini-empty-parts, createnext-readback, vim |
| KEEP-clean | 23 | everything else |

### DROP-upstream (delete patch + apply.sh entry)

- **opus5-adaptive-thinking** -- upstream `2b2aacc939` (#38757) is our change
  verbatim; hunks 1+2 reverse-apply clean at v1.18.18. Matches its own SUNSET note.
- **retry-cap** -- upstream `c78986831c` (#41939): `RETRY_MAX_RETRIES=5`,
  identical `meta.attempt > CONST -> Cause.done` line, plus jitter. All 3 source
  hunks already fail. NOTE upstream chose 5, we had 8; accept upstream's value or
  re-justify ours as a new patch. DECIDE THIS EXPLICITLY.

### KEEP-rebase (the only real work)

- **gemini-empty-parts** -- all SOURCE hunks apply (gemini.ts +2, transform.ts
  +36). Only the `transform.test.ts` append hunk fails: EOF anchor moved
  4118 -> 5668 (+940 lines of upstream test churn). Fix = re-cut a pure append.
- **createnext-readback** -- applies clean but BREAKS TYPECHECK: `get()` leaks
  `NotFoundError` into `create`'s `never` error channel. One-word fix, verified.
- **vim** -- 3 of 15 hunks drift, all from ONE upstream feature (new `tui.cursor`
  config). `git apply --3way` resolves with zero conflict markers. The
  historically fragile hunk #9 (`.catch()` send path) applied CLEAN, no re-port
  needed.
  SEMANTIC FIX REQUIRED, not just textual: vim's cursor effect else-branch
  unconditionally sets `{block, blinking:true}`, which clobbers upstream's new
  `tui.cursor` for NON-VIM users. Change to
  `tuiConfig.cursor ?? {style:"block", blinking:true}`.

### Traps that a textual rebase would silently get wrong

1. **opus5 hunk #3 must NOT be re-applied by hand.** Upstream moved PAST our
   port: `variants()` now calls `anthropicOpus45Effort(model, effort)` returning
   `{thinking:{type:"enabled",budgetTokens:min(16_000, floor(limit.output/2-1))}, effort}`.
   Our patch kept the v1.17.13 `{ effort }` body. Re-applying REGRESSES opus-4-5.
2. **cache-thinking-skip's reach is narrowed by a new upstream gate.** `message()`
   now computes `usesAnthropicAutomaticCaching` and skips `applyCaching` entirely
   for npm anthropic / google-vertex-anthropic with `options.cacheControl`. The
   patch stays live for openrouter / openai-compatible / copilot / alibaba /
   vertex-anthropic-without-cacheControl. REGRESSION-TEST IT AGAINST A
   NON-NATIVE-ANTHROPIC MODEL or you will be testing a bypassed code path.
3. **`event-log-gate`: DO NOT SUNSET. Upstream REGRESSED.** Its named sunset
   trigger `b0017bf1b9` gated inserts in `packages/opencode/src/sync/index.ts`.
   That file DOES NOT EXIST at v1.18.18 -- the sync engine was rewritten into
   `core/src/event.ts` (EventV2) and THE GATE WAS NOT CARRIED ACROSS. No
   successor gate exists (`EXPERIMENTAL_WORKSPACES` appears only at flag.ts:50,
   control-plane/workspace.ts:532, runtime-flags.ts:50). `event.ts:337`
   `insert(EventTable)` + `:304` dup-SELECT are unconditional again. Our patch is
   MORE important after the roll-forward, not less. (This is the 2.8GB-of-4.3GB
   opencode.db bloat.)
4. **`git tag --contains` IS UNRELIABLE ON THIS REPO.** anomalyco history was
   rewritten: v1.17.9 and v1.17.13 mutually diverge by 14188/428 commits.
   Verify upstream-presence BY CONTENT at the target tag, never by tag ancestry.
   (The core db581e47a3 claim was re-verified by content directly against
   v1.18.18: `isAfter` present, `latest()` uses it, `parentID` exit in place,
   ZERO occurrences of `lastUser.id < lastAssistant.id`.)
5. **Generated SDK files: keep textual, verify by regenerating.** `sdk.gen.ts` is
   byte-identical upstream; `types.gen.ts` drift is nowhere near our appended
   types; all hunks apply clean. The generator (`packages/sdk/js/script/build.ts`,
   hey-api 0.90.10) uses `clean:true`, so regenerating would re-encode all of
   upstream's output into our patch. Use it as a CHECK instead: after applying,
   `bun --cwd packages/sdk/js run build` and assert an empty
   `git diff` on `src/v2/gen`.

### Confirmed non-issues (checked, not assumed)

- `compaction-bounded-load` does NOT collide with db581e47a3, and is strictly
  SAFER after it. `compactedWalk`'s newest-first ordering comes from `page()` SQL
  (`orderBy(desc(time_created), desc(id))`), not from `latest()`. Before the fix
  the pipeline held two DISAGREEING orderings (walk on `(time_created,id)`,
  `latest()` on `id` alone); `isAfter()` is now exactly the `page()` sort key, so
  upstream converged `latest()` onto what the walk already assumed. Separately,
  `filterCompacted` uses ID EQUALITY only, never comparison -- the monotonic-ID
  assumption was never load-bearing there.
- `tool-fix` still needed: the PR #16751 regression test is RED on plain v1.18.18.
- `serve-lease`'s `prompt.ts` hunks are disjoint from db581e47a3's.
- `sdk.tsx` is byte-identical upstream. `sync.tsx` drift (21 lines) is the client
  half of db581e47a3 and is disjoint from our bootstrap-region hunks.
- `projector.ts` zero-churn is REAL, not a rename: same blob `afa60dfa88`.
- No upstream file removal hits any patch (all "GONE" files are patch-created).
- Upstream shipped NO vim/modal editing in 1.18. vim.patch stays full size.

### Follow-ups discovered (file as separate beads, do NOT do during the bump)

- **`attach-route-resolve` is now largely dead code.** Its `util/route.ts` has
  ZERO production consumers in the final stacked tree (only its own test imports
  it); `tui-door-attach` reverts nearly all its `attach.ts` hunks and rewrites its
  `sdk.tsx` SSE hunks. Still live: `util/sse.ts` and the `sessionID` SDKProvider
  prop. Recommend folding those two into `tui-door-attach` and deleting the patch.
- **`globalbus-maxlisteners` has no numbered entry in `apply.sh`** (gap between
  #14 and #16); rationale survives only in inline comments + bead workstation-qjk4.
- **`retry-cap` value divergence**: upstream picked 5, we ran 8.

### Open / unverified

- No typecheck or test run for the transform, infra, or TUI groups (read-only
  agents, no `node_modules` in throwaway trees). "Applies" != "compiles".
  The message-v2 group DID get a full `bun install` + test run on v1.18.18 + its
  5 patches: message-v2 40/0, pagination 53/0, prompt 57/0 (including
  db581e47a3's own new tests), session 9/0, provenance 16/0; opencode/core/schema
  typecheck clean.
- `@opentui` 0.3.4 -> 0.4.5 compatibility for vim is ARGUED (upstream still uses
  the same five `TextareaRenderable` members: `cursorOffset`, `deleteRange`,
  `insertText`, `logicalCursor`, `plainText`), NOT proven.
- Whether `GET /api/session/:sessionID/history` is actually wired (no
  `.handle("session.history")` found). If it is served, event-log-gate empties
  it. Identical at both tags, so not a roll-forward regression, but the gate's
  "nothing reads the log" premise remains unproven.
- Whether `createnext-readback`'s type error pre-exists on v1.17.13-patched
  (evidence says yes, which would imply the release build is not gating on
  typecheck -- worth confirming, it affects how much we trust CI).
- Whether any fork call site outside transform.ts passes `options.cacheControl`
  (decides whether trap #2 is real in practice).

### Process note for the execution phase

The four parallel agents COLLIDED in /tmp: two picked the same worktree path
prefix (`/tmp/oc1818.*`, `/tmp/wtpath`) and one applied patches into another's
tree. No shared repo was mutated and no data was lost, but when parallelizing the
execution phase, give every worker a `$RANDOM`-suffixed scratch path.


## Adversarial review (2026-08-14, adversarial-reviewer-fable)

Reviewer independently re-verified the load-bearing claims by content at
v1.18.18 and found NO misclassification among the 28 patch verdicts. It sampled
~8 of the 23 KEEP-cleans directly; all held. The real gaps are all EXECUTION
PHASE, plus one hazard nobody had checked.

### RESOLVED: retry-cap 5-vs-8

ACCEPT UPSTREAM'S 5. Our 8 was a cap where upstream had NONE; upstream's 5 is
strictly stricter, so the Vertex/Gemini runaway cure is preserved and
strengthened. Upstream also widened `RETRYABLE_MESSAGE_PATTERNS` (v1.18.14) --
more error classes retry now, but bounded at 5. If 8 is ever genuinely wanted
it is a 1-line micro-patch, not a reason to keep a 139-line patch.

### THE HAZARD NOBODY CHECKED: DB migrations. Verified EMPTY.

The four research agents partitioned by PATCH, so none owned "what does upstream
do to our data" -- the structural blind spot of a partitioned search. It happened
to be benign, but that was luck. Now verified:

    ls-tree packages/core/src/database/migration/ at v1.17.13 vs v1.18.18 => IDENTICAL
    migration.gen.ts, migration.ts, data-migration.sql.ts, packages/schema => ZERO diff

ZERO new local sqlite migrations in 713 commits. Consequences:
- 1.18.18 opens the existing opencode.db with no schema change; no fix-up SQL phase.
- Rollback is a pin-revert; the DB is untouched.
- workstation's direct-SQL consumers are unaffected (oc-search orders by rowid,
  oc-context by `time_created DESC, id DESC` -- both checked).

This is the single biggest de-risking fact in the whole plan. The prior cutover's
dominant fear (V2 corruption, destructive migration #29908) is structurally
absent this time.

### [HIGH] No integrated verification, and CI will NOT catch it

`build-release.yml` contains NO typecheck step (verified), and `bun build` does
not typecheck. The `createnext-readback` type error has therefore PROBABLY BEEN
SHIPPING SINCE 1.17. Bundling catches missing files, not type/runtime drift.

Only the message-v2 group (5 patches) was actually built and tested. The other 21
rest on `git apply --check` + source reading.

MANDATORY GATE before cutting any release -- one scratch worktree, all 26 kept
patches + the 3 fixes, then:
- `bun install`
- typecheck ALL of opencode / core / schema / tui / sdk
- FULL `packages/tui` and `packages/opencode` suites (not just named files)
- SDK regen empty-diff: `bun --cwd packages/sdk/js run build && git diff --exit-code -- src/v2/gen`
- `script/build.ts` for linux-arm64, then BOOT THE BINARY
  (build.ts itself changed -- tree-sitter worker embedded differently for
  opentui 0.4.5 -- so binary boot smoke is not optional)

Highest-risk semantically-untested surfaces: vim under @opentui 0.4.5 (compile
argued, not proven), the door/lease runtime path against a 1.18 serve, and
gemini-empty-parts' `part.text` narrowing against v1.18.18 `ModelMessage` typings.

### [HIGH] Validate WITHOUT committing the pool

Replicate the 2026-06-11 method: run the built patched binary with `XDG_DATA_HOME`
pointed at a COPY of the live opencode.db in /tmp, on an isolated port.

THE KILLER TEST: prompt one of the three mute sessions ON THE COPY and watch the
loop actually run (assistant row created, `parentID` = the new user msg). That
validates the entire motivation end-to-end at zero blast radius. Also smoke the
pigeon plugin there (session-start registration, swarm tool present,
prompt_async 200). Gate the pool switch on both.

### [HIGH] Follow the previous runbook's gates

`docs/plans/2026-06-11-opencode-1.17-cutover-runbook.md` has gates this plan was
missing entirely:
- Quiesce ALL ~15 writers (serve pool + standalone TUIs + pigeon-adjacent), not
  just the pool. Schema-identity lowers the stakes but 713 commits of
  projector/event semantics are unaudited for mixed-writer drift. Quiesce is cheap.
- Run the switch FROM A BARE SSH SHELL, never inside an opencode session (the
  switch kills your own driver).
- Online backup before switch (python sqlite3 `.backup` one-liner), keep ~2 weeks.
- Verification gates: health-version curl, trivial launch, subagent orphan-check
  SQL, Question-tool submit gate, vim runtime exercise, self-compact-resume check.
- Gate the `update-opencode-patched` automation onto the new line so it cannot
  auto-bump mid-cutover.

### [MEDIUM] Rollback (cheap, because no migrations)

Stop pool -> revert the pin commit in `home.base.nix` -> `home-manager switch` ->
start pool. Old release assets persist on GitHub, but VERIFY rather than assume:
`nix store prefetch-file` one v1.17.13-patched.9 asset before cutover.
DB restore is only needed if corruption is observed, not as part of rollback.
Capture before cutover: the backup file, `readlink -f ~/.nix-profile/bin/opencode`,
and the pin commit sha.
Residual (LOW, unverified): 1.18-written JSON blobs inside message/part rows read
back by 1.17 after a rollback. `packages/schema` is zero-churn so decode shapes
match, but the 49 commits v1.18.15..v1.18.18 were not audited for new enum values
in persisted blobs. The backup covers this tail risk.

### [MEDIUM] Upstream fixed the loop-breaking consumers, NOT all raw-ID ordering

Two raw-ID-ordering consumers SURVIVE at v1.18.18 (verified). Neither is
mute-class; do NOT fix during the bump, file beads:
- `packages/tui/src/routes/session/index.tsx:211` -- children list
  `.toSorted((a,b) => a.id < b.id ...)`: cross-boundary parent+children display
  in the wrong order, PERMANENTLY (~795 days).
- `packages/tui/src/routes/session/index.tsx:659` -- redo finds "next user
  message" via `x.id > messageID`: broken across a revert spanning the boundary.

Also: `id.ts` is unchanged (zero diff), so the NEXT WRAP IS ~Oct 2028. File a
long-fuse bead now; nobody will remember.

### [MEDIUM] vim/gemini/createnext must be RE-CUT, not merged at build time

`apply.sh` uses plain `git apply`, and CI clones `--depth 1 --branch v<version>`.
`--3way` needs pre-image blobs a shallow tag clone does not have. The research's
"`--3way` resolves clean" is a RESEARCH result; the deliverable is a re-cut patch
against v1.18.18 with the `tuiConfig.cursor ?? {style:"block",blinking:true}`
semantic fix baked in. Same for gemini's test hunk and createnext's `Effect.orDie`.
"Re-cut three patches" is an explicit work item, not an implication.

### [MEDIUM] Pigeon coupling: statically safe

`packages/plugin` churn between tags = package.json only; plugin loader +2 lines
(ModalPlugin). `sdk.gen.ts` byte-identical. `prompt_async` and `/global/health`
present at both tags. Pigeon's msg_ids are its own, not opencode IDs.
`38e10eb140` (ignore unknown config fields, v1.18.16) helps config compat.
Residual risk is runtime-only -> covered by the DB-copy gate above.
Watch pigeon-0k8m post-cutover.

### Framing confirmed: v1.18.18, NOT the minimum v1.18.15

v1.18.15..v1.18.18 = 49 commits and contains `c78986831c` (retry cap, first in
v1.18.17) and `38e10eb140` (config leniency, v1.18.16). Targeting the minimum
version would force KEEPING retry-cap (a patch we can otherwise delete) and lose
config robustness, to skip mostly docs/console/provider-metadata commits.
Minimum-version = MORE patches, not less churn.

### Single most likely failure mode

A patch among the 21 textual-only ones that applies, bundles, and passes the
named CI tests but is RUNTIME-WRONG on 1.18 -- surfacing only after the whole
pool is switched, because nothing between `git apply --check` and production runs
a full typecheck, a full suite, or a booted binary. Most probable instance: the
TUI cluster under @opentui 0.4.5 + the rewritten tree-sitter-worker build path.

### Still could not determine

- Whether anything sets `options.cacheControl` at runtime for our providers
  (workstation configs: no; upstream provider defs/plugins: unaudited).
- Runtime behavior of front-door / lease / door-attach against a 1.18 serve.
- Whether `GET /api/session/:id/history` is wired.
- Whether createnext-readback's type error truly pre-exists on shipped 1.17
  builds (strongly implied: byte-identical `Interface`/`get()` + no CI typecheck).
- @opentui 0.4.5 vim compile + darwin implications of the opentui bump (native
  bits / signing) -- until the stacked-build gate runs and the macOS leg builds.
- Exhaustive audit of the 49 commits' persisted-blob shapes for the rollback read
  path.

### Bookkeeping for the bump

Delete 2 patch files + their `apply.sh` array lines; move retry-cap and opus5 to
the DROPPED section with content-verified citations (`c78986831c`/v1.18.17,
`2b2aacc939`/v1.18.5); add the missing #15 header entry for
globalbus-maxlisteners (bead workstation-qjk4); update the "TARGET UPSTREAM" line.
Note `build-release.yml`'s Phase-8 step runs `test/util/route.test.ts`, so the
future deletion of attach-route-resolve must edit that workflow too -- one more
reason to keep that consolidation OUT of this bump.

## W1 RESULTS (2026-08-14, bead workstation-l60f) — GATE PASSED, 0 REGRESSIONS

Deliverable branch: `opencode-patched` @ `w1-1818-recuts` (commit a789f4f), pushed.
Re-cut patches live there; `apply.sh` bookkeeping deliberately left to W3.

### Headline

v1.18.18 + our 26 kept patches introduces **zero test regressions among tests
that are green at baseline**, against the true production baseline (v1.17.13 +
all 28 shipped patches), measured under **bun 1.3.14**.

Read that qualifier literally. 19 `packages/opencode` tests and 21
`packages/core` tests are red on BOTH trees, so the delta is blind over
everything they cover: `Server.listen` (7), PTY (3), `session.llm.stream`
payload composition (3), Vertex REP endpoints (3), event session-scoping (4),
CLI help-text, and the SessionV2 durable-replay cluster. A 1.18 change that
broke any of those would also produce a zero delta. W2's runtime gates are the
mitigation and must stay mandatory; "0 regressions" does not soften them.

The right comparator is patched-vs-patched, not patched-vs-pristine. Upstream
v1.18.18 has 19 failures of its own in `packages/opencode` in this sandbox, and
the patch stack has more still; only the DELTA between the two patched trees is
evidence about the roll-forward.

| Gate | Result |
|---|---|
| 26 patches, apply.sh order, plain `git apply`, fail-fast | ALL CLEAN |
| Typecheck (8 packages) | PASS — opencode, core, schema, tui, sdk/js, llm, plugin, protocol |
| `packages/opencode` full suite | 3340 tests; delta vs baseline = **0** |
| `packages/tui` full suite | 291 pass / 0 fail |
| `packages/llm` full suite | 299 pass / 0 fail |
| `packages/core` full suite | 0 introduced; **1 pre-existing failure FIXED** |
| SDK regen | +533 lines — but IDENTICAL at baseline (see below) |
| linux-arm64 build + boot | builds; `--version`, `--help`, `serve` + `/global/health` + live SSE all OK |

### A FOURTH patch needed re-cutting, and only typecheck found it

The research pass predicted three re-cuts. There were **four**.
`event-log-gate` did not compile against v1.18.18.

An earlier draft of this section said upstream had moved the durable sequence
from `event.seq` to `event.durable.seq`. **That was wrong** (caught in
adversarial review). `packages/core/src/event.ts` is the IDENTICAL BLOB at both
tags (`c92ac0ac2c`), and `packages/schema/src/event.ts` has zero top-level `seq`
at either tag. Nothing moved: `expect(event.seq).toBe(0)` was wrong when it was
written and never compiled against either tag.

The real finding is worse for CI than a rebase would have been: this patch's own
regression test has been RED in the shipped stack the whole time — it fails in
the v1.17.13 production baseline too — and nothing noticed, because
`build-release.yml` runs neither a typecheck nor the full core suite, only named
test files. Second type error the stack has carried (see `createnext-readback`).

`packages/llm` was NOT in the bead's typecheck list but IS patched by
`gemini-empty-parts`. The correct list is eight packages.

### Three "failures" that are not failures — each needed a baseline to see

- **`?session_ids=` 400 (4 red tests).** Looked at first like a live production
  outage of the pool's per-session SSE. It is not. Connectivity was not enough
  evidence, so filtering was proved directly against the built binary: two
  sessions A and B in one directory, a subscriber scoped to `?session_ids=A` and
  an unscoped control, three title updates each. **Scoped stream: 3 A events, 0
  B events. Unscoped control: 3 and 3.** Positive and negative both hold, so the
  feature is correct end-to-end and the tests are the thing that is wrong. Only
  the *test harness* 400s, and only once `session-door-routes` DECLARES the
  field. The harness mechanism is still un-root-caused. Bead `workstation-64da`.
- **SDK regen is not empty (+533).** Pristine upstream regen IS empty, so it is
  ours — but the baseline produces the identical +533, so it is pre-existing.
  The research's "assert an empty diff" criterion is simply wrong for a patched
  tree; the correct gate is PARITY with the previous release. Bead `workstation-n2o8`.
- **The lease-deadline test.** Appeared as the single regression of the entire
  gate on one run, then did not reproduce on two later stacked full-suite runs
  (1 failure in 3), and passes at file level in both trees. Load/order-dependent
  timing. Bead `workstation-ibw0`. A one-shot suite run is not evidence for a
  deadline test — and neither is a two-shot one, which is why the clean re-run
  below matters.

### Traps from the research pass, resolved

- **cacheControl (trap #2): no setter found in source; patch is LIVE.** Upstream's
  `usesAnthropicAutomaticCaching` gate only fires when `options.cacheControl` is
  set. Across `packages/opencode/src`, `packages/core/src` and `packages/llm/src`
  the ONLY occurrence of `options.cacheControl` is the gate's own check — nothing
  in source ever sets it. So `applyCaching` still runs for our traffic and
  `cache-thinking-skip` is not bypassed. 411 transform tests pass. Residual,
  accepted: model options also arrive from the models.dev catalog and from
  user/provider config, which were NOT audited.
- **vim under @opentui 0.4.5: compiles AND passes.** tui typecheck clean, 291/291.
  The semantic cursor fix is in the re-cut.
- **`event-log-gate` premise: CONTRADICTED.** Applying it alone to pristine
  v1.18.18 turns 15 core tests red — SessionV2 replay/projection, migration
  restart, durable progress all read the log. Parity with production, so not a
  blocker, but the rationale needs re-weighing. Evidence in bead `workstation-zvki`.

### Method notes worth keeping

- **Build requires bun ^1.3.14; the nix bun is 1.3.3.** `script/build.ts`
  hard-refuses. Worse, `bun test` still RUNS on 1.3.3, so results can quietly be
  produced on the wrong bun — the failure count moved (25 -> 19/20) when W1
  re-ran everything on 1.3.14. Bead `workstation-2srm`.
- `git apply` is atomic per patch, so a patch whose LAST hunk is stale
  contributes NO hunks. An early diagnostic run that continues past failures
  therefore produces a tree that is not the real stack; the gate must be a
  fail-fast run in apply.sh order from pristine.
- Every scratch tree used a `$RANDOM`/mktemp path (7 worktrees, no collisions).

## W2 RESULTS (2026-08-14, bead workstation-7duy) — GATE PASSED

**Scope of the claim, stated precisely** (the first draft said "fix proven
end-to-end", which over-claims): the wrap-fix mechanism is proven on production
data, on **all 3** mute sessions, under a sandboxed config, with a recording-stub
pigeon daemon. TUI, PTY, Vertex REP and the SessionV2 replay cluster remain
untested. **The tested artifact is W1's hand-applied tree, NOT the release W3
will cut** — see "What must still gate W3".

### Headline

**A session that had been mute for the entire incident answered, on the real
production model, under the new binary — and the deployed v1.17.13 binary failed
on that same session minutes earlier, on the same database, through the same
endpoint.** That differential is the whole point of W2 and it is now evidence
rather than argument.

| Gate | v1.17.13 (deployed) | v1.18.18 + 26 patches |
|---|---|---|
| **All 3** mute sessions, `prompt_async` (`00a083d4`, `01680e0d`, `02db91d4`) | user row materialized, **0 assistant rows**; log `loop step=0` -> `exiting loop` in 16 ms | **assistant row**, `parentID` = new user msg; log `step=0` -> **`step=1`** -> exit |
| Same, on `claude-opus-5@default` (the real model) | — | `finish=stop`, no error, `time.completed` set, text = `PONG` |
| Other two mute sessions (gemini-flash) | — | both `finish=stop`, no error, completed, text `PONG`, `parentID` correct |
| Daemon->opencode endpoints (pigeon's `opencode-client.ts`) | — | `GET /session/{id}` 200 with **both** `id`+`directory`; `/session` 200; `/abort` 200; `/message` 200; nonexistent session **404** (the daemon's "deleted" signal) |
| Fresh control session (proves the harness runs turns at all) | answers, `finish=stop` | answers, `finish=stop`, text `PONG` |
| `?session_ids=` filtering, REAL session ids | — | scoped **6 watched / 0 unwatched**; unscoped control **6 / 6** |
| pigeon plugin `/session-start` registration | — | received: `backend_kind=opencode-plugin-direct`, protocol v1, endpoint, pid, cwd |
| swarm tool present | — | yes (session answered `YES`) |
| `prompt_async` | 204 | 204 |

The assertion was deliberately split, because "an assistant row exists" is NOT
sufficient — `prompt.ts:1185` writes the assistant row **before** the LLM stream,
so an errored or empty turn also produces one:

- **A (wrap fix):** assistant row exists AND `parentID` == the new user message.
- **B (turn healthy):** no `error`, `finish` set and != `tool-calls`,
  `time.completed` set, non-empty text part.

Both pass. A on the mute session under both models; B cleanly on the control and
on the opus run of the mute session.

### The isolation method in the runbook DOES NOT WORK, and it wrote to production

This is the most important thing W2 learned, and it is now bead `workstation-dkcs`.

The documented method (2026-06-11 runbook, inherited by this plan) is to point
`XDG_DATA_HOME` at a copy of the live DB. On this host that is **silently
insufficient**: `home.base.nix:1020` exports `OPENCODE_DB` globally, and
`packages/core/src/database/database.ts` `path()` consults `Flag.OPENCODE_DB`
**first**, returning it verbatim when absolute. The throwaway serve therefore
opened the **live production database**.

It was verified by measurement, not inference: `/proc/<pid>/fd` held handles only
on `~/.local/share/opencode/opencode.db{,-wal,-shm}`, and the copy had no
`-wal`/`-shm` and an mtime that never moved off the VACUUM time.

Two live artifacts were created on the real session `ses_00a083d40ffe` (a model
switch and a queued prompt, 4 rows total). All were removed and live was verified
identical to the pre-test snapshot. It stayed cheap **only because that session
was mute** — the turn never ran. Had it run, an opus turn with tool access would
have executed a real backlog against a real project directory.

Why it fooled the first two attempts: the **log path DOES honor
`XDG_DATA_HOME`**, so a scratch logfile appeared exactly where expected and the
isolation looked correct. Assertions against the copy then returned "0 assistant
rows", which reads as a clean PASS — a false green, because the copy had never
received the request.

Note the asymmetry: `cli/cmd/serve.ts` **already guards** the analogous
routing-slot hazard (`OPENCODE_SERVE_ID` + `OPENCODE_ROUTING_DB` inherited from a
parent session), and that guard fired correctly during this same session and
prevented a serve-0 hijack. The database hazard — the more dangerous of the two —
has no guard at all.

**Mandatory gate, adopted for every boot after the incident and held every time:**

```bash
OPENCODE_DB=<copy> ...   # explicit, not inherited
ls -l /proc/<pid>/fd | grep -q '/home/dev/.local/share/opencode/opencode.db' && ABORT
```

### Three harness traps that each produced an uninterpretable result

Each of these returned something that LOOKED like a clean answer:

- **`/api/session/{id}/prompt` admits input but does not run a turn.** It queues
  into `session_input`/`session_message` (`delivery` is only `steer`|`queue`) and
  returns 200 with an `admittedSeq`. No loop, no turn. The route that actually
  runs a turn — and the one pigeon uses in production, so the right one for this
  incident — is the un-prefixed **`POST /session/{id}/prompt_async`**.
- **No control = no interpretation.** With the queueing endpoint, the mute
  session produced no assistant row and that was recorded as "muteness
  reproduced". It was not: a **fresh session on the same binary and DB also
  produced nothing**, so the null was the harness, not the bug. The control is
  what converted a null result into a real one. Run it BEFORE trusting any
  negative.
- **`PATCH /api/session/{id}` returns 200 `text/html`** from the static asset
  handler (the real route is `PATCH /session/{id}`, un-prefixed). Three "200 OK"
  responses changed nothing, and the SSE assertion that depended on them came
  back empty on both the scoped AND unscoped streams — which first looked like
  the `session_ids` filter was broken. It is not. Bead `workstation-s4lz`.

### Method notes worth keeping

- **`VACUUM INTO`, not the backup API, for the snapshot.** The sqlite backup API
  restarts when the source is written, and this DB has ~15 concurrent writers, so
  a naive `.backup` can spin indefinitely. `VACUUM INTO` takes a read-transaction
  snapshot immune to concurrent writes: 7.43 GB in 52 s, `integrity_check ok`.
- **Isolation needs FOUR env vars, not one:** `OPENCODE_DB` (the DB),
  `XDG_DATA_HOME` (logs/snapshots), `XDG_CONFIG_HOME` (config+plugins), and
  `OPENCODE_SESSION_STATE_DIR` (`session-state.js` hardcodes
  `~/.local/share/opencode/session-state.d` off `homedir()`, ignoring XDG).
  Plus scrubbing `OPENCODE_SERVE_ID`/`OPENCODE_ROUTING_DB`.
- **The scratch config must be at `$XDG_CONFIG_HOME/opencode/opencode.json`**,
  not `$XDG_CONFIG_HOME/opencode.json`. Written to the wrong path it is silently
  ignored — which meant the deny-all tool permissions were NOT in effect for the
  first runs. Confirm by the `message=loading path=...` lines in the serve log.
- **The resumed agent does try to execute the backlog.** On the mute session the
  model ignored "do not act on prior instructions", called tools, and blocked on
  an `external_directory` permission **ask** for a real project path (headless =
  blocks forever). Deny-all containment is not optional, and the deny list must
  include `external_directory` and the read tools, not just bash/edit/write.
- `auth.json`/`account.json` live under `XDG_DATA_HOME`, so an isolated data dir
  has NO credentials unless copied. The `github-copilot` entry was stripped from
  the copy: it is an oauth entry with a refresh token, and a refresh in the
  throwaway would invalidate the live credential.
- Vertex ADC resolves via `HOME`, not `XDG_CONFIG_HOME`, so it survives isolation.

### What W2 does NOT cover

The W1 blind spots it was meant to cover, it covers only partly. Exercised for
real: the prompt/turn loop, provider auth, `session_ids` SSE filtering, the
plugin surface incl. pigeon registration, tool-permission evaluation, snapshot
tracking. **Still unexercised:** PTY, the TUI itself (W3's darwin check is the
first real exercise), Vertex REP endpoints, and the SessionV2 durable-replay
cluster beyond the queueing path incidentally touched here.

One observation deliberately not chased: a `stream error ... Thinking level is
unsupported: THINKING_LEVEL_MINIMAL` for the small `agent=title` model on
`google-vertex/gemini-3.7-flash`. It did not affect any main turn. Not a
roll-forward regression; noted only so the next person does not re-debug it.

## W3 RESULTS (2026-08-14, bead workstation-uslc) — GATE PASSED, release PR #43

### Headline

The tree `apply.sh` builds is **byte-identical to the tree W2's validated binary
came from**, including file modes. W2's green therefore transfers to the release.
Stack goes 28 -> 26 patches. PR: opencode-patched #43, branch `w3-release-1818`.

### The equivalence gate, proven twice by independent methods

W2 validated a binary built by a *manual* fail-fast apply. W3 cuts through
`apply.sh`. `git apply` is atomic per patch, so a stale patch contributes **zero
hunks silently** while the build still succeeds — the green transfers only
through equivalence. Reference tree: `/tmp/w1r-stack-12410-IAHWcb` (survives;
expires ~2026-08-24), both trees at upstream HEAD `31406ccc51`.

| Method | Result |
|---|---|
| sha256 manifest, 6534 files | 0 content differences, 0 files only in the release tree |
| `git diff HEAD --binary` diff-of-diffs | identical apart from index-line hash width; **covers modes/exec bits**, which the sha walk does not; untracked source lists identical |

The 20 files present only in the validated tree are install/build/run artifacts:
17 `.husky/_/` hooks (prepare-hook output), gitignored `.opencode/package*.json`
(runtime plugin bootstrap, never read by `script/build.ts`), and a
`tsbuildinfo`. Review confirmed `bun.lock` is sha-identical in both trees and no
patch changes a dependency, so skipping it hid nothing.

**The control that makes the null result mean something.** Rebuilding with
`vim.patch` omitted yields exactly 3 content diffs + 8 missing files, which
decomposes correctly against that patch's 11 touched files (3 modified, 8
created). Without this, "0 differences" would have been indistinguishable from a
broken comparison — the exact failure that produced two false greens in W2.

### Bookkeeping decisions

- **Tombstones, not renumbering.** Drops keep their number (the convention
  already in use at #15, a `tui-follow-owner` tombstone). So header numbers are a
  stable identity that does NOT track apply order — now stated explicitly at the
  top of `apply.sh` instead of left to be inferred.
- `globalbus-maxlisteners` had been applied since the v1.17 line with **no header
  entry at all** (workstation-dqng); it takes 29. PR #42 also claims 29 and must
  renumber to 30.
- **26, not 27.** PR #42 (`db-isolation-guard`) is held out deliberately so the
  equivalence check stays a literal equality. It lands in a follow-up build.
- **bun pinned 1.3.14**, was `latest`. Upstream v1.18.18 declares exactly that in
  `packageManager`, so this aligns CI with upstream rather than diverging.

### What the adversarial review caught that the gate did not

1. **Clone-by-tag was a silent wrong-artifact hole.** CI clones `--branch
   v<version>` at dispatch time, and this upstream *rewrites history*. Every gate
   was measured against `31406ccc51`; a moved tag would have built different
   sources with nothing noticing. Fixed with a new optional `expected_sha` input
   that fails loudly. **The dry run and the real run are separate clones — the
   assertion must be read in both.**
2. **The release could cut itself.** `sync-upstream` cron dispatches a REAL
   publish from main 3x/day; open issue #41 is the only circuit breaker. Closing
   it "to tidy up" hands the cut to an unattended cron. Order is fixed in the
   `workstation-uslc` bead: merge -> dry run -> manual dispatch -> *then* close #41.
3. **Release notes advertised a patch this PR deletes** ("six patches", retry cap
   MAX_RETRIES=8; upstream caps at 5). Now points at `apply.sh` as authoritative
   rather than re-rotting a hand-written list.

### Release cut: DONE

`v1.18.18-patched` is published (run 31850297000 from main, PR #43 merged as
4d374af). The upstream-sha assertion was read as OUTPUT in **both** the dry run
and the real run — they are separate clones, so one reading does not cover the
other. 26/26 patches applied in each. Darwin arm64 is ad-hoc codesigned
(`Signature=adhoc`), launches, prints 1.18.18, no SIGKILL. Issue #41 was closed
**after** the manual dispatch, so the `sync-upstream` cron never got the chance
to publish unattended. darwin-x64's smoke skipped ("Rosetta unavailable") — that
platform ships unexercised, accepted.

### What W3 does NOT cover

Source equivalence is not binary equivalence: CI cross-compiles arm64 on an x64
runner with a real version stamp. `workstation-efkq` re-runs W2's killer test on
the **published** asset before the pool is committed. Darwin/TUI remains genuinely untested at runtime
(`workstation-5cot`), but that is now **deferred by decision and no longer
blocks W4**: the cloudbox pool is headless, so no serve constructs a TUI and
none of the opentui 0.4.5 renderer, tree-sitter worker, or vim re-cut is on the
cutover's path. The risk lands on the next *Mac rebuild* instead, after W4 moves
`opencodePatchedHold` to 1.18.18. Only `workstation-efkq` blocks W4.

## EFKQ RESULTS (2026-08-14, bead workstation-efkq) — GATE PASSED

### Headline

**The published artifact — not a hand-built tree — un-mutes real production
sessions**, and the deployed v1.17.13 binary reproduces muteness on the *same
session, same DB copy, same endpoint* minutes earlier. Confirmed twice over:
statically in the shipped binary, and at runtime.

### The claim, narrowed (the first draft over-claimed)

The published **linux-arm64** binary (asset digest
`sha256:39fed79a…`, `updatedAt` == publish time, so never re-uploaded) un-mutes
**2 of the 3** mute sessions. darwin and x64 assets from the same release are
untested. **"Un-mutes" means new prompts get answered — user messages stranded
during the mute window are NOT retroactively processed** and must be re-sent.

### Static evidence, at the identical code site in each binary

| Binary | Loop-exit guard |
|---|---|
| deployed 1.17.13 | `!so && J.id < j.id` — the raw-ID compare, **the bug** |
| published 1.18.18 | `!ie && A.parentID === J.id` — **the fix** |

### Runtime evidence (one 7.43 GB `VACUUM INTO` copy throughout)

| Arm | Binary | Result |
|---|---|---|
| Control, fresh session | published | assistant row, `parentID` == user msg, `finish=stop`, text `PONG` — proves the harness runs turns |
| Killer test, `ses_00a083d40ffe` | published | 2 new rows; assistant `parentID` == the NEW user row; `finish=stop`, text `PONG`, **zero tool calls**; `step=0 -> step=1` |
| Differential arm 1, `ses_01680e0d` | **deployed 1.17.13** | 1 new row (user), **ZERO assistant**; `step=0 -> exiting loop` in **9 ms**, no stream lines |
| Differential arm 2, same session | published | 2 new rows; assistant parented to **arm 2's own** user row, not arm 1's orphan; `step=0 -> step=1`, ~10 s, real `stream providerID=…` line |

The wrap premise was verified **still active** at test time (`max(id)` in that
session is `msg_ffb6cbf5a…`, far above any new `msg_002b…`), so the negative arm
is not vacuously passing.

**The arm-2 refusal is signal, not noise.** Opus declined the "ignore all prior
instructions" framing instead of saying `PONG`. A refusal *requires* an LLM call,
and the failure mode under test is the **absence** of any call. Nothing produces
model-generated refusal text while masking the wrap bug.

### Isolation held, and live was re-measured afterward

Explicit `OPENCODE_DB` per boot + `XDG_DATA_HOME`/`XDG_CONFIG_HOME`/
`OPENCODE_SESSION_STATE_DIR` + `env -u OPENCODE_SERVE_ID -u OPENCODE_ROUTING_DB`.
The fd gate ran before **every** request and showed only the copy's handles. Live
verified read-only afterward, twice independently: both sessions unchanged at
198 / 1339 rows, all 5 test message ids absent, control session absent. **No
repeat of the W2 incident.**

### Bonus, and it de-risks W4's rollback

v1.18.18 adds **zero** migrations (`__drizzle_migrations`=21, `migration`=38 in
both live and a 1.18.18-touched copy), and arm 1 **dynamically demonstrated**
1.17.13 running against a DB already written by 1.18.18 turns. Rollback is real,
not theoretical. Keep store path
`/nix/store/9qk1nd4k3jmpjqw17pw1yyi120nwxjq7-opencode-patched-1.17.13.9`.

### Static-verification recipe for the NEXT roll-forward (three traps, all hit)

Grepping a bun-compiled binary works, but only if you grep the right thing:

1. **Local variable names are minified** (`lastAssistant` -> `J`/`A`/`j`).
   Grepping source text like `lastUser.id < lastAssistant.id` returns 0 in
   **both** binaries and is **vacuous**. I nearly banked that meaningless 0/0.
2. **Property names and log strings survive.** Anchor on a nearby literal
   (`loop exit with orphaned interrupted tool`) and match on properties
   (`\.parentID===\w{1,4}\.id`).
3. **The nix-installed `bin/opencode` is a 647-byte wrapper script.** Grep
   `bin/.opencode-wrapped` or every count is 0 and looks like real absence.
   This trap caught both me and the reviewer.
4. **A decisive-looking differential can be coincidence.** `isAfter` appeared 8x
   in the new binary and 0x in the old — all 8 were `isAfterExtendsOrImplements`,
   a syntax-highlighter field. Extract match **context** before believing a count.

### What EFKQ does NOT cover — W4 is the first exercise of these

The test ran with `plugin:[]`, `mcp:{}`, copilot stripped, no `OPENCODE_SERVE_ID`,
vertex via plain ADC, and no TUI. **Production runs all of**: the npm
`opencode-anthropic-auth` plugin (loaded at *runtime*, so W1's typecheck covers
none of it), aigateway routing, serve-ID provenance stamping, the front-door
registry patches, TUI attach, systemd memory caps, ~15 concurrent writers.
"W4 may proceed" is **not** "W4 is de-risked" — see the conditions on
`workstation-pel5`.

## ROADMAP AND BEAD INDEX (read this first after a compaction)

Execution chain: W1 -> W2 -> W3 -> W4 -> er3t closes.
Each W bead carries a SELF-CONTAINED note with its own traps; read the bead, not
just this table. `bd show <id>`.

| Bead | Pri | Step | Blocked by |
|---|---|---|---|
| workstation-l60f | P1 | W1 stacked-build gate | **DONE — 0 regressions, see W1 RESULTS above** |
| workstation-7duy | P1 | W2 DB-copy validation | **DONE — fix proven end-to-end, see W2 RESULTS above** |
| workstation-uslc | P1 | W3 cut opencode-patched v1.18.18 release | **DONE — v1.18.18-patched PUBLISHED, see W3 RESULTS** |
| workstation-efkq | P1 | Re-run W2's killer test on the PUBLISHED binary | **DONE — PASSED, see EFKQ RESULTS below** |
| workstation-5cot | P1 | Manual TUI acceptance on the published darwin-arm64 zip | **DEFERRED by decision — no longer blocks W4; do before the next Mac rebuild** |
| workstation-pel5 | P1 | W4 cloudbox cutover per the 2026-06-11 runbook | **READY — nothing blocks it. Run from a BARE SSH SHELL.** |
| workstation-er3t | P0 | the incident itself; closes when the 3 mute sessions answer | W4 |

Follow-ups (NOT blocking the cutover, do not do them during the bump):

| Bead | Pri | What |
|---|---|---|
| workstation-266p | P2 | **40 tests are RED AT BASELINE (19 opencode + 21 core), so W1's "0 regressions" is blind over Server.listen, PTY, llm.stream payloads, Vertex REP, event scoping, CLI help, SessionV2 replay.** Umbrella for triaging them; blocked by vmm7. Do AFTER W4. |
| workstation-vmm7 | P2 | Add a typecheck step to opencode-patched build-release.yml. CI has NEVER typechecked; that is why a type-broken patch shipped since 1.17. Do AFTER W3. |
| workstation-dxuu | P2 | No host-level detector for "session accepts a prompt but never replies". Every existing net missed the incident BY CONSTRUCTION. Alert-only. |
| workstation-zvki | P3 | Verify whether GET /api/session/:id/history is wired -- the unproven premise of event-log-gate. Not a roll-forward regression. |
| workstation-6e3d | P3 | Two raw-ID-ordering consumers SURVIVE at v1.18.18: tui/routes/session/index.tsx:211 (children sort) and :659 (redo). Not mute-class. |
| workstation-2fxs | P3 | id.ts is unchanged upstream -> the 48-bit wrap RECURS ~Oct 2028. Long fuse; nobody will remember. |
| workstation-vcnz | P3 | Fold attach-route-resolve into tui-door-attach (route.ts has zero production consumers); must also edit build-release.yml Phase-8. |
| workstation-dqng | P3 | apply.sh is missing header entry #15 for globalbus-maxlisteners (bead workstation-qjk4). |
| workstation-dkcs | P1 | **OPENCODE_DB silently defeats XDG_DATA_HOME isolation — a throwaway serve writes to the PRODUCTION db. Hit for real in W2. Fix in flight in worktree `opencode-db-guard`. The 2026-06-11 runbook's isolation method is WRONG and is being followed.** |
| workstation-s4lz | P3 | `PATCH /api/session/{id}` returns 200 text/html from the static handler instead of 404/405, silently swallowing API calls. Not a bump regression. |
| pigeon-0k8m | P2 | (pigeon repo) post-ack verification tripwire; reason the incident was SILENT, not its cause. |

### Facts that must not be re-derived (all verified by content, not inference)

- Wrap boundary: 1786706395136 ms = 2026-08-14 07:19:55 EDT. Period 2^36 ms = 795.36 days.
- Fix commit: db581e47a3 (#40990). PRESENT AT v1.18.18 BY CONTENT: `isAfter` exists,
  `latest()` uses it, prompt.ts:1115 is `lastAssistant.parentID === lastUser.id`,
  and ZERO occurrences of `lastUser.id < lastAssistant.id`.
- `git tag --contains` IS UNRELIABLE on this repo (history rewritten; v1.17.9 and
  v1.17.13 mutually diverge 14188/428 commits). Verify by content at the tag.
- DB migrations between v1.17.13 and v1.18.18 are EMPTY (migration dir +
  packages/schema zero diff; 0 new sqlite migrations in 713 commits).
- The 3 mute sessions / regression fixtures: ses_00a083d40ffeDV54M31SzaOETO,
  ses_01680e0d8ffegZb7b2WNsZTHAU, ses_02db91d4affeb6bkqSgQixN4zN.
- Discriminator query for muteness is in the workstation-er3t bead description.
- Upstream retry cap is 5 (stricter than our 8, which was a cap where upstream
  had none). ACCEPTED -- do not re-litigate.
- v1.18.18 is the right target, NOT the minimum v1.18.15: retry-cap only becomes
  droppable at v1.18.17, so minimum-version means MORE patches.
- opencode's real log is ~/.local/share/opencode/log/opencode.log, NOT journald.
  pigeon-daemon uses LogNamespace=pigeon, so `journalctl --namespace=pigeon -u pigeon-daemon`.

### Working conventions for the execution phase

- Work in a worktree, never at the primary root. This branch: `idwrap-roadmap`.
- Give every scratch worktree a $RANDOM/mktemp-suffixed path; parallel agents
  previously collided on shared /tmp paths and one applied patches into another's tree.
- These repos are shared with live sessions: no reset/stash/clean/checkout/rebase
  at any primary root.

### The gate had to be run TWICE: `git checkout` silently un-applied two patches

Adversarial review (`adversarial-reviewer-fable`) found that the first pass was
measured on a tree that was **no longer the 26-patch stack**.

`session-door-routes` and `session-mcp-routes` both patch
`packages/sdk/js/src/v2/gen/{sdk.gen.ts,types.gen.ts}`. The SDK-regen gate
overwrote those files, and the cleanup — `git checkout -- packages/sdk/js/src/v2/gen`
— restored them to **HEAD, i.e. pristine v1.18.18**, silently discarding the two
patches' hunks along with the regen output. Everything measured after that point
(the built binary, both full-suite runs) came from an effectively 24-patch tree
whose bundled TUI was missing the client half of both patches.

Verified after the fact: `grep -c SessionMcpConnect .../types.gen.ts` returned
**0** in that tree.

This is the same failure class this repo already warns about for shared
worktrees — a destructive git op removing more than intended — and it landed
anyway, because "throwaway worktree, safe from other sessions" was confused with
"safe for my own result". Isolation protects your PEERS; it does nothing for
CORRECTNESS.

**The whole gate was re-run from scratch** in two fresh trees with no regen ever
executed inside them (`/tmp/w1r-stack-*`, `/tmp/w1r-base-*`), gen hunks verified
present on both sides before and after. Every number in the table above is from
that clean re-run. The SDK-regen check now belongs in a disposable copy, never
in the tree under test.

Consequences for later steps:
- **W2 must build its own binary or use `/tmp/w1r-stack-*/packages/opencode/dist/opencode-linux-arm64/bin/opencode`** (built 19:40, from the correct 26-patch tree). The earlier `/tmp/w1-stack2-*` binary is contaminated — do not use it.
- Any `/tmp/w1-*` (single-r) tree may carry uncommitted regen output. Prefer the `/tmp/w1r-*` trees.

### W1 artifact inventory (EXPIRES ~2026-08-24)

Everything W1 built lives in `/tmp`, which systemd-tmpfiles cleans on a **10-day
age rule** with a daily timer. After that date these are gone and W2/W3 must
rebuild from the git branch.

| Artifact | Path |
|---|---|
| **W1 binary** (use this one) | `/tmp/w1r-stack-12410-IAHWcb/packages/opencode/dist/opencode-linux-arm64/bin/opencode` — `0.0.0--202608141940` |
| stacked tree (v1.18.18 + 26) | `/tmp/w1r-stack-12410-IAHWcb` |
| baseline tree (v1.17.13 + 28) | `/tmp/w1r-base-589-s8dLH7` |
| bun 1.3.14 (nix bun 1.3.3 cannot build) | `/tmp/bun-dl/bun-linux-aarch64/bun` |
| re-cut patches | `/tmp/w1-patches` — also, durably, on branch `w1-1818-recuts` |

**Do not use any `/tmp/w1-stack2-*` binary** — that is the contaminated
24-patch build. The single-`r` `/tmp/w1-*` trees may also carry uncommitted
regen output; prefer `/tmp/w1r-*`.

The only durable artifact is the git branch. If `/tmp` has been swept: fresh
worktree at v1.18.18, apply the 26 patches from `w1-1818-recuts`, then
`bun run script/build.ts --single` with bun >= 1.3.14.

### Note for W2: the DB is now 7.4 GB

`~/.local/share/opencode/opencode.db` measured **7.4 GB** on 2026-08-14 — up
from the 4.3 GB figure quoted in `event-log-gate`'s own DB-bloat rationale.
Budget the space and the time for the online `.backup`. It is also a data point
for `workstation-zvki` (whether the gate is doing what it claims); do NOT act on
it during the bump.

### New beads from W1

| Bead | Pri | What |
|---|---|---|
| workstation-64da | P2 | `?session_ids=` 400s in the TEST HARNESS only; the real binary returns 200. 4 permanently-red tests, feature actually works. |
| workstation-n2o8 | P2 | Patched SDK gen is incomplete (+533 on regen): our own SessionMcp*/SessionQuestion*/session_ids routes are unreachable via the generated client. |
| workstation-2srm | P3 | nix bun 1.3.3 < required ^1.3.14; build refuses, and tests silently run on the wrong bun. |
| workstation-ibw0 | P3 | lease-deadline test is load/order-flaky in the full suite. |

### W2 addendum: adversarial review findings (adversarial-reviewer-fable)

The review confirmed the differential is sound at source level — both broken
paths are present at baseline (`prompt.ts:1148` raw-ID exit AND `message-v2.ts`
`latest()` picking `lastUser` by max ID) and both are gone in the tested tree —
and confirmed that running the two arms **sequentially on one copy is not a
confound but an improvement**: arm 1 leaves an orphan user row, which makes arm
2's input state *more* production-like (live mute sessions hold 18 such rows),
and Assert A pins `parentID` to arm 2's own new user message, so arm 2 cannot
have been answering arm 1's leftover.

Acted on during W2:

- **All 3 mute sessions tested**, not 1. All answer cleanly.
- **Daemon->opencode direction smoke-tested** (the stub only covered
  opencode->daemon). This mattered because the bump demonstrably moved route
  behavior. All endpoints pigeon's `opencode-client.ts` calls behave correctly,
  including 404 for a nonexistent session — a wrong answer there cascades into
  reaper/routing unregistration.
- **`event_sequence` correction.** The cleanup write-up said live was restored
  identical. That is not literally true: `SessionInput.admit` dies unless a
  durable event commits, and `event_sequence` is maintained unconditionally even
  though `event-log-gate` skips the `event` row. Live's counter for
  `ses_00a083d40ffe` sits at **2709 where pristine was 2707**. Deliberately NOT
  reset: a monotonic counter running ahead is benign (it only means the next
  event takes 2710), whereas resetting it risks reissuing a used sequence.
  Verified no rows remain at 2707-2709 and the `event` table is empty. The
  accurate claim is "row counts and every field of the session row match the
  pre-test snapshot", not "byte-identical".
- **Live `session_input` sweep** (a stranded queued row fires on the first turn
  that runs post-cutover): **8 stranded rows exist, all ~2026-07-27, on 8
  unrelated sessions, and ZERO on the 3 mute sessions.** Pre-existing, not from
  this work. W4 should decide whether to clear them.
- Pigeon routing tables checked for residue pointing at the throwaway
  endpoint/pid: none (apparent hits were substring matches inside hex ids and
  message text). The serve pool is a fixed seeded list, so a throwaway port
  cannot join it.
- Live `github-copilot` oauth intact; it was stripped from the scratch
  `auth.json` before any boot, so no refresh could have rotated it.

### What must still gate W3

0. **26 PATCHES OR 27?** opencode-patched PR #42 (`db-isolation-guard`, the fix
   for the footgun W2 hit) adds a 27th patch and its own `apply.sh` bookkeeping,
   branched off `main` — while `w1-1818-recuts` also edits `patches/`. Two
   divergent `apply.sh` edits must be reconciled by hand. Shipping 26 keeps the
   released tree equal to the tree W2 actually proved; shipping 27 puts an
   unexercised patch in the cutover artifact and weakens gate 1 below.
   **DECIDED 2026-08-14 (Jonathan): ship 26.** Hold PR #42 for a follow-up
   build so the equivalence check below stays a literal equality. Also decided:
   **pin CI's bun to 1.3.14** (the version W1 validated) rather than `latest`.
   Note the branches do not actually conflict today — `w1-1818-recuts` never
   touches `apply.sh`, so this is only a choice of base, not a merge.

1. **ARTIFACT EQUIVALENCE — the only finding that can invalidate W2's GREEN.**
   W2 validated the binary W1 built by a manual fail-fast apply of
   `w1-1818-recuts`. W3 cuts the release through `apply.sh`, whose bookkeeping
   was deliberately deferred and is known stale (2 deletions pending, missing
   header #15, `build-release.yml` Phase-8 coupling). `git apply` is atomic per
   patch, so a stale patch contributes **nothing** silently. W3 must diff the
   release-built tree against `w1-1818-recuts` (or hash-compare applied sources)
   before W4. The GREEN transfers only through that equivalence.
2. **First-contact plan for the 3 mute sessions (W4).** Un-muting is not the end
   of the incident, it is the start of backlog execution. W2 observed this
   directly: the resumed model ignored "do not act on prior instructions",
   called tools, and blocked on an `external_directory` permission ask. Post
   cutover there is no deny-all: the first prompt to each session shows the model
   6+ stale human messages which it may act on with full permissions, or hang
   headless on an ask. Plan per-session first contact deliberately.
