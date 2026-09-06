# Retiring `claude_personal_oauth_token` (and the chromebook sops remnants)

Status: **devbox done, cloudbox + revocation outstanding**
Beads: `workstation-bs9g` (token), `workstation-s0ln` (chromebook `.sops.yaml`)

## Why this exists

A day of work started from "oracle-fable and adversarial-reviewer-fable return
empty" and ended in the secret store. The chain, because it is not obvious from
any single commit:

1. Anthropic gates model access on the Claude Code version the client reports,
   server-side. `@ex-machina/opencode-anthropic-auth` hardcoded `2.1.87`;
   `claude-fable-5-1` requires `>= 2.1.251`. The 400 surfaces in opencode as an
   **empty assistant turn** with no visible error — the error lands only in the
   `message` row in `opencode.db`.
2. Fixed by pinning the plugin to upstream 1.8.2 (#462 lineage: #447 local
   patch → #451 replace with pin).
3. While verifying, `CLAUDE_CODE_OAUTH_TOKEN` turned up in every bash tool call.
   Investigating *why* showed nothing consumed it: the plugin has zero
   references to it, teamclaude has zero, eternal-machinery has zero. The only
   consumer was an undeclared `npm i -g @anthropic-ai/claude-code`.
4. Removed on devbox (#452 consumers + declaration, #462 ciphertext),
   uninstalled the npm global.

## Load-bearing facts (verified, do not re-derive)

- **The billing header beats the user-agent.** The version reaches Anthropic
  twice: the `user-agent` header, and `cc_version` inside the billing header the
  plugin injects as `system[0]`. The server prefers the latter. Measured: with
  the bundled constant at `2.1.87`, patching *only* `USER_AGENT` still 400s and
  the error still quotes `2.1.87`. This is why a proxy-level rewrite (teamclaude
  only sees headers) cannot fix it.
- **devbox's nightly pool restart works.** `nightly-restart-background.timer`
  → `reset-workspace` → restarts `opencode-serve-pool.target`, 03:00 daily. It
  is a **system** timer, so `systemctl --user list-timers` does not show it.
  Consequence: a plugin/config change lands on disk at switch time and goes live
  within a day without intervention.
- **No auto serve-restart from activation on devbox**, by policy (see
  `injectCodexLbBaseUrl` and, since #451, `installOpencodePlugins` and
  `injectTeamclaudeBaseUrl`). The pool is templated units; restarting the target
  kills every live session including the one running the switch.
- **`sops unset` is the removal tool**, not decrypt/`yq`/re-encrypt. Preserves
  recipients, no plaintext to `/tmp`. See the `managing-secrets` skill (#463).
- **cloudbox is not reachable from devbox.** `ssh cloudbox` fails to resolve.
  Nothing in this plan may assume otherwise.

## Remaining work

### A. cloudbox side of the token (`workstation-bs9g`)

cloudbox still declares and exports it:

| site | what |
|---|---|
| `hosts/cloudbox/configuration.nix:191` | sops-nix declaration |
| `hosts/cloudbox/configuration.nix:1086` | export in a service wrapper |
| `users/dev/home.cloudbox.nix:367` | `~/.bashrc` export |
| `secrets/cloudbox.yaml` | the ciphertext |
| `assets/opencode/plugins/shell-env.ts` | shared mapping, annotated, currently inert on devbox |

**Blocked on a question devbox cannot answer:** is there a consumer on cloudbox?
Run *there*:

```bash
command -v claude
ls ~/.npm-global/lib/node_modules/@anthropic-ai 2>/dev/null
grep -rn CLAUDE_CODE_OAUTH_TOKEN ~/projects --include='*.ts' --include='*.sh' --include='*.nix' 2>/dev/null | grep -v node_modules
```

If nothing: mirror #452 + #462 for cloudbox, then delete the `shell-env.ts` row
(it is the last consumer of the mapping once both hosts are clean).

Note cloudbox routes Anthropic through Vertex/aigateway, not teamclaude, so the
devbox "plugin is shape-only" argument does **not** transfer. Verify on its own
terms.

### B. Revoke at the source (`workstation-bs9g`)

Removing the secret from sops is **not revocation**. The credential is still
valid at Anthropic and the old ciphertext is in git history forever. Once A is
settled, revoke it. Do not revoke first — cloudbox may still be using it.

### C. chromebook `.sops.yaml` remnants (`workstation-s0ln`)

`secrets/chromebook.yaml` is already deleted, but `secrets/.sops.yaml` still has
the `&chromebook` key anchor and a `creation_rule` for the missing file. Dead
config that actively misled: it is why the `managing-secrets` skill cited
chromebook as the multi-recipient example until #463 corrected it to cloudbox.

`hosts/devbox/configuration.nix` and `hosts/cloudbox/configuration.nix` also
mention chromebook — **read before deleting**, some may be legitimate.

## Sequencing

C is independent and safe to do from devbox alone. A is blocked on cloudbox
access. B is blocked on A. So: **C first, then A when cloudbox is reachable,
then B.**

## Upstream thread (informational, no action owed)

`ex-machina-co/opencode-anthropic-auth#229` adds a `CLAUDE_CODE_VERSION` env
override. Tested against a live gated model (bundled forced to `2.1.87`: unset →
400, override → 200, garbage → graceful fallback). Left two review notes:
the variable squats Anthropic's own `CLAUDE_CODE_*` namespace, and a
valid-format *downgrade* passes silently. If merged, it would let us set the
version declaratively instead of chasing pins.
