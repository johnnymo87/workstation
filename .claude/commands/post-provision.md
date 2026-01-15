---
name: post-provision
description: Complete devbox setup after first SSH (authentication, git signing, agent forwarding)
---

# Post-Provision Setup

Complete the devbox setup after first SSH.

> **Note:** Git commit signing uses SSH agent forwarding from your Mac. Connect with `ssh -A devbox`.

## Steps

1. **Authenticate with GitHub**
   ```bash
   gh auth login
   ```
   - Select GitHub.com
   - Select HTTPS
   - Authenticate via browser (device flow)

2. **Configure git credential helper**
   ```bash
   gh auth setup-git
   ```

3. **Verify agent forwarding works**
   ```bash
   ssh-add -l
   ```
   Should show your Mac's SSH key.

4. **Verify git signing works**
   ```bash
   cd ~/projects && mkdir test-signing && cd test-signing
   git init && echo test > file && git add file
   git commit -m "test signing"
   ```
   Should succeed with SSH signature.

5. **Clean up test**
   ```bash
   rm -rf ~/projects/test-signing
   ```

## Done

After these steps, commits will be signed (when connected with agent forwarding) and pushed via gh credentials.
