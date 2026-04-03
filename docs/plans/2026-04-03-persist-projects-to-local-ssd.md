# Move Projects from Cloud Volume to Local SSD

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Move ~/projects from the 10 GB Hetzner Cloud Volume (/persist) to the 320 GB local SSD, freeing the volume for small durable state only.

**Architecture:** Remove the bind mount from /persist/projects to ~/projects, let ~/projects live on the root filesystem (local SSD), copy existing project data to preserve dirty worktrees, and update ensure-projects to not depend on /persist.

**Tech Stack:** NixOS, disko, Hetzner Cloud CLI (hcloud), systemd tmpfiles

---

## Context

The devbox is a Hetzner CAX41 (16 ARM cores, 32 GB RAM, 320 GB local SSD) running NixOS 24.11. A separate 10 GB Hetzner Cloud Volume is mounted at `/persist` for state that survives nixos-anywhere rebuilds.

Currently, `/persist/projects` is bind-mounted to `~/projects`, but 40+ repos have accumulated (only 8 are declared) filling the volume to 98%. The local SSD has 49 GB free. Projects are reconstructable from git, so they don't need cloud volume durability.

**What stays on /persist:** sops age key, SSH keys, tmux resurrect, claude state, my-podcasts NLTK data.

**What moves to local SSD:** All project repos (~/projects).

**Dirty worktrees to preserve:** anthropic-oauth-proxy, chatgpt-relay, citadels, claude-code-remote, comptes, my-podcasts, opencode, opencode-beads, pigeon, tec-codex.

---

### Task 1: Resize the Hetzner Cloud Volume

Resize from 10 GB to 20 GB for breathing room during migration. Hetzner volumes are grow-only.

**Step 1: Resize via hcloud CLI (run from macOS)**

Run: `hcloud volume resize devbox-persist --size 20`
Expected: Success message

**Step 2: Grow the filesystem on devbox**

Run: `ssh devbox 'sudo resize2fs /dev/sda'`
Expected: Filesystem resized message

**Step 3: Verify**

Run: `ssh devbox 'df -h /persist'`
Expected: Size shows ~20 GB, usage drops to ~50%

---

### Task 2: Modify NixOS config to remove projects bind mount

**Files:**
- Modify: `hosts/devbox/configuration.nix:512-525`

**Step 1: Remove the bind mount and /persist/projects tmpfiles rule**

In `hosts/devbox/configuration.nix`, remove:

```nix
  # Bind mount projects from persistent volume
  fileSystems."/home/dev/projects" = {
    device = "/persist/projects";
    fsType = "none";
    options = [ "bind" ];
    depends = [ "/persist" ];
  };
```

And in the `systemd.tmpfiles.rules` list, remove:
```nix
    # Projects directory on persistent volume
    "d /persist/projects 0755 dev dev -"
```

**Step 2: Add a tmpfiles rule to create ~/projects on root**

In the same `systemd.tmpfiles.rules` block, add:
```nix
    # Projects directory on local SSD (not cloud volume)
    "d /home/dev/projects 0755 dev dev -"
```

---

### Task 3: Update ensure-projects to not require /persist

**Files:**
- Modify: `users/dev/home.devbox.nix:213-217`

**Step 1: Remove the /persist mount check**

The ensure-projects script currently refuses to run if /persist isn't mounted. Since projects no longer live on /persist, remove this check:

```bash
      # Refuse to run if /persist isn't mounted
      if ! ${pkgs.util-linux}/bin/findmnt -rn /persist >/dev/null; then
        echo "ERROR: /persist is not mounted; refusing to clone."
        exit 1
      fi
```

The SSH key check (`~/.ssh/id_ed25519_github`) should remain -- it's still relevant.

**Step 2: Commit the config changes**

```bash
git add hosts/devbox/configuration.nix users/dev/home.devbox.nix
git commit -m "Move projects from cloud volume to local SSD

Projects no longer need cloud volume durability -- they're
reconstructable from git. Moving them to the local SSD frees
the /persist volume for small durable state (keys, tmux, etc.)
and eliminates the 10 GB size constraint."
```

---

### Task 4: Apply NixOS rebuild

**Step 1: Push changes and pull on devbox**

Run from macOS: `git push origin HEAD:main` (or appropriate branch)

Then on devbox:
```bash
ssh devbox 'cd ~/projects/workstation && git pull'
```

**Step 2: Apply system config**

```bash
ssh devbox 'cd ~/projects/workstation && sudo nixos-rebuild switch --flake .#devbox'
```

Expected: Rebuild succeeds. The bind mount is removed. ~/projects is now an empty directory on root.

**Step 3: Apply home-manager config**

```bash
ssh devbox 'cd ~/projects/workstation && nix run home-manager -- switch --flake .#dev'
```

Expected: ensure-projects script is updated (no /persist check).

---

### Task 5: Migrate project data

After the rebuild, ~/projects is empty (on root SSD) and /persist/projects still has all the old data.

**Step 1: Copy all projects from /persist to local SSD**

```bash
ssh devbox 'cp -a /persist/projects/* /home/dev/projects/'
```

This preserves all dirty worktrees. May take a few minutes for 9+ GB of data.

**Step 2: Verify the copy**

```bash
ssh devbox 'ls ~/projects/ | wc -l'  # Should match /persist/projects count
ssh devbox 'df -h / /persist'         # Root usage should increase by ~9 GB
```

**Step 3: Spot-check a dirty worktree**

```bash
ssh devbox 'cd ~/projects/pigeon && git status --porcelain | head -5'
```

Expected: Same dirty state as before migration.

---

### Task 6: Clean up /persist/projects

**Step 1: Remove old project data from cloud volume**

```bash
ssh devbox 'rm -rf /persist/projects'
```

**Step 2: Verify /persist is freed**

```bash
ssh devbox 'df -h /persist'
```

Expected: Usage drops from ~9.1 GB to under 100 MB.

---

### Task 7: Set up /persist backup

Hetzner server snapshots do NOT include cloud volumes. The /persist volume contains the sops age key and SSH keys -- losing these would require manual recovery.

**Step 1: Create a one-time backup script**

Add a simple script that copies critical /persist state to a tarball. This can be run manually before risky operations.

The approach: add a `backup-persist` script to `~/.local/bin/` via home-manager that creates a timestamped tarball of /persist (excluding projects, which no longer exist there).

**Step 2: Consider Hetzner volume snapshots**

Hetzner doesn't have built-in volume snapshot automation, but `hcloud volume` commands could be used. This is optional and can be a follow-up.

---

## Post-Migration Verification Checklist

- [ ] `/persist` usage is under 100 MB
- [ ] `~/projects` is on root filesystem (not a bind mount)
- [ ] All 10 dirty worktrees preserved
- [ ] `ensure-projects` service runs successfully
- [ ] `my-podcasts` services still reference `/persist/my-podcasts/nltk_data` (unchanged)
- [ ] Root filesystem has enough space (should have ~40 GB free after migration)
