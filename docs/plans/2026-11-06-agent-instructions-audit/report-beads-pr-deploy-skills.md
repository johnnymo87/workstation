# Audit report: beads, migrating-beads-schema, shepherding-pull-requests, reviewing-github-prs, monitoring-deployments, cleaning-disk

`S=` `workstation/assets/opencode/skills`. Checked against origin/main `d4775bfe`, bd 1.1.0, lgtm `d99b5a4`, beads repo `fe12a44ca` (v1.1.0-32). Nothing was modified.

## Deployment check (users/dev/opencode-skills.nix)
- **beads:** all 4 references are deployed (`:114-123`). Nothing is on disk without being deployed, and nothing deployed is missing.
- **shepherding-pull-requests:** `monitor-pr.py` and all 3 `reference/*.md` files are deployed (`:138-149`). Complete.
- **monitoring-deployments:** `monitor-rollout.py` is deployed, work-only (`:152-157`, `:374`). `test_monitor_rollout.py` (514 lines) is not deployed, which is correct because only the flake check uses it (`flake.nix:2636`). `INTERNAL.md` is fetched from Confluence (`:186`).
- **Mismatches with AGENTS.md:**
  - cleaning-disk is in the `workOnlySkills` list (`:71`), so devbox does not get it. Yet AGENTS.md `:86` says it is "Reclaim disk on devbox/macOS", and the skill body covers devbox.
  - monitoring-deployments has **no row** in the AGENTS.md skills table.

---

## 1. beads: SKILL.md 451 lines / 22.1 KB, plus 4 references (2,467 lines / 74 KB)

**Description (238 chars):** written as an imperative ("Activate…"), not third person. The triggers are fine. It names `TodoWrite`, which is an opencode/Claude tool name, so the shared skill carries harness-specific wording.

**Body**

| Section | Verdict |
|---|---|
| 11-19 Session Activation | KEEP |
| 21-55 Claim Before You Start | KEEP the rule and commands (36-51). DELETE the incident at 27-31 (`pigeon-8cz`, 2026-08-03/04) and 53-55 |
| 57-66 bd vs TodoWrite | KEEP. BOUNDARIES.md (518 lines) repeats it |
| 68-197 Running a whole project | KEEP. It is cited by title (see consumers). DELETE the incident at 139-143 ("happened while writing this section") |
| 199-224 Quick reference | KEEP |
| 226-268 Never `--notes` | KEEP the rule (228-236) and recovery (257-268). DELETE the incident at 238-255 (80,290 / 38,903 chars, dates) or cut it to one clause |
| 270-289 Handoff and checklist | KEEP |
| 291-323 Git hook policy | TRIM to about 8 lines. 301-307 is upstream history |
| 325-442 Git-free and DoltHub setup | MOVE-TO a new `references/DOLTHUB_SETUP.md`. It is setup-time only and holds a credential keyid (375-376). DELETE history: 427-432 ("tried git-backed … 2026-06-12") and 434-442 (sqlite migration for bd ≤0.58) |

**References: upstream status**
- They are stale forks of the beads repo's own skill, last synced around 2026-01, and then edited locally.
- The nearest upstream match is `025142d55` (2026-01-02) at `skills/beads/resources/*`. Diff lines against it: DEPENDENCIES 69, BOUNDARIES 49, WORKFLOWS 268.
- The upstream skill now lives at `plugins/beads/skills/beads/` (110-line SKILL.md, 15 resources), and upstream folder name is `resources/`, not `references/`.
- Upstream `CLI_REFERENCE.md` is now a 13-line stub saying "does not bundle a copied CLI command reference… would drift". It points to `bd prime` and `bd help --all`. The workstation copy is 686 lines and no upstream version matches it.
- All four have a contents list. Nesting is one level deep.

**WRONG-TODAY claims in the references (checked against bd 1.1.0)**
- `CLI_REFERENCE.md:3` and `WORKFLOWS.md:3` say "v0.42+".
- `CLI_REFERENCE.md:20,63,258-266`: `bd relate`. bd answers `unknown command "relate"`; it is now `bd dep relate`.
- `CLI_REFERENCE.md:26,314,320`: "Soft delete (tombstone)… `bd cleanup`". `bd delete --help` says it permanently deletes, and `bd cleanup` is an unknown command. The beads changelog (`cmd/bd/info.go:612`) records that tombstones were removed.
- `CLI_REFERENCE.md:87-88`: `--no-auto-flush` and `--no-auto-import` give "unknown flag".
- `CLI_REFERENCE.md:393,589-618`: JSONL auto-export, "issues.jsonl source of truth (git-tracked)" and the `.gitignore` advice. All three contradict the git-free model taught in SKILL.md 298 and 336-344.
- `CLI_REFERENCE.md:404`: `bd import --resolve-collisions` does not exist.
- **The `discovered-from` direction is reversed** at `DEPENDENCIES.md:460`, `WORKFLOWS.md:104` and `CLI_REFERENCE.md:218,494`. They write `bd dep add <original> <discovered>`. Upstream fixed this to `bd dep add <discovered> <original>` (upstream `DEPENDENCIES.md:457`, `WORKFLOWS.md:102`), which matches `bd dep add` semantics where the first argument depends on the second.

**Recommendation:** drop CLI_REFERENCE.md and point to `bd prime` and `bd <cmd> --help`, as upstream does. Re-sync or drop the other three. BOUNDARIES is mostly a TodoWrite essay that duplicates SKILL.md 57-66.

**Consumers**
- Global path `~/.agents/skills/beads/SKILL.md`: `pigeon/AGENTS.md:660`, `eng-agent-platform/AGENTS.md:153`.
- **Cited by title:** "Running a Whole Project on Beads" in `eng-agent-platform/docs/plans/2026-09-23-bead-board-reorganization.md:6` and in stall-watch fixture and bench data (`stallwatch/tests/data/cases_raw.json`, `bench/classifier/data/review.md:1608`).
- "Workstation setup (DoltHub)" is cited internally at SKILL.md:347. `migrating-beads-schema:36-38,397` points to the beads skill for "the full list" of trackers, which the beads skill does not actually contain (402 names only four).

**Size after cleanup:** SKILL about 260 lines / 12 KB, plus DOLTHUB_SETUP.md about 90 lines. References about 20-30 KB if re-synced, or 0 if replaced by `bd prime`.

---

## 2. migrating-beads-schema: 398 lines / 18.9 KB

**Description (646 chars):** third person ("Resolves…"). Good trigger strings. It is long, contains dashes, and names "stopping a stale bd daemon", which is obsolete (see below).

**WRONG-TODAY: stale bd daemon**
- Affected lines: 41-44, 68-79, 85, 187, 199, 387, and the description.
- bd 1.1.0 answers `unknown command "daemon"`. The changelog says "Daemon subsystem fully removed from bd CLI" in v0.49.6 (`beads/cmd/bd/info.go:658-662`).
- DELETE the section and its checklist steps.

**Body**

| Section | Verdict |
|---|---|
| 9-25 Guard intro | KEEP |
| 27-47 Facts | KEEP, minus the daemon bullet (41-44). The flaky-embedded-clone bullet (45-47) may be historical but cannot be verified |
| 49-66 Step 0 | KEEP |
| 81-178 Procedure A | KEEP |
| 180-277 Procedure B | KEEP |
| 279-317 Known defect 0037 | MOVE-TO `references/0037-uuid-default.md`. It only breaks bd ≤1.0.5 (297-300), and 1.1.0 is installed everywhere. DELETE "fleet-verified 2026-07-04" (281, 348) and "verified on comptes" (294) |
| 319-363 Verification | KEEP. 345-360 on nixpkgs dolt 1.59.10 is still true (`nix eval nixpkgs#dolt.version` gives 1.59.10) |
| 365-377 Cleanup of git dolt refs | KEEP, or cut to one line. It duplicates `beads/SKILL.md:429-430` |
| 379-398 Safety rules and related | KEEP |

**Hazard:** line 119 runs `dolt commit --author "bd repair <dev@$(hostname)>"`. That is an invented identity. It is dolt, not git, but it runs against the spirit of AGENTS.md:259 ("Commit As The Human").

**Verified correct:** `BD_ALLOW_REMOTE_MIGRATE=1 bd migrate` (`beads/internal/storage/schema/remote_migrate_gate.go:18,187`), `bd bootstrap --yes`, `bd dolt push --remote`, `bd export --all -o`.

**Consumers:** AGENTS.md:59 table row and `workstation/docs/notes/2026-09-01-bd-long-text-input-ergonomics.md`. No heading is cited by title.

**Size after cleanup:** about 300 lines / 14 KB, plus a 40-line reference.

---

## 3. shepherding-pull-requests: SKILL.md 477 lines / 38.8 KB, plus 3 references (262 lines / 31 KB) and monitor-pr.py (1,070 lines)

**Description (536 chars):** written in second person ("a pull request you author", "you are about to"). The triggers are strong. It uses `--` dashes.

### WRONG-TODAY, all checked against code

1. **The lgtm re-request rules are outdated.**
   - Affected: SKILL.md:60, 384, 403-411, 417-420, 444; `lgtm-review-mechanics.md:64, 76-83, 88-101`; `common-mistakes.md:9, 11`.
   - They say tier 0b re-reviews only when `reviewDecision == REVIEW_REQUIRED`, and that an empty or `CHANGES_REQUESTED` decision needs one re-request.
   - lgtm#93 (`6b1d52f`, 2026-09-07) changed that. `lgtm/src/settledRereview.ts:186-240` now admits `REVIEW_REQUIRED`, `CHANGES_REQUESTED`, and null when a reviews read confirms no approval. It also re-reviews an `APPROVED` whose patch no longer covers the head (`:200-229`).
   - Still true: "you replied without pushing, so re-request once" (`head-already-reviewed`, `:177`).
   - `lgtm-review-mechanics.md:101` ("Once that is deployed the precondition above relaxes") is now simply the present state.
2. **The wake budget numbers are wrong.** SKILL.md:38 says "8 per signal, 12 total, 15 hard ceiling". The code has 12, 18 and 23, with up to 5 refunds per signal (`lgtm/src/agentRouting.ts:84, 93, 111, 117`).
3. **The routed-signals list is incomplete.** SKILL.md:21, `retired-wake-scheduling.md:5` and `common-mistakes.md:14` omit `base_merged`, which `agentRouting.ts:161` includes.
4. **lgtm-shepherd is not cloudbox-only.** SKILL.md:25 says "on cloudbox journalctl…", but devbox runs it too (`hosts/devbox/configuration.nix:849` with timer `*:7/10`, `LGTM_ENABLE_AGENT_ROUTING=1` at `:811`). `lgtm.yml:79-94` assigns repo ownership per box.
5. **devbox now has lgtm.yml.** `lgtm-review-mechanics.md:31` says "If lgtm.yml doesn't exist (e.g. devbox)…". devbox has it now.
6. **The exit-code table is wrong.** SKILL.md:298-303 lists codes 0-3 and says code 3 covers "CI pending". `monitor-pr.py:73, 1062` adds `EXIT_CI_MOVING = 4` for pending CI; 3 now means settled and waiting.
7. **The script contradicts the skill's wake ban.** `monitor-pr.py:1058` prints "Reschedule the next wake and END THE TURN" under `--once`, and `:977` says the same in help. SKILL.md:8-13 bans scheduling wakes.
8. **A cited heading does not exist.** `common-mistakes.md:21` cites `receiving-code-review §"Address Every Item"`, and that skill has no such heading.
9. **"landable requires an approval" is not strictly true.** SKILL.md:446 says it does, but `lgtm/src/shepherdFetch.ts:678` says `landable` "may fire once on an unapproved PR". Minor.

### Body
- 8-47 (the ⛔ banner): TRIM to about 12 lines. The budget detail and the "verify" journalctl line belong in a reference.
- 49-63 standing expectation and 65-71 references: KEEP.
- 75-139 dot graph: TRIM or DELETE. It restates the prose and costs about 3 KB.
- 141-178 title and description template: KEEP. Note that `[PROJ-XXXX]` is the work convention, and the skill is cross-deployed.
- 180-223 pre-PR checks:
  - KEEP the rebase and stowaway checks.
  - 212-223 (author emails) DUPLICATES AGENTS.md:259-287 "Commit As The Human". Cut it to a pointer plus the `--format='%h %ae'` command.
- 225-273 adversarial review:
  - 229-245 DUPLICATES AGENTS.opencode.md:23-87 (handle per host, astra failure, `astra-probe`, the empty-result rule). That material is harness-specific in a cross-harness skill.
  - 229 holds rename history ("before the 2026-09-28 rename … -fable"). DELETE.
  - KEEP the skip rule (247-260) and what-to-send (262-267).
  - 271 restates AGENTS.md:122 "Reporting to Humans". Cut to a pointer.
- 275-312 post-PR monitoring and tooling: KEEP. Fix the exit table.
- 313-335 "Approval is durable" and "two reviews": TRIM. lgtm now re-reviews a stranded approval (finding 1), so the claim at 315 needs qualifying.
- 337-352 lgtm-bound: KEEP.
- 354-386 loop body: KEEP. Line 358 restates the AGENTS.md:183 bundled-sleep rule; cut to a pointer.
- 388-420 re-requesting: REWRITE per finding 1.
- 431-446 stalled-but-healthy:
  - KEEP the rule and the two `gh` commands.
  - DELETE the incidents at 435 (`monorepo#4476`, 2026-09-02) and 444 (`js-repo#208`, 2026-09-04).
- 448-454 "Merging stays with the human": KEEP the rule. DELETE the incident at 452.
- 456-473: KEEP.
- 475-477 rollout: KEEP.

### References
- **`retired-wake-scheduling.md` (116 lines):** DELETE most of it. It documents a mechanism the skill bans, and its payload template (97-104) tells the agent to "Follow … section 'The watchdog'", which is now a dead instruction. Keep only the 9-14 cost-model paragraph, moved into SKILL.md:462-465, which already summarizes it. Its contents list sits at line 16, after the intro rather than at the top.
- **`lgtm-review-mechanics.md` (107 lines):** has a contents list (7-14), but it describes six topics while the headings are only `###` and `####`. It is mostly incident narrative: 33-50 (the "author of this very section got it wrong" story), 72-74, 84, 88-97, 105. REWRITE per finding 1 to about 40 lines.
- **`common-mistakes.md` (39 lines):** KEEP. DELETE the dated incidents (8, 11, 22) and fix the cite at 21.
- Nesting is one level deep. The references point back to SKILL.md, which is fine.

### Cross-repo conflict
SKILL.md:448-454 says "Do not run `gh pr merge`" with no exception. `eternal-machinery/AGENTS.md` ("Landing changes") says agents may merge their own PRs once `CI Passed` is green. AGENTS.md:85 repeats the never-merge rule. This should be resolved explicitly, either as a per-repo override or in the skill.

### Consumers and title citations
- `eng-agent-platform/stallwatch/remediation.py:150, 173, 209` (prompt text: "load shepherding-pull-requests before `gh pr create`"), plus its test at `stallwatch/tests/test_remediation.py:208`.
- `lgtm/src/agentRouting.ts:531`: the wake payload quotes "Merging stays with the human" verbatim (heading text). Same in lgtm-deploy.
- `lgtm/src/shepherd.ts:9`: a comment.
- `workstation/.agents/skills/opencode-agents/SKILL.md:34`: cites **§"Pre-PR Checks" step 3**.
- `workstation/users/dev/test-monitor-pr-*.sh` hard-codes the script path.
- `opencode-config.nix:318` and `reviving-worktree-orphaned-sessions/SKILL.md:161`.
- AGENTS.md:85 and :97 cite "pre-PR checks", "stalled-but-healthy trap" and "never gh pr merge".
- Internal: `common-mistakes.md` cites §"Merging stays with the human" and §"The stalled-but-healthy trap". SKILL.md cites §"Re-requesting review", §"When the only thing left is waiting", §"Loop body", §"Post-PR Monitoring".
- About 40 docs/plans files across repos mention the skill name. They are history and need no action.

**Size after cleanup:** SKILL about 300 lines / 22 KB. References about 80 lines total (retired file deleted).

---

## 4. reviewing-github-prs: 275 lines / 15.5 KB

**Description (263 chars):** starts "Use when posting…". Not third person, and uses a dash. Good triggers.

**Body:** current-truth mechanics with no incident narrative, and it is the cleanest of the six.
- KEEP 17-62 and 64-236.
- TRIM 238-265 (Common Mistakes): it repeats 31-35 and 112-114 ("Replying without resolving" appears three times: 86, 114, 265, and again in shepherding).
- 93-103 (alternative `in_reply_to` form): DELETE. The skill already prefers `/replies`.

**WRONG-TODAY / gaps:** the REST listings at 51-61, 82 and 273 have no `--paginate`, so a PR with more than 30 comments silently truncates. `monitor-pr.py:127` does paginate. The GraphQL `reviewThreads(first: 100)` at 127 and 167 is not paginated.

**Consumers:**
- `shepherding SKILL.md:376, 427`, `common-mistakes.md:20,21`, and `monitor-pr.py:838`.
- **Cited by title:** §"Resolving review threads" (`common-mistakes.md:20`) and "the unresolved-threads filter query" (SKILL.md:427).
- No consumers outside workstation.

**Size after cleanup:** about 220 lines / 12 KB.

---

## 5. monitoring-deployments: 190 lines / 10.1 KB, plus monitor-rollout.py (836) and test (514); work-only

**Description (409 chars):** starts "Use when…". Not third person, and uses `--`. Good triggers.

**Body**
- KEEP 8-71: the exit codes match `monitor-rollout.py:153-157`.
- KEEP 72-125 (merge queues). It is current and useful.
- 127-147 (fix step): DELETE the parenthetical incident at 135-140 (`monorepo#4613`), or cut it to one clause.
- 149-166: KEEP.
- 168-184: KEEP the rule (170-174 and 181-184). DELETE the measurement at 176-179 (2026-09-12, ReplicaSet hash).

**Hazard:** `lgtm/src/rollout.ts:314` defaults to `~/.config/opencode/skills/monitoring-deployments/monitor-rollout.py`, which is the pre-#690 path. lgtm-deploy has the fixed `~/.agents/...` path, and cloudbox sets `LGTM_ROLLOUT_SCRIPT` explicitly (`hosts/cloudbox/configuration.nix:1559`), so only the fallback is stale.

**Consumers:**
- `lgtm/src/rolloutWake.ts:274` and the lgtm-deploy copy: "the `monitoring-deployments` skill explains the exit codes and the cluster layout". This depends on the exit-code table staying in this skill.
- `rollout.ts:314` path, `hosts/cloudbox/configuration.nix:1559`, `flake.nix:2636`.
- No heading is cited by title.

**Size after cleanup:** about 175 lines / 9 KB.

---

## 6. cleaning-disk: 259 lines / 8.7 KB; work-only (macOS and cloudbox)

**Description (244 chars):** imperative ("Reclaim…"), not third person. It says "any NixOS host (devbox, cloudbox)", but devbox does not get the skill (`opencode-skills.nix:71`).

**WRONG-TODAY**
- **Worktree age:** 14 says "28+ days old". The code has `WORKTREE_MAX_AGE_DAYS=14` and a 2-day floor (`users/dev/disk-cleanup.nix:1391, 1395`).
- **Incomplete step list:** 12-18 omits Docker prune and opencode.log rotation (`disk-cleanup.nix:2338-2340`: `cleanup_docker`, `rotate_opencode_log`).
- **devbox jobs missing:** 10 says "cloudbox only" and says nothing about devbox's own automation: `tmp-scratch-sweep` (02:00, `:3136, 3214`), `venv-sweep` (02:15, `:3245, 3319`) and the disk-watch alert (`:3427`). Those jobs can delete `~/.local/share/uv` venvs, which 86-87 and 223 call "always safe" to remove by hand.
- **Verified correct:** `pull-workstation` every 4h (`home.devbox.nix:788`, `home.cloudbox.nix:1555`), nightly 03:00 (`disk-cleanup.nix:2377`), keep 3 generations (`:1396`), `autoExpire` on all hosts.

**Body**
- KEEP 26-121.
- 123-193 (macOS): KEEP. Line 67 points at a plan doc (`docs/plans/2026-10-30-…`), which is time-sensitive.
- 195-213: KEEP. 211 ("Hetzner console (devbox)") is correct (`hosts/cloudbox/configuration.nix:3`).
- 215-259: TRIM. "Monthly Maintenance" (235-259) duplicates 45-100.

**Consumers:**
- `workstation/users/dev/disk-cleanup.nix:3069, 3404`, `test-disk-watch.sh:24, 238` and `hosts/devbox/configuration.nix:1257`. All of them cite "the cleaning-disk skill documents that above ~90% a nix GC can generate I/O pressure…", which is the "Disk filling can break SSH" section (209-213). That section must stay.
- `.agents/skills/rebuilding/SKILL.md:120` and `.agents/skills/monitoring-serve-pool/SKILL.md:199` (repo-local).
- AGENTS.md:86.

**Decision needed:** either deploy the skill cross-host (it already covers devbox) or drop devbox from its description, body and AGENTS.md:86.

**Size after cleanup:** about 210 lines / 7.5 KB.

---

## Cross-cutting
- **Description person:** only migrating-beads-schema is third person. The other five use "Use when…", imperative, or "you".
- **Duplication with AGENTS.md:**
  - shepherding SKILL.md:212-223 repeats AGENTS.md:259-287.
  - shepherding :271 repeats AGENTS.md:122-181.
  - shepherding :358 and `common-mistakes.md:19` repeat AGENTS.md:183-207.
  - shepherding :227-245 repeats AGENTS.opencode.md:23-87.
- **PR #797 hint-work lines:** none of the six skills was touched by it. The last commits on shepherding are #769 (2026-11-02, opus default) and #734 / #730.
- **Total for the six:** about 274 KB on disk including scripts; about 166 KB of markdown. After cleanup, about 90 KB of markdown.
