# goose-upgrade-probe (bead workstation-6w7i.27.1, L2)

A scripted gate for a goose binary, read-only to production. Usage:
`goose-upgrade-probe <goose-bin> [--old-bin <bin>] [--keep]`. It prints one
`PASS <check>` or `FAIL <check> -- <detail>` line per check and exits 0 only if
every check passes. Nothing is skipped: a check that cannot run is a FAIL.
`--old-bin` defaults to the deployed goose: `/var/lib/goose/current/bin/goose`
once L6 lands, and until then `readlink -f $(command -v goose)`. To self-test,
run it with the candidate equal to the deployed binary (patched-1.54.0.18).
A7 is its first real run.

## Isolation (what makes it read-only to production)

- **Work root.** Everything goes under `R=$(mktemp -d /var/tmp/goose-probe.XXXX)`.
  The probe needs df >= 3x the size of sessions.db free there.
- **goose.** Every goose the probe starts has `GOOSE_PATH_ROOT=$R/goose`, which
  holds config at `$R/goose/config/config.yaml` and the DB at
  `$R/goose/data/sessions/sessions.db` (goose `Paths`, goose/src/config/paths.rs).
  The probe asserts this on every launch.
  - **DB.** A copy made with sqlite's online backup of
    `~/.local/share/goose/sessions/sessions.db`, using python's
    `sqlite3.Connection.backup`, which is what `.backup` does.
  - **Config.** A copy of `~/.config/goose/config.yaml` that keeps only
    `type: platform`/`builtin` extensions. Every stdio/http/sse extension is
    removed, and so is the whole `plugins:` key, because plugins can carry
    `.mcp.json` servers. The swarm tools are not in this file at all: honkd adds
    them per session, and the isolated honkd is started without `--swarm-*`.
- **Serve.** Runs as a transient user unit `goose-probe-<id>-serve`
  (`systemd-run --user --collect -p MemoryMax=6G -p EnvironmentFile=$R/env`,
  where `env` is mode 600). It listens on 127.0.0.1 on a random free port and
  uses a random `GOOSE_SERVER__SECRET_KEY`.
  - **Provider env.** The same as the production unit
    (hosts/cloudbox/configuration.nix goose-serve: Vertex through cfp :8789,
    scopes, `GOOSE_THINKING_EFFORT=high`, Gemini host direct), with
    `GOOSE_MODEL=claude-haiku-4-5@20251001` for cost. That is honk's live-probe
    model, so it is known to route.
  - **Why a unit.** honk's p5-style cgroup lookups need a named unit (they are
    not run here, see check 3), and teardown is `systemctl --user stop`.
- **honkd.** A deployed `~/.nix-profile/bin/honkd` started as its own transient
  unit with `--listen 127.0.0.1:<free> --upstream http://127.0.0.1:<serve>/acp
  --upstream-secret-file $R/secret --state-dir $R/honk-state` and
  `--allow-unpatched-upstream`. It has no swarm, no turn hook, no MCP catalog
  and no `--allow-production-upstream`. Its downstream secret is
  `$R/honk-state/secret`.
- **Refused ports.** 4080, 4180, 4181, 4280, 4700, 4731, 4096-4099 and 8789 can
  never be a probe listen port.
- **Teardown.** A trap stops both units and deletes `$R`'s DB copies unless
  `--keep` is passed. Logs are always kept in `$R/logs`.

## Checks

1. **migration.** Record the copy's `max(schema_version.version)`, then start
   the candidate serve.
   - ACP `initialize` and `session/list` succeed.
   - The schema version is >= before.
   - `PRAGMA quick_check` is `ok`.
   - `session/load` succeeds on the 3 newest production sessions that contain a
     tool request, with at least one replayed update each.
2. **pigeon.** Runs `goose-launch-probe.ts`, `goose-runner-probe.ts` and
   `goose-id-split-probe.ts` (pigeon `packages/daemon/scripts`, from
   `~/projects/pigeon`) with `GOOSE_ACP_URL=ws://127.0.0.1:<serve>/acp`,
   `PIGEON_GOOSE_PROBE_TOKEN` and `GOOSE_ACP_CWD=$R/cwd`. Each probe must exit 0
   with no `FAIL` lines. They make no pigeon DB writes or chat posts, because
   those are in-process fakes.
3. **honk.** A throwaway honk worktree at the rev the workstation flake.lock
   pins (baked in at build), with a persistent `CARGO_TARGET_DIR` in
   `~/.cache/goose-upgrade-probe`.
   - (a) Run `cargo build -p honkd`, then
     `HONK_GOOSE_BIN=<cand> HONKD_BIN=... cargo test --workspace -- --nocapture`.
     It must exit 0 with zero `^skipping` lines: stub_goose.rs:46-60 skips and
     passes when the binary is unset or missing, so the skip lines are counted.
   - (b) Run `p2_patched` and `p4_patched` with `--ignored --test-threads=1`
     against the isolated serve (`HONK_GOOSE_URL`, `HONK_GOOSE_SECRET`,
     `HONK_SANDBOX_UNIT=<probe unit>`, `HONK_FIXTURES_ROOT=$R/fx`). Again, zero
     skips. p5 is not run, because it kill -9s by cgroup.
4. **stall-watch.** Uses the isolated honkd. A python driver runs under
   eng-agent-platform's uv env with `HOME=$R/swhome`, and `config.HONK_URL` and
   `HONK_TOKEN_FILE` are repointed in-process. It calls
   `honk_transport.run_honk()` with `SessionCtx(mode="new")` and
   `swarm_tools=False`.
   - The `recipe_file` is a copy of `coordinator_tools.yaml` whose
     instructions are replaced with "probe: run no command, reply SWPROBEOK",
     so the model never acts as a real coordinator.
   - The payload is `[sw wake run=<id>] ...`.
   - It passes on no exception and the reply containing `SWPROBEOK`.
   - It never opens state.db or programs.toml.
   - The honkd URL override the bead asked for is these kwargs plus the
     in-process repoint. No stall-watch change was needed.
5. **rendered-surface.** For maven-renovate, dependabot-lane-merge and
   dependabot-human-merge: run `capture-rendered-surface.py` with the
   candidate first on PATH, `GOOSE_GLOBAL_SKILLS=false`, and cwd the live lane
   home. Then run `check-rendered-surface.py --param repo=food-truck/mono`,
   whose `--param` makes `--bless` impossible. Exit 0 is PASS. A mismatch is a
   FAIL that includes the checker's report.
   - It never blesses anything.
   - Until L8 adds per-version fixture entries, a new version is expected to
     FAIL here.
6. **rollback.** First, against the candidate: create a rich session (a shell
   tool call, thinking on, then `/compact`) and run a second turn. Stop the
   candidate. Start `--old-bin` on the same migrated copy.
   - `initialize` succeeds.
   - A prompt to a new scratch session WRITES a turn, and its messages row
     count goes up.
   - `session/load` succeeds on every session the candidate created during the
     run (rich session + pigeon/honk probe sessions), with replayed updates.
   - `PRAGMA quick_check` is ok.

## Packaging

The package is `pkgs/goose-upgrade-probe` (python3 with websockets and pyyaml,
plus runtime git, nix, systemd, coreutils). It is installed on cloudbox via
home.cloudbox.nix. Unit tests (`test_probe.py`, run in `nix flake check`) cover
the pure parts: config stripping, the port guard, skip counting, result
aggregation (SKIP and missing both count as FAIL), arg defaults, and the
GOOSE_PATH_ROOT assertion.

## Research notes (2026-11-22)

- Pigeon probes take env `GOOSE_ACP_URL` / `PIGEON_GOOSE_PROBE_TOKEN` /
  `GOOSE_ACP_CWD`. The WS auth is `?token=` (ws-transport.ts:22). Each prints
  `PASS`/`FAIL` lines and exits 1 on any failure. They run real model turns.
  The runner probe treats :38999 as its dead port.
- Honk crates: honk, honkd, honk-upstream, honk-wire, honk-testgoose.
  - CI runs `HONK_GOOSE_BIN=... HONKD_BIN=... cargo test --workspace`.
  - The skip messages are:
    - `skipping stub goose:`
    - `skipping activation test:`
    - `skipping <n>: honkd binary not found`
    - `skipping ...: HONK_SANDBOX_PATCHED unset`, from the ignored live_exit
      tests
    - `skipping ...: HONK_GOOSE_SECRET unset`, from the ignored live probes
- honkd defaults `--listen` to 127.0.0.1:4280, which is production. It needs
  `--state-dir`, or it shares production's lock. `--allow-production-upstream`
  is needed only for :4080.
- stall-watch: `config.HONK_URL` is a constant (config.py:179). `run_honk` and
  `ensure_session` take `url=`, `token_file=`, `db_path=` and `recipe_file=`.
  `--dry-run` still reads the live honkd and never runs a coordinator.
- rendered-surface: the capture runs `goose run --no-session --recipe` with a
  stub OpenAI server and `GOOSE_PATH_ROOT=<tmp>`, so it needs no credentials.
  It picks goose from PATH. Its fixtures record `goose_version` 1.54.0.
- **Production sessions.db was already at schema v18 on 2026-11-22.**
  `schema_version` rows 17 and 18 are stamped 02:19:53Z, while
  patched-1.54.0.18 has `CURRENT_SCHEMA_VERSION` 16. A 1.60-based goose
  therefore touched the real DB. This was reported to the planner,
  ses_dff463191ffeT6iVOqbTfqgzUP.
