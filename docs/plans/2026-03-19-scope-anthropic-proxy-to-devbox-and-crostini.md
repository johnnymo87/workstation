# Scope Anthropic Proxy To Devbox And Crostini Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Restrict the managed Anthropic OAuth proxy integration to devbox and Crostini, with auto-start on both platforms so plain `opencode` works there and nowhere else.

**Architecture:** Move the proxy service/launcher out of the devbox-only module into a shared Home Manager module or shared helper block gated by `isDevbox || isCrostini`. Keep plugin/config wiring in `users/dev/opencode-config.nix`, but gate it to the same two platforms.

**Tech Stack:** Nix Home Manager modules, OpenCode managed config, systemd user services, workstation platform guards.

---

### Task 1: Gate the managed OpenCode plugin to devbox and Crostini

**Files:**
- Modify: `users/dev/opencode-config.nix`

**Step 1: Write the failing test**

Define the expected platform behavior:

- devbox: plugin present
- Crostini: plugin present
- cloudbox: plugin absent
- Darwin: plugin absent

**Step 2: Run test to verify it fails**

Inspect `users/dev/opencode-config.nix` and confirm the current gating does not yet express exactly `isDevbox || isCrostini` for the Anthropic workaround.

Expected: FAIL.

**Step 3: Write minimal implementation**

Update the Anthropic proxy plugin overlay so it is enabled only on devbox and Crostini.

**Step 4: Run test to verify it passes**

Read the Nix expression and confirm the plugin list is conditionally managed only for those two platforms.

Expected: PASS.

**Step 5: Commit**

```bash
git add users/dev/opencode-config.nix
git commit -m "feat: scope anthropic plugin to devbox and crostini"
```

### Task 2: Share the managed proxy service between devbox and Crostini

**Files:**
- Modify: `users/dev/home.devbox.nix`
- Modify: `users/dev/home.crostini.nix`
- Create or Modify: shared helper location if extracted (for example `users/dev/anthropic-oauth-proxy.nix`)

**Step 1: Write the failing test**

Define the desired behavior:

- devbox user service exists and auto-starts
- Crostini user service exists and auto-starts
- cloudbox and Darwin do not get the service

**Step 2: Run test to verify it fails**

Inspect the current service definition and confirm it exists only in `users/dev/home.devbox.nix`.

Expected: FAIL.

**Step 3: Write minimal implementation**

Extract or duplicate the smallest shared launcher/service block necessary, gated to `isDevbox || isCrostini`.

**Step 4: Run test to verify it passes**

Read the updated modules and confirm both devbox and Crostini get the same auto-start behavior.

Expected: PASS.

**Step 5: Commit**

```bash
git add users/dev/home.devbox.nix users/dev/home.crostini.nix users/dev/anthropic-oauth-proxy.nix
git commit -m "feat: run anthropic proxy on devbox and crostini"
```

### Task 3: Update docs to reflect the new platform scope

**Files:**
- Modify: `AGENTS.md`
- Modify: `.opencode/skills/anthropic-oauth-proxy/SKILL.md`

**Step 1: Write the failing test**

List the facts the docs must now say:

- managed scope is devbox + Crostini
- both platforms auto-start the proxy
- cloudbox and Darwin are intentionally excluded

**Step 2: Run test to verify it fails**

Read the current docs and confirm they describe devbox-only behavior.

Expected: FAIL.

**Step 3: Write minimal implementation**

Update the docs to describe the new platform scope and operator behavior.

**Step 4: Run test to verify it passes**

Re-read the docs and confirm they match the implementation.

Expected: PASS.

**Step 5: Commit**

```bash
git add AGENTS.md .opencode/skills/anthropic-oauth-proxy/SKILL.md
git commit -m "docs: update anthropic proxy platform scope"
```

### Task 4: Apply and verify on devbox

**Files:**
- Use: `users/dev/opencode-config.nix`
- Use: `users/dev/home.devbox.nix`
- Use: `users/dev/home.crostini.nix`

**Step 1: Write the failing test**

Define the verification checklist:

- `home-manager switch --flake .#dev` succeeds
- `anthropic-oauth-proxy.service` is active on devbox
- plain `opencode` still works on devbox

**Step 2: Run test to verify it fails**

Use the current state before the new changes are applied.

Expected: not yet verified.

**Step 3: Write minimal implementation**

Apply the Home Manager config and restart the service if needed.

**Step 4: Run test to verify it passes**

Run:

```bash
home-manager switch --flake .#dev
systemctl --user status anthropic-oauth-proxy.service --no-pager
opencode run "say hello in five words" --model anthropic/claude-opus-4-6
```

Expected: service active, Anthropic request succeeds.

**Step 5: Commit**

```bash
git add .
git commit -m "chore: verify anthropic proxy devbox and crostini scope"
```
