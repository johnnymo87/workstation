# m3z2 — HTML-poison guard (+ M1 kind-census fold-in)

Closing-plan item **4** (`docs/plans/2026-07-24-frontdoor-remaining-roadmap.md`), taken
ahead of item 3 (`mlve.11`/D4) deliberately: the diagnostic guard should exist *before*
the risky D4 mechanism work, so a skew failure during it surfaces legibly.

Baseline: HEAD `1a53ca4`, suite 323 green, door live on
`/nix/store/pjbxhdjw71178kj84vzrmxp2gsnpmx2j-opencode-frontdoor-1.0.0`.

Two deliverables: the poison guard, and fable-round-3's **M1** (move the D4 kind census
from vitest into the CLI gate). They batch because both change frontdoor `src/`, and any
such change needs an explicit door restart that drops every in-flight SSE leg — so
landing them together costs one restart instead of two.

---

## 1. Premises, verified before designing

Every claim below was checked against the deployed rev, because the dominant failure mode
of the previous item was *my own wrong premises* (five of them), not bad code.

| # | Claim | Verdict |
|---|---|---|
| P1 | An unknown API route on a live serve returns the SPA fallback | **TRUE.** All four serves (`:4096-4099`) return `200`, `Content-Type: text/html`, 2884 bytes, `<!doctype html>` for `GET /session/ses_totallyfake/nonexistentroute`. |
| P2 | Session-path routes legitimately return JSON | **TRUE.** Probed 8 session-path routes on a live sid: all `application/json`. |
| P3 | `text/html` is never a *legitimate* response anywhere on the surface | **TRUE ONLY OF DECLARATIONS — see the P6 correction below.** The live `/doc` *declares* 518 responses: `application/json` ×512, `text/event-stream` ×4, `text/x-diff; charset=utf-8` ×1, `application/octet-stream` ×1, and `text/html` zero times. `/doc` is authoritative about what routes **declare**, and says nothing about what they **return at runtime**. |
| P4 | OAuth callback routes return HTML (my initial worry, which would have blocked a broad guard) | **FALSE.** `POST /provider/{providerID}/oauth/callback` and `/mcp/{name}/auth/callback` both declare `application/json`. My hazard was imaginary — caught by checking instead of asserting. |
| P5 | The live anchor's route surface equals the pinned build's | **TRUE.** Live `/doc` and the committed fixture have identical 195 path×method pairs, so the media-type census above describes the pinned build. |
| P6 | `GET /api/fs/read/*` streams raw file bytes, so reading an `.html` file could legitimately yield `text/html` | ~~FALSE — it declares `application/octet-stream`.~~ **P6 WAS RIGHT AND MY REFUTATION WAS WRONG. This is premise error #6, and the only one that reached shipped code.** See §2.5. |

**A near-miss worth recording:** my first probe hit ports `46091/46095` and showed
`404 application/json` — i.e. "the SPA fallback doesn't exist, this whole item is moot."
Those were unrelated ports; the pool is on `4096-4099`. I was one step from writing a
confident "this reframes the item" note off a **vacuous probe**. This is discipline note
#3 ("ask whether a test has detection power") catching a live error, not a hypothetical.

## 2. CORRECTION: the guard does not prevent the frozen TUI

The closing plan says item 4 makes skew *"degrade to a clean error instead of a frozen
TUI"*, and demotes Part B (reconcile hardening) because the guard *"covers the same
user-visible harm at the door for less"*. **Both statements are false**, verified in the
deployed patch source (`opencode-patched/patches/tui-door-attach.patch:192-204`):

```js
const reconcilePending = async () => {
  if (!activeSessionID) return
  await Promise.all(sessionIds.map(async (sid) => {
    const perms = await sdk.session.permissions({ sessionID: sid })
    if (perms.error) throw perms.error        // <-- ANY error throws
    const quests = await sdk.session.questions({ sessionID: sid })
    if (quests.error) throw quests.error      // <-- ANY error throws
    ...
  })))
}
```

The patch's own comment states the mechanism: *"Throwing ends the attempt so the caller
reconnects and retries the reconcile (with backoff)."* The bricking condition is **any**
reconcile error, not specifically a parse error. So a JSON 502 sets `.error` → `throw` →
attempt ends → reconnect → 502 again → **the identical infinite reconnect**. Part B was
written to bound exactly this, and it was never cut (`tui-door-attach.patch` still carries
the unbounded form; no `patched.4` reconcile change).

Fable's Correction 3 was directionally right but understated it: the "non-HTML residual"
is not a leftover corner, **it is the guard's own output.** The guard converts every HTML
case *into* the residual case.

**What the guard therefore does and does not buy:**

- ✅ **Diagnosability.** The door logs a precise, actionable diagnosis and returns a
  structured body naming cause and remedy, instead of an opaque parse blowup. Incident #2
  cost ~70 minutes of hand-debugging while a correct machine diagnosis sat unread; this is
  the same lesson.
- ✅ **Non-TUI clients** (curl tooling, `lgtm-sessions`, scripts, subagents) get a
  machine-readable failure instead of an HTML page they would mis-handle.
- ✅ **Collapses two failure shapes into one**, leaving a single structured-error mode for
  a future Part B to bound — it makes Part B *simpler*, not redundant.
- ❌ **Does NOT un-freeze the TUI.** Only Part B does.

**Consequence:** Part B's demotion rested on a false premise and must be re-promoted as
its own bead. The guard and Part B are **complements, not substitutes**. This does not
block m3z2 — the guard is still worth its (already-required) restart — but item 4's
stated rationale is corrected here, and "no more frozen TUIs" is explicitly NOT claimed.

## 2.5 CORRECTION #2 (fable, HIGH): declared ≠ runtime — `GET /api/fs/read/*` really does return `text/html`

I refuted P6 by reading a `/doc` *declaration* and asserting a *runtime* fact. Fable
caught it; I then reproduced it independently through the deployed door:

```
GET /api/fs/read/<repo-relative>.html?location[directory]=... -> 200  Content-Type: text/html   (2884 bytes)
GET /api/fs/read/README.md?location[directory]=...            -> 200  Content-Type: text/markdown
```

The serve derives `Content-Type` **from the file extension at runtime**, regardless of
the `application/octet-stream` it declares. So the widened guard as first written would
have 502'd a legitimate file read, told the user to *"restart the serve pool"* (a remedy
that would not work), and incremented `htmlPoisonBlocked`, corrupting the very skew signal
this item exists to produce.

**Check C structurally cannot catch this class** — the route declares `octet-stream` and
always will. That is a real limit on how much safety Check C buys for §3.1, and the
original §3.1 wording ("widening is *safe*") overstated it.

**Fix (see §3.5):** exempt raw-byte routes, and make the exemption list itself a checked
invariant (Check D) so it cannot rot at the next pin bump.

Blast radius before the fix was nonetheless zero, verified: no workstation client and no
`opencode-patched` patch calls `fs/read` through the door (the TUI reads files via
`/file/content`, which JSON-wraps content at runtime — probed live: `application/json`
even for an `.html` path). Latent, not active.

**The generalisable lesson:** `/doc` answers "what does this route declare?" — never "what
will this route send?". Six of my premises have now been wrong in this work stream, and
this is the only one that made it into shipped reasoning; it did so because a declaration
*looked* like authoritative evidence about behavior.

## 3. Guard design

### 3.1 Scope: every forwarded response, not just `session-path`

The bead specifies `session-path`. I am widening it to **all forwarded responses**, on
evidence:

- The harm is not session-path-specific. Any forwarded route the target serve lacks yields
  the SPA. Narrow scope guarantees a later repeat of the same incident via a new
  global/`experimental` route — this project's whole pathology is "one table discovered one
  incident at a time."
- Widening is *defensible*, but NOT unconditionally safe — see §2.5. Zero routes
  **declare** `text/html` across 518 responses, and the two classes that intentionally
  reach the SPA (`web-ui` at `/`, `unrecognized`) are already 404'd at the door **before**
  forwarding.
- P4 killed the one counter-argument I had (oauth callbacks).
- But declarations are not behavior. Exactly one route serves runtime-typed raw bytes and
  legitimately can return `text/html` (§2.5), so widening REQUIRES the exemption in §3.5.
  With it, the residual risk is a *future* raw-byte route — which Check D converts into a
  build failure rather than a silent 502.

Denied classes (`pty`, `tui`, `web-ui`, `unrecognized`, `per-process-ro`, `global-event`)
never reach an upstream, so they are out of scope by construction.

To keep the widened premise from silently rotting, §4 adds a **gate invariant** that fails
the build if any route ever declares a `text/html` response. That converts "HTML is never
legitimate" from an assumption into a checked fact — the same loop-ending pattern j6de
established. Its limit, learned the hard way in §2.5: it constrains *declared* types only.

### 3.5 Exemption for raw-byte routes, and Check D

`GET /api/fs/read/*` serves arbitrary file bytes with a runtime, extension-derived
`Content-Type`, so `text/html` from it is legitimate data rather than an SPA fallback.
`isHtmlGuardExempt()` (`src/poison.ts`) exempts it, applied in `proxyRequest` only —
`placeAfterCreate` handles just `POST /session` and `POST /session/{id}/fork`, neither of
which is or can be exempt.

A hand-maintained exemption list would rot at the next pin bump, so **Check D** asserts
that the set of routes declaring an `application/octet-stream` response equals
`HTML_GUARD_EXEMPT_ROUTES`, and reports mismatches BOTH ways:

- declared-but-not-exempt → the guard would 502 legitimate bytes;
- exempt-but-not-declared → a stale exemption silently widening the hole.

Why `application/octet-stream` is the right marker: it means "arbitrary bytes", which is
exactly the signature of a route whose runtime type is data-dependent. Contrast
`GET /vcs/diff/raw`, which declares the *specific* type `text/x-diff; charset=utf-8` and
cannot be HTML. Today there is exactly one octet-stream route, and it is the one exemption.

### 3.2 Predicate

`isHtmlResponse(contentType)` — fires iff the media type is exactly `text/html`:

- lowercase, split on `;`, trim → compare to `text/html` (so `text/html; charset=utf-8`
  fires, matching the live header which today carries **no** charset).
- **No prefix matching** — `text/htmlx` must not fire.
- Missing/empty `content-type` → does not fire.
- Array-valued header → use the first element (defensive; Node shouldn't array this).
- **Status-independent.** The SPA arrives as `200`, but `404`+HTML is equally poison.
- `application/xhtml+xml` deliberately NOT matched (not the observed shape; noted as a
  residual rather than speculatively handled).

### 3.3 Insertion points (two, so the invariant has no exceptions)

1. **`proxyRequest`** (streaming; covers `session-path`, `session-query`,
   `forward-anchor`) — inside `upstreamReq.on("response")`, immediately after
   `headersSent = true`, **before** `clientHeaders`/`writeHead`, so no upstream header
   (notably the SPA's `Content-Security-Policy`) is ever forwarded. Drain with
   `upstreamRes.resume()` (matching the existing socket-hygiene comment at `proxy.ts:160`)
   rather than `destroy()`, then `safeResolve()`.
2. **`placeAfterCreate`** (buffered; covers `create`, `fork`) — right after
   `const response = result.response!`, before the status branch. Today an SPA response
   here is *detected* (`"Create response JSON missing session id"`, `degraded = true`) and
   then **forwarded as HTML anyway**; the guard closes that.

### 3.4 Response

`502` + `Content-Type: application/json`, upstream headers dropped:

```json
{"error":"bad_gateway","message":"Upstream returned an HTML page for an API route. The target serve is probably running an older binary that lacks this route; restart the serve pool."}
```

**The body must not name the target serve.** Network opacity is an explicit user
constraint ("I want that to be entirely opaque") — the pool's internals stay out of
client-visible payloads. Full detail (method, path, target URL, upstream status) goes to
the door's own log:

```
[FRONTDOOR WARN] html-poison blocked: GET /session/<sid>/permissions -> <target> returned 200 text/html (stale-serve SPA fallback); returned 502
```

Plus a `Metrics.htmlPoisonBlocked` counter, alongside the existing
`notRoutedMutationToAnchor`, so a skew episode is countable rather than journal-only.

## 4. Check C — `text/html` may never be declared (enables §3.1)

Extend the route gate: census the declared response media types from `/doc` and **fail if
any route declares `text/html`**. Emit the media-type census in the PASS line.

This requires the committed fixture to carry declared media types (it is currently a
paths-only projection, so it cannot see them). Regenerate it from the **pinned** binary,
preserving byte-faithfulness for what the gate reads. Do **not** let the fixture leg skip
this assertion when the data is absent — a skip-on-missing-input is precisely the vacuous
green that discipline note #3 forbids; absence must be a hard error.

## 5. M1 — kind census into the CLI gate

Today the census, the 9-row `needs-mechanism` pin, and the `tuiSurface` counts live only
in `test/route-gate.test.ts:462-561`. The authoritative gate never runs vitest
(`default.nix` sets `doCheck = false`; `route-gate.nix` runs only the CLI), so it enforces
disposition *presence and field validity* but not *kind sets*. A disposition edit flipping
`needs-mechanism` → `accepted-gap` passes `home-manager switch` untested.

Fix, inside `checkDocRoutes` (it already walks every denial, so it has the data):

- Compute a **de-duplicated** kind census (strip the `/api/` mirror, as the vitest test
  does) and expose it as `kindCensus` on `GateCheckResult`.
- Expose `needsMechanismKeys: string[]`.
- Enforce both against exported constants — an exact expected census **and** the exact
  9-key `needs-mechanism` set. The set is the load-bearing one: when D4 lands it shrinks,
  and the gate then *proves* D4 complete instead of asserting it.
- Emit the census in the PASS line.
- Rewrite the vitest census test to assert on `checkDocRoutes()`'s result rather than
  re-implementing the dedup, so the two legs cannot diverge (M2-adjacent hygiene).

Expected census (current, from the fixture): `by-design-501` 21,
`not-session-scopable`/absent 21, /degrades 6, /unverified 5, `superseded` 7,
`needs-mechanism` 9, `accepted-gap` 1 — over 70 de-duplicated denials.

## 6. Test plan — both directions, and prove detection power

Positives (guard fires): html on `session-path`; html on `forward-anchor`; html on
`create`; `text/html; charset=utf-8`; `TEXT/HTML`; upstream `404`+html (status-independent).

**Negatives (guard must NOT fire)** — the direction I under-tested last time, using the
four media types that genuinely occur (P3): `application/json` passthrough unchanged;
`text/event-stream` passthrough with the drift monitor still wired; `text/x-diff;
charset=utf-8`; `application/octet-stream`; `text/htmlx` (prefix-bug guard); missing
`content-type`.

Also: no upstream headers leaked on the 502 (assert the SPA's CSP is absent); the 502 body
does not contain the target URL (opacity); upstream body drained.

End-to-end: the integration harness already stands up real HTTP upstreams
(`test/integration.test.ts` `serverA`/`anchorServer`) and a real door, so the guard gets
tested over real sockets with the **actual captured 2884-byte SPA body** as a fixture — not
a hand-written stub.

Gate/M1: census matches on the fixture; **mutation-test** a kind flip → FAIL; a removed
`needs-mechanism` row → FAIL; a fixture with an injected `text/html` response → Check C
FAIL; missing fixture → hard error, not skip.

## 7. Live verification — stated honestly up front

**The guard cannot be triggered live while the door and pool run the same build.** A route
the door forwards but the serve lacks cannot exist in that state; any "live probe" would be
vacuous, and claiming it as verification is the exact trap from last session. So:

- Live-verified **premise** (already done): all four serves return `200 text/html` on an
  unknown session subpath.
- Guard **behavior** is verified by the real-socket integration tests above.
- Post-deploy live checks are limited to what is real: door healthy, no drift, the
  `htmlPoisonBlocked` counter present and `0`, and no regression on normal traffic.

## 8. Residuals to record on landing

1. **The freeze is not fixed** (§2). Re-promoted as bead `workstation-fdb1`; the guard is a
   complement, not a substitute. Do not let "covers the same harm" imply equivalence.
2. `application/xhtml+xml` and other HTML-ish types are not matched.
3. **Check C constrains *declared* types only — in BOTH directions** (§2.5). A route
   declaring something else while returning HTML at runtime is invisible to it; that is how
   `fs/read` was missed. Check D covers the one known instance of that class by keying on
   the `octet-stream` marker, but a route that declared, say, `application/json` and
   returned HTML at runtime would be caught by neither check — only by the guard firing
   (correctly or not) in production.
4. **`GET /api/fs/read/*` is exempt, so it is unguarded**: if a stale serve SPA-fell-back
   on *that* route, the door would forward the SPA. Accepted: it is one route, no client
   uses it through the door today, and the alternative (502-ing legitimate reads) is worse.

### Fable review round 1 (this change set) — SHIP WITH FIXES, all fixes applied

Verdict was SHIP WITH FIXES on one HIGH (§2.5, the `fs/read` false positive) plus four
lower findings. All are now fixed and each fix was mutation-verified:

| # | Finding | Fix | Mutation proof |
|---|---|---|---|
| F1 | HIGH — `fs/read` returns runtime `text/html`; guard would 502 legitimate reads with a wrong remedy | §3.5 exemption + Check D | removing the exemption fails 9 tests incl. Check D; an over-broad `GET /api/*` exemption fails Check D naming both directions; loosening the matcher so `/api/fs/readsomething` matches fails a test |
| F2 | MED — census enforcement tested only in the GROW direction, so the *shrink* direction (the one that will prove D4 complete) could silently break | added inflated-expectation + extra-key tests | both mutations fable predicted would survive now fail: `expected !== actual` → `expected < actual` fails 2; deleting the `removedKeys` report fails 1 |
| F3 | MED — Check C had no non-vacuousness floor in the authoritative gate; a `$ref`-based `/doc` refactor would blind it silently | `EXPECTED_MEDIA_TYPE_CENSUS` enforced under `usingRealTables` | a doc with zero declared content now fails the floor |
| F5 | LOW — undrained undici body in the `placeAfterCreate` poison branch pinned the connection | use the existing `discardBody` helper | — |
| F4 | LOW — `6d52056`'s claim overstated: the F1 test's `passed=false` is *still* tautological via the pre-existing orphan noise | comment naming the remaining tautology and the load-bearing `expect(result.shadowed)` assertion | — |

Fable independently confirmed as sound: the §2 freeze correction (it re-read the deployed
patch and agreed a 502 throws identically to an HTML parse blowup, and that I am not
over-correcting); guard placement vs `headersSent`/`writeHead`/`clientHeaders`; no
double-respond, header leak, or double-resolve; socket hygiene under mid-drain RST and
premature FIN (reproduced on Node 22 in isolation); SSE/drift-monitor ordering;
`degraded: false` in the create guard; and opacity of the client-visible 502.

Recorded, not fixed: the pre-existing orphaned-disposition check has the same
synthetic-doc noise property as the census did (49 spurious orphans) — the consistent fix
is to scope it the same way, deliberately left out of this change set.
