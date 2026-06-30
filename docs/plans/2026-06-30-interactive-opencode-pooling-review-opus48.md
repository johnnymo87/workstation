# Adversarial review: interactive `opencode` pooling (Phase 2)

- **Reviewer:** opus-4.8 (adversarial / red-team)
- **Date:** 2026-06-30
- **Doc under review:** `docs/plans/2026-06-30-interactive-opencode-pooling-design.md`
- **Verdict:** **SHIP-WITH-CHANGES**

## Verdict (one paragraph)

The core architecture is sound and faithfully mirrors the landed Phase-1
pattern (create → `POST /place` → use-owner, with `parse_serve_url` fallback),
the shadow-function mechanism is proven (the `dd()` precedent in
`home.base.nix:1283`), and the decision to avoid an `opencode-patched` change is
well-justified because the merged attach patches already do owner re-resolution
and submit-follow. **But the design has real correctness holes that must close
before implementation:** (1) the RESUME path derives `--dir` from the CLI/`$PWD`
instead of the session's stored `.directory`, which will *freeze the TUI* on the
exact event-filter mechanism the doc itself cites; (2) the "never worse than
today" guarantee fails in the pigeon-down-but-serve-up window — NEW concentrates
on `:4096` and RESUME can fail-closed against a lease-contended owner, where
today's self-host always works; (3) the arg classifier is under-specified and
the proposed test list omits the dangerous cases (trailing `-s`, `=`-form,
project-before-sid, no-value `-s`) that would let a RESUME be mis-pooled as a
brand-new empty session; (4) the cross-host "safe because it self-hosts where no
pool exists" claim is factually wrong — pigeon + serves run on *all four* hosts,
so K=1 crostini will concentrate every interactive TUI on a single Chromebook
serve; and (5) piped-stdin prompts (`echo … | opencode`) are silently dropped
because `attach` ignores stdin. All five are fixable inside the current design;
none invalidate the approach.

---

## Findings (severity-ranked)

### MAJOR-1 — RESUME passes the wrong `--dir` → frozen TUI

**Claim/section:** Control flow, `RESUME <sid>` (design lines 171-178): `dir =
abs(<project>) or $PWD`, then `attach … --session "$sid" --dir "$dir"`. The doc
discards the `GET /session/<sid>` body (it only checks the status code at line
173).

**Why it's wrong/risky:** The design *itself* states (lines 183-185, echoing
`assets/nvim/lua/user/oc_auto_attach.lua:10-21`) that `--dir` is load-bearing
because the TUI event-filter drops events whose directory ≠ the instance
directory. For a resume, the authoritative directory is the session's **stored**
`.directory` (returned by `GET /session/<sid>` and by `GET /route` consumers),
*not* the directory the user happens to be standing in. The event filter is real
in the deployed tree (`…/tui/context/event.ts:28`, cited by the lua) and present
in the in-repo checkout too (`event.ts:19`: `event.directory === "global" ||
event.project === project.project()`). So `opencode -s ses_x` run from `$HOME`,
from a different worktree, or from any cwd ≠ the session's creation dir will
attach with `--dir=$PWD`, the event filter will drop every turn, and the TUI
freezes — the precise failure mode the doc claims to avoid. The Phase-1 sibling
this design says it "mirrors" goes to deliberate trouble to avoid exactly this:
`pkgs/oc-auto-attach/default.nix:286-340` extracts `session_dir` from
`GET /session` and threads it through as `--dir`. Phase 2 regresses against its
own sibling.

**Suggested fix:** In RESUME, parse `.directory` from the `GET /session/<sid>`
response body (which the wrapper already fetches) and pass *that* as `--dir`.
For symmetry and to dodge canonicalization drift (symlinks/trailing-slash:
`abs()` in the wrapper vs the serve's stored form), do the same in NEW — read
`.directory` back from the `POST /session` create response and use it as `--dir`
rather than the locally-computed `dir`. This makes `--dir` always the
server-canonical session directory in both paths.

---

### MAJOR-2 — "Never worse than today" fails when pigeon is down but a serve is up

**Claim/section:** "Error / fallback behavior" (lines 208-220): "pool down →
self-host (= today); pool up, pigeon flaky → attach `:4096` (≥ today)." And
NEW/RESUME both do `serve_url = parse_serve_url(place_body, OPENCODE_URL)` so any
`/place` failure degrades to `:4096`.

**Why it's wrong/risky:** The interactive baseline being protected is
**self-host** (an isolated embedded server), not `:4096`. Two degraded-mode
branches are strictly worse than that baseline:

1. **NEW, pigeon down, `:4096` serve up.** The flow health-checks only `:4096`
   (line 161), then creates the session (line 163) *before* it ever talks to
   pigeon. When `/place` then fails, it falls back to `:4096` and attaches there
   (lines 167-169). Result: the fresh interactive session piles onto the busiest
   anchor serve — re-creating the very serve-0 contention/3-min-stall that iwpj
   set out to kill — whereas today it would have been an isolated, instant
   embedded TUI. It also leaves the eager empty session committed on `:4096`.
   This is *not* "byte-for-byte today's behavior."

2. **RESUME, pigeon down/contended.** `POST /place` can return **409
   `LeaseContendedError`** or **503 `NoHealthyServeError`** (pigeon
   `packages/daemon/src/app.ts:565-569`). Because the call uses `curl -sf`, a
   409/503 yields an empty body → `parse_serve_url` → `:4096`. If the session is
   actually owned by serve-2 with a held lease, the wrapper now attaches the TUI
   to `:4096` (a non-owner). Under serve-lease enforcement a non-owner serve
   **rejects the prompt** (this is exactly the hazard the `tui-follow-owner`
   patch comments call out: "a non-owner serve can reject a prompt under
   serve-lease enforcement"), and `/route` re-resolution also needs pigeon
   (down) — so the user is stuck on a serve that cannot run their turn, where
   today self-host always works.

**Suggested fix:**
- **NEW:** probe pigeon reachability *before* `POST /session` (e.g. a cheap
  `GET $PIGEON/route?session_id=ses_health` or a daemon health endpoint, with a
  short `--connect-timeout`). If pigeon is unreachable, self-host immediately —
  nothing has been created, so this is a clean byte-for-byte fallback and avoids
  both the `:4096` concentration and the orphan-empty-session. (You can't cleanly
  self-host *after* create without orphaning/double-creating, which is precisely
  why the check must precede create.)
- **RESUME:** since RESUME creates nothing, on any `/place` non-2xx
  (409/503/timeout) **self-host** (`exec <real-opencode> "$@"`) instead of
  attaching `:4096`. Optionally, on a 409 specifically, fall back to a read-only
  `GET /route` to find the real owner and attach there before giving up to
  self-host. Either is strictly safer than the current `:4096` attach.
- Soften the doc's blanket "never worse" claim to scope it to the
  pigeon-reachable case, or implement the pre-checks so the claim holds.

---

### MAJOR-3 — Arg classifier under-specified; test list misses the dangerous cases

**Claim/section:** "Scope" (lines 125-149) and "Testing" (lines 244-254). RESUME
is described only as `opencode -s <sid> [project]` / `--session <sid> [project]`;
the unit-test enumeration (lines 247-249) tests only leading `-s ses_x` /
`--session ses_x`.

**Why it's wrong/risky:** The mis-classification that matters is RESUME → NEW,
because it silently *drops the user's resume intent and creates a fresh empty
session instead* (a real correctness regression vs today, which resumes). A
position-sensitive classifier (one that inspects `$1` only, or stops scanning at
the first positional) breaks on real invocations that the proposed tests would
never catch:

- `opencode <project> -s ses_x` — trailing `-s`. yargs (`thread.ts:79-114`,
  `$0 [project]` + `--session`) accepts this and resumes today. A `$1`-only
  classifier sees a path positional → NEW → **creates a new session, ignores the
  resume.** Not in scope text, not in tests.
- `opencode -s ses_x <project>` — RESUME *with* a project; the classifier must
  capture both the sid *and* the project (for `--dir`). Not tested.
- `opencode --session=ses_x` / `opencode -sSID` (attached `=`/short-value forms;
  cf. how `opencode-launch` must special-case `--model=*`,
  `pkgs/opencode-launch/default.nix:120-127`). At minimum these must resolve to a
  *defined* class (RESUME or safe PASSTHROUGH), with a test.
- `opencode -s` with **no value** — must guard (empty sid → garbage `POST
  /place`/`GET /session`). Not tested.
- `opencode -s ses_x --model Y` — RESUME token *plus* an attach-incompatible flag
  must be PASSTHROUGH (can't be expressed as an attach). Not tested.
- Exact-token boundary cases: `opencode ./serve`, `opencode runfoo`,
  `opencode -- <project>` — must be NEW/PASSTHROUGH via *exact* first-token match
  (a substring/prefix match would misfire). Not tested.

The doc's "default to PASSTHROUGH on doubt" only saves you for the *unrecognized*
shapes; it does **not** save the trailing-`-s` case, because that shape parses as
a valid NEW-looking positional and will be confidently mis-pooled.

**Suggested fix:** Specify `classify_oc_invocation` to scan the *entire* argv (a)
for any attach-incompatible flag or known subcommand as first token → PASSTHROUGH;
(b) for exactly one `-s`/`--session`/`--session=`/`-sSID` occurrence with a
non-empty value → RESUME, capturing the lone remaining positional as the project
regardless of order; (c) zero flags + ≤1 positional → NEW; (d) everything else →
PASSTHROUGH. Validate the sid against `^ses_[A-Za-z0-9_-]+$` (matches pigeon's
`/route` regex, `app.ts:577`) before any interpolation; a bad sid → PASSTHROUGH.
Add explicit tests for *every* bullet above, especially `opencode <project> -s
ses_x` → `RESUME ses_x` with the project captured.

---

### MAJOR-4 — Cross-host "safe because it self-hosts where no pool" is factually wrong

**Claim/section:** Packaging (lines 121-123): "Shared placement in
`home.base.nix` is safe on every host (devbox K=2, cloudbox K=4, crostini K=1,
darwin K=2): where no pool/pigeon is reachable the placer self-hosts (= today)."

**Why it's wrong/risky:** pigeon-daemon **and** opencode serves run on *all four*
hosts, not just cloudbox — verified: `users/dev/home.crostini.nix:94`
(`pigeon-daemon`) and `:135` (`opencode-serve`); `home.devbox.nix` (14 pigeon
refs, `opencode-serve@` at `:455`); `home.darwin.nix` (`pigeon-daemon` launchd
at `:99`, serves at `:221`); plus `serve-pool.nix:35-40` sizing all four. So the
"self-hosts where no pool is reachable" escape hatch **never triggers on a
healthy host** — the wrapper will pool everywhere. The K=1 crostini consequence
is the opposite of safe: today each interactive `opencode` is an isolated
embedded server; post-Phase-2 *every* interactive TUI on the Chromebook is forced
to attach to the single `:4096` serve (create → place → HRW-over-1 → `:4096` →
attach `:4096`), concentrating all interactive agent loops onto one process on
the most resource-constrained host. That is the serve-0 contention pattern in
miniature, newly introduced where it didn't exist.

**Suggested fix:** Gate pooling on pool size: only install/activate the shadow
function (or only let the placer pool) when `K ≥ 2`. The cleanest lever is
`serve-pool.nix` (`forHost.<host>.k`): make `home.base.nix` add the function via
`lib.mkIf (servePool.k >= 2)`, or pass `K`/anchor info to the placer and have it
PASSTHROUGH-self-host when `K == 1`. Either keeps the K=1 host byte-for-byte
today. Independently, fix the doc's safety rationale — the real argument is "K=1
self-host is preserved by gating," not "no pool is reachable."

---

### MAJOR-5 — Piped-stdin prompts are silently dropped

**Claim/section:** Implicit in NEW classification (lines 129-131) + the "NEW →
attach" flow.

**Why it's wrong/risky:** Bare `opencode` reads piped stdin as the initial prompt
(`thread.ts:66-71` `input()`; `:189` `await input(args.prompt)`), so today
`echo "fix the failing test" | opencode` (or `opencode < prompt.txt`) launches a
TUI seeded with that prompt. `opencode attach` has **no** `input()`/stdin read
(`attach.ts` and the patched `cmd/attach.ts` take only flags). The shadow
function is defined in interactive shells, and a pipeline command's stdin is the
pipe even in an interactive shell — so the wrapper classifies bare → NEW →
`attach`, and the piped prompt is **silently lost** (the worst failure class:
no error, just dropped input). `--prompt "x"` is safe (it's in the PASSTHROUGH
flag list, line 138), but the piped form has no flag to catch.

**Suggested fix:** PASSTHROUGH (self-host) whenever stdin is not a TTY: add `! [
-t 0 ] && exec <real-opencode> "$@"` at the top of the NEW branch (or fold it
into the classifier). Add a test asserting non-TTY stdin → PASSTHROUGH.

---

### MINOR-1 — Config-driven `external` server is invisible to an argv-only classifier

`resolveNetworkOptionsNoConfig` (`network.ts:49-56`) derives `external` from the
config file too — `config?.server?.port` / `server.hostname` / `server.mdns` —
not just argv (`thread.ts:193-199`). If a user's `opencode.json` sets
`server.port` (or hostname/mdns), bare `opencode` self-hosts a *real external
server*, but the classifier (argv-only) sees NEW and pools it — a divergence
from today. Unlikely on cloudbox, but latent. Fix: document the limitation, or
have the placer also PASSTHROUGH when the resolved opencode config sets a
non-default `server.*`.

### MINOR-2 — Preserve pristine argv for the self-host fallback `exec`

Every fallback is `exec <real-opencode> "$@"`, claimed byte-for-byte (lines
156-178, 210). `opencode-launch` consumes `"$@"` via `while … shift`
(`default.nix:110-176`); if the placer's classifier mutates positional params
before a fallback, the self-host exec loses args. Snapshot argv (e.g. operate on
a copy / capture `original_args=("$@")`) and exec the original. Add a test that
the fallback exec uses the unmodified argv.

### MINOR-3 — Validate the sid before interpolating it into curl URLs

`oc-auto-attach` hard-validates `^ses_[A-Za-z0-9]+$` before any shell
interpolation (`default.nix:229`). The Phase-2 RESUME path interpolates the raw
sid into `GET …/session/<sid>` and `POST /place {session_id: sid}`. Mirror the
validation (and align with pigeon's `^ses_[A-Za-z0-9_-]+$`, `app.ts:577`); a
malformed sid → PASSTHROUGH.

### MINOR-4 — RESUME of a session currently self-hosted elsewhere

If a session is live in another embedded process (a pre-rollout TUI, or one
started via `command opencode`), its row exists in the shared `OPENCODE_DB`
(`home.base.nix:741`), so `GET /session` returns 200 and `POST /place` will
assign it to a pool serve while it's effectively "running" embedded — a
dual-owner window. This is a pre-existing shared-DB hazard, but Phase 2 widens
it (resume now actively places). Worth a sentence in Residuals; not blocking.

### MINOR-5 — "Strictly better than today" for the in-TUI-new-session residual is overstated

Residuals (lines 226-233) claim an in-TUI new session is "strictly better than
today (it's on a pool serve, not an embedded ephemeral one)." For a power user
who spawns N sessions inside one attached TUI, all N land unplaced on that *one
shared* pool serve — a new contention vector against other tenants of that serve,
which the isolated embedded server did not have. It's a trade-off (better RSS,
possibly worse contention), not strictly better. Reword to "better for memory,
still concentrates per-TUI bursts," and keep the Phase-3 (place-on-in-TUI-create)
deferral gated on measurement.

---

## NITs

- **NIT-1 — Open-question-4 rationale is slightly off.** The doc (lines 192-201,
  and TL;DR lines 34-37) motivates `POST /place` in RESUME via "patched `attach
  --session` with no url errors out." But the wrapper *always* passes an explicit
  `serve_url` positional, so `fallback = args.url` is non-empty and the patch's
  `if (!url)` error (`attach-route-resolve.patch:39-45`) is never reached. The
  real reasons to place are distribution + making `GET /route` resolve for the
  follow-owner SSE. Belt-and-suspenders is fine; just fix the wording so a future
  reader doesn't "simplify" by dropping the explicit url.
- **NIT-2 — Explicit-url + different `/route` owner flip on first connect.**
  Patched attach calls `resolveServeUrl(sid, fallback=serve_url)` even with an
  explicit url; if pigeon re-placed in the µs between `/place` and `exec`, attach
  follows `/route`'s owner. Harmless (it's still a valid owner, no event gap on
  first connect). No action.
- **NIT-3 — Post-`exec` has no self-host fallback if the placed (non-anchor)
  serve dies in the window.** Only `:4096` is health-checked, not the placed
  owner. Largely closed because pigeon places only on healthy serves
  (`NoHealthyServeError` → 503 → `:4096`), but `validateSession` against a freshly
  dead owner would `exitCode 1` rather than self-host. Acceptably narrow.
- **NIT-4 — `type opencode` / `command -v opencode` now report a function.**
  Cosmetic; path-sniffing tooling that expects a binary path could be confused.
  `command opencode` remains the documented escape hatch.

---

## What the design got right

- **Pattern fidelity.** create → `POST /place` → use-owner with the verbatim
  `parse_serve_url` dual-key (`.api_base`/`.apiBase`) fallback is a faithful copy
  of the landed Phase-1 code (`pkgs/opencode-launch/default.nix:30-38, 255-285`),
  including the auth-aware `/place` header.
- **Create-then-place ordering.** Correctly verified that `POST /session` ignores
  a caller-supplied id (design fact #3), so place-before-create is impossible;
  NEW creates exactly once and RESUME creates nothing — no double-create, and the
  only "orphan" is the acknowledged eager-empty-session.
- **Existence-check-before-place for RESUME.** `GET /session` before `POST /place`
  correctly avoids the pigeon-eup phantom-assignment hazard (mirrors
  `oc-auto-attach` Step-1.5, `default.nix:342-362`); placing an unknown sid would
  manufacture a phantom route (`app.ts:541-573` has no existence gate).
- **No `opencode-patched` change.** Justified: `attach` is already a full
  pool-aware, self-healing `tui()` (`attach-route-resolve.patch` +
  `tui-follow-owner.patch` do `resolveServeUrl` on connect and an owner-drift
  poll with confirm-twice + degrade-hard), so the wrapper only needs to land the
  initial attach.
- **Shadow-function mechanism is proven.** `programs.bash.initExtra` sits *after*
  the `[[ $- == *i* ]] || return` interactive guard, so the function is
  interactive-only — directly confirmed by the existing `dd()` function and its
  comment (`home.base.nix:1277-1285`). nvim `jobstart` (a list-form spawn, no
  shell) and systemd/launchd units (absolute paths) are correctly unaffected, and
  `command oc-pool-attach` + store-path references to the real binary avoid PATH
  recursion. Not-`exec`ing the function (so it doesn't replace the login shell)
  is the right call.
- **Split-brain for the *initial* session is genuinely handled** (place completes
  before `exec attach`; first prompt + submit-client target the placed owner).
- **PASSTHROUGH cut is honestly scoped.** `-c`/`--model`/`--agent`/`--prompt`/
  `--port`… are correctly identified as inexpressible-as-attach and routed to
  self-host (consistent with `attach.ts`'s limited flag set, design fact #6).
