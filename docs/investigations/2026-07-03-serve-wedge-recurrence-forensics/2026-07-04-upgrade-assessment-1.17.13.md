# 1.17.7 -> 1.17.13 upgrade assessment (2026-07-04)

Written here because `bd update` is blocked by a pending schema migration
(v49 -> v53, see morning items). Also relayed to the user via
ses_0d4127d19ffeFgfvxDTBPlQnLj (msg_mr6c35lk_33a8199a).

**Recommendation: yes, worth doing — as a dedicated one-day rebase pass after
the patched.13 wedge fix soaks for 1-2 days.**

- Delta: 556 commits / 1,505 files (v1.17.8-13: session snapshots + revert,
  managed provider integrations, MCP resource tools, MCP OAuth fixes,
  copilot/reasoning fixes). Nothing burning — the fix we needed most
  (Integration.list bulk read) is already backported in patched.13.
- Drops on upgrade (verified): `integration-list-batch` (native in 1.17.13),
  `event-log-gate` (upstream gate commit b0017bf1b9 is an ancestor of
  v1.17.13; verify semantics at rebase time — event.ts rewritten, 460 changed
  lines).
- Still needed on 1.17.13: `available-cache` (upstream still recomputes the
  ~5,331-model projection per /api/model call), project-copy-debounce,
  step-end-diff-bound, compaction-bounded-load (no filterCompacted paging
  upstream), gemini-empty-parts, cache-thinking-skip, tool-fix, retry-cap,
  and the whole serve-pool/TUI set.
- Re-apply risk: 15/19 patches touch upstream-changed files.
  - Heavy: serve-lease (prompt.ts, 322 changed lines), available-cache
    re-port (catalog.ts, 180 — new resolveConnections/reload shape),
    cache-thinking-skip + gemini-empty-parts (transform.ts, 155).
  - Moderate: app.tsx drift (105) for attach-route-resolve/vim/
    bootstrap-disposed-filter.
  - Light: vim's prompt/index.tsx only 6 lines drift; tui util/sse.ts,
    util/route.ts, context/sdk.tsx have ZERO upstream delta.
- Hidden cost: upstream is mid-v2 refactor in location/instance/event
  plumbing — re-run the yl00 / serve-lease / event-scoping verification
  recipes on .13, not just clean applies.
- Shape: cutover-runbook pattern
  (docs/plans/2026-06-11-opencode-1.17-cutover-runbook.md in opencode-patched)
  + check-sunset.yml; pin to whatever tag is current at rebase time.

## Morning items
- `bd` on devbox refuses writes: 4 pending schema migrations (v49 -> v53)
  against the remote-backed dolt DB. Decide the designated migrator machine,
  then `BD_ALLOW_REMOTE_MIGRATE=1 bd migrate && bd dolt push` there and
  `bd bootstrap` elsewhere. All of tonight's bead writes (g3iy close + notes,
  hbc3 creation, the wedge memory) landed BEFORE the guard tripped and are
  safe.
