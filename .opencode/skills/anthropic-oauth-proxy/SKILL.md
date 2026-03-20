---
name: anthropic-oauth-proxy
description: Use when OpenCode on devbox or Crostini needs Anthropic OAuth to work through the local workaround, or when verifying, restarting, or debugging the managed proxy and plugin integration.
---

# Anthropic OAuth Proxy

This workaround keeps Anthropic OAuth support working on devbox and Crostini by routing Anthropic auth and message traffic through a local proxy and a managed OpenCode plugin with route-specific Claude Code parity behavior.

## Quick Reference

| Task | Command | Notes |
|------|---------|-------|
| Apply config changes | `home-manager switch --flake .#dev` | User-level only |
| Check proxy service | `systemctl --user status anthropic-oauth-proxy.service` | Managed on devbox and Crostini |
| Restart proxy service | `systemctl --user restart anthropic-oauth-proxy.service` | Picks up code/config changes |
| Follow proxy logs | `journalctl --user -u anthropic-oauth-proxy.service -f` | Check `/oauth/exchange`, `/oauth/refresh`, and `/v1/messages` separately |
| Check health | `python - <<'PY'` ... `http://127.0.0.1:4318/health` | Returns `{"ok":true}` |
| Verify Anthropic works | `opencode run "say hello in five words" --model anthropic/claude-opus-4-6` | Plain `opencode` should work |

## Where It Lives

Managed files are split across `workstation` like this:

- `assets/opencode/plugins/anthropic-oauth-proxy/` - plugin and proxy source deployed to the machine
- `users/dev/opencode-config.nix` - adds the managed OpenCode plugin entry
- `users/dev/anthropic-oauth-proxy.nix` - installs the launcher script and `anthropic-oauth-proxy.service`

The plugin is added to `~/.config/opencode/opencode.managed.json` during Home Manager activation, then merged into the runtime `~/.config/opencode/opencode.json`.

## Proven-Good Mode

The currently verified configuration on devbox is:

- OAuth exchange/refresh `User-Agent`: `axios/1.13.6`
- message-path `User-Agent`: `claude-code/2.1.80`
- OAuth endpoints: `platform.claude.com`
- billing header injection: on
- cache marker stripping: off

That is the default service configuration. Use cache stripping only as a troubleshooting experiment, not the default path.

## How It Works

1. OpenCode loads the managed plugin from `~/.config/opencode/plugins/anthropic-oauth-proxy/plugin.ts`
2. The plugin handles Anthropic OAuth login, exchange, refresh, and request rerouting
3. The local proxy listens on `127.0.0.1:4318`
4. The proxy sends `/oauth/exchange` and `/oauth/refresh` to `platform.claude.com` with `User-Agent: axios/1.13.6`
5. The proxy sends Anthropic message traffic with `User-Agent: claude-code/2.1.80`, billing injection, and system prompt rewriting
6. The managed user service keeps the proxy running on devbox and Crostini

## Verification Workflow

After changing the proxy code or its Nix wiring:

```bash
cd ~/projects/workstation
home-manager switch --flake .#dev    # devbox (.#livia for Crostini)
systemctl --user restart anthropic-oauth-proxy.service
systemctl --user status anthropic-oauth-proxy.service --no-pager
journalctl --user -u anthropic-oauth-proxy.service --no-pager -n 50
opencode run "say hello in five words" --model anthropic/claude-opus-4-6
```

Expected:

- service is `active (running)`
- logs show `axios/1.13.6` on `/oauth/exchange` and `/oauth/refresh`
- logs show `claude-code/2.1.80` on `/v1/messages`
- `opencode` succeeds without extra env vars

## Troubleshooting

### `opencode` fails on Anthropic again

Check the proxy logs first:

```bash
journalctl --user -u anthropic-oauth-proxy.service -f
```

Look for whether the failure is in:

- OAuth exchange
- token refresh
- message request shape

For current parity mode, verify that:

- `/oauth/exchange` and `/oauth/refresh` are hitting `platform.claude.com`
- those auth-path calls show `user-agent: axios/1.13.6`
- `/v1/messages` shows `user-agent: claude-code/2.1.80`

### Service is not running

```bash
systemctl --user status anthropic-oauth-proxy.service --no-pager
systemctl --user restart anthropic-oauth-proxy.service
```

If it still fails, verify the source files exist under `assets/opencode/plugins/anthropic-oauth-proxy/` and re-apply Home Manager.

### Anthropic login needs to be repeated

Use plain OpenCode login:

```bash
opencode auth login
```

Choose:

- `Anthropic`
- `Claude Pro/Max`

The managed plugin should handle the code exchange through the proxy.
