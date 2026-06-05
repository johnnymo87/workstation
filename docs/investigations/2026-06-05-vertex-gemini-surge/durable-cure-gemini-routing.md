# Durable retry-cap CURE + Gemini routing through the aigateway

**Date:** 2026-06-05 (~17:20 EDT). **Host:** cloudbox (aarch64-linux).
**Predecessors:** `retry-cap-deploy.md` (the cure, deployed on a local --impure pin),
`aigateway-cost-fix.md` §7 (gated gemini routing). This report covers making the
cure **durable** (adopt the published capped release) and **enabling gemini routing**
through the local gateway, deployed together in one pure `home-manager switch`
(generation 381). The single controlled `opencode-serve` restart is the final step,
fired detached after this report.

---

## 0. TL;DR

- **TASK A (durable cure):** workstation `users/dev/home.base.nix` no longer pins a
  LOCAL `/home/.cache` tarball (commit `1af8073`, which broke pure flake eval).
  It now points at the **published capped release `v1.16.2-patched.1`**
  (opencode-patched HEAD `6fa9663` = `patches/retry-cap.patch`: `MAX_RETRIES=8` +
  downward backoff jitter). All four platforms use `fetchurl` with
  release-checksum-verified hashes. **A PURE `home-manager switch` works again**, and
  `update-opencode-patched.yml` will now track a CAPPED release going forward.
- **TASK B (gemini routing):** `injectAigatewayBaseUrl` now also sets
  `provider.google-vertex.options.baseURL` →
  `http://localhost:8080/v1beta1/projects/<project>/locations/global/publishers/google`
  (mirrors the existing anthropic override; symmetric strip-on-disable branch; folded
  into the restart hash). Committed + pushed by the orchestrator as `96c2cd6`.
- **Deployed:** generation **381** active (pure build). Running `opencode-serve` is
  still on the prior capped binary (`1.15.13.3`) until the final controlled restart —
  **no uncapped window** at any point.
- **Gateway:** verified UP (`localhost:8080/actuator/health` → `status: UP`) before
  enabling gemini routing.

---

## 1. What changed

### 1a. `users/dev/home.base.nix` (TASK A — this worker's commit)

| | before (commit 1af8073) | after |
|---|---|---|
| `upstreamVersion` | `"1.15.13"` | `"1.16.2"` |
| `patchedRevision` | `"3"` | `"1"` |
| release tag | `v1.15.13-patched.3` (never published) | `v1.16.2-patched.1` (published) |
| aarch64-linux `src` | `localBuildTarball = /home/dev/.cache/opencode-retry-cap-deploy/...` | `pkgs.fetchurl` (released asset) |
| `localBuildTarball` binding | present | **removed** |
| platform hashes | local-build / 1.15.13.2 hashes | v1.16.2-patched.1 release hashes (below) |

The `if hostPlatform == "aarch64-linux" then localBuildTarball else fetchurl` branch is
gone; `src` is unconditionally `pkgs.fetchurl`. **No `/home` path literal remains**, so
pure flake evaluation succeeds.

### 1b. `users/dev/opencode-config.nix` (TASK B — orchestrator commit `96c2cd6`)

`home.activation.injectAigatewayBaseUrl` extended to manage the gemini provider
alongside anthropic, gated on the **same** signal (`systemctl is-active
aigateway.service` AND a readable `/run/secrets/google_cloud_project`):

- **inject branch:** `gemini_url="http://localhost:8080/v1beta1/projects/$project/locations/global/publishers/google"`
  then `jq '… | .provider."google-vertex".options.baseURL = $gemini_url'`. Shape is
  `v1beta1` / `publishers/google` / **no** trailing `/models` (the `@ai-sdk/google-vertex`
  `getBaseURL` appends `/models/<id>:streamGenerateContent` itself).
- **strip branch:** symmetric del-ladder for `google-vertex`
  (`del(.provider."google-vertex".options.baseURL)` → collapse empty `options` →
  collapse empty `google-vertex` → collapse empty `provider`), so a stopped gateway
  falls back to direct Vertex.
- **restart hash:** `new_hash = sha256(printf '%s\n%s' anthropic_url gemini_url)` so the
  opencode-serve auto-restart still fires when either URL changes.

This matches `aigateway-cost-fix.md` §7's recommended implementation exactly.

## 2. Release hashes (v1.16.2-patched.1)

Computed via `nix-prefetch-url | nix hash convert --to sri` AND cross-verified against
the release's `checksums.sha256` (both methods agree):

| platform | asset | SRI hash |
|---|---|---|
| aarch64-linux | `opencode-linux-arm64.tar.gz` | `sha256-ylNLmALAoLZxruu3WOUZpC5S1xZZe07CAsdWbGLMXPY=` |
| aarch64-darwin | `opencode-darwin-arm64.zip` | `sha256-Og1Vb543zv3BrxjJdNnY+BMM2PH5mZNJyjhMi1NMYgM=` |
| x86_64-linux | `opencode-linux-x64.tar.gz` | `sha256-eK/+lS/2bnf5pI6R/8FtrAlRHaIHlbPIGLMIWNBNsSc=` |
| x86_64-darwin | `opencode-darwin-x64.zip` | `sha256-peusqNY4VqtVeqEZmeepIogx9uowsE0gnyBEx3mlodY=` |

Release: published 2026-06-05T18:58:01Z, not draft / not prerelease, all 4 platform
assets + `checksums.sha256` present, and it is the repo's **`releases/latest`** — so the
workstation `update-opencode-patched.yml` cron (~18:00 EDT) will track the CAPPED
version, not the uncapped `v1.16.2-patched`.

## 3. Pure-build proof (no --impure)

```
$ nix build --no-link --print-out-paths .#homeConfigurations.cloudbox.activationPackage
  (4 derivations built incl. opencode-patched-1.16.2.1.drv)
  /nix/store/xxhns0im1dai15b95pqcwyzk4dwjphyw-home-manager-generation
  real 0m53s   # NO --impure flag
```

Built opencode binary = `/nix/store/fwmg3h82vk2dl34zrzkz93898njhd01c-opencode-patched-1.16.2.1`.
Cap markers confirmed in `.opencode-wrapped`:

- `RETRY_JITTER_RATIO` present (×1); `MAX_RETRIES` present (×2)
- downward jitter math: `Math.round(A*(1-Math.random()*Ea))`
- attempt cap (minified): `attempt>na)return kA.done` (`meta.attempt > MAX_RETRIES → Cause.done`)
- `bin/opencode --version` → `1.16.2`

The cure (capped retry) is present in the pure-built published binary. The retry-cap
production hunks are byte-identical to the 1.15.13.3 local build (per `retry-cap-deploy.md`
§1); only the upstream base differs (1.15.13 → 1.16.2).

## 4. Deploy (generation 381)

```
$ nix run home-manager -- switch --flake ~/projects/workstation#cloudbox   # PURE
  Activating injectAigatewayBaseUrl
  aigateway: pointed opencode at …/publishers/anthropic/models (anthropic)
             and …/publishers/google (gemini)
  # NO "baseURL changed … restarting opencode-serve" line  → restart skipped
```

- New generation **381** (`/nix/store/xxhns0im1dai15b95pqcwyzk4dwjphyw-home-manager-generation`), current.
- Profile binary `~/.nix-profile/bin/opencode` → `fwmg3h82…-opencode-patched-1.16.2.1`.
- `opencode-serve` MainPID **unchanged** (1740135, started 15:48:27) → the switch did
  **not** restart serve. The running process is still the prior capped `1.15.13.3`
  (`wmf3lc23…`); it swaps to `1.16.2-patched.1` only on the final controlled restart.

### Why the switch didn't restart serve (intentional)

`injectAigatewayBaseUrl` restarts `opencode-serve` whenever its URL hash changes. The
stored hash file (`~/.cache/workstation/aigateway-url.hash`) held the **old
anthropic-only** value `2cf8ebeb…`, while the activation now computes the **two-line**
`dc629052…`. Left alone, the switch would have restarted serve mid-activation and killed
this session (risking a half-applied generation). Mitigation: the hash file was
**pre-seeded** with `dc629052…` immediately before the switch, so the activation saw
`new_hash == old_hash` and skipped the restart. The runtime `opencode.json` already
carried both base URLs, so nothing was lost — the single controlled restart (below)
performs the one intended bounce.

`installOpencodePlugins` (the other serve-restarting activation) only restarts on plugin
cache invalidation; no plugin pins changed, so it did not fire.

## 5. Rollback

The deploy is fully reversible. **Both** the immediate prior generation (380) and 379
hold a **capped** binary (`opencode-patched-1.15.13.3`, store path
`/nix/store/wmf3lc23s0avsf2n3311dn0l4bngk1hm-opencode-patched-1.15.13.3`):

```bash
# Recommended: immediate prior generation (380, capped 1.15.13.3)
/nix/store/3v2q6ir21kdqp27xaq8hph12anp1i80d-home-manager-generation/activate
sudo systemctl restart opencode-serve.service

# Equivalent: generation 379 (same capped 1.15.13.3 binary)
/nix/store/mwljsvypsc1cnb0hz1m2x1bg212dfi39-home-manager-generation/activate
sudo systemctl restart opencode-serve.service
```

**Do NOT roll back to generation 378** —
`/nix/store/p0nsgnv71rynsps5bq27vb6kqmqzb544-home-manager-generation` is the **uncapped
1.16.2** drift (`nisvz7q…-opencode-patched-1.16.2`).

Config rollback (revert + re-switch, no --impure needed since HEAD is publishable):
```bash
cd ~/projects/workstation
git revert <capped-bump-commit>        # TASK A
git revert 96c2cd6                     # TASK B (gemini routing), if also reverting
nix run home-manager -- switch --flake ~/projects/workstation#cloudbox
sudo systemctl restart opencode-serve.service
```
To disable **only** gemini routing without a rebuild: `systemctl stop aigateway.service`
then `home-manager switch` (the strip branch removes the override), or hand-edit
`~/.config/opencode/opencode.json` to delete `provider."google-vertex".options.baseURL`
and restart serve.

## 6. Push result

- `opencode-patched` `main` @ `6fa9663` — already pushed (retry-cap patch).
- Release `v1.16.2-patched.1` — published (built from `6fa9663`).
- workstation: TASK B `96c2cd6 feat(opencode): route Gemini through aigateway on
  cloudbox` — committed **and pushed to `origin/main`** by the orchestrator.
- workstation: TASK A capped-release bump — committed by this worker and pushed
  (see final summary for the SHA). HEAD is **publishable** (no `/home` path).
- aigateway mono PR #3373 — already pushed; left untouched.

> Out of scope, left uncommitted on disk (other worker's deliverable, NOT pushed by
> this task): `AGENTS.md` (+1 line adding the auditing-opencode-llm-calls skill row)
> and the untracked `.opencode/skills/auditing-opencode-llm-calls/` dir. The
> `users/dev/opencode-llm-audit.nix` module itself is already committed.

## 7. The single controlled restart (final step — detached, after this report)

Restarting `opencode-serve` kills this worker's own session, so it is fired detached and
last (after the report + commits + push):

```bash
setsid nohup bash -c 'sleep 5; /run/wrappers/bin/sudo -n /run/current-system/sw/bin/systemctl restart opencode-serve.service' </dev/null >/tmp/durable-cure-deploy.log 2>&1 & disown
```

This one restart accomplishes BOTH goals: (a) swap the running serve to the new capped
binary `1.16.2-patched.1`, and (b) load the gemini routing from `opencode.json` into the
running process.

## 8. Post-restart verification checklist (for the resuming session)

After the restart settles (~10–20s):

1. **Serve up on the new capped binary:**
   ```bash
   systemctl status opencode-serve.service          # active (running), just started
   readlink -f /proc/$(systemctl show opencode-serve.service -p MainPID --value)/exe
   # EXPECT: /nix/store/fwmg3h82vk2dl34zrzkz93898njhd01c-opencode-patched-1.16.2.1/bin/.opencode-wrapped
   ```
2. **Cap markers in the running binary:**
   ```bash
   BIN=/nix/store/fwmg3h82vk2dl34zrzkz93898njhd01c-opencode-patched-1.16.2.1/bin/.opencode-wrapped
   grep -c RETRY_JITTER_RATIO "$BIN"   # >= 1
   grep -c MAX_RETRIES "$BIN"          # >= 2
   ```
3. **Restart log:** `/tmp/durable-cure-deploy.log` shows the restart command output
   (empty/clean = success).
4. **Gemini routes through the gateway (tokens + dollars):** send any prompt in a NEW
   session on the default model (`google-vertex/gemini-3.5-flash`), then:
   ```bash
   docker exec dev-postgres-1 psql -U aigateway -d aigateway -c \
     "SELECT model,http_status,input_tokens,output_tokens,total_dollars \
      FROM gateway_request_log WHERE model LIKE 'gemini%' ORDER BY id DESC LIMIT 5;"
   # EXPECT: a fresh gemini-3.5-flash row, http_status 200, non-null tokens AND dollars
   ```
5. **Forward-capture log shows gemini via gateway:**
   ```bash
   tail -n 50 ~/.local/state/opencode-llm-audit/llm.log | grep -i gemini
   ```
6. **Runtime config still correct:**
   ```bash
   jq '.provider | {anthropic: ."google-vertex-anthropic".options.baseURL,
                    gemini: ."google-vertex".options.baseURL}' ~/.config/opencode/opencode.json
   # EXPECT both → localhost:8080 (…/publishers/anthropic/models and …/publishers/google)
   ```
7. **Hash file converged:** `cat ~/.cache/workstation/aigateway-url.hash` →
   `dc629052ffc0c527957284f51cb65ac616e107cb117d825191f6551f342068ae`.

## 9. Watch the next overnight cycle

Confirm the cap holds: the forward-capture log
(`~/.local/state/opencode-llm-audit/llm.log`) should show no session.id repeating
abnormally, and BQ / `gateway_request_log` gemini volume stays bounded (no ~35×
amplification). See `HANDOFF.md` and `aigateway-cost-fix.md` for the dashboards.
