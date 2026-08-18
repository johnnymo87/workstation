# Plugin-Loader Hardening Roadmap

**Bead:** `workstation-5yox` (P1) · **Started:** 2026-08-01 · **Status:** steps 0-3a **live**; devbox detector merged (#320); 3b blocked on an OBSERVED fire drill (`workstation-y8ql`)

> **Revision 2.** The first draft of this file (PR #242) was written and merged
> *without* the adversarial review it makes mandatory. Review afterwards found
> three HIGH defects, each of which rebuilt the failure family this roadmap
> exists to kill: the spine's numbered order contradicted its own "before code"
> rule, the E2 log-watch would have been unconditionally red against ~2500
> historical matches while its own negative control polluted the log it reads,
> and the `LOADER_VERSION` pin rotted on an 8-hourly auto-merge timer with only a
> comment guarding it. All are fixed below. Recorded rather than quietly
> corrected, because "the process document skipped the process" is the single
> most useful datum in this file.

Kills the bug class that took devbox down on 2026-07-30 and then silently
disabled `shell-env.ts` for ~32 hours. Four steps, each with the same spine.

---

## Facts that must survive compaction

Everything below was verified at source or in a live process. Do not re-derive
from memory, and do not trust a summary of it — including this one — over a
fresh check.

**Loader semantics** (opencode `v1.17.13`, `packages/opencode/src/plugin/`):

| Site | Behaviour |
|---|---|
| `index.ts:99-105` `getLegacyPlugins` | iterates `Object.values(mod)`; anything not a function and not `{ server: fn }` hits `throw new TypeError("Plugin export is not a function")` at **:103** → **whole file rejected** |
| `index.ts:110-121` `applyPlugin` | v1 branch pushes `plugin.server(...)` and **returns at :115**; only the fallthrough reaches `getLegacyPlugins` at :118 |
| `shared.ts:272-283` `readV1Plugin` | in `"detect"` mode returns `mod.default` when it is a record carrying `id`/`server`/`tui` |
| `shared.ts:306-316` `resolvePluginId` | `source === "file" && !id` → throws `Path plugin ... must export id`. **`id` is mandatory for our plugins.** |

**The three failure shapes:**

```
export function foo          -> invoked as a plugin factory; return value pushed
                                into hooks unvalidated. undefined poisons the
                                array -> /config/providers 500s, no prompt runs.
                                (LOUD - the devbox outage)
export const foo = {...}     -> throws at index.ts:103 -> file rejected, one
                                ERROR line, serve otherwise healthy.
                                (QUIET - shell-env, 2026-07-30..08-01)
export default {id, server}  -> v1 branch; named exports never inspected. SAFE.
export interface / type      -> erased at compile time. SAFE.
```

**Grepping the serve log** — `~/.local/share/opencode/log/opencode.log`, *not*
the systemd journal (serve stdout does not go there; `journalctl -u
opencode-serve@4096` is a false-negative trap).

```bash
# CORRECT - anchors the field
grep -E '^timestamp=\S+ level=ERROR .*failed to load plugin' "$LOG"
```

A naive `grep level=ERROR` also matches INFO permission-audit lines that *quote*
command text, so any session merely discussing the error string produces false
positives. This bit the author of this document twice, once after having
explicitly warned about it. **Step E2 depends on getting this right.**

**The log is shared, append-only, and full of history.** One ~633MB file for the
whole host — every TUI, headless session, and scratch serve appends to it, and it
holds entries back to June including **~2500 historical `failed to load plugin`
matches** from the 07-30..08-01 incident itself. So the anchored pattern above is
necessary but *not sufficient*: an unwindowed grep is unconditionally red.

Any consumer must scope to the current process, by either:

- **`run=<id>`** — the per-process field on every line, and the only true
  discriminator available; or
- **byte offset captured at restart**, reading only what was appended after.

**Scratch serves must scrub routing env AND redirect their data dir.** The first
or our own routing guard kills them; the second because a scratch serve otherwise
writes real `ERROR` lines into the very log the production canary reads — the
negative control poisons the detector.

**CORRECTED 2026-08-14 — the recipe that used to be printed here was WRONG and
silently opened the production database.** `XDG_DATA_HOME` does not redirect the
database: opencode's `Database.path()` returns an absolute `$OPENCODE_DB`
verbatim *before* it consults `Global.Path.data`, and `OPENCODE_DB` is a session
variable (`users/dev/home.base.nix`) that every child process inherits. So the
scratch serve wrote logs/config/state to `/tmp` — making the isolation *look*
like it worked — while reading and writing live session rows. That is not
hypothetical: it happened on 2026-08-14, and the verification query, run against
the untouched copy, returned a clean-looking "0 rows" false green.

Use the wrapper, which builds the environment correctly and then PROVES it from
`/proc/<pid>/fd` before handing you a URL:

```bash
oc-throwaway-serve                 # empty scratch DB
oc-throwaway-serve --copy-db       # seeded from a consistent snapshot of the live DB
OC_THROWAWAY_SERVE_BIN=/path/to/candidate/opencode oc-throwaway-serve   # validate a build
```

By hand, `OPENCODE_DB` must be scrubbed or repointed explicitly — never left to
inheritance:

```bash
env -u OPENCODE_SERVE_ID -u OPENCODE_ROUTING_DB -u OPENCODE_DB \
    XDG_DATA_HOME="$scratch/data" XDG_CONFIG_HOME="$scratch/config" \
    opencode serve --port <scratch-port>
# then VERIFY, do not assume:
ls -l /proc/<pid>/fd | grep '\.db'    # must show NO ~/.local/share/opencode/opencode.db
```

opencode itself now refuses the broken shape (`db-isolation-guard.patch` in
opencode-patched: `XDG_DATA_HOME` set + `OPENCODE_DB` resolving outside it ⇒
FATAL, exit 22, before any handle is opened), but the guard ships with a build —
verify by measurement anyway, which is the actual lesson.

**Deploy ordering.** `git pull` **before** `home-manager switch`. Doing it the
other way round silently deploys the pre-merge tree — this cost a full day on
step 0. Existing serves keep their in-memory module, so a pool restart is
required before any verification means anything.

**The lesson the whole bead exists for:** verify in the *role the code actually
plays*. #202 was tested exhaustively as a module under vitest and never once as
a plugin, which is the only role in which it broke. The guard written afterward
repeated the error — it asserted a rule *about* the loader instead of exercising
it, passed on a file opencode was rejecting, and its failure message recommended
the very pattern that was breaking production. Three instances in one week.

---

## Per-step spine

Every step below runs this sequence. It is the point of the roadmap: the spine
survives even if the step's details are lost.

1. **Compact** *(only if context is long)* — `preparing-for-compaction`. Persist
   to `workstation-5yox` and update this file *before* compacting, not after. A
   fresh session has nothing to compact and should skip straight to 2; a
   mid-flight session should not compact away the context the step still needs.
   This is a conditional, not a ritual.
2. **Consult `oracle-fable`** *(optional)* — when the design is genuinely open.
   Skip for mechanical steps.
3. **`adversarial-reviewer-fable` on the DESIGN** — **mandatory, and it comes
   before any code exists.** Every time this was skipped in this bead's history
   the result was wrong: fable caught the broken remediation that had already
   shipped to production, and caught three HIGH defects in the first draft of
   this very document, which was written and merged without it.
4. **SDD / implement** *(if applicable)* — `subagent-driven-development` when the
   step splits into independent tasks; dispatch `implementer`, then
   `spec-reviewer` to check the diff against the reviewed design. Skip the
   subagents for single-file changes; do not skip the review in 3.
5. **`adversarial-reviewer-fable` on the IMPLEMENTATION** — **also mandatory,
   also before the PR opens.** Added by the user on 2026-08-01 after the
   evidence became one-sided: the design pass caught three HIGH defects in this
   document's first draft, and an implementation pass caught the *inert* pin
   guard shipped in #249 — a check wired nowhere, which every design review in
   the world would have approved because the design was right and the wiring
   was not. **Neither pass substitutes for the other; they read different
   artifacts.** Step 1 then proved it again: the design pass produced the
   fail-on-throw idea, and the implementation pass found that the very check
   implementing it had a `hooks = undefined` catch-path that would have skipped
   the assertion for a factory *successfully* resolving to `undefined` — the
   exact outage shape.
6. **PR** *(if applicable)* — throwaway worktree off `origin/main`, never the
   shared checkout. Body states what was verified *and how*.
7. **Update roadmap** — tick the step here, file new beads for anything
   discovered, note what the next step inherits.

> **Why review precedes implementation.** Earlier drafts of this list numbered
> SDD *before* the review while annotating the review "before writing code" — a
> contradiction that a post-compaction reader, following the list literally,
> resolves by implementing first and reviewing the diff. That is the `9eb5b0e`
> pattern reconstructed inside the process meant to prevent it. Every failure in
> this bead was a *wrong-approach* failure — wrong export shape, wrong rule,
> wrong role — not an implementation typo. Design review is the only place those
> get caught.

> Steps 3 and 5 both name the `fable` variants, which are otherwise
> use-only-when-explicitly-asked. The user asked for them in this roadmap; that
> standing request applies to these steps only.

---

## Step 0 — Repair `shell-env.ts` · **DONE** (PR #225, `55a6b51`)

Adopted the v1 shape; replaced `no-function-exports.test.ts` with
`test/plugin-loader-contract.test.ts`, a loader replica pinned via
`LOADER_VERSION`. Verified by three mutations (all caught; the first was
*passing* the old guard) and by a real `opencode serve` on a scratch
`XDG_CONFIG_HOME` with both controls — 0 errors with the fix, exactly the
production error with the pre-fix file.

Deployed 2026-08-01 18:11 (gen 528). Confirmed live: `OPENCODE_HOSTNAME` set,
per-session `KUBECONFIG` injected, sops secrets restored, **0** load failures
since restart. Per-session kube isolation (`workstation-ev9n`) became real for
the first time at that moment — it was inert from merge until then.

---

## Step 1 — E1 across the remaining plugins · **DONE** (PR #288, `424d590`)

All six repo plugins are now on `export default { id, server }`. Deployed
2026-08-04; the artifacts on disk carry the shape, and running serves keep their
old in-memory modules until the pool next restarts (the mixed state is safe --
the old modules are the legacy shape, which worked).

The consequent change was **not** in the plugins. `pkgs/opencode-plugin-bundle`'s
checkPhase asserted `typeof m.default === 'function'`, so the v1 shape broke both
bundle builds. It was replaced with a v1-shape assertion that also *invokes* the
factory and asserts a hooks object — the v1 branch pushes that return value
unvalidated exactly as the legacy branch does (`plugin-index.ts:114`), so the
LOUD outage shape survives into the v1 world untouched. Until step 4, that line
is the only cover the two bundles have for it.

Three things worth carrying forward:

- **A sandbox throw now FAILS the bundle build** rather than passing, with an
  explicit `factoryMayThrowInSandbox` opt-out. Treating a throw as a pass meant
  the hook-shape assertion could silently cover nothing, announced only by an
  `OK: factory threw` line in a green build log. Same family as the SKIPping
  store-prefix gate in `flake.nix`. This bit for real: with `client: undefined`,
  self-compact threw on `ctx.client._client` and the assertion covered nothing.
- **The checkPhase is a third in-repo copy of loader semantics**, now coupled to
  the other two by a `# LOADER_SEMANTICS_PIN` marker that `test-loader-pin.sh`
  checks. It shipped for one revision with only a comment saying "nothing will
  tell you" when the pin moves — which is the rot the pin guard exists to
  prevent, restated as a hope.
- **`/config/providers` returning 200 does NOT mean plugin loading has
  finished.** During the negative control the anchored grep found nothing, then
  found the error moments later: the serve answers HTTP *before* the
  `failed to load plugin` line is flushed. **Step 2 must not sample at HTTP
  readiness** — it will miss the very line it exists to find. Poll for the
  line, or window by `run=` and sample after a settle delay.

Also filed: `workstation-u59h` — the older replica in
`plugin-loader-contract.test.ts:164` checks `tui` is not a *function*, so it
passes `tui: 42` while upstream throws `invalid tui export` and rejects the
file. The new checkPhase gets this right; the two copies disagree.

### Original scope (kept for the record)


**Six repo-authored plugins, not four.** Deployed directly as `.ts`:
`compaction-context.ts`, `session-header.ts`, `subagent-routing.ts`. Deployed as
Nix-built `.js` bundles: `self-compact.ts`, `session-state.ts`.
(`shell-env.ts` was step 0.)

All are safe *today* only because they happen to have zero named runtime
exports. Any future helper export is an outage. Migrate each to
`export default { id: "<name>", server: plugin }` so the property holds by
construction.

The two bundled ones matter more than they look: `plugin-loader-contract` skips
them (its `existsSync` filter only sees sources deployed verbatim), and step 4 —
the only thing that would cover their *artifacts* — is last. Until then a helper
export added to either source ships completely unchecked. Migrating the **source**
is enough: bundlers preserve the entry module's exports, so the artifact inherits
the v1 shape.

- Spine: skip 2 (mechanical); **3 still applies** — `9eb5b0e` was also
  "mechanical."
- Watch: each plugin's own tests reach the hook via the default export and will
  need `pluginModule.server(...)`, as `shell-env.test.ts` did.
- Exit: **all six** repo plugins on the v1 shape; `plugin-loader-contract` green;
  real-process check shows 0 load failures.

## Step 2 — E2 canary log-watch · **DONE** (PR #294)

Shipped as `opencode-plugin-canary`, a minutely detect-only system unit on
cloudbox. Design: `docs/plans/2026-08-04-e2-plugin-canary-design.md`. Two legs,
orthogonal rather than ranked — leg A (probe through the door) sees *any* failure
shape but one file; leg B (log tail) sees one failure shape but *all nine*.

**Nine plugin files load here, not six.** The roadmap counted the ones we author.
`caveman/plugin.js` loads via the config `plugin` array rather than the glob, and
`opencode-pigeon.ts` / `superpowers.js` are `mkOutOfStoreSymlink`s into other
repos' live checkouts — no build-time cover at all, covered *only* by leg B. Any
coverage claim in this file that says six is wrong.

**Four things measured that were previously assumed:**

- **Plugin loading is LAZY.** A broken plugin logged nothing at serve start; the
  error appeared only when a request arrived. So the "logs once per serve start"
  model in this file is wrong — it is once per *directory App init*, and can
  therefore happen at any time. This makes leg B's latch (edge detection, level
  alerting) more clearly right, and it shrinks the first-run blind window.
- **An import-time throw is COMPLETELY silent** — zero matching lines, zero
  `level=ERROR` lines, and nothing on stdout/stderr either, so journald has it
  too. Predicted "probably no line"; now measured. G4 confirmed.
- **That throw is isolated to its own file** — a sibling plugin still loaded and
  its tool was still registered. Checked because the opposite would have widened
  leg A a lot; it does not. The blind cell stands.
- **Delivery was fire-drilled end to end.** Pigeon accepted the POST (it writes
  state only on 2xx, and 502s if Telegram rejects), and three consecutive passes
  produced exactly one message.

**The defect worth remembering.** The first design was edge-triggered: it called
`driftAlert` once per detection. But `driftAlert` is a **throttle, not a
scheduler** — it re-alerts only when the caller re-invokes, and it swallows a
failed POST (`exit 0` always, state written only on 2xx). That design would have
sent one `warning`-severity page, never nagged, never escalated, and lost the
alert entirely if pigeon were down for that minute: **the 2026-07-26 frontdoor
incident rebuilt inside the fix for it** (760 detections, one page, missed,
12h39m silence). Caught by the design review, before code. The fix is a latch
written before the offset advances, re-alerted every pass.

Also from review: threshold **7**, not 3 — the post-boot catalog burn runs 5-6
min and `/config/providers` *is* the provider catalog, so a lower threshold pages
on routine restarts. And the probe routes are pinned anchor-forwarded, because
`forward-pool` fails over only on *unreachable*: a plugin-broken-but-alive member
would answer wrong content 1 probe in 4 and never cross a threshold.

**Testing lesson, again.** `test.sh`'s three ordering markers are *static greps*
for comments — deletion tripwires, nothing more; a refactor that hoists the
offset write above the latch loop passes all three while breaking the design. So
`test-behaviour.sh` extracts the real `ExecStart` from the evaluated NixOS config
and **runs it**. Both new guards caught real defects while being written: the
route-table check matched its own prose warning containing "poolSafe", and the
pin check was upgraded from comparing version numbers to asserting the pattern
against the vendored upstream fixture.

Filed: `workstation-j95n` (unbounded 668MB log, no rotation), `workstation-im79`
(a masked timer is still invisible — `OnFailure` covers only a crashing script).

### Original scope (kept for the record)

## Step 2 — E2 canary log-watch

Cheapest real detection, and it runs **before** the loader patch on purpose.

**Why E2 gates D, rather than merely being cheaper.** D's validate-and-throw
converts the LOUD shape into the QUIET one: a factory returning garbage stops
poisoning the hooks array (visible — 500s, no prompts) and instead gets the file
rejected with a single log line (invisible). *D without E2 manufactures more
32-hour silent failures.* E2 is D's prerequisite.

The weaker argument, which the first draft of this document leaned on: "a health
check would not have caught this." True of the QUIET shape only —
`/config/providers` returned `200` throughout the shell-env breakage — but a
health check *would* have caught the LOUD devbox outage. Do not lead with it.

Upstream reinforces the point: the user-visible event for a plugin load failure
is **commented out** in `index.ts` ("TODO: make proper events"), so the log line
is quite literally the only signal that exists.

- **Positive signal is primary, and it must be BEHAVIOURAL, not log-derived.**
  Assert an observable *effect* of each plugin having loaded — e.g. a probe bash
  call through the door returning `OPENCODE_HOSTNAME`, which is exactly what
  shell-env's absence removed. Do **not** try to assert "plugin X loaded" by
  grepping: upstream emits no per-plugin success line at all (`report.start` is
  a no-op, the loader logs nothing on success), so there is nothing to match.
  An earlier revision of this file specified the log-derived version; it is
  unimplementable, and it replaced a probe that already worked.
  Rationale for keeping positive signal primary: matching known-bad strings
  cannot see failure shapes we have not met yet, and "assert about known-bad" is
  the guard class that already failed here twice. Keep the anchored ERROR grep
  as the secondary, windowed by `run=` or restart offset (see Facts).
- Coverage gap to state plainly: this is a devbox/cloudbox canary, but **macOS
  deploys these same plugins** and has no canary. D is the only macOS cover.
- Spine: consider 2 (alert routing is an open design); **3 applies**.
- **Do not sample at HTTP readiness.** Measured in step 1: `/config/providers`
  returned 200 while the `failed to load plugin` line had not yet been written,
  so an anchored grep run at readiness found nothing and the same grep moments
  later found the error. A canary built on "wait for healthy, then grep" is
  green by construction on the fastest-moving failures. Poll for the line with a
  timeout, or settle first, and make the *absence* claim only after the window
  closes.
- Exit: three controls, not two — (a) clean restart is silent; (b) a deliberately
  broken plugin raises the alert; (c) an **import-time** throw also raises it
  (different upstream message, see Residual). Scratch serve must use the
  `XDG_DATA_HOME` recipe in Facts, or the test contaminates the detector.

## Step 3 — D patch the loader · **SPLIT into 3a / 3b** (design: `docs/plans/2026-08-04-step3-loader-patch-design.md`)

Design review split this step, and the reason is the roadmap's own gating rule
turned back on itself. Change 1 (validate-and-throw) converts LOUD → QUIET, and
**only cloudbox has a canary** — verified: `opencode-plugin-canary` appears in
`hosts/cloudbox/configuration.nix` and nowhere else, and `hosts/devbox` has zero
`drift-alert` references. Line 328 below calls E2 "a devbox/cloudbox canary";
that was never true in the shipped artifact. So by *"D without E2 manufactures
more 32-hour silent failures"*, D is ungated on two of three hosts — including
devbox, where the founding LOUD incident happened, and which deploys
`opencode-pigeon.ts` and `superpowers.js` **unconditionally**
(`opencode-config.nix:646-658`).

| | Contents | Status |
|---|---|---|
| **3a — observability** | Log per plugin on failure (all four `report.error` stages **and** `report.missing`) and on success. Pure signal addition, safe on every host. | **LIVE** since 2026-08-05 03:01 EDT. Fork patch `8ce5fe9`, released `v1.17.13-patched.8`, auto-bumped in #301, pin machinery in #303. |
| **3b — validation** | `assertHooks` + buffer-then-commit at both push sites. The class-killer. | `workstation-l7bz`, **blocked** on `workstation-y8ql` (an *observed* alert), not on merged config. |

**Devbox cover shipped in #320 (`workstation-fg2w` closed), and it does NOT open
the 3b gate.** Leg B moved into the shared library so both hosts run one
implementation; devbox got a `systemd.user` unit, because nothing auto-applies
NixOS *system* config here — there is no `system.autoUpgrade` and
`pull-workstation.timer` runs `home-manager switch` only, so a system unit would
have sat merged-but-inert and looked, from off-host, exactly like a working
detector.

The gate now hangs on `workstation-y8ql`: a fire drill that appends one synthetic
anchored ERROR line and requires the Telegram message, the `LATCHED` journal
line, and a *re-alert* on a later pass to be pasted in as evidence. The reason is
this roadmap's own repeated lesson — merged is not deployed is not working — and
it applies with unusual force here, because nobody has observed either host fire
since the extraction, and devbox is unreachable from cloudbox. A detector that
has never been seen to fire is mechanically no worse than nothing, but it becomes
*worse than nothing* the moment a gate opens on its existence.

**macOS gets 3b too, and has no canary and never will.** The gate as previously
written was silent about this, which is the same unchecked-claim shape one host
over: 3b ships as a fork binary through the shared `home.base.nix` bump, so
per-host gating of the *binary* is not available. Step D is the only macOS cover.
Recording the gap here rather than leaving it implied — **the decision to accept
it is the user's to make, not this document's to assume.**

> **Running, verified 2026-08-05 03:50 EDT.** The 03:00 nightly reset was the
> deploy window (it restarts the serve pool), so nothing had to be killed by
> hand. All four serve PIDs now exec `1.17.13.8`, restarted 03:01:16; 267
> `plugin loaded` lines, zero failures, canary exit 0.
>
> The count is the interesting part: **267 did not reconcile with 9 × 24 = 216.**
> Chasing the 51-line gap found that there are **twelve** plugin sources, not
> nine — nine `file://` plugins plus `opencode-beads`,
> `@ex-machina/opencode-anthropic-auth`, and `opencode-gemini-auth@1.3.11` (the
> last config-scoped to two projects, hence 3 loads not 24). "Nine deployed
> plugins" is right about *files* and undercounts what the canary sees. Stopping
> at "all three checks green" would have recorded a clean pass and missed both
> this and the residual below.

3a makes 3b cheaper *and* safer: after it deploys, a load failure is a real ERROR
line on every host, so a devbox detector needs **leg B only** — no frontdoor, no
drift-alert, just pigeon, which devbox has. **3b stays P1;** its gate is a
log-tail port, not an open-ended project.

**Measured while building 3a** (real serves, patched vs. unpatched binaries):

- **`report.missing` was a fifth silent stage nobody had enumerated** — a bare
  no-op that does not even `publishPluginError`, i.e. *quieter* than the error
  path. Reachable for a directory plugin whose `package.json` `exports` resolve
  no server entrypoint. A patch closing G4 while leaving this open would have
  shipped G4's signature inside the fix for G4.
- **An import-time throw arrives as stage `load`, not `entry`.** The prediction
  was wrong; covering all stages rather than the interesting-looking one is what
  saved it.
- **Unpatched, three broken plugins produced 0 log lines, 0 `level=ERROR` lines
  and 118 bytes of stdout while answering 200.** The blind cell, quantified.
- **`loadExternal` retries only when passed `wait`, which this call site does
  not pass** — so failures are reported exactly once. A first draft asserted
  `>= 1` on the strength of a retry path that cannot be reached here.

**Two corrections to this file's own machinery, both found by review:**

- **The compound-version pin was withdrawn.** Making the five constants
  `${upstreamVersion}.${patchedRevision}` would have gone red on *every* fork
  release — 26 patches, ~25 loader-unrelated — against an auto-merged bump PR,
  training exactly the ritual bumping `test-loader-pin.sh:176` forbids. The pin
  must key on the loader patch's **identity**, not the fork's revision number.
- **The pin must also cover spec normalisation** (`config/plugin.ts:42-54`).
  The canary's per-file key requires `path=file://`; without it every failure
  collapses to one shared `unknown` latch. That shape is produced in a file the
  design had not vendored.

### Original scope (kept for the record)

Validate the awaited result before `hooks.push` — at **BOTH** sites. The line
usually cited, `index.ts:119`, is only the *legacy* loop. The v1 branch pushes
its result unvalidated at **`index.ts:114`**, and every plugin we author is now
on the v1 shape (step 1), so a patch that covers only `:119` would protect
nothing we ship. Prefer **throw** over silent-skip, consistent with upstream's
existing shape-throw.
Land in `opencode-patched` (`patches/`, ~20 existing; none touch the loader) and
open an upstream PR — fable judges it genuinely upstreamable.

Only step that protects plugins we do not author (`superpowers.js`,
`opencode-pigeon.ts`) and cannot lint. **This is the class-killer — do not let
the bead decay into "add more tests."**

- **The patch must also LOG per plugin, on success and on failure** — added by
  step 2, and it is now the cheapest per-file coverage left anywhere in this
  roadmap. Three things measured in step 2 make it load-bearing rather than
  nice-to-have: an import-time throw currently produces *zero* output anywhere
  (log, stdout, stderr), that throw is isolated to its own file so no probe
  elsewhere can infer it, and nine files load while only one is behaviourally
  probeable. A success line converts "no positive signal exists" from a fact of
  nature into a temporary condition: leg B could then assert per-file
  *presence*, the canary's latches could clear automatically instead of by hand,
  and the shared blind cell closes. It is a few lines in a patch we are writing
  anyway.
- **The canary's log pattern is now a FIFTH pinned constant.** `test-loader-pin.sh`
  couples `pkgs/opencode-plugin-canary-sh`'s `LOADER_SEMANTICS_PIN`, and its
  test asserts the anchored pattern against the vendored fixture's real
  `logError` call. If this step changes what the loader logs — which the bullet
  above requires — that check goes red by design. Update the pattern and the
  fixture together; do not move the marker to quiet it.
- Spine: 2 **recommended** (design is genuinely open); **3 mandatory**; 4 if
  the work splits into fork-patch and upstream-PR tracks.
- Exit: patched loader rejects a non-hook return with a named error; upstream PR
  open; **and the pin guard re-pointed at the fork** — see below.
- **This step breaks the loader pin, by design.** The patch lands in
  `opencode-patched` as a `patched.N` cut, which does not move
  `upstreamVersion`. So the deployed loader diverges from the replica, the
  fixtures, and the `curl`-from-`sst/opencode` recipe in the guard's failure
  message — while `test-loader-pin.sh` stays green. Before this step is done:
  extend the guard to couple `patchedRevision` as well, and re-point the
  fixtures at the fork's patched sources. A pin that cannot see our own patch is
  the same silent-rot failure in a new costume. **Three constants move, not
  two:** `LOADER_VERSION`, `fixtures/VERSION`, and the `# LOADER_SEMANTICS_PIN`
  marker in `pkgs/opencode-plugin-bundle/default.nix` added in step 1.
  `test-loader-pin.sh` fails on any of them drifting, so this cannot be
  forgotten — but note the bundle checkPhase is deliberately *stricter* than the
  loader in one place (it rejects a bare-function default as a policy ratchet),
  and that clause should survive a pin bump untouched.

## Step 4 — B loader replica vs deployed artifacts in CI

Promote `plugin-loader-contract.test.ts` to run against the **nix-store
artifacts** resolved from `opencode-config.nix`, not repo sources. Closes G2
(build-time export injection) for the artifacts we build: `self-compact.js`,
`session-state.js`, `caveman`.

**It does not close G1, contrary to the first draft.** `superpowers.js` and
`opencode-pigeon.ts` are `mkOutOfStoreSymlink`s into live checkouts of other
repos: they mutate on any `git pull` there, are not nix-store artifacts, and are
invisible to workstation CI by construction. That remainder of G1 belongs to
**D + E2**, and to nothing else.

- Pin drift is now handled mechanically by the `LOADER_VERSION` coupling test —
  no longer a manual "must stay pinned" note.
- **Reassess after D lands.** If the patched loader validates results, this step
  is the one most at risk of being the "add more tests" outcome the bead warns
  against. Do not cut it yet — the upstream PR may stall, and until it lands this
  is the only CI-side cover — but cut it honestly if D makes it redundant.
- Exit: CI fails on a deliberately broken deployed artifact.

---

## Known residual (not scheduled)

**Trigger-time hook throw.** A factory returning a *valid-looking* hooks object
whose hook throws when triggered. `trigger` uses `Effect.promise`, not
`tryPromise`, so there is no per-hook catch and the request 500s. Neither step 3
nor step 4 catches this.

**Import-time throw** (bead gap G4). **Measured in step 2, and the earlier
prediction here was half right in the way that mattered least.**

Confirmed: a module that throws while being imported fails in `loadExternal`'s
`entry` stage, which calls `publishPluginError` — an event with no `logError` —
and it writes **nothing at all**. Not a matching line, not a `level=ERROR` line,
and nothing on stdout/stderr either, so journald does not have it. The serve
answers 200 throughout. Step 2's log leg is blind to it, as predicted.

**But the claim this file made next was wrong**, and it was wrong in the
dangerous direction: that the behavioural probe "is the only proposed mechanism
that would notice." Step 2 tested it — a plugin that throws at import is
**isolated to its own file**, and a sibling plugin still loads and still
registers its tool. So leg A notices only if the throw happens in the one file it
probes (`self-compact.js`). For the other eight it is as invisible as it is to
the log leg.

That is the roadmap's real blind cell, stated properly: **any non-logging failure
in a file the behavioural probe does not cover.** Import-time throw is the member
we have met, not the whole set. **Step 3 is the only thing that closes it**, which
is why step 3 now carries a requirement to make the patched loader log per plugin
on success *and* failure — including this shape, which upstream currently
swallows entirely.

**The canary's own dependencies can rot** (filed during step 2, both affecting
the machinery this roadmap now relies on rather than the loader itself):

- `workstation-j95n` — `opencode.log` is 668MB and **has no rotation**. Step 2's
  log leg handles rotation when it comes (inode + truncation detection, and an
  8MiB bound on the reset path), but whoever adds it should keep it out of the
  nightly reset window: the canary lock-skips during reset, so a rotation there
  can eat the per-start error lines between the last offset and the rotation.
- `workstation-im79` — **nothing detects a masked canary timer.** `OnFailure=`
  covers the script crashing, not the timer being disabled or never scheduled, in
  which case silence is indistinguishable from health. That is this bead's own
  signature failure applied to its own detector, and it is generic across all
  four cloudbox canaries.

All are filed here so they are not rediscovered as surprises.

## Out of scope

`global-ro` / anchor-serve is owned by the frontdoor session. Do not start it.
