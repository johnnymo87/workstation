# Workstation

NixOS hosts (devbox on Hetzner, cloudbox on GCP) + nix-darwin (macOS), all sharing standalone home-manager.

## Host Identification (READ FIRST)

**Always check `$OPENCODE_HOSTNAME` (injected into every bash call by `assets/opencode/plugins/shell-env.ts`) or run `hostname` at the start of any session.** This repo configures three first-class hosts; do NOT assume "devbox" — `cloudbox` and `devbox` are both NixOS, both run on `dev@`, and look superficially identical from inside an opencode session. Skills and configs that look "devbox-shaped" usually apply to both NixOS hosts; check `hostname` before reaching for host-specific guidance.

| `hostname` returns | Host kind | NixOS rebuild | Home-manager |
|---|---|---|---|
| `devbox` | NixOS on Hetzner | `sudo nixos-rebuild switch --flake .#devbox` | `nix run home-manager -- switch --flake .#dev` |
| `cloudbox` | NixOS on GCP ARM | `sudo nixos-rebuild switch --flake .#cloudbox` | `nix run home-manager -- switch --flake .#cloudbox` |
| `Y0FMQX93RR-2` (or similar) | macOS (nix-darwin) | `sudo darwin-rebuild switch --flake .#Y0FMQX93RR-2` (covers both) | (combined) |

Note the home-manager target name is asymmetric: devbox uses `.#dev` (legacy name kept for compatibility), cloudbox uses `.#cloudbox`. See the [Rebuilding](.opencode/skills/rebuilding/SKILL.md) skill for the canonical commands and their host-detection logic.

## Quick Start

**NixOS hosts (devbox or cloudbox):**
```bash
sudo nixos-rebuild switch --flake ".#$(hostname)"      # System changes
# Home-manager target differs per host (see table above):
nix run home-manager -- switch --flake .#dev           # devbox
nix run home-manager -- switch --flake .#cloudbox      # cloudbox
```

**macOS (nix-darwin):**
```bash
sudo darwin-rebuild switch --flake .#Y0FMQX93RR-2      # System + user combined
```

## Work in a Worktree, Not the Primary Root

**Do not edit or commit in `~/projects/workstation` itself.** That checkout is
shared by every concurrent session on the host; two agents editing it at once
clobber each other, and a commit made there strands work on a local `main` that
nobody is watching. This repo was itself found sitting on an unpushed `main`
commit on 2026-08-11.

Start work with:

```bash
work <slug>     # creates ~/projects/workstation/.worktrees/<slug> off origin/main
```

On **cloudbox**, a `pre-commit` hook refuses commits made at the primary root of
`mono`, `pigeon` and `workstation` (enrolled in `users/dev/home.base.nix` via
`worktreeGuardRepos`). On devbox and macOS the hook is not installed, so there
the rule above is convention only — follow it anyway. If the hook blocks you:

1. **No local changes yet** — just `work <slug>` and commit there.
2. **You already have uncommitted changes at the root** — copy them forward.
   **Never `git stash` in the root**; it moves every session's changes, not just
   yours, and has already destroyed a peer session's uncommitted database.
   ```bash
   work <slug>
   p=$(mktemp /tmp/wg.XXXXXX.diff)
   # `diff HEAD` (not bare `diff`) so STAGED work is included; --binary so
   # binary files survive the round trip.
   git -C ~/projects/workstation diff HEAD --binary > "$p"
   git -C ~/projects/workstation/.worktrees/<slug> apply "$p"
   # Untracked files are NOT in that diff -- list and copy them by hand:
   git -C ~/projects/workstation status --porcelain | grep '^??'
   ```
   The root is shared, so that diff may contain another session's work as well
   as yours. Check before cleaning anything up there, and only once your
   worktree commit exists.
3. **Genuine hotfix that must land at the root** — `git commit --no-verify` is
   supported, not a transgression. Say why in the commit message.

The hook blocks *commits*, not *edits*, and `cherry-pick`/`revert`/`merge`/`rebase`
all bypass it (the `merge` bypass is load-bearing — `git pull` at a deploy root
depends on it). So the hook is a backstop, not a guarantee: the convention above
is what actually keeps the root clean. See
`docs/plans/2026-08-11-worktree-guard-generalization-design.md`.

## Managing Projects

Projects are declared in `projects.nix` and auto-cloned per platform.

| Platform | Clone target | Trigger |
|----------|-------------|---------|
| Devbox | `~/projects/` | Login (systemd service) or `~/.local/bin/ensure-projects` |
| Cloudbox | `~/projects/` | Login (systemd service) or `~/.local/bin/ensure-projects` |
| macOS | `~/Code/` | `darwin-rebuild switch` (activation script) |

**Add a project:**
1. Edit `projects.nix`:
   ```nix
   my-new-project = { url = "git@github.com:org/repo.git"; };
   ```
2. Push to GitHub
3. Apply: `nix run home-manager -- switch --flake .#dev` (devbox) or `darwin-rebuild switch` (macOS)

**Devbox projects live on the local SSD** (`~/projects` on root filesystem). They are reconstructable from git and do not survive full reprovisioning — `ensure-projects` reclones declared projects on login.

## Commands

| Command | Description |
|---------|-------------|
| [/rebuild](.opencode/commands/rebuild.md) | Apply system and/or home changes |
| [/apply-home](.opencode/commands/apply-home.md) | Quick home-manager apply |
| [/post-provision](.opencode/commands/post-provision.md) | Complete devbox setup after first SSH |

## Automated Dependency Updates

- **Local packages** (`beads`): auto-updated by `.github/workflows/update-packages.yml` (daily) using `nix-update`.
- **opencode-patched**: auto-updated by `.github/workflows/update-opencode-patched.yml` (every 8 hours) -- checks `johnnymo87/opencode-patched` releases (caching + vim), computes platform hashes, updates `home.base.nix`.
- **gws**: auto-updated by `.github/workflows/update-gws.yml` (daily) -- checks `googleworkspace/cli` releases, computes platform hashes, updates `pkgs/gws/default.nix`.
- **bb**: auto-updated by `.github/workflows/update-bb.yml` (daily) -- checks `buildbuddy-io/bazel` releases, computes platform hashes for the four naked-binary assets, updates `pkgs/bb/default.nix`.
- All workflows open a PR with auto-merge enabled.

## Skills

| Skill | Description |
|-------|-------------|
| [Understanding Workstation](.opencode/skills/understanding-workstation/SKILL.md) | Repo structure, concepts, navigation |
| [Setting Up Hetzner](.opencode/skills/setting-up-hetzner/SKILL.md) | Initial machine setup, hcloud context |
| [Setting Up Cloudbox](.opencode/skills/setting-up-cloudbox/SKILL.md) | GCP ARM VM provisioning with nixos-anywhere |
| [Rebuilding](.opencode/skills/rebuilding/SKILL.md) | How to apply changes to any NixOS host (devbox, cloudbox) |
| [Troubleshooting NixOS Host](.opencode/skills/troubleshooting-nixos-host/SKILL.md) | SSH issues, host keys, NixOS problems (devbox + cloudbox) |
| [Automated Updates](.opencode/skills/automated-updates/SKILL.md) | GitHub Actions + systemd timer update pipeline |
| [Managing Secrets](.opencode/skills/managing-secrets/SKILL.md) | Adding, removing, and using sops-nix secrets |
| [Growing Neovim Config](.opencode/skills/growing-nvim-config/SKILL.md) | How to incrementally add nvim config |
| [Clipboard (gclpr & OSC 52)](.opencode/skills/clipboard/SKILL.md) | Copy/paste over mosh/SSH via gclpr TCP bridge |
| [Screenshot to Remote OpenCode](.opencode/skills/screenshot-to-remote-opencode/SKILL.md) | Sharing screenshots with remote OpenCode (devbox/cloudbox over SSH) |
| [OpenCode Agents](.opencode/skills/opencode-agents/SKILL.md) | Agent set rationale, what was kept/removed and why |
| [Tracking Cache Costs](.opencode/skills/tracking-cache-costs/SKILL.md) | Measuring OpenCode prompt caching efficiency |
| [Measuring Session Context](.opencode/skills/measuring-session-context/SKILL.md) | `oc-context`: per-session context size / % of window, for deciding who compacts |
| [Configuring GWS](.opencode/skills/configuring-gws/SKILL.md) | Adding, debugging gws accounts and OAuth credentials |
| [Scrubbing Company References](.opencode/skills/scrubbing-company-references/SKILL.md) | Policy for keeping org metadata out of public source |
| [Atlassian Multi-Instance](.opencode/skills/atlassian-multi-instance/SKILL.md) | Adding, removing, debugging Atlassian instance profiles |
| [Setting Up Notion MCP](.opencode/skills/setting-up-notion-mcp/SKILL.md) | First-time OAuth + headless devbox SSH-L dance for Notion's hosted MCP |
| [Setting Up DevCycle MCP](.opencode/skills/setting-up-devcycle-mcp/SKILL.md) | Local dvc-mcp + client-credentials (sops/Keychain) for DevCycle's feature-flag MCP; hosted remote is unusable (no dynamic client registration) |
| [Resetting Workspace](.opencode/skills/resetting-workspace/SKILL.md) | Manual + nightly cloudbox reset (kill nvims, clear sessions, restart serve) |
| [Monitoring Serve Pool](.opencode/skills/monitoring-serve-pool/SKILL.md) | Wedged-serve detection/recovery (canary timer), "alive but frozen" failure mode, serve memory-limit rationale |
| [Auditing OpenCode LLM Calls](.opencode/skills/auditing-opencode-llm-calls/SKILL.md) | Durable LLM-call capture on cloudbox; attribute surges by agent/model/session |
| [Operating the aigateway](.opencode/skills/operating-aigateway/SKILL.md) | Deploy/route/debug the LLM cost-capture proxy on cloudbox; query the ledger; add prices; roll back |

## Structure

```
workstation/
├── flake.nix              # Flake: NixOS + nix-darwin + home-manager
├── projects.nix           # Declarative project list (both platforms)
├── hosts/
│   ├── devbox/            # NixOS system config (Hetzner)
│   ├── cloudbox/          # NixOS system config (GCP ARM)
│   └── Y0FMQX93RR-2/     # macOS (nix-darwin) system config
├── users/dev/
│   ├── home.nix           # Entry point (imports all modules)
│   ├── home.base.nix      # Shared config (git, bash, packages)
│   ├── home.devbox.nix    # Devbox-only (identity, sops secrets)
│   ├── home.cloudbox.nix  # Cloudbox-only (identity, sops secrets, work tools)
│   ├── home.darwin.nix    # macOS-only (launchd, ensure-projects, dotfiles migration)
│   ├── opencode-config.nix  # OpenCode managed config + agents
│   └── opencode-skills.nix  # System-wide OpenCode skills deployed to ~/.config/opencode/skills/
├── pkgs/                  # Self-packaged tools (auto-updated by nix-update)
│   ├── dd-cli/            # Datadog CLI (installed as editable Python tool via home.activation.installDdCli in home.base.nix)
│   ├── beads/             # Distributed issue tracker
│   └── pinentry-op/       # macOS GPG pinentry via 1Password
├── assets/                # Content deployed to user
│   ├── opencode/          # OpenCode agents, skills, plugins, base config
│   └── nvim/              # Neovim Lua config
├── secrets/               # sops-nix encrypted secrets
└── .opencode/             # Documentation and config for THIS repo
    ├── skills/            # Repo-specific skills (auto-discovered by OpenCode)
    └── commands/          # Repo-specific slash commands
```

## Fresh Devbox Setup

After `nixos-anywhere`:
1. Copy age key: `scp /path/to/key devbox:/persist/sops-age-key.txt`
2. Clone workstation: `git clone ... ~/projects/workstation`
3. Apply system: `sudo nixos-rebuild switch --flake .#devbox`
4. Apply home: `nix run home-manager -- switch --flake .#dev`
5. Projects auto-clone on next login (or run `~/.local/bin/ensure-projects`)

## Fresh Cloudbox Setup

See [Setting Up Cloudbox](.opencode/skills/setting-up-cloudbox/SKILL.md) for the full nixos-anywhere flow on a GCP ARM instance. Post-provisioning home-manager command is `nix run home-manager -- switch --flake .#cloudbox` (note the target name, not `.#dev`).

## Fresh macOS Setup

1. Install Nix: `curl -L https://nixos.org/nix/install | sh`
2. Clone workstation: `git clone ... ~/Code/workstation`
3. Apply: `sudo darwin-rebuild switch --flake ~/Code/workstation#Y0FMQX93RR-2`
4. Projects auto-clone during activation (to `~/Code/`)
5. For devenv projects: `cd ~/Code/<project> && direnv allow`

## Running `nix flake check` Locally

Run it the way CI does:

```bash
nix flake check --keep-going
```

**Never add `--no-build`.** It looks like a cheap way to get an
evaluation-only check. It is not, because at least one host's evaluation
depends on import-from-derivation: nixpkgs'
`nixos/modules/virtualisation/google-compute-config.nix` sets

```nix
boot.extraModprobeConfig = readFile "${pkgs.google-guest-configs}/etc/modprobe.d/gce-blacklist.conf";
```

so cloudbox cannot finish *evaluating* until `google-guest-configs` has
actually been *built* — `readFile` has to read a file out of its output.
`--no-build` forbids that build, and the failure surfaces as:

```
error: path '/nix/store/...-google-guest-configs-<ver>.drv' is not valid
```

That names a store path, so it reads like a garbage-collected or corrupt
store and invites a pile of pointless `nix store repair` / GC work. It
actually means "you told me not to build, and I needed to build."

**How to recognise it rather than re-diagnose it.** Run the check once
*without* `--no-build`. That realises the IFD dependency, after which
`--no-build` passes on the identical tree with no source change. A result
that flips on flags alone, with the tree held constant, is a fact about
your command — not about the repo.

Corollary worth internalising: comparing your branch against `main` proves
nothing if you run *both* with the same broken flag. Identical failures are
consistent with "pre-existing repo breakage" and with "my invocation is
wrong," and only varying the invocation separates them. See
[Attributing Causes](https://github.com/johnnymo87/workstation/blob/main/assets/opencode/skills/attributing-causes/SKILL.md)
on interrogating the instrument.

## Pipefail Inversion Guard

`nix flake check` runs `users/dev/test-pipefail-inversion.sh`: no `.sh` or
`.nix` file may pipe a **`printf`/`echo` of a double-quoted string containing a
variable** into an early-exiting `grep -q` / `grep --quiet`, on a single line.

That scope is narrower than "don't pipe into grep -q", deliberately — see
below. It is calibrated against history rather than guessed: the pattern
matches exactly the 57 sites that PRs #431 and #432 removed by hand, and 0 at
`main`. Those two fixed points are the regression oracle for editing it.
Known gaps it does **not** catch: a pipeline split across lines, and a writer
that is a command rather than a variable.

```bash
printf '%s\n' "$VAR" | grep -q PAT      # banned
grep -q PAT <<<"$VAR"                   # the fix, always
```

**Why.** Under `set -o pipefail`, `grep -q` exits the instant it matches and
closes the pipe; a writer still holding data takes EPIPE and returns non-zero;
pipefail then makes the pipeline non-zero *even though the pattern was found*.
A match reads as a miss. For a positive assertion that is a false red. For a
negative one (`... | grep -q BAD && { echo FAIL; }`) it is a false **green** —
the check stops checking and nothing goes red to say so.

The here-string is safe because bash writes the whole document *before*
exec'ing grep, so there is no concurrent writer to receive EPIPE. (The common
claim that here-strings are temp-file backed is false below ~64 KiB; the
pre-write is what matters, not the backing store.)

**The guard does not try to prove `pipefail` is active**, and deliberately so.
`pkgs.writeShellApplication` injects pipefail into shell embedded in `.nix` —
which is how two production sites stayed invisible to a `*.sh`-only search,
one of them able to `rm` a live nvim socket. Any snippet can also be sourced
into a pipefail context later. So the shape is banned unconditionally: one
mechanical edit to comply, versus unbounded reasoning to justify an exception.

**Only the narrow shape is banned** — writer is `printf`/`echo` of a single
quoted variable. `cmd | grep -q` is *not* flagged, because its mechanical fix
is process substitution and `grep -q P < <(cmd)` discards the writer's failure,
trading one silent-failure class for another. Those need `out=$(cmd)` first,
which is a judgement call.

If it blocks you, fix the line. If you genuinely cannot, add
`pipefail-exempt: <reason>` on or within 3 lines above it **and** a per-file
count in the guard's `EXPECTED_MANIFEST` (per-file, so concurrent PRs collide
instead of merging consistent-but-wrong). The manifest is currently empty and
that is the intended steady state.

The suite self-tests its detector against planted fixtures before scanning, so
a rotted regex fails loudly rather than reporting a reassuring "0 violations".

## Front-Door Opacity Guard

`nix flake check` runs `users/dev/test-frontdoor-opacity.sh`: no shipped consumer may address an individual serve (`127.0.0.1:4096-4099`) without an inline exemption.

If it blocks your PR, the fix is **three edits in your own PR**:

1. **Marker** on (or within 3 lines above) the line:
   `frontdoor-exempt(<ROW>): <one-line reason>`
2. **Table row** in `docs/plans/2026-07-26-phase9-consumer-disposition.md`. The row must be a C*/D* exemption class **and its path column must name your file** — you cannot borrow another host's row. If no row describes your file, add one.
3. **Manifest count** for your file in the guard's `EXPECTED_MANIFEST`.

The count is per-file *because* a single scalar merges clean-but-wrong across concurrent PRs. Same-file edits are meant to conflict; resolve them by hand.

**The wrong fix**, which the guard now rejects: citing an existing row that does not describe your file. That was shipped once and reverted. If routing through the door (`:4700`) is possible at all, do that instead of adding an exemption.

## Secrets

**Devbox/Cloudbox:** Secrets at `/run/secrets/<name>` via sops-nix (NixOS module). Env vars auto-exported in bash. See [Managing Secrets](.opencode/skills/managing-secrets/SKILL.md).

**macOS:** macOS Keychain. Secrets populated via helper scripts (e.g. `pigeon-setup-secrets`).

## Landing the Plane (Session Completion)

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   # bd 1.0 flushes writes to Dolt automatically via dolt.auto-commit=on.
   # If a Dolt remote is configured, sync it explicitly with bd dolt pull/push.
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds
