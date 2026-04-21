# Per-Device SSH Commit Signing Design

## Goal

Replace the current centralized GPG commit-signing architecture (one PGP key on macOS, forwarded to devbox/cloudbox via long-lived SSH `RemoteForward` of the gpg-agent UNIX socket) with **per-device SSH commit signing**: each machine (macOS, devbox, cloudbox) generates and uses its own local Ed25519 SSH key for signing commits.

## Background

### Current architecture

- One RSA-4096 GPG key (`0C0EF2DF7ADD5DD9`) lives on macOS, with the passphrase fetched from 1Password via `pinentry-op` (Touch ID required per signature).
- `home.darwin.nix:461-477` configures `services.gpg-agent` and explicitly disables home-manager's launchd socket-activated service.
- Two dedicated launchd agents (`devbox-gpg-tunnel`, `cloudbox-gpg-tunnel` in `home.darwin.nix:202-240`) maintain `ssh -N` connections that `RemoteForward /run/user/1000/gnupg/S.gpg-agent` from the Linux box to `~/.gnupg/S.gpg-agent.extra` on the Mac.
- `home.devbox.nix:85-93` and `home.cloudbox.nix:274-282` mask all local `gpg-agent.*` systemd units so the Linux side never starts its own agent that could clobber the forwarded socket.
- `home.devbox.nix:201-203` and `home.cloudbox.nix:291-293` install `~/.gnupg/common.conf` with `no-autostart`.
- `home.devbox.nix:194-197` and `home.cloudbox.nix:284-287` create `/run/user/1000/gnupg/` via `systemd.user.tmpfiles` so the forward target exists at boot.
- `update-ssh-config.sh:67-79, 133-143` defines `Host devbox-gpg-tunnel` and `Host cloudbox-gpg-tunnel` that ONLY do the GPG socket forward.
- `home.base.nix:431-432` sets `commit.gpgsign = true` and `gpg.format = "openpgp"` for git on every host.
- `home.base.nix:44-50` warns at shell startup on Linux if the forwarded GPG socket is missing.

### Problems with the current architecture

1. **Chronic launchd tunnel flapping.** `devbox-gpg-tunnel` and `cloudbox-gpg-tunnel` accumulate respawns from network blips, sleep/wake cycles, and (historically) a `UseKeychain yes` parse error in `~/.ssh/config`. The latter has since been removed from the active config but lingers in log files.
2. **Stale-socket recovery requires manual intervention.** When SSH connections die mid-tunnel without unlinking the remote socket, the file persists but doesn't route to a live agent, leaving GPG signing broken until someone runs `rm -f /run/user/1000/gnupg/S.gpg-agent` on the box and kickstarts the launchd agent.
3. **Three layers of fragility for one operation.** Signing requires (a) the Mac's `gpg-agent` to be alive with the unlocked key, (b) the launchd `ssh -N` tunnel to be connected, (c) the remote socket to be valid. Any layer breaking breaks signing.
4. **The architecture exists almost entirely to support headless OpenCode sessions** that need to commit without an interactive SSH session present. For interactive work, plain `ForwardAgent yes` would suffice.

### Why SSH signing solves this

- Git natively supports `gpg.format = ssh` and signs commits with SSH keys via OpenSSH's `ssh-keygen -Y sign` mechanism. GitHub validates SSH-signed commits and shows the same "Verified" badge as GPG signatures.
- A per-device key means **no forwarding, no agents, no tunnels**. Each box signs locally with its own key file. The launchd `*-gpg-tunnel` jobs disappear. The masked-systemd-units machinery on the Linux side disappears.
- Failure mode is simpler: either the local key file exists or it doesn't. No three-layer debugging.
- Touch ID per signature on the Mac is sacrificed, but it was never present on devbox/cloudbox sessions anyway (the forwarded gpg-agent had `defaultCacheTtl = 86400` so Touch ID was prompted at most once per 24 hours per box, in practice rarely).

## Design

### Per-device Ed25519 signing keys

Each host generates its own dedicated SSH signing key, separate from any existing auth key:

| Host | Key path | Purpose |
|------|----------|---------|
| macOS | `~/.ssh/id_ed25519_signing` | Sign commits made on macOS |
| devbox | `~/.ssh/id_ed25519_signing` | Sign commits made on devbox |
| cloudbox | `~/.ssh/id_ed25519_signing` | Sign commits made on cloudbox |

Keys are generated **without a passphrase**. Rationale: these are signing keys, not auth keys; they live on already-trusted user-owned hosts; passphrase prompts in non-interactive opencode sessions defeat the purpose of moving away from the GPG architecture. The macOS signing key is no more sensitive than the per-device dotfiles or git config — both grant the ability to make commits attributed to the user.

**Key rotation:** when a key needs to be rotated (host decommission, suspected compromise), the workflow is: generate a new key on that host, register the new public key with GitHub Settings → SSH and GPG keys → New SSH key (type: Signing Key), update `~/.config/git/allowed_signers` (see below), and remove the old key from GitHub.

### Git configuration

In `home.base.nix`, change git settings from:

```nix
commit.gpgsign = true;
gpg.format = "openpgp";
```

to:

```nix
commit.gpgsign = true;
gpg.format = "ssh";
"gpg \"ssh\"".allowedSignersFile = "~/.config/git/allowed_signers";
user.signingkey = "~/.ssh/id_ed25519_signing.pub";
```

`user.signingkey` points to the **public** half of the per-device key. Git uses the matching private key (same path without `.pub`) to actually sign.

### The `allowed_signers` file

For local verification (`git verify-commit`, `git log --show-signature`), git needs an `allowed_signers` file listing every public key trusted to sign as a given email address. Format:

```
jonathan.mohrbacher@gmail.com namespaces="git" ssh-ed25519 AAAA...macOS-key... darwin
jonathan.mohrbacher@gmail.com namespaces="git" ssh-ed25519 AAAA...devbox-key... devbox
jonathan.mohrbacher@gmail.com namespaces="git" ssh-ed25519 AAAA...cloudbox-key... cloudbox
```

This file is checked into `assets/git/allowed_signers` and deployed to `~/.config/git/allowed_signers` via home-manager's `home.file`. Adding a new host or rotating a key means editing this one file and applying home-manager.

The trailing field after the public key (`darwin`, `devbox`, etc.) is a free-form identifier — useful for human inspection and for `ssh-keygen -lvf allowed_signers` audits.

### Removing the GPG forwarding architecture

Once SSH signing works on all three hosts, the following pieces become unused and are removed:

**macOS (`home.darwin.nix`):**
- `services.gpg-agent` config (lines ~461-477)
- `launchd.agents.devbox-gpg-tunnel` (lines ~202-220)
- `launchd.agents.cloudbox-gpg-tunnel` (lines ~222-240)
- `OP_GPG_SECRET_REF` from `home.sessionVariables` (lines ~447-448)
- `pinentry-op` package from the system package set (around line ~70)
- The cleanup of `~/.gnupg/common.conf` from `home.activation.prepareForHM` (around line ~526) — keep, since users may still occasionally use GPG for non-Git purposes
- `launchd.agents.gpg-agent.enable = lib.mkForce false;` (line ~477)

**Devbox (`home.devbox.nix`):**
- `home.activation.maskGpgAgentUnits` (lines ~85-93)
- `systemd.user.tmpfiles.rules` for `/run/user/.../gnupg` (lines ~194-197)
- `home.file.".gnupg/common.conf"` with `no-autostart` (lines ~199-203)

**Cloudbox (`home.cloudbox.nix`):**
- `home.activation.maskGpgAgentUnits` (lines ~274-282)
- `systemd.user.tmpfiles.rules` for `/run/user/.../gnupg` (lines ~284-287)
- `home.file.".gnupg/common.conf"` with `no-autostart` (lines ~289-293)

**Shared (`home.base.nix`):**
- The shell-startup GPG socket warning (lines ~44-50)
- `programs.gpg.publicKeys` may stay (harmless; the public key remains useful for verifying GPG-signed work from others or signing files)
- `assets/gpg-signing-key.asc` may stay for the same reason

**SSH config (`scripts/update-ssh-config.sh`):**
- `Host devbox-gpg-tunnel` block (lines ~70-79)
- `Host cloudbox-gpg-tunnel` block (lines ~133-143)

**Custom packages (`pkgs/pinentry-op/`):**
- The whole package can be removed from the flake, since nothing references it anymore. The directory can stay if you want to preserve the work for future reuse, but should be unwired from `flake.nix`.

**Docs:**
- `troubleshooting-devbox/SKILL.md` "GPG Agent Forwarding" section — replace with a much shorter "SSH commit signing" section pointing at the per-device key + allowed_signers model.

### Migration sequence

The migration must be sequenced carefully because git is configured to sign all commits and a half-migrated state could break commits during the migration itself:

1. **Generate keys on all three hosts first** (no config changes).
2. **Build the `allowed_signers` file** with all three public keys.
3. **Switch git config** atomically to SSH signing in `home.base.nix`. This must include both `user.signingkey` AND `gpg.format = "ssh"` AND `gpg.ssh.allowedSignersFile` in the same change, applied to all three hosts in close succession.
4. **Verify** signing works on all three hosts.
5. **Register** all three public keys with GitHub as Signing Keys.
6. **Remove** the GPG forwarding infrastructure (separate, cleanup-only PR/commits).
7. **Update docs.**

Steps 1-5 are the active migration. Steps 6-7 are pure cleanup that can happen later if desired, but should happen in this work to prevent confusion and dead code accumulation.

## Scope

### In scope

- macOS, devbox, cloudbox configurations
- Git signing config in `home.base.nix`
- `allowed_signers` file and deployment
- Removal of all GPG forwarding infrastructure (launchd agents, masked units, tmpfiles, common.conf, tunnel SSH config)
- Update to `troubleshooting-devbox/SKILL.md`

### Out of scope

- **Crostini**: see Open Questions
- Removing the GPG public key from `assets/` (harmless, useful for non-git workflows)
- Removing `programs.gpg` entirely (still used to import the public key, useful for signature verification of others' work)
- Migrating SSH **auth** keys (separate concern, currently using 1Password SSH agent on Mac, host-specific keys on Linux — unchanged)
- 1Password SSH agent usage for signing: investigated and rejected. Per-device keys are simpler and avoid forwarding a 1Password agent socket which would re-introduce the same launchd tunnel fragility we're trying to escape.

## Non-Goals

- Touch ID per commit on macOS. The 24-hour cached GPG passphrase approximation we had didn't really deliver this anyway. SSH signing with a passphrase-less key trades one weak biometric story for a simpler architecture.
- Cross-host signature attribution differences. All three hosts sign as the same email; GitHub will show "Verified" identically regardless of which device signed.
- Backwards compatibility with old GPG-signed commits. Existing history remains GPG-signed and verifiable; only new commits use SSH signing.

## Open Questions

1. **Crostini.** This host is not currently configured for GPG signing in detail (the design doc at `2026-03-24-gpg-headless-sessions-design.md` only covers devbox). Should crostini get the same SSH signing setup as the other Linux hosts? If yes, the plan must include `home.crostini.nix` parallel changes.
2. **Cloudbox `home.cloudbox.nix` masking + tmpfiles cleanup**: confirm exact line numbers and that cloudbox's structure mirrors devbox's. The line numbers above were observed in the current tree; will be re-verified in the plan.
3. **Detached HEAD on `origin/main`**: this work needs a feature branch or worktree; will be handled by the executing agent following the standard flow.

## Verification

- `git config --get gpg.format` returns `ssh` on all three hosts
- `git config --get user.signingkey` returns the per-host signing key path
- `echo test | git commit-tree HEAD^{tree} -m test -S` succeeds on all three hosts (one-shot signing test against an existing commit)
- A real test commit pushed to a sandbox branch on GitHub shows "Verified" in the GitHub UI
- `git log --show-signature -1` on a commit made by each host shows `Good "git" signature for jonathan.mohrbacher@gmail.com`
- `launchctl list | grep gpg-tunnel` returns nothing on macOS (the agents are gone)
- `systemctl --user list-unit-files | grep -E '^(gpg-agent|gpg-agent-extra|gpg-agent-browser|gpg-agent-ssh)\.(service|socket)' ` does not show masked units on devbox/cloudbox (the masking activation is gone, units are at their package defaults)
- `ls /run/user/1000/gnupg/` on devbox/cloudbox shows the directory absent (no longer pre-created by tmpfiles)
- A headless opencode session can make a signed commit without any interactive SSH session being open

## References

- ChatGPT research answer: `/tmp/research-launchd-ssh-gpg-tunnel-flapping-answer.md` (recommends this approach)
- Original research brief: `/tmp/research-launchd-ssh-gpg-tunnel-flapping-question.md`
- Predecessor design: `docs/plans/2026-03-24-gpg-headless-sessions-design.md` (the GPG-forwarding architecture this work replaces)
- Predecessor plan: `docs/plans/2026-03-24-gpg-headless-sessions-plan.md`
- GitHub docs on SSH commit signing: https://docs.github.com/en/authentication/managing-commit-signature-verification/about-commit-signature-verification
