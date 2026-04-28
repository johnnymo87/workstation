# Design: Bare opencode TUI restoration via cwd→sid resolution (P2.5)

**Status:** Approved 2026-04-27. Implementation plan to follow.

**Predecessor:** `docs/plans/2026-04-27-reset-workspace-snapshot-fix-design.md` (workstation-0gu — narrow strict-pgrep fix, shipped at e170356).

**Bead:** TBD (filed after this doc lands).

## Goal

Extend `reset-workspace` so that bare `:te opencode` TUIs (which have no `--session` in their argv) survive nightly reset, by resolving their `/proc/<pid>/cwd` to the most-recent root session for that directory via `opencode-serve`'s `GET /session` API, then restoring them as attach clients in step 6.5.

**Net effect:** every opencode TUI alive at snapshot time comes back across reset, regardless of launch flavor (Telegram `/launch`, `opencode-launch` CLI, or bare `:te opencode`). After restoration, all restored TUIs are uniformly attach-mode clients — so the next reset's strict-pgrep captures all of them via argv, with no special bare-TUI logic needed for already-restored sessions.

## Constraints

- Script-only change to `pkgs/reset-workspace/default.nix`. No opencode source patches.
- Must work in the existing nightly systemd timer path (no pty, runs as `User=dev`).
- Must continue to work for the strict-attach contract shipped in workstation-0gu (don't break the working case).
- Cloudbox: NixOS aarch64-linux, single user.
- `opencode-serve` is alive at step 2 time (we restart it in step 5, so it must be up before that).

## Architecture

### Substrate (already proven, no changes needed)

- `pkgs/oc-auto-attach/default.nix`: takes a sid, finds-or-creates a tmux window for the session's project cwd, sends `:te opencode attach $url --session $sid` into the nvim there.
- `reset-workspace` step 6.5: iterates `OPENCODE_MANIFEST` (newline-separated sids), calls `oc-auto-attach $sid` per entry.
- Step 2's existing strict-attach pgrep loop (workstation-0gu): captures `(sid)` from `opencode attach … --session ses_xxx` argv form via the strict regex anchored on `^[^[:space:]]+/opencode[[:space:]]+attach[[:space:]]+https?://[^[:space:]]+[[:space:]]+--session[[:space:]]+(ses_[A-Za-z0-9]+)$`.
- Step 2's existing bare-TUI enumeration loop: walks all opencode-exe processes, filters out `opencode serve` and `opencode attach`, currently emits a `WARNING: bare opencode TUI pid=X cwd=Y will NOT be restored` per skipped TUI.

### The change

Replace the bare-TUI enumeration loop's WARNING-only behavior with **resolve-or-warn**:

For each bare opencode TUI found:
1. Read `/proc/<pid>/cwd`. If unreadable, log WARNING and skip.
2. Curl `GET $OPENCODE_URL/session?directory=$cwd&roots=true&limit=1`.
3. Parse the response with `jq -r '.[0].id // empty'`.
4. Validate the sid against `^ses_[A-Za-z0-9]+$`.
5. If a valid sid is returned: log `pid=$pid (bare-resolved) sid=$sid cwd=$cwd` and append the sid to `OPENCODE_MANIFEST`.
6. If no sid (empty response, malformed sid, or curl failure): log `WARNING: bare opencode TUI pid=$pid cwd=$cwd has no resolvable session in DB; skipping restoration`.

The dedupe pass (`awk 'NF && !seen[$0]++'`) at the end of step 2 handles the rare case where a strict-attach sid and a bare-resolved sid coincide (e.g., the user opened `opencode -s ses_xxx` against the same sid as a live `opencode attach`).

Counters split for observability:
- `OPENCODE_STRICT_COUNT`: sids captured via strict-attach pgrep
- `OPENCODE_BARE_RESOLVED`: sids resolved from bare-TUI cwds
- `OPENCODE_BARE_SKIPPED`: bare TUIs whose cwd had no resolvable sid (or unreadable cwd)
- `OPENCODE_COUNT = strict + bare_resolved` (after dedupe — this is what drives step 6.5's loop)

Summary log line:
```
captured N restorable session(s) (M strict-attach + K bare-resolved); J bare TUI(s) skipped
```

### Why this works

`GET /session?directory=$cwd&roots=true&limit=1` (verified live against http://127.0.0.1:4096):
- Returns sessions where `session.directory = $cwd` exactly.
- `roots=true` filters out child sessions (those with non-null `parent_id`) — this matters because subagent sessions accumulate in the DB and we don't want to restore them as if they were the user's main session.
- Default sort is `time.updated DESC`, so `limit=1` gives the most-recently-updated root for that cwd — i.e., "the session the user was most likely viewing".

The resolution happens during step 2 (before any kill) for two reasons:
1. Serve must be alive — at step 2 time it's still in its pre-restart state, alive and serving.
2. We need to read `/proc/<pid>/cwd` from live processes. By step 4 (kill nvims) and step 5 (restart serve), bare TUIs are dead and their `/proc/<pid>/cwd` is gone.

### Restoration (no changes)

`oc-auto-attach $sid` already does the right thing for any sid passed to it: queries `GET /session/$sid` to get the session's directory, then finds-or-creates a tmux window for that project_key and sends `:te opencode attach $OPENCODE_URL --session $sid` into the nvim. Since bare-resolved sids end up in `OPENCODE_MANIFEST` alongside strict-attach sids, step 6.5 calls `oc-auto-attach` for each uniformly. No bare-vs-attach branching at restoration time.

**Side effect:** post-restoration, every restored TUI is now an `opencode attach` client. Next reset's strict-pgrep captures all of them via argv directly — bare-resolved code path only fires for newly-launched bare TUIs since the previous reset.

## Skill doc update

Replace the existing "What survives a reset" section in `.opencode/skills/resetting-workspace/SKILL.md` with the new contract documenting both restoration paths (direct via argv, resolved via cwd), the edge case for multiple bare TUIs in the same cwd (they all collapse to the same sid), and the new summary log line format.

## Edge cases

| Scenario | Behavior |
|---|---|
| Bare TUI in cwd with valid recent session | ✅ Resolved + restored as attach client |
| Bare TUI in cwd with no session (just opened, never used) | Logged as skipped, not restored |
| Bare TUI cwd unreadable (`/proc/<pid>/cwd` returns error) | Logged as skipped, not restored |
| Two bare TUIs in same cwd | Both resolve to same sid → dedupe collapses to one restoration. User loses one of the two windows. P4 (runtime manifest) would solve this precisely. |
| `opencode-serve` unhealthy at step 2 | curl returns non-zero, sid is empty, all bare TUIs logged as skipped. Strict-attach captures still work. Manual investigation needed. |
| `jq` missing from PATH | Same as above (jq -r returns nothing). The `pkgs/reset-workspace/default.nix` Nix derivation should declare `jq` in its `runtimeInputs` to prevent this. |
| Session resolved exists in DB but `oc-auto-attach $sid` fails | Already handled by the existing `WARNING: oc-auto-attach $sid returned non-zero` log line in step 6.5. |
| Bare-resolved sid matches a strict-attach sid (user opened `opencode -s ses_xxx` against an active attach session) | Dedupe collapses; one restoration. Idempotent. |

## Out of scope (deferred follow-ups)

### Tear-down + rebuild simplification (the broader architectural cleanup)

The pre-P2.5 conversation surfaced an instinct to delete `reset-workspace` step 1 (snapshot tmux nvim panes) and step 6 (respawn nvims via send-keys), relying entirely on the opencode-aware restore path (oc-auto-attach creates fresh tmux windows + nvims per restored sid). With P2.5 in place, every opencode TUI is uniformly captured and restored, which **makes that simplification coherent** — there's no longer a need for two parallel restoration mechanisms.

We are explicitly NOT shipping that simplification with P2.5, for these reasons:

- P2.5 is intentionally narrow ("just extend step 2") to keep the diff small and the risk low.
- Deleting step 1 + step 6 changes the behavior for users who have nvim panes WITHOUT opencode TUIs in them (pure-editor sessions). Those would not survive reset under the simpler model. That's a behavior change deserving its own discussion.
- It's reversible: P2.5 doesn't lock us in to keeping step 1 + step 6 forever.

**Trigger to revisit:** if step 1's tmux snapshot or step 6's send-keys respawn proves fragile (e.g., breaks under user-typing race conditions like the one we hit during Task 4's interactive verification), or if maintenance of the parallel-paths design becomes painful, file a new bead with this as the design starting point. Reference this doc and the workstation-0gu plan for context.

### P4 — runtime manifest at `$XDG_RUNTIME_DIR/opencode/tui/<pid>.json`

A TUI-side patch that writes `{pid, mode, cwd, url, sessionID, lastSeen}` per TUI. Reset reads manifests instead of (or in addition to) cwd resolution. Solves the "two bare TUIs in same cwd" ambiguity precisely. Bigger surgery (requires opencode source patch in opencode-patched). File as separate bead. Defer until cwd-latest proves ambiguous in practice.

### P3 — opt-in `OPENCODE_ATTACH_URL` patch routing bare TUI through serve

Architectural unification: patch `thread.ts` to detect `$OPENCODE_ATTACH_URL/global/health` before Worker creation; if healthy, construct the TUI's transport with native HTTP fetch to that URL instead of spawning a private worker. Falls back to worker on failure. Per ChatGPT's analysis: should be **opt-in** via env var (not silent default), and a source patch (not a wrapper script) so IDE/scripts/internal invocations inherit the behavior. Need to think carefully about MCP/tool scoping (a per-TUI worker's MCP tools vs a long-lived serve's MCP tools) and reconnect-on-serve-restart behavior. File as separate bead. Reference upstream issues #8948, #7629, #6461, #17322 for prior art.

## Implementation note

The new bare-TUI resolution loop should:
- Inherit the existing exe-basename guard (`readlink /proc/$pid/exe` must basename-match `\.?opencode(-wrapped)?`) — this was added during workstation-0gu's amend and prevents pgrep over-match noise.
- Use the existing `OPENCODE_URL` variable (already exported at the top of the script with default `http://127.0.0.1:4096`).
- Add `jq` to the Nix derivation's `runtimeInputs` if not already present.
- Verify via the same nightly-restart-background.service path used for workstation-0gu (no pty interference).

## Done when

- `pkgs/reset-workspace/default.nix` step 2 resolves bare TUIs via cwd and appends to `OPENCODE_MANIFEST`.
- `.opencode/skills/resetting-workspace/SKILL.md` documents the two-path contract.
- Live verification via `sudo systemctl --no-block start nightly-restart-background.service` shows journal lines for `pid=X (bare-resolved) sid=Y cwd=Z` and the updated summary line.
- A bead is filed with this doc and the implementation plan referenced.
