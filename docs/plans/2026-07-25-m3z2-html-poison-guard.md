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
| P3 | `text/html` is never a *legitimate* response anywhere on the surface | **TRUE, authoritatively.** The live `/doc` declares 518 responses: `application/json` ×512, `text/event-stream` ×4, `text/x-diff; charset=utf-8` ×1, `application/octet-stream` ×1. **`text/html` appears zero times.** |
| P4 | OAuth callback routes return HTML (my initial worry, which would have blocked a broad guard) | **FALSE.** `POST /provider/{providerID}/oauth/callback` and `/mcp/{name}/auth/callback` both declare `application/json`. My hazard was imaginary — caught by checking instead of asserting. |
| P5 | The live anchor's route surface equals the pinned build's | **TRUE.** Live `/doc` and the committed fixture have identical 195 path×method pairs, so the media-type census above describes the pinned build. |
| P6 | `GET /api/fs/read/*` streams raw file bytes, so reading an `.html` file could legitimately yield `text/html` | **FALSE.** It declares `application/octet-stream`. Even raw reads are not an HTML source. |

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

## 3. Guard design

### 3.1 Scope: every forwarded response, not just `session-path`

The bead specifies `session-path`. I am widening it to **all forwarded responses**, on
evidence:

- The harm is not session-path-specific. Any forwarded route the target serve lacks yields
  the SPA. Narrow scope guarantees a later repeat of the same incident via a new
  global/`experimental` route — this project's whole pathology is "one table discovered one
  incident at a time."
- Widening is *safe*, not reckless: P3 shows zero declared `text/html` across 518
  responses, and the two classes that intentionally reach the SPA (`web-ui` at `/`,
  `unrecognized`) are already 404'd at the door **before** forwarding.
- P4 killed the one counter-argument I had (oauth callbacks).

Denied classes (`pty`, `tui`, `web-ui`, `unrecognized`, `per-process-ro`, `global-event`)
never reach an upstream, so they are out of scope by construction.

To keep the widened premise from silently rotting, §4 adds a **gate invariant** that fails
the build if any route ever declares a `text/html` response. That converts "HTML is never
legitimate" from an assumption into a checked fact — the same loop-ending pattern j6de
established.

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

1. **The freeze is not fixed** (§2). Re-promote Part B as its own bead; the guard is a
   complement. Do not let "covers the same harm" imply equivalence.
2. `application/xhtml+xml` and other HTML-ish types are not matched.
3. Check C constrains *declared* types only; a route that undeclares its content type and
   returns HTML at runtime would still slip past the gate (the guard would still catch it
   at runtime — this is a gate gap, not a guard gap).
