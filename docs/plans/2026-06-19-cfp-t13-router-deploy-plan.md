# T13 — Deploy claude-failover-proxy (cfp) router on cloudbox

Bead: `claude-failover-proxy-8fe.14` (T13). Epic: `claude-failover-proxy-8fe`.
This plan is the durable handoff for executing T13 in `~/projects/workstation`.
The fetch-auth was de-risked earlier (see bead DESIGN field); THIS plan adds the
packaging + service + config-flip discoveries made 2026-06-19.

## Goal / blast radius
Stand up the cfp router as a cloudbox systemd service and flip ONLY the
`google-vertex-anthropic` (claude) baseURL to it. Gemini (`google-vertex`) MUST
keep going to the aigateway. Split into T13a (package + service, NO routing
change) then T13b (the baseURL flip).

## STATUS (updated 2026-06-20)
T13a PHASE 1 = DONE + VERIFIED on cloudbox; router is LIVE on :8789.
- `pkgs/claude-failover-proxy/default.nix` — BUILT + RAN. Verified by temporarily
  injecting GITHUB_TOKEN into the nix-daemon env (a /run drop-in), building the
  FOD via the daemon (rc=0), and running the wrapper (threw the expected
  `CFP_TEAMCLAUDE_API_KEY is required`). Drop-in removed, daemon clean. FOD now
  cached in the store. This also proved the daemon-env GITHUB_TOKEN -> FOD
  `netrcImpureEnvVars` path end-to-end. (Committed: package 16c5e63.)
- `flake.nix` localPkgsFor entry — committed `172e46d`.
- `hosts/cloudbox/configuration.nix` cfp systemd service — committed `3e0fc41`,
  `nixos-rebuild switch`'d. `systemctl is-active` = active; journald
  `listening on port 8789, budget: $100`; `ss` shows :8789 held by the
  `ld-linux-aarch6` wrapper proc; `/var/lib/claude-failover-proxy` created;
  `curl POST /v1/messages` => HTTP 401 (serving + routing to aigateway path).
  Reads CFP_TEAMCLAUDE_API_KEY from the existing /run/secrets/teamclaude_api_key
  via shell shim. Env: budget=100, reset_hour=0, CFP_TZ=America/New_York.
- The FAST client-env `nix build` path is CONFIRMED DEAD (404: the daemon does
  not inherit the shell's GITHUB_TOKEN; `configurable-impure-env` is not enabled
  daemon-side). Token MUST come from the daemon env.

T13a PHASE 2 = DONE + VERIFIED. No new PAT was needed: the EXISTING sops
`github_api_token` reads the private cfp asset (HTTP 200), so we reused it.
- `hosts/cloudbox/configuration.nix` (commit `1c8c7da`): a `sops.templates`
  block renders `GITHUB_TOKEN=<github_api_token>` to
  /run/secrets/rendered/nix-daemon-github-token, and
  `systemd.services.nix-daemon.serviceConfig.EnvironmentFile` loads it
  (`-` optional prefix; restartUnits bounces the daemon on render). VERIFIED:
  forced a clean re-fetch of the inner fetchurl FOD with NO shell GITHUB_TOKEN
  and it succeeded -> the daemon now supplies the token (the last unverified
  link is closed). Single source of truth (reuses github_api_token, no 2nd PAT).
- `.github/workflows/update-claude-failover-proxy.yml` (commits `a69c409`,
  `dddf2a7`): daily poller. cfp is PRIVATE so the default github.token AND
  UPDATE_TOKEN 404 on it; we set a dedicated `CFP_READ_TOKEN` Actions secret
  (value = the sops github_api_token) for the check + asset steps, keeping
  UPDATE_TOKEN for the PR step. VERIFIED via workflow_dispatch: check step
  authenticated, reported "Already on 0.1.0", PR steps skipped. Update path
  (asset-id resolve + gh release download + nix hash) validated locally.
  NOTE: CFP_READ_TOKEN is the BROAD classic github_api_token; if preferred,
  swap it for a fine-grained PAT scoped to cfp contents:read.

T13a is COMPLETE. Router live on :8789; reproducible daemon builds + CI
auto-update both wired and verified.

T13b = NOT STARTED, HELD for explicit user go-ahead (high blast radius: flips
live opencode Claude routing). Open design questions still pending (read cfp
src/server.ts + src/backends.ts forwardToVertex for the baseURL path shape;
split the strip-branch so vertex-anthropic follows cfp.service health while
gemini stays on aigateway.service). See the T13b section below.

- Coordination: bkdw (`ses_128ece55bffeGfKs52gPTQBJZq`) is synced through the
  Phase 2 pushes (told to `git pull --rebase`); they're idle on zao4 (PR #4),
  entirely in the pigeon repo, deferring pigeon-daemon.service env to their M6+.
  Their file `docs/plans/2026-06-19-zao4-pigeon-ingress-router-plan.md` is THEIRS.

## CRITICAL packaging findings (empirically verified on cloudbox 2026-06-19)
The release asset is a `bun build --compile` single-file executable
(`claude-failover-proxy-linux-arm64`, ~89MB, aarch64, glibc-dynamic; NEEDED:
libc/ld-linux/libpthread/libdl/libm). Bun appends the JS bundle as a trailer
read by offset from EOF.

1. **patchelf CORRUPTS it.** `patchelf --set-interpreter --set-rpath` changed the
   file size (93694096 → 93759632) and the patched binary SIGSEGVs (core dump,
   exit 139). => `autoPatchelfHook` is OUT. Set `dontFixup = true` so the nix
   fixup phase never patchelf/strips it.
2. **ld.so wrapper WORKS (chosen approach).** Keeping the binary pristine and
   launching it as
   `${glibc}/lib/ld-linux-aarch64.so.1 --library-path <glibc[+gcc.cc.lib]> <binary>`
   runs correctly and finds its bundle (bun locates the bundle via argv, NOT
   /proc/self/exe). This is hermetic and does NOT depend on nix-ld.
3. **Fallbacks also proven** (informational): the raw binary runs unpatched via
   nix-ld both with explicit `NIX_LD`/`NIX_LD_LIBRARY_PATH` and even under a
   fully empty env (`env -i`) — nix-ld (enabled on cloudbox,
   configuration.nix:847) provides `/lib/ld-linux-aarch64.so.1` with a baked-in
   glibc fallback. So a bare `install -Dm755` + nix-ld would also work on
   cloudbox, but the wrapper is more robust for a hardened systemd unit and for
   the all-devices future (bead `fsw`).

The package file already implements approach #2. Verify it before trusting it
(see T13a step 4).

## cfp runtime config interface (authoritative; from src/config.ts)
All config is env-only; NO CLI args, NO config file. Entry runs on
`import.meta.main`; `Bun.serve({port})` binds ALL interfaces (no host var).
- `CFP_TEAMCLAUDE_API_KEY` — **REQUIRED** (throws/exits if empty). Sent to
  TeamClaude as `x-api-key`.
- `CFP_LISTEN_PORT` = `8789`
- `CFP_AIGATEWAY_URL` = `http://127.0.0.1:8080` (under-budget upstream → work
  aigateway → Vertex)
- `CFP_TEAMCLAUDE_URL` = `http://127.0.0.1:3456` (over-budget upstream)
- `CFP_BUDGET_DOLLARS` = `100` (daily ceiling; fractional ok; 0.01 forces failover)
- `CFP_IDLE_MIGRATE_SECONDS` = `300` (sticky-migration idle gap)
- `CFP_RESET_HOUR` = `0` (0–23, integer; budget rollover hour)
- `CFP_TZ` — set EXPLICITLY (e.g. America/Chicago); do NOT rely on system tz
  under systemd (falls back to UTC).
- `CFP_STATE_PATH` = `$XDG_STATE_HOME/claude-failover-proxy/spend.json` — set
  EXPLICITLY to a writable dir; spend ledger persists here, write errors are
  swallowed (=> lost budget across restarts if dir unwritable). Pair with
  `StateDirectory=`.
- `CFP_ANTHROPIC_VERSION` = `2023-06-01`
- **No GCP creds needed** by cfp (under-budget path is a transparent reverse
  proxy; forwards client Authorization as-is).
- **No health endpoint.** Liveness = journald line `[claude-failover-proxy]
  listening on port 8789, budget: $100` OR `ss -tlnp | grep :8789`. (The proxy
  probes TeamClaude at `${teamclaudeUrl}/teamclaude/status` — that's cfp AS a
  client, not an endpoint it serves.)

## Workstation survey (file:line anchors)
- Naked-binary pkg template: `pkgs/bb/default.nix` (dontUnpack, install -Dm755,
  sources keyed by `stdenv.hostPlatform.system`). Tarball+patchelf variant:
  `pkgs/gws/default.nix`.
- Package wiring: NO overlay (`flake.nix:38` `overlays=[]`). Central map
  `localPkgsFor` at `flake.nix:52-67` (add the new pkg here, +1 line). Exposed as
  flake `packages.<system>.<pname>` (`flake.nix:84-92`) and to home-manager via
  `extraSpecialArgs.localPkgs` (`flake.nix:140-158` for cloudbox).
  **NixOS configs do NOT get localPkgs** — `systemd.services` must
  `pkgs.callPackage ../../pkgs/claude-failover-proxy { }` in the
  `hosts/cloudbox/configuration.nix` `let` block (pattern at lines 16-39).
- sops: `defaultSopsFile = secrets/cloudbox.yaml`; age key
  `/var/lib/sops-age-key.txt` (`configuration.nix:59-67`). Secrets declared in
  the NixOS module `sops.secrets = { ... }` (configuration.nix:67+), decrypt to
  `/run/secrets/<name>`. Standard attrs `owner="dev"; group="dev"; mode="0400";`.
  Edit ciphertext: `SOPS_AGE_KEY_FILE=/var/lib/sops-age-key.txt sops
  secrets/cloudbox.yaml`. `.sops.yaml` encrypts cloudbox.yaml only to `&cloudbox`.
- `teamclaude_api_key` sops secret already exists (`configuration.nix:118-130`,
  `/run/secrets/teamclaude_api_key`) — comment explicitly says it's there so cfp
  can send it as `CFP_TEAMCLAUDE_API_KEY`. It's a RAW value (not KEY=VALUE), so
  read it via a bash-shim ExecStart (the aigateway pattern), not EnvironmentFile.
- `systemd.services.teamclaude` (`configuration.nix:658-689`): Type=simple,
  User=dev, `wantedBy=multi-user.target`, port **3456**, Restart=always. MODEL
  THE CFP SERVICE ON THIS (long-running node/bun proc) — not on aigateway
  (oneshot docker).
- `systemd.services.aigateway` (`configuration.nix:721-772`): port **8080**,
  sops-via-bash-shim pattern (`cat /run/secrets/...` in ExecStart),
  `restartIfChanged=false`.
- nix config: `nix.settings` at `configuration.nix:860-872` (trusted-users root
  + @wheel; dev is in wheel). NO existing `systemd.services.nix-daemon`
  serviceConfig override anywhere — add it fresh.

## T13a — package + service (NO routing change)

0. **MANUAL PREREQ (ask user):** mint a FINE-GRAINED read-only PAT with
   `contents:read` on `johnnymo87/claude-failover-proxy`. `gh` cannot mint PATs.
   This single PAT is reused for: (a) the nix-daemon fetch token, (b) the
   auto-update workflow. For fast LOCAL iteration you can instead use
   `GITHUB_TOKEN=$(gh auth token)` (classic, broader) — fine for build tests, but
   the committed sops secret should hold the fine-grained PAT.

1. Add to `flake.nix:52-67` `localPkgsFor`:
   `claude-failover-proxy = p.callPackage ./pkgs/claude-failover-proxy { };`

2. sops secret `nix_daemon_github_token` — content MUST be KEY=VALUE for
   EnvironmentFile: `GITHUB_TOKEN=<fine-grained-PAT>`. Add to
   `secrets/cloudbox.yaml` (sops edit) AND declare in `configuration.nix`
   `sops.secrets`:
   `nix_daemon_github_token = { mode = "0400"; };` (owner root — nix-daemon runs
   as root; do NOT set owner=dev).

3. nix-daemon EnvironmentFile (NEW block after configuration.nix:877):
   ```nix
   systemd.services.nix-daemon.serviceConfig.EnvironmentFile =
     [ "-/run/secrets/nix_daemon_github_token" ];  # '-' => optional, won't brick daemon on boot before sops decrypts
   sops.secrets.nix_daemon_github_token.restartUnits = [ "nix-daemon.service" ];
   ```
   GOTCHA (the one UNVERIFIED link): does the daemon actually get GITHUB_TOKEN
   from EnvironmentFile and forward it into the FOD sandbox via
   netrcImpureEnvVars? VERIFY after `nixos-rebuild switch` + daemon restart with
   a clean build (step 4, daemon path).

4. **Build verification (two ways):**
   - FAST (client env, before any rebuild): `GITHUB_TOKEN=$(gh auth token) nix
     build .#claude-failover-proxy` — tests whether impureEnvVars forwards from
     the CLIENT env. If it works, iterate here. Then
     `./result/bin/claude-failover-proxy` => expect throw `CFP_TEAMCLAUDE_API_KEY
     is required` (proves wrapper+package run). [NOTE: de-risk concluded the
     token comes from the DAEMON env, not the shell — so this fast path MAY 404;
     if so, go straight to the daemon path.]
   - REAL (daemon env, after steps 2-3 + `sudo nixos-rebuild switch --flake
     .#cloudbox` + `sudo systemctl restart nix-daemon`): force a clean FOD
     rebuild (the FOD dedups by hash, so use `--rebuild` or gc the path first) to
     prove daemon EnvironmentFile delivery.

5. `systemd.services.claude-failover-proxy` in `configuration.nix` (model on
   teamclaude.service). Add `claude-failover-proxy = pkgs.callPackage
   ../../pkgs/claude-failover-proxy { };` to the `let` block (line ~16). Service:
   ```nix
   systemd.services.claude-failover-proxy = {
     description = "claude-failover-proxy (budget-gated Vertex->Max failover router)";
     wantedBy = [ "multi-user.target" ];
     after = [ "network.target" "teamclaude.service" ];
     wants = [ "teamclaude.service" ];
     serviceConfig = {
       Type = "simple";
       User = "dev"; Group = "dev";
       StateDirectory = "claude-failover-proxy";  # => /var/lib/claude-failover-proxy
       Environment = [
         "CFP_LISTEN_PORT=8789"
         "CFP_AIGATEWAY_URL=http://127.0.0.1:8080"
         "CFP_TEAMCLAUDE_URL=http://127.0.0.1:3456"
         "CFP_BUDGET_DOLLARS=100"
         "CFP_IDLE_MIGRATE_SECONDS=300"
         "CFP_TZ=America/Chicago"
         "CFP_STATE_PATH=/var/lib/claude-failover-proxy/spend.json"
       ];
       # teamclaude_api_key is a RAW value -> export via shim (aigateway pattern)
       ExecStart = "${pkgs.bash}/bin/bash -c 'export CFP_TEAMCLAUDE_API_KEY=$(cat /run/secrets/teamclaude_api_key); exec ${claude-failover-proxy}/bin/claude-failover-proxy'";
       Restart = "on-failure"; RestartSec = 10;
     };
   };
   ```
   Verify: `systemctl status claude-failover-proxy`, journald shows the listening
   line, `ss -tlnp | grep :8789`. Smoke: with budget high, a request through the
   router should reach the aigateway. NO opencode routing change yet.

6. `.github/workflows/update-claude-failover-proxy.yml` — poll private repo
   releases (needs the PAT as an Actions secret to SEE private releases), resolve
   tag→asset id via `gh api repos/johnnymo87/claude-failover-proxy/releases/tags/<tag>
   --jq '.assets[]|select(.name=="claude-failover-proxy-linux-arm64").id'`, bump
   BOTH the asset-id in the url AND the hash in default.nix, open auto-merge PR.
   Pattern after `.github/workflows/update-bb.yml`.

## T13b — flip google-vertex-anthropic baseURL (HIGH blast radius)
The aigateway baseURL for BOTH providers is set at runtime by the
`home.activation.injectAigatewayBaseUrl` script in
`users/dev/opencode-config.nix` (cloudbox-only, `lib.mkIf isCloudbox`, line 774),
NOT in static nix. Key lines:
- claude URL `full_url` (CHANGE): line 822
  (`http://localhost:8080/v1/projects/$project/locations/global/publishers/anthropic/models`)
- gemini URL `gemini_url` (LEAVE): line 826
- single `jq` setting BOTH baseURLs: lines 829-832 (split: keep gemini stage)
- combined restart-trigger hash: line 836
- strip branch (gateway-down; deletes both baseURLs): lines 806-820
- toggle keyed on `systemctl is-active aigateway.service` (787-791) + presence of
  `/run/secrets/google_cloud_project` (793-796)

OPEN DESIGN QUESTIONS to resolve in T13b (read cfp `src/server.ts` +
`src/backends.ts` `forwardToVertex` first):
1. What baseURL does opencode point at the router? The router forwards
   under-budget traffic to `CFP_AIGATEWAY_URL` (http://127.0.0.1:8080). Determine
   how forwardToVertex builds the target URL (does it concat aigatewayUrl +
   incoming path?) so opencode's vertex-anthropic baseURL is shaped correctly
   (likely `http://127.0.0.1:8789/v1/projects/$project/locations/global/publishers/anthropic/models`).
2. The current strip-branch logic removes vertex-anthropic's baseURL when the
   AIGATEWAY is down. With the router as an INDEPENDENT service, that coupling is
   wrong — vertex-anthropic should follow the ROUTER's health, not aigateway's.
   Decide: gate the claude baseURL on `is-active claude-failover-proxy.service`
   instead. Keep gemini gated on aigateway.
Verify: `home-manager switch --flake .#cloudbox` rewrites ONLY
`~/.config/opencode/opencode.json` `.provider."google-vertex-anthropic".options.baseURL`;
`.provider."google-vertex".options.baseURL` must still be the localhost:8080
gemini URL. Rollback: stop router → switch → vertex-anthropic override stripped →
opencode falls back (decide fallback target: aigateway or direct).

## Commit discipline
Shared tree with bkdw. Always `git status` pre-commit, `git commit -- <explicit
paths>`. Small commits. After landing configuration.nix/flake.nix, ping bkdw
(`ses_128ece55bffeGfKs52gPTQBJZq`) so they rebase. `bd dolt push` after bead
updates.
