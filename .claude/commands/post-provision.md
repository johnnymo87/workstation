---
name: post-provision
description: Complete devbox setup after first SSH (authentication, GPG signing, agent forwarding)
---

# Post-Provision Setup

Complete the devbox setup after first SSH.

> **Note:** Git commit signing uses GPG agent forwarding from your Mac. Your SSH config should include `RemoteForward` for the GPG socket.

## Steps

1. **Authenticate with GitHub CLI**
   ```bash
   gh auth login
   ```
   - Select GitHub.com
   - Select SSH (matches our git config)
   - Authenticate via browser (device flow)

   Note: This is for the `gh` CLI (PRs, issues, API). Git operations use the SSH key at `~/.ssh/id_ed25519_github`.

2. **Configure git credential helper**
   ```bash
   gh auth setup-git
   ```

3. **Verify GPG agent forwarding works**
   ```bash
   gpg --card-status
   ```
   Should show your GPG card/key info from your Mac's agent.

   If it fails, check your SSH config has the GPG socket RemoteForward configured.

4. **Verify git signing works**
   ```bash
   cd ~/projects && mkdir test-signing && cd test-signing
   git init && echo test > file && git add file
   git commit -m "test signing"
   ```
   Should succeed with GPG signature.

5. **Clean up test**
   ```bash
   rm -rf ~/projects/test-signing
   ```

## Done

After these steps, commits will be GPG-signed (when connected with agent forwarding) and pushed via gh credentials.
