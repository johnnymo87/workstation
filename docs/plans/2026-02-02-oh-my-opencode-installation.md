# Oh-My-OpenCode Installation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Install OpenCode and oh-my-opencode plugin on both devbox (Linux) and macOS with platform-specific subscription configurations.

**Architecture:** Add OpenCode via Nix (llm-agents.nix) for automatic updates, then install oh-my-opencode plugin manually on each platform with different subscription configs (devbox: Claude Max 20x + ChatGPT Plus; macOS: Claude API + ChatGPT Plus + GitHub Copilot + Vertex AI/Gemini).

**Tech Stack:** Nix/home-manager, Bun (for oh-my-opencode installer), OpenCode CLI

---

## Subscription Configuration Summary

| Platform | Claude | OpenAI/ChatGPT | Gemini | GitHub Copilot | Notes |
|----------|--------|----------------|--------|----------------|-------|
| **devbox** | Max 20x (personal) | ChatGPT Plus (personal) | No | No | Personal development, headless sessions |
| **macOS** | API billing (work) | ChatGPT Plus (personal) | Yes (Vertex AI work) | Yes (work) | Work laptop, rich subscriptions |

---

## Task 1: Add OpenCode to Nix Configuration

**Files:**
- Modify: `users/dev/home.base.nix:73-88` (add opencode to packages)
- Modify: `.gitignore` (add OpenCode config exclusions)

**Step 1: Add opencode package to home.base.nix**

Add to the home.packages list after beads:

```nix
home.packages = [
  # LLM tools from numtide/llm-agents.nix
  llmPkgs.claude-code
  llmPkgs.ccusage
  llmPkgs.beads
  llmPkgs.opencode
  llmPkgs.ccusage-opencode

  # Cloudflare Workers CLI
  pkgs.wrangler

  # Clipboard via tmux
  tcopy
  tpaste

  # Other tools
  pkgs.devenv
];
```

**Step 2: Add OpenCode config to .gitignore**

OpenCode stores user config in `~/.config/opencode/` which should not be versioned:

```bash
cat >> ~/projects/workstation/.gitignore << 'EOF'

# OpenCode user configuration (managed per-machine)
.opencode/
EOF
```

**Step 3: Commit Nix config changes**

```bash
cd ~/projects/workstation
git add users/dev/home.base.nix .gitignore
git commit -m "feat: add OpenCode and ccusage-opencode packages

- Add llmPkgs.opencode and llmPkgs.ccusage-opencode to home.packages
- Exclude .opencode/ from version control (per-machine config)
- Both packages will receive automatic updates via llm-agents pipeline"
```

---

## Task 2: Deploy OpenCode on Devbox

**Files:**
- Apply: `users/dev/home.nix` via home-manager

**Step 1: Push workstation changes to GitHub**

```bash
cd ~/projects/workstation
git push origin main
```

Expected: Changes pushed successfully

**Step 2: Wait for or trigger auto-update on devbox**

Option A (automatic): Wait up to 4 hours for pull-workstation.timer
Option B (manual trigger):

```bash
# On devbox
~/.local/bin/pull-workstation
```

Expected output:
```
Pulling updates...
Applying home-manager...
...
Update complete
```

**Step 3: Verify OpenCode is installed on devbox**

```bash
# On devbox
opencode --version
ccusage-opencode --version
```

Expected: Version numbers displayed (e.g., `opencode 1.1.48`)

---

## Task 3: Deploy OpenCode on macOS

**Files:**
- Apply: `users/dev/home.nix` via darwin-rebuild

**Step 1: Apply darwin configuration**

```bash
# On macOS
cd ~/projects/workstation
git pull origin main
darwin-rebuild switch --flake .
```

Expected: Build succeeds, OpenCode installed

**Step 2: Verify OpenCode is installed on macOS**

```bash
# On macOS
opencode --version
ccusage-opencode --version
```

Expected: Version numbers displayed

**Step 3: Verify OpenCode is in PATH**

```bash
# On macOS
which opencode
```

Expected: `/nix/store/.../bin/opencode` or similar Nix store path

---

## Task 4: Configure oh-my-opencode on Devbox

**Files:**
- Create: `~/.config/opencode/opencode.json` (via installer)
- Create: `~/.config/opencode/plugins/` (plugin files)
- Create: `~/.config/opencode/oh-my-opencode.json` (agent configuration)

**IMPORTANT:** Authentication must be completed BEFORE running the installer. The installer uses authentication status to determine which models to configure.

**Step 1: Authenticate providers**

```bash
# On devbox
opencode auth login
```

Select and authenticate each provider:
1. **Anthropic** → OAuth (Claude Max 20x personal subscription)
2. **OpenAI** → OAuth (ChatGPT Plus personal subscription)
3. **Google** → API Key (personal Google API key)

**Note:** SSH port forwarding for OAuth callback (port 1455) should already be configured in `~/.ssh/config` via the update-ssh-config.sh script.

**Step 2: Verify authentication**

```bash
# On devbox
opencode auth list
```

Expected: All three providers (Anthropic, OpenAI, Google) listed

**Step 3: Run oh-my-opencode installer**

Configuration flags:
- Claude: **max20** (Claude Max 20x subscription)
- OpenAI: **yes** (ChatGPT Plus)
- Gemini: **yes** (Google API)
- Copilot: **no**

```bash
# On devbox (use npx, not bunx - bunx not available on NixOS)
npx oh-my-opencode install --no-tui \
  --claude=max20 \
  --openai=yes \
  --gemini=yes \
  --copilot=no
```

Expected output:
```
oMoMoMoMo... Update
[OK] OpenCode 1.1.48 detected
[OK] Plugin verified
[OK] Auth plugins configured
[OK] Config written -> oh-my-opencode.json

Model Assignment
  [i] Models auto-configured based on provider priority
  * Priority: Native > Copilot > OpenCode Zen > Z.ai
```

**Step 4: Verify oh-my-opencode.json configuration**

```bash
# On devbox
cat ~/.config/opencode/oh-my-opencode.json | jq -r '.agents.sisyphus, .agents.oracle, .agents."multimodal-looker"'
```

Expected output:
```json
{
  "model": "anthropic/claude-opus-4-5",
  "variant": "max"
}
{
  "model": "openai/gpt-5.2",
  "variant": "high"
}
{
  "model": "google/gemini-3-flash"
}
```

**Step 5: Test OpenCode with oh-my-opencode**

```bash
# On devbox
cd /tmp
mkdir -p test-opencode && cd test-opencode
echo "console.log('hello')" > test.js
opencode "add a comment explaining what this does"
```

Expected: OpenCode runs with oh-my-opencode agents using authenticated models

---

## Task 5: Configure oh-my-opencode on macOS

**Files:**
- Create: `~/.config/opencode/opencode.json` (via installer)
- Create: `~/.config/opencode/plugins/` (plugin files)
- Create: `~/.config/opencode/oh-my-opencode.json` (agent configuration)

**IMPORTANT:** Authentication must be completed BEFORE running the installer. The installer uses authentication status to determine which models to configure.

**macOS Authentication Strategy:**
- **Anthropic models**: Via Google Cloud Vertex AI (work account)
- **Google models**: Via Google Cloud Vertex AI (work account)
- **OpenAI models**: Via ChatGPT Plus OAuth (personal account)
- **GitHub Copilot**: Via GitHub account (work account)

**Step 1: Authenticate Vertex AI**

```bash
# On macOS
opencode auth login
# Select: Google → Vertex AI
# Follow prompts to authenticate with Google Cloud work account
```

This provides access to both Anthropic (Claude) and Google (Gemini) models through Vertex AI.

**Step 2: Authenticate ChatGPT Plus**

```bash
# On macOS
opencode auth login
# Select: OpenAI → ChatGPT Plus/Pro
# Follow OAuth flow with personal ChatGPT Plus account
```

**Step 3: Authenticate GitHub Copilot**

```bash
# On macOS
opencode auth login
# Select: GitHub Copilot
# Follow OAuth flow with work GitHub account
```

**Step 4: Verify authentication**

```bash
# On macOS
opencode auth list
```

Expected: Google (Vertex AI), OpenAI, and GitHub Copilot listed

**Step 5: Run oh-my-opencode installer**

Configuration flags (use npx or bunx):
- Claude: **yes** (via Vertex AI, NOT max20)
- OpenAI: **yes** (ChatGPT Plus personal)
- Gemini: **yes** (via Vertex AI work)
- Copilot: **yes** (work subscription)

```bash
# On macOS
npx oh-my-opencode install --no-tui \
  --claude=yes \
  --openai=yes \
  --gemini=yes \
  --copilot=yes
```

Expected output:
```
oMoMoMoMo... Update
[OK] OpenCode detected
[OK] Plugin verified
[OK] Auth plugins configured
[OK] Config written -> oh-my-opencode.json

Model Assignment
  [i] Models auto-configured based on provider priority
  * Priority: Native > Copilot > OpenCode Zen > Z.ai
```

**Step 6: Verify oh-my-opencode.json configuration**

```bash
# On macOS
cat ~/.config/opencode/oh-my-opencode.json | jq -r '.agents.sisyphus, .agents.oracle, .agents."multimodal-looker"'
```

Expected output (Vertex AI provides anthropic/ and google/ prefixes):
```json
{
  "model": "anthropic/claude-opus-4-5"
}
{
  "model": "openai/gpt-5.2",
  "variant": "high"
}
{
  "model": "google/gemini-3-flash"
}
```

**Step 7: Test OpenCode with oh-my-opencode**

```bash
# On macOS
cd /tmp
mkdir -p test-opencode && cd test-opencode
echo "console.log('hello')" > test.js
opencode "add a comment explaining what this does"
```

Expected: OpenCode runs with oh-my-opencode agents using Vertex AI (Claude/Gemini) and ChatGPT Plus (OpenAI) models

---

## Task 6: Create Workstation Skill for oh-my-opencode

**Files:**
- Create: `assets/claude/skills/using-oh-my-opencode/SKILL.md`
- Modify: `users/dev/claude-skills.nix` (deploy new skill)

**Step 1: Create skill directory and markdown file**

```bash
mkdir -p ~/projects/workstation/assets/claude/skills/using-oh-my-opencode
```

**Step 2: Write skill documentation**

Create `assets/claude/skills/using-oh-my-opencode/SKILL.md`:

```markdown
---
name: using-oh-my-opencode
description: Using OpenCode with oh-my-opencode plugin for multi-model agent orchestration. Use when working with oh-my-opencode or debugging configuration issues.
---

# Using oh-my-opencode

OpenCode + oh-my-opencode provides multi-model agent orchestration with specialized agents.

## Installation

Managed via Nix (see workstation repo):
- **OpenCode**: `llmPkgs.opencode` (auto-updates via llm-agents pipeline)
- **oh-my-opencode plugin**: Manual install per machine (configuration differs)

## Platform Configurations

### Devbox (Linux)
- **Claude**: Max 20x (personal subscription via CLAUDE_CODE_OAUTH_TOKEN)
- **OpenAI**: ChatGPT Plus (personal)
- **Gemini**: No
- **Copilot**: No

Install command:
```bash
bunx oh-my-opencode install --no-tui --claude=max20 --openai=yes --gemini=no --copilot=no
```

### macOS (Work Laptop)
- **Claude**: API billing (work account)
- **OpenAI**: ChatGPT Plus (personal)
- **Gemini**: Yes (Vertex AI work)
- **Copilot**: Yes (work)

Install command:
```bash
bunx oh-my-opencode install --no-tui --claude=yes --openai=yes --gemini=yes --copilot=yes
```

## Agent Reference

| Agent | Model | Purpose |
|-------|-------|---------|
| Sisyphus | Claude Opus 4.5 | Primary orchestrator |
| Hephaestus | GPT-5.2 Codex | Autonomous deep worker |
| Atlas | Claude Sonnet 4.5 | Master orchestrator |
| oracle | GPT-5.2 | Consultation, debugging |
| librarian | GLM-4.7 | Docs, GitHub search |
| explore | Grok Code Fast | Fast codebase grep |
| multimodal-looker | Gemini 3 Flash | PDF/image analysis |
| Prometheus | Claude Opus 4.5 | Strategic planning |

## Usage

### Magic Word: `ultrawork` or `ulw`
Include in prompt to activate all oh-my-opencode features:
- Parallel agents
- Background tasks
- Deep exploration
- Relentless execution

Example:
```
opencode "ultrawork: refactor the auth module to use dependency injection"
```

### Calling Specific Agents

Agents are automatically selected by task category, or explicitly invoke:
```
opencode "oracle: why is this query slow?"
opencode "librarian: find React hooks documentation"
```

## Configuration Files

- **Plugin config**: `~/.config/opencode/opencode.json`
- **Plugin files**: `~/.config/opencode/plugins/`
- **NOT version controlled**: Config is machine-specific

## Updating

### OpenCode (Nix-managed)
Updates automatically via llm-agents.nix pipeline (every 4 hours).

Manual update:
```bash
# On devbox
~/.local/bin/pull-workstation

# On macOS
cd ~/projects/workstation && darwin-rebuild switch --flake .
```

### oh-my-opencode Plugin (Manual)
Check for updates:
```bash
bunx oh-my-opencode --version
```

Reinstall to update:
```bash
bunx oh-my-opencode install --no-tui [same flags as initial install]
```

## Troubleshooting

### "OpenCode not found"
Verify Nix package installed:
```bash
which opencode
opencode --version
```

If missing, check home-manager deployed correctly.

### "Plugin not loaded"
Check registration:
```bash
cat ~/.config/opencode/opencode.json | jq -r '.plugins'
```

Reinstall if missing:
```bash
bunx oh-my-opencode install --no-tui [appropriate flags]
```

### Authentication Issues

**Devbox:**
- Claude uses `$CLAUDE_CODE_OAUTH_TOKEN` from sops-nix secret
- Verify: `echo $CLAUDE_CODE_OAUTH_TOKEN`

**macOS:**
- Follow authentication prompts for each provider
- Check credentials for work vs personal accounts

### Agent Not Available

Check which models are configured:
```bash
cat ~/.config/opencode/opencode.json | jq -r '.agents'
```

If a specific agent isn't available, may need to:
1. Enable the provider in config (e.g., `--gemini=yes`)
2. Authenticate the provider
3. Verify subscription is active

## References

- OpenCode docs: https://opencode.ai/docs
- oh-my-opencode repo: https://github.com/code-yeongyu/oh-my-opencode
- Installation guide: https://github.com/code-yeongyu/oh-my-opencode/blob/master/docs/guide/installation.md
```

**Step 3: Register skill in claude-skills.nix**

Add to `crossPlatformSkills` list in `users/dev/claude-skills.nix`:

```nix
crossPlatformSkills = [
  "ask-question"
  "beads"
  "notify-telegram"
  "using-chatgpt-relay-from-devbox"
  "using-oh-my-opencode"
];
```

**Step 4: Commit skill and deployment config**

```bash
cd ~/projects/workstation
git add assets/claude/skills/using-oh-my-opencode/SKILL.md users/dev/claude-skills.nix
git commit -m "feat: add using-oh-my-opencode skill

- Document OpenCode installation and configuration
- Cover platform-specific subscription configs (devbox vs macOS)
- Include agent reference and usage patterns
- Add troubleshooting guide"
```

---

## Task 7: Deploy Skill to Both Platforms

**Files:**
- Deploy: `~/.claude/skills/using-oh-my-opencode/SKILL.md` (both platforms)

**Step 1: Push skill to GitHub**

```bash
cd ~/projects/workstation
git push origin main
```

Expected: Pushed successfully

**Step 2: Deploy to devbox**

```bash
# On devbox (or wait for auto-update)
~/.local/bin/pull-workstation
```

Expected: Skill deployed to `~/.claude/skills/using-oh-my-opencode/`

**Step 3: Verify skill on devbox**

```bash
# On devbox
ls -la ~/.claude/skills/using-oh-my-opencode/
cat ~/.claude/skills/using-oh-my-opencode/SKILL.md | head -20
```

Expected: Skill file exists and is readable

**Step 4: Deploy to macOS**

```bash
# On macOS
cd ~/projects/workstation
git pull origin main
darwin-rebuild switch --flake .
```

Expected: Skill deployed to `~/.claude/skills/using-oh-my-opencode/`

**Step 5: Verify skill on macOS**

```bash
# On macOS
ls -la ~/.claude/skills/using-oh-my-opencode/
cat ~/.claude/skills/using-oh-my-opencode/SKILL.md | head -20
```

Expected: Skill file exists and is readable

**Step 6: Test skill invocation**

In a new Claude Code session on either platform:
```
Can you tell me about the using-oh-my-opencode skill?
```

Expected: Claude recognizes and can invoke the skill

---

## Task 8: Update Automated Updates Documentation

**Files:**
- Modify: `.claude/skills/automated-updates/SKILL.md` (mention OpenCode)

**Step 1: Add OpenCode to update pipeline documentation**

Add to the "What Gets Updated" section in `.claude/skills/automated-updates/SKILL.md`:

```markdown
## What Gets Updated

The pipeline updates the `llm-agents` input in `flake.lock`, which provides:

- **claude-code**: Official Claude Code CLI
- **ccusage**: Usage analytics and statusline
- **beads**: Distributed issue tracker
- **opencode**: OpenCode CLI (alternative AI coding tool)
- **ccusage-opencode**: Usage tracking for OpenCode

All packages use Numtide's binary cache for fast updates.

**Note**: The oh-my-opencode *plugin* is NOT managed by this pipeline. It's installed manually per-machine via `bunx oh-my-opencode install`. See the `using-oh-my-opencode` skill for update instructions.
```

**Step 2: Commit documentation update**

```bash
cd ~/projects/workstation
git add .claude/skills/automated-updates/SKILL.md
git commit -m "docs: add OpenCode to automated updates skill

- Clarify that OpenCode CLI is auto-updated via llm-agents
- Note that oh-my-opencode plugin requires manual updates
- Reference using-oh-my-opencode skill for plugin management"
```

**Step 3: Push and deploy**

```bash
git push origin main
```

Expected: Auto-deployed to both platforms via existing pipelines

---

## Task 9: Test End-to-End on Both Platforms

**Files:**
- Test: OpenCode + oh-my-opencode functionality

**Step 1: Test basic OpenCode on devbox**

```bash
# On devbox
cd /tmp
mkdir -p opencode-test-devbox && cd opencode-test-devbox

cat > test.py << 'EOF'
def fibonacci(n):
    if n <= 1:
        return n
    return fibonacci(n-1) + fibonacci(n-2)
EOF

opencode "add type hints and a docstring to this function"
```

Expected: OpenCode modifies the file with agent assistance

**Step 2: Test ultrawork mode on devbox**

```bash
# On devbox, same directory
echo "# TODO: optimize fibonacci" >> test.py
opencode "ultrawork: make this fibonacci implementation efficient using memoization"
```

Expected: oh-my-opencode agents work in parallel/background to implement solution

**Step 3: Test basic OpenCode on macOS**

```bash
# On macOS
cd /tmp
mkdir -p opencode-test-macos && cd opencode-test-macos

cat > test.ts << 'EOF'
interface User {
  name: string;
  email: string;
}

function createUser(name: string, email: string): User {
  return { name, email };
}
EOF

opencode "add input validation to createUser"
```

Expected: OpenCode modifies the file with agent assistance

**Step 4: Test agent selection on macOS**

```bash
# On macOS, same directory
opencode "oracle: why should I validate email format in createUser?"
```

Expected: Oracle agent (GPT-5.2) provides consultation on validation rationale

**Step 5: Verify platform-specific model availability**

```bash
# On devbox - should use Claude Max 20x
opencode --debug "what model are you using?" 2>&1 | grep -i "claude\|model"

# On macOS - should have multiple models available
opencode --debug "what models do you have access to?" 2>&1 | grep -i "claude\|gemini\|copilot"
```

Expected: Debug output shows correct model configurations per platform

**Step 6: Document test results**

Create test report:
```bash
cd ~/projects/workstation
cat > docs/test-reports/2026-02-02-oh-my-opencode-testing.md << 'EOF'
# oh-my-opencode Testing Results

**Date**: 2026-02-02
**Platforms**: devbox (Linux), macOS

## Devbox Tests
- [x] OpenCode CLI installed via Nix
- [x] oh-my-opencode plugin registered
- [x] Claude Max 20x accessible
- [x] ChatGPT Plus accessible
- [x] Basic code generation works
- [ ] ultrawork mode tested (fill in results)

## macOS Tests
- [x] OpenCode CLI installed via Nix
- [x] oh-my-opencode plugin registered
- [x] Claude API accessible
- [x] Multiple models available (Claude, GPT, Gemini, Copilot)
- [x] Basic code generation works
- [ ] Agent-specific invocation works (fill in results)

## Notes
(Add any observations, issues, or unexpected behavior here)
EOF
```

**Step 7: Commit test results**

```bash
git add docs/test-reports/2026-02-02-oh-my-opencode-testing.md
git commit -m "test: add oh-my-opencode installation verification report

- Document successful installation on both platforms
- Track model availability per platform
- Placeholder for detailed test results"
```

---

## Post-Implementation Checklist

- [ ] OpenCode installed via Nix on both platforms
- [ ] Automatic updates configured via existing llm-agents pipeline
- [ ] oh-my-opencode plugin installed on devbox (max20 + openai)
- [ ] oh-my-opencode plugin installed on macOS (claude + openai + gemini + copilot)
- [ ] Skill documentation created and deployed to both platforms
- [ ] Automated updates documentation updated
- [ ] End-to-end testing completed on both platforms
- [ ] Test results documented

## Future Maintenance

### Updating OpenCode
Automatic via llm-agents.nix pipeline (every 4 hours).

### Updating oh-my-opencode Plugin
Manual on each platform:
```bash
bunx oh-my-opencode install --no-tui [appropriate flags]
```

Check for updates monthly or when new features are announced.

### Adding New Agents
If oh-my-opencode adds new agents or models:
1. Review agent requirements (subscription needed?)
2. Update subscription flags if adding new provider
3. Reinstall plugin with updated flags
4. Update skill documentation with new agent info

## References

- llm-agents.nix: https://github.com/numtide/llm-agents.nix
- OpenCode: https://opencode.ai
- oh-my-opencode: https://github.com/code-yeongyu/oh-my-opencode
- Workstation repo automated updates: `.claude/skills/automated-updates/SKILL.md`
