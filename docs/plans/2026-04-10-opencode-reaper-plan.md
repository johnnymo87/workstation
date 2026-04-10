# Opencode Reaper + Bazel Remote Cache Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** (1) Automatically kill stale opencode processes that leak memory and accumulate as zombies. (2) Set up GCS-backed Bazel remote cache shared across worktrees and machines.

**Architecture:** A systemd timer fires every 6 hours, running a bash script that identifies and kills stale opencode processes using two heuristics: DB-based session staleness for headless (`-s`) processes, and process age for interactive (bare) processes. SIGKILL is used directly since opencode ignores SIGTERM. Separately, a GCS bucket is created for Bazel remote cache, and `.bazelrc` is updated to use it alongside the existing local disk cache.

**Tech Stack:** Bash, systemd timers, SQLite3 (for DB queries), procps (pgrep/ps), NixOS configuration, GCS, Bazel remote cache.

---

### Task 1: Write the reaper script and systemd service for cloudbox

**Files:**
- Modify: `hosts/cloudbox/configuration.nix` (add after the `nightly-restart-background` timer block, around line 379)

**Step 1: Add the reaper service and timer to cloudbox config**

Add the following NixOS configuration block after the `nightly-restart-background` timer (after line 379 in `hosts/cloudbox/configuration.nix`):

```nix
  # Reap stale opencode processes every 6 hours.
  # Two classes of opencode processes accumulate and leak memory:
  # 1. Headless sessions (opencode -s <id>): /launched from Telegram, often forgotten.
  #    Killed when the session's time_updated in the DB is >24h ago.
  # 2. Interactive sessions (bare opencode): started in tmux, left running.
  #    Killed when the process is >24h old.
  # opencode-serve is excluded (managed by nightly-restart-background).
  # SIGKILL is used directly because opencode ignores SIGTERM.
  systemd.services.reap-stale-opencode = {
    description = "Kill stale opencode processes (>24h idle or old)";
    path = [ pkgs.procps pkgs.gawk pkgs.coreutils pkgs.sqlite ];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
    };
    script = ''
      THRESHOLD_SECONDS=86400  # 24 hours
      NOW=$(date +%s)
      NOW_MS=$((NOW * 1000))
      CUTOFF_MS=$(( (NOW - THRESHOLD_SECONDS) * 1000 ))
      DB="/home/dev/.local/share/opencode/opencode.db"
      KILLED=0

      # Skip if DB doesn't exist
      if [ ! -f "$DB" ]; then
        echo "opencode DB not found at $DB, skipping"
        exit 0
      fi

      # Find all opencode processes (exclude "opencode serve")
      for pid in $(pgrep -f 'opencode' -u dev || true); do
        # Read cmdline
        cmdline=$(tr '\0' ' ' < /proc/$pid/cmdline 2>/dev/null || continue)

        # Skip opencode serve
        if echo "$cmdline" | grep -q 'serve'; then
          continue
        fi

        # Skip non-opencode processes (e.g. grep itself, earlyoom)
        if ! echo "$cmdline" | grep -q '/opencode'; then
          continue
        fi

        # Check if this is a headless session (has -s <session_id>)
        session_id=$(echo "$cmdline" | grep -oP '(?<=-s )\S+' || true)

        if [ -n "$session_id" ]; then
          # Headless session: check DB for session staleness
          last_updated=$(sqlite3 "$DB" \
            "SELECT time_updated FROM session WHERE id = '$session_id';" 2>/dev/null || echo "0")

          if [ -z "$last_updated" ] || [ "$last_updated" = "0" ]; then
            echo "PID $pid: session $session_id not found in DB, killing"
            kill -9 "$pid" 2>/dev/null && KILLED=$((KILLED + 1))
          elif [ "$last_updated" -lt "$CUTOFF_MS" ]; then
            age_hours=$(( (NOW_MS - last_updated) / 1000 / 3600 ))
            echo "PID $pid: session $session_id last updated ''${age_hours}h ago, killing"
            kill -9 "$pid" 2>/dev/null && KILLED=$((KILLED + 1))
          else
            echo "PID $pid: session $session_id is recent, keeping"
          fi
        else
          # Interactive session: check process age
          start_time=$(stat -c %Y /proc/$pid 2>/dev/null || continue)
          age=$((NOW - start_time))

          if [ "$age" -gt "$THRESHOLD_SECONDS" ]; then
            age_hours=$((age / 3600))
            echo "PID $pid: bare opencode process ''${age_hours}h old, killing"
            kill -9 "$pid" 2>/dev/null && KILLED=$((KILLED + 1))
          else
            age_hours=$((age / 3600))
            echo "PID $pid: bare opencode process ''${age_hours}h old, keeping"
          fi
        fi
      done

      echo "Reaped $KILLED stale opencode processes"
    '';
  };

  systemd.timers.reap-stale-opencode = {
    description = "Reap stale opencode processes every 6 hours";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 00/6:30:00";  # Every 6h at :30 past (offset from nightly-restart at :00)
      Persistent = true;
    };
  };
```

**Step 2: Verify the config evaluates**

Run: `nix eval .#nixosConfigurations.cloudbox.config.systemd.services.reap-stale-opencode.description --apply builtins.trace 2>&1 | head -5`

Expected: No evaluation errors.

**Step 3: Commit**

```bash
git add hosts/cloudbox/configuration.nix
git commit -m "feat(cloudbox): add reaper for stale opencode processes

Kills headless (-s) sessions when DB shows >24h idle, and bare
interactive sessions when process age >24h. Runs every 6 hours.
Uses SIGKILL directly since opencode ignores SIGTERM."
```

---

### Task 2: Add the same reaper to devbox

**Files:**
- Modify: `hosts/devbox/configuration.nix` (add after the `nightly-restart-background` timer block, around line 277)

**Step 1: Add the identical reaper config to devbox**

Add the exact same `systemd.services.reap-stale-opencode` and `systemd.timers.reap-stale-opencode` blocks from Task 1 after the `nightly-restart-background` timer in `hosts/devbox/configuration.nix`.

**Step 2: Verify the config evaluates**

Run: `nix eval .#nixosConfigurations.devbox.config.systemd.services.reap-stale-opencode.description --apply builtins.trace 2>&1 | head -5`

Expected: No evaluation errors.

**Step 3: Commit**

```bash
git add hosts/devbox/configuration.nix
git commit -m "feat(devbox): add reaper for stale opencode processes

Same reaper as cloudbox: kills headless sessions idle >24h (DB check)
and bare interactive sessions older than 24h. Runs every 6h."
```

---

### Task 3: Test the reaper manually on cloudbox

**Step 1: Apply the NixOS config**

Run: `sudo nixos-rebuild switch --flake ~/projects/workstation#cloudbox`

Expected: Build succeeds, new service and timer are registered.

**Step 2: Verify the timer is registered**

Run: `systemctl list-timers reap-stale-opencode`

Expected: Timer shows up with next firing time.

**Step 3: Dry-run the reaper to see what it would find**

Run: `sudo systemctl start reap-stale-opencode.service`

Then check the output: `journalctl -u reap-stale-opencode.service --no-pager -n 30`

Expected: Log lines showing each opencode process found, whether it was kept or killed, with reasons.

**Step 4: Verify the current session survived**

Run: `ps aux | grep '[o]pencode' | grep -v serve`

Expected: The current interactive session is still running (it should be <24h old).

**Step 5: Commit (no code change, just verification)**

No commit needed -- this is a verification step.

---

### Task 4: Create GCS bucket for Bazel remote cache

**Files:**
- None (GCP infrastructure, not code)

**Step 1: Create the GCS bucket**

Run:
```bash
gcloud storage buckets create gs://wonder-sandbox-bazel-cache \
  --project=wonder-sandbox \
  --location=us-east1 \
  --uniform-bucket-level-access \
  --public-access-prevention
```

Expected: Bucket created successfully.

**Step 2: Add lifecycle rule to expire old cache entries (90 days)**

Run:
```bash
gcloud storage buckets update gs://wonder-sandbox-bazel-cache \
  --lifecycle-file=/dev/stdin <<'EOF'
{
  "rule": [
    {
      "action": {"type": "Delete"},
      "condition": {"age": 90}
    }
  ]
}
EOF
```

Expected: Lifecycle rule applied.

**Step 3: Verify the bucket**

Run: `gcloud storage ls --project=wonder-sandbox | grep bazel`

Expected: `gs://wonder-sandbox-bazel-cache/`

---

### Task 5: Add remote cache to .bazelrc

**Files:**
- Modify: `users/dev/home.base.nix` (the `.bazelrc` block, around line 237-268)

**Step 1: Add remote cache config to .bazelrc**

In `users/dev/home.base.nix`, modify the `.bazelrc` configuration to add the remote cache line after the existing disk cache line (line 245):

Change:
```nix
      "# Local disk and repository caches"
      "common --disk_cache ~/bazel-diskcache --repository_cache ~/bazel-cache/repository"
```

To:
```nix
      "# Local disk and repository caches"
      "common --disk_cache ~/bazel-diskcache --repository_cache ~/bazel-cache/repository"
      ""
      "# GCS remote cache — shared across worktrees and machines"
      "# Local disk_cache is checked first (fast); remote is fallback + shared warming"
      "common --remote_cache=https://storage.googleapis.com/wonder-sandbox-bazel-cache"
      "common --remote_upload_local_results"
```

Note: `--remote_cache` with `https://storage.googleapis.com/<bucket>` uses GCS's REST API. Bazel uses Application Default Credentials (ADC) automatically, which are already set up on cloudbox via `gcloud auth application-default login`.

**Step 2: Verify the config evaluates**

Run: `nix eval .#homeConfigurations.cloudbox.config.home.file.\".bazelrc\".text 2>&1 | head -20`

Expected: The `.bazelrc` text includes the remote cache line.

**Step 3: Commit**

```bash
git add users/dev/home.base.nix
git commit -m "feat(bazel): add GCS remote cache shared across worktrees

Uses wonder-sandbox-bazel-cache bucket in us-east1. Local disk cache
is checked first for speed; remote cache provides cross-worktree and
cross-machine cache sharing. ADC auth is already configured."
```

---

### Task 6: Apply and test Bazel remote cache

**Step 1: Apply home-manager**

Run: `nix run home-manager -- switch --flake ~/projects/workstation#cloudbox`

Expected: Build succeeds, `.bazelrc` updated.

**Step 2: Verify .bazelrc content**

Run: `cat ~/.bazelrc | grep remote`

Expected: Lines showing `--remote_cache` and `--remote_upload_local_results`.

**Step 3: Test with a Bazel build in the monorepo**

Run a small build in the monorepo to verify cache upload works:

```bash
cd ~/projects/mono && bazel build //some/small:target
```

Then check GCS for cache entries:

```bash
gcloud storage ls gs://wonder-sandbox-bazel-cache/ | head -5
```

Expected: Cache entries appear in the bucket.

**Step 4: Commit (no code change, just verification)**

No commit needed -- this is a verification step.

---

### Task 7: Push and clean up

**Step 1: Push to remote**

```bash
git push
```

**Step 2: Verify**

Run: `git status`

Expected: Clean working tree, up to date with origin.
