# em-ci runners on gamebox, devbox failover — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Run eternal-machinery's self-hosted CI on gamebox (2 runners), with
devbox's runners as a label-gated failover and gamebox's runners paused while a
Sunshine stream is active.

**Design:** `docs/plans/2026-10-11-em-ci-gamebox-design.md` (read it first; this
plan does not repeat the rationale).

**Architecture:** One shared NixOS module (`modules/em-ci-runners.nix`) used by
both hosts. A devbox timer (`em-ci-failover`) reconciles the `em-ci` label on
devbox's runners from gamebox's online status. gamebox gets a flag-file pause
driven by Sunshine's `global_prep_cmd`, plus a small reconciler.

**Tech stack:** NixOS modules, nixos-containers, `services.github-runners`,
sops-nix, bash + jq + curl (writeShellApplication), polkit, Sunshine, GitHub
REST API, eternal-machinery `.github/workflows/ci.yml`.

**Repos:** workstation (`~/Code/workstation` on the Mac,
`~/projects/workstation` on devbox) and eternal-machinery. Work in worktrees.
Never `gh pr merge`; follow `shepherding-pull-requests` for every PR.

**Hosts / where to run things:**
- Eval-only checks run anywhere with Nix (`nix eval`), including the Mac.
- devbox deploys: on devbox, `sudo nixos-rebuild switch --flake .#devbox`.
- gamebox deploys: on gamebox itself (devbox is aarch64 and cannot build
  x86_64): `ssh gamebox`, then `sudo nixos-rebuild switch --flake .#gamebox`.
- `nix flake check --keep-going` (never `--no-build`) before each PR.

**PR boundaries** (each independently revertible):

| PR | Repo | Tasks | Behaviour change |
|---|---|---|---|
| 1 | workstation | 1 | none (devbox toplevel drvPath identical) |
| 2 | eternal-machinery | 2 | none while only devbox runners exist |
| 3 | workstation | 3–5 | gamebox runners online; both hosts take jobs |
| 4 | workstation | 6–9 | devbox runners label-gated |
| 5 | workstation | 10–12 | streaming pause |
| 6 | eternal-machinery | 13 | drop old `HEAVY_RUNNER` value |

---

## PR 1 — shared module, no behaviour change

### Task 1: Extract `modules/em-ci-runners.nix`

**Files:**
- Create: `modules/em-ci-runners.nix`
- Modify: `hosts/devbox/em-ci.nix` (becomes a thin host config)
- Modify: `flake.nix:2509-2526` (only if the import path changes; keep
  `./hosts/devbox/em-ci.nix` in the module list and import the shared module
  from it)

**Step 1: Record the oracle.** From a clean checkout of `origin/main`:

```bash
nix eval --raw .#nixosConfigurations.devbox.config.system.build.toplevel.drvPath > /tmp/em-ci-before.drv
cat /tmp/em-ci-before.drv
```

The refactor is correct iff the same command prints the **same path** afterwards.
Any difference means behaviour changed; diff with
`nix-diff $(cat /tmp/em-ci-before.drv) <after>` to find out where.

**Step 2: Write the module.** Move the body of `hosts/devbox/em-ci.nix` into
`modules/em-ci-runners.nix`, behind `options.services.em-ci-runners`, keeping
the long explanatory comments with the code they explain. Options (all with
the devbox values as nothing — no defaults that hide host choices except where
noted):

```nix
{ config, lib, pkgs, nixpkgs-unstable, devenvPkg, ... }:
let
  cfg = config.services.em-ci-runners;
  inherit (lib) mkOption mkEnableOption mkIf types;
in {
  options.services.em-ci-runners = {
    enable = mkEnableOption "eternal-machinery self-hosted runner containers";
    runners = mkOption {
      type = types.attrsOf (types.submodule {
        options = {
          n = mkOption { type = types.int; };
          hostAddress = mkOption { type = types.str; };
          localAddress = mkOption { type = types.str; };
        };
      });
      description = "Container name -> addressing. Names <= 11 chars (ve-<name>) and must match em-ci-* (egress fence pattern).";
    };
    namePrefix = mkOption { type = types.str; description = "GitHub runner name prefix, e.g. devbox -> devbox-em-ci-1."; };
    cpus = mkOption { type = types.int; };
    memoryMax = mkOption { type = types.str; };
    stateDevice = mkOption { type = types.nullOr types.str; default = null; };
    externalInterface = mkOption { type = types.nullOr types.str; default = null;
      description = "NAT egress interface; null masquerades on every out-interface."; };
    nameservers = mkOption { type = types.listOf types.str; default = [ "1.1.1.1" "9.9.9.9" "1.0.0.1" ]; };
    patSecret = mkOption { type = types.str; default = "em_ci_runner_pat"; };
    watchdogMinFreeGiB = mkOption { type = types.int; default = 10; };
    pauseFlag = mkOption { type = types.nullOr types.str; default = null;
      description = "If set, container units carry ConditionPathExists=!<flag> (used by gamebox's streaming pause)."; };
  };
  config = mkIf cfg.enable { /* body of today's em-ci.nix, parameterised */ };
}
```

Parameterise exactly these sites from today's `hosts/devbox/em-ci.nix`:

| Today | Becomes |
|---|---|
| `runners = { em-ci-1 = …; em-ci-2 = …; }` (L57-60) | `cfg.runners` |
| `watchdogMinFreeGiB = 10` (L71) | `cfg.watchdogMinFreeGiB` |
| `networking.nameservers = [ … ]` (L98) | `cfg.nameservers` |
| `name = "devbox-em-ci-${toString r.n}"` (L126) | `"${cfg.namePrefix}-em-ci-${toString r.n}"` |
| `EM_CI_CPUS = "4"` (L143) | `toString cfg.cpus` |
| `fileSystems."/var/lib/nixos-containers"` (L188-192) | wrapped in `lib.mkIf (cfg.stateDevice != null)`, `device = cfg.stateDevice` |
| `unitConfig.RequiresMountsFor` (L227) | only when `cfg.stateDevice != null` |
| `sops.secrets.em_ci_runner_pat` (L202) and `config.sops.secrets.em_ci_runner_pat.path` (L220) | `sops.secrets.${cfg.patSecret}` |
| `externalInterface = "enp1s0"` (L212) | `cfg.externalInterface` |
| `CPUQuota = "400%"; MemoryMax = "6G";` (L235-236) | `"${toString (cfg.cpus * 100)}%"`, `cfg.memoryMax` |
| (new) | `unitConfig.ConditionPathExists = lib.mkIf (cfg.pauseFlag != null) "!${cfg.pauseFlag}"` on each `container@` unit |

The `/tmp/credo-diff-*` tmpfiles rule (L335-339) is devbox-only and unrelated
to CI: leave it in `hosts/devbox/em-ci.nix`, not the module.

Rename the watchdog log/description strings only if the drvPath oracle still
matches — i.e. **don't** rename anything in this task.

**Step 3: Rewrite `hosts/devbox/em-ci.nix`:**

```nix
# devbox's em-ci runners. Implementation and rationale:
# modules/em-ci-runners.nix. Design: docs/plans/2026-10-11-em-ci-gamebox-design.md.
{ ... }:
{
  imports = [ ../../modules/em-ci-runners.nix ];

  services.em-ci-runners = {
    enable = true;
    namePrefix = "devbox";
    runners = {
      em-ci-1 = { n = 1; hostAddress = "10.233.71.1"; localAddress = "10.233.71.2"; };
      em-ci-2 = { n = 2; hostAddress = "10.233.71.5"; localAddress = "10.233.71.6"; };
    };
    cpus = 4;
    memoryMax = "6G";
    stateDevice = "/dev/disk/by-id/scsi-0HC_Volume_107073920";
    externalInterface = "enp1s0";
  };

  # Local `mix credo` diff runs leave /tmp/credo-diff-<ts> checkouts behind
  # (~2 GB/day). Age out their contents after a day; the empty dirs remain.
  systemd.tmpfiles.rules = [ "e /tmp/credo-diff-* - - - 1d" ];
}
```

(`externalInterface` stays `enp1s0` on devbox in this PR so the drvPath is
unchanged; gamebox uses `null`.)

**Step 4: Verify the oracle.**

```bash
nix eval --raw .#nixosConfigurations.devbox.config.system.build.toplevel.drvPath
```

Expected: byte-identical to `/tmp/em-ci-before.drv`. If not, `nix-diff` and fix
until it is. Do not proceed with a differing drvPath.

**Step 5: `nix flake check --keep-going`.** Expected: pass.

**Step 6: Commit** — `refactor(em-ci): extract runner containers into a shared module`.

**Step 7: PR 1** via `shepherding-pull-requests`. Body states the drvPath
identity as the evidence of no behaviour change. Deploying it to devbox is a
no-op switch.

---

## PR 2 — eternal-machinery: stop requesting an arch label

### Task 2: Accept both `HEAVY_RUNNER` values

**Files:**
- Modify: `.github/workflows/ci.yml` (runner selection, ~L200-260 on `origin/main`)
- Modify: `docs/runbooks/ci-self-hosted.md` (new value; gamebox + devbox failover)

**Step 1:** In a worktree of eternal-machinery, read L200-260 of
`.github/workflows/ci.yml`. Today: `selfhosted='["self-hosted","em-ci","ARM64"]'`
(L221) and `HEAVY_RUNNER` is validated by exact match (L233-239).

**Step 2:** Change to:

```bash
selfhosted='["self-hosted","em-ci"]'
legacy_selfhosted='["self-hosted","em-ci","ARM64"]'   # remove in a follow-up PR once the repo variable is flipped
```

and in the `HEAVY_RUNNER` `case`, add an arm that maps
`"$legacy_selfhosted"` to `r=$selfhosted` (whitespace-stripped comparison, same
as the existing arms). Leave every other arm untouched.

**Step 3:** Test locally by extracting the selection script into a temp file
and running it with each input:

| `FORCE_HOSTED` | `HEAVY_RUNNER` | expected `runner` output |
|---|---|---|
| (unset) | `["self-hosted","em-ci","ARM64"]` | `["self-hosted","em-ci"]` |
| (unset) | `["self-hosted","em-ci"]` | `["self-hosted","em-ci"]` |
| (unset) | `"ubuntu-latest"` | hosted value (unchanged) |
| (unset) | `garbage` | `::error` + exit 1 (unchanged) |
| `true` | anything | hosted (unchanged) |

**Step 4:** Update the runbook: runners now live on gamebox (primary) and devbox
(failover via label); `FORCE_HOSTED=true` still the escape hatch; new
`HEAVY_RUNNER` value.

**Step 5:** Commit, PR, shepherd. After merge, flip the variable:

```bash
gh variable set HEAVY_RUNNER -R johnnymo87/eternal-machinery --body '["self-hosted","em-ci"]'
gh variable get HEAVY_RUNNER -R johnnymo87/eternal-machinery
```

Then confirm the next CI run's `changes` job logs `["self-hosted","em-ci"]` and
its heavy jobs land on `devbox-em-ci-*`.

---

## PR 3 — gamebox runners

### Task 3: gamebox sops recipient + PAT

**Manual step (owner):** mint a fine-grained PAT: repository
`johnnymo87/eternal-machinery` only, permission **Administration: read and
write**, no expiry (same shape as devbox's, design §Decisions). Hand it over
out-of-band; never paste into a commit, PR, or shell history.

**Files:**
- Modify: `secrets/.sops.yaml`
- Create: `secrets/gamebox.yaml`
- Modify: `secrets/README.md` (table row)

**Step 1: Derive gamebox's age recipient from its SSH host key** (no private
key leaves gamebox):

```bash
ssh gamebox cat /etc/ssh/ssh_host_ed25519_key.pub | nix run nixpkgs#ssh-to-age
```

**Step 2:** Add to `secrets/.sops.yaml`:

```yaml
  - &gamebox age1...   # from step 1; derived from gamebox's SSH host key
...
  - path_regex: gamebox\.yaml$
    key_groups:
      - age:
          - *gamebox
          - *devbox     # so the owner can edit it from devbox
```

**Step 3: Create the file.** Encryption needs only public keys, so this works on
any host. Write the plaintext to a 0600 temp file, never argv. Pass recipients
explicitly: `--config` creation rules match `path_regex` against the *input*
path (the temp file), so they would not match. The rule added in step 2 is for
later `sops updatekeys` / edits of `secrets/gamebox.yaml`.

```bash
umask 077; t=$(mktemp)
printf 'em_ci_runner_pat: %s\n' "$(cat /path/to/pat-file)" > "$t"
GAMEBOX_AGE=age1...   # step 1
DEVBOX_AGE=age1kyd7dzxtgte0rcd0nj3chfvcfvammhywe63f25tlsrf8knhf3u8sxp8z9n   # from secrets/.sops.yaml
sops -e --age "$GAMEBOX_AGE,$DEVBOX_AGE" --input-type yaml --output-type yaml "$t" > secrets/gamebox.yaml
rm -f "$t"
grep -c ENC secrets/gamebox.yaml   # expect 1
sops --config secrets/.sops.yaml updatekeys -y secrets/gamebox.yaml   # expect "already up to date" (rule and file agree)
```

**Step 4:** Verify recipients: `grep -A1 'recipient' secrets/gamebox.yaml`
lists exactly the two age keys.

**Step 5:** Commit — `secrets: add gamebox sops file with em-ci runner PAT`.

### Task 4: gamebox runner config

**Files:**
- Modify: `flake.nix` (`nixosConfigurations.gamebox`, ~L2544)
- Create: `hosts/gamebox/em-ci.nix`
- Modify: `hosts/gamebox/configuration.nix` (sops)

**Step 1: flake.** In `nixosConfigurations.gamebox`:

```nix
specialArgs = {
  inherit (inputs) nixpkgs-unstable;
  devenvPkg = devenv.packages."x86_64-linux".devenv;
};
modules = [
  disko.nixosModules.disko
  sops-nix.nixosModules.sops
  ./hosts/gamebox/configuration.nix
  ./hosts/gamebox/hardware.nix
  ./hosts/gamebox/disko.nix
  ./hosts/gamebox/streaming.nix
  ./hosts/gamebox/em-ci.nix
];
```

**Step 2: sops on gamebox** (`configuration.nix`):

```nix
sops = {
  defaultSopsFile = ../../secrets/gamebox.yaml;
  # Decrypt with the host SSH key; no separate age key file to provision.
  age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
};
```

**Step 3: `hosts/gamebox/em-ci.nix`:**

```nix
# gamebox's em-ci runners: the primary pool. devbox's runners are a label-gated
# failover (hosts/devbox/em-ci-failover.nix). Design:
# docs/plans/2026-10-11-em-ci-gamebox-design.md.
{ ... }:
{
  imports = [ ../../modules/em-ci-runners.nix ];

  services.em-ci-runners = {
    enable = true;
    namePrefix = "gamebox";
    runners = {
      em-ci-1 = { n = 1; hostAddress = "10.233.71.1"; localAddress = "10.233.71.2"; };
      em-ci-2 = { n = 2; hostAddress = "10.233.71.5"; localAddress = "10.233.71.6"; };
    };
    cpus = 3;
    memoryMax = "5G";
    stateDevice = null;          # root NVMe; the disk watchdog guards it
    externalInterface = null;    # Ethernet or Wi-Fi, whichever is up
  };

  # Builds the containers request run in nix-daemon's cgroup, outside the
  # container caps. Max-only (no MemoryHigh): a throttled daemon is the
  # alive-but-frozen trap. If a gamebox rebuild itself (Sunshine+CUDA compiles
  # locally) hits this, lift it for that one rebuild:
  #   sudo systemctl set-property --runtime nix-daemon MemoryMax=infinity
  systemd.services.nix-daemon.serviceConfig = {
    MemoryMax = "3G";
    CPUQuota = "400%";
  };
  nix.settings = { max-jobs = 2; cores = 4; };
}
```

Also update the module's RUNNER VERSION comment (moved from `em-ci.nix:38-46`):
the monthly `nix flake update nixpkgs-unstable` rebuilds gamebox's Sunshine
locally, so lift the nix-daemon cap on gamebox for that switch, and check the
runner version on both hosts (`.#nixosConfigurations.{devbox,gamebox}…`).

**Step 4: Eval.**

```bash
nix eval --raw .#nixosConfigurations.gamebox.config.system.build.toplevel.drvPath
nix eval --json .#nixosConfigurations.gamebox.config.containers --apply 'builtins.attrNames'
# expect ["em-ci-1","em-ci-2"]
nix eval --raw .#nixosConfigurations.gamebox.config.containers.em-ci-1.config.services.github-runners.em-ci.name
# expect gamebox-em-ci-1
nix eval --raw .#nixosConfigurations.devbox.config.system.build.toplevel.drvPath
# expect unchanged from PR 1
```

**Step 5:** `nix flake check --keep-going`. Commit —
`feat(gamebox): em-ci runner containers`. Open PR 3 (Task 5's verification
results go in its description before asking for review).

### Task 5: Deploy and verify on gamebox

**Step 1:** On gamebox, check out the PR branch and
`sudo nixos-rebuild switch --flake .#gamebox`. The first switch does not yet
have the nix-daemon cap. For any LATER switch that rebuilds Sunshine (CUDA
compiles locally; e.g. after `nix flake update nixpkgs-unstable` for the
monthly runner bump), first lift the cap:
`sudo systemctl set-property --runtime nix-daemon MemoryMax=infinity CPUQuota=`.

**Step 2:** Secret and fence:

```bash
sudo ls -l /run/secrets/em_ci_runner_pat                     # root 0400
sudo iptables -t mangle -S PREROUTING | grep em-ci           # hook present
sudo nixos-container run em-ci-1 -- curl -sm3 http://10.233.71.1:22; echo $?   # 28 (dropped)
sudo nixos-container run em-ci-1 -- runuser -u em-ci -- cat /run/em-ci/pat     # permission denied
```

**Step 3: DNS on the current network** (office guest Wi-Fi may block :53 to
public resolvers):

```bash
sudo nixos-container run em-ci-1 -- getent hosts github.com
sudo nixos-container run em-ci-1 -- curl -sIm5 https://api.github.com | head -1   # HTTP/2 200
```

If DNS fails: STOP and report. The fix (host forwarder on `hostAddress` + a
port-53 exception in the fence ahead of the LOCAL drop) changes the fence and
needs its own review.

**Step 4: Runners online:**

```bash
gh api repos/johnnymo87/eternal-machinery/actions/runners --jq '.runners[]|.name+" "+.status+" "+([.labels[].name]|join(","))'
```

Expect `gamebox-em-ci-1/2 online` with `self-hosted,Linux,X64,em-ci`, and the
devbox runners still online.

**Step 5: A full CI run on x86_64.** Trigger a FRESH run (not "re-run failed
jobs", which reuses the old `changes` output, possibly from before the
variable flip): `gh workflow run ci.yml -R johnnymo87/eternal-machinery --ref main`. Confirm at least one heavy job ran on `gamebox-em-ci-*` and passed
(`gh run view <id> --json jobs --jq '.jobs[]|.name+" "+.runner_name+" "+.conclusion'`).
Arch-only failures here are design-relevant: report them, don't paper over them.

**Step 6:** Record results in PR 3's description; shepherd it.

---

## PR 4 — devbox failover reconciler

### Task 6: Reconciler script, test-first

**Files:**
- Create: `hosts/devbox/em-ci-failover.sh`
- Create: `hosts/devbox/test-em-ci-failover.sh`

**Interface.** Environment (set by the unit): `EM_CI_REPO`,
`EM_CI_PRIMARY_PREFIX` (`gamebox-`), `EM_CI_FALLBACK_RUNNERS` (space-separated:
`devbox-em-ci-1 devbox-em-ci-2`), `EM_CI_LABEL` (`em-ci`), `EM_CI_TICKS` (`3`),
`EM_CI_ERROR_ALERT` (`10`), `EM_CI_PRIMARY_OFFLINE_ALERT_H` (`6`),
`STATE_DIRECTORY`, `CREDENTIALS_DIRECTORY` (`gh_token`, `tg_bot_token`,
`tg_chat_id`). Test seams: `EM_CI_GH_API_STUB` and `EM_CI_TG_STUB` — if set,
called instead of curl with the same arguments. `EM_CI_NOW` overrides `date +%s`.

**Step 1: Write the failing test** `hosts/devbox/test-em-ci-failover.sh`. Shape,
following `users/dev/test-disk-watch.sh` (a `check` helper that counts and
prints `ALL PASS (N assertions)` at the end):

```bash
#!/usr/bin/env bash
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
pass=0; fail=0
check() { if eval "$2"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; fi; }

# Build a runnable copy the way writeShellApplication would.
# Absolute shebangs: the flake-check sandbox has no /usr/bin/env
# (same trap as users/dev/test-disk-watch.sh:121-125).
bash_bin=$(command -v bash)
bin=$(mktemp); { echo "#!$bash_bin"; echo 'set -euo pipefail'; cat "$here/em-ci-failover.sh"; } >"$bin"; chmod +x "$bin"

setup() { # fresh sandbox per case
  S=$(mktemp -d); export STATE_DIRECTORY=$S/state CREDENTIALS_DIRECTORY=$S/cred
  mkdir -p "$STATE_DIRECTORY" "$CREDENTIALS_DIRECTORY"
  echo tok >"$CREDENTIALS_DIRECTORY/gh_token"; echo bot >"$CREDENTIALS_DIRECTORY/tg_bot_token"; echo 1 >"$CREDENTIALS_DIRECTORY/tg_chat_id"
  export EM_CI_REPO=o/r EM_CI_PRIMARY_PREFIX=gamebox- EM_CI_FALLBACK_RUNNERS="devbox-em-ci-1 devbox-em-ci-2" \
         EM_CI_LABEL=em-ci EM_CI_TICKS=3 EM_CI_ERROR_ALERT=10 EM_CI_PRIMARY_OFFLINE_ALERT_H=6 EM_CI_NOW=1000000
  # Stub: GET answers from $S/runners.json (or fails if $S/api_down exists);
  # writes are appended to $S/writes.
  cat >"$S/gh" <<EOF
#!$bash_bin
[ -e "$S/api_down" ] && exit 22
case "\$1" in GET) cat "$S/runners.json" ;; *) echo "\$*" >>"$S/writes" ;; esac
EOF
  printf '#!%s\necho "$1" >>"%s/tg"\n' "$bash_bin" "$S" >"$S/tgs"
  chmod +x "$S/gh" "$S/tgs"; export EM_CI_GH_API_STUB=$S/gh EM_CI_TG_STUB=$S/tgs
}
runners() { # $1: gamebox status, $2: devbox labels json array (e.g. '["em-ci"]' or '[]')
  jq -n --arg g "$1" --argjson d "$2" '{runners:[
    {id:1,name:"gamebox-em-ci-1",status:$g,busy:false,labels:[{name:"em-ci"}]},
    {id:11,name:"devbox-em-ci-1",status:"online",busy:false,labels:($d|map({name:.}))},
    {id:12,name:"devbox-em-ci-2",status:"online",busy:false,labels:($d|map({name:.}))}]}' >"$S/runners.json"
}
tick() { "$bin"; }
writes() { cat "$S/writes" 2>/dev/null || true; }

# 1. Empty state, gamebox online once: desired stays present; label already present -> no writes.
setup; runners online '["em-ci"]'; tick
check "initial desired present" '[ "$(cat $STATE_DIRECTORY/desired)" = present ]'
check "no writes when no drift" '[ -z "$(writes)" ]'

# 2. Online for 3 ticks -> desired absent -> DELETE on both devbox runners, one Telegram.
setup; runners online '["em-ci"]'; tick; tick; tick
check "absent after 3 online" '[ "$(cat $STATE_DIRECTORY/desired)" = absent ]'
check "deleted label on runner 11" 'grep -q "DELETE /repos/o/r/actions/runners/11/labels/em-ci" <<<"$(writes)"'
check "deleted label on runner 12" 'grep -q "DELETE /repos/o/r/actions/runners/12/labels/em-ci" <<<"$(writes)"'
check "one transition message" '[ "$(wc -l <"$S/tg")" -eq 1 ]'

# 3. Absent, label already gone -> next tick no writes.
: >"$S/writes"; runners online '[]'; tick
check "no writes once converged" '[ -z "$(writes)" ]'

# 4. Then offline for 2 ticks -> unchanged; 3rd -> present, POST on both.
runners offline '[]'; tick; tick
check "hysteresis holds at 2" '[ "$(cat $STATE_DIRECTORY/desired)" = absent ]'
tick
check "present after 3 offline" '[ "$(cat $STATE_DIRECTORY/desired)" = present ]'
check "posted label on 11" 'grep -q "POST /repos/o/r/actions/runners/11/labels" <<<"$(writes)"'

# 5. Mixed sequence resets the streak.
setup; runners online '["em-ci"]'; tick; tick; runners offline '["em-ci"]'; tick; runners online '["em-ci"]'; tick; tick
check "streak reset by an offline tick" '[ "$(cat $STATE_DIRECTORY/desired)" = present ]'

# 6. Drift: desired absent but a re-registration put the label back -> DELETE again.
setup; runners online '["em-ci"]'; tick; tick; tick; : >"$S/writes"; tick
check "re-asserts after drift" 'grep -q "DELETE /repos/o/r/actions/runners/11/labels/em-ci" <<<"$(writes)"'

# 7. API down: no state change, no writes; alert exactly once at 10 errors.
setup; runners online '["em-ci"]'; tick; touch "$S/api_down"
for _ in 1 2 3 4 5 6 7 8 9; do tick; done
check "no alert before 10 errors" '[ ! -e "$S/tg" ]'
tick
check "alert at 10 errors" '[ "$(grep -c "cannot reach the GitHub API" "$S/tg")" -eq 1 ]'
tick
check "not repeated at 11" '[ "$(grep -c "cannot reach the GitHub API" "$S/tg")" -eq 1 ]'
check "desired unchanged while API down" '[ "$(cat $STATE_DIRECTORY/desired)" = present ]'

# 8. Primary offline > 6 h -> one alert; clears when back online.
setup; runners offline '["em-ci"]'; tick
EM_CI_NOW=$((1000000 + 6*3600)) tick
check "offline-6h alert" '[ "$(grep -c "offline for" "$S/tg")" -eq 1 ]'
EM_CI_NOW=$((1000000 + 7*3600)) tick
check "offline-6h alert not repeated" '[ "$(grep -c "offline for" "$S/tg")" -eq 1 ]'

# 9. Missing fallback runner: skipped, no crash.
setup; jq -n '{runners:[{id:1,name:"gamebox-em-ci-1",status:"online",busy:false,labels:[]}]}' >"$S/runners.json"
check "missing fallback runner tolerated" 'tick; tick; tick'

[ "$fail" -eq 0 ] || { echo "FAILED $fail"; exit 1; }
echo "ALL PASS ($pass assertions)"
```

**Step 2: Run, expect failure** (`em-ci-failover.sh` does not exist):
`bash hosts/devbox/test-em-ci-failover.sh` → error.

**Step 3: Implement** `hosts/devbox/em-ci-failover.sh`:

```bash
# shellcheck shell=bash
# em-ci failover: one reconcile pass. Wrapped by writeShellApplication in
# em-ci-failover.nix (PATH + set -euo pipefail). Design:
# docs/plans/2026-10-11-em-ci-gamebox-design.md, "Failover reconciler".
#
# Keeps the em-ci label on devbox's runners ABSENT while gamebox's runners are
# online and PRESENT while they are offline, with EM_CI_TICKS of hysteresis.
# Labels gate assignment only, so removing one never touches an in-flight job.
# Writes only on drift: a re-registration resets labels to the configured set,
# so desired state is compared every pass, but DELETE of an absent label 404s.

cred() { cat "${CREDENTIALS_DIRECTORY:?}/$1"; }
now=${EM_CI_NOW:-$(date +%s)}
S=${STATE_DIRECTORY:?}

gh_api() { # $1 method, $2 path, [$3 json body]
  if [ -n "${EM_CI_GH_API_STUB:-}" ]; then "$EM_CI_GH_API_STUB" "$@"; return; fi
  local body=()
  [ -z "${3:-}" ] || body=(--data-raw "$3")
  printf 'header = "Authorization: Bearer %s"\n' "$(cred gh_token)" |
    curl -fsS -m 30 --retry 2 -X "$1" \
      -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" \
      "${body[@]}" -K - "https://api.github.com$2"
}
tg_send() {
  if [ -n "${EM_CI_TG_STUB:-}" ]; then "$EM_CI_TG_STUB" "$1"; return; fi
  printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$(cred tg_bot_token)" |
    curl -fsS -m 20 --retry 3 -o /dev/null \
      --data-urlencode "chat_id=$(cred tg_chat_id)" --data-urlencode "text=$1" -K - || true
}
get() { cat "$S/$1" 2>/dev/null || echo "$2"; }
put() { printf '%s\n' "$2" >"$S/$1"; }

desired=$(get desired present)
on=$(get on 0); off=$(get off 0); errors=$(get errors 0)
offline_since=$(get offline_since ""); offline_alerted=$(get offline_alerted 0)

if ! runners=$(gh_api GET "/repos/$EM_CI_REPO/actions/runners?per_page=100") ||
   ! jq -e '.runners | type == "array"' >/dev/null <<<"$runners"; then
  errors=$((errors + 1)); put errors "$errors"
  [ "$errors" -ne "$EM_CI_ERROR_ALERT" ] ||
    tg_send "em-ci failover (devbox): cannot reach the GitHub API for $errors passes; devbox runner labels frozen at '$desired'."
  exit 0
fi
put errors 0

if jq -e --arg p "$EM_CI_PRIMARY_PREFIX" \
     'any(.runners[]; (.name | startswith($p)) and .status == "online")' >/dev/null <<<"$runners"; then
  on=$((on + 1)); off=0; offline_since=""; offline_alerted=0
else
  off=$((off + 1)); on=0; [ -n "$offline_since" ] || offline_since=$now
fi

if [ "$desired" = present ] && [ "$on" -ge "$EM_CI_TICKS" ]; then
  desired=absent
  tg_send "em-ci failover: gamebox runners online; devbox runners stop taking em-ci jobs (label removed, in-flight jobs finish)."
elif [ "$desired" = absent ] && [ "$off" -ge "$EM_CI_TICKS" ]; then
  desired=present
  tg_send "em-ci failover: gamebox runners offline; devbox runners now take em-ci jobs."
fi

if [ -n "$offline_since" ] && [ "$offline_alerted" = 0 ] &&
   [ $((now - offline_since)) -ge $((EM_CI_PRIMARY_OFFLINE_ALERT_H * 3600)) ]; then
  tg_send "em-ci failover: gamebox runners offline for $(( (now - offline_since) / 3600 )) h (a streaming pause cannot last that long). devbox is carrying CI."
  offline_alerted=1
fi

for name in $EM_CI_FALLBACK_RUNNERS; do
  row=$(jq -c --arg n "$name" --arg l "$EM_CI_LABEL" \
    '[.runners[] | select(.name == $n) | {id, has: ([.labels[].name] | index($l) != null)}][0] // empty' <<<"$runners")
  [ -n "$row" ] || continue   # missing runner: em-ci-monitor reports it
  id=$(jq -r .id <<<"$row"); has=$(jq -r .has <<<"$row")
  if [ "$desired" = present ] && [ "$has" = false ]; then
    gh_api POST "/repos/$EM_CI_REPO/actions/runners/$id/labels" "{\"labels\":[\"$EM_CI_LABEL\"]}" >/dev/null || true
  elif [ "$desired" = absent ] && [ "$has" = true ]; then
    gh_api DELETE "/repos/$EM_CI_REPO/actions/runners/$id/labels/$EM_CI_LABEL" >/dev/null || true
  fi
done

put desired "$desired"; put on "$on"; put off "$off"
put offline_since "$offline_since"; put offline_alerted "$offline_alerted"
```

(Failed writes are retried naturally next pass, because drift is recomputed
from the GET each time.)

**Step 4: Run tests** → `ALL PASS (N assertions)`. Run `shellcheck` on both
files (writeShellApplication will anyway). Also run
`bash users/dev/test-pipefail-inversion.sh` — the tests use here-strings, not
`printf | grep -q`, deliberately.

**Step 5: Commit** — `feat(em-ci): devbox failover label reconciler + tests`.

### Task 7: Unit, timer, flake check

**Files:**
- Create: `hosts/devbox/em-ci-failover.nix`
- Modify: `flake.nix` (devbox modules list; new `checks` entry)

**Step 1: `hosts/devbox/em-ci-failover.nix`** — mirror `em-ci-monitor.nix`'s
hardening exactly (DynamicUser, ProtectSystem=strict, etc.), plus:

```nix
let
  failover = pkgs.writeShellApplication {
    name = "em-ci-failover";
    runtimeInputs = with pkgs; [ coreutils curl jq ];
    text = builtins.readFile ./em-ci-failover.sh;
  };
in {
  systemd.services.em-ci-failover = {
    description = "em-ci: gate devbox runners' em-ci label on gamebox's runners";
    after = [ "network-online.target" ]; wants = [ "network-online.target" ];
    environment = {
      EM_CI_REPO = "johnnymo87/eternal-machinery";
      EM_CI_PRIMARY_PREFIX = "gamebox-";
      EM_CI_FALLBACK_RUNNERS = "devbox-em-ci-1 devbox-em-ci-2";
      EM_CI_LABEL = "em-ci";
      EM_CI_TICKS = "3";
      EM_CI_ERROR_ALERT = "10";
      EM_CI_PRIMARY_OFFLINE_ALERT_H = "6";
    };
    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.getExe failover;
      TimeoutStartSec = "5min";   # 1 GET + 2 writes, each up to 30 s x 3 attempts
      DynamicUser = true;
      StateDirectory = "em-ci-failover";
      LoadCredential = [
        # Administration: write is needed for label edits; the monitor's token is read-only.
        "gh_token:${config.sops.secrets.em_ci_runner_pat.path}"
        "tg_bot_token:${config.sops.secrets.telegram_bot_token.path}"
        "tg_chat_id:${config.sops.secrets.telegram_chat_id.path}"
      ];
      # ... same hardening block as em-ci-monitor.nix L76-86
    };
  };
  systemd.timers.em-ci-failover = {
    wantedBy = [ "timers.target" ];
    timerConfig = { OnBootSec = "2min"; OnUnitActiveSec = "1min"; AccuracySec = "5s"; };
  };
}
```

**Step 2:** Add `./hosts/devbox/em-ci-failover.nix` to devbox's modules in
`flake.nix`. Add a check, pinned count, following
`checks.pressure-sampler-tests` (flake.nix ~L506):

```nix
em-ci-failover-tests = devboxPkgs.runCommand "em-ci-failover-tests" {
  nativeBuildInputs = with devboxPkgs; [ bash coreutils gnugrep jq ];
} ''
  cd ${self}
  bash hosts/devbox/test-em-ci-failover.sh 2>&1 | tee "$TMPDIR/f.txt"
  grep -q '^ALL PASS (N assertions)' "$TMPDIR/f.txt" || {
    echo "GATE FAILURE: em-ci-failover suite did not reach ALL PASS (N assertions)." >&2
    exit 1
  }
  touch $out
'';
```

(Replace `N` with the actual count from Task 6.) Check that
`users/dev/test-unwired-tests.sh` (if it guards unwired test files) is happy.

**Step 3:** `nix flake check --keep-going`. Commit.

### Task 8: Monitor changes

**Files:**
- Modify: `hosts/devbox/em-ci-monitor.sh`, `hosts/devbox/em-ci-monitor.nix`

Changes (keep each small; the monitor's heartbeat contract is untouched):

1. Message heads `em-ci (devbox CI runners)` → `em-ci (CI runners)`.
2. Per-name offline loop (L85-88) stays on `EM_CI_RUNNERS` = devbox runners
   only. gamebox runners are **not** added: offline is a normal paused state,
   and the 6 h alert lives in the reconciler.
3. New check after the watchdog check (L181-183):

   ```bash
   if systemctl is-failed --quiet em-ci-failover.service; then
     add "failover" "em-ci-failover failed (devbox runner labels not reconciled)"
   fi
   last=$(systemctl show -p LastTriggerUSecMonotonic --value em-ci-failover.timer)
   # 0 = never triggered since boot; alert only after boot grace (monitor's own OnBootSec is 10 min)
   ```

   Use `systemctl show -p LastTriggerUSec --value em-ci-failover.timer`, parse
   with `date -d`, and alert (`key failover:stale`) if older than 5 min. Test
   the parse on devbox by hand with the dry-run unit before relying on it.
4. The "stuck queue" logic already counts only runners carrying `em-ci`
   (`idle_em_ci_runners`, L75-79), so label-stripped devbox runners correctly
   stop counting as idle. No change; add a one-line comment saying so.

Verify with `sudo systemctl start em-ci-monitor-dry-run` after deploy (Task 9).
Commit — `feat(em-ci-monitor): watch the failover reconciler`.

### Task 9: Deploy to devbox and measure

**Prereq:** devbox healthy (it was not on 2026-10-11; don't deploy into a
thrashing host), AND eternal-machinery PR 2 (#686) merged. Before #686, jobs
request `ARM64`, which only devbox's runners carry; stripping their `em-ci`
while gamebox (X64) is online would leave every self-hosted job unmatched.
Runs created before #686 keep requesting `ARM64` on "re-run failed jobs":
re-run them fresh instead.

**Step 1:** PR 4 branch on devbox; `sudo nixos-rebuild switch --flake .#devbox`.

**Step 2:** `journalctl -u em-ci-failover -n 20`; within ~3 min of gamebox being
online, `gh api …/runners` shows devbox runners **without** `em-ci`, and one
Telegram transition message arrived.

**Step 3: Measure offline-flip latency.** On gamebox:
gamebox is headless; cut its network on a timer so it comes back by itself:
`sudo systemd-run --on-active=5 sh -c 'nmcli radio wifi off; sleep 240; nmcli radio wifi on'`
(Ethernet: `nmcli device disconnect <iface>` / `connect`). Also measure a hard
listener death without a network cut:
`sudo systemctl kill -s KILL container@em-ci-1.service container@em-ci-2.service`. Record: time of cut; time GitHub shows gamebox runners
`offline` (poll `gh api` every 15 s from the Mac); time devbox regains `em-ci`.
Restore, and record the reverse. Put the numbers in the design doc's "Known
behaviour" section and adjust `EM_CI_TICKS` only if the data says so.

**Step 4:** `sudo systemctl start em-ci-monitor-dry-run; journalctl -u em-ci-monitor-dry-run -n 30`
— no new problems.

**Step 5:** Update PR 4 description with the measurements; shepherd.

---

## PR 5 — streaming pause on gamebox

### Task 10: Pause flag, pause unit, reconciler, polkit

**Files:**
- Create: `hosts/gamebox/em-ci-pause.nix`
- Modify: `hosts/gamebox/em-ci.nix` (`pauseFlag`, import)

**Step 1:** In `hosts/gamebox/em-ci.nix` set
`services.em-ci-runners.pauseFlag = "/run/em-ci-paused";` and import
`./em-ci-pause.nix`.

**Step 2: `hosts/gamebox/em-ci-pause.nix`:**

```nix
# Pause gamebox's em-ci runners while a Sunshine stream is active.
# Design: docs/plans/2026-10-11-em-ci-gamebox-design.md §4.
# The pause is the flag file; container units carry
# ConditionPathExists=!<flag> (modules/em-ci-runners.nix), so any start while
# paused is skipped, whoever asks. No Conflicts=: it is bidirectional, and a
# container start would end the pause mid-stream.
{ config, lib, pkgs, ... }:
let
  flag = config.services.em-ci-runners.pauseFlag;
  units = map (n: "container@${n}.service") (lib.attrNames config.services.em-ci-runners.runners);
  systemctl = "${pkgs.systemd}/bin/systemctl";
  resume = pkgs.writeShellScript "em-ci-resume" ''
    rm -f ${flag}
    ${systemctl} is-failed --quiet em-ci-disk-watchdog.service && exit 0
    ${systemctl} --no-block start ${lib.concatStringsSep " " units}
  '';
in {
  systemd.services.em-ci-pause = {
    description = "Pause em-ci runners (Sunshine stream active)";
    serviceConfig = {
      Type = "exec";
      ExecStartPre = "${pkgs.coreutils}/bin/touch ${flag}";
      ExecStart = "${pkgs.coreutils}/bin/sleep infinity";
      ExecStartPost = "${systemctl} --no-block stop ${lib.concatStringsSep " " units}";
      # '-': a start refused during shutdown must not fail the stop.
      ExecStopPost = "-${resume}";
      RuntimeMaxSec = "8h";   # stale-pause ceiling
    };
  };

  # Belt and braces for paths the hook can miss (Sunshine crash, Moonlight
  # disconnect with an app still running, a stale flag after the pause unit died).
  systemd.services.em-ci-reconcile = {
    description = "Reconcile em-ci containers with the pause flag";
    serviceConfig.Type = "oneshot";
    script = ''
      paused=0; ${systemctl} is-active --quiet em-ci-pause.service && paused=1
      if [ "$paused" = 0 ] && [ -e ${flag} ]; then rm -f ${flag}; fi   # stale flag
      for u in ${lib.concatStringsSep " " units}; do
        if [ "$paused" = 1 ]; then
          ${systemctl} is-active --quiet "$u" && ${systemctl} --no-block stop "$u"
        elif ! ${systemctl} is-failed --quiet em-ci-disk-watchdog.service; then
          ${systemctl} is-active --quiet "$u" || ${systemctl} --no-block start "$u"
        fi
      done
      exit 0   # NixOS `script` runs under -e; without this a no-op pass ends on a non-zero is-active and the unit reads failed
    '';
  };
  systemd.timers.em-ci-reconcile = {
    wantedBy = [ "timers.target" ];
    timerConfig = { OnBootSec = "5min"; OnUnitActiveSec = "5min"; };
  };

  # `gamer` (Sunshine's user) may start/stop the pause unit and nothing else.
  security.polkit.extraConfig = ''
    polkit.addRule(function(action, subject) {
      if (action.id == "org.freedesktop.systemd1.manage-units" &&
          action.lookup("unit") == "em-ci-pause.service" &&
          (action.lookup("verb") == "start" || action.lookup("verb") == "stop") &&
          subject.user == "gamer") {
        return polkit.Result.YES;
      }
    });
  '';
}
```

**Step 3: Eval** —
`nix eval --json .#nixosConfigurations.gamebox.config.systemd.services."container@em-ci-1".unitConfig`
contains `"ConditionPathExists":"!/run/em-ci-paused"`; devbox's does not
(`pauseFlag` null there). Oracle: record devbox's toplevel drvPath from
`origin/main` after PR 4 merges; PR 5's devbox drvPath must equal it.

**Step 4:** Commit — `feat(gamebox): pause em-ci runners via a flag file`.

### Task 11: Sunshine hook

**Files:** Modify `hosts/gamebox/streaming.nix` (`services.sunshine.settings`).

**Step 1:** Add:

```nix
# Pause em-ci while streaming (hosts/gamebox/em-ci-pause.nix). Absolute path:
# Sunshine's user unit sets PATH = mkForce null. --no-block: never hold the
# game launch for a container shutdown.
global_prep_cmd = builtins.toJSON [{
  do = "/run/current-system/sw/bin/systemctl --no-block start em-ci-pause.service";
  undo = "/run/current-system/sw/bin/systemctl --no-block stop em-ci-pause.service";
}];
```

**Step 2:** Check how the module renders settings: build or eval the generated
`sunshine.conf` and confirm the line is
`global_prep_cmd = [{"do":"…","undo":"…"}]` (valid JSON on one line). If the
module's settings type rejects/escapes it, report rather than hack around it.

**Step 3:** Commit — `feat(gamebox): Sunshine pauses em-ci during streams`.

### Task 12: Deploy and verify on gamebox

**Step 1:** Deploy while gamebox runners are idle (the `ConditionPathExists`
change restarts both containers, killing in-flight jobs). If the switch
rebuilds Sunshine, lift the nix-daemon cap first (Task 5 step 1).
`sudo nixos-rebuild switch --flake .#gamebox`.

**Step 2: polkit, denied paths:**

```bash
sudo -u gamer systemctl --no-block start container@em-ci-1.service; echo $?   # non-zero (denied)
sudo -u dev   systemctl --no-block start em-ci-pause.service; echo $?         # non-zero: no polkit rule for dev
sudo -u gamer systemctl --no-block start em-ci-pause.service; echo $?         # 0
```

then `sudo systemctl stop em-ci-pause` and confirm containers come back.

**Step 3: Condition while paused:**
`sudo systemctl start em-ci-pause; sudo systemctl start container@em-ci-1; systemctl status container@em-ci-1`
→ "Condition check … was not met", inactive, not failed. Then stop the pause.

**Step 4: Real stream.** From the Mac, launch a game in Moonlight. Expect: game
starts without extra delay; within ~30 s both `gamebox-em-ci-*` runners show
`offline` in `gh api`; after ~3 min devbox regains `em-ci` (Telegram message).
Quit the game: containers start, runners online, devbox loses the label after
~3 min.

**Step 5: undo-never-runs path.** Start a stream, then
`sudo systemctl kill --signal=KILL --user -M gamer@ sunshine` (or restart
Sunshine). Pause stays active (correct: you may still be playing) until
`RuntimeMaxSec` or a manual stop; confirm the reconciler keeps containers
stopped meanwhile, and that `sudo systemctl stop em-ci-pause` brings them back.

**Step 6:** PR 5 description with results; shepherd.

---

## PR 6 — eternal-machinery cleanup

### Task 13: Remove the legacy `HEAVY_RUNNER` arm

Only after the variable has been `["self-hosted","em-ci"]` for at least one
merged CI run. Delete `legacy_selfhosted` and its `case` arm; PR; shepherd.

---

## Follow-ups (file as beads, not in this plan)

- Demote a black-holing gamebox (online but every job fails at setup): the
  reconciler strips gamebox's `em-ci` label after N setup failures.
- healthchecks.io stays green while devbox is alive-but-starved (2026-10-11):
  em-ci-monitor runs outside the starved user slice.
