# opencode-launch pool-aware serve resolution (mn9r M7) — design

**Date:** 2026-06-21
**Bead:** workstation-2g14
**Status:** approved, implementing
**Follows:** 2026-06-21-oc-auto-attach-pool-route-design.md (same `/route` pattern)

## Problem

`opencode-launch` (defined inline in `users/dev/home.base.nix:7-235`) drives the
entire create→prompt lifecycle against a hardwired `OPENCODE_URL` (=`:4096` =
serve-0):

- `:154` health `GET /global/health`
- `:161` create `POST /session`
- `:176-178` **MCP-connect** `POST /mcp/<srv>/connect` (per `--mcp`)
- `:207` prompt `POST /session/<id>/prompt_async`
- `:232-233` printed attach/kill hints

Under the K=2 pool this pins **every launched session's first turn AND its MCP
tools to serve-0**, regardless of which serve pigeon's rendezvous hashing makes
the owner. Consequences:
1. No pool load distribution for launches — everything runs on serve-0.
2. The first turn can run on serve-0 while `/route` (and now the TUI, post
   oc-auto-attach fix) points at serve-1 → transient stale view / split runtime.
3. **MCP tools connect on the wrong serve**: MCP connections are per-serve-
   process/in-memory, so if tools connect on serve-0 but the agent loop runs on
   serve-1, those tools are absent from the run.

Placement is a **pure function of the sid** (`pigeon router.ts placeSession →
pickServe → sha256(serveId:sessionId)`), independent of which serve created the
row, so **create-then-route is safe**: create writes only the shared-DB row.

## Approach

After `POST /session` yields `$session_id`, resolve the owning serve and target
the owner for MCP-connect + prompt + hints:

1. Health-check + `POST /session` stay on `$OPENCODE_URL` (serve-0 always exists
   per `serve-pool.nix`; create just writes the shared DB row, no sid yet).
2. Resolve `serve_url` = `parse_serve_url( GET $PIGEON_DAEMON_URL/route?session_id=$session_id , $OPENCODE_URL )`.
   Fall back to `$OPENCODE_URL` on any pigeon failure (never worse than today).
3. MCP-connect → `$serve_url/mcp/<srv>/connect`.
4. prompt → `$serve_url/session/$session_id/prompt_async`.
5. attach/kill hints → `$serve_url`.
6. `oc-auto-attach` handoff unchanged (it already does its own `/route`).

New env `PIGEON_DAEMON_URL` (default `http://127.0.0.1:4731`), matching
oc-auto-attach / opencode-send convention.

Net: a launched session's runtime serve == `/route` owner == TUI attach serve ==
MCP-tool serve, and launches distribute across the pool.

Rejected: delegating to a pigeon `/launch` endpoint — pigeon's launch-ingest is
the *telegram* launch path; the CLI keeps create-then-route (in-repo, no pigeon
change). (Telegram launch-ingest is a parallel gap → separate follow-up.)

## Structure: extract to `pkgs/opencode-launch/`

Per decision, move opencode-launch out of `home.base.nix` into
`pkgs/opencode-launch/{default.nix,test.sh}`, mirroring `oc-auto-attach`, to get
a unit-test harness + shellcheck-on-build:

- `pkgs/opencode-launch/default.nix` — `{ pkgs }: pkgs.writeShellApplication {…}`
  (verbatim move + the `/route` changes above + `parse_serve_url` helper).
- `flake.nix:53 localPkgsFor` — add `opencode-launch = p.callPackage ./pkgs/opencode-launch { };`
  (also exposes `nix build .#opencode-launch`).
- `home.base.nix` — delete the inline `let` def (`:7-235`); change the
  `home.packages` entry `:526` from `opencode-launch` → `localPkgs.opencode-launch`.

## Implementation order

1. **Refactor (no behavior change):** extract the *current* script verbatim to
   `pkgs/opencode-launch/default.nix`; wire flake + home.base.nix; `nix build
   .#opencode-launch` green (shellcheck clean), confirm script unchanged.
2. **TDD the feature:** add `test.sh` (mirror `parse_serve_url` + 6 behavioral
   cases + source guards: defines `parse_serve_url`, references
   `PIGEON_DAEMON_URL`, `/route?session_id=`, and uses `serve_url` for the
   prompt + MCP connect). Watch source guards fail RED, implement the `/route`
   wiring, GREEN. `nix build .#opencode-launch` green.

## Testing

- Unit: `pkgs/opencode-launch/test.sh` (`parse_serve_url` happy/empty/garbage/
  no-apiBase/null/empty → fallback) + source-sync grep guards.
- Build gate: `nix build .#opencode-launch` (shellcheck).
- Live integration (optional, on running pool): `opencode-launch ~ "say hi"`,
  capture sid, confirm prompt was delivered to `GET /route` owner.

## Scope / limitations / follow-ups

- Owner-down edge: health-check is on serve-0 only; if `/route` returns a down
  owner the prompt POST fails loudly (acceptable; fallback covers no-route).
- Telegram launch-ingest (pigeon) has the same serve-0 pinning → separate bead.
- Does not change create-on-serve-0 (correct: no sid before create).
