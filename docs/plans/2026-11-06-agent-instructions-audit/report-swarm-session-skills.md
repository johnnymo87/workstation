The brief was followed: research only, nothing edited. All 12 skills are in `crossPlatformSkills` (`users/dev/opencode-skills.nix:35-67`). `mkSkill` deploys **only SKILL.md** (`opencode-skills.nix:25-29`), so every new `references/*.md` needs its own `home.file` entry. The cleanest pattern is an attrset per skill, merged in the cross branch at `:365-369`, not the work-only `optionalAttrs` at `:370`:
```nix
swarmMessagingExtras = {
  "${skillsDir}/swarm-messaging/references/cross-machine.md".source =
    "${assetsPath}/opencode/skills/swarm-messaging/references/cross-machine.md";
};
```
The alternative is to change `mkSkill` so it also deploys a skill's `references/` directory. Either way the new files must be `git add`ed before switching, or they deploy as dangling links (adding-opencode-skills §7).

**The most urgent finding is staleness that has already shipped.** pigeon a2c3a66 (#219), merged today, adds coordinators to `swarm_list` and lets them accept relayed messages without contacting the sender's machine first. Its design names workstation `swarm-messaging` and `finding-program-coordinators` as follow-ups (`pigeon/docs/plans/2026-11-06-coordinator-discovery-design.md:120-121`). The devbox daemon already answers `GET /swarm/goose-sessions` with 200. The plugin half reaches agents after each serve pool restarts.

---

## 1. opencode-launch: 515 lines / 27.9 KB (over the 500 limit)
**Description** (354 chars): third person and states what it does, but contains "you" and "wasn't". Its trigger terms leave out `--worktree`, `--tag`, `--model` and `--no-attach`.

**Body**
- **KEEP-INLINE:** Quick Start 11-22, What This Does 24-35, a short flag summary, Attach/Kill/List 449-478, Environment, Prerequisites and Troubleshooting 480-515.
- **MOVE** the MCP material at 63-262 (`--mcp`, `oc-mcp-enable`, scope, security, the failure table), about 200 lines. Two options:
  - (a) `opencode-launch/references/mcp-grants.md`;
  - (b) better: `enabling-mcp-servers/references/opencode.md`. enabling-mcp-servers is the harness-neutral entry point and currently just defers here (`enabling-mcp-servers/SKILL.md:37-39`). Keep `--mcp` as about 10 lines inline.
  - Option (b) means rewording the description, `assets/agents/AGENTS.md:36` ("Also covers `oc-mcp-enable`") and enabling-mcp-servers:37-39.
- **MOVE** the tagging material at 311-406 to `references/tagging.md` (about 45 lines after trimming).
- **TRIM** worktree 264-309 and auto-attach 408-447 to about 25 lines each.
- **DELETE as history or implementation detail:**
  - "an earlier version of this doc said": 101-104
  - verified-on note and older builds: 132-141
  - 2026-10-27 incident: 153-155
  - 2026-10-22 incident dates: 190-192, 199-201, 206-207
  - "Before this fix": 213-215
  - 2026-09-29 worktree-loss incident: 302-303
  - LC_ALL rationale: 348-351
  - timing detail: 360-364
  - tmux env scrub: 395-397
  - pigeon#158 and the design-doc path: 399-403
  - incidents at 435-444, keeping one clause on why `--no-attach` exists
  - Transitional text "Newer doors exempt…": 208

**WRONG-TODAY**
- **297-299:** says merged worktrees are reclaimed by the nightly `reset-workspace` running `work --prune-merged`. It only prunes `~/projects/mono` (`pkgs/reset-workspace/default.nix:1009-1012`). Other repos rely on disk-cleanup, which is cloudbox only (`users/dev/disk-cleanup.nix:5`). On devbox and macOS, nothing reclaims them.
- **300-301:** the prune also spares goose sessions (`pkgs/git-work/default.nix:330`), not only opencode ones.
- **437-438:** "no reaper" is wrong. `oc-attach-reap` sweeps every 15 minutes on Linux (`users/dev/home.base.nix:1409-1445`). It reaps only TUIs whose session is gone, so the `--no-attach` advice still stands.
- **410:** says auto-attach is on "devbox, macOS". `oc-auto-attach` is installed on every host (`home.base.nix:592`). Line 435 already half-corrects this.
- **210:** cites `monitoring-serve-pool`, a workstation repo-local skill (`.agents/skills/monitoring-serve-pool`). It cannot be loaded from other repos. The same pointer is in `pkgs/oc-mcp-enable/default.nix:114`.

**Harness:** inheritance at 372-375 depends on `$OPENCODE_SESSION_ID`. A goose launcher (a coordinator) inherits nothing, and the skill doesn't say so. Goose's equivalent, `honk launch`, is not mentioned anywhere in this skill.

**Duplicates**
- `--no-attach` incident: 435-444 = swarm-shaped-work:85-91
- worktree lifecycle: 297-306 ≈ swarm-shaped-work:76-83 and scheduling-wakes:84-89
- tag inheritance: 370-406 ≈ tagging-sessions:44-47
- "don't route around a failed MCP": 196-201 = enabling-mcp-servers:15-25
- slack-ro discipline: 249-262 ≈ enabling-mcp-servers:66-72
- kill commands: 457-472 = swarm-shaped-work:150-159

**Estimated size after:** about 170 inline, plus 45 for tagging, plus about 130 for MCP (wherever it lands).

**External consumers (by name only):**
- `eng-agent-platform/stallwatch/coordinator_tools.yaml:21,29`
- `eternal-machinery/.agents/skills/running/references/tec-mcp-harness.md:3,73-75` (relies on `--mcp` being documented here)
- `eternal-machinery/docs/runbooks/livia-son-chargen.md:168`
- `assets/agents/AGENTS.md:36`

No section headings are cited by title from outside. Internally, "When `oc-mcp-enable` fails" is cited at line 99.

## 2. swarm-messaging: 585 lines / 35.8 KB (over the limit)
**Description** (708 chars): third person ("Covers…"), but contains "you" and an em dash. It is wordy, and the sentence "The coordinator role is banned here" is body content.

**Body**
- **KEEP-INLINE:**
  - Message economy 22-99, trimming the examples
  - Coordinator ban 101-151, trimmed to about 30 lines
  - Delegated answers 153-194, kept whole because stall-watch relies on it
  - Relay, stale-board and silence rules 203-237 and 286-297
  - Sending, Message kinds, Priority 299-329
  - Receiving 490-514
  - Don'ts 577-585
- **DELETE/TRIM** the incident narrative at 248-284 down to the 3-line rule. It is duplicated verbatim in `shepherding-pull-requests/reference/retired-wake-scheduling.md:85-90`.
- **DELETE** 477-488 (restates scheduling-wakes; keep a one-line pointer) and 536 (tool-name regex trivia).
- **MOVE** "Sessions on other machines" and "Starting a session on another machine: `swarm_launch`" (331-475, 145 lines) to `references/cross-machine.md`. It needs a contents list.
- **MOVE** "Replay & pagination" and "Verifying delivery" (516-575) to `references/delivery.md`.

**WRONG-TODAY**
- **313:** goose sessions and coordinators "never appear" in `swarm_list`. Now they do (pigeon #219, `swarm-list-tool.ts`).
- **113-116 and 378-387:** a coordinator on another machine is no longer refused before it reaches out (D2 of the design). Only non-coordinator `gse_` sessions are.

**Harness:** "opencode-pigeon plugin exposes" (8) ignores goose's `swarm__*` tools. Reading a peer's transcript with curl (530-534) and the `prompt_async` don't (583) are opencode-only and unlabelled.

**Duplicates:** the ban is restated at swarm-shaped-work:10, 36-52 and 165-172, at finding-program-coordinators:18-22, and in `assets/agents/AGENTS.md:37`. The retry backoff (563) repeats in reviving:93.

**Estimated size after:** about 300 inline, plus about 130 and 50 in references.

**Headings cited by title (keep exact text or update the citer):**
- **"Never assert a checkable fact you did not fetch":** cited by `shepherding-pull-requests/reference/retired-wake-scheduling.md:90`, a deployed file.
- **"Sessions on other machines":** cited internally at :8 and :567 (repoint if moved). Also cited at `pigeon/docs/plans/2026-10-30-relay-hold-design.md:113` (a plan).
- **"The relay is part of the failure surface":** internal, :136.
- **"Message economy":** internal, :18.
- **"Starting a session on another machine":** internal, :14.
- **The "kinds table":** `pigeon/.agents/skills/swarm-development/SKILL.md:51` tells pigeon developers to add new kinds "to the kinds table in assets/opencode/skills/swarm-messaging/SKILL.md". Keep "Message kinds" in SKILL.md.

**Other consumers by name:**
- `eng-agent-platform/stallwatch/coordinator_tools.yaml:29`
- `pigeon/packages/daemon/src/swarm/envelope.ts:39` (a comment)
- scheduling-wakes, swarm-shaped-work, finding-program-coordinators and reviving

## 3. scheduling-wakes: 167 lines / 9.1 KB
**Description** (613 chars): starts "Schedules…", which is fine, but contains "you" three times and an em dash.

**Body:** a good skill.
- **DELETE** the measurement anecdote at 33-35.
- **TRIM** the bead ids (`pigeon-0ay7`, `o57l`, `s9d`) at 91-99.
- **DELETE** "it took two sessions comparing notes" at 127.

**WRONG-TODAY:** 85-87 has the same reset-workspace overgeneralization (only mono is pruned).

**Harness:** "handed off to your serve" (52) is opencode wording. Goose now has the `swarm_schedule` tool (honk ac2e358). Whether the deleted-directory failure applies to goose is unverified.

**Duplicates:** 16-29 = `assets/agents/AGENTS.md:42-47`. 152-157 overlaps attributing-causes:311-328.

**Repo-local references:** `resetting-workspace` (163) is labelled repo-local, which is fine.

**Estimated size after:** about 140. **Consumers:** AGENTS.md:38 and :47, swarm-messaging:485, and retired-wake-scheduling.md. No heading is cited by title.

## 4. finding-program-coordinators: 146 lines / 9.2 KB
**Description** (406 chars): third person ("Looks up…"), with "you" three times.

**Body**
- **DELETE** "Why this skill exists" (30-50), the 2026-10-24 and 2026-11-05 incidents. Its table row "`swarm_list` lists opencode only" is now wrong anyway. Keep one line: bead notes, `opencode.db` and session-tags are not the registry.
- **DELETE** "(since 2026-11-04)" at 14 and "Since 2026-10-31" at 101.

**WRONG-TODAY (pigeon #219)**
- **38:** coordinators now appear in `swarm_list`.
- **70 and 140-143:** exit 2 means "this host cannot reach it", but `swarm_list remote: true` now lists other machines' coordinators and they accept relays. The matching text in `eng-agent-platform/stallwatch/find_coordinator.py:212` and `assets/agents/AGENTS.md:39` ("why `swarm_list`… can't answer it") also needs updating, as the pigeon plan's task 7 says.

**Estimated size after:** about 100. **Headings cited by title:** "Before you send" (internal, :68) and "No coordinator found" (internal, :69-70). External consumers are eng-agent-platform plan docs only, by name.

## 5. swarm-shaped-work: 178 lines / 10.9 KB
**Description** (220 chars): starts "Use when". It does say what it covers ("Covers the heuristic…"), and has no "you".

**Body:**
- **TRIM** the ban restatement (10, 165-169); point to swarm-messaging instead.
- **DELETE** the incident at 86-89, keeping one clause, since it duplicates opencode-launch.
- Lines 8 ("on the same machine") and 134-144 ignore `swarm_launch` and cross-machine workers.

**WRONG-TODAY**
- **86-87:** "no reaper" (`oc-attach-reap` exists).
- **82-83:** worktrees are reclaimed only in mono (see opencode-launch above).
- **161:** "the session reaper expire[s] them after 1 week". pigeon's reaper drops only pigeon's own registration. No `deleteSession` is passed (`pigeon/packages/daemon/src/index.ts:1129-1138`), so the opencode session persists.
- **163:** swarm messages "aren't auto-cleaned yet". Retention is wired: `storage.swarm.cleanupOlderThan(now - SWARM_RETENTION_MS)` with a 7-day window (`pigeon/packages/daemon/src/index.ts:1084`, `storage/swarm-schema.ts:4`).

**Estimated size after:** about 115. **Headings:** "When NOT To Swarm" (internal, :66). **Consumers:** AGENTS.md:40 and old workstation plans.

## 6. preparing-for-compaction: 108 lines / 10.7 KB (long lines)
**Description** (224 chars): "Use when… - prepares…". It is second-person framing with a dash, and the what-it-does comes last.

**Body:** sound. The harness-specific material is labelled ("Harness differences", 40-55), which is fine. Optionally:
- **DELETE** "(read this once)" at 14.
- The goose bullets at 49-55 are dense; they could move to `references/goose.md` (about 10 lines saved).

**Unverified:** goose's exact result strings (49-55). Only the honk fixture at `honk/fixtures/self_compact/export.json:90` matches.

**Estimated size after:** about 95. **Consumers:**
- `assets/opencode/plugins/self-compact.ts:82`, the tool description, which says "the final step of the preparing-for-compaction skill": **the skill name must not change**.
- honk and pigeon plan docs.
- **Headings:** "Harness differences" (internal, :16).

## 7. searching-sessions: 96 lines / 3.6 KB
**Description** (192 chars): third person, which is good.

**Body**
- **DELETE** "Design Decisions" (83-96). The README already holds it.
- Lines 45 and 49 carry dated measurements (4.1 GB, about 80 minutes, about 10.9 GB, from `pkgs/oc-search/README.md:48,122`). Round them, or say "about 2.6× the transcript size".

**WRONG-TODAY:** line 50's hourly `oc-search-index.timer` is Linux-only (`home.base.nix:1358,1378`, `mkIf (!isDarwin)`). On macOS nothing keeps the index current.

**Harness:** opencode-only, since it covers `opencode.db` and not goose sessions. That is true to the name, but a goose agent loads it too; add one line saying goose sessions aren't covered.

**Estimated size after:** about 65. **Consumers:** AGENTS.md:56 only.

## 8. tagging-sessions: 120 lines / 6.7 KB
**Description** (413 chars): a noun phrase ("Policy and commands for…"), with no "you". Acceptable.

**Body:** good.
- Line 8 is a rename note; keep it until the `oc-tags` alias is gone.
- Line 21: `which` with no argument uses `$OPENCODE_SESSION_ID` (`pkgs/oc-tags/oc_tags.py:1638-1643`), so in goose it needs `goose:$AGENT_SESSION_ID`, the same as line 23.
- Lines 44-47 duplicate opencode-launch:370-406.

**Verified:** subcommands, `--goose-dir`, `--since`, `ls --counts`, `top --min`, and the `tags.db` path (`oc_tags.py:157,1614-1666`).

**Estimated size after:** about 115. **Consumers:**
- `pkgs/oc-tags/TAG-MAP.md:3-4`
- opencode-launch:322
- `opencode-skills.nix:188`, the Confluence `INTERNAL.md` entry: **the directory name must not change**.

## 9. reviving-worktree-orphaned-sessions: 161 lines / 11.7 KB
**Description** (528 chars): third person ("Diagnoses…"), with concrete log-string triggers. Good.

**Body**
- **DELETE** history: the "Seen" date column (10-13), the inference narrative (15, keep one clause), the incident timestamps (60), "died twice" (129) and "(measured 2026-11-04)" (152).
- The goose section (147-155) is properly labelled.
- The journalctl and sqlite recipes are Linux-only and unlabelled for macOS.

**Verified:** pigeon `ttlMs` is 5 minutes (`directory-resolver.ts:13`), the backoff is `[1s, 2s, 5s, 15s, 60s]` with `MAX_ATTEMPTS = 10` (`arbiter.ts:225-226`), the outage retry is 30 s (`arbiter.ts:235`), the reset-workspace prune is mono-only (:135 is correct), and disk-cleanup is cloudbox only (:134 is correct). `journalctl --namespace=pigeon` is correct on both hosts (`hosts/devbox/configuration.nix:551`).

**Repo-local references:** `monitoring-serve-pool` (159) is labelled repo-local, which is fine.

**Duplicates:** 133 and 145 = `assets/agents/AGENTS.md:98` (the finishing-a-development-branch override). 93 ≈ swarm-messaging:563.

**Estimated size after:** about 140. **Consumers (by name):** `lgtm/src/bazelReap.ts:42`, `lgtm/src/index.ts:2005` (and lgtm-deploy), `eternal-machinery/docs/runbooks/stack-health.md:206`, `users/dev/disk-cleanup.nix:1413,2512`, `pkgs/git-work/default.nix:140`. **Headings:** "Goose sessions" is cited in `docs/plans/2026-11-04-goose-revive.md:183`, a plan.

## 10. adding-opencode-skills: 199 lines / 12.7 KB
**Description** (228 chars): "Use when…" only. It never says what the skill does.

**Body**
- The template at 41 and the name at 37 teach "Use when…" descriptions, which **conflicts with the target design** (third person "Explains/Covers…").
- Nothing about `references/`, its contents list, or "load when". Workflow B (67-78) covers per-file nix entries, which matters for every split above.
- **MOVE** the Gotchas (110-179) to `references/troubleshooting.md`, keeping §7 (dangling link) inline as a one-line warning.
- **DELETE** the worked-example commit at 199 (`348be81` exists, but it is history).

**WRONG-TODAY:** line 153 says "Existing examples: `notifyTelegramScript`". No such attribute exists anywhere in `users/`.

**Estimated size after:** about 140, plus about 60 in the reference. **Consumers:** `assets/agents/AGENTS.md:53` only.

## 11. enabling-mcp-servers: 132 lines / 7.8 KB
**Description** (341 chars): third person, with good triggers.

**Body**
- Harness sections are labelled. The opencode path is a stub that defers to opencode-launch; it is the natural home for the `oc-mcp-enable` material (see §1).
- **TRIM** the 2026-10-22 incident (23-25) to one clause.
- Time-sensitive "not … yet" claims at 96 and 122. The remote-unsupported one is still true (`honk/crates/honkd/src/mcp/catalog.rs:305`).

**Verified:** the `mcp_list`, `mcp_enable` and `mcp_disable` tools (`honk/crates/honk/src/swarm_mcp.rs:2006-2033`), and that macOS has no honkd.

**Missing from the `assets/agents/AGENTS.md` skills table entirely.**

**Estimated size after:** about 125, or about 245 if it absorbs `oc-mcp-enable` as a reference.

**Consumers:** `eng-agent-platform/stallwatch/coordinator_tools.yaml:48`, and `stallwatch/tests/test_slack_posting.py:78`, which asserts the skill **name** appears in that yaml, so **the name must not change**. No heading is cited.

## 12. attributing-causes: 346 lines / 18.4 KB
**Description** (496 chars): "Use when…" with an em dash. It never says what the skill does.

**Body**
- Rules 1-10 (258-300) restate the sections above them almost line for line. Keep one of the two.
- **MOVE** the worked examples (92-189) and the instrument anecdotes (201-256) to `references/worked-examples.md`, keeping one sentence per rule inline.
- Line 194, "in this repo", is meaningless in a global skill.

**Duplicates:** 330-343 ↔ `assets/agents/AGENTS.md:139-146` (which cites this skill for "load-bearing infrastructure"). 311-328 ↔ swarm-messaging:203-229.

**Estimated size after:** about 140 inline, plus about 150 in the reference.

**Consumers:** `assets/agents/AGENTS.md:54,146`, workstation's repo-root `AGENTS.md:249` (a GitHub URL to `attributing-causes/SKILL.md`, so **the path must not change**), and scheduling-wakes:165. No heading is cited.

---

**Cross-cutting**
- **Description style:** six descriptions open with "Use when" (swarm-shaped-work, preparing-for-compaction, adding-opencode-skills, attributing-causes) or contain "you"/"your" (opencode-launch, swarm-messaging, scheduling-wakes, finding-program-coordinators). All are under 1024 characters.
- **No renames are safe:** every skill name is load-bearing somewhere — the self-compact plugin string, stall-watch's yaml and its test, the Confluence fetch entry, and the repo-root AGENTS.md URL.
- **Repo-local skills:** a few pigeon skills are cited from global ones (`cross-device-deployment`, `swarm-operations`, `swarm-architecture`). They are labelled as pigeon's and load only inside the pigeon repo.
- **Recent edits:** swarm-messaging (#803) and finding-program-coordinators (#805) were both edited today. Coordinate before splitting them.

Only scratch files were written: `/tmp/opencode/wsaudit/headings-sessions.tsv` and `hpat-sessions.txt`.
