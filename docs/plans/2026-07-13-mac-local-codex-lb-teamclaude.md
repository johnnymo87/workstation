# Mac-Local codex-lb + teamclaude Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Run codex-lb (ChatGPT/Codex rotator, `127.0.0.1:2455`) and teamclaude (Claude Max rotator, `127.0.0.1:3456`) as native macOS launchd services on the Mac, and route the Mac's opencode `openai`/`anthropic` providers through them when they're up — the darwin equivalent of the systemd-only setup that exists on devbox/cloudbox today.

**Architecture:** Both tools are currently systemd user services gated `isDevbox || isCloudbox` (`users/dev/codex-lb.nix`, `users/dev/home.devbox.nix`). macOS uses launchd, not systemd, so we add separate **launchd agents** in `users/dev/home.darwin.nix`, each gated behind a per-host runtime marker via a wrapper + `KeepAlive.SuccessfulExit = false`. opencode routing is ported to darwin as new `*Darwin` activation blocks in `users/dev/opencode-config.nix` that detect "is the proxy up" with a **loopback port probe** (`/usr/bin/nc -z`) instead of `systemctl --user is-active`, and — because the Mac runs an opencode **serve pool** (not a single unit) — follow codex-lb's "write config, do NOT auto-restart, print the apply command" discipline so we never kill live pool sessions.

**Tech Stack:** nix-darwin home-manager launchd agents, uv/uvx (codex-lb via PyPI pin `codex-lb==1.20.1`), `localPkgs.teamclaude` (Nix-packaged, `platforms = unix`), jq, macOS `/usr/bin/nc`.

**Key constraints discovered:**
- codex-lb's OAuth callback is pinned to `localhost:2455`; teamclaude login is a local PKCE+browser flow. Both bootstrap **locally on the Mac** — no SSH forward needed (unlike bootstrapping a remote host).
- Enabling routing changes the Mac's **primary** Claude/OpenAI path. It stays opt-in: the launchd agents only run once a marker exists, and routing auto-follows the port probe, reverting to direct providers when the proxy is down.
- `~/.codex-lb/` and `~/.config/teamclaude.json` are per-host runtime state (OAuth tokens that auto-refresh); never synced, lost on reprovision.

---

### Task 1: codex-lb launchd agent (darwin)

**Files:**
- Modify: `users/dev/home.darwin.nix` (add to `launchd.agents`)

**Step 1: Write the failing check**

Run:
```bash
rg 'codex-lb' users/dev/home.darwin.nix
```
Expected before implementation: no matches.

**Step 2: Add the agent**

Inside `launchd.agents = { … }` in `users/dev/home.darwin.nix`, add:

```nix
    # codex-lb (ChatGPT/Codex rotator) — darwin/launchd flavor of the systemd
    # unit in codex-lb.nix (which is NixOS-only). Opt-in per host: the wrapper
    # exits 0 when the marker is absent, and KeepAlive.SuccessfulExit=false means
    # launchd does NOT respawn a clean exit — so no marker => stays down; marker
    # present => runs, and a crash (non-zero) is restarted. Bootstrap:
    #   1. touch ~/.codex-lb/enabled
    #   2. launchctl kickstart -k gui/$(id -u)/org.nix-community.home.codex-lb
    #   3. open http://127.0.0.1:2455 and log in ChatGPT account(s)
    #   4. darwin-rebuild switch  (wires opencode via injectCodexLbBaseUrlDarwin)
    codex-lb = {
      enable = true;
      config = {
        ProgramArguments = [
          "/bin/sh" "-c"
          ''
            [ -e "$HOME/.codex-lb/enabled" ] || exit 0
            exec ${pkgs.uv}/bin/uvx --from codex-lb==1.20.1 codex-lb --host 127.0.0.1 --port 2455
          ''
        ];
        EnvironmentVariables = {
          HOME = config.home.homeDirectory;
          # bare launchd service has no CA bundle -> httpx CERTIFICATE_VERIFY_FAILED
          SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
          # uvx-generated wrapper shells out to realpath/dirname
          PATH = lib.concatStringsSep ":" [ "${pkgs.coreutils}/bin" "/usr/bin" "/bin" ];
        };
        RunAtLoad = true;
        KeepAlive = { SuccessfulExit = false; };
        StandardOutPath = "${config.home.homeDirectory}/Library/Logs/codex-lb.out.log";
        StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/codex-lb.err.log";
      };
    };
```

**Step 3: Eval check**

Run:
```bash
rg 'codex-lb|SuccessfulExit' users/dev/home.darwin.nix
nix eval --impure --expr 'builtins.seq (builtins.getFlake (toString ./.)).darwinConfigurations.Y0FMQX93RR-2.config.system.build.toplevel.drvPath "ok"'
```
Expected: matches present; eval prints `"ok"` (confirms `pkgs.uv` + `pkgs.cacert` resolve on aarch64-darwin).

**Step 4: Commit**

```bash
git add users/dev/home.darwin.nix
git commit -m "feat(darwin): add codex-lb launchd agent (opt-in via ~/.codex-lb/enabled)"
```

---

### Task 2: teamclaude package + launchd agent (darwin)

**Files:**
- Modify: `users/dev/home.darwin.nix` (add `localPkgs.teamclaude` to `home.packages`; add agent to `launchd.agents`)

**Step 1: Failing check**

Run:
```bash
rg 'teamclaude' users/dev/home.darwin.nix
```
Expected: no matches.

**Step 2: Add the package**

Add `localPkgs.teamclaude` to the `home.packages = [ … ]` list in `home.darwin.nix` (the CLI is needed for `teamclaude login` + `teamclaude accounts`). `pkgs/teamclaude/default.nix` is `platforms = lib.platforms.unix` with zero runtime deps, so it builds on aarch64-darwin.

**Step 3: Add the agent**

```nix
    # teamclaude (Claude Max rotator) — darwin/launchd flavor of the systemd unit
    # in home.devbox.nix. Same opt-in wrapper pattern as codex-lb. Marker is the
    # config file itself, created by interactive `teamclaude login`. Bootstrap:
    #   1. teamclaude login    # PKCE OAuth, needs TTY + browser; repeat per account
    #   2. launchctl kickstart -k gui/$(id -u)/org.nix-community.home.teamclaude
    #   3. darwin-rebuild switch  (wires opencode via injectTeamclaudeBaseUrlDarwin)
    teamclaude = {
      enable = true;
      config = {
        ProgramArguments = [
          "/bin/sh" "-c"
          ''
            [ -e "$HOME/.config/teamclaude.json" ] || exit 0
            exec ${localPkgs.teamclaude}/bin/teamclaude server --headless
          ''
        ];
        EnvironmentVariables = {
          HOME = config.home.homeDirectory;
          TEAMCLAUDE_CONFIG = "${config.home.homeDirectory}/.config/teamclaude.json";
          PATH = "/usr/bin:/bin";
        };
        RunAtLoad = true;
        KeepAlive = { SuccessfulExit = false; };
        StandardOutPath = "${config.home.homeDirectory}/Library/Logs/teamclaude.out.log";
        StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/teamclaude.err.log";
      };
    };
```

**Step 4: Eval check**

Run:
```bash
nix eval --impure --expr 'builtins.seq (builtins.getFlake (toString ./.)).darwinConfigurations.Y0FMQX93RR-2.config.system.build.toplevel.drvPath "ok"'
nix build --no-link .#homeConfigurations 2>/dev/null || true   # optional; teamclaude drv resolves via toplevel eval above
```
Expected: `"ok"`.

**Step 5: Commit**

```bash
git add users/dev/home.darwin.nix
git commit -m "feat(darwin): add teamclaude package + launchd agent"
```

---

### Task 3: opencode `openai` routing for codex-lb (darwin)

**Files:**
- Modify: `users/dev/opencode-config.nix` (add `injectCodexLbBaseUrlDarwin` activation)

**Context:** The existing `injectCodexLbBaseUrl` (line ~1255) is `lib.mkIf (isDevbox || isCloudbox)` and uses `systemctl --user is-active`. Add a sibling gated `lib.mkIf isDarwin`. Detection = loopback port probe. It reuses the exact same jq mutation (set/strip `.provider.openai.options.baseURL` + `apiKey`) and the same `.openai` deletion from `auth.json` (force apiKey mode so opencode doesn't send the user's own ChatGPT token). **No auto serve-restart** — the Mac runs a serve pool; print the apply command instead.

**Step 1: Failing check**

Run:
```bash
rg 'injectCodexLbBaseUrlDarwin' users/dev/opencode-config.nix
```
Expected: no matches.

**Step 2: Add the activation** (immediately after the existing `injectCodexLbBaseUrl` block)

```nix
  # Darwin flavor of injectCodexLbBaseUrl. No systemctl on macOS, so detect
  # "codex-lb is up" with a loopback port probe. No auto serve-restart: the Mac
  # runs an opencode-serve POOL, so we write config + clear the auth entry and
  # print the apply command; run `opencode-serve-pool-restart` to pick it up.
  home.activation.injectCodexLbBaseUrlDarwin = lib.mkIf isDarwin
    (lib.hm.dag.entryAfter [ "mergeOpencode" ] ''
      set -euo pipefail
      runtime="$HOME/.config/opencode/opencode.json"

      openai_url=""
      openai_key=""
      if /usr/bin/nc -z -G2 127.0.0.1 2455 2>/dev/null; then
        openai_url="http://127.0.0.1:2455/v1"
        openai_key="sk-codex-lb-local"
      fi

      if [[ -f "$runtime" ]]; then
        tmp="$(mktemp "''${runtime}.tmp.XXXXXX")"
        ${pkgs.jq}/bin/jq --arg u "$openai_url" --arg k "$openai_key" '
            (if $u == "" then del(.provider.openai.options.baseURL)
             else .provider.openai.options.baseURL = $u end)
          | (if $k == "" then del(.provider.openai.options.apiKey)
             else .provider.openai.options.apiKey = $k end)
          | (if (.provider.openai.options // {}) == {}
             then del(.provider.openai.options) else . end)
          | (if (.provider.openai // {}) == {}
             then del(.provider.openai) else . end)
          | (if (.provider // {}) == {} then del(.provider) else . end)' \
          "$runtime" > "$tmp"
        mv "$tmp" "$runtime"
      fi

      if [[ -n "$openai_url" ]]; then
        auth="$HOME/.local/share/opencode/auth.json"
        if [[ -f "$auth" ]] && ${pkgs.jq}/bin/jq -e '.openai' "$auth" >/dev/null 2>&1; then
          atmp="$(mktemp "''${auth}.tmp.XXXXXX")"
          ${pkgs.jq}/bin/jq 'del(.openai)' "$auth" > "$atmp"
          mv "$atmp" "$auth"; chmod 600 "$auth"
          echo "codex-lb(darwin): removed .openai from auth store (force apiKey mode)" >&2
        fi
      fi

      echo "codex-lb(darwin): openai -> ''${openai_url:-<direct OpenAI>}" >&2
      [[ -n "$openai_url" ]] && echo "codex-lb(darwin): run 'opencode-serve-pool-restart' to apply to running serves" >&2 || true
    '');
```

**Step 3: Eval check**

Run:
```bash
rg 'injectCodexLbBaseUrlDarwin' users/dev/opencode-config.nix
nix eval --impure --expr 'builtins.seq (builtins.getFlake (toString ./.)).darwinConfigurations.Y0FMQX93RR-2.config.system.build.toplevel.drvPath "ok"'
```
Expected: `"ok"`.

**Step 4: Commit**

```bash
git add users/dev/opencode-config.nix
git commit -m "feat(darwin): route opencode openai through local codex-lb when up"
```

---

### Task 4: opencode `anthropic` routing for teamclaude (darwin)

**Files:**
- Modify: `users/dev/opencode-config.nix` (add `injectTeamclaudeBaseUrlDarwin` activation)

**Context:** Port `injectTeamclaudeBaseUrl` (line ~1139, `lib.mkIf isDevbox`) to darwin. Detection = port probe on 3456. Reuse the same jq mutation for `.provider.anthropic.options.baseURL` AND the **dummy non-expiring oauth seed** into `auth.json` (keeps the `@ex-machina/opencode-anthropic-auth` plugin in shape-only mode; teamclaude owns the real tokens). Same pool discipline: no auto-restart, print the apply command. Note the dummy-cred shaping only takes effect after a serve reload, so the printed hint matters more here.

**Step 1: Failing check**

Run:
```bash
rg 'injectTeamclaudeBaseUrlDarwin' users/dev/opencode-config.nix
```
Expected: no matches.

**Step 2: Add the activation** (immediately after the existing `injectTeamclaudeBaseUrl` block)

```nix
  # Darwin flavor of injectTeamclaudeBaseUrl. Port-probe detection; dummy-cred
  # seed identical to the systemd path; no auto serve-restart (pool) — the dummy
  # cred's shape-only mode is decided at provider init, so a manual
  # `opencode-serve-pool-restart` is required to take effect.
  home.activation.injectTeamclaudeBaseUrlDarwin = lib.mkIf isDarwin
    (lib.hm.dag.entryAfter [ "mergeOpencode" ] ''
      set -euo pipefail
      runtime="$HOME/.config/opencode/opencode.json"

      anthropic_url=""
      if /usr/bin/nc -z -G2 127.0.0.1 3456 2>/dev/null; then
        anthropic_url="http://127.0.0.1:3456/v1"
      fi

      if [[ -f "$runtime" ]]; then
        tmp="$(mktemp "''${runtime}.tmp.XXXXXX")"
        ${pkgs.jq}/bin/jq --arg a "$anthropic_url" '
            (if $a == "" then del(.provider.anthropic.options.baseURL)
             else .provider.anthropic.options.baseURL = $a end)
          | (if (.provider.anthropic.options // {}) == {}
             then del(.provider.anthropic.options) else . end)
          | (if (.provider.anthropic // {}) == {}
             then del(.provider.anthropic) else . end)
          | (if (.provider // {}) == {} then del(.provider) else . end)' \
          "$runtime" > "$tmp"
        mv "$tmp" "$runtime"
      fi

      if [[ -n "$anthropic_url" ]]; then
        auth="$HOME/.local/share/opencode/auth.json"
        mkdir -p "$(dirname "$auth")"
        [[ -f "$auth" ]] || echo '{}' > "$auth"
        want="$(${pkgs.jq}/bin/jq -cnS '{type:"oauth",access:"teamclaude-managed-noop",refresh:"teamclaude-managed-noop",expires:4102444800000}')"
        have="$(${pkgs.jq}/bin/jq -cS '.anthropic // empty' "$auth" 2>/dev/null || true)"
        if [[ "$have" != "$want" ]]; then
          atmp="$(mktemp "''${auth}.tmp.XXXXXX")"
          ${pkgs.jq}/bin/jq '.anthropic = {type:"oauth",access:"teamclaude-managed-noop",refresh:"teamclaude-managed-noop",expires:4102444800000}' \
            "$auth" > "$atmp"
          mv "$atmp" "$auth"; chmod 600 "$auth"
          echo "teamclaude(darwin): seeded non-expiring dummy anthropic oauth credential (plugin shape-only)" >&2
        fi
      fi

      echo "teamclaude(darwin): anthropic -> ''${anthropic_url:-<direct Anthropic>}" >&2
      [[ -n "$anthropic_url" ]] && echo "teamclaude(darwin): run 'opencode-serve-pool-restart' to apply to running serves" >&2 || true
    '');
```

**Step 3: Eval check**

Run:
```bash
rg 'injectTeamclaudeBaseUrlDarwin' users/dev/opencode-config.nix
nix eval --impure --expr 'builtins.seq (builtins.getFlake (toString ./.)).darwinConfigurations.Y0FMQX93RR-2.config.system.build.toplevel.drvPath "ok"'
```
Expected: `"ok"`.

**Step 4: Commit**

```bash
git add users/dev/opencode-config.nix
git commit -m "feat(darwin): route opencode anthropic through local teamclaude when up"
```

---

### Task 5: Apply + interactive bootstrap + verify

**These steps are interactive (OAuth in a browser / TTY) and cannot be fully automated.**

**Step 1: Apply the config (agents installed, still dormant — no markers yet)**

```bash
sudo darwin-rebuild switch --flake .#Y0FMQX93RR-2
launchctl print "gui/$(id -u)/org.nix-community.home.codex-lb"   | rg 'state|program'
launchctl print "gui/$(id -u)/org.nix-community.home.teamclaude" | rg 'state|program'
```
Expected: both agents loaded; codex-lb/teamclaude NOT listening yet (`/usr/bin/nc -z 127.0.0.1 2455` and `:3456` both refuse) because markers are absent.

**Step 2: Bootstrap codex-lb**

> **CRITICAL — the 1455 OAuth-callback conflict (validated live 2026-07-13).**
> codex-lb's login callback is hardcoded to `http://localhost:1455/auth/callback`
> (the OpenAI Codex CLI's registered redirect URI — NOT configurable). codex-lb
> opens `:1455` only *during* a login. But the always-on `devbox-dev-tunnel`
> LaunchAgent owns `LocalForward 1455` (`scripts/update-ssh-config.sh:58`), so
> Mac:1455 is pinned to devbox and the local codex-lb cannot bind it. You MUST
> free Mac:1455 for the duration of the login:
> ```bash
> U=$(id -u)
> # 1. free Mac:1455 (bootout so KeepAlive doesn't respawn). This drops devbox
> #    clipboard (gclpr 2850) + CDP forwards for the login window — Mac-local
> #    sessions are unaffected.
> launchctl bootout "gui/$U/org.nix-community.home.devbox-dev-tunnel"
> nc -z -G2 127.0.0.1 1455 || echo "1455 freed"
> # 2. ... do the codex-lb login below ...
> # 3. AFTER login completes, restore the devbox tunnel:
> launchctl bootstrap "gui/$U" ~/Library/LaunchAgents/org.nix-community.home.devbox-dev-tunnel.plist
> #    (verify clipboard: printf x | pbcopy && ssh devbox gclpr paste)
> ```
> Permanent alternative (decide with the user): drop `LocalForward 1455` from the
> `devbox-tunnel` block in `scripts/update-ssh-config.sh` if devbox's opencode
> ChatGPT OAuth forward is no longer needed, so Mac:1455 stays free for the local
> codex-lb. Not done by default — it removes a devbox capability.

```bash
touch ~/.codex-lb/enabled
launchctl kickstart -k "gui/$(id -u)/org.nix-community.home.codex-lb"
# wait for listener, then grab the first-run dashboard token from the log:
rg -A3 'bootstrap token' ~/Library/Logs/codex-lb.err.log
# open http://127.0.0.1:2455 locally, enter the token, log in ChatGPT account(s).
# The callback to localhost:1455 now reaches the LOCAL codex-lb (devbox tunnel booted out).
```
Verify: `curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:2455/` → `200`. Then restore the devbox tunnel (see box above).

**Step 3: Bootstrap teamclaude**

```bash
teamclaude login      # repeat per Claude Max account; needs TTY + browser
teamclaude accounts   # verify accounts present
launchctl kickstart -k "gui/$(id -u)/org.nix-community.home.teamclaude"
```
Verify: `/usr/bin/nc -z 127.0.0.1 3456 && echo up`.

**Step 4: Wire opencode routing + apply to the pool**

```bash
sudo darwin-rebuild switch --flake .#Y0FMQX93RR-2   # activations detect ports up, rewrite opencode.json + auth.json
rg 'baseURL' ~/.config/opencode/opencode.json        # expect 127.0.0.1:2455/v1 and :3456/v1
opencode-serve-pool-restart                          # apply to running serves (disrupts live sessions — do when idle)
```

**Step 5: End-to-end verify**

- In opencode, select a sol/terra/luna (codex-lb) model and confirm a completion succeeds.
- Confirm an anthropic (opus/sonnet) turn succeeds and codex-lb/teamclaude logs show the request.
- Rollback check: `launchctl kill SIGTERM gui/$(id -u)/org.nix-community.home.codex-lb` (or remove the marker), `darwin-rebuild switch`, confirm `baseURL` override is stripped and opencode falls back to direct.

---

### Notes / open considerations for the implementer
- **`pkgs.uv` on aarch64-darwin**: the Task 1/2 `nix eval … drvPath` confirms it resolves. If uv is unexpectedly unavailable, fall back to installing uv via `home.packages` and referencing `${config.home.homeDirectory}/.nix-profile/bin/uvx`.
- **macOS `nc -G`**: `-G` is the connection timeout (seconds) on the BSD/macOS `nc`; `-z` is scan mode. Both are supported by `/usr/bin/nc` on macOS.
- **Serve pool restart is disruptive.** Unlike devbox's single `opencode-serve.service`, the Mac pool restart kills in-flight sessions. Always do Step 4's `opencode-serve-pool-restart` when idle.
- **Per-host accounts.** These logins are independent from cloudbox/devbox; tokens live in `~/.codex-lb/` and `~/.config/teamclaude.json` on the Mac only.
- **Optional docs**: consider a short note in the codex-lb.nix header pointing to the darwin agents, and/or a `.opencode/skills` entry, once verified.
