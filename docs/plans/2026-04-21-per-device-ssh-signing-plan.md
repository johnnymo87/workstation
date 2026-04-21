# Per-Device SSH Commit Signing Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace centralized GPG commit signing (one PGP key on Mac, forwarded to Linux boxes via launchd SSH tunnels) with per-device Ed25519 SSH signing keys on macOS, devbox, and cloudbox.

**Architecture:** Each host generates its own SSH signing key. Git is reconfigured with `gpg.format = ssh` and `user.signingkey` pointing at the per-host key. An `allowed_signers` file deployed via home-manager lists all three public keys for local verification. All GPG forwarding infrastructure (launchd agents, masked systemd units, tmpfiles rules, common.conf, tunnel SSH config, pinentry-op package) is removed.

**Tech Stack:** nix-darwin, NixOS, home-manager, OpenSSH (`ssh-keygen -Y sign`), git ≥2.34, GitHub commit signature verification.

**Design doc:** `docs/plans/2026-04-21-per-device-ssh-signing-design.md` — read this first.

---

## Pre-flight (do before starting Task 1)

**Verify the working tree.** This plan modifies many files across `users/dev/`, `scripts/`, `assets/`, and `docs/`.

```bash
cd ~/Code/workstation
git status
git log --oneline -3
```

Expected: clean working tree on a feature branch (or worktree). If on detached HEAD, create a branch first: `git checkout -b ssh-commit-signing`.

**Read the design doc.**

```bash
$EDITOR docs/plans/2026-04-21-per-device-ssh-signing-design.md
```

**Re-verify line numbers** noted in the design doc — files may have shifted since the design was written. If they have, update the design doc's line references in the same commit as the code change that touches them.

**Resolve Open Question about Crostini** (design doc §"Open Questions" item 1) before Task 6. If we are NOT including crostini in this work, leave its `programs.gpg` config untouched. If we ARE, add a parallel set of changes mirroring devbox.

**For the rest of this plan**, "all three hosts" means **macOS + devbox + cloudbox** unless crostini is explicitly added; in that case it means all four.

---

## Task 1: Generate the macOS signing key

**Files:**
- Create: `~/.ssh/id_ed25519_signing` (private)
- Create: `~/.ssh/id_ed25519_signing.pub` (public)

**Step 1: Verify the key doesn't already exist.**

```bash
test ! -e ~/.ssh/id_ed25519_signing && test ! -e ~/.ssh/id_ed25519_signing.pub && echo "OK: no existing keys"
```

Expected: `OK: no existing keys`. If either exists, stop and investigate — do not overwrite.

**Step 2: Generate the key.**

```bash
ssh-keygen -t ed25519 -N '' -C 'jonathan.mohrbacher@gmail.com (darwin signing)' -f ~/.ssh/id_ed25519_signing
```

Expected: two new files. The comment helps identify the key in `ssh-keygen -l` output.

**Step 3: Verify and capture the public key for later tasks.**

```bash
ls -la ~/.ssh/id_ed25519_signing*
ssh-keygen -l -f ~/.ssh/id_ed25519_signing.pub
cat ~/.ssh/id_ed25519_signing.pub
```

Expected: private key 0600, public key 0644, fingerprint shown, public key starts with `ssh-ed25519 AAAA...`.

Save the public key line — you will need it verbatim in Task 4. Recommendation: write it to a scratchpad file that survives this task chain:

```bash
echo "darwin: $(cat ~/.ssh/id_ed25519_signing.pub)" >> /tmp/per-device-signing-pubkeys.txt
```

**Step 4: No commit.** This is host-local key material, not repo content.

---

## Task 2: Generate the devbox signing key

**Files:** same shape as Task 1, on devbox.

**Step 1: Verify devbox SSH connectivity and absence of existing key.**

```bash
ssh devbox 'test ! -e ~/.ssh/id_ed25519_signing && test ! -e ~/.ssh/id_ed25519_signing.pub && echo OK'
```

Expected: `OK`. Stop if not.

**Step 2: Generate the key on devbox.**

```bash
ssh devbox "ssh-keygen -t ed25519 -N '' -C 'jonathan.mohrbacher@gmail.com (devbox signing)' -f ~/.ssh/id_ed25519_signing"
```

**Step 3: Capture the public key.**

```bash
echo "devbox: $(ssh devbox 'cat ~/.ssh/id_ed25519_signing.pub')" >> /tmp/per-device-signing-pubkeys.txt
ssh devbox 'ssh-keygen -l -f ~/.ssh/id_ed25519_signing.pub'
```

Expected: 256-bit ED25519 fingerprint and the comment string. Confirm the line was appended to `/tmp/per-device-signing-pubkeys.txt`.

---

## Task 3: Generate the cloudbox signing key

Same as Task 2 but for cloudbox. Mirror the steps:

```bash
ssh cloudbox 'test ! -e ~/.ssh/id_ed25519_signing && test ! -e ~/.ssh/id_ed25519_signing.pub && echo OK'
ssh cloudbox "ssh-keygen -t ed25519 -N '' -C 'jonathan.mohrbacher@gmail.com (cloudbox signing)' -f ~/.ssh/id_ed25519_signing"
echo "cloudbox: $(ssh cloudbox 'cat ~/.ssh/id_ed25519_signing.pub')" >> /tmp/per-device-signing-pubkeys.txt
ssh cloudbox 'ssh-keygen -l -f ~/.ssh/id_ed25519_signing.pub'
```

Expected: three lines now in `/tmp/per-device-signing-pubkeys.txt`, one per host.

---

## Task 4: Create the `allowed_signers` asset and home-manager wiring

**Files:**
- Create: `assets/git/allowed_signers`
- Modify: `users/dev/home.base.nix` (deploy the asset)

**Step 1: Inspect the captured public keys.**

```bash
cat /tmp/per-device-signing-pubkeys.txt
```

You should see three lines like `darwin: ssh-ed25519 AAAAC3...`, `devbox: ssh-ed25519 AAAAC3...`, `cloudbox: ssh-ed25519 AAAAC3...`.

**Step 2: Create `assets/git/allowed_signers`.**

The format is one signer per line: `<principal> [namespaces="..."] <public-key> [comment]`. We restrict to the `git` namespace so this file only applies to git signature verification, not generic `ssh-keygen -Y` use.

```bash
mkdir -p assets/git
```

Build the file from the captured pubkeys. Each line follows the shape:

```
jonathan.mohrbacher@gmail.com namespaces="git" ssh-ed25519 AAAA...REDACTED... darwin
jonathan.mohrbacher@gmail.com namespaces="git" ssh-ed25519 AAAA...REDACTED... devbox
jonathan.mohrbacher@gmail.com namespaces="git" ssh-ed25519 AAAA...REDACTED... cloudbox
```

Use the actual public key strings from `/tmp/per-device-signing-pubkeys.txt`. Write the file directly with the Write tool, or hand-edit, but do NOT shell-quote in a way that strips the trailing newline. The file should end with a single trailing `\n`.

**Step 3: Verify the file parses.**

```bash
ssh-keygen -Y find-principals -s /dev/null -f assets/git/allowed_signers 2>&1 | head
# Just want to confirm the file is syntactically valid; the command will error
# without a signature, but should not error about the allowed_signers format itself.
wc -l assets/git/allowed_signers
```

Expected: 3 lines (one per host). No "invalid format" complaint from ssh-keygen.

**Step 4: Wire the asset into `home.base.nix`.**

Locate the existing `programs.git.settings` block (currently around `home.base.nix:425-447`). After the `settings` block (NOT inside it), add a `home.file` deployment:

```nix
  # Allowed signers for git SSH-signature verification.
  # Lists every per-device SSH signing key trusted to sign as our identity.
  # Add a new line here when adding a new host or rotating a key, then re-apply.
  home.file.".config/git/allowed_signers".source = "${assetsPath}/git/allowed_signers";
```

Place this near the existing git/gpg config for cohesion (immediately after `programs.git = { ... };` ends, before `programs.gpg = { ... };`).

**Step 5: Commit (the asset and wiring, BUT NOT the git config switch yet).**

```bash
git add assets/git/allowed_signers users/dev/home.base.nix
git commit -m 'feat: add allowed_signers for SSH commit signing

Pre-staging for the per-device SSH signing migration. Deploys the
allowed_signers file to ~/.config/git/allowed_signers on every host
via home-manager. Does not yet switch git from openpgp to ssh signing
(see follow-up commit).

See docs/plans/2026-04-21-per-device-ssh-signing-design.md.'
```

The asset is now deployed but unused — git is still configured for openpgp signing. This is intentional sequencing.

---

## Task 5: Apply home-manager on all three hosts to deploy `allowed_signers`

**Files:** none (apply step only).

**Step 1: Apply on macOS.**

```bash
sudo darwin-rebuild switch --flake .#Y0FMQX93RR-2
```

Expected: completes without error, `~/.config/git/allowed_signers` now exists as a symlink.

**Step 2: Verify on macOS.**

```bash
ls -la ~/.config/git/allowed_signers
cat ~/.config/git/allowed_signers
```

Expected: symlink to nix store, contents identical to `assets/git/allowed_signers`.

**Step 3: Apply on devbox.**

```bash
ssh devbox 'cd ~/projects/workstation && git pull && nix run home-manager -- switch --flake .#dev'
```

(Adjust `git pull` if working from an unpushed branch — you may need to push the branch first or rsync the working tree.)

**Step 4: Verify on devbox.**

```bash
ssh devbox 'ls -la ~/.config/git/allowed_signers && cat ~/.config/git/allowed_signers'
```

**Step 5: Apply on cloudbox.**

```bash
ssh cloudbox 'cd ~/projects/workstation && git pull && nix run home-manager -- switch --flake .#dev'
```

**Step 6: Verify on cloudbox.**

```bash
ssh cloudbox 'ls -la ~/.config/git/allowed_signers && cat ~/.config/git/allowed_signers'
```

Expected on all three: file present, contents identical, three lines.

**Step 7: No commit.** Apply-only step.

---

## Task 6: Switch git config from openpgp to ssh signing

**Files:**
- Modify: `users/dev/home.base.nix` (the `programs.git.settings` block, currently lines 425-447)

**Step 1: Edit the settings block.**

Find:

```nix
      commit.gpgsign = true;
      gpg.format = "openpgp";
```

Replace with:

```nix
      commit.gpgsign = true;
      gpg.format = "ssh";
      user.signingkey = "~/.ssh/id_ed25519_signing.pub";
      "gpg \"ssh\"".allowedSignersFile = "~/.config/git/allowed_signers";
```

The escaped quotes in `"gpg \"ssh\""` are required by Nix to produce the literal git config section name `[gpg "ssh"]`. (Nix attribute names with embedded dots become nested config sections; embedded quotes survive into the output.)

**Step 2: Verify the Nix expression evaluates.**

```bash
nix eval .#homeConfigurations.dev.config.programs.git.extraConfig 2>&1 | head -30
```

(If your flake exposes the home config under a different attribute, adjust accordingly. The point is: catch syntax errors before applying.)

Expected: no error, output contains `format = "ssh"`, `signingkey = "~/.ssh/id_ed25519_signing.pub"`, and a `[gpg "ssh"]` section with `allowedSignersFile`.

**Step 3: Commit.**

```bash
git add users/dev/home.base.nix
git commit -m 'feat: switch git from openpgp to ssh commit signing

Each host now signs commits with its own ~/.ssh/id_ed25519_signing key.
Verification uses ~/.config/git/allowed_signers (deployed in previous
commit).

GitHub will continue to show "Verified" once each host'"'"'s public key
is registered as a Signing Key in GitHub Settings.

GPG forwarding infrastructure is still in place but unused after this
commit; cleanup follows in a later commit.

See docs/plans/2026-04-21-per-device-ssh-signing-design.md.'
```

---

## Task 7: Apply git config switch and verify signing on all three hosts

**Step 1: Apply on macOS.**

```bash
sudo darwin-rebuild switch --flake .#Y0FMQX93RR-2
```

**Step 2: Verify git config on macOS.**

```bash
git config --global --get gpg.format
git config --global --get user.signingkey
git config --global --get gpg.ssh.allowedSignersFile
```

Expected: `ssh`, `~/.ssh/id_ed25519_signing.pub`, `~/.config/git/allowed_signers`.

**Step 3: Test signing on macOS without a real commit.**

```bash
cd /tmp && rm -rf signing-test && mkdir signing-test && cd signing-test
git init -q
git config user.email jonathan.mohrbacher@gmail.com
git config user.name 'Jonathan Mohrbacher'
echo hi > a
git add a
git commit -m 'test signing' -S
git log --show-signature -1
```

Expected: commit succeeds, `git log --show-signature` shows `Good "git" signature for jonathan.mohrbacher@gmail.com with ED25519 key SHA256:...`.

If verification reports `No principal matched`: confirm `~/.config/git/allowed_signers` contains the macOS key and that `gpg.ssh.allowedSignersFile` resolves correctly (`git config --get gpg.ssh.allowedSignersFile` and ensure the path expands).

**Step 4: Apply and verify on devbox.**

```bash
ssh devbox 'cd ~/projects/workstation && git pull && nix run home-manager -- switch --flake .#dev'
ssh devbox 'cd /tmp && rm -rf signing-test && mkdir signing-test && cd signing-test && git init -q && git config user.email jonathan.mohrbacher@gmail.com && git config user.name "Jonathan Mohrbacher" && echo hi > a && git add a && git commit -m "test signing" -S && git log --show-signature -1'
```

Expected: same `Good "git" signature` output.

**Step 5: Apply and verify on cloudbox.** Same pattern.

```bash
ssh cloudbox 'cd ~/projects/workstation && git pull && nix run home-manager -- switch --flake .#dev'
ssh cloudbox 'cd /tmp && rm -rf signing-test && mkdir signing-test && cd signing-test && git init -q && git config user.email jonathan.mohrbacher@gmail.com && git config user.name "Jonathan Mohrbacher" && echo hi > a && git add a && git commit -m "test signing" -S && git log --show-signature -1'
```

**Step 6: No commit.** Apply-and-verify step.

---

## Task 8: Register all three public keys with GitHub as Signing Keys

**Files:** none (manual web action).

**Step 1: Open the GitHub SSH/GPG keys page.**

```
https://github.com/settings/ssh/new
```

**Step 2: Add each key.**

For each of the three public keys in `/tmp/per-device-signing-pubkeys.txt`:

1. Title: `<hostname> signing key (ed25519)` — e.g., `darwin signing key (ed25519)`
2. Key type: **Signing Key** (NOT Authentication Key)
3. Key: paste the full `ssh-ed25519 AAAA... comment` line

After adding all three, the GitHub Settings → SSH and GPG keys page should list all three under "Signing Keys".

**Step 3: Verify with a real commit pushed to GitHub.**

Pick a low-stakes repo (or use `~/Code/workstation` itself on a sandbox branch). Make a real commit on each host and push:

```bash
# On macOS:
cd ~/Code/workstation
git checkout -b ssh-signing-verify-darwin
git commit --allow-empty -m 'verify ssh signing from darwin'
git push -u origin ssh-signing-verify-darwin

# On devbox:
ssh devbox 'cd ~/projects/workstation && git checkout -b ssh-signing-verify-devbox && git commit --allow-empty -m "verify ssh signing from devbox" && git push -u origin ssh-signing-verify-devbox'

# On cloudbox:
ssh cloudbox 'cd ~/projects/workstation && git checkout -b ssh-signing-verify-cloudbox && git commit --allow-empty -m "verify ssh signing from cloudbox" && git push -u origin ssh-signing-verify-cloudbox'
```

**Step 4: Confirm "Verified" badge in GitHub UI.**

Visit each branch on GitHub and confirm the commit shows the green "Verified" badge.

```
https://github.com/<org>/workstation/tree/ssh-signing-verify-darwin
https://github.com/<org>/workstation/tree/ssh-signing-verify-devbox
https://github.com/<org>/workstation/tree/ssh-signing-verify-cloudbox
```

**Step 5: Clean up the verify branches.**

```bash
git push origin --delete ssh-signing-verify-darwin ssh-signing-verify-devbox ssh-signing-verify-cloudbox
git branch -D ssh-signing-verify-darwin
ssh devbox 'cd ~/projects/workstation && git branch -D ssh-signing-verify-devbox'
ssh cloudbox 'cd ~/projects/workstation && git branch -D ssh-signing-verify-cloudbox'
```

**Step 6: No code commit.** This task is verification only.

**STOP HERE if you want to ship the migration in a smaller chunk.** Tasks 9-13 are pure cleanup of the old GPG architecture. The migration is fully functional after Task 8; the remaining tasks just delete dead code and unused launchd jobs.

---

## Task 9: Remove launchd `*-gpg-tunnel` agents from `home.darwin.nix`

**Files:**
- Modify: `users/dev/home.darwin.nix` (delete lines ~202-240, the two `launchd.agents.{devbox,cloudbox}-gpg-tunnel` blocks)

**Step 1: Confirm the line numbers in the current tree.**

```bash
grep -n 'devbox-gpg-tunnel\|cloudbox-gpg-tunnel' users/dev/home.darwin.nix
```

Expected: matches inside `launchd.agents.devbox-gpg-tunnel` and `launchd.agents.cloudbox-gpg-tunnel` blocks. Note the line ranges.

**Step 2: Delete both blocks.**

Remove the entire `launchd.agents.devbox-gpg-tunnel = { ... };` and `launchd.agents.cloudbox-gpg-tunnel = { ... };` blocks, including the comment header that introduces them ("Persistent SSH tunnels for GPG agent forwarding...").

**Step 3: Verify nothing else references them.**

```bash
grep -rn 'gpg-tunnel' users/ scripts/ assets/ docs/
```

You will see references in:
- `scripts/update-ssh-config.sh` (Host blocks — handled in Task 10)
- `.opencode/skills/troubleshooting-devbox/SKILL.md` (docs — handled in Task 13)
- `docs/plans/` (old planning docs — leave them as historical record)

**Step 4: Apply on macOS and verify the agents are gone.**

```bash
sudo darwin-rebuild switch --flake .#Y0FMQX93RR-2
launchctl list | grep gpg-tunnel
```

Expected: `launchctl list` returns nothing (the agents were unloaded by darwin-rebuild).

**Step 5: Commit.**

```bash
git add users/dev/home.darwin.nix
git commit -m 'chore: remove launchd *-gpg-tunnel agents

These maintained ssh -N tunnels forwarding the macOS gpg-agent extra
socket to /run/user/1000/gnupg/S.gpg-agent on devbox/cloudbox. Replaced
by per-device SSH commit signing keys (no forwarding needed).'
```

---

## Task 10: Remove `*-gpg-tunnel` Host blocks from `update-ssh-config.sh`

**Files:**
- Modify: `scripts/update-ssh-config.sh` (delete two `Host *-gpg-tunnel` blocks, currently around lines 67-79 and 133-143)

**Step 1: Locate the blocks.**

```bash
grep -n '-gpg-tunnel' scripts/update-ssh-config.sh
```

**Step 2: Delete both `Host devbox-gpg-tunnel` and `Host cloudbox-gpg-tunnel` blocks** including their preceding comment headers ("Persistent GPG agent forwarding...").

**Step 3: Re-run the script and inspect the result.**

```bash
./scripts/update-ssh-config.sh
grep -n 'gpg-tunnel\|Host ' ~/.ssh/config
```

Expected: no `gpg-tunnel` Host blocks in `~/.ssh/config`. The `Host devbox`, `Host devbox-tunnel`, `Host cloudbox`, `Host cloudbox-tunnel` blocks remain.

**Step 4: Verify the dev tunnels still work** (they should be unaffected — different Host blocks):

```bash
launchctl list | grep dev-tunnel
ssh devbox 'echo OK'
ssh cloudbox 'echo OK'
```

Expected: dev-tunnel agents loaded, both SSH connections succeed.

**Step 5: Commit.**

```bash
git add scripts/update-ssh-config.sh
git commit -m 'chore: drop devbox/cloudbox-gpg-tunnel SSH host configs

These existed solely to give the now-removed launchd *-gpg-tunnel
agents an isolated SSH host config for the GPG socket RemoteForward.
With per-device SSH signing in place, no GPG forwarding happens at
all and these Host blocks have no consumer.'
```

---

## Task 11: Remove GPG masking, tmpfiles, and `no-autostart` from devbox

**Files:**
- Modify: `users/dev/home.devbox.nix` — delete:
  - `home.activation.maskGpgAgentUnits` (lines ~85-93)
  - `systemd.user.tmpfiles.rules` for `/run/user/1000/gnupg` (lines ~194-197) — but check whether anything ELSE in that block needs the directory; if so, keep the block but remove just the gnupg rule
  - `home.file.".gnupg/common.conf"` with `no-autostart` (lines ~199-203)

**Step 1: Locate each block.**

```bash
grep -n 'maskGpgAgentUnits\|tmpfiles.rules\|gnupg/common.conf\|no-autostart' users/dev/home.devbox.nix
```

**Step 2: Delete each block.** Be careful with `systemd.user.tmpfiles.rules` — if it ONLY contains the gnupg rule, delete the whole block; if it has other rules, just remove the gnupg line.

**Step 3: Manually undo the masking on the live devbox.**

Home-manager's activation script that created the masking `/dev/null` symlinks is no longer present, but the symlinks themselves persist on disk. Remove them:

```bash
ssh devbox 'for unit in gpg-agent.service gpg-agent.socket gpg-agent-extra.socket gpg-agent-browser.socket gpg-agent-ssh.socket; do
  if [ -L "$HOME/.config/systemd/user/$unit" ] && [ "$(readlink "$HOME/.config/systemd/user/$unit")" = "/dev/null" ]; then
    rm -v "$HOME/.config/systemd/user/$unit"
  fi
done
systemctl --user daemon-reload'
```

**Step 4: Apply on devbox.**

```bash
ssh devbox 'cd ~/projects/workstation && git pull && nix run home-manager -- switch --flake .#dev'
```

**Step 5: Verify the cleanup.**

```bash
ssh devbox 'ls -la ~/.config/systemd/user/ | grep gpg-agent || echo "no gpg-agent units present (good)"'
ssh devbox 'systemctl --user is-enabled gpg-agent.socket 2>&1'
ssh devbox 'test -f ~/.gnupg/common.conf && echo "common.conf still present (BAD)" || echo "common.conf gone (good)"'
ssh devbox 'ls -la /run/user/1000/gnupg/ 2>&1 | head'
```

Expected: no gpg-agent unit symlinks under `~/.config/systemd/user/`, `common.conf` absent (or, if a non-our-managed file remains, that's fine — just not the `no-autostart` one), `/run/user/1000/gnupg/` either absent or only present because gpg-agent autostarted (harmless now).

**Step 6: Verify signing still works on devbox.**

```bash
ssh devbox 'cd /tmp && rm -rf signing-test2 && mkdir signing-test2 && cd signing-test2 && git init -q && git config user.email jonathan.mohrbacher@gmail.com && git config user.name "Jonathan Mohrbacher" && echo hi > a && git add a && git commit -m "test signing post-cleanup" -S && git log --show-signature -1'
```

Expected: `Good "git" signature`. SSH signing has nothing to do with the GPG infrastructure we just removed, so this should be unaffected.

**Step 7: Commit.**

```bash
git add users/dev/home.devbox.nix
git commit -m 'chore: remove GPG forwarding infrastructure on devbox

- maskGpgAgentUnits activation (no need to mask now that we are not
  forwarding a socket the local agent could clobber)
- /run/user/1000/gnupg tmpfiles rule (no socket gets forwarded here)
- ~/.gnupg/common.conf with no-autostart (no agent forwarding to protect)

The devbox now signs commits with its own SSH key. No GPG agent
forwarding from macOS is involved.'
```

---

## Task 12: Mirror Task 11 changes on cloudbox

**Files:**
- Modify: `users/dev/home.cloudbox.nix` — same three blocks (lines ~274-282, ~284-287, ~289-293)

Repeat Task 11 step-by-step against cloudbox. Same patterns, same verification, same commit message (s/devbox/cloudbox/).

---

## Task 13: Remove `pinentry-op` package and `OP_GPG_SECRET_REF` from `home.darwin.nix`

**Files:**
- Modify: `users/dev/home.darwin.nix` — delete:
  - The `pinentry-op` entry from the package list (around line 70)
  - `OP_GPG_SECRET_REF` from `home.sessionVariables` (around lines 447-448)
  - `services.gpg-agent` block (around lines 461-477) — including the `pinentry-program` and the `extra-socket` settings
  - `launchd.agents.gpg-agent.enable = lib.mkForce false;` (around line 477) — no longer needed since we are not configuring services.gpg-agent at all
  - The `pinentry-op` import from the function arguments at top of file (line 8)

**Files (flake-level):**
- Modify: `flake.nix` — remove the `pinentry-op` entry from `localPkgsFor` and from the `extraSpecialArgs` for darwin systems (search for `pinentry-op` — multiple references)

**Files (package definition):**
- Optional: delete `pkgs/pinentry-op/` directory entirely. If you want to preserve it for future reuse, leave it but ensure it is not referenced from `flake.nix`. Recommendation: delete; it is recoverable from git history.

**Step 1: Find every `pinentry-op` reference.**

```bash
grep -rn 'pinentry-op\|OP_GPG_SECRET_REF' users/ flake.nix pkgs/ assets/ scripts/
```

**Step 2: Remove from `home.darwin.nix`.**

Edit each location identified. The `services.gpg-agent` block includes the `extraConfig` with the `pinentry-program` line — that whole block goes.

**Step 3: Remove from `flake.nix`.**

Find the `localPkgsFor` function and the darwin `extraSpecialArgs`. Remove `pinentry-op` from both.

**Step 4: (Optional) Delete `pkgs/pinentry-op/`.**

```bash
git rm -r pkgs/pinentry-op/
```

**Step 5: Apply on macOS and verify.**

```bash
sudo darwin-rebuild switch --flake .#Y0FMQX93RR-2
which pinentry-op 2>&1 || echo "pinentry-op gone (expected)"
echo "$OP_GPG_SECRET_REF" || echo "OP_GPG_SECRET_REF unset (expected after new shell)"
```

(The shell variable will only update on a new shell — open a new terminal tab to confirm.)

**Step 6: Verify the local Mac gpg-agent is no longer being managed by home-manager** (it may still be running because GnuPG auto-started it on demand for some other operation; that's fine, just confirming we removed the explicit launchd configuration):

```bash
launchctl list | grep gpg-agent || echo "no launchd gpg-agent (good)"
```

The local macOS gpg-agent will still auto-start if you use `gpg` on a file, since `programs.gpg.enable = true` is still set in `home.base.nix`. That is fine — we are only removing the explicit `services.gpg-agent` configuration that was tuned for forwarding via `pinentry-op`.

**Step 7: Commit.**

```bash
git add users/dev/home.darwin.nix flake.nix
git rm -r pkgs/pinentry-op/  # if doing the optional deletion
git commit -m 'chore: remove pinentry-op and services.gpg-agent on macOS

pinentry-op (1Password Touch ID pinentry helper) was used to unlock
the GPG signing key for git commits on macOS and to feed the unlocked
agent through the *-gpg-tunnel forwards to devbox/cloudbox. With
per-device SSH signing, neither use case remains.

GPG itself is still installed via programs.gpg for occasional file
encryption / verifying others signatures, but with the upstream-default
auto-start behavior rather than our custom launchd setup.'
```

---

## Task 14: Remove the shell-startup GPG socket warning

**Files:**
- Modify: `users/dev/home.base.nix` (lines ~44-50, the `# GPG agent forwarding check (Linux only)` block in the bashrc init)

**Step 1: Locate.**

```bash
grep -n 'GPG agent forwarding check\|GPG_SOCKET\|persistent GPG tunnel' users/dev/home.base.nix
```

**Step 2: Delete the block.** The whole `if [ -d "/run/user/1000" ]...` snippet that warns when the forwarded socket is missing.

**Step 3: Apply on all three hosts.**

```bash
sudo darwin-rebuild switch --flake .#Y0FMQX93RR-2
ssh devbox 'cd ~/projects/workstation && git pull && nix run home-manager -- switch --flake .#dev'
ssh cloudbox 'cd ~/projects/workstation && git pull && nix run home-manager -- switch --flake .#dev'
```

**Step 4: Verify the warning is gone.**

Open a new shell on devbox and cloudbox; confirm no GPG socket warning appears.

**Step 5: Commit.**

```bash
git add users/dev/home.base.nix
git commit -m 'chore: drop shell-startup GPG socket warning

The warning was useful when commit signing depended on the forwarded
gpg-agent socket. With per-device SSH signing, the socket is irrelevant
for git use and the warning is just noise.'
```

---

## Task 15: Update `troubleshooting-devbox` skill

**Files:**
- Modify: `.opencode/skills/troubleshooting-devbox/SKILL.md`

**Step 1: Locate the GPG section.**

```bash
grep -n 'GPG\|gpg-tunnel' .opencode/skills/troubleshooting-devbox/SKILL.md
```

**Step 2: Replace the entire "GPG Agent Forwarding" section** (currently spanning ~50 lines around line 319) with a much shorter "Commit signing" section:

```markdown
## Commit Signing

Each host (macOS, devbox, cloudbox) has its own SSH signing key at
`~/.ssh/id_ed25519_signing`. Git is configured with `gpg.format = ssh`
and signs commits locally on whichever host you are using; no agent
forwarding is involved.

### Symptoms

- `git commit` fails with `error: gpg failed to sign the data`
- `git log --show-signature` shows `No principal matched`

### Diagnose

```bash
git config --get gpg.format               # expect: ssh
git config --get user.signingkey          # expect: ~/.ssh/id_ed25519_signing.pub
git config --get gpg.ssh.allowedSignersFile   # expect: ~/.config/git/allowed_signers
ls -la ~/.ssh/id_ed25519_signing*         # both files present, private key 0600
ssh-keygen -l -f ~/.ssh/id_ed25519_signing.pub   # fingerprint should match the
                                                 # corresponding line in
                                                 # ~/.config/git/allowed_signers
```

### Add a new host's signing key

1. On the new host: `ssh-keygen -t ed25519 -N '' -C '<email> (<host> signing)' -f ~/.ssh/id_ed25519_signing`
2. Append the new pubkey to `assets/git/allowed_signers` with the format `<email> namespaces="git" <pubkey> <hostname-tag>`
3. Apply home-manager: `nix run home-manager -- switch --flake .#dev`
4. Register the pubkey at https://github.com/settings/ssh/new (type: Signing Key)
```

Also remove the `*-gpg-tunnel` row from the connection-model table at the top of the skill, and any other references to `gpg-tunnel` agents.

**Step 3: Commit.**

```bash
git add .opencode/skills/troubleshooting-devbox/SKILL.md
git commit -m 'docs: update troubleshooting-devbox for SSH commit signing

Replaces the long GPG agent forwarding troubleshooting section with a
short commit-signing section appropriate to the per-device SSH signing
architecture.'
```

---

## Task 16: Verify end-to-end on all three hosts

**Step 1: Make a real commit on each host and confirm.**

```bash
# On macOS:
cd ~/Code/workstation
git commit --allow-empty -m 'final verification: signing from darwin'
git log --show-signature -1 | head -10
# Expected: Good "git" signature for jonathan.mohrbacher@gmail.com

# On devbox:
ssh devbox 'cd ~/projects/workstation && git commit --allow-empty -m "final verification: signing from devbox" && git log --show-signature -1 | head -10'

# On cloudbox:
ssh cloudbox 'cd ~/projects/workstation && git commit --allow-empty -m "final verification: signing from cloudbox" && git log --show-signature -1 | head -10'
```

Expected on all three: `Good "git" signature for jonathan.mohrbacher@gmail.com with ED25519 key SHA256:...`

**Step 2: Push and confirm "Verified" on GitHub.**

```bash
git push  # on each host where the verification commit was made
```

Visit each commit on GitHub and confirm the green "Verified" badge.

**Step 3: Verify infrastructure is gone.**

```bash
# macOS
launchctl list | grep gpg-tunnel || echo "no gpg-tunnel agents (good)"
test ! -d /Users/<user>/.gnupg/S.gpg-agent.extra && echo "extra socket gone (or never existed; either is fine)" || echo "still there"

# devbox
ssh devbox 'ls -la ~/.config/systemd/user/ | grep -E "gpg-agent.*-> /dev/null" && echo "still masked (BAD)" || echo "no masking symlinks (good)"'
ssh devbox 'test -f ~/.gnupg/common.conf && grep -q no-autostart ~/.gnupg/common.conf && echo "common.conf still has no-autostart (BAD)" || echo "good"'

# cloudbox
ssh cloudbox 'ls -la ~/.config/systemd/user/ | grep -E "gpg-agent.*-> /dev/null" && echo "still masked (BAD)" || echo "no masking symlinks (good)"'
ssh cloudbox 'test -f ~/.gnupg/common.conf && grep -q no-autostart ~/.gnupg/common.conf && echo "common.conf still has no-autostart (BAD)" || echo "good"'
```

Expected: `(good)` for every check.

**Step 4: No commit. Verification only.**

---

## Task 17: Push everything and clean up

**Step 1: Push the branch.**

```bash
git push -u origin <branch-name>
```

**Step 2: Open a PR if working in PR-based flow.**

PR title and description follow the repo conventions — see the `creating-pull-requests` skill if uncertain.

**Step 3: Clean up the scratchpad.**

```bash
rm -f /tmp/per-device-signing-pubkeys.txt
rm -f /tmp/research-launchd-ssh-gpg-tunnel-flapping-question.md
rm -f /tmp/research-launchd-ssh-gpg-tunnel-flapping-answer.md
```

**Step 4: After merge, sync devbox and cloudbox to merged main.**

```bash
ssh devbox 'cd ~/projects/workstation && git checkout main && git pull && nix run home-manager -- switch --flake .#dev'
ssh cloudbox 'cd ~/projects/workstation && git checkout main && git pull && nix run home-manager -- switch --flake .#dev'
```

---

## Rollback

If anything in this migration goes badly wrong:

**Quick rollback to GPG signing:**
- `git revert` the commit from Task 6 (the git-config switch)
- Apply home-manager on the affected host
- Signing reverts to the GPG path
- (The launchd `*-gpg-tunnel` agents and other infrastructure remain in place until you start removing them in Task 9, so a rollback before Task 9 is just one revert)

**After cleanup commits (Task 9+):**
- Multiple reverts required (Tasks 9-15)
- Consider whether to revert at all vs. fix forward — by this point, signing has been verified working with SSH on all three hosts, so the issue is more likely a misunderstanding than a real failure of the architecture

---

## Notes for the executing agent

- **Sequence matters**: do NOT do Task 6 (git config switch) before Task 5 (deploy `allowed_signers`). The signing keys must exist (Tasks 1-3), the public keys must be deployed in `allowed_signers` (Tasks 4-5), and ONLY THEN switch git config. Otherwise local verification will fail and `git log --show-signature` will be unhappy.
- **GitHub registration (Task 8) can happen any time after Task 7** but BEFORE expecting the "Verified" badge on github.com.
- **Tasks 9-15 are pure cleanup** and can be deferred to a separate PR if the migration PR is getting too large to review. They can also be ordered differently — they are independent of each other once Task 8 is done.
- **Crostini is intentionally out of scope** for this plan unless the executing agent (or user) decides to add it explicitly. If adding it, mirror Tasks 3 + 12 + 14 for crostini.
- **For each remote `git pull && nix run home-manager`**, if working from an unpushed branch, you will need to either push the branch first or rsync the working tree. The executing agent should pick the right approach based on workflow.
