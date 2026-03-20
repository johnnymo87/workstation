# Anthropic Proxy Claude Code Parity Design

**Date:** 2026-03-20

## Goal

Repair the managed local Anthropic proxy so OpenCode's Anthropic OAuth flow again works on devbox and Crostini by matching the most relevant Claude Code v2.1.80 request-shaping behavior discovered in `ex-machina-co/opencode-anthropic-auth` PR `#13`.

## Problem

Our current managed proxy partially works: message traffic can still reach Anthropic, but OAuth exchange and refresh are failing with persistent `429` responses.

Fresh evidence from local logs and the later comments on `anomalyco/opencode#18267` suggests the break is no longer explained by a single global Claude Code `User-Agent` or billing marker alone. The strongest signal is `ex-machina-co/opencode-anthropic-auth` PR `#13`, which reports that Anthropic now expects different request shaping for different legs of the flow:

- OAuth authorize, exchange, and refresh moved from `console.anthropic.com` to `platform.claude.com`
- token exchange and refresh work with `User-Agent: axios/1.13.6`
- Anthropic API calls such as `/v1/messages` still want Claude Code style request shaping
- billing marker injection and Claude Code wording in system prompts still matter on message requests

Our current managed implementation still uses old `console.anthropic.com` URLs in the plugin path, keeps one global user-agent policy, uses older OAuth scopes, and does not deduplicate concurrent exchange calls. That likely explains why inference can still work while auth-path calls now fail.

## Chosen Approach

Keep the existing managed proxy/plugin architecture and port the relevant protocol behavior from PR `#13` into it.

This keeps the workaround under our control, preserves the Nix-managed service and docs, and avoids replacing the whole setup with a third-party package. We only adopt the parts that appear necessary for parity with current Anthropic expectations.

## Architecture

1. `assets/opencode/plugins/anthropic-oauth-proxy/plugin.ts` remains the OpenCode-facing auth shim.
2. `assets/opencode/plugins/anthropic-oauth-proxy/index.ts` remains the single request-shaping layer for Anthropic-bound traffic.
3. The proxy no longer treats all outbound requests the same. Instead it applies route-specific behavior:
   - `/oauth/exchange` and `/oauth/refresh` use `platform.claude.com` and `User-Agent: axios/1.13.6`
   - `/v1/messages` use `api.anthropic.com` and `User-Agent: claude-code/2.1.80`
4. Billing marker injection remains enabled only for `/v1/messages`.
5. System prompt text rewriting applies only on Anthropic message requests.
6. OAuth callback exchange is deduplicated in-memory so duplicate callbacks do not trigger multiple token exchanges.

## Scope

### In scope

- Migrating OAuth URLs and redirect URIs to `platform.claude.com`
- Updating OAuth scopes to the v2.1.80-compatible set reported in PR `#13`
- Splitting user-agent behavior by request class
- Adding exchange deduplication
- Updating billing/version defaults from `2.1.76` to `2.1.80`
- Rewriting `OpenCode`/`opencode` strings in Anthropic system prompt text blocks
- Updating tests, docs, and verification instructions for the new behavior

### Out of scope

- Replacing the managed proxy with the external `ex-machina-co` plugin
- Chasing every reverse-engineered Claude Code behavior not currently tied to our failures
- General provider routing changes outside Anthropic
- Automatic credential recovery or token-sync integrations from Claude Code

## Detailed Behavior

### OAuth authorize and callback

The plugin should generate authorize URLs using `platform.claude.com` for the console/Max path and use `https://platform.claude.com/oauth/code/callback` as the redirect URI.

The OAuth scope set should match the current PR `#13` findings:

`org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload`

### OAuth exchange and refresh

The local proxy must send exchange and refresh requests to `https://platform.claude.com/v1/oauth/token` with:

- `Content-Type: application/json`
- `User-Agent: axios/1.13.6`

The proxy should not reuse the Claude Code message-path user-agent here.

### Anthropic message requests

For `/v1/messages` and equivalent message traffic, the proxy should continue applying Claude Code style request shaping:

- `User-Agent: claude-code/2.1.80`
- required Anthropic beta headers
- billing marker as first `system` text block
- optional cache-marker stripping if enabled
- rewriting `OpenCode` -> `Claude Code` and `opencode` -> `Claude` in text system blocks only

### Exchange deduplication

OpenCode may invoke the callback more than once. We should guard the plugin's `exchange()` call so concurrent exchanges for the same code share one in-flight promise.

This is only an in-memory safety mechanism. It does not need persistence.

## Error Handling And Observability

The proxy should keep logging structured redacted summaries, but logs should make it obvious which outbound shaping policy was applied.

For auth-path debugging, the important observable fields are:

- request type (`exchange`, `refresh`, `messages`)
- upstream status
- selected user-agent policy
- whether billing injection was enabled
- whether cache stripping was enabled

Sensitive material must remain redacted.

## Risks

- Anthropic may change the accepted request shape again, so `2.1.80` parity may be temporary.
- Some late-thread claims come from community reverse engineering rather than official docs.
- Prompt rewriting may be unnecessary or incomplete, but it is a low-cost parity improvement and should stay scoped to Anthropic text system blocks.
- If the current refresh token is already effectively poisoned by repeated 429s, deployment alone may not recover the session without re-login.

## Success Criteria

- Proxy logs show `axios/1.13.6` for `/oauth/exchange` and `/oauth/refresh`
- Proxy logs show `claude-code/2.1.80` for `/v1/messages`
- `systemctl --user status anthropic-oauth-proxy.service --no-pager` shows the service running after deploy
- `opencode providers login` can complete the Anthropic flow without the previous exchange failure
- `opencode run "say hello in five words" --model anthropic/claude-opus-4-6` succeeds again without extra env vars

## Decision

Adopt a broader parity port inside the existing managed proxy/plugin instead of swapping to an external package. This keeps the workaround integrated with workstation while targeting the exact auth-flow gaps most likely causing the current `429` failures.
