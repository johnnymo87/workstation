# Anthropic OAuth Proxy Design

**Date:** 2026-03-19

## Goal

Add a local Anthropic-only proxy layer that lets `opencode-cached` keep its existing caching fork clean while giving us a controlled place to add observability and Claude Code request-shape emulation for OAuth traffic.

## Problem

Recent Anthropic OAuth breakage appears to depend on more than prompt shape alone. Evidence from `anomalyco/opencode#17910`, `anomalyco/opencode#18267`, and the HCPTangHY comment suggests Anthropic now checks additional Claude Code fingerprinting details such as `User-Agent` and a salt-derived billing marker. Separately, the `/api/oauth/usage` endpoint appears to apply different behavior based on `User-Agent`, producing persistent `429` responses for non-Claude-Code callers.

At the same time, upstream `anomalyco/opencode` is moving away from Anthropic OAuth support rather than toward a repair. As of 2026-03-19, issues `#17910`, `#18267`, and `#18265` are open, while merged PR `#18186` removes the built-in Anthropic OAuth plugin path and related Anthropic-specific support. This makes a local workaround path more realistic than waiting for an official upstream fix.

Patching these behaviors directly into `opencode-cached` would mix auth-specific work into a fork whose main purpose is prompt caching, and every upstream release would make the patch harder to maintain.

## Chosen Approach

Use a small local proxy for Anthropic OAuth requests, with staged feature flags and structured logging.

The proxy will sit between OpenCode and Anthropic only for the affected Anthropic paths. It will start in observability mode, then allow selective request mutations so we can confirm which changes actually affect behavior.

## Architecture

1. `opencode-cached` runs with the built-in Anthropic auth plugin disabled and a local replacement plugin enabled.
2. The replacement plugin handles Anthropic OAuth auth/loading and routes Anthropic traffic to a local proxy endpoint.
3. The proxy forwards requests to Anthropic using the stored OAuth credentials or forwarded bearer auth as configured.
4. The proxy records structured diagnostics for:
   - usage endpoint calls
   - token refresh calls
   - message/inference calls
5. Feature flags enable request mutations one at a time:
   - Claude Code `User-Agent`
   - optional billing/salt marker injection
   - optional stripping of Anthropic cache markers for OAuth traffic
6. Logs show which toggles were active for each request so we can correlate behavior changes.

## Integration Point

The preferred integration point is not `opencode-cached` patching. Current OpenCode versions still support:

- disabling built-in plugins with `OPENCODE_DISABLE_DEFAULT_PLUGINS=true`
- loading a local plugin via `opencode.json`
- provider-specific `baseURL` overrides

That means we can replace the built-in `opencode-anthropic-auth` behavior locally and keep the workaround outside the `opencode-cached` patch stack.

## Scope

### In scope

- Anthropic OAuth request proxying
- Local Anthropic replacement auth plugin
- Local observability and diagnostics
- Runtime flags for staged experiments
- Minimal configuration needed for local use

### Out of scope

- Reworking `opencode-cached` caching behavior
- General-purpose provider proxying for all models
- Upstreaming changes to `anomalyco/opencode`
- Attempting to fully replicate every Claude Code behavior before evidence requires it

## Proxy Behavior

### Phase 1: Observability only

Log request class, upstream path, response status, refresh attempts, and active feature flags without modifying payloads except what is required to route traffic.

### Phase 2: Low-risk mutation

Override `User-Agent` with a Claude Code style value on usage, refresh, and inference paths.

### Phase 3: Higher-signal experiments

Add a billing/salt-style marker and optionally strip Anthropic cache markers from OAuth requests. These remain independently toggleable so we can isolate cause and effect.

## Observability Design

Each proxied request should emit a compact structured log record containing:

- request type (`usage`, `refresh`, `messages`)
- upstream path
- timestamp
- response status
- error summary if present
- whether `User-Agent` override was enabled
- whether billing marker injection was enabled
- whether cache-marker stripping was enabled

Sensitive tokens must never be logged. If request bodies need inspection, logs should record only safe derived facts such as the presence of `cache_control`, not the full prompt.

## Configuration

The proxy should be controlled through simple env vars or a tiny config file:

- proxy listen address
- upstream Anthropic base URL
- `User-Agent` override on/off
- billing marker injection on/off
- cache-marker stripping on/off
- log level

This keeps experimentation reversible and avoids rebuilding the binary for each attempt.

## Risks

- Anthropic may validate additional request fields later, so the first proxy iteration may not fully restore functionality.
- Some requests may still originate from code paths that are hard to redirect without a small local routing tweak.
- The billing/salt behavior is inferred from community evidence rather than official documentation, so it must be treated as experimental.

## Success Criteria

- We can observe and distinguish usage, refresh, and inference failures locally.
- We can toggle request-shape changes without modifying `opencode-cached` patches each time.
- We confirm whether `User-Agent` alone fixes the `/api/oauth/usage` `429` behavior.
- We confirm whether inference-path failures change when billing/salt and cache-marker toggles are enabled.

## Decision

Prefer a proxy-centered solution over expanding `opencode-cached` patches, because it isolates Anthropic-specific churn and gives us a better debugging surface.
