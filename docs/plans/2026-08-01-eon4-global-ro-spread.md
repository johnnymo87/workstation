# eon4: Spread pool-invariant `global-ro` reads across the serve pool

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Stop the front door concentrating every session-less read on the anchor (`:4096`), by letting explicitly-flagged pool-invariant routes round-robin across all K serve members.

**Architecture:** Add an opt-in `poolSafe?: boolean` field to `RouteEntry`. `dispatch()` maps `global-ro` + `poolSafe` to a new `forward-pool` action; unflagged `global-ro` keeps `forward-anchor` unchanged. `proxy.ts` round-robins `forward-pool` across a pool list supplied by a new `FRONTDOOR_POOL_URLS` env var, failing over to the next member on connection-level errors with the anchor tried last. `FRONTDOOR_POOL_URLS` unset ⇒ `[anchorUrl]` ⇒ behaviour byte-identical to today, so the deploy is order-independent.

**Tech Stack:** TypeScript (Node builtins only, no framework), vitest (~250 tests, `./test.sh`), NixOS system unit on cloudbox, `users/dev/serve-pool.nix` as the pool source of truth.

---

## Background — read this before touching code

The bead is `workstation-eon4`; its two `2026-08-01` notes hold the approved design and are authoritative if this document and the bead ever disagree.

**The failure.** `dispatch.ts` maps the whole `global-ro` class to `forward-anchor`, so every session-less read lands on `:4096`, which also hosts sessions. Under a burst of TUI attaches the anchor exceeds the door's 5s cheap-first-byte budget and the door returns 503. Measured 2026-07-30: 333 such 503s, 196 inside one 7-second window, all `target=:4096`, all `durationMs` 4999–5002 — pinned at the budget, i.e. a hard wall, not a tail. The door was not the bottleneck; the anchor process was.

After the caller-side fix (`workstation-220`, backpressure + retry, shipped) that fell to 22 on 2026-08-01 — spread over 7.5 minutes rather than 7 seconds, user-visible outcome clean because the client retries. The concentrator itself is untouched. Those 22 were `/api/provider` ×8, `/api/model` ×8, `/api/reference` ×3, `/api/integration` ×3. **The Task 2 flag set below covers all 22.**

**Two closed doors — do not reopen.** A door-side response cache was built and abandoned on evidence (`workstation-221`): real attach traffic carries `?directory=` on 41/41 requests across 17 distinct project dirs, so coalescing measured ~2x, and it risked an unbounded `arrayBuffer()` stall plus cross-credential leakage. And the caller side is already fixed; more client work is not the answer here.

**Why RR composes with the shipped retry.** Today a retry after an anchor 503 deterministically lands on the anchor again and fails again. With RR the retry lands on a *different* member, so the already-deployed client retry becomes genuinely effective. This is a large part of the value and is worth preserving in any redesign.

### Scope limit, to be stated honestly and not quietly widened

This fixes `global-ro` concentration only. The residual 503s pinned at 5000–5006 ms prove the anchor has ≥5s first-byte stalls even outside bursts; sessions *pinned* to the anchor still eat those. Do not close `eon4` claiming anchor stalls are fixed generally.

### Accepted tradeoff — no wedge awareness in this change

`wedge.ts` is a per-stream probe, not a standing per-member health registry, so the door has no cheap way to know a member is wedged (accepting connections but not answering). Consequence: today, if the anchor wedges, 100% of global-ro fails; after this change, if any one member wedges, ~25% fails — and the client retry lands elsewhere and succeeds. That is a strict improvement in the anchor case and a new (small, retry-covered) exposure in the non-anchor case. Passive ejection / circuit-breaking is deliberately **out of scope**; revisit only with measurements. Do not add pre-request health probes — they double upstream traffic, which is the resource under contention.

---

## Task 1: `FRONTDOOR_POOL_URLS` config parsing

**Files:**
- Modify: `pkgs/opencode-frontdoor/src/config.ts` (add `poolUrls` to `Config`; parse in `loadConfig`)
- Test: `pkgs/opencode-frontdoor/test/config.test.ts`

**Step 1: Write the failing tests.** Add to `test/config.test.ts`, following the existing env-var save/restore style in that file:

```ts
describe('FRONTDOOR_POOL_URLS', () => {
  it('defaults to [anchorUrl] when unset', () => {
    delete process.env.FRONTDOOR_POOL_URLS;
    process.env.OPENCODE_ANCHOR_URL = 'http://127.0.0.1:4096';
    expect(loadConfig().poolUrls).toEqual(['http://127.0.0.1:4096']);
  });

  it('parses a comma-separated list in order', () => {
    process.env.FRONTDOOR_POOL_URLS =
      'http://127.0.0.1:4096,http://127.0.0.1:4097,http://127.0.0.1:4098';
    expect(loadConfig().poolUrls).toEqual([
      'http://127.0.0.1:4096', 'http://127.0.0.1:4097', 'http://127.0.0.1:4098',
    ]);
  });

  it('trims whitespace and ignores empty entries', () => {
    process.env.FRONTDOOR_POOL_URLS = ' http://127.0.0.1:4096 , ,http://127.0.0.1:4097,';
    expect(loadConfig().poolUrls).toEqual(['http://127.0.0.1:4096', 'http://127.0.0.1:4097']);
  });

  it('falls back to [anchorUrl] when the value is empty or only separators', () => {
    process.env.FRONTDOOR_POOL_URLS = ' , , ';
    process.env.OPENCODE_ANCHOR_URL = 'http://127.0.0.1:4096';
    expect(loadConfig().poolUrls).toEqual(['http://127.0.0.1:4096']);
  });

  it('always includes anchorUrl, appending it if the list omits it', () => {
    process.env.FRONTDOOR_POOL_URLS = 'http://127.0.0.1:4097';
    process.env.OPENCODE_ANCHOR_URL = 'http://127.0.0.1:4096';
    expect(loadConfig().poolUrls).toContain('http://127.0.0.1:4096');
  });

  it('rejects a malformed URL loudly', () => {
    process.env.FRONTDOOR_POOL_URLS = 'http://127.0.0.1:4096,not-a-url';
    expect(() => loadConfig()).toThrow(/FRONTDOOR_POOL_URLS/);
  });

  it('de-duplicates repeated members, preserving first-seen order', () => {
    process.env.FRONTDOOR_POOL_URLS =
      'http://127.0.0.1:4096,http://127.0.0.1:4097,http://127.0.0.1:4096';
    expect(loadConfig().poolUrls).toEqual(['http://127.0.0.1:4096', 'http://127.0.0.1:4097']);
  });
});
```

**Step 2: Run and verify they fail.** `cd pkgs/opencode-frontdoor && npx vitest run test/config.test.ts` — expect failures on `poolUrls` being undefined.

**Step 3: Implement.** Add `poolUrls: string[];` to the `Config` interface with a comment explaining the unset ⇒ `[anchorUrl]` rollout property. Parse near the other env reads:

```ts
function parsePoolUrls(value: string | undefined, anchorUrl: string): string[] {
  const parts = (value ?? '')
    .split(',')
    .map((s) => s.trim())
    .filter((s) => s.length > 0);

  for (const p of parts) {
    try {
      new URL(p);
    } catch {
      throw new Error(`Invalid FRONTDOOR_POOL_URLS entry: "${p}". Must be an absolute URL.`);
    }
  }

  // Unset/empty => anchor-only, i.e. exactly today's behaviour. This is what
  // makes the door rebuild and the unit's env change land in either order.
  if (parts.length === 0) return [anchorUrl];

  // The anchor must always be a member: it is the universal fallback target
  // elsewhere in the door, and a pool that excludes it would make `forward-pool`
  // diverge from `forward-anchor` under failover.
  if (!parts.includes(anchorUrl)) parts.push(anchorUrl);

  return [...new Set(parts)];
}
```

Reject malformed entries rather than silently dropping them: a typo'd port that silently vanishes would leave the pool quietly smaller than intended, which is precisely the class of failure this epic exists to stop.

**Step 4: Run tests.** Same command. Expect PASS. Then the full suite: `npx vitest run`.

**Step 5: Commit.** `git commit -m "feat(frontdoor): parse FRONTDOOR_POOL_URLS, defaulting to anchor-only"`

---

## Task 2: `poolSafe` flag on the route table + the anti-laundering guard

**Files:**
- Modify: `pkgs/opencode-frontdoor/src/routes.classification.ts`
- Test: `pkgs/opencode-frontdoor/test/dispatch.test.ts`

**Step 1: Write the failing guard test first.** This test is the durable regression barrier and matters more than the flags themselves:

```ts
describe('poolSafe flag integrity', () => {
  // A route whose note documents PER-PROCESS state must never be flagged
  // pool-safe. Spreading such a route converts a latent anchor-view bug into a
  // random-member-view bug, which is strictly harder to diagnose.
  it('never flags a route documented as per-process', () => {
    const offenders = ROUTE_CLASSIFICATION_TABLE
      .filter((e) => e.poolSafe && /PER-PROCESS/i.test(e.note ?? ''))
      .map((e) => `${e.method} ${e.path}`);
    expect(offenders).toEqual([]);
  });

  it('only ever flags the global-ro class', () => {
    const offenders = ROUTE_CLASSIFICATION_TABLE
      .filter((e) => e.poolSafe && e.class !== 'global-ro')
      .map((e) => `${e.method} ${e.path}`);
    expect(offenders).toEqual([]);
  });

  it('only ever flags safe, side-effect-free methods', () => {
    const offenders = ROUTE_CLASSIFICATION_TABLE
      .filter((e) => e.poolSafe && !['GET', 'HEAD'].includes(e.method.toUpperCase()))
      .map((e) => `${e.method} ${e.path}`);
    expect(offenders).toEqual([]);
  });

  it('every flagged route carries a justification note', () => {
    const offenders = ROUTE_CLASSIFICATION_TABLE
      .filter((e) => e.poolSafe && !(e.note ?? '').includes('POOL-SAFE'))
      .map((e) => `${e.method} ${e.path}`);
    expect(offenders).toEqual([]);
  });

  // Pins the reviewed set. Changing it must be a deliberate, reviewed edit —
  // not a side effect of adding a route.
  it('flags exactly the reviewed set', () => {
    const flagged = ROUTE_CLASSIFICATION_TABLE
      .filter((e) => e.poolSafe)
      .map((e) => `${e.method} ${e.path}`)
      .sort();
    expect(flagged).toEqual(EXPECTED_POOL_SAFE_ROUTES);
  });
});
```

Define `EXPECTED_POOL_SAFE_ROUTES` in the test file as the sorted literal of the Step 3 set.

**Step 2: Run and verify failure.** `npx vitest run test/dispatch.test.ts` — fails on `poolSafe` not existing.

**Step 3: Implement.** Add to `RouteEntry`:

```ts
  /**
   * Opt-in: this read is POOL-INVARIANT and may be served by any member of the
   * serve pool, not just the anchor (bead workstation-eon4).
   *
   * OPT-IN, NEVER CLASS-WIDE. `global-ro` is NOT uniformly pool-invariant —
   * several entries below read PER-PROCESS in-memory state and are marked
   * FABLE-P5-F2. Absent this flag a route forwards to the anchor exactly as
   * before, so a NEWLY ADDED route is anchor-pinned (safe) by construction and
   * spreading is always a deliberate, reviewed act.
   *
   * Bar for flagging: the response must derive solely from state shared by every
   * member — on-disk config//project files, or the shared opencode.db — and must
   * not depend on which process answers. When unsure, do not flag; the cost of a
   * wrong flag (silent divergence by member) far exceeds the cost of one route
   * still on the anchor.
   */
  poolSafe?: boolean;
```

Flag exactly these, appending `POOL-SAFE (eon4): <reason>` to each `note`:

| Route(s) | Why invariant |
|---|---|
| `GET /api/provider`, `GET /provider`, `GET /api/provider/{providerID}`, `GET /provider/auth` | provider set from on-disk config + credentials |
| `GET /api/model` | model catalogue, derived from provider config |
| `GET /api/reference` | static reference data |
| `GET /api/integration`, `GET /api/integration/{integrationID}` | integration registry from shared config |
| `GET /api/agent`, `GET /agent` | agent definitions from disk |
| `GET /api/command`, `GET /command` | command definitions from disk |
| `GET /api/skill`, `GET /skill` | skill definitions from disk |
| `GET /api/location` | derived from the shared `WorkingDirectory` |
| `GET /config/providers` | on-disk config projection |
| `GET /path` | derived from the shared `WorkingDirectory` |
| `GET /project`, `GET /project/current`, `GET /project/{projectID}/directories` | project state from disk |
| `GET /experimental/capabilities` | static capability report |
| `GET /doc` | OpenAPI spec, identical per binary |

The cwd-derived entries (`/path`, `/api/location`, `/project/current`) are only invariant because **every pool member runs with `WorkingDirectory = "/home/dev"` and an identical `Environment` block**, set by the single templated `opencode-serve@` unit in `hosts/cloudbox/configuration.nix`. Note that dependency in the table; if per-member cwd is ever introduced these three must be unflagged.

**Deliberately NOT flagged — record the reason, do not "tidy" these later:**

- `GET /permission`, `GET /question`, `GET /api/permission/request`, `GET /api/question/request`, `GET /session/status` — FABLE-P5-F2 per-process in-memory views.
- `GET /config`, `GET /global/config` — `workstation-g8k9`: mislabelled process-local; shared disk **plus a stale per-process cache**, so members can genuinely disagree.
- `GET /api/health`, `GET /global/health` — health *of which process?* Per-process by definition.
- `GET /api/session`, `GET /session`, `GET /api/session/active`, `GET /experimental/session` — session listings; `active` in particular is per-process in-memory. Plausibly safe from the shared DB, but unproven, and `#234`'s new session switcher is a live consumer. Tier-2 candidate, evidence first.
- `GET /lsp`, `GET /formatter` — LSP/formatter servers are spawned per serve process.
- `fs`/`file`/`find`/`vcs` reads — genuinely disk-derived and probably safe, but absent from the measured failure set. Held back to keep blast radius minimal.

**Step 4: Run tests.** Expect PASS.

**Step 5: Commit.** `git commit -m "feat(frontdoor): flag pool-invariant global-ro routes as poolSafe"`

---

## Task 3: `forward-pool` action in `dispatch()`

**Files:**
- Modify: `pkgs/opencode-frontdoor/src/dispatch.ts`
- Test: `pkgs/opencode-frontdoor/test/dispatch.test.ts`

**Step 1: Write failing tests.**

```ts
it('dispatches a flagged global-ro route to forward-pool', () => {
  expect(dispatch('GET', '/api/provider').action).toBe('forward-pool');
  expect(dispatch('GET', '/api/model').action).toBe('forward-pool');
});

it('keeps unflagged global-ro on forward-anchor', () => {
  expect(dispatch('GET', '/permission').action).toBe('forward-anchor');
  expect(dispatch('GET', '/config').action).toBe('forward-anchor');
  expect(dispatch('GET', '/session/status').action).toBe('forward-anchor');
});

it('reports class global-ro either way', () => {
  expect(dispatch('GET', '/api/provider').class).toBe('global-ro');
});

it('resolves flagged templated routes', () => {
  expect(dispatch('GET', '/api/provider/anthropic').action).toBe('forward-pool');
});

it('treats HEAD like GET for flagged routes', () => {
  expect(dispatch('HEAD', '/api/provider').action).toBe('forward-pool');
});
```

**Step 2: Run, verify failure.**

**Step 3: Implement.** Add `'forward-pool'` to the `RouteAction` union. Build a `poolSafe` lookup alongside the existing precomputed maps — exact keys in a `Set<string>` keyed `"<METHOD> <path>"`, and a `poolSafePatternRoutes` array mirroring the existing `patternRoutes` handling so templated routes work. Then:

```ts
    case 'global-ro':
      action = isPoolSafe(normalizedMethod, normalizedPath) ? 'forward-pool' : 'forward-anchor';
      break;
```

`isPoolSafe` must mirror `classify()`'s resolution order exactly — exact match, then pattern in table order, then the HEAD⇒GET retry — or a templated route will classify one way and route another. Prefer factoring the shared path/method resolution over duplicating it.

**Step 4: Run tests.** Full suite: `npx vitest run`. Every existing `forward-anchor` assertion for an unflagged route must still pass untouched.

**Step 5: Commit.** `git commit -m "feat(frontdoor): add forward-pool action for poolSafe routes"`

---

## Task 4: Round-robin forwarding with failover in `proxy.ts`

**Files:**
- Modify: `pkgs/opencode-frontdoor/src/proxy.ts` (near the `forward-anchor` branch, currently ~line 677)
- Test: `pkgs/opencode-frontdoor/test/integration.test.ts`

**Step 1: Write failing tests.** Use the existing loopback-server harness in `integration.test.ts`:

```ts
it('round-robins successive poolSafe reads across members', async () => {
  // three stub upstreams; issue 6 GET /api/provider through the door
  // expect each upstream to receive exactly 2
});

it('keeps unflagged global-ro pinned to the anchor', async () => {
  // 4 x GET /config -> anchor receives all 4, others 0
});

it('fails over to the next member when one refuses the connection', async () => {
  // kill member 2's listener; request that would select it must still 200
});

it('tries the anchor last during failover', async () => {
  // with all non-anchor members refusing, the anchor still serves the request
});

it('returns 502/503 when every member refuses', async () => {
  // no hang, no unhandled rejection, bounded latency
});

it('behaves exactly as before when poolUrls is [anchorUrl]', async () => {
  // the deploy-order safety property
});

it('does not retry on a first-byte timeout (only on connection errors)', async () => {
  // a member that accepts then stalls must NOT be retried elsewhere:
  // ws#220's caller retry owns that case
});
```

**Step 2: Run, verify failure.**

**Step 3: Implement.** Module-level cursor, advanced per request:

```ts
let poolCursor = 0;

function poolOrder(poolUrls: string[], anchorUrl: string): string[] {
  if (poolUrls.length <= 1) return [...poolUrls];
  const start = poolCursor++ % poolUrls.length;          // advance once per request
  const rotated = [...poolUrls.slice(start), ...poolUrls.slice(0, start)];
  // Anchor last on the FAILOVER path: it is the busiest member and the universal
  // fallback, so it should absorb retries only when nothing else can serve them.
  const withoutAnchor = rotated.filter((u) => u !== anchorUrl);
  return rotated.includes(anchorUrl) ? [...withoutAnchor, anchorUrl] : rotated;
}
```

Note the anchor still takes its normal turn as a *primary* target — `poolOrder`'s first element is whatever the cursor selects, including the anchor; "anchor last" governs only the order of failover attempts after the first choice fails.

In the handler:

```ts
    if (decision.action === "forward-pool") {
      degraded = false;
      const order = poolOrder(ctx.config.poolUrls, ctx.config.anchorUrl);
      for (let i = 0; i < order.length; i++) {
        target = order[i];
        const isLast = i === order.length - 1;
        const outcome = await proxyRequest(target, method, url, req, res, ctx, null,
                                           { failoverIfUnreachable: !isLast });
        if (outcome !== "upstream-unreachable") return;
      }
      return;
    }
```

Requirements on the failover contract, all of which the tests above pin:

- Retry **only** on connection-level failure (`ECONNREFUSED`, `ECONNRESET`, `EHOSTUNREACH`, DNS) **before any response byte is written**. Never retry once `res.headersSent`.
- Do **not** retry on first-byte timeout. A stalled-but-listening member is exactly `eon4`'s symptom, and the shipped client retry already covers it; retrying inside the door would multiply load on an already-saturated pool.
- Do **not** pre-probe members.
- Keep the existing per-request log line emitting the chosen `target` — post-deploy verification counts 503s *by target* and is impossible without it.

Whether `proxyRequest` can already signal "unreachable without writing a response" decides whether this is a small refactor or a signature change; inspect it before writing the loop and prefer the smallest honest change.

**Step 4: Run tests.** `./test.sh` in full (includes typecheck, the vitest suite, and the `/doc` route gate).

**Step 5: Commit.** `git commit -m "feat(frontdoor): round-robin poolSafe reads with connection-level failover"`

---

## Task 5: Wire `FRONTDOOR_POOL_URLS` from `serve-pool.nix`

**Files:**
- Modify: `hosts/cloudbox/configuration.nix` (the `opencode-frontdoor` unit's `Environment` block, ~line 1830)

**Step 1: Implement.** The unit already has `servePool = (import ../../users/dev/serve-pool.nix).forHost.cloudbox;` in scope, and `serve-pool.nix` already exposes `endpointsCsv` in port order — which is exactly this variable's format. Use it; do **not** hand-write the port list, since the whole point of that file is that ports cannot drift:

```nix
        # eon4: pool-invariant `global-ro` reads (poolSafe in
        # routes.classification.ts) round-robin across the whole pool instead of
        # concentrating on the anchor. Derived from serve-pool.nix so it cannot
        # drift from the actual serve units. Unset => anchor-only, i.e. the
        # pre-eon4 behaviour.
        # frontdoor-exempt(C3): the door's own upstreams; it cannot proxy through itself
        "FRONTDOOR_POOL_URLS=${servePool.endpointsCsv}"
```

The `frontdoor-exempt(C3)` marker is required — this is a literal serve-address site and `test-frontdoor-opacity.sh` will otherwise flag it. Verify the disposition row it cites genuinely covers this file.

**Step 2: Verify the derivation, not the intention.**

```bash
nix eval --raw ".#nixosConfigurations.cloudbox.config.systemd.services.opencode-frontdoor.serviceConfig.Environment" 2>&1 | tr ' ' '\n' | grep FRONTDOOR_POOL_URLS
```

Expect `FRONTDOOR_POOL_URLS=http://127.0.0.1:4096,http://127.0.0.1:4097,http://127.0.0.1:4098,http://127.0.0.1:4099`. If the flake's `nixosConfigurations` attr path differs, find the real one rather than skipping this check.

**Step 3: Run the opacity guard.** `users/dev/test-frontdoor-opacity.sh` — note it is *already red on `main`* for unrelated reasons (16 sites vs 14 expected, from #217's devbox convergence). Confirm your change does not add a *new* unmarked site; do not attempt to fix the pre-existing failure here, it belongs to `mlve.4` Step 1.

**Step 4: Commit.** `git commit -m "feat(cloudbox): supply frontdoor pool URLs from serve-pool.nix"`

---

## Task 6: Full verification pass

**Step 1:** `cd pkgs/opencode-frontdoor && ./test.sh` — full suite plus route gate. Expect all green.

**Step 2:** Confirm the deploy-order safety property directly: with `FRONTDOOR_POOL_URLS` unset, a `GET /api/provider` must still reach the anchor and succeed.

**Step 3:** `git log --oneline origin/main..HEAD` — expect ~5 focused commits.

---

## Deploy (authorised for this change only)

The user authorised this deploy explicitly; it overrides the standing rule that they run `nixos-rebuild` themselves. That authorisation does **not** generalise.

1. Merge the PR — `gh pr merge --squash` (the repo forbids merge commits).
2. `sudo nixos-rebuild switch --flake .#cloudbox`
3. `sudo systemctl restart opencode-frontdoor.service` — **required and explicit**: the unit sets `restartIfChanged = false`, so the rebuild alone leaves the old binary and the old env running. Skipping this yields a fully green deploy that changed nothing.
4. The restart drops in-flight SSE legs through the door; do it in an idle window. **No pool restart, no `patched.N` cut.**
5. Confirm the *running* process actually has the new env — a green unit is not evidence:
   ```bash
   sudo cat /proc/$(systemctl show -p MainPID --value opencode-frontdoor)/environ | tr '\0' '\n' | grep FRONTDOOR_POOL_URLS
   curl -sS 127.0.0.1:4700/healthz
   ```
6. Smoke: issue several `GET /api/provider` through `:4700` and confirm from the door's logs that `target` varies across members. This is the first real evidence the change does anything.

## Verification — the fix is UNVERIFIED until this runs

Cross-member diff loop (curl each flagged route against every pool member and compare to detect response drift):
```bash
for route in /api/agent /api/command /api/integration /api/location /api/model /api/provider /api/reference /api/skill /doc /experimental/capabilities /path /project /provider/auth; do
  echo "=== Diffing $route ==="
  tmp=$(mktemp -d)
  for port in 4096 4097 4098 4099; do
    curl -sS "http://127.0.0.1:$port$route" > "$tmp/$port.json"
  done
  diff -u "$tmp/4096.json" "$tmp/4097.json" && diff -u "$tmp/4096.json" "$tmp/4098.json" && diff -u "$tmp/4096.json" "$tmp/4099.json"
  rm -rf "$tmp"
done
```

The deploy proving green proves nothing about the failure mode. On the next post-reset morning, count `class=global-ro` 503s **by target**:

```bash
journalctl -u opencode-frontdoor.service --since "2026-08-02 06:00:00"
```

Use an explicit ISO timestamp. A bare `--since "today 00:00"` **fails to parse and silently returns zero lines**, which reads exactly like "no errors" — this nearly produced a false all-clear earlier in this epic.

Expect: reads distributed across all four targets, near-zero `global-ro` 503s, anchor p95 down. Until that measurement exists, report the fix as deployed-but-unverified. `eon4` stays open until it does, and closes citing global-ro only — the anchor's own ≥5s stalls are out of scope.
