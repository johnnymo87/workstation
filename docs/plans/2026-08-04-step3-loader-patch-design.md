# Step 3 (D) — patch the plugin loader: design

**Bead:** `workstation-5yox` step 3 · **Date:** 2026-08-04 · **Status:** revision 2, design reviewed

> **Revision 2, after adversarial design review.** Three findings landed, two of
> them on decisions I had rationalized rather than reasoned. The step is now
> **split into 3a and 3b** (see "Sequencing"), the compound-version pin is
> **withdrawn** because it would have broken the 8-hourly auto-merge pipeline on
> every loader-unrelated fork release, and a **fifth silent stage
> (`report.missing`) was found completely unenumerated** — G4's exact signature
> surviving inside the patch that claims to close G4. Details inline; the
> original text is kept where it survived review so the corrections are legible
> rather than quietly absorbed.

The class-killer. Steps 0-2 prevent at build time and detect in production; this
is the only step that makes the *loader itself* safe, and therefore the only one
that covers plugins we neither author nor lint (`superpowers.js`,
`opencode-pigeon.ts` — `mkOutOfStoreSymlink`s into other repos' live checkouts,
mutating on a `git pull` nobody here reviews).

Everything below was re-verified at source today against the vendored fixture
`assets/opencode/plugins/test/fixtures/plugin-index.ts` (upstream v1.17.13), not
recalled from the roadmap.

---

## Three defects, all confirmed at source

| # | Site | Defect |
|---|---|---|
| **A** | `plugin-index.ts:114` (v1) and `:119` (legacy) | `hooks.push(await server(...))` with **no validation**. A factory returning `undefined` poisons `hooks[]`; consumption at `:246` does `(hook as any).config?.(cfg)` → TypeError → `/config/providers` 500s, no prompt runs. **The LOUD devbox outage.** |
| **B** | `report.start(candidate) {}` at `:187` | No-op. The loader logs **nothing on success**, so no detector can assert "plugin X loaded". |
| **C** | `report.error(...)` at `:189` | Calls only `publishPluginError` → `bridge.fork(events.publish(...))`, an **event with no `logError`**. Measured: an import-time throw produces zero log line, zero stderr, nothing in journald. Serve answers 200 throughout. **This is G4, the blind cell.** |
| **D** | `report.missing(...)` at `:188` | **Found in review; I had not enumerated it.** A bare `{}` no-op — it does not even call `publishPluginError`, so it carries *strictly less* signal than C. Fires from `loader.ts:174` when a resolved target exposes no entrypoint for the requested kind (`loader.ts:110-120`, `Plugin ... does not expose a server entrypoint`). Zero log, zero event, zero stderr. A patch that closed C and left D open would have shipped G4's exact signature inside the fix for G4. |

The one line that *does* exist is `:227`,
`Effect.logError("failed to load plugin", { path: load.spec, error })` — and the
production canary greps exactly it.

---

## The changes

### 1. Validate before push — buffer-then-commit

```ts
function assertHooks(value: unknown): Hooks {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new TypeError(
      `Plugin factory must return a hooks object, received ${
        value === null ? "null" : Array.isArray(value) ? "array" : typeof value
      }`,
    )
  }
  return value as Hooks
}
```

Applied at **both** sites. `{}` stays legal — `session-state.ts:43` legitimately
returns it. Arrays and functions are rejected (`typeof [] === "object"`, so
`Array.isArray` is load-bearing; `typeof null === "object"`, so the truthiness
check is too).

**Buffer-then-commit.** `applyPlugin` stages into a local array and splices into
`hooks[]` only after every server in the file has validated:

```ts
const staged: Hooks[] = []
// ...fill staged...
hooks.push(...staged)
```

The reason is not hypothetical purity. Step 3's whole point is to make "this file
failed" a *trustworthy per-file signal* — the thing latch auto-clear will later
key on. A file that is half-registered but reported failed poisons that semantic
at the source.

Worth stating precisely, because my first framing of this was wrong: **partial
application already exists today.** The legacy loop at `:118-119` pushes per
iteration, so if server #2's factory *throws at runtime*, server #1 is already in
`hooks[]` while `:227` logs the file as failed. Validation adds a new *path* into
an existing state, not a new state. Buffering fixes both.

**What buffering does not fix, and the PR must not claim it does:** a staged
server that already resolved may have run side effects — registered a workspace
adapter via `input.experimental_workspace.register`, spawned something, mutated
module state. Commit-atomicity covers `hooks[]` only. It cannot unwind those.

### 2. Log per-plugin failure in `report.error` **and `report.missing`** — closes G4

One `logError` covering **all four `report.error` stages** (`install`,
`compatibility`, `entry`, `load`) **plus a fifth in `report.missing`** — added
*alongside* `publishPluginError`, not replacing it:

```ts
bridge.fork(Effect.logError("failed to load plugin", { path: spec, stage, error: message }))
```

`bridge.fork` is the idiom already used two lines away by `publishPluginError`
(`:135-137`) — `report.error` is a plain callback, not an Effect context, so
`Effect.logError` cannot simply be yielded there.

**It deliberately reuses the exact existing message string and `path=` field.**
That is what makes the existing production canary detect import-time throws with
**zero canary changes** — the anchored pattern
`^timestamp=\S+ level=ERROR .*failed to load plugin` matches, and
`plugin_canary_plugin_key` extracts from `path=file:///...` exactly as it does
today. The new `stage=` field appends; the pattern is a prefix match and is
unaffected.

`report.missing` gets the same treatment with `stage: "missing"`. Because it
reuses the same message string, the deployed canary detects the
no-entrypoint shape for free as well.

No double-logging — but **the mechanism I first gave for this was wrong**, and
the correction matters more than the conclusion. I claimed `loadExternal`
returns `undefined` for a failed candidate which the loop then skips at `:216`.
It does not: `loader.ts:232-234` **filters** them out before returning
(`for (const item of out) if (item.value !== undefined) ready.push(item.value)`),
so no `undefined` ever reaches `:216` and that guard is dead for this shape. The
conclusion (no double-log) survives; the reasoning did not.

That error is diagnostic, not incidental: I "re-verified at source" against
fixtures that **do not include `loader.ts`**, the very file defining the
`Report` callback contract, the stage names, the retry behaviour, and what
`candidate.plan.spec` holds. Change 2 lives entirely inside that contract. So:

**`loader.ts` joins the vendored fixtures and the refresh recipe.** Without it,
upstream can rename a stage, change retry semantics, or normalise specs, and
every in-repo copy of loader semantics stays green while the patched line's
content drifts.

One consequence to encode in tests: `attempt()` fires `report.error` **twice**
for a retryable file-plugin failure (`loader.ts:212-228`, the retry-after-wait
path). Two ERROR lines, one latch — harmless in production because the latch is
idempotent, but fatal to any test asserting exactly one line per failure.

### 3. Log per-plugin success

```ts
Effect.tap(() => Effect.logInfo("plugin loaded", { path: load.spec }))
```

on the existing pipe in the load loop, before the existing `tapError`.

**INFO, not DEBUG — verified empirically, not assumed.** 20MB of production log
contains 84,020 `level=INFO`, 2,220 `WARN`, 76 `ERROR`, and **zero `DEBUG`**. A
DEBUG success line would not be emitted at the default level at all, which would
make the entire per-file-presence idea dead on arrival.

**Volume is a rounding error.** ~4,200 INFO lines/MB measured; nine lines per
(process, directory) init is well under a MB/day against a 645MB file. The
unrotated log is a real problem but it is `workstation-j95n`'s problem — do not
warp this design around its absence.

`"plugin loaded"` cannot false-match the canary: it does not contain the
substring `failed to load plugin`, *and* the pattern additionally requires
`level=ERROR`. Two independent reasons.

---

## Pin machinery: couple the fork revision

The guard's five constants all answer one question — *which loader semantics are
we assuming?* Today the answer is "upstream 1.17.13". After this step it is
"upstream 1.17.13 **plus our patch**", and the vendored fixtures no longer
describe the loader that actually runs. The canary's pattern test would then be
asserting against a file that is not what production emits: the pin rotting in a
new costume, exactly as the roadmap predicts at `:379-392`.

### ~~Compound version~~ — WITHDRAWN, it breaks auto-merge

My first design made all five constants a compound
`"${upstreamVersion}.${patchedRevision}"` → `1.17.13.8`, on the reasoning that
the constants answer "which loader semantics do we assume?" and the answer now
includes our patch. That prose is elegant and the operational consequence is
disqualifying.

`patchedRevision` bumps on **any** fork release. The fork carries 26 patches, ~25
of them nothing to do with the loader; a TUI fix or a lease tweak bumps it.
`update-opencode-patched.yml` bumps that constant by `sed` and **auto-merges**
the resulting PR, while `ci.yml` runs `nix flake check` → `test-loader-pin.sh`.
So the very next unrelated fork release turns the guard red on an auto-merged PR
and demands a human bump five constants and re-vendor fixtures **when the loader
did not change**.

Two outcomes, both bad: the auto-update pipeline stays broken, or humans learn to
bump the pin ritually to make it quiet — which is precisely the move
`test-loader-pin.sh:176` forbids in its own failure text ("Do NOT move it to
make this quiet"), promoted to standard procedure. A guard that cries wolf on
every release is pin-rot wearing a fresh costume.

### What replaces it: pin the loader's *identity*, not the fork's revision

The five existing constants **stay at `1.17.13`** and keep meaning "which
*upstream* loader". Auto-merge keeps working. Our patch is pinned separately, by
content:

- **`fixtures/plugin-index.ts` becomes upstream + our loader patch**, so the
  existing pattern-vs-fixture assertion checks the line production actually
  emits rather than one upstream stopped emitting.
- **`fixtures/loader.ts`** is vendored (per H2 above).
- **The spec-normalisation behaviour of `config/plugin.ts` is pinned too.**
  Found by the *implementation* review, and it is a hole in this design rather
  than in the code: the canary's key extraction
  (`opencode-plugin-canary.sh:97,100`) requires a literal `path=file://`, and
  without it every failure collapses to one shared `unknown` latch — per-file
  signal silently gone. That `file://` shape is produced by `resolvePluginSpec`
  at `config/plugin.ts:42-54` (`pathToFileURL(path.resolve(base, spec)).href`),
  which is in **neither** vendored file. This design named "normalise specs" as a
  drift vector and then pinned the two files that cannot see it. Upstream changes
  normalisation → the patch applies clean, the fork tests pass, the pin guard
  stays green, and the canary's keys collapse.
- **The loader patch itself is vendored** into `fixtures/`, with its `sha256`
  recorded as a new constant. The guard asserts the recorded hash matches the
  vendored file — offline, deterministic, and red only when the *loader patch*
  changes.
- **Cross-repo drift** — the fork edits its loader patch and workstation's copy
  goes stale — is closed where the network already is: `update-opencode-patched.yml`
  fetches the fork's loader patch at the release tag and fails the auto-PR when
  it diverges from the vendored copy. That fires exactly when meaning drifts and
  stays silent when it doesn't.
- The `refresh_recipe()` gains the patch-apply step, so it stops handing the next
  person sources that omit our own patch.

**Rehearsal is a required exit criterion, not a nicety.** Bump `patchedRevision`
locally with the loader patch untouched, run `test-loader-pin.sh`, and confirm it
stays **green**. One rehearsal of exactly that would have caught the compound
design before it shipped; its absence is why the flaw survived into a written
design.

### Revision 3 — what the implementation review changed

Four corrections, all from the `adversarial-reviewer-fable` pass on this section
before any code was written.

**The renderer was the unpinned drift vector.** Everything the canary parses is
produced by `packages/core/src/observability/logging.ts`, not by the loader:
field order (`timestamp` first, `level` second) feeding the anchored pattern; the
quoting rule at `:46` (`/^[^\s="\\]+$/ ? value : JSON.stringify`) which is the
*only* reason `path=file://...` renders unquoted and the key extraction matches
at all; flat annotations; and the `opencode.log` filename. None of the files this
design named could see any of it, and the guard's failure text sent the reader to
the `logError` **call site** — a ritual a reader can complete faithfully while a
renderer change walks straight through. Same shape as the spec-normalisation hole
this design already had, one layer down. `logging.ts` is now vendored and the
canary's failure text carries a four-point renderer checklist.

Be precise about what that buys, though, because the earlier draft of this
section overstated it: `logging.ts` and `config-plugin.ts` are pinned by
*existence and refresh ritual*, not mechanically. The guard proves nothing about
their contents — it cannot, offline, without replicating the renderer. They are
escorts that put the right file in front of the next reader at the moment of a
bump. The mechanically-enforced claims are only these: the patch's identity, that
the patched fixture really is pristine + patch, that the canary's literal appears
in the helper that emits it, that every emission site carries `path`, and that
the five stages' call sites still exist.

**The `sha256` marker alone pins bytes, not meaning** — it is regenerable in one
command, so on its own it is an escort, not a ratchet. The guard now also greps
the canary's *literal* message pattern against the composed loader, and requires
**every** `failed to load plugin` site to carry the `path` annotation. That
per-site form is deliberate: checking `path:` appears merely *somewhere* is
satisfied by upstream's own apply-stage call, so it could not see our patch
dropping `path` from the five load-stage sites that are the entire point. It is
the one assertion a dutifully-regenerated `sha256` marker cannot silence, and it
was verified in exactly that role — patch edited, fixture recomposed, marker
updated, everything else green, and it still fired.

**Nothing verified the patched fixture was actually upstream + patch.** As first
designed, a hand-edit or half-finished refresh of the "patched" fixture was caught
by nothing, while the guard and the re-verification ritual both read it as ground
truth. So `plugin-index.ts` **stays pristine upstream** (the `curl | diff` recipe
keeps coming back empty) and `plugin-index.patched.ts` sits beside it, recomposed
and byte-compared by the guard offline. The relationship is proven, not trusted.

**Ordering is a constraint, not an incident.** The `patchedRevision` bump must
merge *before* the pin machinery: the cross-repo fetch is only coherent once the
target tag contains the patch (it 404s on `.7`), and the rewritten "diff against
upstream + patch" instructions are wrong until the patched loader is what
deploys. The window is safe rather than lucky — `opencodePatchedHold` at
`1.17.13` means no upstream loader change can arrive by automation; only a
deliberate human bump, which reds the guard anyway.

*(Also flagged, and filed as `workstation-qzya` rather than fixed here: the
fork's own `loader-observability.test.ts` asserts the `file://` shape against
`plugin_origins` it constructed as `file://` itself. The production behaviour is
real — verified directly in `config/plugin.ts:21-27` — but that test does not
establish it. This bead's signature error, inside the patch written to fix it.)*

*(The `sst/opencode` vs `anomalyco/opencode` discrepancy between the guard's
recipe and `build-release.yml:60-61` was checked: both serve byte-identical
content for `v1.17.13`, so it is cosmetic. Worth a note in the recipe, not a
fix.)*

The bundle checkPhase's deliberate extra strictness (rejecting a bare-function
default, a policy ratchet) survives untouched, per the guard's own note.

---

## Verification

The bead's founding lesson is that #202 was tested exhaustively as a module and
never once in the role it broke in. So:

1. **Unit tests inside the patch**, on `assertHooks` and the buffering property
   — and a `build-release.yml` step naming them. A patch-carried test that no
   workflow runs is inert, which is the #249 failure verbatim.
2. **Scratch-serve controls, in the role** (`XDG_DATA_HOME` redirected, or the
   control poisons the log the production canary reads):
   - an **import-time throw** → anchored grep matches (today: nothing at all),
     and `plugin_canary_plugin_key` extracts the right key;
   - a **missing entrypoint** (defect D) → anchored grep matches. Review found
     this stage unenumerated; without a control for it, every control would
     exercise stages the patch covers and none would exercise the stage it
     forgot. That is this bead's signature error — testing only the role you
     already had in mind — so it is required, not optional;
   - a clean load → `message="plugin loaded"` appears once per plugin;
   - **caveman specifically** (config-array origin, relative spec
     `./plugins/caveman/plugin.js`) → record the actual `path=` and assert the
     extracted key. *Pre-checked at source:* `config/plugin.ts:42-54` normalises
     path-like specs via `pathToFileURL(path.resolve(base, spec)).href`, so it
     should emit a `file://` URL and `test.sh:122` already covers that key. The
     control confirms it in the role rather than trusting the read;
   - **3b only:** a factory returning `undefined` → file rejected, anchored grep
     matches, serve stays healthy and `/config/providers` returns 200 (today it
     500s); and `{}` → loads fine, no error.
3. **`bridge.fork(Effect.logError(...))` must be verified to produce a line the
   anchored pattern matches** — same `timestamp=`/`level=ERROR` formatting as a
   yielded `logError`. This is a role-not-module claim and gets a real serve, not
   a unit test.
4. **Pin-guard rehearsal in its own role.** Bump `patchedRevision` locally with
   the loader patch untouched and confirm `test-loader-pin.sh` stays **green**;
   then change the vendored loader patch and confirm it goes **red**. The
   guard's job is to fire on meaning-drift, and the withdrawn compound design
   fired on version-drift instead — a distinction no amount of reading catches
   and one rehearsal does.
5. Re-run `test.sh`, `test-behaviour.sh`, `test-loader-pin.sh`, `nix flake check`.

---

## Scope: what this step does NOT do

**Canary consumption of the success line** — per-file presence assertion and
automatic latch clearing — is a **separate step**, filed as its own bead.

The string-compatibility decision above means the canary needs zero changes for
correctness through this transition, and that decoupling is exactly what makes
the split safe. Against it: a combined step would have to land synchronously
across the fork repo, a pin bump, the workstation repo, and a production restart
— and deploy ordering has already cost this bead a full day.

The deeper reason is that auto-clear needs design work of its own. **Loading is
lazy**, so a success line for X is per-(process, directory) and can arrive at any
time; *absence proves nothing*. The only sound rule is one-directional: clear the
latch for key K when a success line for K appears with a `run=`/timestamp newer
than the latch. "Assert all nine present after a restart" is level-asserting a
lazy event and would false-page. That deserves its own adversarial review, not a
bullet here.

---

## The gap this step makes worse, stated plainly

**Devbox has no canary — not just no plugin canary, no canary at all.** Verified
today: `opencode-plugin-canary` appears only in `hosts/cloudbox/configuration.nix`.
The roadmap's line 328 calls E2 "a devbox/cloudbox canary"; the shipped reality is
cloudbox-only, and devbox slipped out between design and ship.

That matters here specifically, because **the LOUD incident was on devbox**
(2026-07-30), and devbox is live and actively maintained (its config was touched
2026-08-03; 43 devbox commits in 90 days), runs a K=2 `opencode-serve@` pool, and
deploys the same nine plugin files through the shared `opencode-config.nix`.

Change 1 converts LOUD → QUIET. On cloudbox that is the intended trade, because
E2 catches the QUIET shape. On devbox and macOS there is nothing to catch it:

| | pre-D | post-D |
|---|---|---|
| cloudbox | total outage, obvious | one log line → **canary pages** |
| **devbox** | total outage, obvious | one log line → **nobody is watching** |
| **macOS** | total outage, obvious | one log line → **nobody is watching** |

By the roadmap's own gating logic — *"D without E2 manufactures more 32-hour
silent failures; E2 is D's prerequisite"* — D is ungated on two of three hosts.

**Porting the canary is not a step-3 bolt-on.** Devbox has no frontdoor (leg A
probes `:4700`), no `drift-alert` references at all (no notification path wired),
and runs its serves as `systemd.user` rather than system units. That is a real
port, and it is its own step.

**My first disposition was to proceed anyway, and review correctly called it
rationalized.** The argument I wrote weighed only *proceed* against *block*, and
never surfaced the third option this very design makes available: the step is not
atomic. Changes 2 and 3 are **pure signal additions**, safe on every host and
gated by nothing. Change 1 is the **only** LOUD→QUIET converter and the only
thing the roadmap's rule speaks to. My argument (a) — "changes 2 and 3 improve
every host" — was true, and was doing illegitimate duty as justification for
shipping change 1 alongside them.

The concrete scenario settles it. After step 1, every repo plugin is v1-shaped
and the bundle checkPhase invokes the factory and asserts a hooks object, so the
realistic surviving LOUD trigger is **an external symlink going bad on a `git
pull` nobody here reviews**. Verified today: `opencode-pigeon.ts` and
`superpowers.js` are deployed **unconditionally** (`opencode-config.nix:646-658`,
no `mkIf`) — devbox and macOS carry both. Pre-change-1 that is a total outage,
fixed in hours because it announces itself. Post-change-1 on devbox it is pigeon
silently unloaded — **swarm messaging and scheduled wakes quietly dead**,
discovered days later when a wake never arrives. That is the 32-hour shape
verbatim, on the founding-incident host, with nobody watching.

**Decision: split the step.** See "Sequencing" below.

---

## Sequencing: 3a now, 3b gated

| | Contents | Gate |
|---|---|---|
| **3a — observability** | Changes **2 + 3**: `logError` in `report.error` (4 stages) and `report.missing`, plus the `plugin loaded` INFO line. Pin machinery. | **None.** Pure signal addition; strictly improves every host. |
| ↳ *3a-fork* | The patch itself. **Merged:** `opencode-patched` PR #36 (`8ce5fe9`). Not released, not deployed — production still runs `1.17.13.7`. | — |
| ↳ *3a-workstation* | Pin machinery: vendored fixtures (`plugin-index.ts` patched, `loader.ts`, spec normalisation), patch-identity hash, `update-opencode-patched.yml` cross-check, release + `patchedRevision` bump + deploy. | Needs a fork release to pin against. |
| **3b — validation** | Change **1**: `assertHooks` + buffer-then-commit. The LOUD→QUIET converter. Tracked as `workstation-l7bz`. | Devbox has *some* detector (`workstation-fg2w`), or an explicit, recorded acceptance. The gate is a `bd` dependency, not just prose. |

This costs one extra release cut and loses nothing, because **3a makes 3b
cheaper and safer**:

- After 3a deploys, a load failure is a real ERROR line on *every* host,
  including the two with no canary. Today there is literally no evidence
  anywhere. That is the first per-file signal devbox and macOS have ever had.
- A devbox detector then needs **leg B only** — a log tail. Leg B needs no
  frontdoor (devbox has none) and no `drift-alert` (devbox has none); it needs
  pigeon, which devbox **does** have (20 references in its config). So the port
  that gates 3b is a fraction of the full cloudbox canary, and 3a is what makes
  it possible at all.

The ordering is therefore not delay-for-caution; it is the cheapest path to
having 3b be safe.

**This must not become the decay the roadmap warns about** ("do not let the bead
decay into 'add more tests'"). 3b is the class-killer and stays P1. Its gate is a
log-tail port, not an open-ended project.

## Upstream vs fork split

**Upstream PR** — all three changes, one PR. Each is generic and carries no
workstation-specific logic: a real crash class, a measured zero-output failure
(upstream's own `:230` comment says "TODO: make proper events for this", so the
gap is acknowledged), and a success line. With tests.

**Fork-local** — the exact-string constraint. Upstream may well bikeshed the
wording; the fork patch keeps `failed to load plugin` and the `path=` shape
byte-compatible so the deployed canary works regardless. If upstream later lands
different wording, the bump-time pin test goes red and pattern + fixture move
together. The mechanism already exists.

**Do not block step 3 on the upstream PR.** Land the fork patch first.

---

## Residuals this step does NOT close

Stated so the "class-killer" framing does not overclaim in the PR body:

- **Trigger-time hook throw** — a valid-shaped hooks object whose hook throws
  when triggered. `trigger` uses `Effect.promise`, not `tryPromise`; no per-hook
  catch, request 500s. Neither leg sees it.
- **Valid-shaped but behaviourally wrong** hooks. Nothing sees it.
- **Side effects of a staged-then-rejected server** (above).
- **First-pass EOF blind window** on the canary (design doc `:227-235`), bounded
  ≤24h and shrunk by laziness.
- **Non-`file://` specs collapse to latch key `unknown`** (`opencode-plugin-canary.sh:97-100`,
  fallback at `configuration.nix:1745`). Install- and compatibility-stage
  failures carry an npm spec like `pkg@version`, so two distinct such failures
  share one latch and the second is swallowed by the first's backoff — losing the
  per-file-signature property the E2 design defends. **This bound was false when
  written, and the residual is live today** (`workstation-njer`, which now blocks
  `workstation-0lkp`). Production has **three** npm-spec plugins —
  `opencode-beads`, `@ex-machina/opencode-anthropic-auth`,
  `opencode-gemini-auth@1.3.11` — so three of twelve sources share one `unknown`
  latch right now. Measured 2026-08-05 by rewriting real `plugin loaded` lines to
  the failure shape and running the canary's own extraction: all three returned
  empty; a `file://` plugin returned `caveman/plugin.js`.

  Worth dwelling on, because the failure is not the missed fact but the shape of
  the sentence. This section correctly *identified* the hazard and then retired it
  with an unchecked empirical claim — "there are zero npm plugins" — of exactly
  the kind that reads as settled. The alert still fires; only attribution
  degrades. But a residual dismissed by an assumption is indistinguishable from a
  residual that was actually bounded, right up until someone counts.
- **`assertHooks` is deliberately shallow** (3b). `{ config: 42 }` passes, and
  the trigger path (`plugin-index.ts:290`, `Effect.promise`, no per-hook catch)
  then 500s. Deepening it to "all members are functions" would reject legal
  plugins, since `Hooks` may carry non-function members. The upstream PR body
  should pre-answer this, because it is the first question a reviewer asks.
