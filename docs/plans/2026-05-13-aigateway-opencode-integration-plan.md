# Aigateway → opencode Integration Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** On cloudbox, route opencode's `google-vertex-anthropic` provider through the local aigateway by default, with the gateway itself managed as a workstation systemd unit. Bypass = disable the unit and re-apply home-manager.

**Architecture:** A NixOS systemd unit (`aigateway.service`) wraps the existing `wonder/data/aigateway/dev/start.sh` script. A home-manager activation script reads the unit's `is-enabled` state and the `GOOGLE_CLOUD_PROJECT` sops secret, then either injects `provider.google-vertex-anthropic.options.baseURL` into `~/.config/opencode/opencode.json` or strips it. A SHA-256 hash of the effective URL gates auto-restart of `opencode-serve.service` so rebuilds are idempotent.

**Tech Stack:** NixOS systemd units, home-manager activation scripts, jq, sha256sum, sops-nix, Docker Compose (already running on cloudbox).

**Design doc:** `docs/plans/2026-05-13-aigateway-opencode-integration-design.md`

**Verification model:** Activation scripts have no test harness. Each task ends with concrete verification commands and expected output. We commit per task; if a verification fails, we roll back the single commit, fix, re-commit.

---

## Pre-flight (read once before starting)

- **Current host must be cloudbox.** `echo $OPENCODE_HOSTNAME` should print `cloudbox`. Every `nix run home-manager` and `sudo nixos-rebuild` command targets `.#cloudbox`.
- **Working directory:** `~/projects/workstation`. Branch: `main`. No worktree.
- **Reference paths to read once before any code:**
  - `users/dev/opencode-config.nix:400-441` — the `injectSlackMcpSecretsSops` activation we mirror.
  - `users/dev/opencode-config.nix:196-296` — the `installOpencodePlugins` activation, source of the sudo-restart pattern we mirror.
  - `users/dev/home.base.nix:385-461` — the `generateBazelrc` activation, source of the template-from-secret pattern.
  - `hosts/cloudbox/configuration.nix:413-491` — the `opencode-serve.service` definition we add `Wants=`/`After=` to.
  - `hosts/cloudbox/configuration.nix:78-95` (sops block, `google_cloud_project` declared there).
  - `~/projects/mono/wonder/data/aigateway/dev/start.sh` — the script the systemd unit wraps.
- **Coordination with parallel sessions:** Two cleanup sessions still running (Claude Code refs in workstation, us-east5 → global in mono). If either lands a commit on `main` that touches `users/dev/opencode-config.nix`, `users/dev/home.cloudbox.nix`, or `hosts/cloudbox/configuration.nix`, rebase before continuing the next task.
- **Sudo expectations:** Cloudbox has `wheelNeedsPassword=false`, so `sudo` calls in activation scripts work non-interactively.

---

### Task 1: Verify reference state before changes

**Files:**
- Read-only: confirms baseline before any modifications.

**Step 1: Confirm the host**

Run: `echo "$OPENCODE_HOSTNAME"`
Expected: `cloudbox`

If anything else, STOP. This plan does not run on devbox or macOS.

**Step 2: Confirm `GOOGLE_CLOUD_LOCATION` is already `global`**

Run: `grep -n 'GOOGLE_CLOUD_LOCATION' ~/projects/workstation/users/dev/home.base.nix ~/projects/workstation/hosts/cloudbox/configuration.nix`

Expected: hits in both files, all values `global`. Specifically:
- `home.base.nix:1539: export GOOGLE_CLOUD_LOCATION="global"`
- `hosts/cloudbox/configuration.nix:444: "GOOGLE_CLOUD_LOCATION=global"`

If anything is `us-east5` or absent, STOP and surface — Component 6 of the design assumes these are in place.

**Step 3: Confirm `google_cloud_project` sops secret exists and decrypts**

Run: `sudo cat /run/secrets/google_cloud_project | wc -c`
Expected: a positive integer (the byte count of the project ID). 0 means the secret isn't being decrypted; STOP and debug.

**Step 4: Confirm Docker is up and `dev` is in `docker` group**

Run: `systemctl is-active docker && groups dev | grep -q docker && echo OK`
Expected: `active` then `OK` on a single line.

**Step 5: Confirm `mono` is checked out at the expected path**

Run: `test -x ~/projects/mono/wonder/data/aigateway/dev/start.sh && echo OK`
Expected: `OK`

**Step 6: Confirm port 8080 is free**

Run: `ss -tlnp 2>/dev/null | grep ':8080 ' || echo FREE`
Expected: `FREE`. If something is listening, STOP and resolve.

**Step 7: Snapshot current `opencode.json` provider state**

Run: `jq '.provider // {}' ~/.config/opencode/opencode.json`
Expected: probably `{}` (no provider overrides currently). Whatever it is, note it — the activation we're adding must not disturb anything outside `provider.google-vertex-anthropic.options.baseURL`.

**Step 8: No commit (read-only task).**

---

### Task 2: Add `aigateway.service` systemd unit (disabled by default)

**Files:**
- Modify: `hosts/cloudbox/configuration.nix` — add a new `systemd.services.aigateway` block alongside the existing `systemd.services.opencode-serve`.

**Step 1: Read the existing `opencode-serve.service` definition for structural reference**

Run: `sed -n '413,491p' ~/projects/workstation/hosts/cloudbox/configuration.nix`
Expected: see the unit's structure (description, after/wants, serviceConfig, ExecStart shape).

**Step 2: Add the new unit**

Insert after the closing `};` of `systemd.services.opencode-serve`. Locate that closing brace first (`grep -n 'opencode-serve = {' hosts/cloudbox/configuration.nix` then count braces forward) before pasting.

```nix
  # Aigateway: local Anthropic-on-Vertex proxy that captures per-request
  # attribution to a Postgres ledger. Source lives in the mono repo
  # (~/projects/mono/wonder/data/aigateway/); this unit wraps its
  # dev/start.sh which (1) bazel-builds the server.jar + migrate.jar then
  # (2) brings up Docker Compose (Postgres + Redis + Spring Boot on :8080).
  #
  # First boot: ~2 min for the Bazel build on a clean cache. Subsequent
  # boots: ~10 sec.
  #
  # Disabled by default — enable with `sudo systemctl enable --now
  # aigateway.service`. The home-manager activation
  # `injectAigatewayBaseUrl` keys off this unit's `is-enabled` state to
  # decide whether to point opencode at the gateway.
  systemd.services.aigateway = {
    description = "AI Gateway (local Anthropic-on-Vertex proxy)";
    after = [ "docker.service" "network-online.target" ];
    wants = [ "network-online.target" ];
    requires = [ "docker.service" ];
    # Disabled by default — operator opts in.
    wantedBy = [ ];

    # Skip silently if the mono checkout is missing (fresh-install state).
    unitConfig.ConditionPathIsExecutable =
      "/home/dev/projects/mono/wonder/data/aigateway/dev/start.sh";

    serviceConfig = {
      Type = "simple";
      User = "dev";
      Group = "dev";
      WorkingDirectory = "/home/dev/projects/mono/wonder/data/aigateway/dev";
      # `start.sh -d` runs the bazel build in foreground then `docker
      # compose up -d`. After detach, the service "succeeds" — but we
      # need the unit to stay active so `is-enabled`/`is-active` reflect
      # operator intent. Type=oneshot + RemainAfterExit handles that.
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "/home/dev/projects/mono/wonder/data/aigateway/dev/start.sh -d";
      ExecStop = "${pkgs.docker}/bin/docker compose down";
      # Bazel + Docker Compose can take a while on first boot.
      TimeoutStartSec = "10min";
      Restart = "on-failure";
      RestartSec = 30;
    };
  };
```

**Step 3: Run nixos-rebuild dry-run**

Run: `sudo nixos-rebuild dry-build --flake ~/projects/workstation#cloudbox 2>&1 | tail -20`
Expected: build succeeds, no eval errors. Any "infinite recursion" or "attribute missing" messages mean the unit references a binding that doesn't exist in this scope (e.g. `pkgs` not in scope) — fix before continuing.

**Step 4: Apply the system change**

Run: `sudo nixos-rebuild switch --flake ~/projects/workstation#cloudbox 2>&1 | tail -10`
Expected: `activating the configuration...` followed by `setting up tmpfiles` and a clean exit. No "Failed to start" lines.

**Step 5: Verify the unit exists and is disabled**

Run: `systemctl is-enabled aigateway.service`
Expected: `disabled`

Run: `systemctl status aigateway.service 2>&1 | head -5`
Expected: `Loaded: loaded (...; disabled; ...)`, `Active: inactive (dead)`. If `Loaded: not-found`, the unit didn't materialize — check `journalctl -xe`.

**Step 6: Commit**

```bash
cd ~/projects/workstation
git add hosts/cloudbox/configuration.nix
git commit -m "cloudbox: add aigateway.service systemd unit (disabled)

Wraps the local Docker aigateway from ~/projects/mono/wonder/data/aigateway
as a NixOS systemd unit. Disabled by default — operator opts in via
\`sudo systemctl enable --now aigateway.service\`.

The home-manager activation in a follow-up commit keys off this unit's
\`is-enabled\` state to decide whether to point opencode at the gateway.

Type=oneshot + RemainAfterExit because start.sh exits cleanly after
\`docker compose up -d\` detaches; we want the unit to stay 'active'
to reflect operator intent for downstream tools.

Per design doc 2026-05-13-aigateway-opencode-integration-design.md."
```

---

### Task 3: Add `Wants=`/`After=` for opencode-serve → aigateway ordering

**Files:**
- Modify: `hosts/cloudbox/configuration.nix` — `systemd.services.opencode-serve` block.

**Step 1: Locate the existing `after`/`wants` lists in `opencode-serve`**

Run: `grep -n -A2 'opencode-serve = {' ~/projects/workstation/hosts/cloudbox/configuration.nix | head -10`
Expected: shows the start of the unit. Find its `after = [ ... ];` and `wants = [ ... ];` lines.

**Step 2: Add `aigateway.service` to both**

In the `opencode-serve` unit, change `after` and `wants` to include `"aigateway.service"`. Example shape (yours may differ):

```nix
after = [ "network-online.target" "aigateway.service" ];
wants = [ "network-online.target" "aigateway.service" ];
```

`Wants=` is non-fatal: if `aigateway` isn't enabled, opencode-serve still starts. If `aigateway` IS enabled, opencode-serve waits for it. This is exactly the property we want.

**Step 3: Apply**

Run: `sudo nixos-rebuild switch --flake ~/projects/workstation#cloudbox 2>&1 | tail -10`
Expected: clean.

**Step 4: Verify the dependency was added**

Run: `systemctl show opencode-serve.service -p Wants -p After | grep aigateway`
Expected: both lines mention `aigateway.service`.

**Step 5: Verify opencode-serve still works (sanity check; we didn't change its behavior, only its ordering)**

Run: `curl -s http://127.0.0.1:4096/global/health && echo`
Expected: a JSON object (or at least a 200). If opencode-serve is dead, restart it: `sudo systemctl restart opencode-serve` and re-curl.

**Step 6: Commit**

```bash
cd ~/projects/workstation
git add hosts/cloudbox/configuration.nix
git commit -m "cloudbox: order opencode-serve after aigateway.service

Wants= keeps the dependency non-fatal when aigateway is disabled (the
default state) — opencode-serve starts normally. When aigateway IS
enabled, After= waits for it to come up before opencode-serve, avoiding
a connection-refused on the first request.

Per design doc 2026-05-13-aigateway-opencode-integration-design.md."
```

---

### Task 4: Add the `injectAigatewayBaseUrl` activation script (no auto-restart yet)

We split this into two tasks: this one adds the inject/strip logic, the next adds the auto-restart hash dance. Keeping commits small means each verifies independently.

**Files:**
- Modify: `users/dev/opencode-config.nix` — add a new `home.activation.injectAigatewayBaseUrl` block, alongside the existing `injectSlackMcpSecretsSops`.

**Step 1: Read the reference activation**

Run: `sed -n '400,441p' ~/projects/workstation/users/dev/opencode-config.nix`
Expected: see the structure of `injectSlackMcpSecretsSops` — `lib.mkIf isCloudbox`, `lib.hm.dag.entryAfter [ "mergeOpencode" ]`, `set -euo pipefail`, jq pipeline, mv-on-success.

**Step 2: Add the new activation**

Insert immediately after the closing `'');` of `injectSlackMcpSecretsSops` (around line 441). Whitespace and indentation must match the surrounding file.

```nix
  # Inject (or strip) the aigateway baseURL override on cloudbox.
  # Trigger: `aigateway.service` is enabled AND we have a GOOGLE_CLOUD_PROJECT.
  # When both conditions hold: set `provider.google-vertex-anthropic.options.baseURL`
  # to a URL pointing at the local Docker gateway, with the project baked
  # into the path. Otherwise: strip the override so opencode falls back to
  # direct Vertex.
  #
  # The path shape MUST match what @ai-sdk/google-vertex/anthropic
  # generates by default — verified against
  # node_modules/.bun/@ai-sdk+google-vertex@4.0.112+.../anthropic/index.js
  # (the `getBaseURL` function). If that SDK version drifts in opencode's
  # bundled deps, this hardcoded path may need to move with it. Verified
  # against opencode commit at the time of writing — see design doc
  # 2026-05-13-aigateway-opencode-integration-design.md.
  home.activation.injectAigatewayBaseUrl = lib.mkIf isCloudbox
    (lib.hm.dag.entryAfter [ "mergeOpencode" ] ''
      set -euo pipefail

      runtime="$HOME/.config/opencode/opencode.json"

      # Trigger: aigateway.service is enabled. `is-enabled` returns
      # "enabled" for explicitly enabled units, "alias", "static",
      # "linked", etc. We treat anything that isn't "disabled" / "masked"
      # / "not-found" / "" as "operator wants this on".
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
        exit 0
      fi

      full_url="http://localhost:8080/v1/projects/$project/locations/global/publishers/anthropic/models"

      if [[ -f "$runtime" ]]; then
        tmp="$(mktemp "''${runtime}.tmp.XXXXXX")"
        ${pkgs.jq}/bin/jq --arg url "$full_url" \
          '.provider."google-vertex-anthropic".options.baseURL = $url' \
          "$runtime" > "$tmp"
        mv "$tmp" "$runtime"
      fi
      echo "aigateway: pointed opencode at $full_url" >&2
    '');
```

**Step 3: Apply home-manager**

Run: `nix run home-manager -- switch --flake ~/projects/workstation#cloudbox 2>&1 | tail -20`
Expected: clean exit. Look for `aigateway: aigateway.service is not enabled; opencode pointed at direct Vertex` in the output (since we haven't enabled the unit yet).

**Step 4: Verify the strip path produced clean state**

Run: `jq '.provider // empty' ~/.config/opencode/opencode.json`
Expected: empty output (no `provider` key at all). If the snapshot from Task 1 step 7 had a non-empty `.provider` for unrelated reasons, then expect that same content here MINUS any `google-vertex-anthropic.options.baseURL` (and related parents collapsed if empty).

**Step 5: Now exercise the inject path. Enable the unit (don't start, just enable)**

Run: `sudo systemctl enable aigateway.service && systemctl is-enabled aigateway.service`
Expected: `Created symlink ...` then `enabled`.

**Step 6: Re-apply home-manager**

Run: `nix run home-manager -- switch --flake ~/projects/workstation#cloudbox 2>&1 | tail -10`
Expected: clean exit, log line `aigateway: pointed opencode at http://localhost:8080/v1/projects/<project>/locations/global/publishers/anthropic/models`.

**Step 7: Verify the inject path produced the expected URL**

Run: `jq -r '.provider."google-vertex-anthropic".options.baseURL' ~/.config/opencode/opencode.json`
Expected: `http://localhost:8080/v1/projects/<your-project>/locations/global/publishers/anthropic/models` (the actual project string substituted in, no literal `$project`).

If the output contains `$project` literally, the activation didn't decrypt the secret — re-check `/run/secrets/google_cloud_project` is readable.

**Step 8: Disable the unit again to leave a clean state for Task 5**

Run: `sudo systemctl disable aigateway.service && nix run home-manager -- switch --flake ~/projects/workstation#cloudbox 2>&1 | tail -5`
Expected: disabled, then clean exit, then `aigateway: aigateway.service is not enabled; opencode pointed at direct Vertex` in the log.

Run: `jq '.provider // empty' ~/.config/opencode/opencode.json`
Expected: empty — back to clean state.

**Step 9: Commit**

```bash
cd ~/projects/workstation
git add users/dev/opencode-config.nix
git commit -m "opencode: inject aigateway baseURL based on systemd unit state

New home.activation.injectAigatewayBaseUrl on cloudbox. When
aigateway.service is enabled AND google_cloud_project sops secret
exists, writes provider.google-vertex-anthropic.options.baseURL into
opencode.json pointing at http://localhost:8080 with the project
baked into the URL path. Otherwise strips the override so opencode
falls back to direct Vertex.

URL path shape verified against the @ai-sdk/google-vertex SDK source
in opencode's bundled deps. SDK version + opencode commit comments
in the activation point at the verified-against versions.

Per design doc 2026-05-13-aigateway-opencode-integration-design.md.
opencode-serve auto-restart is added in the next commit."
```

---

### Task 5: Add hash-based opencode-serve auto-restart

**Files:**
- Modify: `users/dev/opencode-config.nix` — extend `injectAigatewayBaseUrl`.

**Step 1: Re-read what we have**

Run: `grep -A 60 'injectAigatewayBaseUrl' ~/projects/workstation/users/dev/opencode-config.nix | head -70`
Expected: the activation block from Task 4.

**Step 2: Extend the activation script**

Add hash file management at the top, capture the effective state into `new_hash` in both branches, and append the restart-on-change block before the closing `'');`. The full final shape:

Replace the existing block from `home.activation.injectAigatewayBaseUrl = lib.mkIf isCloudbox` through its closing `'');` with this expanded version:

```nix
  home.activation.injectAigatewayBaseUrl = lib.mkIf isCloudbox
    (lib.hm.dag.entryAfter [ "mergeOpencode" ] ''
      set -euo pipefail

      runtime="$HOME/.config/opencode/opencode.json"
      hash_file="$HOME/.cache/workstation/aigateway-url.hash"
      mkdir -p "$(dirname "$hash_file")"

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
        full_url="http://localhost:8080/v1/projects/$project/locations/global/publishers/anthropic/models"
        if [[ -f "$runtime" ]]; then
          tmp="$(mktemp "''${runtime}.tmp.XXXXXX")"
          ${pkgs.jq}/bin/jq --arg url "$full_url" \
            '.provider."google-vertex-anthropic".options.baseURL = $url' \
            "$runtime" > "$tmp"
          mv "$tmp" "$runtime"
        fi
        echo "aigateway: pointed opencode at $full_url" >&2
        new_hash="$(printf '%s' "$full_url" | ${pkgs.coreutils}/bin/sha256sum | ${pkgs.coreutils}/bin/cut -d' ' -f1)"
      fi

      # Auto-restart opencode-serve only when the effective URL changed.
      # Same sudo dance as installOpencodePlugins for the same reasons
      # (sudo path-sanitization, errexit-mask interactions): use absolute
      # paths to systemctl, capture exit code into a variable. Hash file
      # is updated ONLY after a successful restart so the next rebuild
      # retries on failure.
      old_hash=""
      [ -r "$hash_file" ] && old_hash="$(cat "$hash_file")"
      if [[ "$new_hash" != "$old_hash" ]]; then
        echo "aigateway: baseURL changed ($old_hash -> $new_hash); restarting opencode-serve" >&2
        sudo_err="$(mktemp)"
        sudo_rc=0
        /run/wrappers/bin/sudo -n /run/current-system/sw/bin/systemctl restart opencode-serve.service 2>"$sudo_err" || sudo_rc=$?
        if [ "$sudo_rc" -eq 0 ]; then
          echo "$new_hash" > "$hash_file"
          echo "aigateway: opencode-serve restarted; hash file updated" >&2
        else
          {
            echo "aigateway: WARNING — opencode-serve restart failed (sudo exit $sudo_rc):"
            ${pkgs.gnused}/bin/sed 's/^/  /' "$sudo_err"
            echo "aigateway: hash file NOT updated; next rebuild will retry"
          } >&2
        fi
        rm -f "$sudo_err"
      fi
    '');
```

(Note: replace the entire existing `injectAigatewayBaseUrl` from Task 4 with the above. Don't try to append.)

**Step 3: Apply (no state change yet — unit is disabled, hash file doesn't exist)**

Run: `nix run home-manager -- switch --flake ~/projects/workstation#cloudbox 2>&1 | tail -15`
Expected: log lines:
- `aigateway: aigateway.service is not enabled; opencode pointed at direct Vertex`
- `aigateway: baseURL changed ( -> DIRECT-VERTEX); restarting opencode-serve`
- `aigateway: opencode-serve restarted; hash file updated`

**Step 4: Verify hash file**

Run: `cat ~/.cache/workstation/aigateway-url.hash`
Expected: `DIRECT-VERTEX`

**Step 5: Verify opencode-serve is healthy after restart**

Run: `sleep 3 && curl -s http://127.0.0.1:4096/global/health`
Expected: a 200 JSON response.

**Step 6: Idempotence — run apply again with no changes**

Run: `nix run home-manager -- switch --flake ~/projects/workstation#cloudbox 2>&1 | tail -10`
Expected: log line `aigateway: aigateway.service is not enabled; opencode pointed at direct Vertex` is present, but **no** `baseURL changed` line and **no** `restarting opencode-serve` line.

Run: `cat ~/.cache/workstation/aigateway-url.hash`
Expected: still `DIRECT-VERTEX` (unchanged).

**Step 7: Exercise the change-detection — enable unit and re-apply**

Run: `sudo systemctl enable aigateway.service && nix run home-manager -- switch --flake ~/projects/workstation#cloudbox 2>&1 | tail -10`
Expected:
- `aigateway: pointed opencode at http://localhost:8080/...`
- `aigateway: baseURL changed (DIRECT-VERTEX -> <some-sha>); restarting opencode-serve`
- `aigateway: opencode-serve restarted; hash file updated`

Run: `cat ~/.cache/workstation/aigateway-url.hash`
Expected: a 64-char hex string (the SHA-256 of the full URL).

**Step 8: Idempotence again — apply with no state change**

Run: `nix run home-manager -- switch --flake ~/projects/workstation#cloudbox 2>&1 | tail -10`
Expected: log line `aigateway: pointed opencode at ...` is present, but no `baseURL changed` and no restart.

**Step 9: Disable the unit, re-apply, leave clean for Task 6**

Run: `sudo systemctl disable aigateway.service && nix run home-manager -- switch --flake ~/projects/workstation#cloudbox 2>&1 | tail -10`
Expected: `baseURL changed (<hash> -> DIRECT-VERTEX); restarting opencode-serve` in the log. Hash file back to `DIRECT-VERTEX`.

**Step 10: Commit**

```bash
cd ~/projects/workstation
git add users/dev/opencode-config.nix
git commit -m "opencode: auto-restart opencode-serve when aigateway URL changes

Hash the effective baseURL (or 'DIRECT-VERTEX' for the strip case),
compare against ~/.cache/workstation/aigateway-url.hash, only restart
opencode-serve when they differ. Same defensive sudo pattern as
installOpencodePlugins (absolute systemctl path, exit-code capture,
hash file updated only after successful restart so failures retry).

This makes \`nix run home-manager -- switch\` a complete operation —
flipping aigateway.service enable state and re-applying is enough; no
manual systemctl restart needed.

Per design doc 2026-05-13-aigateway-opencode-integration-design.md."
```

---

### Task 6: End-to-end verification with the gateway actually running

This task does not modify any files. It runs the full design-doc verification flow (Phases 1-3) to prove the integration works end-to-end with real Vertex traffic flowing through the real gateway and being recorded in the real ledger.

**Files:**
- Read-only.

**Step 1: Enable and start the gateway**

Run: `sudo systemctl enable --now aigateway.service`
Expected: clean. Note this is the first time the unit actually starts, so the Bazel build will run (~2 min on a clean cache).

**Step 2: Wait for the unit to settle and the gateway to be reachable**

Run:
```bash
echo "Waiting for aigateway..."
for i in $(seq 1 60); do
  if curl -fsS http://localhost:8080/actuator/health >/dev/null 2>&1; then
    echo "Up after ${i}s"
    break
  fi
  sleep 5
done
```
Expected: `Up after Ns` for some N. If it loops to 60 (5 minutes), check `journalctl -u aigateway.service --since='5 min ago'` and `docker compose -f ~/projects/mono/wonder/data/aigateway/dev/docker-compose.yml ps`.

**Step 3: Confirm health**

Run: `curl -s http://localhost:8080/actuator/health | jq '.status'`
Expected: `"UP"`. If `"DOWN"`, drill into per-component status with `curl -s http://localhost:8080/actuator/health | jq` to see which component (db/redis/r2dbc/etc.) is failing.

**Step 4: Re-apply home-manager so the activation runs against the now-enabled unit**

Run: `nix run home-manager -- switch --flake ~/projects/workstation#cloudbox 2>&1 | tail -10`
Expected: log line `aigateway: pointed opencode at http://localhost:8080/v1/projects/<project>/locations/global/publishers/anthropic/models`, followed by `baseURL changed ... restarting opencode-serve`.

**Step 5: Confirm `opencode.json` reflects the override**

Run: `jq -r '.provider."google-vertex-anthropic".options.baseURL' ~/.config/opencode/opencode.json`
Expected: the full localhost:8080 URL with project substituted.

**Step 6: Sanity check `opencode-serve` is up**

Run: `sleep 3 && curl -s http://127.0.0.1:4096/global/health | jq -r '.status // .'`
Expected: 200 / a healthy response.

**Step 7: Send a real prompt through opencode-serve**

Run:
```bash
opencode-launch ~/projects/workstation 'just say hello'
```

Note the session id. Wait ~10s for the model to respond. Check the session ran:

Run: `sleep 15 && curl -s "http://localhost:4096/session" | jq -r '.[] | select(.title // "" | contains("hello")) | .id' | head -1`
Expected: the session id you noted.

**Step 8: Verify the ledger captured the request**

Run:
```bash
PGPASSWORD=aigateway-local-dev psql -h localhost -U aigateway -d aigateway -c \
  "SELECT user_email, model, http_status, total_dollars, request_started_at \
   FROM gateway_request_log \
   WHERE request_started_at > now() - interval '5 minutes' \
   ORDER BY id DESC LIMIT 5"
```
Expected: at least one row from the last 5 minutes with:
- `user_email`: your gcloud-resolved identity
- `model`: `claude-opus-4-7@default` (or whatever your default is)
- `http_status`: 200
- `total_dollars`: a small non-null number

If empty: opencode bypassed the gateway. Re-check the `opencode.json` baseURL value (Step 5) and confirm `opencode-serve` actually restarted after the activation (Step 4).

If `http_status` is non-200 or `total_dollars` is null: drill into the gateway logs (`docker compose logs -f gateway` from `~/projects/mono/wonder/data/aigateway/dev/`).

**Step 9: Bypass test — disable the unit and re-apply**

Run: `sudo systemctl disable --now aigateway.service && nix run home-manager -- switch --flake ~/projects/workstation#cloudbox 2>&1 | tail -10`
Expected: log shows the strip + restart sequence.

**Step 10: Verify the override is gone**

Run: `jq '.provider // empty' ~/.config/opencode/opencode.json`
Expected: empty.

**Step 11: Send another prompt**

Run: `opencode-launch ~/projects/workstation 'just say goodbye'`

Wait, then verify the request did NOT appear in the ledger (the gateway is down anyway, so the proof that it bypassed is that opencode succeeded reaching Vertex directly).

Run: `sleep 15 && curl -s "http://localhost:4096/session" | jq -r '.[] | select(.title // "" | contains("goodbye")) | .id' | head -1`
Expected: a session id (proving opencode worked).

**Step 12: Re-enable for the operator's preferred default state**

Decide: do we want aigateway enabled by default after this work lands? The design says "disabled by default — operator opts in." Per that:

Run: `sudo systemctl status aigateway.service | head -3`
Expected: `disabled`. Leave it disabled. Operator can enable when ready.

If you want it enabled going forward (you do — this is the whole point of "default through the gateway"):

Run: `sudo systemctl enable --now aigateway.service && nix run home-manager -- switch --flake ~/projects/workstation#cloudbox 2>&1 | tail -5`
Expected: enabled, gateway starts, activation re-injects baseURL.

**Step 13: No commit (verification-only task). Move to Task 7.**

---

### Task 7: Push the chain to remote

**Files:**
- None (all commits already exist locally).

**Step 1: Confirm we have four new commits since `main` last pushed**

Run: `cd ~/projects/workstation && git log --oneline origin/main..HEAD`
Expected: four commits in this order (most recent first):
```
opencode: auto-restart opencode-serve when aigateway URL changes
opencode: inject aigateway baseURL based on systemd unit state
cloudbox: order opencode-serve after aigateway.service
cloudbox: add aigateway.service systemd unit (disabled)
```

If the order is wrong or there are extra commits, STOP and reconcile.

**Step 2: Pull just in case parallel sessions landed something**

Run: `cd ~/projects/workstation && git pull --rebase 2>&1 | tail -5`
Expected: `Already up to date` OR a clean rebase. If conflicts, resolve them per the standard workflow (the conflicts will most likely be in `users/dev/opencode-config.nix` if the Claude Code cleanup session also touched that file).

**Step 3: Push**

Run: `cd ~/projects/workstation && git push 2>&1 | tail -5`
Expected: `main -> main`.

**Step 4: Verify remote state**

Run: `cd ~/projects/workstation && git status`
Expected: `Your branch is up to date with 'origin/main'`.

**Step 5: No commit. Done.**

---

## Post-implementation checklist

- [ ] `aigateway.service` is enabled and running
- [ ] `opencode.json` has the gateway baseURL injected
- [ ] A real opencode session lands a row in `gateway_request_log`
- [ ] Disabling `aigateway.service` + `home-manager switch` cleanly bypasses
- [ ] All four commits are pushed to `origin/main`
- [ ] No new beads created (this scope was small enough not to need them)
- [ ] No org-identifying strings introduced (only `localhost:8080`, no project names except via the `/run/secrets/google_cloud_project` interpolation)

## Future work (deferred from this plan)

- **macOS branch.** Mirror `injectAigatewayBaseUrl` for `isDarwin`, reading the project ID from Keychain (`google-cloud-project` service, already populated). The systemd-unit-state trigger would translate to a launchd-equivalent toggle — we'll figure out the cleanest signal then.
- **Operator helpers.** `aigateway-health` (curl + jq + non-zero on DOWN) and `aigateway-ledger-tail` (psql wrapper). Add if writing the underlying commands by hand becomes friction.
- **Opencode-flavored volunteer doc.** Co-author with first-hand usage experience and contribute back to `mono/wonder/data/aigateway/`.
- **`us-east5` fallback fix in mono.** Tracked by parallel session `ses_1dda0e4b7ffehcS7pTijUkSLfd`; independent of this work.
