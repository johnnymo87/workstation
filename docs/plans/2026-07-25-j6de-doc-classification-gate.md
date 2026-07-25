# j6de — `/doc` classification gate + denial-disposition gate

Status: **DESIGN — ready for SDD.**
Bead: `workstation-j6de` (P1). Closing-plan **item 2 of 5** (`docs/plans/2026-07-24-frontdoor-remaining-roadmap.md`, "CLOSING PLAN").
Predecessor: item 1 = `workstation-sq1v` (DONE, deployed, verified 2026-07-25).

## Purpose

End the discover-a-broken-route-per-incident loop by converting the door's
hand-maintained `routes.classification.ts` from an *assertion* into a **checked
invariant**, and by forcing every denial to carry a written decision.

Two checks, per the fable review of the closing plan (Correction 4). Shipping
only Check A does not end the loop.

---

## Empirical findings (verified THIS session against the PINNED rev — do not re-derive)

All of the following were established by running the pinned store-path binary
`/nix/store/niqliars0nacijlzc7ma2bxmh60sappn-opencode-patched-1.17.13.4`, **not**
`~/projects/opencode` (1.15.10) and **not** the live pool.

1. **The pinned binary boots in an isolated env and serves `/doc`.** With
   `HOME`/`XDG_*` pointed at a scratch dir and a scratch cwd, `opencode serve`
   answers `GET /doc` → 486584 bytes.
2. **It also boots inside the nix build sandbox** — verified with a real
   `runCommand` probe: byte-identical `/doc` (486584). Loopback works; **no
   network access is required**. This retires the feasibility risk implied by
   `default.nix:46-47` ("the hermetic sandbox forbids" socket binds) — that
   comment is about the *vitest* suite, and does not generalise.
   *Gotcha:* the store path must be a real dependency (`builtins.storePath`), or
   it is not mounted into the sandbox and the build fails with `No such file or
   directory`.
3. **`/doc` shape:** 169 declared paths → **195 path × method** pairs
   (118 bare + 51 `/api/*`).
4. **`/doc` does not declare `/doc`** — confirms the `FABLE-W6` manual-entry note
   at `routes.classification.ts:120`.
5. **`/auth/{providerID}` is `DELETE, PUT` only** — independently re-confirms the
   fable CORRECTION that `POST /auth/{providerID}` is a *phantom* route. Do not
   add a table row for it.
6. **Check A is green today:** all 195 path × method classify to something other
   than `unrecognized`.
7. **Check A has real detection power** (mutation-tested, discipline #2): with the
   4 session-scoped permission/question rows deleted from a *throwaway copy* of
   the built table, the gate reports exactly those 4 as `unrecognized`. **It would
   have failed the Phase 9 deploy.**
8. **The TUI SDK surface is NOT mechanically derivable on this box.** This is
   what forced the Check B redesign (below):
   - `~/projects/opencode-patched` is a **patches-only** repo (`patches/`,
     `docs/`, `README.md`) — there is no TUI/SDK source tree for 1.17.13.
   - `bin/opencode` is a *wrapper script*; the real binary is
     `bin/.opencode-wrapped` (167 MB). It **does** embed ~113 route literals, but
     those are the **union** of server-registered and SDK-client routes — there is
     no way to isolate "routes the interactive TUI calls".
   - So `2026-07-24-phase9-door-route-allowlist.md:17` exists as **prose only**,
     and cannot be regenerated or validated here.
9. **Denial census over `/doc`** (the Check B workload): **77 denial rows**,
   **70** after collapsing `/api/*` mirrors:

   | count (de-duped) | class | disposition style |
   |---|---|---|
   | 47 | `global-sideeffect` | **per-route** (this is the D4-relevant class) |
   | 13 | `tui` | class-level blanket (501 by design, Task 5.1) |
   | 8 | `pty` | class-level blanket (501 by design, Task 5.1) |
   | 1 | `global-event` | per-route (410; the D6 note) |
   | 1 | `per-process-ro` | per-route (501; F3) |

10. **The census is itself informative.** The `global-sideeffect` set contains
    global variants of routes the TUI *does* call, whose session-scoped
    equivalents are already forwarded — `POST /sync/start`,
    `POST /permission/{requestID}/reply`, `POST /question/{requestID}/reply`,
    `POST /question/{requestID}/reject`. Their correct disposition is
    "superseded by session-scoped route X", which is knowledge the table does
    not currently record anywhere.

## Wiring facts

- `opencode-frontdoor` is `pkgs.callPackage`'d **twice**, independently:
  `hosts/cloudbox/configuration.nix:53` (for the systemd unit,
  `ExecStart` at `:1382`) and `flake.nix:62`.
- The **pinned opencode lives in home-manager**, not NixOS:
  `users/dev/home.base.nix:274-325` (`patchedRevision = "4"`,
  `opencodePatchedHold = "1.17.13"`).
- **Do not relocate that derivation.** `.github/workflows/update-opencode-patched.yml`
  edits `home.base.nix` in place to bump the pin and its four platform hashes;
  moving it would break automated pin bumps.

---

## USER DECISION (2026-07-25): Check B is scoped **B1**

Given finding 8, the user chose **B1 — disposition every `/doc` denial** over
transcribing the prose TUI list.

Rationale: B1's input is `/doc` (already fetched for Check A), so it is
**self-maintaining and tracks pin bumps automatically**, whereas the fable-specified
TUI list would introduce a *new hand-maintained table* — the exact failure mode
this gate exists to kill — with nothing on this box to validate it against.

**State the claim honestly (discipline #2).** B1 is a *superset* of the TUI surface
by coverage, but it is a **weaker** claim by intent than fable's spec:

- B1 **does** guarantee: no route may land in a denying class without a written
  decision. A pin bump that adds a denying route fails the build, forcing the
  "does the TUI need this?" question **at bump time** — which is exactly when
  Phase 10 was born.
- B1 **does not** know the TUI's needs. It cannot detect that an *existing*,
  properly-dispositioned denial is one the TUI has started needing. Closing
  existing gaps is D4's job (item 3), not this gate's.
- Corollary: a lazy blanket disposition would keep the gate green while the TUI
  stayed broken. The enum below exists to make each decision cheap but explicit,
  and to keep the D4 backlog machine-readable rather than prose.

---

## Design

### Check A — `/doc` × `classify()` → fail on `unrecognized`

Boot the **pinned** binary (never the live pool), fetch `/doc`, enumerate
path × method, run each through the door's real `classify()`, fail on any
`unrecognized`, printing every offender.

### Check B — every `/doc` denial must carry an explicit disposition

New artifact `pkgs/opencode-frontdoor/src/routes.dispositions.ts`:

- **Class-level blanket dispositions** for `pty` and `tui` (21 rows) — both are
  documented-by-design 501s; a per-route rationale there would be pure ceremony.
- **Per-route dispositions** for `global-sideeffect`, `global-event`,
  `per-process-ro` (49 rows), each a small structured record, not free prose:

  ```ts
  type DispositionKind =
    | 'tui-unused'          // not called by the interactive TUI
    | 'superseded'          // a session-scoped route serves this need (name it)
    | 'denied-by-design'    // TUI may call it; denial is correct; degrades gracefully
    | 'needs-mechanism'     // D4: anchor-pin / broadcast required (bead ref required)
    | 'accepted-gap';       // known gap, consciously accepted (bead ref required)
  ```

  `needs-mechanism` and `accepted-gap` **require** a bead reference; `superseded`
  **requires** naming the superseding route. This makes "D4 complete" computable
  rather than asserted.

Check B fails if any `/doc` denial row has neither a class-level nor a per-route
disposition, listing each.

**Scope note:** Check B covers `/doc` rows — the surface that can *change* under a
pin bump. Table-only entries (e.g. the manual `GET /`) are static and out of
scope; record that as a residual.

### Wiring (fable's required constraint)

A nix **check derivation** taking **both** the pinned opencode store path **and**
the door's classification source. Any change to either changes its drv hash, so it
re-runs.

**Attach it to the home-manager closure** (`home.base.nix`), because that is the
only closure that sees pin bumps, and `pull-workstation` runs
`home-manager switch` every 4h — the strongest automatic trigger available.

**Do NOT wrap the frontdoor package to force the gate.** The door self-reports its
store path via `/healthz`, and the drift canary
(`configuration.nix:1293-1308`) compares that against the unit's `ExecStart`. A
wrapper would make `ExecStart` and the reported path differ permanently → a
**false drift alert forever**. Force the build via the closure instead.

**Also invoke the gate from `test.sh`** for a pre-deploy dev signal. Fable's
constraint is that it must not live *only* in `test.sh`; both is strictly better,
and it mitigates the ordering gap below.

**Accepted residual (ordering).** The canonical runbook is
`nixos-rebuild` → restart door → `home-manager switch` → restart pool. So a
*door-source-only* change is deployed and the door restarted **before** the
home-manager closure builds the gate. The `test.sh` invocation is the pre-deploy
mitigation; the closure is the mechanical backstop (≤4h via `pull-workstation`).
Closing this properly would require the pinned opencode in the NixOS closure,
which finding "Wiring facts" rules out for now.

**Accepted residual (blast radius).** A failing gate fails `home-manager switch`,
which `pull-workstation` retries every 4h — blocking *unrelated* home-manager
changes until the table is fixed. That is the intended fail-closed behaviour, but
name it so it is not a surprise.

### Bookkeeping

- Update the reconciliation header (`routes.classification.ts:4-9`) to state that
  the gate **supersedes `routes.snapshot.txt`'s reconciliation role** — so nobody
  hand-reconciles counts again (closing-plan bookkeeping item).
- Record in the bead that Check B's honest claim is the narrower one above.

## Verification plan

1. `npm run build && npm test` in `pkgs/opencode-frontdoor` — baseline 297 green.
2. Unit tests for both checks, including **negative** cases.
3. **Mutation-test each check individually** (discipline #1 — do NOT generalise a
   single verification across both):
   - Check A: delete a table row → gate must name that route.
   - Check B: delete one disposition → gate must name that route.
   - Confirm each mutation is caught by the *intended* check, and that the suite
     is RED under each mutation and GREEN with both restored.
4. Build the nix check derivation for real; confirm it passes.
5. Confirm the derivation **re-runs** when either input changes (perturb the door
   source, observe a new drv hash).
6. State explicitly what each check would have caught (Phase 9 = A; a future
   pin-bump denial = B) and what neither catches (existing TUI-needed denials → D4).

---

## OUTCOME (implemented 2026-07-25) — NOT yet deployed

Commits: `52b9f83` (Check A), `866634a` (pin-duplication fix + wiring),
`cb8854e` (Check B), `820a01a` (fabricated-supersession fix). Suite **312 green**
(baseline 297).

### Deviation from the design above
The draft enum included **`tui-unused`**. It was **dropped**: on this box that
claim is *unfalsifiable* (finding 8), so it would have been decoration. Replaced
with **`not-session-scopable`**, which asserts something about the door's
architecture that can actually be reasoned about. Final kinds:
`by-design-501`, `not-session-scopable`, `superseded`, `needs-mechanism`,
`accepted-gap`.

Census as dispositioned (70 de-duplicated): 21 `by-design-501` (class blanket for
`pty`/`tui`), 34 `not-session-scopable`, 11 `needs-mechanism` (all
`workstation-mlve.11` — these ARE the D4 rows), 3 `superseded`, 1 `accepted-gap`.

### Two defects found in review — both instructive
1. **A duplicated pin (critical, would have made the gate silently wrong).** The
   Check A implementation added `pkgs/opencode-patched/default.nix`, a second copy
   of the pin, and fed the gate from it. Since
   `update-opencode-patched.yml` edits **only** `home.base.nix`, the next
   automated bump would have left the gate validating the OLD binary while the
   pool ran the NEW one — green and wrong, at exactly the moment the gate exists
   for. Fixed by deleting it and instantiating the gate against the in-scope
   pinned `opencode` in `home.base.nix`.
2. **A fabricated supersession, and it was MY fault.** I asserted in the task
   prompt that `POST /sync/start` was superseded by a session-scoped route; the
   subagent invented a rationale to satisfy the premise rather than pushing back.
   There is no session-scoped sync route at all. Now `accepted-gap` +
   `workstation-mlve.11`, because `sync.start` *is* in the TUI SDK surface and
   the Phase 9 audit only checked 404s, never 403s — so the through-door
   consequence is genuinely unverified.

**Recorded limit of Check B (from defect 2):** it validates a `supersededBy`
target *structurally* (exists, non-denying) and therefore **cannot** detect a
semantically nonsensical pairing. The bogus entry passed the gate.

### Also fixed during review
- `test.sh` hardcoded a **third** copy of the pin as a literal store path, and
  **silently skipped** the gate (warning + exit 0) when it was absent — a gate
  that no-ops while reporting success. Now resolves via the profile and fails loud.
- Poll bounds widened `10x0.2s` → `120x0.5s` with early-exit detection, in both
  `test.sh` and `route-gate.nix`. A flaky gate trains people to ignore it.
- Corrected an overclaim in the new reconciliation header: it said the gate runs
  "during build and CI". **There is no CI job for this gate.**

### Verification actually performed (each individually, not generalised)
- Check A detection power, re-proven against the **rewritten combined** gate.
- Check B detection power: one disposition deleted → that route named.
- Field enforcement, per requirement: missing `bead`, empty `rationale`.
- Both checks report in one run.
- Wiring, structurally: the gate drv is a genuine **requisite of the
  `home-manager-generation` drv**, so `home-manager switch` cannot succeed without
  building it; both the pinned opencode and the door package are direct drv inputs.
- Wiring, empirically (door leg): perturbing `routes.classification.ts` changes the
  gate's out path.
- **NOT verified:** the pin leg by mutation — that needs real upstream hashes.
  Structural proof only, stated as such.

### Fable review round 2 (post-implementation) — findings and disposition

Verdict: *"Sound with fixes — but one of the fixes goes to the heart of the gate's
promise."* Fable independently re-verified the wiring (both legs), Check B's
detection power, and the pin/profile coherence. Two real holes, both reproduced by
me before acting:

**F1 (HIGH) — template shadowing. FIXED (`6c9909d`).** Deleting the
`GET /session/status` row left the gate **PASSING**: `classify()` falls back to
template regex where `{sessionID}` is `[^/]+`, so `/session/status` silently
matched `GET /session/{sessionID}` and returned `session-path` — the door would
treat `"status"` as a session id. Check A only tested for `unrecognized`, so it
could never trip. The forward direction is the real exposure: a future
`GET /session/search` would be silently misrouted with a green gate — **exactly the
Phase-9 shape this item exists to end.**
Fix: Check A now requires an **exact normalized template match** (`{x}` → `{}`),
reporting `shadowed` as a distinct kind that names the shadowing template. Verified
green today with **zero exceptions** across all 195 rows before landing it. 8 `/doc`
paths are structurally shadow-vulnerable, so this was not hypothetical.

**F2 (MEDIUM) — orphaned dispositions invisible. FIXED (`6c9909d`).** A disposition
for a nonexistent route left the gate passing; nothing checked the inverse
direction. Worse, a route moving between denying classes under a bump would keep a
stale disposition and still pass. Fix: every `ROUTE_DISPOSITIONS` key must match a
live `/doc` denial. Zero allowlist entries needed.

**F3/F4/F5 — `not-session-scopable` was doing too much work. FIXED.** It conflated
"the TUI never calls this" with "the TUI calls this and nobody checked". Added a
**required `tuiSurface: 'absent' | 'degrades' | 'unverified'`** field, deliberately
defined as a *documentary* claim about membership in the TUI SDK surface list
(`2026-07-24-phase9-door-route-allowlist.md:17`) — checkable against a specific
line — rather than an unfalsifiable behavioural claim. Split: 21 `absent`,
6 `degrades` (Phase-9-audited, now citing `:35`), 5 `unverified`.

**Three more of my own wrong premises, same shape as the `/sync/start` error.**
Partitioning for F4 surfaced that I had asserted these in task prompts and they
were wrong:
- `POST /mcp/{name}/connect` and `POST /mcp/{name}/disconnect` were marked
  `needs-mechanism` (D4). **Phase 10 already solved them** via forwarded
  session-scoped routes (`routes.classification.ts:207-208`) — and the roadmap's D4
  list deliberately omits them. Now `superseded`.
- `GET /mcp` is likewise `superseded` by the patch-added
  `GET /session/{sessionID}/mcp`.
- `GET /global/event` was `not-session-scopable` while its own rationale named its
  successor. Now `superseded` by `GET /event`.

`needs-mechanism` now contains **exactly the 9** roadmap D4 rows, asserted by test.
So **"D4 complete" is computable**, and item 3 inherits a machine-readable 15-row
list (9 `needs-mechanism` + 5 `unverified` + 1 `accepted-gap`) instead of prose.

Final census (70 de-duplicated): 21 `by-design-501`, 32 `not-session-scopable`
(21/6/5), 7 `superseded`, 9 `needs-mechanism`, 1 `accepted-gap`. Suite **323 green**.

### Corrections to earlier claims in THIS document (fable W1-W3)

- **W1.** "Check A: delete a table row → gate must name that route" was **true only
  for the rows I happened to test, and false in general** until F1 was fixed. The
  rows I mutated were not shadowed. The property I proved was "these rows are
  caught"; I generalised it to "any row". This is the *same* over-generalisation
  error as the previous item, in a new costume — the lesson did not fully take.
- **W2.** The deviation note recorded dropping `tui-unused` but silently dropped
  **`denied-by-design`** too, which discarded the one bit D4 most needs (TUI calls
  it but degrades). Now restored as `tuiSurface: 'degrades'`.
- **W3.** "B1 forces the *does the TUI need this?* question at bump time" needs two
  exceptions to be true: new routes landing in a **blanketed class** (`pty`/`tui`)
  are auto-covered with **zero** human decision, and shadowed routes never reached
  Check B as denials at all (F1). With F1 fixed and those exceptions stated, the
  claim holds.

### Accepted / deferred from fable round 2

- **F6 — fail-closed is currently fail-*silent*-closed.** `pull-workstation` is
  journal-only and there is no `OnFailure=` anywhere in the repo, so a firing gate
  could block all home-manager changes for days before anyone noticed — which is
  precisely when a gate gets disabled in anger. Telegram plumbing already exists.
  **Deferred to its own bead**, to be done before the gate first fires for real.
  Fable also credited two mitigations I had undersold: `opencodePatchedHold` means
  auto-bumps only track self-cut releases (human in the loop), and a failed switch
  also withholds the new binary from the pool, so gate-vs-pool coherence is
  preserved — fail-closed is *correct*, not merely tolerable.
- **F7 minor, deferred:** `head`/`options`/`trace` in `/doc` are skipped (empty set
  today); `--min-routes` `parseInt` NaN is unguarded; the fixed-port comment should
  state its `sandbox = true` assumption; and the gate validates the *HM-closure*
  build of the door while the deployed door is the *NixOS-closure* build (same
  source at the same commit, so benign — an unstated cousin of the ordering residual).
- **Fable's framing worth keeping:** *the gate proves the table, not the door.* A
  correctly classified route can still break through the door (sid-resolution
  degrade, child-routing). That is outside this item by construction.

### Fable review round 3 (delta pass over `2a34e48..HEAD`) — PASSED

Round 2 reviewed `2a34e48`; the fixes for its own findings landed in four later
commits and were therefore unreviewed (and by then deployed). Round 3 closed that
gap. Verdict: **deltas sound, no redeploy warranted.**

**F1 genuinely closes the hole, in both directions.** Fable mutation-tested the
*forward* case I could not: adding `GET /session/search` to `/doc` → fails as
`shadowed` naming `GET /session/{sessionID}`; adding a non-shadow-shaped route →
fails as `unrecognized`. It also probed for cry-wolf risk and found none — renaming
a path parameter (`{sessionID}`→`{id}`), the commonest cosmetic upstream churn,
**passes**, because `{x}`→`{}` erases names by design. Every failure it could
construct corresponds to a change genuinely requiring a table decision.

Also independently re-derived and confirmed: all 32 `tuiSurface` assignments
(21/6/5), the four supersessions against the roadmap D4 list, `/api`-vs-bare
disposition fallback, and that the fixture is **byte-faithful** to the live `/doc`
(identical 195 pairs; the real `/doc` has no non-method pathItem keys, so the
projection drops nothing the gate reads).

**Why no redeploy** (fable's structural argument, verified by me): nothing in
`2a34e48..HEAD` touches the door's request path. `routes.classification.ts` — the
only table `dispatch.ts` imports — is unchanged in the range, and `route-gate.ts` /
`routes.dispositions.ts` are imported by nothing reachable from
`main.ts`/`server.ts`/`proxy.ts`. The running door is functionally identical to the
reviewed state. (It will still need a restart at the *next* rebuild, since the
package hash changed — which is why M1 below folds into `m3z2`, whose door restart
is required anyway.)

**M1 (the one real finding) — "D4 complete is computable" is `test.sh`-scoped, not
closure-enforced.** The census, the 9-row `needs-mechanism` pin, and the
`tuiSurface` counts live **only in vitest**, which the authoritative gate never
runs: `default.nix` sets `doCheck = false` and `route-gate.nix` runs only the CLI
check. So the nix gate enforces disposition *presence and field validity*, but not
*kind sets* — a disposition edit flipping `needs-mechanism` → `accepted-gap` would
pass `home-manager switch` untested and the 9-row assertion would drift silently
until someone ran `./test.sh` by hand.
**Correction to record:** the claim above that "D4 complete is computable" is true
of the codebase but enforced only on a voluntarily-run leg. **Folded into `m3z2`**:
move a kind-census assertion into the CLI gate (which already walks every denial,
so it has the data), making the claim closure-enforced.

Recorded only (all bookkeeping-rot vectors, no runtime risk):
- **M2** — F2's "matched" means *key exists and route is denied*, not *actually
  consulted*. A route-level disposition shadowed by a class blanket (e.g.
  `GET /pty`) is never consulted yet not flagged orphaned. Likewise a route that
  stays denied but migrates between denying classes keeps a now-mislabeled
  disposition; there is no kind↔action consistency check.
- **M3** — there is no inverse Check A. Upstream *deleting* a forwarded route leaves
  a stale table row and a green gate. Loud at runtime (door forwards, serve 404s)
  rather than silently misrouting, and it predates this delta — but the asymmetry
  is conspicuous next to F2.
- **M4** — `tuiSurface` is typed optional with runtime enforcement; a discriminated
  union on `kind` would enforce it at compile time *and* reject a meaningless
  `tuiSurface` on a `superseded` row (currently unchecked in both directions).
- **M5** — structural matching cannot see semantics: a future route whose normalized
  shape collides with an existing template (`GET /session/{query}` with non-sid
  meaning) exact-matches and passes. Irreducible; the genus is already covered by
  *the gate proves the table, not the door*.

### Residuals
- Ordering: a door-source-only change is deployed *before* the home-manager
  closure builds the gate (runbook order). `test.sh` is the pre-deploy mitigation.
- Blast radius: a failing gate fails `home-manager switch`, retried by
  `pull-workstation` every 4h, blocking unrelated home-manager changes. Intended
  fail-closed behaviour, named so it is not a surprise.
- No standalone `nix build` target for the gate (would require a second pin copy).
  A `pin.nix` single-source refactor would restore it, but it touches the
  load-bearing updater — deliberately deferred.
- Check B covers `/doc` rows only; table-only entries (e.g. manual `GET /`) are
  static and out of scope.

## Out of scope

- Fixing existing denials that the TUI needs → **item 3 / `mlve.11` (D4)**.
- The prose TUI-surface list → deliberately not transcribed (finding 8 + B1).
- Running the gate against **live** serves as a skew detector → nice-to-have the
  roadmap mentions; not required here, and the drift canaries already cover skew.
