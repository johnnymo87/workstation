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
