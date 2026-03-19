# Anthropic Proxy Documentation Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Document the Anthropic OAuth proxy workaround consistently across `workstation` and `anthropic-oauth-proxy`, using each repo's normal `AGENTS.md` and `.opencode/skills/` patterns.

**Architecture:** Add one workstation skill plus an `AGENTS.md` link for the Nix-managed integration, and bootstrap the proxy repo with an `AGENTS.md` table of contents, quick start, and repo-local skill(s). Keep `README.md` in the proxy repo as a lightweight pointer to `AGENTS.md`.

**Tech Stack:** Markdown docs, repo-local OpenCode skills, existing workstation Nix/service layout.

---

### Task 1: Document the workstation-side integration

**Files:**
- Modify: `AGENTS.md`
- Create: `.opencode/skills/anthropic-oauth-proxy/SKILL.md`

**Step 1: Write the failing test**

Define the missing operator questions this doc must answer:

- where the workaround lives in `workstation`
- what Home Manager config owns it
- how the proxy service is managed
- what behavior is proven-good (`ua+billing`, no cache stripping)
- how to verify and troubleshoot it

**Step 2: Run test to verify it fails**

Read `AGENTS.md` and confirm there is no Anthropic OAuth proxy entry in the Skills table and no dedicated skill covering this workflow.

Expected: FAIL because this knowledge is currently scattered across code changes and conversation context.

**Step 3: Write minimal implementation**

Create a new skill focused on the workaround and add a row to `AGENTS.md` linking to it.

**Step 4: Run test to verify it passes**

Read `AGENTS.md` and the new skill and confirm a future operator can discover and operate the workaround without conversation context.

Expected: PASS.

**Step 5: Commit**

```bash
git add AGENTS.md .opencode/skills/anthropic-oauth-proxy/SKILL.md
git commit -m "docs: add anthropic oauth proxy workstation guide"
```

### Task 2: Bootstrap the proxy repo documentation shape

**Files:**
- Create: `../anthropic-oauth-proxy/AGENTS.md`
- Create: `../anthropic-oauth-proxy/.opencode/skills/understanding-anthropic-oauth-proxy/SKILL.md`
- Create: `../anthropic-oauth-proxy/.opencode/skills/`

**Step 1: Write the failing test**

List the expected proxy repo conventions:

- canonical `AGENTS.md`
- table of contents
- quick start
- repo-local `.opencode/skills/`
- one foundational understanding skill

**Step 2: Run test to verify it fails**

Inspect `../anthropic-oauth-proxy` and confirm it lacks `AGENTS.md` and `.opencode/skills/`.

Expected: FAIL.

**Step 3: Write minimal implementation**

Create `AGENTS.md` with ToC + Quick Start + operations sections and add one repo-local understanding skill.

**Step 4: Run test to verify it passes**

Read `../anthropic-oauth-proxy/AGENTS.md` and the skill and confirm a future operator can onboard without external explanation.

Expected: PASS.

**Step 5: Commit**

```bash
git add ../anthropic-oauth-proxy/AGENTS.md ../anthropic-oauth-proxy/.opencode/skills
git commit -m "docs: add anthropic oauth proxy repo docs"
```

### Task 3: Convert the proxy README into a pointer

**Files:**
- Modify: `../anthropic-oauth-proxy/README.md`

**Step 1: Write the failing test**

Define the README target behavior:

- brief repo summary
- points readers to `AGENTS.md`
- does not duplicate the full operator manual

**Step 2: Run test to verify it fails**

Read the current README and confirm it duplicates detailed setup and scenario material that will belong in `AGENTS.md`.

Expected: FAIL.

**Step 3: Write minimal implementation**

Trim `README.md` to a short overview and pointer to `AGENTS.md`.

**Step 4: Run test to verify it passes**

Read `README.md` and confirm it is now a lightweight entrypoint.

Expected: PASS.

**Step 5: Commit**

```bash
git add ../anthropic-oauth-proxy/README.md
git commit -m "docs: point proxy readme to agents guide"
```

### Task 4: Verify docs match current proven behavior

**Files:**
- Verify: `AGENTS.md`
- Verify: `.opencode/skills/anthropic-oauth-proxy/SKILL.md`
- Verify: `../anthropic-oauth-proxy/AGENTS.md`
- Verify: `../anthropic-oauth-proxy/.opencode/skills/understanding-anthropic-oauth-proxy/SKILL.md`
- Verify: `../anthropic-oauth-proxy/README.md`

**Step 1: Write the failing test**

Create a checklist of facts that must be accurate:

- `opencode` works without extra env vars on devbox
- `anthropic-oauth-proxy.service` is the managed service
- default proven-good mode is `User-Agent + billing`, cache stripping off
- workstation owns the deployed plugin and service wiring
- proxy repo explains local development and workstation integration separately

**Step 2: Run test to verify it fails**

Compare draft docs against the live implementation and note any mismatches.

Expected: any mismatch blocks completion.

**Step 3: Write minimal implementation**

Fix only the mismatches found.

**Step 4: Run test to verify it passes**

Re-read all docs and confirm they are aligned with the current verified behavior.

Expected: PASS.

**Step 5: Commit**

```bash
git add AGENTS.md .opencode/skills/anthropic-oauth-proxy/SKILL.md ../anthropic-oauth-proxy/AGENTS.md ../anthropic-oauth-proxy/.opencode/skills/understanding-anthropic-oauth-proxy/SKILL.md ../anthropic-oauth-proxy/README.md
git commit -m "docs: align anthropic proxy documentation"
```
