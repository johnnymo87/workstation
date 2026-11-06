# Audit: 14 assigned skills, plus monitoring-deployments deployment check

Read-only; nothing was modified. Repo at `d4775bfe`. `S/` = `workstation/assets/opencode/skills/`, `A` = `assets/agents/AGENTS.md`, `ocfg` = `users/dev/opencode-config.nix`, `osk` = `users/dev/opencode-skills.nix`.

## Shared mechanisms and findings

- **How INTERNAL.md gets there.** The `confluenceSkills` list (`osk:182-189`) fetches five pages: k8s, aks-rbac, monitoring-deployments, jenkins and tagging-sessions. `home.activation.fetchConfluenceSkills` (`osk:420-425`) runs them through `nvim --headless … FetchConfluencePage`, only on Darwin or cloudbox. It does a preflight (`osk:209-250`) and writes through a temp file and swap (`osk:296-332`). Out of scope, except that three skills defer to it correctly: `reading-jenkins-builds:10-13`, `working-with-kubernetes:10` and `escalating-azure-aks-rbac:32-42`.
- **Where the skills deploy.**
  - escalating-azure-aks-rbac (`osk:72`) and monitoring-deployments (`osk:74`) are both in `workOnlySkills`. They deploy to macOS and cloudbox only (`osk:404-409`). Neither has a row in `A:63-86`.
  - monitoring-deployments ships `monitor-rollout.py` (`osk:152-157`). `test_monitor_rollout.py` is not deployed and runs in CI (`flake.nix:2636`).
  - **monitoring-deployments consumers:** lgtm-deploy `src/rollout.ts:314` and `src/rolloutWake.ts:274` (both have tests), and `hosts/cloudbox/configuration.nix:1559` (`LGTM_ROLLOUT_SCRIPT`).
  - **Stale path:** `lgtm/src/rollout.ts:314` still defaults to `~/.config/opencode/skills/monitoring-deployments/…`. The `cleanupLegacySkillsDir` step (`osk:362-400`) removes that directory.
- **Description person.** Nine of the 14 open with "Use when" (imperative, not third person): using-gws, using-atlassian, formatting-slack, pagerduty, rollbar, figma, k8s, aks-rbac, buildbuddy. using-chatgpt-relay opens with "Send". Third-person openings: ask-question, slack-mcp-setup ("Sets up"), jenkins ("Reads") and gcloud-bq ("Gotchas and…", a fragment). All are 1024 characters or less, and every name matches its directory.
- **AGENTS.md table restates descriptions.** The rows at `A:67-84` repeat or extend the skills' own descriptions, and harnesses list those descriptions anyway. The longest rows are formatting-slack `A:71`, k8s `A:81` and jenkins `A:84`. Verdict: TRIM each to a name and a three-to-five-word purpose, or drop the table entirely. None of these rows was touched by #797 (blame: `35f1a2e2`, `61a5fa8c`, `f412ccbe`, …).
- **AGENTS.md always-loaded sections that duplicate skills:**
  - `A:327-337` (Jenkins) duplicates the table at `reading-jenkins-builds:48-53`. It sits in every devbox prompt, where Jenkins does not exist. Verdict: MOVE to the jenkins skill, leaving at most one line ("load reading-jenkins-builds before touching Jenkins").
  - `A:339-349` (read-only DB) duplicates `working-with-kubernetes:12-49`. It qualifies as a standing hard rule, so KEEP-INLINE, but only as a two-line rule plus a pointer to the skill.

### The four *-mcp-setup skills: merge or keep

**Content they share, near-verbatim:**
- Platform table: slack:11-14, pd:10-13, rollbar:13-16, figma:14-17.
- Keychain `security add-generic-password … -U`: slack:192, pd:39, rollbar:61, figma:127.
- sops set via `/run/wrappers/bin/sudo` with a token file: pd:59, rollbar:82, figma:104. slack:210 differs: it uses `sudo` with the token inline on the command line, so the token lands in shell history.
- Apply commands: slack:218-221, pd:66-68, rollbar:89-91, figma:111-112.
- Verify `jq`: slack:226, pd:51/75, rollbar:73/98, figma:134.
- Rotation: slack:231-243, pd:125-133, rollbar:188-197, figma:152-162.
- "sudo must be owned by uid 0": pd:165, rollbar:207.
- Gemini warning: pd:80-88, rollbar:103-109.
- Global enable via `jq` flip: pd:113-121, rollbar:128-140.
- In code, all four use the same `keychainMirror`, `sopsPresent` and `secretRef` helpers (`ocfg:475-520`). The same pattern is already written up in repo-local `workstation/.agents/skills/managing-secrets/SKILL.md:37-101` ("Option D").

**Setup and rotation are workstation-repo work.** They edit `secrets/cloudbox.yaml` and need a switch. Comparable skills (setting-up-devcycle-mcp, -wiz-mcp, -notion-mcp) are already repo-local in `workstation/.agents/skills/`.

**Recommendation: do not merge into one global skill.**
- Move the shared token recipe into one place: repo-local managing-secrets, or a new repo-local `setting-up-token-mcp`.
- Keep a small global skill per server holding only what an agent needs at use time:
  - slack: the gates table and why `slack-ro` stays read-only.
  - figma: quota rules and the hardening list.
  - rollbar: the triage flow.
  - pd: the warning about arming write tools.

**What breaks under a rename or delete:**
- The skill names are cited by activation stderr in `ocfg:1655,1804,1901,1938,1977,2014,2052,2088` ("see the X-mcp-setup skill").
- Also `hosts/cloudbox/configuration.nix:439` (figma), `workstation/.agents/skills/setting-up-devcycle-mcp/SKILL.md:235` (pd and rollbar), the rollbar↔pd cross-references (rollbar:165,218 and pd:109), `formatting-slack-messages:168,177` (slack-mcp-setup), and `A:72-75`.
- lgtm and lgtm-deploy `docs/plans/2026-04-30-multi-reviewer-identity-design.md:273` (slack-mcp-setup). That is a plan doc, so low risk.
- No cross-repo file cites any of these skills' headings.

**WRONG-TODAY claims in this group:**
- pd:83-84 and rollbar:105-106 say "cloudbox and macOS both default to Gemini". On both hosts the primary model is `vertexOpusModel` (`ocfg:939-942`, `ocfg:24`). Gemini is only the compaction and subagent tier (`ocfg:970`). The stale comment at `ocfg:2244` carries the same error. Verdict: TRIM both warnings to one line about Gemini-tier subagents, the way figma:172 does.
- pd:51/75 and rollbar:73/98 check `hasToken: type=="string"`. The value is a `{file:…}` reference (`ocfg:475-478`, 1914, 1990), so the check always passes and proves nothing. figma:134-135 has the correct check.
- slack:18 says the server is "injected into opencode.json with the xoxp token". It is injected as a `{file:}` reference (`ocfg:1749`, `secretRef`).
- pd:113-123 and rollbar:128-140 recommend flipping `enabled` by hand and then "restart OpenCode". This contradicts slack:270-272 and managing-secrets:91-101. Neither skill mentions `oc-mcp-enable`, so the swarm_send caveat at pd:110-111 does not go away. The current route is `oc-mcp-enable` (figma:70-78, `enabling-mcp-servers`). Verdict: DELETE the "Global enable" sections and point to enabling-mcp-servers.

## Per-skill verdicts

### ask-question: 87 lines, 6.0 KB (deployed cross)
- **Description:** third person, 251 characters, triggers fine. The `argument-hint` and `allowed-tools` keys (`:4-5`) are Claude Code command frontmatter that opencode ignores. The body is a first- and second-person command template (`:8`, "Help me…"), acceptable for a slash command.
- **Body:** KEEP `:15-72`. TRIM `:74-85`, the bash-timeout and pgrep detail, which `using-chatgpt-relay:198-207` duplicates. Keep it in this skill only, since relay already defers here.
- **Host labels:** `:77` labels its NixOS and "elsewhere" branches correctly.
- **Consumers:** the CLI name appears everywhere (`pkgs/ask-question`, `flake.nix`, `ci.yml`). The skill name appears only at `A:67`, `osk:37` and relay:207. Plan docs don't count.
- **Estimate:** about 80 lines.

### using-chatgpt-relay: 207 lines, 8.4 KB (cross)
- **Description:** "Send…" is imperative; should be "Explains…". 225 characters.
- **DELETE (history or misplaced):**
  - `:123-148`, "Research Caveats": a Letta incident from 2026-04-17 (bead zvul). It is guidance about ChatGPT answers, not the relay; move one line of it to ask-question, or drop it.
  - `:187-190`, the chatgpt-relay bead `cgpt-6ke` pointer.
  - `:194-195`, the commit reference `c866bae`.
- **TRIM:** the ASCII diagram (`:15-37`) to three lines. Also cut `:98-100` (version-bump instructions), which is repo work already covered by the `pkgs/ask-question/default.nix:21-24` header.
- **Verified correct:** the 20-minute default timeout (relay:200 matches chatgpt-relay `src/cli.js:67`). The CLI is installed on all three hosts (`home.base.nix:662-664`). Both tunnel agents carry 3033 (`home.darwin.nix:586-626`, `scripts/update-ssh-config.sh:65,89,216,255`).
- **Unlabelled repo-local reference:** `:73-74` cites `troubleshooting-nixos-host`, which exists only as repo-local `workstation/.agents/skills/troubleshooting-nixos-host`. It dangles outside the workstation repo.
- **Estimate:** about 120 lines.

### using-gws: 142 lines, 6.1 KB (cross)
- **Description:** "Use when", 170 characters.
- **WRONG-TODAY:**
  - `:28-31` says devbox, cloudbox and macOS each have a single config directory, and that `switch-gws` "once supported" a second profile. `switch-gws` exists on devbox (`home.devbox.nix:426-442`), and `gws-alt` is assembled on devbox (`home.devbox.nix:446-449,537`). Cloudbox has a single directory (`home.cloudbox.nix:515,531`). macOS has no declarative gws configuration (`home.darwin.nix` has no match). Verdict: relabel per host.
- **Missing:**
  - On devbox and cloudbox, `credentials.json` is rebuilt from the sops `gws_refresh_token` at every home-manager switch (`home.cloudbox.nix:523-580`). A `gws auth login` re-auth (`:38-88`) is therefore silently undone at the next switch unless sops is updated. Repo-local `configuring-gws` covers that path, but this skill does not mention it.
- **TRIM:** `:42-56` restates AGENTS.md "Bash Environment" (`A:183-207`) and "Backgrounding" (`A:376-417`). Cut it to the one command plus "verify the listener". Also drop the "(learned the hard way)" phrasing.
- **Cross-reference hazard:** `:44-45,52-53` cite AGENTS.md headings by title. If the audit moves those sections, these references break.
- **Estimate:** about 110 lines.

### using-atlassian: 121, 324 and 29 lines (SKILL, REFERENCE, script), 19.6 KB (work-only, plus extras at `osk:125-133`)
- **Description:** "Use when", 158 characters. "from this host" is a vague trigger.
- **DELETE (history):** SKILL `:43-44`, the 2026-10-22 incident narrative. Keep the rule `:40-47`, minus that sentence.
- **WRONG-TODAY:**
  - SKILL `:75,98` and REF `:48,89` tell agents to use `$ATLASSIAN_ASSIGNEE_ID`. It is not set anywhere in `users/`, `hosts/`, `pkgs/` or `shell-env.ts`.
  - REF `:195,244,252` and SKILL `:18` say Confluence downloads are PNG only. `assets/nvim/lua/user/atlassian.lua:452` matches `^image/`.
  - REF `:169,254` say Jira comments are flat because of a "TODO in source". `atlassian.lua` contains no TODO.
- **Placeholders:** the SKILL `:92-99` "Org Config" table holds only placeholders (`PROJ`, `PROJ-5678`). DELETE it, or move it to INTERNAL.md.
- **Unlabelled repo-local reference:** REF `:29,33,298` cite `atlassian-multi-instance`, which is repo-local to the workstation repo.
- **Structure:** REF has a contents list (good) and is linked one level deep (good). TRIM REF Part 2 internals (`:143-147,190-195`) to two lines.
- **Consumers:** `escalating-azure-aks-rbac:37,75` and `adding-opencode-skills:199`. In lgtm and lgtm-deploy, only `docs/plans/2026-06-01-two-phase-context-enrichment-design.md:54,99`.
- **Estimate:** SKILL about 105 lines, REF about 270.

### formatting-slack-messages: 209 lines, 14.0 KB (cross)
- **Description:** 630 characters. Imperative, with a "Use when" opening, an em dash, and an embedded instruction ("do not base64…"). TRIM to about 300 characters, third person.
- **External consumers (high risk):**
  - stall-watch cites this skill's `— Claude` signature and its "draft-approval step": `eng-agent-platform/stallwatch/sw_skill/SKILL.md:110,151`, `stallwatch/remediation.py:153,178,203`, `stallwatch/coordinator_tools.yaml:49`, `tests/test_remediation.py:211` and `tests/test_slack_posting.py:66,85,94`.
  - `enabling-mcp-servers:67`.
  - Any change to `:16-18` (the signature and approval rules) breaks those references in meaning.
- **TRIM:**
  - `:47-51` and `:53-68` repeat the cheat sheet.
  - `:131-140` is the cheat sheet again as a checklist; keep it as the single checklist and cut the prose.
  - `:173-177` duplicates `slack-mcp-setup:116-121`; keep it in setup only.
  - `:181-204` (read-API lossiness): about 24 lines of narrative, including "Naive Claudes (including me…)" at `:193`. Cut to about 8 lines.
- **Split candidate:** `:142-177` (file upload) could become a reference file. The duplicated error table appears at `:164-168` and slack-mcp-setup `:251-253`.
- **Host labels:** cross-deployed, but the Slack MCP exists only on work hosts. The skill says so only implicitly (`:168`).
- **Estimate:** about 140 lines.

### slack-mcp-setup: 291 lines, 15.7 KB (work-only)
- **Description:** third person, 452 characters, contains a "/" sequence. OK.
- **WRONG-TODAY:** `:18` says opencode.json holds the token itself. It holds a `{file:}` reference (`ocfg:1749`).
- **DELETE or TRIM:**
  - `:80-82` (PR #334 "Measured, not assumed").
  - `:26-29`, a "why disabled" list that `:31-46` repeats.
  - `:256`, a single 900-character table cell (cold-cache warm-up). MOVE it to a troubleshooting reference.
- **Duplication:**
  - Upload rationale `:111-121` duplicates formatting-slack `:144-177`.
  - Gate explanation `:31-46` duplicates managing-secrets `:91-101` and enabling-mcp-servers.
  - The shared recipe (`:161-243`) is covered in the merge section above.
- **Missing:** the sops command at `:210` puts the token on the command line, unlike the token-file form the other three use.
- **Split candidate:** "Why a pinned build" plus the patch audit (`:123-159`) is maintainer content; move it to repo-local or a reference.
- **Estimate:** about 170 lines global, the rest moved to repo-local.

### pagerduty-mcp-setup: 175 lines, 9.5 KB (work-only)
- **Description:** "Use when", 142 characters. Triggers are thin: nothing about triaging an incident or acknowledging or resolving.
- **WRONG-TODAY:** the Gemini default claim (`:83-84`), the useless hasToken check (`:51,75`), and the hand-enable route (`:113-123`), all covered in the merge section.
- **Time-sensitive:** `:102-107` ("current example (2026-09)"); the model id also lacks `@default`.
- **TRIM:** the tools table `:137-154` duplicates upstream docs; keep a link plus the write-tools warning at `:156`.
- **Estimate:** about 70 lines global.

### rollbar-mcp-setup: 218 lines, 10.4 KB (work-only)
- **Description:** "Use when", 189 characters.
- **WRONG-TODAY:** the same three items: `:105-106`, `:73,98` and `:128-140`.
- **Time-sensitive:** `:50-52` (April 2025 token change) and `:122-126` (2026-09).
- **KEEP:** the triage flow (`:162-186`), the core use-time content.
- **Duplication:** the curl at `:181-186` needs `$PD_TOKEN`, which is not provided anywhere (the PD MCP gets its token through a file reference). Drop it, or point at `/run/secrets/pagerduty_user_api_key`.
- **Estimate:** about 80 lines global.

### figma-mcp-setup: 180 lines, 9.2 KB (work-only)
- **Description:** "Use when", 320 characters, good triggers.
- **KEEP:** quota (`:48-66`), tools, and hardening (`:140-150`). The `{file:}` verify and the serve-restart guidance are correct (`:118-122`, `:134-135`).
- **Time-sensitive:** `:28` ("Measured 2026-10-12"). Keep as a one-clause "why".
- **Labels:** `:19` labels devbox correctly. The repo-local references at `:121,172` are labelled.
- **Duplication:** shared recipe `:98-129,152-162`.
- **Estimate:** about 120 lines.

### reading-jenkins-builds: 109 lines, 7.4 KB (work-only, plus INTERNAL.md)
- **Description:** third person, 467 characters, good triggers.
- **Body:** concise, a good model. KEEP.
- **Host labels:** `:31-41` labels cloudbox, and `:108` is cloudbox-specific but labelled.
- **Duplication:** `A:327-337` (see the shared section).
- **Consumers:** `scripts/update-ssh-config.sh:184,265`, `home.cloudbox.nix:475`, `home.darwin.nix:1458` and `hosts/cloudbox/configuration.nix:508,2104,6068,6087`, plus `A:84,336`.
- **Estimate:** 109 lines, unchanged.

### working-with-kubernetes: 130 lines, 6.6 KB (work-only, plus INTERNAL.md)
- **Description:** 736 characters, "Use when", three em dashes. The `ba` CLI and AKS estate it promises are only in INTERNAL.md. TRIM to about 400 characters.
- **Title mismatch:** the H1 is "Generic Patterns" (`:6-8`), but the body opens with the database policy. Retitle it.
- **Duplication:** `:12-49` is the long form of `A:339-349`. Keep the skill as the canonical copy.
- **Inconsistency:** `:76` runs `psql $DATABASE_URL`, the pooler URL, while `:60` says to swap the port. Fix the example.
- **Unlabelled macOS path:** `:104` uses `/Users/you/.kube`.
- **TRIM:** best practices `:124-130` restate the content above them.
- **Consumers:** `escalating-azure-aks-rbac:71`, `monitoring-deployments:34,189`, `A:81,348`.
- **Estimate:** about 115 lines.

### escalating-azure-aks-rbac: 76 lines, 4.1 KB (work-only, plus INTERNAL.md; missing from `A:63-86`)
- **Description:** "Use when", 445 characters, good triggers.
- **Body:** fine.
- **TRIM:** `:44-46` and `:21-42` say "the Confluence split" three ways.
- **Path issue:** the relative links at `:71,75` (`../working-with-kubernetes/SKILL.md`) assume co-deployment. That holds, because both skills are work-only.
- **Consumers:** `monitoring-deployments:34,145,190` only.
- **Recommendation:** add a table row to AGENTS.md, or drop the table entirely.
- **Estimate:** about 65 lines.

### using-gcloud-bq-cli: 130 lines, 4.6 KB (work-only)
- **Description:** "Gotchas and patterns for…" is a fragment; should be "Explains…". 160 characters. It is missing triggers such as `Access Denied`, `bigquery.jobs.create` and "active account changed".
- **DELETE (history):** `:8` ("learned the hard way") and the dated incident at `:85-95`; keep one clause.
- **Incomplete:**
  - `:107-109` says a human must re-login. On cloudbox the Mac-driven `gcloud-reauth-refresh` refreshes both CLI and application-default credentials (`home.darwin.nix:222-240`, `assets/gcloud-reauth/refresh.sh:1-30`).
  - It also omits the isolation fix, a per-task `CLOUDSDK_CONFIG`, which the repo already uses at `home.darwin.nix:58,118`.
- **Host labels:** gcloud is in `home.cloudbox.nix:376`; macOS is not stated.
- **Estimate:** about 100 lines.

### using-buildbuddy: 119 lines, 5.3 KB (work-only)
- **Description:** "Use when", 278 characters, one em dash.
- **WRONG-TODAY (partial):** the `:18-21` "Loaded by home.cloudbox.nix initExtra" table. For agent bash on cloudbox, the variables come from `shell-env.ts:85-86`, because initExtra does not run in non-interactive shells (`A:306-325`). macOS is correct (`home.darwin.nix:1400-1406`).
- **Body:** fine. `bb-test-log` is real (`home.base.nix:413-428,672-675`).
- **TRIM:** `:102-106` repeats `:12-13`.
- **Consumers:** `pkgs/bb/default.nix:3`, `home.base.nix:421`, `hosts/cloudbox/configuration.nix:397`, `A:83`.
- **Estimate:** about 105 lines.

## Totals
- **Now:** about 2,540 lines and 123 KB of SKILL, REFERENCE and script files.
- **After cleanup:** about 1,650 lines globally. A further 250 lines or so move to workstation repo-local skills, mainly the MCP setup and rotation recipes and the slack patch audit.
- **AGENTS.md:** `A:63-86` and `A:327-349` shrink from about 4.5 KB to about 1.2 KB.
