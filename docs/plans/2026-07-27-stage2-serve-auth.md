# Stage 2 — serve auth (`workstation-km5f`)

Status: PLAN, not yet implemented. Supersedes the design sketched in the bead.
Revised after adversarial review, which falsified a load-bearing premise (§2).

## 0. The finding that reshapes this stage

**opencode already ships server authentication. We do not need to build it.**

`packages/opencode/src/server/auth.ts`:

```ts
password: EffectConfig.string("OPENCODE_SERVER_PASSWORD").pipe(EffectConfig.option),
username: EffectConfig.string("OPENCODE_SERVER_USERNAME").pipe(withDefault("opencode")),
required(config)   // Some(password) && password !== ""   -> unset ⇒ auth OFF
headers()          // { Authorization: "Basic base64(user:pass)" }
```

| Bead assumed | Reality |
|---|---|
| We write a new auth patch (27th overlay patch) | Auth exists upstream |
| `Authorization: Bearer` | HTTP **Basic**, `opencode:<password>` |
| `OPENCODE_SERVE_AUTH_TOKEN` | `OPENCODE_SERVER_PASSWORD` |
| unset ⇒ auth off | **Correct**, and already native |

"Unset ⇒ off" protects devbox/darwin (D1/D2) natively; a pin bump cannot brick
their pools.

### Measured on the wire

Source reading suggested the `global` group, carrying no `.middleware(Authorization)`,
would stay anonymous for free. **Wrong.** Isolated serve on :47821 with a password:

```
anonymous:  /global/health 401  /global/config 401  /event 401  /session 401  /config 401  /auth/anthropic 401
Basic:      /global/health 200  /global/config 200  /session 200  /config 200
?auth_token=base64(user:pass):  200        wrong password: 401
```

`authorizationRouterMiddleware` wraps the whole router (`httpapi/server.ts:117-120,164,176`);
per-group `.middleware()` is a second layer. Because `global.ts` has no second
layer, the 401 on `/global/health` comes solely from the router middleware — which
is why the Option B patch is genuinely one entry in a public-path set
(`public-ui.ts:4-12`, checked at `authorization.ts:107`).

### Where the bead's file-fallback advice does not apply

`ServerAuth.Config` reads **env only**; no file support. The no-code equivalent is
systemd `EnvironmentFile=`. Two traps: sops-nix writes raw values but
`EnvironmentFile=` wants `KEY=value`, so this needs a sops **template**, not a bare
`/run/secrets/<name>`; and an **empty** password fails `required()` and silently
disables auth (`auth.ts:25`) — every file says "armed" while nothing is.

## 1. Decision: keep `/global/health` anonymous (Option B)

- **A — zero patches, credentialed canaries.** Rejected: couples alerting to
  credential distribution *and* deploy ordering, for no benefit.
- **B — one small patch**, health stays anonymous.
- **C — anonymous 401-as-liveness** (raised in review): probe anonymously; 200 ⇒ armed-off
  (alarm), 401 ⇒ up and armed, refused ⇒ down. Elegant, zero patches, and makes every
  probe assert the invariant.

**Ship B.** Not on the monitoring-independence argument alone (which is real but not
unique to B) — the deciding reason is that B leaves all five probe sites
byte-identical, whereas C requires editing a five-member family of `curl -sf` probes
(`reset-workspace/default.nix:491,824,865`, canary `configuration.nix:1879`, door
`healthz.ts:19`), and fumbling exactly that kind of multi-site change is this
project's dominant failure mode. Rank: B ≥ C ≫ A.

**Adopt C's best idea regardless:** the canary should alarm on an anonymous **200**
on `/session`, making it a standing detector for the empty-password case above.

## 2. FALSIFIED: "in-process callers authenticate for free"

The previous draft argued that because `ServerAuth.headers()` reads the process env,
any in-process caller authenticates for free, so the unidentified self-connection
caller was probably harmless. **That is wrong, and it would have broken production.**

In-process requests bypass **TCP, not auth**: `app.fetch` is the same route tree
with the same router middleware (`server.ts:59-67`). A caller authenticates only if
something attaches the header. The SDK *wrapper* does (`plugin/index.ts:133`) — but
pigeon's plugin deliberately extracts the **raw** fetch out of the wrapper
(`opencode-plugin/src/index.ts:25-26`) and builds its own requests. Verified:

| Site | Headers sent | Result when armed |
|---|---|---|
| `index.ts:118` Telegram → `prompt_async` delivery | `Content-Type` only (`:85`) | **401** |
| `index.ts:169` Telegram question reply | `Content-Type`, `x-opencode-directory` | **401** |
| `swarm-list-tool.ts:48` `swarm_list` → `/experimental/session` | **none at all** | **401** |

`/experimental/session` is a protected group (`experimental.ts:235`). So arming the
password without fixing these breaks Telegram delivery, Telegram question replies,
and `swarm_list` on every serve.

This is the Stage-1 `swarm_read` failure replayed: one verified member
(`plugin/index.ts:133-134`), generalised to a family whose siblings differ. Fifth
occurrence on this project.

**Fix:** the plugin attaches `Authorization: Basic …` (or `?auth_token=`) on all
three paths, resolved from its own process env at call time — plugin and credential
live in the same process, so ordering is automatic. Plugins import once, so this
takes effect only at pool restart and must be verified live **before** the password
arms. Enumerate every other external plugin in the deployed config for the same
`getConfig().fetch` extraction pattern.

## 2b. The detection channel was silent

The previous mitigation — "arm one serve, watch its journal for 401s" — could not
have worked. Request logging is disabled on both transports (`server.ts:107`,
`httpapi/server.ts:255`), and the middleware rejection is a silent
`Effect.succeed(...401)` with no log call (`authorization.ts:88-95`). The watch
would have reported "no 401s, all clear" while Telegram delivery was down.

This is fine for the *threat model* — the loud 401 is designed to land at the
**calling** agent as a tool error, not in a server log. Say so explicitly so nobody
builds another server-side watch. But it means rollout verification must be an
**active checklist** run against the first armed serve: Telegram delivery, question
round-trip, `swarm_send`/`swarm_read`/`swarm_list`, attach, `opencode-launch --mcp`,
lgtm child, reset-workspace. Watch **client-side** logs (pigeon journal, in-session
tool results).

## 2c. Self-connection caller: still unidentified

Real and re-measured: 12 self-connections (4096×1, 4097×5, 4098×3, 4099×3).
Falsified candidates: the plugin client is in-process (`plugin/index.ts:134`); no
MCP server targets a pool port; an idle serve shows zero, so it is activity-driven.
Review's candidate — in-process tools making real TCP fetches via
`FetchHttpClient.layer` (`webfetch.ts:27,79`), i.e. an agent webfetching its own
serve, which would *be* the drift Stage 2 exists to catch — was **not** confirmed:
`oc-search '127\.0\.0\.1:409[6-9]'` returns no transcript hits.

Unresolved. Acceptable to carry only because §2b's active checklist replaces the
silent watch; it is not acceptable to carry on the original "probably fine" premise.

## 3. Client work

**Status after Deploy-1 code (2026-07-27):**

| Client | State |
|---|---|
| C3 door (`opencode-frontdoor`) | **DONE** — workstation#208, merged `22c68705` |
| pigeon **plugin** (in-process, 3 raw-fetch sites) | **DONE** — pigeon#9, merged `130b58db` |
| **pigeon daemon** | **NOT DONE — blocks Deploy 2** |
| C7/C8 `opencode-launch` degrade paths | **NOT DONE** |
| C2 `lgtm-run` children | **NOT DONE** (unverified) |
| C6 `oc-auto-attach` | **No credential needed** — resolved below |

**The pigeon daemon is the critical gap, and missing it was my error.**
`packages/daemon` has zero `OPENCODE_SERVER_PASSWORD` support, while
`opencode-client.ts` calls the serve at `:27` (`/session` create), `:46`, `:69`,
`:102` (`prompt_async`), `:117`, `:127` (`abort`), `:137` (`message`), `:148`
(`summarize`) — and its own comment notes that client is used on *every swarm
delivery*. Only `healthCheck()` survives arming, because it uses `/global/health`.
Arming the password with only the door and plugin deployed breaks swarm messaging,
Telegram-initiated session creation, and every daemon control operation.

The bead named this as C1/C9 from the start. I enumerated the door family
exhaustively and the plugin family exhaustively, then generalised *"clients done"*
without checking the daemon member — this project's signature failure, sixth
occurrence, one level up from where I was watching for it. Re-derive the client list
from the C-table **plus a fresh grep**, not from memory.

`opencode-launch` is in the same state: `pkgs/opencode-launch/default.nix:474` posts
`prompt_async` straight to `$serve_url` on the degrade path.

**C6 resolved — needs no credential.** `oc-auto-attach`'s session probe targets
`FRONTDOOR_URL` (`default.nix:343`), route/place target pigeon with the bearer
(`:375-385`), and the attach TUI rides the door (`:527-536`).

**The disposition table is stale.** `reset-workspace/default.nix:607-624` added a
direct-member `/session` **data** read after C5 was written as "health-only, exempt".
It will 401 when armed, and it fires precisely on the compound-failure night when the
door path already failed. Re-audit the table for other post-table additions.

**Password constraints (settle before generating the secret).** opencode's
`decodeCredential` does `header.split(":")` and requires **exactly two** parts
(`authorization.ts:59-66`) rather than splitting on the first colon per RFC 7617 — so
a password containing `:` gives permanent 401s from correct clients while every config
file looks right. Generate with `openssl rand -hex`. Combined with the empty-password
trap in §0, the rule is: **non-empty, colon-free, no leading/trailing whitespace.**

**Canonical resolver semantics — settle when the next three resolvers are written.**
The server compares raw env with strict `===` and no trimming (`auth.ts:24-33`); the
door matches that (`config.ts:70-74`); the plugin **trims** (`serve-auth.ts:24,30`).
With a constrained password this is unreachable, which is why it did not block the two
merges — but the daemon, launch and lgtm resolvers are still to come. Give all five
one rule and the same conformance vectors rather than harmonising two now and three
later.

### Original per-site notes

- **C3 the door — TWO copy sites, not one.** `proxy.ts:66` (`proxyRequest`,
  streaming/SSE) *and* `proxy.ts:334` (`placeAfterCreate`, session create/fork, via
  `boundedFetch`). Injecting only in the first breaks session creation through the
  door. Both must inject **and overwrite** any client-supplied `Authorization`.
  Also `healthz.ts:19,32` probes the anchor's health — fine under B.
  The door's existing bearer (`http.ts`) is *pigeon's* credential — a different
  secret; do not conflate.
- **Strip `auth_token` from the forwarded query string.** The middleware checks the
  query param *before* the header (`authorization.ts:75-78`) and the door forwards
  `url.search` verbatim (`proxy.ts:74,342`), so a client-supplied `?auth_token=`
  overrides correct door injection and 401s.
- **C1/C9 pigeon**, **C7/C8 `opencode-launch`**, **C2 `lgtm-run`** children.
- **C6 `oc-auto-attach`** — verify whether it calls a serve or only resolves a URL.
- **D1/D2** untouched via unset ⇒ off.
- **Fence the password out of agent envs.** `shell-env.ts:38-59` is an allow-list and
  does not carry it today. Add a comment and a negative assertion to the opacity
  test: if this password ever reaches agent bash environments, the whole stage is
  worthless.

## 4. Ordering

Two separate deploys, because the door is `restartIfChanged=false` and the nightly
reset restarts serves at 03:01 unattended.

**An earlier version of this section was wrong and would have caused an outage.** It
restarted the door in step 1 — *before the password existed* — and never restarted it
again, so the door would have come up with no credential and stayed that way while
the serves armed. The door must be restarted **after** the password lands and
**before** any serve is armed.

1. **Client code only, no password anywhere.** Door injection, plugin fix, and the
   daemon / launch / lgtm credentials (see §3 — not all built yet). Restart the door
   and the pool. Verify every workflow still works against **auth-off** serves;
   credentials sent to an auth-off serve are never parsed
   (`authorization.ts:87,101`), so this step is strictly safe.
2. **Land the password** on both the door and serve units. Restart the **door first**
   and positively verify it now holds the credential — at this point the serves are
   still unarmed, so the door's credential is simply ignored, which makes this a free
   checkpoint.
3. **Only then** arm **one** serve; run the §2b checklist; then roll to the rest.

Landing the password and the door restart in the wrong order risks a credential-less
door meeting armed serves at 03:01 — a box-wide outage while asleep. Note the nightly
reset restarts `opencode-serve-pool.target` (`reset-workspace/default.nix:284-288`)
but **never the door**, so the reset cannot rescue this and will actively cause it if
Deploy 2 is left half-finished overnight. Deploy 2 and its verification must complete
the same day.

Also beware `EnvironmentFile=-` (leading dash) silently tolerating a missing secret at
first boot, which yields a permanently credential-less unit that looks configured.

Done test: anonymous `/session` → 401 on all four ports; `/global/health` → 200
anonymous on all four; attach, `opencode-launch --mcp`, swarm messaging all work;
canary asserts the 401s *and* alarms on anonymous 200; nightly reset completes;
`test-frontdoor-opacity.sh` passes.
