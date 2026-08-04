# E2 — Plugin-load canary: design

**Bead:** `workstation-5yox` step 2 · **Date:** 2026-08-04 · **Status:** design reviewed, pre-implementation

Detects in production what steps 0-1 can only prevent at build time: an opencode
plugin that fails to load on a running serve. Ships **before** step 3 on purpose
— step 3's validate-and-throw converts the LOUD failure shape into the QUIET
one, so shipping it without a detector manufactures more 32-hour silent
failures.

> **Revision 2**, after adversarial design review. Revision 1 contained a defect
> that reconstructed this bead's signature failure: leg B was edge-triggered and
> called `driftAlert` **once** per failure. `driftAlert` is a *throttle*, not a
> scheduler — it re-alerts only when the caller re-invokes with the same
> signature, and it swallows a failed POST (`exit 0` unconditionally, state
> written only on 2xx). So revision 1 would have sent exactly one
> `warning`-severity page, with no nag and no escalation, and would have lost
> the alert entirely if pigeon was down for that one minute. That is the
> 2026-07-26 frontdoor incident rebuilt — 760 detections, one page, missed,
> 12h39m of silence — while *appearing* to use the escalation logic written to
> prevent it. Fixed by the latch in leg B below.

---

## What is actually deployed (corrected)

The roadmap said "six repo plugins". That is the number we *author*; it is not
the number that **loads**. Verified on cloudbox today:

| File | Origin | Covered by step-1 build assert? |
|---|---|---|
| `compaction-context.ts` | repo | yes |
| `session-header.ts` | repo | yes |
| `subagent-routing.ts` | repo | yes |
| `shell-env.ts` | repo | yes |
| `self-compact.js` | repo (bundle) | yes |
| `session-state.js` | repo (bundle) | yes |
| `caveman/plugin.js` | repo (`pkgs/caveman`), loaded via the config `plugin` array at `opencode-config.nix:391`, not the glob | yes |
| `opencode-pigeon.ts` | **external**, `mkOutOfStoreSymlink` into a live checkout | **no** |
| `superpowers.js` | **external**, `mkOutOfStoreSymlink` into a live checkout | **no** |

**Nine files, not six.** The two external ones mutate on a `git pull` in
*another repo*, are invisible to workstation CI by construction, and are exactly
the G1 remainder the bead assigns to this step and to step 3. Any coverage claim
that counts six is wrong.

## Measured, not assumed (2026-08-04, real scratch serves)

Four controls were run against real `opencode serve` processes on scratch
`XDG_CONFIG_HOME`/`XDG_DATA_HOME` dirs. Two results changed the design.

**1. Plugin loading is LAZY.** A broken plugin produced *no* log line at serve
start. The failure appeared only when a request arrived (`/experimental/tool/ids`),
i.e. plugins load on first App/directory initialisation, not on boot. So the
roadmap's "logs once per serve start" is wrong: the error recurs whenever a
*new directory* is first used in a serve.

Three consequences, all favourable:
- Leg B's edge detection plus a latch is even more clearly right than for a
  once-per-boot event, because the event can now occur at arbitrary times.
- Leg A's probe *triggers* the load it then checks, so the canary partly provokes
  the condition it detects rather than waiting for a user to.
- The first-run EOF blind window is smaller than feared: a failure invisible
  because it predates the offset will be re-logged the next time any directory
  initialises, not only after the next restart.
- But a plugin that fails only under *some* directory is invisible to leg A,
  which probes one. Another item on leg B's side of the ledger.

**2. An import-time throw is COMPLETELY silent.** Predicted "probably no log
line"; measured **zero output anywhere** — nothing matching the anchored pattern,
nothing mentioning the plugin, no `level=ERROR` line at all, and nothing on the
process's stdout/stderr either (so journald would not have it). The serve
answered 200 throughout.

**3. And that throw is isolated to its own file.** A sibling plugin registering a
tool still loaded and its tool was still present. This was worth checking because
the opposite result would have *widened* leg A considerably — if one import throw
disabled every plugin, the `self_compact_and_resume` probe would catch it whatever
file it happened in. It does not. **The blind cell stands exactly as stated
below: leg A gains nothing here.**

**4. The known QUIET shape matches the shipped pattern byte-for-byte.** A
non-function named export produced
`level=ERROR ... message="failed to load plugin" path=file:///...` with
`error="Plugin export is not a function"` — the anchored pattern matched it, the
plugin key was extracted, the latch was written, and the alert fired.

**Delivery was fire-drilled end to end.** With the real `driftAlert`, pigeon
accepted the POST and wrote its state file — which it does *only* on HTTP 2xx, and
pigeon 502s if Telegram rejects, so 2xx means delivered. Three consecutive canary
passes then produced exactly **one** message: the canary re-invoked every pass
(the HIGH-1 fix) while the throttle suppressed the repeats. Both halves of the
property, in the same run.

## Coverage: two legs, orthogonal, neither "primary"

The roadmap says the behavioural positive is primary and the log grep secondary.
That ordering does not survive contact with the file list above, but making the
log leg primary instead is also wrong. The two legs fail along *different axes*:

| | Leg A — behavioural probe | Leg B — log tail |
|---|---|---|
| **Failure shapes seen** | ANY, including shapes we have never met | only failures that emit the known string |
| **Files covered** | `self-compact.js` by name, plus the host-wide LOUD symptom | **all nine**, including the two external ones |
| | *shape-general, file-narrow* | *shape-narrow, file-general* |

So the honest statement is not a ranking. **Leg A is the only leg that can see
an unknown failure shape; leg B is the only leg that can see eight of the nine
files.** Deleting either opens a hole the other does not cover.

Two consequences worth stating rather than leaving derivable:

- **The shared blind cell is: any non-logging failure in the eight files leg A
  does not probe.** Import-time throw is the known member of that cell (no
  `logError`, so likely no line at all), but it is not the whole cell — that is
  the shape we happen to have met. Step 3 closes it.
- **`opencode-pigeon.ts` and `superpowers.js` are covered *exclusively* by the
  known-string leg** — no build assert, no probe. They are simultaneously the
  highest-churn inputs on the machine (they change on a `git pull` in a repo
  nobody here reviews) and the ones guarded only by the guard class that has
  already failed twice in this bead. That asymmetry is the strongest argument
  for step 3's priority.

## Leg A — behavioural, through the front door

Two `GET`s against `http://127.0.0.1:4700`, both verified working today
(5ms and 13ms):

1. `/experimental/tool/ids` → 200 **and** the array contains
   `self_compact_and_resume`. That tool exists only because `self-compact.js`
   loaded and its `tool` hook registered — a genuine load-proof for one file,
   and the only such proof available over HTTP.
2. `/config/providers` → 200. This is the **literal symptom of the devbox
   outage**: a poisoned hooks array 500s this route. It is not file-specific —
   the LOUD shape breaks every plugin at once — so one probe suffices *for that
   shape*.

**Anchor-only, and that is correct.** Both routes are `global-ro` without
`poolSafe`, so the door forwards them to the anchor (`dispatch.ts:137-139`,
anchor fixed at `config.ts:102`). All four serves read the same plugin
directory, so a load failure is a config/deploy regression and is
serve-independent.

Deliberately **not** requesting `poolSafe`. `forward-pool` is a round-robin
cursor with failover only on *unreachable* (`proxy.ts:64-82`), so a member that
is alive but plugin-broken answers wrong content roughly 1 probe in 4 with no
failover — which can never cross a consecutive-failure threshold. Rotation
would convert a detectable failure into a permanently suppressed one.

**This decision must be defended in the place that would break it.** Sixteen
rows already carry `poolSafe: true`, promoted "by cross-member diff", and
`/experimental/tool/ids` *passes* a cross-member diff on any healthy day — so it
is a natural promotion candidate and the verification method cannot see why it
must stay anchored. Therefore: a `note:` on both rows naming this canary, plus
an assertion in the canary's flake-checked test that dispatch for these two
routes yields `forward-anchor`. That fails the *promoting* PR, which is where
the knowledge is needed.

**Level-triggered.** Plugins load once per serve start, but edge-triggering
would have to hook every start path (nightly reset, serve-canary restarts,
manual, OOM) and would race the flush gap measured in step 1. A level poll
misses no start by construction.

**Status → action, explicit, and locked by a test.** Revision 1 said only
"cannot reach vs reachable-but-broken", which leaves the interesting cells
undefined in both dangerous directions — any-non-200-is-failure false-pages on
every restart, and non-200-is-skip goes permanently silent if the route ever
404s. Through the door leg A will meet all of these:

| Observed | Action | Why |
|---|---|---|
| 200, tool present, providers 200 | healthy, reset counter | — |
| 200 but tool **missing**; or providers **500** | **alert** | the failure we exist to catch |
| `000` / timeout / **502** / **503** | **skip**, do not reset the counter | door or anchor down — `opencode-serve-canary`'s jurisdiction, and it already pages |
| **401**, **404**, any other | **distinct alert**: "canary cannot evaluate" | these never self-heal. A vanished `experimental/` route (8-hourly upstream bumps) must not read as health |

**Threshold 7 consecutive, not 3.** The post-boot catalog/credential burn runs
~5-6 minutes, and `opencode-serve-canary` sits at `THRESHOLD=7` for exactly
this reason (`configuration.nix:988-1000`, bead `workstation-g3iy`) — a
threshold of 3 (~3 min) would false-page on every normal anchor restart, and
`/config/providers` *is* the provider catalog, i.e. the very thing being burned
in. Matching 7 keeps margin while still catching a permanent fault. A canary
that cries wolf during routine restarts trains the operator to ignore the
channel, which `configuration.nix:1034-1038` documents as worse than a missed
alert.

## Leg B — log tail, host-wide

Reads `~/.local/share/opencode/log/opencode.log`. Verified today: **668MB, one
shared append-only file, actively written, no rotation configured** (the repo's
only `logrotate` unit covers a different file, the LLM audit log).

**Detection is edge; alerting is level.** This split is the fix for the
revision-1 defect and is the single most load-bearing decision in the design.
(Measurement above sharpens *why* detection is edge: the line is written once per
directory App init, not once per boot, so it can appear at any moment and will not
be repeated on a schedule.)

1. Read new bytes since the stored offset. **Advance the offset only as far as
   the last newline** — the file is appended by many processes, so a read can
   catch a partially-flushed final line; advancing to raw EOF would leave the
   next pass reading a fragment that can never match, and the miss would land
   precisely on lines written during a serve start, which is when error lines
   are written.
2. For each match, extract the plugin basename from the line's
   `path=file:///...` field and **write a latch file** under
   `$STATE/latch/<basename>` recording first-seen epoch, the `run=` id, and the
   line excerpt.
3. **Only then** advance the offset. Latch-before-advance means a crash or a
   pigeon outage cannot consume the evidence.
4. **Every subsequent pass re-invokes `driftAlert` for every live latch**, not
   only for new matches. This is what makes the throttle's documented behaviour
   — hourly nag, backoff to 6h, escalation to `error` on the third — actually
   happen, and it makes a failed POST retry for free on the next pass instead of
   being swallowed forever.

**First run initialises the offset to EOF and scans nothing.** The file holds
~2500 historical matches; a scan-from-zero detector is unconditionally red on
its first pass and would be switched off within a day. **Accepted bound:** if
the pool restarts with a broken plugin *before* the canary's first pass (deploy
ordering, or a state-dir wipe), those lines predate the EOF mark and leg B is
blind to them until the next serve start re-logs — ≤24h via the nightly reset,
with leg A covering the LOUD shape and `self-compact.js` meanwhile. This is why
the Telegram fire drill must run **after deploy against live state**, not only
in a scratch dir.

**Anchored pattern, with the reason beside it** so nobody "simplifies" it:
`^timestamp=\S+ level=ERROR .*failed to load plugin`. A bare `grep level=ERROR`
matches INFO permission-audit lines that quote command text — this has already
produced false positives twice, once after the author had explicitly warned
about it.

**The pattern is pinned, because it is upstream's internals, not ours.** The
message string and the `path=` field shape belong to opencode's loader, and
`opencode-patched` auto-bumps **every 8 hours** — the exact cadence that rotted
the original `LOADER_VERSION` pin. If upstream rewords the line, leg B goes
blind silently while test fixtures carrying the old string stay green: the
file-general leg, sole cover for eight of nine files, dying invisibly. So the
pattern and the extraction format live in fixtures coupled to the existing
`LOADER_SEMANTICS_PIN` / `test-loader-pin.sh` machinery, so a version bump
forces re-verification against the fork's actual `logError` call site. Step 3
then strengthens this: once our own patch emits the line, the format is ours and
pinned by us.

**Latch clearing is manual, deliberately.** The alert text carries the exact
`rm` command. Auto-clearing requires proving a plugin *now loads*, which is
precisely the per-plugin success signal that does not exist until step 3 — and
every cheap proxy for it (file mtime changed, leg A green, no recurrence) can
clear a latch while the plugin is still broken, because a serve that has not
restarted yet logs nothing either way. A latch that errs toward nagging is the
correct direction for a fault class whose precedent went unnoticed for 32 hours.
Step 3 makes real auto-clear trivial.

## Alerting

Reuse `pkgs/opencode-drift-alert` — the repo's one canonical human-notification
path (pigeon `/alert` on `:4731` → Telegram), already used by five call sites.
Journal-only warnings are documented there as insufficient: 1363 went unread
over 23h.

`driftAlert STATE_FILE SIGNATURE TEXT 3600 21600` — first alert immediate, nag
hourly, backing off to 6h, escalating to `error` on the third. Proportionate to
a fault that needs a human to edit a file and restart a serve.

Signatures are the *identity of the failure*, never the time or the port:

| Leg | Signature |
|---|---|
| B | `plugin-canary:load-failed:<basename>` |
| A | `plugin-canary:tool-missing:self_compact_and_resume` |
| A | `plugin-canary:providers-unhealthy` |
| A | `plugin-canary:cannot-evaluate:<status>` |

Per-file signatures on leg B give the property we want in both directions: a
persistent failure of one file backs off instead of paging every minute, while a
*second* file failing is a new signature and pages immediately rather than being
swallowed by the first one's backoff. A loader-wide breakage therefore pages up
to nine times at once — accepted, because that is genuinely nine failures.

**Alert texts embed the remediation commands**, as the serve-canary's do
(`configuration.nix:1344-1346`). With a backoff floor measured in hours, a page
whose reader has to reconstruct the fix is a page half-wasted.

## Unit shape

System unit `opencode-plugin-canary` in `hosts/cloudbox/configuration.nix`,
`User=dev` (it reads dev's log and probes the door), `Type=oneshot`,
`StateDirectory=opencode-plugin-canary`, timer `OnCalendar="minutely"`,
`AccuracySec="15s"` — matching the four existing cloudbox canaries.

**Detect-only. It never restarts anything.** A restart cannot fix a bad plugin
file, and a restart loop here would fight `opencode-serve-canary`, whose
contract is restart-the-wedged. Separate unit for the same reason: two different
contracts should not share a script.

**Skips while `/tmp/reset-workspace.lock` is held**, exactly as
`opencode-serve-canary` does (`configuration.nix:1006-1013`). The skip must
happen **before any state mutation** — in particular before the offset is
advanced — so that error lines written during the reset are read on the first
post-lock pass rather than skipped. `test.sh` asserts that ordering.

**`OnFailure=` → `driftAlert`.** Three lines, and it covers the
script-dies half of "nothing watches the watcher". A canary that crashes silently
is this bead's own failure mode.

## Testability

This bead exists because a guard was verified in the wrong role, and its own
roadmap then shipped a *second* guard wired to nothing. So:

- The fiddly logic — offset/rotation arithmetic, the last-newline rule, first-run
  EOF, latch lifecycle, signature extraction, the anchored pattern, the
  status→action table — goes in a **sourceable bash library** with a `test.sh`,
  following `pkgs/opencode-store-prefix-sh` exactly, and is **wired into `nix
  flake check`**. Unwired tests are documentation with a shebang; #292 landed
  today for exactly that reason.
- Required test cases, each corresponding to a defect found in review:
  - pigeon returns 500 at the moment of detection → the alert is still delivered
    on a later pass (the revision-1 killer);
  - a match split across two reads → still detected once the line completes;
  - rotation by inode change **and** by truncation → offset resets, no miss;
  - first run → offset lands at EOF, history not scanned;
  - lock held → no state mutation at all;
  - each row of the status→action table;
  - dispatch for both probe routes is `forward-anchor`.
- Unit tests are necessary and **not sufficient**, because that is this bead's
  entire lesson. Also required before calling the step done:
  1. **Three controls** on a scratch serve (`XDG_DATA_HOME` redirected, or the
     control poisons the log the detector reads): (a) clean start is silent;
     (b) a deliberately broken plugin raises the alert; (c) an **import-time
     throw** — record what is actually observed, since the prediction is that no
     line appears at all.
  2. **A real fire drill of the delivery path, post-deploy on live state**:
     provoke a latch and confirm the message arrives in Telegram, then confirm
     the nag re-fires. A detector whose last mile is untested is a detector that
     does not exist.

## Rejected

- **A marker tool per plugin** (so leg A could prove all nine loaded). Eight
  no-op tools would enter the tool list of every prompt on the machine — a
  permanent token tax on every session for the canary's convenience.
- **Driving `shell.env` via `POST /session/{id}/shell`.** Creates a session per
  probe: 1440/day into a database we already fight for size, and `session-path`
  routing reintroduces the attribution problem leg A avoids.
- **`opencode debug info`** as a load-check. It lists *configured* plugins, not
  *loaded* ones — it reports success for a file the loader rejected
  (`opencode-config.nix:598`). The most tempting wrong simplification here, so
  it is named in a comment in the script.
- **Auto-clearing latches on inference** — see above.

## Known gaps

- **macOS has no canary** and deploys these same nine files. Step 3 is its only
  cover. Restated so it is not mistaken for covered.
- **The shared blind cell** (non-logging failure in the eight unprobed files);
  step 3.
- **A masked timer is still invisible.** `OnFailure=` covers a crashing script,
  not a disabled unit. Follow-up bead.
- **If logrotate is ever configured for this file** and runs inside the nightly
  reset window, it can eat per-start error lines between the last offset and the
  rotation while the canary is lock-skipped. A comment goes at the would-be
  logrotate site. (No rotation exists today; that this 668MB file grows unbounded
  is its own follow-up bead.)

## Amendment this forces on step 3

Step 3 patches the loader. It should also make the loader **log a structured
per-plugin line on both success and failure**, including the import-time throw it
currently swallows. That is a few lines in a patch we are already writing, and it
converts "no positive signal exists" from a fact of nature into a temporary
condition — after which leg B can assert *presence* per file, latch clearing
becomes automatic, and the blind cell closes. It is the cheapest per-file
coverage available anywhere in this roadmap. Step 3's acceptance criteria must
name it.
