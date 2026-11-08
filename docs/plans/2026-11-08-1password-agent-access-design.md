# 1Password for agents: the vault is the boundary, op-fill keeps values out of transcripts

Date: 2026-11-08. Status: **proposed, awaiting owner decisions** (see
"Decisions for the owner"). The draft was revised after an adversarial review,
which added the dedicated booking browser, top-level-origin binding for cards,
the context-bound fill sequence, a fill-and-submit step, and corrected audit
claims. Nothing is installed or configured.

## Goal and non-goals

Goal: an opencode session on the Mac fills a small, owner-chosen set of
1Password items (a payment card, a few travel and loyalty logins, their TOTPs)
into a browser it drives over CDP, **while the owner is away from the Mac**.
Secret values never appear in tool output, the model's context, or `opencode.db`.

Non-goals:
- General vault access, or any vault browsing by agents.
- Fills initiated from cloudbox or devbox. The token, the helper and the booking
  browser all stay on the Mac and are never forwarded (§3).
- A defence against an agent that deliberately goes around the helper. On a
  single-UID Mac that cannot be built (next section).

## What prompted it

On 2026-11-08 an agent booked a hotel via CDP. `op` was not installed and the
owner was remote, so he pasted his Hilton password and card details into two
Google Docs, which the agent read via `gws` on devbox. Those values now sit in
Google Docs, in `/tmp` files and in session transcripts. Owner setup step 0
cleans that up whatever is decided here.

## The fact the design rests on

Agents on the Mac run as the owner's UID with unrestricted bash. Anything a
helper can read, the agent can too:
- A Keychain item created by `security add-generic-password` trusts
  `/usr/bin/security`, so `security find-generic-password -s <svc> -w` returns
  it silently. The login keychain is `no-timeout` here, so this works while the
  owner is away.
- `ps eww` shows the environment of same-user processes.
- A Keychain ACL pinned to the helper binary would prompt on the Mac's GUI, and
  the binary's hash changes on every nix rebuild.
- A separate macOS user to run a broker would need local admin, which this Mac
  doesn't have.

So **the blast radius is whatever the token can read.** The helper's controls
(origin binding, no-print, logging, approval) defend against the accidental
leak and against a cooperative agent that a page has steered. That is the
realistic prompt-injection case. They cannot stop an agent that decides to go
around the helper, so the vault's contents must be survivable if an agent reads
all of them. That is why **a capped, merchant-locked virtual card** is the most
valuable single control in this design.

## Options

| Option | Auth / headless while away | Blast radius | Audit | Verdict |
|---|---|---|---|---|
| **A. Service account, read-only, dedicated vault** | `OP_SERVICE_ACCOUNT_TOKEN` authenticates straight to 1Password's API, with no desktop app, Touch ID or unlock. Works headless. | One custom vault, `read_items` only (permissions are immutable after creation). | Our local log, plus a rate-limit counter (`op service-account ratelimit`) to reconcile against it. Usage reports and the Activity Log appear to be Business-only. | **Recommended** |
| B. `op` + desktop-app integration | Touch ID per authorisation. Fails exactly when the owner is away. | Entire account once unlocked. | Desktop only. | Rejected: wrong availability, maximal scope. |
| C. 1Password Connect | Connect token plus two always-on containers. | Vault-scoped, like A. | Like A. | Rejected: needs a Docker engine running on a laptop, for no gain over A. |
| D. A 1Password MCP server | The official one (desktop-app Environments MCP) deliberately never returns secret values. Community ones (`op-mcp` and others) wrap `op` and **return raw values into the LLM context**. | Whatever their token reaches. | None of their own. | Rejected: the official one cannot do the job by design; the community ones defeat goal 3 by construction. |
| E. Drive the 1Password browser extension via CDP | The extension locks with the app; unlocking needs Touch ID or the master password. Its UI is closed shadow DOM and brittle to automate. | The **whole** personal vault, offered to any page the agent visits. | None. | Rejected: largest blast radius, and it fails while locked. |
| F. 1Password "Secure Agentic Autofill" (Browserbase) | The extension fills without exposing values, which is the right shape. But each request needs **human approval on a device within about 2 minutes**, and it targets Browserbase-hosted browsers. | Approval-gated per item. | 1Password-side. | Not now: it fails "while away", and support for a local Chrome over CDP is unconfirmed. Revisit if it gains standing grants for a local browser. |

Verified against developer.1password.com on 2026-11-08:
- Service accounts exist on Individual, Families, Teams and Business.
- They cannot access the built-in Personal, Private or Employee vault or the
  default Shared vault, so the items must be in a **custom** vault.
- Individual and Families limits are 1,000 reads/hour per token and 1,000
  requests/24h per account. `op read` by *name* costs about 3 requests, and by
  ID it costs 1.

Rows D–F rest on secondary research and may be dated.

## Design

### 1. The vault: `Agent`, a custom vault, read-only to one service account

- The owner creates a custom vault `Agent` and **moves** the chosen items into
  it. Moving keeps one copy to rotate, and he still sees the items everywhere.
  Copies diverge silently at the next password change.
- Contents: **a virtual card** (issuer virtual number or a Privacy.com-style
  card with a monthly cap, ideally merchant-locked or single-use per booking),
  plus the travel and loyalty logins with TOTPs. It holds no email, bank or
  primary card.
- Before moving each login, **prune its website URLs** to the exact hosts where
  it should be filled. Old items accumulate stray URLs (SSO hosts, old domains),
  and each URL becomes a fill target (§3).
- Service account `opencode-mac-agent`: `--vault Agent:read_items`, no vault
  creation, `--expires-in 90d`.

### 2. The token: Keychain, read at call time, never mirrored or exported

- Keychain generic password, service `op-agent-service-account-token`, account
  `$USER`, following the existing convention.
- Unlike the MCP tokens, there is **no `keychainMirror` into
  `~/.config/opencode/secrets/`** and **no shell-init export**
  (`users/dev/home.darwin.nix:1379` onward exports `GH_TOKEN` and others). The
  token is never in any agent's environment or in a file.
- `op-fill` reads it at fill time. Its preferred path is the **1Password Python
  SDK in-process**, so there is no `op` child, no token in a child's
  environment, and no `op` binary in the closure for an agent to find. The
  fallback is `_1password-cli` (unfree; `allowUnfree` is already set in
  `flake.nix`) as a private dependency, run with an allowlisted environment
  (dropping `OP_CONNECT_*`, which overrides the token, and the proxy variables).
- Reads are one field at a time, by vault and item **ID**. It never runs
  `item get --format json`, which pulls every field including the TOTP seed.

### 3. A dedicated booking browser, never forwarded

Today 9222 is the owner's main Chrome profile, and `scripts/update-ssh-config.sh:56`
reverse-forwards it to devbox, cloudbox and cloudbox-tunnel. The remote end
binds to loopback, which still lets any process on two internet-facing hosts
drive it. The repo already removed the 9223 forward for exactly this reason
(`update-ssh-config.sh:57-63`). Putting filled cards and loyalty sessions in
that browser would hand them to every remote agent, as live session cookies
(`Network.getAllCookies`) and as DOM values. It would also let a remote client
navigate the tab in the middle of a fill.

So:
- A separate Chrome profile `Chrome-Booking` on **port 9224**, launched on demand
  by a script modelled on `assets/gcloud-reauth/chrome.sh` (the 9223 launcher),
  **never** added to any `RemoteForward`. In that profile the password manager,
  card autofill and sync are off.
- `op-fill` connects only to 9224 and refuses any other port.
- The skill tells booking sessions to drive 9224 with op-fill's own commands or
  raw CDP, **not** `chrome-devtools-mcp`. Its uid model needs post-fill
  snapshots, which show card numbers unmasked, and its network tools capture
  POST bodies.

(Whether 9222 should still be forwarded at all is a separate question for the
owner, outside this design. See the decisions list.)

### 4. `op-fill`

```
op-fill list                                         # titles, field labels, allowed hosts: metadata only
op-fill fill   --tab <targetId> --selector '<css>' op://Agent/<item>/<field>  [--then-click '<css>']
op-fill submit --tab <targetId> --selector '<css>'   # click without the agent needing a snapshot
```

The `fill` sequence fails closed at every step:
1. **Fetch the value first** (the network round trip), before touching the page.
2. Attach to the tab on 9224 with `Target.setAutoAttach` (flatten), so
   cross-site payment iframes become reachable sessions.
3. In an **isolated world**, resolve the selector to an `objectId`. The selector
   is passed as an argument and never interpolated into JS.
4. Get origins from the browser (`Page.getFrameTree` `securityOrigin`), not from
   URLs. Require https and refuse opaque or `null` origins.
   - **Login:** the frame origin's host and the top-level host must both be
     **exact** matches to a URL host on the item, and every intermediate
     ancestor frame must be same-site. There is no override flag.
   - **Card:** the **top-level** host must be in the item's owner-written
     `agent_allowed_hosts` field, and every ancestor frame must match too. The
     frame holding the input may be any https origin, because a processor
     iframe (Stripe, Adyen) is normal. Binding on the frame origin would let any
     merchant on the same processor pass. With no allowlist entry, the fill
     needs the v2 approval, or is refused in v1.
5. In **one** `Runtime.callFunctionOn` on that objectId: re-check that it is
   connected, focus it, and assert that `document.activeElement === el` and
   that `document.hasFocus()` is true. If the frame navigated, its context is
   gone, the call fails, and op-fill aborts.
6. Call `Input.insertText` (it takes no target; it goes to the focused element,
   which is why step 5 asserts focus). Then post-check on the same objectId that
   the value length grew by exactly n. If not, it aborts loudly, logs, and
   **does not retry**, because a partial insert into a `maxlength` field or a
   split card input must not be retried blindly.
7. `--then-click` / `submit`: click by selector through the same
   resolve-and-check path, so the agent never needs to snapshot a filled form.
8. Output only `filled <field label> (<n> chars) into <selector> on <top host>`.
   There is no read, no `--print`, and no value-returning mode. Errors are
   scrubbed to one line with values redacted.
9. Append JSON to `~/Library/Logs/op-fill.log`: timestamp, `OPENCODE_SESSION_ID`,
   ref, top and frame origins, selector, result. The value is never logged.

Language: Python, because the 1Password SDK is available for it, packaged like
the repo's other Python tools.

What op-fill cannot prevent, written into the skill as rules:
- The value lives in the DOM after a fill. Any `.value` evaluation, DOM
  snapshot, or screenshot of an unmasked field reads it back. Rule: after a
  fill, interact only through op-fill until the page has navigated away from
  the form, **including after a failed submit**.
- A same-origin XSS on an allowed host gets what the extension would give it.

### 5. Per-session opt-in and the approval gate

- **Soft gate (v1).** Base opencode config denies bash `op-fill *`, `op *` and
  `security *op-agent*`. A session gets `op-fill` through a session permission
  rule. `oc-mcp-enable` already PATCHes `{permission, pattern, action}`
  (`pkgs/oc-mcp-enable/default.nix:86-94`). Extend it to grant
  `{permission:"bash", pattern:"op-fill *", action:"allow"}`, and add
  `--allow-op-fill` to `opencode-launch`. This stops accidents and is not a
  boundary: bash patterns are trivially bypassed.
- **Approval (v2; needs pigeon work; may be unnecessary).** For card fills
  without an allowlist entry, op-fill asks pigeon to send a Telegram
  Approve/Deny message. Pigeon has the pieces (inline keyboard and
  `callback_query`: `notification-service.ts:290-360`, `webhook.ts:1500-1534`)
  but no standalone request/approve primitive. Requirements:
  - The message shows the **top-level host** prominently and **no page title**,
    since the attacker controls the title.
  - One approval per item bundle (all card fields at once), so the owner isn't
    trained into tapping Approve.
  - The approval binds to (tab, frame, top host, item, field set), is valid for
    60 seconds, and is **re-validated after approval**.
  - op-fill returns at once with `pending <id>`, and a second call completes the
    fill. This keeps the wait under the bash tool's 120 s timeout.
  - `ALLOWED_USER_IDS` must be set on the worker, because it is optional
    (`webhook.ts:124`).

  Build it only if merchant-locked single-use cards plus the issuer's own push
  notifications turn out to be insufficient.

### 6. Where it lives

- `pkgs/op-fill/`: added to `home.packages` under `lib.optionals isDarwin`.
- The booking-browser launcher, next to `assets/gcloud-reauth/chrome.sh`.
- Skill `assets/opencode/skills/using-1password-agent-vault/SKILL.md`: owner
  setup, §3 and §4 rules, `op-fill list`, and cleanup. It needs a **new
  macOS-only bucket** in `users/dev/opencode-skills.nix`
  (`lib.optionalAttrs isDarwin`, beside `workOnlySkills` at :66-80), because
  none exists today. Add a row in the global AGENTS.md skills table.
- Deny rules in `assets/opencode/opencode.base.json`.

### 7. Threat model

| Threat | Control | Residual |
|---|---|---|
| A prompt-injected page or email steers a fill to an attacker site | Exact-host binding (logins), top-level allowlist (cards), virtual-card cap and merchant lock | XSS on an allowed host; capped spend |
| Injection makes the agent exfiltrate via bash (`security … -w`, then the SDK or `op`) | Deny rules (soft); no `op` on PATH; read-only token; survivable vault contents | **Real.** A complying agent can read all of `Agent`. Bounded by the vault's contents and the card cap. Detected only by reconciling the rate-limit counter with `op-fill.log`. |
| A remote host (cloudbox, devbox) or a co-tenant agent drives the booking browser | 9224 is never forwarded; op-fill refuses other ports | A local same-UID process |
| Navigation or focus change between check and insert | Value fetched first; check, focus and assert in one context-bound call; post-check | Sub-millisecond window between steps 5 and 6 |
| A value leaks into Slack, a PR, `bd` or `opencode.db` | No value in op-fill output; no chrome-devtools MCP on 9224; no post-fill snapshots | An agent that breaks the rule |
| Token theft | Keychain only, no file or export, SDK in-process, 90-day expiry, read-only | Same-UID read; revoke on 1Password.com |
| Rate limits (1,000/day per account) | ID-based single-field reads | Low |

## Owner setup (only the owner can do these)

0. **Clean up today's residue.** Delete the two Google Docs (and empty them from
   Drive trash). Rotate the Hilton password. Treat that card as exposed: replace
   it or watch it. Remove the `/tmp` copies on whichever host holds them.
   Whether to delete that session's transcript is your call.
1. Confirm **which 1Password account** holds these items (personal or employer)
   and that service accounts are allowed there. On Business, an admin may have
   to grant "create service accounts".
2. Get a capped, ideally merchant-locked, virtual card.
3. Create the custom vault `Agent`. Prune each login's URLs, then move the
   chosen logins and the virtual card into it. Add `agent_allowed_hosts` to the
   card if v1 should fill cards (one host per line, e.g. `www.hilton.com`).
4. Create the service account on 1Password.com (Developer → Service accounts):
   `opencode-mac-agent`, vault `Agent`, **read items only**, no vault creation,
   90-day expiry. Save the token in **your own** vault, not `Agent`.
5. Store it on the Mac **yourself**:
   `security add-generic-password -a "$USER" -s op-agent-service-account-token -w`
   (it prompts for the value, so it stays out of shell history).
6. Add a calendar reminder for token rotation.

## Implementation plan (after approval)

1. `pkgs/op-fill`: `list`, `fill`, `submit`, with the §4 sequence. Tests: a
   local fixture page served on two origins, with a cross-origin iframe, a
   mid-fill navigation, a focus-stealing handler and a `maxlength` field, and the
   SDK stubbed. One live test against a dummy item in `Agent`.
2. Booking-browser launcher for 9224, and a check that no `RemoteForward` names
   9224.
3. Darwin wiring: the package, no Keychain mirror, no export.
4. Deny rules; `oc-mcp-enable` bash-pattern grant; `opencode-launch
   --allow-op-fill`.
5. Skill plus the darwin-only skill bucket; AGENTS.md row.
6. Verification: `nix flake check --keep-going`, `home-switch`, an end-to-end
   fill and submit of a dummy login, then grep the session's `opencode.db` rows
   for the dummy value and expect no hits.
7. (v2, only if needed) the pigeon approval endpoint, in a separate PR.

## Decisions for the owner

1. Which 1Password account, and are service accounts allowed on it?
2. Virtual card (recommended) or the real card?
3. Card fills in v1 through `agent_allowed_hosts`, or logins only until v2?
4. Which items go in `Agent`?
5. Separately: 9222, your main Chrome profile, is reverse-forwarded to devbox
   and cloudbox today. Keep the forward, or narrow it?
