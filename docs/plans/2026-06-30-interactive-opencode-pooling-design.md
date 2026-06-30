# Pool interactive `opencode`: a shadow function + tested placer

- **Date:** 2026-06-30
- **Bead:** workstation-jiae (Phase 2; discovered-from workstation-iwpj)
- **Status:** approved (brainstorming) — ready to implement (implementation NOT
  yet authorized; deploy/push gated on explicit user authority)
- **Host of design:** cloudbox (K=4 pool `:4096`–`:4099`, pigeon `:4731`)
- **Branch / worktree:** `iwpj-phase2-interactive` at `~/projects/ws-iwpj-phase2`
- **Predecessors:**
  - `docs/plans/2026-06-24-serve-load-distribution-iwpj-design.md` (root-cause +
    Phase 1/2 split)
  - `docs/plans/2026-06-29-place-on-launch-and-attach-design.md` (Phase 1, landed
    `fcb882a`; the create→`POST /place`→use-owner pattern this mirrors)

---

## TL;DR

Phase 1 made `opencode-launch` and `oc-auto-attach` place their sessions via
pigeon `POST /place`, so headless launches and TUI re-attaches now distribute
across the pool (post-reset spread 8/4/4/2, was ~23/28 concentrated on `:4096`).

The remaining gap — and per iwpj the **dominant** persistent-SSE load — is
plain/interactive `opencode` run directly in a terminal. Bare `opencode` spawns
its **own in-process embedded server** (`TuiThreadCommand`, the `$0 [project]`
default; transport `http://opencode.internal` via a `Worker`,
`thread.ts:201-211`), so the session is hosted off-pool: pigeon can't route to
it, it never distributes, and the serve-side lease code is dormant for it (no
`OPENCODE_SERVE_ID` / `OPENCODE_ROUTING_DB` in an interactive shell).

**Fix:** a transparent shadow `opencode()` bash function (interactive shells
only) delegates to a new tested `pkgs/` **placer** that, for a fresh interactive
TUI start (or an explicit `-s <sid>` resume), creates+places a session on a pool
serve and `exec`s `opencode attach <owner> --session <sid> --dir <dir>` instead
of letting opencode self-host. Everything else passes through verbatim. Any
pool/pigeon outage degrades to self-hosting — byte-for-byte today's behavior, so
it is **never worse**.

**No `opencode-patched` change.** `opencode attach` is already a full `tui()`
renderer (UX parity) and already pool-aware + self-healing (attach-route-resolve
+ tui-follow-owner: it re-resolves the owning serve via `GET /route` and rebuilds
the submit client on every SSE reconnect). The wrapper only has to land the
*initial* attach on the placed owner; the patched TUI handles migration.

---

## Verified facts (cloudbox, 2026-06-30)

1. **Bare `opencode` self-hosts.** `TuiThreadCommand` (`$0 [project]`,
   `packages/opencode/src/cli/cmd/tui/thread.ts:79-262`) spawns an in-process
   `Worker` and uses the in-process transport (`http://opencode.internal`,
   `thread.ts:207-211`) UNLESS `--port`/`--hostname`/`--mdns` is given. So the
   session, its agent loop, and its SSE bus all live in a server pigeon does not
   know about and cannot route to.
2. **`opencode attach` is the same full TUI and is already pool-aware.**
   `AttachCommand` calls the identical `tui()` renderer (`attach.ts`), so session
   list / new-session / switching all work; the only difference is a remote
   transport. The `opencode-patched` `attach-route-resolve.patch` makes the `url`
   positional optional and resolves the owner via `resolveServeUrl` (pigeon
   `GET /route`); `tui-follow-owner` re-resolves + rebuilds the client on every
   SSE reconnect so REST/control submits follow a migrated session.
3. **`POST /session` ignores a caller-supplied id.** Sending
   `{"id":"ses_TESTPLACE001"}` returned a server-generated
   `ses_0e73ea9ecffe…` (throwaway deleted). So we must **create-then-place**
   (like opencode-launch), not place-before-create.
4. **pigeon `POST /place`** (`packages/daemon/src/app.ts:541-573`) takes
   `{session_id}`, runs `ensureRouted` (`resolveRoute ?? placeSession`, HRW +
   `ACTIVE_TURN_CAP`), and returns `api_base`/`serve_id`/… There is no
   server-side existence gate, so the caller is responsible for only placing real
   sessions (we do — create first for NEW, `GET /session` first for RESUME).
5. **No existing `opencode` wrapper.** `opencode` on PATH is the patched package
   binary directly. `OPENCODE_DB` is shared via `home.sessionVariables`, so the
   embedded server uses the same DB — but is still off-pool/off-pigeon.
6. **`opencode attach` flag set is limited:** `--dir`, `-c/--continue`,
   `-s/--session`, `--fork`, `-p/-u` (auth). It does NOT accept `--model`,
   `--agent`, `--prompt`, `--port`, `--hostname`, `--mdns`, `--cors`. This
   bounds which invocations can be expressed as an attach (see Scope).

---

## Decision

Adopt the **out-of-band wrapper** (iwpj option a-ii), exactly mirroring the
Phase-1 create→`POST /place`→use-owner pattern, packaged as:

- a new tested `pkgs/` placer (all logic; pure helpers; `test.sh` with a
  source-grep lockstep guard), plus
- a thin shadow `opencode()` **bash function** in interactive shells that
  delegates to it.

### Why not patch the TUI (iwpj option a-i)

Bare `opencode` *always* spins up its in-process `Worker` first. To pool-join,
the TUI would have to skip self-hosting and instead create-on-a-pool-serve — a
substantial change to opencode's startup, carrying an `opencode-patched` rebase
liability on every upstream bump, a patched-release build, and a pool
deploy. The wrapper achieves the same distribution with none of that, *because*
the heavy lifting (owner re-resolution, submit-client follow) already lives in
the merged attach patches. Patch is not justified; revisit only if the
documented in-TUI-new-session residual (below) proves material.

---

## Design

### Packaging

- **Placer** — `pkgs/<name>/default.nix` (`writeShellApplication`, name TBD e.g.
  `oc-pool-attach`). Holds `classify_oc_invocation`, `parse_serve_url`, and the
  create/place/attach flow. References the real opencode binary by nix store
  path (`${opencode}/bin/opencode`) for both self-host fallback and the `attach`
  exec — no PATH recursion.
- **Shadow function** — in `users/dev/home.base.nix` via
  `programs.bash.initExtra` (placed *after* the `~/.bashrc` interactivity guard,
  so it exists only in interactive shells — precisely the human/agent
  interactive-TUI case). One-liner:
  `opencode() { command oc-pool-attach "$@"; }` (final name TBD). Because the
  function is absent from non-interactive shells, nvim `jobstart`, systemd serve
  units (absolute path), and the Phase-1 tools are all unaffected.

  Shared placement in `home.base.nix` is safe on every host (devbox K=2,
  cloudbox K=4, crostini K=1, darwin K=2): where no pool/pigeon is reachable the
  placer self-hosts (= today). Roll out + validate on cloudbox first.

### Scope (which invocations are pooled)

`classify_oc_invocation argv…` (pure; unit-tested) returns exactly one of:

- **`NEW`** — bare `opencode`, or `opencode <project>` (a path positional), with
  no session-affecting / attach-incompatible flags.
- **`RESUME <sid>`** — `opencode -s <sid> [project]` /
  `opencode --session <sid> [project]`.
- **`PASSTHROUGH`** — everything else. Triggers on **any** of:
  - a known subcommand as the first token: `completion acp mcp attach run debug
    providers auth agent upgrade uninstall serve web models stats export import
    github pr session plugin plug db`;
  - an attach-incompatible flag: `--model -m --agent --prompt --port --hostname
    --mdns --cors -c --continue --fork --pure --help -h --version -v
    --print-logs --log-level`;
  - anything ambiguous/unrecognized.

**Default to `PASSTHROUGH` on any doubt** — a mis-pool is a regression; a
mis-passthrough is just today's self-host (never worse).

Rationale for the cut: `-c` (continue-last) can't be expressed as an attach
(patched `attach -c` with neither url nor session errors out), and
`--model/--agent/--prompt/--port/…` aren't attach flags, so those self-host.
This still captures the dominant "cd into a repo, run `opencode`" case plus
explicit `-s` resumes.

### Control flow (the placer)

```
classify_oc_invocation "$@"  ->  NEW | RESUME <sid> | PASSTHROUGH

PASSTHROUGH:
    exec <real-opencode> "$@"                      # verbatim; today's behavior

NEW:
    dir = abs(<project>) or $PWD
    if ! health-check OPENCODE_URL (:4096):
        exec <real-opencode> "$@"                  # pool down -> self-host (=today)
    resp = POST OPENCODE_URL/session  (x-opencode-directory: dir)
    if create failed:
        exec <real-opencode> "$@"                  # nothing created -> self-host
    sid = resp.id
    place_body = POST PIGEON/place {session_id: sid}
    serve_url  = parse_serve_url(place_body, OPENCODE_URL)   # place hiccup -> :4096
    exec <real-opencode> attach "$serve_url" --session "$sid" --dir "$dir"

RESUME <sid>:
    dir = abs(<project>) or $PWD
    code = GET OPENCODE_URL/session/<sid>          # confirm it exists (no phantom)
    if 404 / unreachable:
        exec <real-opencode> "$@"                  # let opencode handle / self-host
    place_body = POST PIGEON/place {session_id: sid}
    serve_url  = parse_serve_url(place_body, OPENCODE_URL)
    exec <real-opencode> attach "$serve_url" --session "$sid" --dir "$dir"
```

`OPENCODE_URL` defaults to `http://127.0.0.1:4096`, `PIGEON_DAEMON_URL` to
`http://127.0.0.1:4731` (same conventions as opencode-launch / oc-auto-attach).
The `--dir` is load-bearing: opencode-serve runs with `WorkingDirectory=/home/dev`,
and the TUI event-filter drops events whose directory ≠ the instance directory
(see `oc_auto_attach.lua` header + `2026-04-28-attach-tui-frozen-fix-design.md`).

`parse_serve_url` is the Phase-1 helper verbatim: accepts both `.api_base`
(`/place`) and `.apiBase` (`/route`); fallback on empty/garbage/missing field.
Include `Authorization: Bearer $PIGEON_DAEMON_AUTH_TOKEN` on `/place` iff the env
var is set (future-proofing, matches oc-auto-attach).

### Open-question answers

1. **Wrapper vs patch** → wrapper (shadow function); **no** opencode-patched
   change. Justified above by attach already being a full, pool-aware,
   self-healing TUI.
2. **Does `POST /session` accept a caller-supplied id?** → **No** (verified).
   Create-then-place.
3. **Split-brain** → placement completes *before* `exec attach`, so the user's
   first prompt runs on the placed owner and the patched submit client targets
   the resolved owner. No split-brain for the initial session.
4. **Interaction with nvim / manual attach** → none. `attach` is `PASSTHROUGH`,
   and the function doesn't exist in nvim's non-interactive `jobstart` shell. The
   Phase-1 tools are separate commands. Nothing is duplicated or broken.

---

## Error / fallback behavior ("never worse than single-serve")

The outermost fallback is **self-host** (`exec <real-opencode> "$@"`), which is
byte-for-byte today's interactive behavior — chosen over a `:4096`-attach
fallback because if `:4096` is itself down, attaching to it would be *worse* than
self-hosting, whereas self-host always works (it is what happens today). We
self-host only when the anchor is unreachable or session create/lookup fails.

Within the pool-reachable branch, a `/place` hiccup degrades to the anchor
`:4096` via `parse_serve_url` (identical to opencode-launch). So: pool down →
self-host (= today); pool up, pigeon flaky → attach `:4096` (≥ today); healthy →
attach the HRW owner (distributed). The change can only improve distribution,
never strand an interactive user.

---

## Residual / known limitations (documented, not blocking)

- **In-TUI new sessions.** A session created *inside* an attached TUI (the
  "new session" action) is created on the serve the TUI is attached to and is
  **not** `POST /place`d, so it runs fail-open on that one serve (no HRW spread,
  no lease). This is **strictly better than today** (it's on a pool serve, not an
  embedded ephemeral one), and aggregate distribution still holds because each
  fresh `opencode` *start* HRW-distributes its first session. Closing this would
  need a small TUI patch (`POST /place` on session create + rebuild submit
  client) — deferred to a possible Phase 3, gated on measured impact.
- **`-c` / `--model` / `--agent` / `--prompt` / `--port` starts self-host** (out
  of attach's expressible surface). Coverage gap, safe by construction.
- **Eager empty session row.** `NEW` creates a session before the user types
  anything; an immediate quit leaves an empty session (same as opencode-launch).
  Minor litter; session list / nightly cleanup absorb it.

---

## Testing (mirrors `pkgs/opencode-launch/test.sh`)

- **Unit (`pkgs/<name>/test.sh`, pure helpers + source-grep lockstep guard):**
  - `classify_oc_invocation`: bare → `NEW`; `<project>` → `NEW` (dir captured);
    `-s ses_x` / `--session ses_x` → `RESUME ses_x`; `attach` / `serve` / `run` /
    `mcp` / `db` (and the rest) → `PASSTHROUGH`; `--model` / `-m` / `--agent` /
    `--prompt` / `--port` / `--hostname` / `-c` / `--pure` / `-h` / `-v` →
    `PASSTHROUGH`; mixed/ambiguous → `PASSTHROUGH`.
  - `parse_serve_url`: `.api_base` body, `.apiBase` body, dual-key tolerance,
    empty/garbage/missing-field → fallback.
  - Source-grep guard asserting the placer actually calls `POST .../place`,
    `POST .../session`, `GET .../session/`, and `attach … --session … --dir …`
    (kept in lockstep, the established pattern).
- **Manual cloudbox (post-deploy, gated on authority):** run `opencode` in a
  repo → TUI attaches to a non-`:4096` serve and a `session_assignment` row
  exists for the new sid on its owner; `opencode -s <sid>` → attaches to the
  placed owner; stop pigeon → `opencode` self-hosts (no error, = today). Confirm
  the next nightly reset's interactive TUIs spread across `:4096`–`:4099`.

---

## Rollout (gated on explicit user authority — NOT part of this task)

1. Implement the placer + `test.sh` (TDD), then the `home.base.nix` function.
2. `home-manager switch --flake .#cloudbox`; validate as above on cloudbox first.
3. Only then consider the other hosts (safe by construction; self-hosts where no
   pool).

No `opencode serve` restart is needed (clients-only change). No
`opencode-patched` release.
