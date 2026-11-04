---
name: setting-up-wiz-mcp
description: Use when authenticating OpenCode to Wiz's hosted MCP server (mcp.app.wiz.io) for the first time on a host, re-authenticating after a revoked or expired grant, checking what the Wiz MCP can and cannot do (read-only claims, OAuth scopes, tool list), granting it to a session, or debugging `opencode mcp auth wiz`.
---

# Setting Up Wiz MCP

## Overview

Wiz (cloud and code security) hosts an MCP server at `https://mcp.app.wiz.io/`.
OpenCode's remote MCP type handles its OAuth natively: Wiz advertises RFC 7591
dynamic client registration and PKCE (S256), so there is no client id, no token
in sops or Keychain, and no `mcp-remote` shim. The user is expected to sign in
with their own Wiz login, so the grant should see what that user sees in the
Wiz console. Whether a tenant admin has to enable the MCP integration before an
ordinary user can consent is not yet known.

Two config entries in `assets/opencode/opencode.base.json`:

- `mcp.wiz`: `enabled: false`, like every MCP server here.
- `tools: {"wiz_*": false}`: a config-level deny, as for `slack_*`. Without it,
  once one session connects `wiz`, **every** session in that directory on that
  serve (and their Task subagents) can call its tools, because MCP connections
  are per directory and the base permission is `"*": "allow"`. With it, only a
  session granted by `oc-mcp-enable <ses> wiz` (or `opencode-launch --mcp wiz`)
  can, since that appends a session-level `wiz_*` allow that wins.

Consequence: turning `wiz` on from the TUI's MCP dialog alone shows no tools.
Run `oc-mcp-enable` for that session as well.

goose cannot use it yet: honkd lists remote servers as unsupported. When it can,
`wiz` is not in `--mcp-no-confirm`, so it will need `wiz!`.

## The scope you get is not the scope you ask for

Wiz's protected-resource metadata advertises three scopes:

```
read:all  create:penetration_test_findings  offline_access
```

OpenCode (MCP SDK 1.27+, SEP-835) picks the requested scope in this order: the
`scope` in the server's `WWW-Authenticate` header, then the metadata's
`scopes_supported`, then the user's `oauth.scope` from config. Wiz's 401 carries
no `scope`, so the request is **all three**, and an `oauth.scope` in
`opencode.json` is silently ignored. Verified 2026-11-04 in the bundled code of
opencode-patched 1.18.18.5 (`n=e||t?.scopes_supported?.join(" ")||o.scope`).

So do not call the grant read-only on the strength of config. Two things
decide what it can do, and both are checked by `inspect-wiz-mcp.sh` (below):

1. **The tool list.** A tool that creates or changes anything in Wiz needs a
   guard that `oc-mcp-enable` cannot override (a config deny of one tool loses
   to the session `wiz_*` allow). Options: a `tool.execute.before` plugin with
   an allowlist, or a trailing per-tool deny that `oc-mcp-enable` appends for
   `wiz`.
2. **The token's audience.** The tokens sit in
   `~/.local/share/opencode/mcp-auth.json`, which any agent with bash can read.
   If the token is accepted by Wiz's API as well as the MCP host, the write
   scope is reachable with curl whatever the tools are. The SDK sends an
   RFC 8707 `resource`, so the token is probably bound to the MCP host; confirm
   it from the `aud` claim.

## Auth on a headless host (cloudbox, devbox)

The callback is `http://127.0.0.1:19876/mcp/oauth/callback`, served by the
`opencode mcp auth` process for **5 minutes** (`CALLBACK_TIMEOUT_MS`). The
browser that consents is on the Mac, so forward the port first. The
`setting-up-notion-mcp` skill covers this in detail (mosh does not forward
ports; a "missing state parameter" log line is harmless).

1. On the Mac, in a fresh OpenSSH window (not mosh):

   ```bash
   ssh -L 19876:127.0.0.1:19876 <host>
   ```

2. In that window, on the host:

   ```bash
   opencode mcp auth wiz
   ```

   Open the printed `https://mcp.app.wiz.io/oauth2/authorize?...` URL in the
   Mac browser where you are signed in to Wiz, read the consent screen, and
   approve. The process should exit reporting saved tokens.

3. Close the forward.

**Before the home-manager switch lands** (PR not merged yet), the CLI still
sees the entry from a project-level config. Run step 2 from a scratch
directory:

```bash
d=$(mktemp -d) && cd "$d"
printf '%s\n' '{"mcp":{"wiz":{"type":"remote","url":"https://mcp.app.wiz.io/","enabled":true}}}' > opencode.json
opencode mcp auth wiz
```

Tokens are stored by server name in `~/.local/share/opencode/mcp-auth.json`,
not per directory, so the grant carries over once the real entry exists.

Any CLI command that connects (`opencode mcp list` included) registers an OAuth
client with Wiz the first time (`clientInfo` appears in `mcp-auth.json`). That
is a record on Wiz's side, not tenant data.

## Verification

```bash
opencode mcp auth list                                # wiz: authenticated
.agents/skills/setting-up-wiz-mcp/inspect-wiz-mcp.sh  # scope, aud, tools
```

The script calls only MCP `initialize` and `tools/list`, prints tool names with
their `annotations` (`readOnlyHint`, `destructiveHint`), and never prints the
token. Do not check the tool list by asking a model with the tools live:
nothing but the prompt would stop it calling one.

A running serve sees a new `mcp.wiz` entry only after it restarts (the nightly
`reset-workspace`, or by hand). Until then `oc-mcp-enable` reports `wiz` as not
configured.

## Gemini-tier agents

Not yet tested. Run the one-liner in the `opencode-agents` skill ("Testing a
new MCP server against Gemini") after auth. If it fails, add `wiz*: false` to
the Gemini-tier agents.

## Revoking

`opencode mcp logout wiz` removes the local tokens. The client registration and
grant on Wiz's side are for the Wiz tenant admins to revoke.
