# Pool interactive `opencode`: a shadow function + tested placer

- **Date:** 2026-06-30
- **Bead:** workstation-jiae (Phase 2; discovered-from workstation-iwpj)
- **Status:** approved (brainstorming); **v2 — revised after opus-4.8 adversarial
  review.** Implementation NOT yet authorized; deploy/push gated on explicit user
  authority.
- **Host of design:** cloudbox (K=4 pool `:4096`–`:4099`, pigeon `:4731`)
- **Branch / worktree:** `iwpj-phase2-interactive` at `~/projects/ws-iwpj-phase2`
- **Predecessors:**
  - `docs/plans/2026-06-24-serve-load-distribution-iwpj-design.md` (root-cause +
    Phase 1/2 split)
  - `docs/plans/2026-06-29-place-on-launch-and-attach-design.md` (Phase 1, landed
    `fcb882a`; the create→`POST /place`→use-owner pattern this mirrors)
- **Adversarial review:**
  `docs/plans/2026-06-30-interactive-opencode-pooling-review-opus48.md` (verdict
  SHIP-WITH-CHANGES; this v2 folds in all 5 MAJOR + the MINOR/NIT findings).

### Changelog v1 → v2 (review fixes)

- **MAJOR-1:** `--dir` now comes from the session's **server-stored
  `.directory`** (read back from `POST /session` for NEW, `GET /session/<sid>` for
  RESUME), not `$PWD`/`<project>` — else the TUI event-filter freezes a resume
  run from any other cwd.
- **MAJOR-2:** NEW **pre-checks pigeon reachability before creating** (pigeon down
  → self-host, nothing created, no `:4096` pile-on / orphan). RESUME **self-hosts
  on any `/place` non-2xx** (409/503/timeout) instead of attaching `:4096` to a
  non-owner serve that would reject the prompt under lease enforcement.
- **MAJOR-3:** classifier scans the **whole argv** (captures `-s`/project in any
  order, `=`/short-attached forms, guards empty sid, validates the sid regex);
  test list expanded to the dangerous mis-classification cases.
- **MAJOR-4:** pooling is **gated on `K ≥ 2`** (`serve-pool.nix forHost.<host>.k`)
  so the K=1 crostini host stays self-host (pigeon+serves run on *all* hosts, so
  "self-host where no pool" never triggers otherwise).
- **MAJOR-5:** **non-TTY stdin → PASSTHROUGH** (`echo … | opencode` seeds a prompt
  via stdin that `attach` would silently drop).
- **MINOR/NIT:** snapshot pristine argv for the fallback `exec`; validate sid
  before interpolation; document the config-driven `server.*` external case;
  reword the RESUME-place rationale (it's for distribution + `/route` resolution,
  not an "empty-url error"); soften the in-TUI-new-session residual wording.

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
it, it never distributes, and the serve-side lease code is dormant for it.

**Fix:** a transparent shadow `opencode()` bash function (interactive shells
only) delegates to a new tested `pkgs/` **placer** that, for a fresh interactive
TUI start (or an explicit `-s <sid>` resume), creates+places a session on a pool
serve and `exec`s `opencode attach <owner> --session <sid> --dir <server-dir>`
instead of letting opencode self-host. Everything else passes through verbatim.
Any pool/pigeon outage degrades to self-hosting — byte-for-byte today's behavior
— so it is **never worse**.

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
   `thread.ts:207-211`) UNLESS `external` is true. **`external` is derived from
   BOTH argv AND config** (`network.ts`/`resolveNetworkOptionsNoConfig`): argv
   `--port`/`--hostname`/`--mdns` (`thread.ts:193-199`) *or* a non-default
   `server.{port,hostname,mdns}` in `opencode.json` (see MINOR-1).
2. **Bare `opencode` reads piped stdin as the prompt.** `input(args.prompt)`
   (`thread.ts:189`, `input()` at `:66-71`) consumes stdin, so
   `echo "…" | opencode` and `opencode < f` seed the first prompt. `attach` has
   **no** stdin read (`attach.ts`). → MAJOR-5 guard.
3. **`opencode attach` is the same full TUI and is already pool-aware.**
   `AttachCommand` calls the identical `tui()` renderer (`attach.ts`), so session
   list / new-session / switching all work; only the transport differs. The
   `opencode-patched` `attach-route-resolve.patch` makes the `url` positional
   optional and resolves the owner via `resolveServeUrl` (pigeon `GET /route`);
   `tui-follow-owner` re-resolves + rebuilds the client on every SSE reconnect so
   REST/control submits follow a migrated session.
4. **`POST /session` ignores a caller-supplied id.** Sending
   `{"id":"ses_TESTPLACE001"}` returned a server-generated `ses_0e73ea9ecffe…`
   (throwaway deleted). So we must **create-then-place**, not place-before-create.
   The `POST /session` response includes the canonical `.directory`.
5. **pigeon `POST /place`** (`packages/daemon/src/app.ts:541-573`) takes
   `{session_id}`, runs `ensureRouted` (HRW + `ACTIVE_TURN_CAP`), returns
   `api_base`/`serve_id`/…, and can return **409 `LeaseContendedError`** or
   **503 `NoHealthyServeError`** (`app.ts:565-569`). There is no server-side
   existence gate — the caller must only place real sessions (we do: create first
   for NEW; `GET /session` first for RESUME, mirroring oc-auto-attach Step-1.5).
6. **`opencode attach` flag set is limited:** `--dir`, `-c/--continue`,
   `-s/--session`, `--fork`, `-p/-u` (auth). It does NOT accept `--model`,
   `--agent`, `--prompt`, `--port`, `--hostname`, `--mdns`, `--cors`. This bounds
   which invocations can be expressed as an attach (see Scope).
7. **No existing `opencode` wrapper.** `opencode` on PATH is the patched package
   binary directly. `OPENCODE_DB` is shared via `home.sessionVariables`
   (`home.base.nix:741`), so the embedded server uses the same DB — still
   off-pool/off-pigeon. The shadow-function mechanism is proven by the existing
   `dd()` function (`home.base.nix:1277-1285`), defined in `programs.bash`'s
   interactive section (after the `[[ $- == *i* ]] || return` guard).
8. **pigeon + serves run on all four hosts** (not cloudbox-only):
   `home.crostini.nix:94,135`, `home.devbox.nix` (`opencode-serve@`),
   `home.darwin.nix:99,221`, plus `serve-pool.nix:35-40`. → MAJOR-4 gate.

---

## Decision

Adopt the **out-of-band wrapper** (iwpj option a-ii), mirroring the Phase-1
create→`POST /place`→use-owner pattern, packaged as:

- a new tested `pkgs/` placer (all logic; pure helpers; `test.sh` with a
  source-grep lockstep guard), plus
- a thin shadow `opencode()` **bash function** in interactive shells (gated on
  `K ≥ 2`) that delegates to it.

### Why not patch the TUI (iwpj option a-i)

Bare `opencode` *always* spins up its in-process `Worker` first. To pool-join,
the TUI would have to skip self-hosting and create-on-a-pool-serve — a
substantial startup change carrying an `opencode-patched` rebase liability on
every upstream bump, a patched-release build, and a pool deploy. The wrapper
achieves the same distribution with none of that, *because* owner re-resolution
and submit-follow already live in the merged attach patches. Revisit only if the
documented in-TUI-new-session residual proves material.

---

## Design

### Packaging

- **Placer** — `pkgs/<name>/default.nix` (`writeShellApplication`, name TBD e.g.
  `oc-pool-attach`). Holds `classify_oc_invocation`, `parse_serve_url`, and the
  create/place/attach flow. References the real opencode binary by nix store path
  (`${opencode}/bin/opencode`) for both self-host fallback and the `attach` exec
  — no PATH recursion.
- **Shadow function** — in `users/dev/home.base.nix` via `programs.bash` interactive
  init (after the `~/.bashrc` interactivity guard, like `dd()`), so it exists only
  in interactive shells. One-liner: `opencode() { command oc-pool-attach "$@"; }`
  (final name TBD). It does **not** `exec` (must not replace the login shell);
  the *placer* `exec`s. Because the function is absent from non-interactive
  shells, nvim `jobstart` (list-form spawn, no shell), systemd/launchd serves
  (absolute path), and the Phase-1 tools are all unaffected.

  **Gate on `K ≥ 2` (MAJOR-4):** add the function only where the host's pool has
  ≥2 serves: `lib.mkIf (servePoolK >= 2)` with `servePoolK` resolved per host
  from `serve-pool.nix` (`forHost.<host>.k`). The placer ALSO defensively
  PASSTHROUGHs if told `K == 1` (belt-and-suspenders). This keeps the K=1
  crostini host byte-for-byte today (no forced concentration on its single
  serve).

### Scope (which invocations are pooled)

`classify_oc_invocation argv…` (pure; unit-tested) scans the **entire** argv and
returns exactly one of:

- **`PASSTHROUGH`** (checked FIRST; default on any doubt) if **any** of:
  - the first non-flag token is a known subcommand (exact match): `completion acp
    mcp attach run debug providers auth agent upgrade uninstall serve web models
    stats export import github pr session plugin plug db`;
  - any token is an attach-incompatible flag: `--model -m --agent --prompt --port
    --hostname --mdns --cors -c --continue --fork --pure --help -h --version -v
    --print-logs --log-level` (and their `=value` forms);
  - a `-s`/`--session` is present but its value is empty/missing, or the sid fails
    `^ses_[A-Za-z0-9_-]+$` (pigeon's regex, `app.ts:577`);
  - more than one positional remains after extracting the optional project, or any
    unrecognized shape.
- **`RESUME <sid> [project]`** if exactly one `-s <sid>` / `--session <sid>` /
  `--session=<sid>` / `-s<sid>` occurrence with a valid sid, in **any order**
  relative to the project positional, and no PASSTHROUGH trigger. Captures both
  the sid and the (optional) lone project positional.
- **`NEW [project]`** if zero session/attach-incompatible flags and ≤1 positional
  (the project path).

**RESUME→NEW mis-classification is the dangerous case** (it would silently drop
the resume and create a fresh empty session). The whole-argv scan exists
specifically to catch trailing `-s` (`opencode <project> -s ses_x`).

### Control flow (the placer)

```
original_args=("$@")                       # MINOR-2: pristine snapshot for fallback
class = classify_oc_invocation "$@"        # NEW [proj] | RESUME <sid> [proj] | PASSTHROUGH

# --- top guards (force self-host = today) ---
if K < 2:                       exec <real-opencode> "${original_args[@]}"   # MAJOR-4
if ! [ -t 0 ] (stdin not a TTY): exec <real-opencode> "${original_args[@]}"  # MAJOR-5 (piped prompt)
if class == PASSTHROUGH:         exec <real-opencode> "${original_args[@]}"

# --- NEW ---
NEW [project]:
    # MAJOR-2: prove pigeon is reachable BEFORE creating anything.
    if ! pigeon_reachable():     exec <real-opencode> "${original_args[@]}"   # nothing created
    if ! health OPENCODE_URL:    exec <real-opencode> "${original_args[@]}"   # anchor down
    resp = POST OPENCODE_URL/session  (x-opencode-directory: abs(project|PWD))
    if create failed:            exec <real-opencode> "${original_args[@]}"
    sid = resp.id
    dir = resp.directory                       # MAJOR-1: server-canonical dir
    place = POST PIGEON/place {session_id: sid}
    serve_url = parse_serve_url(place, OPENCODE_URL)   # rare post-precheck race -> :4096
    exec <real-opencode> attach "$serve_url" --session "$sid" --dir "$dir"

# --- RESUME ---
RESUME <sid> [project]:
    # sid already regex-validated by the classifier.
    body,code = GET OPENCODE_URL/session/<sid>
    if code != 200:              exec <real-opencode> "${original_args[@]}"   # absent -> let opencode handle
    dir = body.directory                       # MAJOR-1: server-canonical dir
    place,code = POST PIGEON/place {session_id: sid}
    if code is not 2xx (409/503/timeout/empty):  exec <real-opencode> "${original_args[@]}"  # MAJOR-2
    serve_url = parse_serve_url(place, OPENCODE_URL)
    exec <real-opencode> attach "$serve_url" --session "$sid" --dir "$dir"
```

- `OPENCODE_URL` defaults to `http://127.0.0.1:4096`, `PIGEON_DAEMON_URL` to
  `http://127.0.0.1:4731` (opencode-launch / oc-auto-attach conventions).
- `pigeon_reachable()`: a short `--connect-timeout` probe of pigeon that treats
  **any** HTTP response as reachable (e.g. `GET /route?session_id=ses_probe` →
  400/404 both prove pigeon is up; `000`/timeout = down). Cheap, read-only.
- `parse_serve_url` = the Phase-1 helper verbatim: accepts `.api_base` (`/place`)
  and `.apiBase` (`/route`); fallback on empty/garbage/missing field. `/place`
  carries `Authorization: Bearer $PIGEON_DAEMON_AUTH_TOKEN` iff the env var is
  set (matches oc-auto-attach).
- **NEW post-precheck race** (pigeon healthy at precheck, `/place` fails at call):
  narrow; degrade to `:4096` via `parse_serve_url`. Optional hardening: `DELETE`
  the just-created session and self-host instead — deferred unless observed.
- `--dir` is **load-bearing**: opencode-serve runs with
  `WorkingDirectory=/home/dev`, and the TUI event-filter drops events whose
  directory ≠ the instance directory (`tui/context/event.ts`, see
  `oc_auto_attach.lua:10-21` + `2026-04-28-attach-tui-frozen-fix-design.md`).
  Using the **server-stored** `.directory` (not `$PWD`) is what makes a resume
  from any cwd render.

### Open-question answers

1. **Wrapper vs patch** → wrapper (shadow function); **no** opencode-patched
   change. Justified by attach already being a full, pool-aware, self-healing TUI.
2. **Does `POST /session` accept a caller-supplied id?** → **No** (verified).
   Create-then-place.
3. **Split-brain** → placement completes *before* `exec attach`, so the first
   prompt runs on the placed owner and the patched submit client targets the
   resolved owner. No split-brain for the initial session.
4. **Interaction with nvim / manual attach** → none. `attach` is `PASSTHROUGH`,
   and the function doesn't exist in nvim's non-interactive `jobstart` shell. The
   Phase-1 tools are separate commands. Nothing is duplicated or broken.
5. **Why place at all in RESUME** (NIT-1 correction) → NOT to dodge an
   "empty-url error" (the wrapper always passes an explicit `serve_url`, so
   patched attach never hits its `if (!url)` branch). Placement is for
   **distribution** (HRW assignment for a never-placed session) and to make
   `GET /route` resolve so the follow-owner SSE re-resolution works.

---

## Error / fallback behavior ("never worse than today")

The interactive baseline being protected is **self-host** (an isolated embedded
server) — chosen over a `:4096`-attach fallback because if `:4096` is down,
attaching to it is *worse* than self-hosting, whereas self-host always works (it
is what happens today). Concretely:

- **K=1 host** → self-host (gate). **Piped stdin** → self-host. **PASSTHROUGH** →
  self-host.
- **NEW, pigeon unreachable** → self-host **before** create (no `:4096` pile-on,
  no orphan session). **NEW, anchor down / create fails** → self-host.
- **RESUME, session absent** → self-host (opencode emits its native error).
  **RESUME, `/place` 409/503/timeout** → self-host (never attach a non-owner
  `:4096` that lease-enforcement would reject).
- **Healthy path** → attach the HRW owner (distributed). Narrow NEW place-race →
  `:4096` (≥ today for a fresh empty session).

So distribution can only improve; an interactive user is never stranded.

---

## Residual / known limitations (documented, not blocking)

- **In-TUI new sessions.** A session created *inside* an attached TUI is created
  on the attached serve and is **not** placed, so it runs fail-open there (no HRW
  spread, no lease). This is **better for memory** than today's embedded server,
  but for a power user spawning many sessions in one TUI it **concentrates those
  per-TUI bursts on one shared pool serve** (a contention vector the isolated
  embedded server lacked) — a trade-off, not strictly better. Aggregate spread
  still holds because each fresh `opencode` *start* HRW-distributes its first
  session. Closing this needs a small TUI patch (`POST /place` on session create
  + rebuild submit client) — deferred to a possible Phase 3, gated on measured
  impact.
- **`-c` / `--model` / `--agent` / `--prompt` / `--port` starts self-host** (out
  of attach's expressible surface). Coverage gap, safe by construction.
- **Config-driven external server (MINOR-1).** If `opencode.json` sets a
  non-default `server.{port,hostname,mdns}`, bare `opencode` self-hosts a real
  external server, but an argv-only classifier sees NEW and would pool it.
  Unlikely on these hosts; mitigation: have the placer also PASSTHROUGH when the
  resolved opencode config sets a non-default `server.*` (best-effort), else
  document the limitation.
- **RESUME of a session live elsewhere (MINOR-4).** A session running in another
  embedded process still has a row in the shared `OPENCODE_DB`, so `GET /session`
  is 200 and `POST /place` will assign it to a pool serve — a dual-owner window.
  Pre-existing shared-DB hazard that Phase 2 widens slightly; not blocking.
- **Eager empty session row.** `NEW` creates a session before the user types; an
  immediate quit leaves an empty session (same as opencode-launch). Minor litter.
- **Cosmetic (NIT-4).** `type opencode` / `command -v opencode` now report a
  function; `command opencode` is the escape hatch to the raw binary.

---

## Testing (mirrors `pkgs/opencode-launch/test.sh`)

- **Unit (`pkgs/<name>/test.sh`, pure helpers + source-grep lockstep guard):**
  - `classify_oc_invocation` — NEW: bare; `<project>` (dir captured). RESUME:
    `-s ses_x`; `--session ses_x`; `--session=ses_x`; `-sses_x`; **`<project> -s
    ses_x`** (trailing, project captured); `-s ses_x <project>`. PASSTHROUGH:
    every subcommand incl. exact-token boundaries (`./serve`, `runfoo`,
    `-- <project>`); `--model`/`-m`/`--agent`/`--prompt`/`--port`/`--hostname`/
    `-c`/`--pure`/`-h`/`-v`; `-s ses_x --model Y` (RESUME token + incompatible
    flag); `-s` with no value; `-s bad!sid` (regex fail); mixed/ambiguous.
  - `parse_serve_url`: `.api_base`, `.apiBase`, dual-key, empty/garbage/missing →
    fallback.
  - Source-grep guard asserting the placer calls `POST .../session`,
    `GET .../session/`, `POST .../place`, `attach … --session … --dir …`, the
    `[ -t 0 ]` stdin guard, the `K`/`pigeon_reachable` self-host guards, and uses
    the pristine `original_args` snapshot on every fallback `exec`.
- **Manual cloudbox (post-deploy, gated on authority):** `opencode` in a repo →
  TUI attaches to a non-`:4096` serve with a `session_assignment` row for the new
  sid on its owner; `opencode -s <sid>` from a *different cwd* → attaches to the
  placed owner and renders (MAJOR-1); `echo hi | opencode` → self-hosts and shows
  the prompt (MAJOR-5); stop pigeon → `opencode` self-hosts with no error
  (MAJOR-2). Confirm the next nightly reset spreads interactive TUIs across
  `:4096`–`:4099`.

---

## Rollout (gated on explicit user authority — NOT part of this task)

1. Implement the placer + `test.sh` (TDD), then the gated `home.base.nix`
   function.
2. `home-manager switch --flake .#cloudbox`; validate as above on cloudbox first.
3. Other K≥2 hosts (devbox/darwin) afterward; crostini (K=1) stays self-host by
   gate.

No `opencode serve` restart is needed (clients-only change). No `opencode-patched`
release.
