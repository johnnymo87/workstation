---
name: setting-up-notion-mcp
description: Use when authenticating OpenCode to Notion's hosted MCP server for the first time on a host, re-authenticating after token revocation, or debugging a stuck OAuth callback during `opencode mcp auth notion`.
---

# Setting Up Notion MCP

## Overview

Notion exposes a hosted MCP endpoint at `https://mcp.notion.com/mcp` that supports OAuth. OpenCode's remote MCP type handles the OAuth flow natively via `opencode mcp auth notion` — no static integration token, no `mcp-remote` shim, no Keychain/sops plumbing on our side.

The catch: OAuth's redirect-URI callback is `http://127.0.0.1:19876/mcp/oauth/callback`, served by a temporary listener inside the `opencode mcp auth` process itself. On a headless host (devbox over SSH), the browser that consents lives on your Mac, so the Mac's port 19876 needs to forward to devbox's port 19876 for the callback to land.

## When to Use

- First-time auth for `notion` MCP on any host (devbox, cloudbox, macOS, crostini)
- Re-authenticating after token revocation or scope change
- Debugging "stuck on Waiting for authorization" or "Connection refused" during the OAuth dance

## Prerequisites

The `notion` entry must already be in `assets/opencode/opencode.base.json`:

```json
"notion": {
  "type": "remote",
  "url": "https://mcp.notion.com/mcp",
  "enabled": false
}
```

After editing that file: `nix run home-manager -- switch --flake .#<host>`. The merge activation script writes it through to `~/.config/opencode/opencode.json`.

`enabled: false` is intentional — toggle the MCP on per-session via `/mcp` in the TUI; otherwise it adds tool-noise and context cost to every session.

## Auth on a Headless Host (devbox)

The full sequence:

1. **From your Mac**, open a parallel `ssh` window dedicated to the OAuth callback forward:

   ```bash
   ssh -L 19876:127.0.0.1:19876 devbox
   ```

   Leave it idle. Don't try to add the forward to an existing mosh session — mosh doesn't honor port forwards or `~C` escape sequences. A fresh OpenSSH connection is the simplest path.

2. **On devbox**, start the auth flow:

   ```bash
   opencode mcp auth notion
   ```

   It will print:
   - `WARN ... failed to open browser, user must open URL manually` — **harmless on headless devbox**, expected. `xdg-open` has nothing to drive.
   - A `https://mcp.notion.com/authorize?...` URL — copy this to your Mac browser.

3. **In your Mac browser**, paste the URL. Notion shows a workspace + page picker. Pick what OpenCode should access. Click through Notion's two confirmation steps.

4. **Watch devbox**. The auth process exits with `saved oauth tokens` once the callback lands. Tokens go to OpenCode's auth state (managed by OpenCode, not by us — no sops, no Keychain involvement).

5. **Restart `opencode-serve`** so already-running TUI sessions see the new MCP:

   ```bash
   sudo systemctl restart opencode-serve.service
   ```

6. **Tear down** the SSH-L window. You only need it for re-auth.

## Auth on macOS

Single command:

```bash
opencode mcp auth notion
```

A real browser is local; `xdg-open`/`open` works; the `127.0.0.1:19876` callback goes to local opencode directly. No port forwarding.

## Verification

```bash
opencode mcp auth list           # notion should show ✓ authenticated
opencode mcp debug notion         # check auth + connection round-trip
```

`mcp debug` will print one `HTTP 401 Unauthorized` line followed by `Connection successful (already authenticated)`. The 401 is a bare probe without the bearer header; the second line is the real test. Both lines appearing means it's working.

## How OpenCode's OAuth Callback Works

`opencode mcp auth <name>` does several things in order, per the source in `packages/opencode/src/mcp/oauth-callback.ts`:

1. Binds an HTTP listener on `127.0.0.1:19876` (the port is hardcoded as `OAUTH_CALLBACK_PORT`).
2. Generates `state` and `code_challenge` (PKCE), prints the auth URL.
3. Tries `xdg-open` / `open` to launch a browser; if that fails, just keeps polling.
4. Browser consents → Notion redirects to `http://127.0.0.1:19876/mcp/oauth/callback?code=...&state=...`.
5. Listener validates `state`, exchanges `code` for tokens via PKCE, persists tokens, exits.

The listener exists **only while `opencode mcp auth` is running**. If you `Ctrl+C` or `timeout`-kill the process mid-flow, the listener dies and the next callback hits a closed port — leaving the browser tab sitting on `Connection refused`. Re-running `opencode mcp auth notion` mints a fresh URL and a fresh listener; old URLs become invalid.

## Common Mistakes

- **Killing the auth process for "taking too long".** It's polling for the callback; that's normal. It only exits on success or a hard cancel. Open the URL on your Mac, then it completes within ~1 second of consent.

- **Trying to add the SSH forward to a mosh session.** Mosh transports keystrokes over UDP and never speaks SSH's port-forwarding protocol. `~C` won't intercept. Use a parallel `ssh -L ...` window instead.

- **Confusing the first "missing state parameter" callback for a real failure.** Notion's consent flow can issue an interstitial `GET /callback` with no params before the real redirect. The auth-callback code logs `ERROR ... oauth callback missing state parameter` for it. The genuine callback (`hasCode=true state=<state>`) follows seconds later. Both lines appearing in the log is the success pattern, not a failure.

- **Forgetting to restart `opencode-serve`.** The systemd-managed serve daemon caches the parsed `opencode.json` and the MCP client list at startup. Adding a new MCP entry — even after `home-manager switch` rewrites `opencode.json` — won't be visible to active sessions until `sudo systemctl restart opencode-serve.service`. Symptom: `/mcp` in TUI shows the old list.

- **Pointing the callback at the wrong port.** `19876` is hardcoded in OpenCode 1.14.x. There's no config knob (see `anomalyco/opencode#18955`, `#23787`). If a future version adds `oauth.callbackPort`, the SSH `-L` forward must follow.

## Token Refresh

Notion access tokens expire in 1 hour. OpenCode persists a refresh token alongside and silently refreshes when it sees a 401. No user action needed unless the refresh token is itself revoked (Notion side: workspace owner removes the connection, or you `opencode mcp logout notion` deliberately). After revocation, repeat the full setup flow.

## Related

- `assets/opencode/opencode.base.json` — the `mcp.notion` entry
- `users/dev/opencode-config.nix` — `mergeOpencode` activation that writes `~/.config/opencode/opencode.json`
- `clipboard` skill — also covers Mac↔devbox bridging over SSH/mosh
- `troubleshooting-nixos-host` skill — for deeper SSH session weirdness
