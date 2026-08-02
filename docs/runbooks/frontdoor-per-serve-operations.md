# Runbook — operations that must address individual serves

**Audience: a human operator on the host.** Everything here is a procedure the front door
deliberately refuses to perform, because performing it correctly requires addressing
individual pool members and the door cannot do that safely on a caller's behalf.

This file exists so the **door's denial bodies do not have to carry these recipes**. A
denial body is read by automated consumers, agents, and TUIs; anything printed there
becomes an instruction they can follow. The door therefore names the constraint and points
here, and the port-level detail lives in the repo where it can be reviewed and changed.

> The pool's addresses are deliberately not repeated in prose below. Read them from the
> deployed configuration (`FRONTDOOR_POOL_URLS` in `hosts/cloudbox/configuration.nix`,
> derived from `endpointsCsv` in `users/dev/serve-pool.nix`), so this runbook cannot drift
> from the actual pool the way a hardcoded list would.

## 1. Writing a provider credential (`PUT|DELETE /auth/{providerID}`, `POST /provider/{providerID}/oauth/*`)

`auth.json` is **shared** by every member and has **no lock**, and each member caches the
credential in RAM after it boots.

1. Send the write to **exactly ONE** member, with credentials.
   Do **not** send it to all of them: concurrent whole-document writes to a shared
   unlocked file can silently lose an update.
2. Then force every member to re-read the file, by posting `/global/dispose` to each.

**Step 2 is disruptive.** `/global/dispose` cancels every in-flight run on that member, for
every directory, and SIGTERMs its stdio MCP children. Expect a cold-boot latency spike
afterwards. Do it in a quiet window.

The server password is at the path given by the `opencode_server_password` sops secret
(see `.opencode/skills/managing-secrets/SKILL.md`); read it from that file rather than
pasting it into a shell history.

## 2. MCP OAuth (`POST|DELETE /mcp/{name}/auth`, `.../auth/authenticate`, `.../auth/callback`)

MCP OAuth state is pinned to **one process** by a module-level map keyed by MCP name, so
the whole flow must complete against a **single member**.

**Before you start, confirm no stray `opencode` process already owns `127.0.0.1:19876`.**
The callback listener binds that fixed port and, if it is taken, **returns success without
binding**. The browser redirect then lands in the wrong process, and the authenticate call
blocks until it times out (~5 minutes) and fails. That silence is the failure mode worth
guarding against, not the OAuth flow itself.

Prefer the session-scoped route through the door
(`POST /session/{sessionID}/mcp/{name}/connect`) for ordinary MCP *connects* — the door
resolves the owner and no direct addressing is needed. Only the **auth** routes above
require this per-member procedure.

## 3. Disposing an instance (`POST /instance/dispose`)

**Do not "pick a serve and call dispose".** The caller cannot know which member holds the
instance, and hitting a member that does not hold it **cold-boots it and then destroys
nothing** — the exact inversion of the request. The instance-context middleware loads the
instance before the handler runs, and the load is not cancelled when the door gives up at
its first-byte timeout.

Disposal is **per-member and per-directory**. To invalidate everywhere, post
`/global/dispose` to every member, accepting that it cancels in-flight runs (see §1).

## 4. The web UI

The web UI is not proxied. Open a member's address directly in a browser. This is an
interactive human action, which is why it is a runbook entry and not a denial-body hint.

---

**If you are an automated consumer that ended up here from an error message: stop.** The
door denied your request because it cannot be performed correctly through the door, not
because there is a port you should have used instead. Adding a direct-to-member call to
shipped code requires an exemption row in
`docs/plans/2026-07-26-phase9-consumer-disposition.md` and will otherwise fail the opacity
guard in CI (see `AGENTS.md`, "front-door opacity").
