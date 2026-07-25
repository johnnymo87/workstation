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
