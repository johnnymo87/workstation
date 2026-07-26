# dx8p Stage 1 — pigeon bearer token

**Bead:** `workstation-dx8p` (P1). **Status: PLAN, ready for SDD.**
**Strategy context (read first):** `docs/plans/2026-07-26-frontdoor-spine.md` §3.

## Goal

Every anonymous request to pigeon (`:4731`) returns 401. Today all three of
`GET /sessions`, `GET /route`, `POST /place` return 200 unauthenticated; `/place`
is a **write**, so any local process can re-place any session.

This is Stage 1 of 4. It does **not** deliver opacity as a property (`ss -tlnp`
still reveals the pool, serve ports stay open — that's Stages 2/4). It delivers
"drift becomes a loud 401 at the moment of writing", which is the mechanism that
actually matches our threat model: *our own agents taking shortcuts*, not an
attacker.

## Cross-repo: this spans TWO repos

| Repo | Change |
|---|---|
| `~/projects/pigeon` (out of repo, own git) | extend `checkAuth`'s protected set |
| `~/projects/workstation` | sops secret + plumb env into pigeon **and door** units |

Land pigeon first (it is back-compatible: auth is disabled when the token is
falsy, `auth.ts:4`), then workstation.

## THE TRAP — read before writing any code

`pigeon/packages/daemon/src/auth.ts:5-9` protects only:

```
request.method === "POST" || request.method === "DELETE" ||
(request.method === "GET" && url.pathname === "/route")
```

So **turning the token on today leaves `GET /sessions` (the 166 KB inventory:
sids, cwds, pids, endpoints) wide open** while feeling closed. Extending the
protected set is Task 1 and is the whole point; the env plumbing is the easy half.

## Tasks

### Task 1 — pigeon: extend the protected set (repo: `~/projects/pigeon`)

Edit `packages/daemon/src/auth.ts`. Change `needsAuth` to protect **every** route
by default, with an explicit anonymous allowlist, rather than an allow-by-default
with a deny list. Rationale: the current shape failed exactly by omission, and a
new unauthenticated read route added later would silently inherit "public".

Suggested allowlist (justify any addition in a comment):
- `GET /health` (or whatever the daemon's own liveness path is — **verify it
  exists before allowlisting; do not invent one**).

Keep the falsy-token back-compat branch (`if (!authToken) return null`) — devbox,
darwin and any dev instance rely on it, and Stage 2 uses the same convention.

Handler is `packages/daemon/src/app.ts:118`; `GET /sessions` is `app.ts:325`.

*Done test:* unit test in the pigeon repo asserting, with a token set: `/sessions`,
`/route`, `/place` → 401 without a bearer, 200 with. Without a token set: all 200
(back-compat). Run pigeon's existing suite.

### Task 2 — workstation: sops secret

Add `pigeon_daemon_auth_token` to `secrets/cloudbox.yaml` and declare it in
`sops.secrets` in `hosts/cloudbox/configuration.nix`, following the existing
pattern used by `ccr_api_key` / `telegram_bot_token`.

See `.opencode/skills/managing-secrets/SKILL.md`. Generate a high-entropy value
(e.g. `openssl rand -hex 32`).

*Done test:* after rebuild, `/run/secrets/pigeon_daemon_auth_token` exists and is
readable by `dev`.

### Task 3 — workstation: plumb the token into BOTH units in ONE rebuild

**Ordering is load-bearing.** If pigeon requires the token before the door sends
it, every door→pigeon resolve fails, the door degrades, and mutating traffic
either 503s or hammers the anchor. Both must land in the same activation.

- **pigeon unit** — `hosts/cloudbox/configuration.nix:564+`, alongside the existing
  `export CCR_*` lines:
  `export PIGEON_DAEMON_AUTH_TOKEN="$(cat /run/secrets/pigeon_daemon_auth_token)"`
- **door unit** — `opencode-frontdoor`. The client side **already exists**, nothing
  to build: read at `pkgs/opencode-frontdoor/src/config.ts:66`, sent at
  `resolve.ts:46`, `place.ts:37`, `healthz.ts:27`. It only needs the env var.

Also confirm the **canary** units that probe pigeon get the token, or they will
start alarming on 401.

*Done test:* `systemctl show pigeon-daemon.service` and the door unit both
reference the secret; door `/healthz` still reports pigeon reachable.

### Task 4 — delete the phantom route

`ses_0000000000000000000000000 -> serve-0` is live in the routing registry,
written by an adversarial-reviewer probe that was demonstrating `POST /place` is an
unauthenticated write. Remove it. (Read-only verify first:
`curl -s ':4731/route?session_id=ses_0000000000000000000000000'`.)

### Task 5 — regression guard

Extend `users/dev/test-frontdoor-opacity.sh`, or add a canary assertion, so an
anonymous `:4731/sessions` returning 200 fails loudly. Without this, a future
pigeon refactor silently reopens the hole — which is exactly how it got here.

Prefer a **runtime** assertion (canary) over a source grep: the failure mode is a
live-service property, not a source-string property.

## Verification (all must hold)

1. `curl -s -o /dev/null -w '%{http_code}' :4731/sessions` → **401**; same for
   `/route`; `POST /place` → **401**.
2. With the bearer → 200.
3. `opencode attach` TUIs still work; count on `:4700` unchanged.
4. `swarm_send` between sessions still works. **The plugin client does send the
   bearer** — `packages/opencode-plugin/src/daemon-client.ts:105-106` and
   `swarm-send-tool.ts:268` read `PIGEON_DAEMON_AUTH_TOKEN` — this was verified,
   so a failure here means the env is missing from the *session's* environment,
   not that the code lacks support.
5. `opencode-launch` still launches (its degrade path talks to pigeon).
6. Nightly `reset-workspace` completes (it uses pigeon discovery).
7. `bash users/dev/test-frontdoor-opacity.sh` still green.

## Deploy

`nixos-rebuild switch --flake .#cloudbox` (units + secret), then restart pigeon
**and** the door together. Door is `restartIfChanged = false` on purpose — an
explicit `systemctl restart opencode-frontdoor` is required and **will drop live
SSE legs**, so do it deliberately, not mid-turn.

**Confirm by generation timestamp, not by the command appearing to run:**
`ls -lat ~/.local/state/nix/profiles/`. A switch failed silently on shellcheck
earlier today and left the profile four hours stale.

## Out of scope (do not scope-creep into these)

- Stage 2 (serve token) — separate bead when started.
- Stage 3 (move the degrade into the door, per-member health surface).
- Stage 4 (netns) — escalation only.
- `workstation-vjq0` (silent MCP tool loss), `workstation-u417` (the door
  instructs its own bypass).

**After this lands the user's chosen next work is `workstation-y8m`** — the only
open P0, a measurement gate blocking the `b4p` epic, untouched while this spine
consumed sessions.
