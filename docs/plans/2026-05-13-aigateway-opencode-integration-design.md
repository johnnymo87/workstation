# Defaulting opencode through the local aigateway — Design

**Date:** 2026-05-13
**Host scope (initial):** cloudbox
**Host scope (deferred):** macOS
**Tracking:** workstation beads (TBD when plan is written)

## Problem

The `mono` repo's `wonder/data/aigateway` MVP is a local Docker stack
(Postgres + Redis + Spring Boot) that proxies Anthropic-on-Vertex traffic and
writes a per-request ledger row (timestamp, email, model, tokens, dollars,
status). The volunteer-facing onboarding doc instructs users to point Claude
Code at the gateway via `ANTHROPIC_VERTEX_BASE_URL=http://localhost:8080`.

Workstation does not use Claude Code. It uses opencode, and on cloudbox the
default model is already `google-vertex-anthropic/claude-opus-4-7@default`,
authenticated via gcloud Application Default Credentials. opencode does not
read `ANTHROPIC_VERTEX_BASE_URL`. To make our opencode usage land in the
ledger, we have to redirect opencode's `google-vertex-anthropic` provider at
the gateway through opencode's own configuration mechanism.

## Goal

On cloudbox, every request opencode sends to Anthropic-on-Vertex flows
through the local aigateway by default. Bypass back to direct Vertex is
available via a single config knob (no code change, no rebuild required for
the bypass itself).

## Constraints (workstation idioms)

- **Public repo discipline.** Per the `scrubbing-company-references` skill,
  no org-identifying strings (project IDs, internal hostnames, vendor
  domains) get committed. Anything org-identifying lives in sops on cloudbox
  and Keychain on macOS, read at activation time.
- **Activation-script idiom.** Opencode runtime config (`~/.config/opencode/
  opencode.json`) is built by merging a Nix-built managed JSON over a
  runtime-mutable JSON. Conditional secret injection follows the existing
  `injectSlackMcpSecretsSops` / `injectDatadogMcpSecretsSops` pattern: read
  from `/run/secrets/<name>`, write into `opencode.json` via `jq`, delete
  the corresponding key if the secret is missing.
- **Bypass-first.** The aigateway's own onboarding doc emphasizes a panic
  button. Workstation should mirror that — disabling the gateway has to be a
  one-step recoverable action.
- **opencode-serve is the primary surface on cloudbox.** Most opencode
  sessions on cloudbox are launched via pigeon / Telegram into the
  systemd-managed `opencode-serve.service`. Whatever we configure has to be
  picked up by `opencode-serve`, not just by interactive TUI sessions.

## How opencode actually talks to Vertex (verified against source)

From `~/projects/opencode/packages/opencode/src/provider/provider.ts:498`:

```ts
"google-vertex-anthropic": Effect.fnUntraced(function* () {
  const env = yield* dep.env()
  const project = env["GOOGLE_CLOUD_PROJECT"] ?? env["GCP_PROJECT"] ?? env["GCLOUD_PROJECT"]
  const location = env["GOOGLE_CLOUD_LOCATION"] ?? env["VERTEX_LOCATION"] ?? "global"
  const autoload = Boolean(project)
  if (!autoload) return { autoload: false }
  return { autoload: true, options: { project, location }, ... }
})
```

The provider is autoloaded when `GOOGLE_CLOUD_PROJECT` is in the environment.
Cloudbox already exports it (in `home.cloudbox.nix:148` for interactive
shells and in `hosts/cloudbox/configuration.nix:460` for `opencode-serve`),
and `GOOGLE_CLOUD_LOCATION=global` is already set in the `opencode-serve`
service environment.

The actual SDK call lands in `@ai-sdk/google-vertex/dist/anthropic/index.js`:

```js
return options.baseURL ?? `https://${location === "global" ? "" : location + "-"}aiplatform.googleapis.com/v1/projects/${project}/locations/${location}/publishers/anthropic/models`;
// then: `${baseURL}/${modelId}:streamRawPredict`
```

So overriding `provider.google-vertex-anthropic.options.baseURL` in
`opencode.json` fully replaces everything up to (and not including) the
model id and the streaming-suffix. The gateway's `/**` catch-all controller
will then receive a request like:

```
POST http://localhost:8080/v1/projects/<project>/locations/global/publishers/anthropic/models/claude-opus-4-7@default:streamRawPredict
Authorization: Bearer ya29.<real ADC token>
```

The gateway extracts the location with `Regex("/locations/([^/]+)")` (which
returns `global` here, exercising the happy path and bypassing the broken
`?: "us-east5"` fallback that the parallel cleanup session is fixing). The
`ya29...` token is what the gateway's `EmailResolver` needs to resolve the
caller email via Google's `tokeninfo` endpoint.

Conclusion: we redirect opencode at the gateway by writing a single
`provider.google-vertex-anthropic.options.baseURL` value into
`~/.config/opencode/opencode.json`. No env-var trickery, no plugin, no
patches.

## Approach: sops-toggled baseURL injection on cloudbox

### Component 1 — packaging the gateway as a workstation-managed Docker stack

Per "(1) we'll integrate it into workstation," the gateway runs as a
systemd-managed Docker Compose service on cloudbox owned by this repo. The
`mono` checkout still hosts the *source* (server.jar + migrate.jar + the
docker-compose definitions); workstation hosts the *lifecycle*.

Add a NixOS systemd service `aigateway.service` to
`hosts/cloudbox/configuration.nix` that:

1. Depends on `docker.service` and is wanted by `multi-user.target`.
2. `WorkingDirectory=/home/dev/projects/mono/wonder/data/aigateway/dev`.
3. `ExecStart=/home/dev/projects/mono/wonder/data/aigateway/dev/start.sh -d`
   (the `-d` so docker compose detaches; service stays alive while the
   compose stack runs).
4. `ExecStop=docker compose down`.
5. Runs as `dev`. Needs `dev` in the `docker` group (already true given
   `users.users.dev.extraGroups` includes `docker`).
6. Restart=on-failure with a backoff so a stuck `bazel build` (start.sh
   re-builds the jars first) doesn't tight-loop.

Caveats and call-outs:

- **The service depends on the `mono` checkout existing on disk.** That's
  a live workstation idiom (`projects.nix` declares which repos clone where)
  so an `assert` or `ConditionPathExists=` on the working directory keeps
  the unit from failing in a confusing way during a fresh install.
- **First launch builds Bazel jars.** Roughly 2 min on a clean cache,
  per the volunteer doc. We can either (a) leave that in `start.sh`'s
  prelude and accept a 2-min boot delay on first launch, or (b) move the
  jar-build into a separate one-shot oneshot service that runs *before*
  `aigateway.service`, so the long Bazel build is observable as its own
  unit and can be retried independently. **Recommendation: (a) for now.**
  YAGNI; if the Bazel build proves flaky we revisit.
- **The unit is opt-in.** Don't `enable = true;` it unconditionally on
  cloudbox until the volunteer onboarding doc has an opencode-flavored
  variant we can trust. Wire it in but leave it disabled-by-default, with
  a one-line note in `hosts/cloudbox/configuration.nix` explaining the
  enable.
- **The aigateway docker-compose stack listens on `5432`, `6379`, `8080`**
  on the host. Cloudbox needs those ports free. Verify via `ss -tlnp`
  before enabling the service for real.

### Component 2 — gating the baseURL override on the systemd unit's enable state

Mirror the `injectSlackMcpSecretsSops` activation script's *shape* but
swap the trigger: instead of "a sops secret exists," the trigger is
"`aigateway.service` is enabled and we have a `GOOGLE_CLOUD_PROJECT`."
The URL host:port (`http://localhost:8080`) is a string constant in
`opencode-config.nix` since it isn't org-identifying — see Component 3
for the rejection of the sops-as-toggle approach.

New activation in `users/dev/opencode-config.nix`:

```nix
home.activation.injectAigatewayBaseUrl = lib.mkIf isCloudbox
  (lib.hm.dag.entryAfter [ "mergeOpencode" ] ''
    set -euo pipefail
    runtime="$HOME/.config/opencode/opencode.json"
    hash_file="$HOME/.cache/workstation/aigateway-url.hash"
    mkdir -p "$(dirname "$hash_file")"

    # Trigger: aigateway.service is enabled (`is-enabled` returns "enabled"
    # for explicitly enabled units, "alias", "static", "linked", etc.; we
    # treat anything that isn't "disabled" / "masked" / "not-found" as
    # "the operator wants this on"). Mirrors how systemd treats the unit:
    # if it's enabled at boot, downstream tooling should assume it's the
    # intended path.
    enabled_state="$(/run/current-system/sw/bin/systemctl is-enabled aigateway.service 2>/dev/null || true)"
    case "$enabled_state" in
      disabled|masked|not-found|"") gateway_enabled=0 ;;
      *)                            gateway_enabled=1 ;;
    esac

    project=""
    if [ -r /run/secrets/google_cloud_project ]; then
      project="$(cat /run/secrets/google_cloud_project)"
    fi

    if [[ "$gateway_enabled" = "0" ]] || [[ -z "$project" ]]; then
      # Strip any prior override so opencode falls back to the direct
      # Vertex path. The del + reset-if-empty ladder keeps opencode.json
      # clean of orphaned empty objects.
      if [[ "$gateway_enabled" = "0" ]]; then
        echo "aigateway: aigateway.service is not enabled; opencode pointed at direct Vertex" >&2
      else
        echo "aigateway: GOOGLE_CLOUD_PROJECT secret unavailable; opencode pointed at direct Vertex" >&2
      fi
      if [[ -f "$runtime" ]]; then
        tmp="$(mktemp "''${runtime}.tmp.XXXXXX")"
        ${pkgs.jq}/bin/jq 'del(.provider."google-vertex-anthropic".options.baseURL)
                          | if .provider."google-vertex-anthropic".options == {}
                            then del(.provider."google-vertex-anthropic".options) else . end
                          | if .provider."google-vertex-anthropic" == {}
                            then del(.provider."google-vertex-anthropic") else . end
                          | if .provider == {} then del(.provider) else . end' \
          "$runtime" > "$tmp"
        mv "$tmp" "$runtime"
      fi
      new_hash="DIRECT-VERTEX"
    else
      # The gateway path shape MUST match what @ai-sdk/google-vertex/
      # anthropic generates by default — verified against
      # node_modules/.bun/@ai-sdk+google-vertex@4.0.112+.../anthropic/
      # index.js (the `getBaseURL` function). If the SDK version drifts
      # and changes that path shape, this constant must move with it.
      full_url="http://localhost:8080/v1/projects/$project/locations/global/publishers/anthropic/models"

      if [[ -f "$runtime" ]]; then
        tmp="$(mktemp "''${runtime}.tmp.XXXXXX")"
        ${pkgs.jq}/bin/jq --arg url "$full_url" \
          '.provider."google-vertex-anthropic".options.baseURL = $url' \
          "$runtime" > "$tmp"
        mv "$tmp" "$runtime"
      fi
      new_hash="$(printf '%s' "$full_url" | sha256sum | cut -d" " -f1)"
    fi

    # Auto-restart opencode-serve only when the effective URL changed.
    # See Component 4 for the full reasoning. Same sudo dance as
    # installOpencodePlugins (above) for the same reasons documented there.
    old_hash=""
    [ -r "$hash_file" ] && old_hash="$(cat "$hash_file")"
    if [[ "$new_hash" != "$old_hash" ]]; then
      echo "aigateway: baseURL changed ($old_hash -> $new_hash); restarting opencode-serve" >&2
      sudo_err="$(mktemp)"
      sudo_rc=0
      /run/wrappers/bin/sudo -n /run/current-system/sw/bin/systemctl restart opencode-serve.service 2>"$sudo_err" || sudo_rc=$?
      if [ "$sudo_rc" -eq 0 ]; then
        echo "$new_hash" > "$hash_file"
      else
        {
          echo "aigateway: WARNING — opencode-serve restart failed (sudo exit $sudo_rc):"
          sed 's/^/  /' "$sudo_err"
          echo "aigateway: hash file NOT updated; next rebuild will retry."
        } >&2
      fi
      rm -f "$sudo_err"
    fi
  '');
```

- The strip-on-disabled branch is symmetric with the inject-on-enabled
  branch and fully cleans up the nested object so `opencode.json` doesn't
  sprout empty `provider.google-vertex-anthropic.options = {}` litter
  that would confuse later debugging.
- `del + reset-if-empty` ladder is uglier than ideal. If a third caller
  ever needs the same shape, factor it into a jq helper under
  `assets/opencode/`. Two callers (this and a hypothetical macOS sibling)
  is below the rule-of-three threshold.

### Component 3 — host:port as a string constant (no sops)

The URL `http://localhost:8080` is a string constant in
`users/dev/opencode-config.nix`. It's not org-identifying, and putting it
in sops would bloat the secrets file with non-secret data without buying
us anything we don't already get from Component 2's enabled-state toggle.

The bypass is "disable the systemd unit, re-apply, opencode-serve
restarts": `sudo systemctl disable --now aigateway.service && nix run
home-manager -- switch --flake .#cloudbox`. The activation strips the
override, the auto-restart picks up the cleaned config, opencode is back
on direct Vertex. To re-enable: `sudo systemctl enable --now
aigateway.service && nix run home-manager -- switch --flake .#cloudbox`.

(Counter-argument we considered and rejected: putting the URL in sops to
make "set the secret to empty string and rebuild" the bypass. Rejected
because the systemd unit's enable state already encodes operator intent
naturally, and using the same signal for both "is the gateway running?"
and "should opencode point at it?" prevents the failure mode where the
unit is disabled but opencode still tries to reach it, or vice versa.)

### Component 4 — auto-restart opencode-serve on URL change

The activation rewrites `opencode.json`, and `opencode-serve` reads it
once at boot. To make `nix run home-manager -- switch` a complete
operation, the activation auto-restarts `opencode-serve.service` whenever
the effective baseURL changes (including the strip → direct-Vertex
transition).

Implementation: hash the effective URL (or the literal string
`DIRECT-VERTEX` for the strip case), compare against
`~/.cache/workstation/aigateway-url.hash`, restart only when they differ.
Mirrors the cache-invalidation flag in the existing
`installOpencodePlugins` activation, including its `sudo` mechanics
(absolute paths, `cmd || rc=$?` capture instead of `if cmd; then`).

Footgun avoided: hash is written *only after the restart succeeds*, so a
sudo failure doesn't silently mask the next rebuild's retry attempt.

### Component 5 — operator helpers (deferred)

Two small helpers were considered but cut from this iteration to keep
scope tight:

1. **`aigateway-health`** — wrap `curl -s http://localhost:8080/actuator/
   health | jq`, exit non-zero if any component is `DOWN`. Pre-session
   sanity check.
2. **`aigateway-ledger-tail`** — wrap the `psql` query from the volunteer
   doc, showing the last 10 ledger rows for the current `gcloud`-resolved
   email. Verify that the last opencode call hit the gateway.

Both would slot into `users/dev/home.cloudbox.nix` as
`pkgs.writeShellApplication` packages, same idiom as `pigeon-setup-secrets`
on macOS. Add them if the muscle memory of writing the underlying
commands by hand turns out to be friction in practice.

### Component 6 — locking `GOOGLE_CLOUD_LOCATION=global` (already done)

The overridden baseURL hardcodes `/locations/global/` in its path. For
the gateway and opencode to agree, every code path that loads
`google-vertex-anthropic` must set `GOOGLE_CLOUD_LOCATION=global`.

Audit confirmed this is already the case on cloudbox:

- `hosts/cloudbox/configuration.nix:444` — `opencode-serve.service`'s
  `Environment=` block.
- `users/dev/home.base.nix:1539` — interactive bash via `initExtra`
  (cross-host; comment there mentions Gemini-on-Vertex as the original
  motivation, but the export benefits us too).

No action required for this component. Future macOS branch will need a
parallel verification — `home.base.nix` covers macOS too via the
shared `initExtra`, so likely also a no-op there.

## What this design does NOT do

- **Does not run on macOS.** Macros for the Keychain branch will mirror the
  sops branch line-for-line (read `aigateway-base-url` from Keychain,
  read `google-cloud-project` from Keychain, same jq dance). Out of scope
  for this iteration.
- **Does not auto-bypass on gateway down.** If `aigateway-base-url` is set
  and the gateway is down, every opencode request gets a connection-refused
  error. Acceptable initially — this is a "FAFO" deployment posture and a
  loud failure beats silent direct-Vertex requests that don't get billed
  properly. If this proves annoying in practice, we add a startup probe
  to the activation script (`curl -fsS http://localhost:8080/actuator/health
  >/dev/null` → if it fails, strip the URL with a warning).
- **Does not write opencode-flavored volunteer docs.** Per (1)+(5) in the
  conversation, those go in `mono` separately, in a follow-up PR co-authored
  with our actual usage experience. Not workstation's concern.
- **Does not address the `us-east5` fallback bug.** Separate parallel
  session in `mono`. The integration here works *because* our URL contains
  `/locations/global/`, so the regex extracts `global` and the fallback
  doesn't trigger. The fallback is still wrong and should be fixed; we just
  don't depend on its fix landing first.
- **Does not address the Claude Code references in workstation.** Separate
  parallel session.
- **Does not address the leaked org strings (`wonder-sandbox-bazel-cache`,
  `bundle-fury-freshrealm-com`, root-level `session-ses_28bc.md`).**
  Separate parallel session. *This design must not introduce any new such
  strings.*

## Risks

| Risk | Severity | Mitigation |
|---|---|---|
| First `start.sh` invocation takes 2+ min for Bazel build, blocking unit start | Low | Document in the unit comment. If real, split build into a one-shot prereq unit later. |
| `opencode-serve` boot races with `aigateway.service` boot (opencode comes up first, fails first request) | Medium | Add `Wants=aigateway.service` and `After=aigateway.service` to `opencode-serve.service`. `Wants=` is non-fatal if aigateway isn't enabled, so this doesn't break devbox or the disabled-by-default initial state. |
| Activation auto-restart fights with the nightly 3 AM `workstation-reset.service` | Low | Both restart `opencode-serve` for legitimate reasons; restarting twice in a window is harmless (idempotent). Auto-restart only fires when the URL hash changes, so it's a no-op on most rebuilds. |
| Auto-restart's sudo call fails (e.g. `wheelNeedsPassword=true` regression) and the hash file gets out of sync | Low | We deliberately don't write the hash file until restart succeeds, so the next rebuild retries. The activation logs the failure to stderr loud enough to spot. Same defensive pattern as `installOpencodePlugins`. |
| Path interpolation drifts if AI SDK upstream changes the URL shape | Medium | We've baked `/v1/projects/.../locations/global/publishers/anthropic/models` into the activation script. If `@ai-sdk/google-vertex` ever changes that, our overridden URL stops matching what the gateway expects. Comment in the activation points at the SDK file (`@ai-sdk+google-vertex@4.0.112+.../anthropic/index.js`) and the verified-against version. |
| `provider.google-vertex-anthropic` is the wrong key on a future opencode version | Low | Same as above — comment with verified-against opencode commit / version. Also caught by Verification step 4 (jq lookup of the exact key). |
| Operator forgets to `enable` the unit and is confused when the activation doesn't inject a baseURL | Low | Activation logs `aigateway.service is not enabled; opencode pointed at direct Vertex` on the strip path. Document the enable step in commit message and a future skill. |

## Verification

Order matters; each step assumes the prior succeeded.

**Phase 1 — gateway up, opencode pointed at it**

1. `sudo systemctl enable --now aigateway.service`. After ~2 min on a
   clean Bazel cache, `sudo systemctl status aigateway` shows
   `active (running)`.
2. `curl -s http://localhost:8080/actuator/health | jq '.status'` returns
   `"UP"`.
3. `nix run home-manager -- switch --flake .#cloudbox`. Activation should
   log `aigateway: baseURL changed (... -> <hash>); restarting opencode-serve`.
4. `cat ~/.config/opencode/opencode.json | jq '.provider."google-vertex-anthropic".options.baseURL'`
   matches `http://localhost:8080/v1/projects/<project>/locations/global/publishers/anthropic/models`.
5. `systemctl status opencode-serve` shows it restarted at the expected
   time (look at `Active: active (running) since ...`).
6. `echo $GOOGLE_CLOUD_LOCATION` in a fresh bash session prints `global`.
7. New session via `opencode-launch`. Send any prompt. After response:

   ```bash
   PGPASSWORD=aigateway-local-dev psql -h localhost -U aigateway -d aigateway -c \
     "SELECT user_email, model, http_status, total_dollars
      FROM gateway_request_log ORDER BY id DESC LIMIT 5"
   ```

   Should show a row with our `gcloud`-resolved email,
   `claude-opus-4-7@default`, `http_status=200`, non-null `total_dollars`.

**Phase 2 — bypass test**

8. `sudo systemctl disable --now aigateway.service`. Verify with
   `systemctl is-enabled aigateway` → `disabled`.
9. `nix run home-manager -- switch --flake .#cloudbox`. Activation should
   log `aigateway: baseURL changed (<hash> -> DIRECT-VERTEX); restarting
   opencode-serve`.
10. `cat ~/.config/opencode/opencode.json | jq '.provider // empty'`
    should output nothing (or, if `provider` exists for unrelated reasons,
    no `google-vertex-anthropic.options.baseURL` key under it).
11. New session via `opencode-launch`. Send any prompt. The request must
    NOT appear in the ledger (the gateway is down anyway, but the proof
    is that opencode succeeded — meaning it reached Vertex directly).

**Phase 3 — re-enable test**

12. `sudo systemctl enable --now aigateway.service && nix run
    home-manager -- switch --flake .#cloudbox`. New session, prompt,
    confirm a fresh ledger row appears.

**Phase 4 — idempotence test**

13. Run `nix run home-manager -- switch --flake .#cloudbox` a second time
    with no state changes. Activation should NOT log a baseURL change and
    should NOT restart opencode-serve. The hash file
    `~/.cache/workstation/aigateway-url.hash` confirms by being unchanged
    on disk.

## Out of band

The three parallel cleanup sessions in flight:

- `ses_1dda1333cffebkOUceazYClTpn` — Claude Code reference cleanup in
  workstation.
- `ses_1dda0e4b7ffehcS7pTijUkSLfd` — `us-east5` → `global` in
  `wonder/data/aigateway` (mono).
- `ses_1dda07faaffeKgnuBLfPW8LwlF` — org-string scrubbing in workstation.

If any of those land before we ship this design, they'll either:

- Tighten an assumption this doc rests on (us-east5 fix → our `global` URL
  is now also the gateway's *default* not just our happy path; no impact).
- Eliminate a leaked string (org-scrub → unrelated).
- Clarify Claude Code refs (CC cleanup → unrelated, but it'll touch some
  of the same files in `users/dev/`, so we coordinate by rebasing whichever
  PR lands second).

We don't need any of them to merge before this work can start.
