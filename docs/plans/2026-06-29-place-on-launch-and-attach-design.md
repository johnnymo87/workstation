# Place-on-launch-and-attach: distribute pool sessions off `:4096`

Date: 2026-06-29
Bead: workstation-iwpj
Status: approved (brainstorming) — ready to implement

## Problem

On cloudbox the 4-serve pool (`:4096`–`:4099`) is badly concentrated: ~23 of 28
attached TUIs land on serve-0 (`:4096`). serve-0 carries the most RSS/CPU and
stalls under load spikes (a launched session took >3 min to begin its agent loop
because serve-0 was contended).

### Root cause (verified 2026-06-29)

The TUI spawner (`oc_auto_attach.lua`) just forwards a URL chosen by
`pkgs/oc-auto-attach`, which asks pigeon `GET /route?session_id=<sid>` for the
owning serve and **falls back to `OPENCODE_URL` (`:4096`) on any miss**.
`opencode-launch` does the same after creating the session.

`GET /route` is deliberately read-only (the `pigeon-eup` phantom-route fix) and
its prospective-route fallback is **gated on an assignment already existing**
(`router.ts:110 resolveProspectiveRoute → if (!a) return null`). Assignments are
only created on pigeon's in-process control/swarm paths
(`OpencodeClientFactory.forSession → ensureRouted`); plain `POST /session-start`
only registers the session, it does not place it.

Measured: **20 of 28 attached sessions have no `session_assignment` row** →
`/route` 404s → both clients fall back to `:4096`. The 8 with rows route
correctly (0 serve mismatches). So routing is sound; the gap is that most
sessions are **never placed**.

The `POST /place` primitive (idempotent `ensureRouted`, HRW + `ACTIVE_TURN_CAP`)
exists but **nothing calls it** — the "client migration" item the pigeon routing
README explicitly defers.

## Decision

Wire `POST /place` into the two **pool** entry points (`opencode-launch`,
`oc-auto-attach`) as the authoritative owner-serve selection, **keeping the
existing `:4096` fallback** so any pigeon hiccup degrades to today's
single-serve behavior ("never worse"). This is approach A.

### Out of scope (separate work)
- **Plain/interactive `opencode`**: self-hosts its own embedded server, does not
  load the pigeon plugin, and is not in the pool — it is neither placed nor
  dumped on `:4096`. Pooling interactive `opencode` is a separate design
  (delegated to a separate opus-4.8 session).
- **Re-placing the 20 currently-concentrated live sessions**: left to drain; the
  nightly reset re-attaches them through the new path and distributes them.

## Prerequisite (DONE)

`POST /place` merged to pigeon `main` (ff `efa231a`, pushed). The running daemon
was already started from that exact commit, so no restart was needed. Live smoke
test passed: a session created on serve-2 was placed by `/place` onto serve-1
(HRW), and `GET /route` then honored it.

## Design

### `pkgs/opencode-launch/default.nix`
After `POST $OPENCODE_URL/session` (creates the row + sid; the DB is shared so
any serve is fine), replace the `GET /route` owner-resolution with
`POST $PIGEON_DAEMON_URL/place` (JSON body `{"session_id": "<sid>"}`). Parse
`api_base`; on any failure (curl error, non-2xx, missing field) fall back to
`OPENCODE_URL`. Use the resolved `serve_url` for MCP-connect, `prompt_async`, and
the printed attach hint (unchanged downstream). The session was just created, so
placing it cannot manufacture a phantom assignment.

### `pkgs/oc-auto-attach/default.nix`
Ordering matters: do not place a session before confirming it exists (phantom
assignment hazard). So:
1. Keep `GET /route` (read-only) as the **probe-target** resolver (Step 0,
   unchanged) — used only to pick a serve for the existence probe.
2. Step 1 existence probe unchanged (classifies FOUND/MISS/WAIT, yields
   `session_dir`).
3. **After FOUND**, `POST /place` to get the authoritative owner; set the attach
   `serve_url` to its `api_base`, falling back to the Step-0 `serve_url` (which
   itself falls back to `OPENCODE_URL`) on any failure. Use that for the
   `opencode attach` URL.

### Shared
- `parse_serve_url` made tolerant of both response shapes:
  `jq -r '.apiBase // .api_base // empty'` (route is camelCase, place is
  snake_case).
- Auth-aware helper: include `Authorization: Bearer $PIGEON_DAEMON_AUTH_TOKEN`
  on the `POST /place` call iff the env var is set (matches `daemon-client.ts`;
  currently unset, future-proof for when pigeon auth is enabled).

## Error / fallback behavior
Every `/place` failure path → `OPENCODE_URL` (`:4096`). No new hard dependency on
pigeon; identical degradation to today. The only change is the happy path now
distributes.

## Testing
- `pkgs/oc-auto-attach/test-project-key.sh`: update the source-grep guard
  (currently asserts `GET /route?session_id=`) to also assert the new
  `POST .../place` call; extend `parse_serve_url` tests to cover an `api_base`
  body and the dual-key tolerance; add a no-`api_base` → fallback case.
- Manual: after `home-manager switch`, `opencode-launch` a throwaway session and
  confirm its TUI/agent land off `:4096`; re-run `oc-auto-attach <sid>` for an
  existing session and confirm the attach URL is the placed owner. Verify the
  next nightly reset spreads attachments across `:4096`–`:4099`.

## Deploy
`home-manager switch --flake .#cloudbox` rebuilds both client tools (no serve
restart). New `opencode-launch`es distribute immediately; the next nightly reset
distributes the reopened TUIs (and bootstraps assignments so subsequent
`GET /route`s resolve to distributed owners).
