---
name: setting-up-wiz-mcp
description: Use when authenticating OpenCode to Wiz's hosted MCP server (mcp.app.wiz.io) for the first time on a host, re-authenticating after a revoked or expired grant, checking what the Wiz MCP can and cannot do (read-only claims, OAuth scopes), or debugging `opencode mcp auth wiz`.
---

# Setting Up Wiz MCP

## Overview

Wiz (cloud and code security) hosts an MCP server at `https://mcp.app.wiz.io/`.
OpenCode's remote MCP type handles its OAuth natively: Wiz supports RFC 7591
dynamic client registration and PKCE, so there is no client id, no token in
sops or Keychain, and no `mcp-remote` shim. The user signs in once with their
own Wiz login, and the grant can see exactly what that user can see in the
Wiz console.

The entry in `assets/opencode/opencode.base.json` is `enabled: false`, like
every MCP server here. Grant it per session (`oc-mcp-enable <ses> wiz`, or
`opencode-launch --mcp wiz`). goose cannot use it yet: honkd lists remote
servers as unsupported.

## The scope you get is not the scope you ask for

Wiz's protected-resource metadata advertises three scopes:

```
read:all  create:penetration_test_findings  offline_access
```

OpenCode (MCP SDK >= 1.2x, SEP-835) picks the requested scope in this order:
the `scope` in the server's `WWW-Authenticate` header, then the metadata's
`scopes_supported`, then the user's `oauth.scope` from config. Wiz's 401 carries
no `scope`, so the request is **all three**, and an `oauth.scope` in
`opencode.json` is silently ignored. Verified 2026-11-04 in the bundled code of
opencode-patched 1.18.18.5 (`n=e||t?.scopes_supported?.join(" ")||o.scope`).

So do not describe the grant as read-only on the strength of config. What
keeps it read-only in practice is the **tool list** the server exposes: check
it after auth (Verification below). If a tool that creates or changes anything
in Wiz appears, it needs a decision before anyone grants `wiz` to an
unattended session: `oc-mcp-enable` appends a session-level `wiz_*` allow,
which overrides a config-level `tools`/`permission` deny of that one tool.

## Auth on a headless host (cloudbox, devbox)

The callback is `http://127.0.0.1:19876/mcp/oauth/callback`, served by the
`opencode mcp auth` process for **5 minutes** (`CALLBACK_TIMEOUT_MS`). The
browser that consents is on the Mac, so forward the port first. The
`setting-up-notion-mcp` skill covers this dance in detail (mosh does not
forward ports; the "missing state parameter" log line is harmless).

1. On the Mac, in a fresh OpenSSH window (not mosh):

   ```bash
   ssh -L 19876:127.0.0.1:19876 <host>
   ```

2. In that window, on the host:

   ```bash
   opencode mcp auth wiz
   ```

   Open the printed `https://mcp.app.wiz.io/oauth2/authorize?...` URL in the
   Mac browser where you are signed in to Wiz, read the consent screen, approve.
   The process exits with `saved oauth tokens`.

3. Close the forward.

**Before the home-manager switch lands** (a PR not merged yet), the CLI can
still see the entry from a project-level config. Run step 2 from a scratch
directory:

```bash
d=$(mktemp -d) && cd "$d"
printf '%s\n' '{"mcp":{"wiz":{"type":"remote","url":"https://mcp.app.wiz.io/","enabled":true}}}' > opencode.json
opencode mcp auth wiz
```

Tokens are stored by server name in `~/.local/share/opencode/mcp-auth.json`,
not per directory, so the grant carries over once the real entry exists.

## Verification

```bash
opencode mcp auth list      # wiz: authenticated
opencode mcp debug wiz      # a 401 probe line, then a successful connection
```

Then list the tools and read them before granting `wiz` anywhere:

```bash
d=$(mktemp -d) && cd "$d"
printf '%s\n' '{"mcp":{"wiz":{"type":"remote","url":"https://mcp.app.wiz.io/","enabled":true}}}' > opencode.json
opencode run "List every tool whose name starts with wiz_, with its one-line description. Do not call any of them."
```

A running serve picks up a new `mcp.wiz` entry only after it restarts (the
nightly `reset-workspace`, or by hand). Until then `oc-mcp-enable` reports
`wiz` as not configured.

## Gemini-tier agents

Not yet tested. Run the one-liner in the `opencode-agents` skill ("Testing a
new MCP server against Gemini") after auth; if it fails, add `wiz*: false` to
the Gemini-tier agents.

## Revoking

`opencode mcp logout wiz` removes the local tokens. The registration and
grant on Wiz's side are the Wiz tenant admins' to revoke.
