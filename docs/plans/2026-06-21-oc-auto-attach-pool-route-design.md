# oc-auto-attach pool-aware serve resolution (mn9r M7, minimal slice) — design

**Date:** 2026-06-21
**Bead:** workstation-b4n5
**Status:** approved, implementing

## Problem

With the K=2 `opencode serve` pool deployed (ports 4096 + 4097, sharing one
`opencode.db`), the pigeon ingress router distributes sessions across **both**
serves via rendezvous (HRW) hashing. But every TUI is launched by
`oc-auto-attach`, which hardwires `OPENCODE_URL=http://127.0.0.1:4096` and
passes it to `opencode attach`. opencode's streaming event bus
(`Bus.subscribeAll`) is **in-memory, per-process**; the two serves do not share
it. So when pigeon delivers a turn (session→session swarm, or telegram revive)
to a session whose HRW owner is serve-1 (4097), the agent loop runs on 4097 and
emits events on 4097's bus, while the TUI's `/event` SSE stream is connected to
4096 — the TUI never receives those events and renders stale.

Confirmed live (2026-06-21): 4 of 5 eternal-machinery TUIs were attached to
:4096 while pigeon's `GET /route` placed them on serve-1/:4097.

This is the unbuilt client half of the pool design (mn9r **M7**). The
server-side prerequisite is NOT required for this slice: per-session `/event`
filtering is an optimization; correctness only needs the TUI to attach to the
serve that actually runs the session. The `--dir` event-filter fix
(workstation-gsi Fix A) is already shipped, so once attached to the right serve
the session's events pass the directory filter.

## Approach (A — launcher-side discovery)

`oc-auto-attach` resolves the owning serve via the pigeon daemon's discovery
endpoint and attaches the TUI there.

- New env `PIGEON_DAEMON_URL` (default `http://127.0.0.1:4731`), matching the
  existing convention used by `opencode-send` (`home.base.nix`).
- Before the session-dir wait, `curl -sf --connect-timeout 2 --max-time 3
  "$PIGEON_DAEMON_URL/route?session_id=$sid"`; parse `.apiBase`.
- On success → use that `apiBase` as the working URL for BOTH the dir-wait
  (Step 1) and the URL handed to `opencode attach` (the nvim payload).
- On ANY failure (pigeon down, non-200, empty/garbage body, missing/empty
  `.apiBase`) → **fall back to `$OPENCODE_URL`** (today's :4096 behavior). The
  fix can never be worse than current behavior.

Rejected alternatives:
- **B. Pin all placement to serve-0** — defeats K=2 (it's K=1 in disguise).
- **C. Patch `opencode attach` to self-resolve + re-resolve on reconnect** —
  most robust (covers manual attach + idle-migration) but needs an
  opencode-patched binary patch + upgrade maintenance. Deferred as follow-up.

## Implementation

Single source file: `pkgs/oc-auto-attach/default.nix`, plus its test mirror
`pkgs/oc-auto-attach/test-project-key.sh`.

Factor the parse + fallback into a pure, network-free function so it is
unit-testable in the existing harness:

```bash
# parse_serve_url <route-json-body> <fallback-url>
#   Extract .apiBase from a pigeon /route JSON body. Falls back to
#   <fallback-url> when the body is empty, not JSON, or .apiBase is
#   absent/null/empty.
parse_serve_url() {
  local body="$1" fallback="$2" api
  api="$(printf '%s' "$body" | jq -r '.apiBase // empty' 2>/dev/null || true)"
  if [ -n "$api" ] && [ "$api" != "null" ]; then
    printf '%s\n' "$api"
  else
    printf '%s\n' "$fallback"
  fi
}
```

Production caller does the network I/O, then delegates parsing:

```bash
PIGEON_DAEMON_URL="${PIGEON_DAEMON_URL:-http://127.0.0.1:4731}"
route_body="$(curl -sf --connect-timeout 2 --max-time 3 \
  "$PIGEON_DAEMON_URL/route?session_id=$sid" 2>/dev/null || true)"
serve_url="$(parse_serve_url "$route_body" "$OPENCODE_URL")"
```

`$serve_url` then replaces `$OPENCODE_URL` in the Step-1 dir-wait and in the
jq-built nvim payload (`url:$serve_url`).

## Testing (TDD, existing harness)

Behavioral unit tests against the `parse_serve_url` mirror:
- valid JSON `{"apiBase":"http://127.0.0.1:4097",...}` → returns `:4097`.
- empty body → returns fallback.
- non-JSON garbage → returns fallback.
- JSON without `apiBase` → returns fallback.
- `apiBase: null` → returns fallback.
- `apiBase: ""` → returns fallback.

Source-sync guards (grep `default.nix`) keeping source and mirror in lockstep,
matching the existing pattern:
- defines `parse_serve_url()`.
- references `PIGEON_DAEMON_URL`.
- references `/route?session_id=`.

Red→green: the source guards fail before editing `default.nix`; implementing the
function + rewiring makes them pass. Build gate: `nix build` the package (or
`nix flake check` / per-host eval) green.

## Scope / limitations (follow-up beads)

- Does NOT follow idle-migration after attach (acceptable: HRW is deterministic
  in a healthy pool; migration only on serve health change → re-attach). → C.
- Does NOT cover hand-typed `opencode attach`. → C / wrapper.
- Other M7 consumers (`opencode-send`, `lgtm`, `reset-workspace`, pigeon
  `OPENCODE_URL`, fp-digest, `opencode-llm-audit`) and `:4096` removal remain.

## Rollout

The 5 currently-attached TUIs stay on :4096 until re-attached. After
build+deploy, remediation is operational (kill stale attach + re-run
`oc-auto-attach <sid>`, or let the next revive re-attach correctly). User
handles remediation.
