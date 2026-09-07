# Retiring `claude_personal_oauth_token` (and the chromebook sops remnants)

Status: **CLOSED 2026-09-07.** devbox done (#452, #462); chromebook remnants and
the inert creation rules fixed (#474); cloudbox deferred by the user; credential
exposure closed on the user's confirmation that no one holds the chromebook key.
Beads: `workstation-bs9g`, `workstation-s0ln`, `workstation-pg8f` — all closed.

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

## Work items (historical — see Status above for disposition)

### A. cloudbox side of the token (`workstation-bs9g`) — DEFERRED by user

Left as-is on the user's call ("don't worry about cloudbox"). The table below
is what would need doing if that changes. cloudbox still declares and exports it:

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

### B. Revoke at the source (`workstation-bs9g`) — DEFERRED with A

Removing the secret from sops is **not revocation**. The credential is still
valid at Anthropic and the old ciphertext is in git history forever. Since A is
deferred, so is this: revoking first would break cloudbox to tidy devbox.

### C. chromebook `.sops.yaml` remnants (`workstation-s0ln`) — DONE, PR #474

Removed the `&chromebook` anchor and its `creation_rule`. Verified first that
the key was never a recipient of a surviving file (`git log --all -S'age14hkwan'`
is empty), so no ciphertext changed and no `updatekeys` was needed.

Two things fell out of it that were bigger than the task:

**Every creation_rule in `.sops.yaml` was inert.** sops strips the config file's
own directory before matching `path_regex`. The config lives in `secrets/`, so
the matched string is `devbox.yaml`, and the rules were anchored
`secrets/devbox\.yaml$`. They matched nothing from the day they were written;
`sops updatekeys` had always failed with `no matching creation rules found`, and
the files were created by passing `--age` on the CLI instead. Fixed by dropping
the prefix. **If you edit that file, re-verify with the command in its header
comment** — a rule that matches nothing fails silently and looks fine.

**A credential exposure, tracked separately as `workstation-pg8f` (P1).** See
below; it is not fixed by anything in section C.

### D. Rotate credentials leaked via chromebook history (`workstation-pg8f`) — CLOSED, no rotation

`secrets/chromebook.yaml` is gone from the tree but lives in this **public**
repo's history, encrypted to devbox + chromebook. Four of its values are still
byte-identical to live devbox secrets: `ccr_api_key`, `telegram_bot_token`,
`dolthub_jwk`, `dolthub_api_token`.

Anyone with the chromebook age private key can read them out of public history,
permanently. age has no revocation and rewriting public history does not help.
Resolved on the user's confirmation that no one holds the chromebook key. With
no holder, ciphertext in history is unreadable, so nothing was rotated. If that
ever turns out to be wrong, this section is the rotation list.

Generalise the lesson: **deleting a secrets file does not delete the secret**,
and neither does removing a recipient. Only rotation at the provider does.
`secrets/README.md` now says so.

## Sequencing

All closed or deferred; nothing owed. See Status at the top.

## Upstream thread (informational, no action owed)

`ex-machina-co/opencode-anthropic-auth#229` adds a `CLAUDE_CODE_VERSION` env
override. Tested against a live gated model (bundled forced to `2.1.87`: unset →
400, override → 200, garbage → graceful fallback). Left two review notes:
the variable squats Anthropic's own `CLAUDE_CODE_*` namespace, and a
valid-format *downgrade* passes silently. If merged, it would let us set the
version declaratively instead of chasing pins.
