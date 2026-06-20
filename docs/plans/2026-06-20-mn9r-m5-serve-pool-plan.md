# mn9r M5 — Serve-Pool Supervisor Implementation Plan

> **For Claude:** This is a **workstation-tree** milestone (Nix config across 4 platforms) — the tree the USER controls and the sibling co-edits. Do NOT execute without explicit user go-ahead. When executing, use **superpowers:subagent-driven-development**, but note most "tests" here are `nix eval` / rebuild / `systemctl` runtime checks, not unit tests. **HIGH BLAST RADIUS** — this activates the dormant M4 lease path and replaces the single serve with a pool.

**Goal:** Boot and manage **K warm `opencode serve` processes** per host on fixed loopback ports, all sharing one `opencode.db`, each holding a serve identity + session leases (M4), with pigeon routing sessions across them — one restart fans out to the whole pool — deployed on all four devices (cloudbox, devbox, crostini, macOS).

**Architecture:** A systemd **target** (`opencode-serve-pool.target`) wanting K **templated** units (`opencode-serve@.service`, instance = port), each with a distinct `--port`, a stable `OPENCODE_SERVE_ID=serve-<i>`, the shared `OPENCODE_DB`, and `OPENCODE_ROUTING_DB` pointing at pigeon's DB (activates M4). Pigeon learns the K endpoints via `PIGEON_SERVE_ENDPOINTS` (index-aligned with serve ids) and switches to self-heartbeat liveness (`PIGEON_SERVE_LIVENESS=self`, the M4/Task-3b flag). macOS has no systemd target → emulate with K launchd agents + a fan-out restart wrapper.

**Tech stack:** NixOS systemd (system + `systemd.user`) templated units, nix-darwin `launchd.agents`, home-manager host-gating flags (`isCloudbox`/`isDevbox`/`isCrostini`/`isDarwin`), pigeon-daemon env, sops secrets.

---

## 0. Verified ground truth (recon 2026-06-20)

### Current single-serve launch sites
| Host | Kind | File | Lines | Mem cap | Notes |
|---|---|---|---|---|---|
| cloudbox | **system** `systemd.services.opencode-serve` | `hosts/cloudbox/configuration.nix` | **529–654** | MemoryMax 40G / High 32G | secrets exported from `/run/secrets/*` in ExecStart `writeShellScript`; `--port 4096 --hostname 127.0.0.1` at :634; `Restart=always`; no `restartIfChanged` (defaults true); After=`network.target sops-nix.service aigateway.service` |
| devbox | **user** `systemd.user.services.opencode-serve` | `users/dev/home.devbox.nix` | **425–474** | MemoryMax 10G / High 8G | secrets in ExecStart; `WantedBy=default.target` |
| crostini | **user** `systemd.user.services.opencode-serve` | `users/dev/home.crostini.nix` | **135–171** | uncapped | only `GOOGLE_GENERATIVE_AI_API_KEY` from sops |
| macOS | **launchd agent** `launchd.agents.opencode-serve` | `users/dev/home.darwin.nix` | **135–175** | none (no cgroup) | Keychain secrets via `security find-generic-password`; `KeepAlive=true` |

- **M2 groundwork already present** in every unit: `OPENCODE_DB=<...>/opencode.db` + `OPENCODE_DISABLE_CHANNEL_DB=1` (comment on cloudbox explicitly says "Required by the K-serve pool — every serve must share one DB").
- **No `OPENCODE_SERVER_PASSWORD`** set anywhere today.

### Pigeon-daemon launch sites
| Host | Kind | File | Lines | `OPENCODE_URL` |
|---|---|---|---|---|
| cloudbox | system | `hosts/cloudbox/configuration.nix` | 381–432 (target 435–438) | :426 `http://127.0.0.1:4096` |
| devbox | system | `hosts/devbox/configuration.nix` | 225–262 (target 265–268) | :256 `http://127.0.0.1:4096` |
| crostini | user | `users/dev/home.crostini.nix` | 94–132 | :121 `http://127.0.0.1:4096` |
| macOS | launchd | `users/dev/home.darwin.nix` | 89–129 | :110 `http://127.0.0.1:4096` |

- `PIGEON_SERVE_ENDPOINTS`, `PIGEON_DAEMON_AUTH_TOKEN`, `PIGEON_DAEMON_DB_PATH`, `PIGEON_SERVE_LIVENESS` are **set nowhere** today. Pigeon derives `serveEndpoints` from `OPENCODE_URL` when `PIGEON_SERVE_ENDPOINTS` is unset. Pigeon mints serve ids as `serve-<i>` from `PIGEON_SERVE_ENDPOINTS` order (route-registry `seedServes`).
- Pigeon's ingress router (and routing-schema creation via `initRouteSchema`) only initializes when it has serve endpoints; the schema lives in `pigeon-daemon.db` (`PIGEON_DAEMON_DB_PATH`, default `<cwd>/data/pigeon-daemon.db`).

### Sibling-owned restart sites (`users/dev/opencode-config.nix`) — must fan out to the pool
| Hook | Gate | Restart line | Command |
|---|---|---|---|
| `installOpencodePlugins` (devbox) | isDevbox | **362** | `systemctl --user restart opencode-serve.service` |
| `installOpencodePlugins` (cloudbox) | isCloudbox | **395** | `sudo -n systemctl restart opencode-serve.service` |
| `injectAigatewayBaseUrl` | isCloudbox | **875** | `sudo -n systemctl restart opencode-serve.service` |
| `injectTeamclaudeBaseUrl` | isDevbox | **997** | `$sc --user restart opencode-serve.service` |

### Host-gating
Boolean flags `isDevbox/isCloudbox/isCrostini/isDarwin` injected from `flake.nix` (devbox 133–137, cloudbox 154–158, crostini 175–179, darwin 198–202); consumed via `lib.mkIf`/`lib.optionalString`/`if isCloudbox then … else …`.

### M4 dependency (what M5 activates)
- M4 (shipped, dormant) gates everything on `OPENCODE_ROUTING_DB`. Setting it on the serves turns ON: serve self-registration + heartbeat (D1a), lease acquire/renew/release + deadline guard (D2a). Serve reads `OPENCODE_SERVE_ID` for its serve id; both flags already exist in `packages/core/src/flag/flag.ts` (opencode-patched `d8019e6`).
- Pigeon Task-3b (shipped, pigeon `149988d`) added `PIGEON_SERVE_LIVENESS` (default `http`); M5 sets it to `self`.

---

## ⚠️ Design decisions to confirm BEFORE executing

### DM5-1 — Routing DB path coordination (serves ↔ pigeon must agree)
Serves' `OPENCODE_ROUTING_DB` and pigeon's `PIGEON_DAEMON_DB_PATH` must point at the **same file**. Today pigeon's DB path is implicit (`<cwd>/data/pigeon-daemon.db`, cwd = pigeon service WorkingDirectory). **Proposal:** pin `PIGEON_DAEMON_DB_PATH` to an explicit absolute path per host (e.g. cloudbox `/home/dev/.local/share/pigeon/pigeon-daemon.db`) and set every serve's `OPENCODE_ROUTING_DB` to that same absolute path. **Confirm** the canonical path per host (and that the dir exists / is created).

### DM5-2 — Startup ordering + schema bootstrap
Serves **fail closed** if the routing schema is absent (M4 boot-assert). The schema is created by pigeon when it inits the router (needs `PIGEON_SERVE_ENDPOINTS`). **Proposal:** order `opencode-serve@.service After=pigeon.service`/`Wants=pigeon` (and user-bus equivalent), so pigeon creates+seeds the schema first. **Risk to confirm:** if pigeon restarts and recreates/migrates the schema, in-flight serves keep their open handle (fine). If the schema checksum drifts (pigeon upgrade), serves fail-closed on next boot — acceptable (that's M6 cutover territory). **Open Q:** should serves retry-with-backoff on "schema not yet present" instead of hard-failing at boot, to decouple from pigeon ordering? (Recommend: keep fail-closed + `After=pigeon` + `Restart=always` so a too-early serve just restarts until pigeon is up.)

### DM5-3 — Per-device K (pool size)
Proposal: **cloudbox K=4** (40G cap → ~9G/serve), **devbox K=2** (10G cap → ~4.5G/serve), **crostini K=1** (Chromebook, uncapped → keep 1), **macOS K=2**. Confirm/tune. (K=1 on crostini means the pool is a trivial 1-serve pool — still goes through routing, exercises the same path.)

### DM5-4 — serve_id ↔ endpoint index alignment
Pigeon mints `serve-<i>` from `PIGEON_SERVE_ENDPOINTS` order. So serve unit on the i-th port MUST set `OPENCODE_SERVE_ID=serve-<i>` and `PIGEON_SERVE_ENDPOINTS` must list `http://127.0.0.1:<port_i>` at index i. **Proposal:** derive both from ONE Nix list `servePorts = [ 4096 4097 4098 4099 ]` (host-sized), so ids/endpoints/ports are generated from a single source of truth and can never drift. Confirm the base port + numbering (keep `4096` as `serve-0` so a K=1 host ≈ today).

### DM5-5 — Per-serve memory subdivision (cgroup)
cloudbox MemoryMax 40G is for ONE serve today; under K=4 either set per-instance `MemoryMax` (~9G each) or a slice with an aggregate cap. **Proposal:** per-instance `MemoryMax`/`MemoryHigh` on the templated unit (simpler) sized = total/K with headroom. Confirm caps per host.

### DM5-6 — macOS fan-out restart (no target)
launchd has no "target". **Proposal:** K agents `opencode-serve-0..K-1` + a `opencode-serve-pool-restart` wrapper script (`launchctl kickstart -k` each agent) that the restart hooks call. Confirm acceptable.

### DM5-7 — Don't bounce the pool on every rebuild
**Proposal:** `restartIfChanged = false` on the templated units (like aigateway), so routine home/system rebuilds don't kill all K serves (and all live sessions). Restarts happen only via the explicit fan-out hooks (plugin cache invalidation, aigateway URL change) or M6 cutover. Confirm.

### DM5-8 — Flip pigeon to self-heartbeat liveness
Set `PIGEON_SERVE_LIVENESS=self` on every pigeon-daemon (serves now self-heartbeat via D1a). Confirm (the alternative `http` also works but keeps pigeon probing; `self` is the D1a target).

---

## Tasks

> Execute per-host. After EACH host's change: `nix eval` / build the config, rebuild, then runtime-verify. Commit per logical unit with explicit pathspec (shared tree — `git pull --rebase` first, `git commit -- <paths>`, ping sibling). Recommended order: **single source-of-truth list → cloudbox (system, canary host) → verify end-to-end → devbox → crostini → macOS → restart-hook fan-out (coordinate w/ sibling) → pigeon liveness flip**.

### Task M5.1 — Single source-of-truth pool descriptor + canonical paths
**Files:** a shared Nix let-binding (per host module, or a small `users/dev/serve-pool.nix` imported where needed).
**Change:** define `servePorts` (host-sized list), derive `serveEndpoints = map (p: "http://127.0.0.1:${toString p}") servePorts` and `serveIds = imap0 (i: _: "serve-${toString i}") servePorts`, and `routingDbPath` (DM5-1). Export for both the serve units and the pigeon config so they can't drift.
**Verify:** `nix eval` the derived lists per host; assert index alignment (endpoint i ↔ serve-i ↔ port i).

### Task M5.2 — cloudbox: templated system unit + target (CANARY HOST)
**Files:** `hosts/cloudbox/configuration.nix` (replace/augment `:529-654`).
**Change:**
- Convert `systemd.services.opencode-serve` → `systemd.services."opencode-serve@"` templated unit: ExecStart uses `%i` for `--port` (and to compute the index → `OPENCODE_SERVE_ID`); add `OPENCODE_ROUTING_DB=${routingDbPath}`, `OPENCODE_SERVE_ID=serve-<idx>`; keep all existing secret exports + `OPENCODE_DB` + `OPENCODE_DISABLE_CHANNEL_DB`. Per-instance `MemoryMax`/`MemoryHigh` (DM5-5). `After=pigeon.service` + `Wants` (DM5-2). `restartIfChanged=false` (DM5-7).
- Add `systemd.targets.opencode-serve-pool` with `wants`/`wantedBy` for each `opencode-serve@<port>.service` (generate from `servePorts`).
- Keep `opencode-serve.service` name as an alias OR leave the M7 consumers on `:4096` (serve-0 still binds 4096) until M7.
**Verify:** `nixos-rebuild build`; after switch: `systemctl status opencode-serve-pool.target` shows K active; `lsof <opencode.db>` shows K writers; each serve registered a `serve_instance` row (query pigeon-daemon.db); `curl :4096/global/health` + each port healthy.

### Task M5.3 — cloudbox pigeon: endpoints + liveness + DB path
**Files:** `hosts/cloudbox/configuration.nix` pigeon service (`:381-432`).
**Change:** set `PIGEON_SERVE_ENDPOINTS=${concat serveEndpoints}`, `PIGEON_SERVE_LIVENESS=self` (DM5-8), `PIGEON_DAEMON_DB_PATH=${routingDbPath}` (DM5-1). (Optional now / later: `PIGEON_DAEMON_AUTH_TOKEN` via sops + `127.0.0.1` bind — can defer to a hardening pass.) Keep `OPENCODE_URL` for now (M7 removes it).
**Verify:** after rebuild, pigeon logs "ingress router started with self-heartbeat liveness (serves=K)"; `GET /route` for a few session ids distributes across the K serves (rendezvous); pigeon `serve_instance` rows show all K healthy with serve-minted `instance_uuid`s.

### Task M5.4 — cloudbox end-to-end canary
**Verify (no code):** start N>K real sessions through pigeon; confirm each is assigned a serve, a `session_lease` row appears for the duration, and releases on completion; kill one serve → pigeon staleness-sweep marks it unhealthy + reassigns its sessions; restart the pool target → one action bounces all K. Capture event-loop behavior (ties to bead `workstation-1mc2`). **GATE:** do not proceed to other hosts until cloudbox is proven.

### Task M5.5 — devbox templated user units + target
**Files:** `users/dev/home.devbox.nix` (`:425-474`).
**Change:** `systemd.user.services."opencode-serve@"` templated + `systemd.user.targets.opencode-serve-pool`; K=2; per-instance mem; routing env; `OPENCODE_SERVE_ID`; `restartIfChanged=false`; `After=pigeon` (devbox pigeon is a SYSTEM unit — user unit can't `After` a system unit directly; use a readiness wrapper or accept `Restart=always` retry until schema exists — see DM5-2).
**Verify:** `systemctl --user status opencode-serve-pool.target` K active; lease rows appear.

### Task M5.6 — crostini templated user units (K=1)
**Files:** `users/dev/home.crostini.nix` (`:135-171`).
**Change:** templated user unit + target, K=1 (trivial pool, still routed). Routing env + serve id. Pigeon here is a USER unit (`:94-132`) → set its `PIGEON_SERVE_ENDPOINTS`/`LIVENESS`/`DB_PATH`.
**Verify:** single serve registers + routes through pigeon.

### Task M5.7 — macOS K launchd agents + fan-out wrapper
**Files:** `users/dev/home.darwin.nix` (`:135-175` serve, `:89-129` pigeon).
**Change:** generate K agents `opencode-serve-<i>` (each its own port/id/routing env, Keychain secrets) from `servePorts`; add `opencode-serve-pool-restart` wrapper (`launchctl kickstart -k gui/$(id -u)/<agent>` per agent). Set pigeon agent's `PIGEON_SERVE_ENDPOINTS`/`LIVENESS`/`DB_PATH` (DM5-6).
**Verify:** `launchctl list | grep opencode-serve`; each healthy; routing works.

### Task M5.8 — restart-hook fan-out (COORDINATE with sibling — their file)
**Files:** `users/dev/opencode-config.nix` restart sites (362, 395, 875, 997).
**Change:** replace each `restart opencode-serve.service` with the pool fan-out: Linux → `restart opencode-serve-pool.target` (system or `--user` per host as today); macOS → call the `opencode-serve-pool-restart` wrapper. Keep host gating intact.
**Coordination:** sibling owns `opencode-config.nix`; `git pull --rebase`, edit only these 4 sites with explicit pathspec, ping sibling with the exact lines.
**Verify:** trigger a plugin-cache invalidation / aigateway URL change → all K serves bounce.

### Task M5.9 — devbox/macOS pigeon endpoints + liveness
**Files:** `hosts/devbox/configuration.nix` pigeon (`:225-262`); macOS done in M5.7.
**Change:** mirror M5.3 for devbox pigeon (system) + set DB path.
**Verify:** per host.

---

## Risks (carry into execution)
- **Activates dormant M4 across the fleet** — first host (cloudbox canary) must fully validate the lease path before fanning out. A bug here breaks session execution, not just routing.
- **Schema bootstrap ordering** (DM5-2) — serves fail-closed without the routing schema; rely on `After=pigeon` + `Restart=always`. User-unit-vs-system-unit ordering (devbox) is the trickiest.
- **serve_id ↔ endpoint drift** (DM5-4) — mitigated by the single source-of-truth list (M5.1). A misalignment silently breaks lease acquire (assignment.desired_serve_id mismatch → fail-open, no lease) — verify alignment explicitly.
- **Memory** — K serves × per-serve cap must fit the host; cloudbox 40G/4 ≈ 9G each is fine, crostini stays K=1.
- **Shared tree + user-controlled main** — the USER controls workstation main; coordinate every commit with the sibling; `opencode-config.nix` is sibling-owned.
- **Don't bounce the pool on every rebuild** (DM5-7) — without `restartIfChanged=false`, every home/system rebuild kills all live sessions.
- **macOS no-target emulation** (DM5-6) — the weakest fan-out story; test the wrapper.

## Rollback
Each host change is independent and reversible: revert the templated unit back to the single `opencode-serve` (serve-0 on :4096) and unset the serve's `OPENCODE_ROUTING_DB` → M4 goes dormant again, pigeon falls back to `OPENCODE_URL`-derived single endpoint + (if reverted) `PIGEON_SERVE_LIVENESS=http`. Keep the single-serve definition in git history for fast revert. The cloudbox canary gate (M5.4) means a failed pool never reaches the other hosts.

## Dependencies / sequencing
M5 depends on M4 (done) + M2 (done; `OPENCODE_DB` pinned + channel-DB disabled — already in every unit). After M5: **M6** (atomic binary cutover — epoch bump/drain/zero-FD) then **M7** (client migration to `GET /route` + per-session `/event`, remove `:4096`). Follow-ups `workstation-qr69` (renewal jitter) and `workstation-1mc2` (event-loop p99 canary) fold into M5.4's canary.
