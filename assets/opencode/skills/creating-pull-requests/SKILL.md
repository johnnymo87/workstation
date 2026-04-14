---
name: creating-pull-requests
description: Use when creating pull requests on macOS or cloudbox. Enforces PR title format, description template, pre-PR checks, and post-PR monitoring.
---

# Creating Pull Requests

## PR Lifecycle

```dot
digraph pr_lifecycle {
    rankdir=TB;
    "Pre-PR checks" [shape=box];
    "Conflicts?" [shape=diamond];
    "Auto-rebase + force-push" [shape=box];
    "Rebase failed?" [shape=diamond];
    "Abort + warn user" [shape=box, style=filled, fillcolor=lightyellow];
    "Review commits/diff" [shape=box];
    "Looks right?" [shape=diamond];
    "Fix (drop/squash/amend)" [shape=box];
    "Create PR" [shape=box];
    "Sleep 5 min" [shape=box];
    "Check CI" [shape=box];
    "CI green?" [shape=diamond];
    "Investigate + fix + push" [shape=box];
    "Fetch inline comments" [shape=box];
    "Unresolved comments?" [shape=diamond];
    "Address comments + push" [shape=box];
    "Done" [shape=doublecircle];

    "Pre-PR checks" -> "Conflicts?";
    "Conflicts?" -> "Review commits/diff" [label="no"];
    "Conflicts?" -> "Auto-rebase + force-push" [label="yes"];
    "Auto-rebase + force-push" -> "Rebase failed?";
    "Rebase failed?" -> "Review commits/diff" [label="no"];
    "Rebase failed?" -> "Abort + warn user" [label="yes"];
    "Review commits/diff" -> "Looks right?";
    "Looks right?" -> "Create PR" [label="yes"];
    "Looks right?" -> "Fix (drop/squash/amend)" [label="no"];
    "Fix (drop/squash/amend)" -> "Review commits/diff";
    "Create PR" -> "Sleep 5 min";
    "Sleep 5 min" -> "Check CI";
    "Check CI" -> "CI green?";
    "CI green?" -> "Fetch inline comments" [label="yes"];
    "CI green?" -> "Investigate + fix + push" [label="no/pending"];
    "Investigate + fix + push" -> "Sleep 5 min";
    "Fetch inline comments" -> "Unresolved comments?";
    "Unresolved comments?" -> "Done" [label="no"];
    "Unresolved comments?" -> "Address comments + push" [label="yes"];
    "Address comments + push" -> "Sleep 5 min";
}
```

## PR Title

Format: `[PROJ-XXXX] Sentence case description`

- Bracket the Jira ticket: `[PROJ-6082]`, not `PROJ-6082:`
- After the prefix, sentence case -- first word is an imperative verb
- Examples:
  - `[PROJ-6082] Add cutover date to billing dashboard`
  - `[PROJ-2740] Fix order closure race condition`
  - `[NO-JIRA] Bump dependency versions`

## PR Description

Explain like you're speaking to a TPM. Prefer brevity, but not at the cost of clarity.

Template:

```markdown
#### Description

...

#### Stakeholders

...

#### References

- https://$ATLASSIAN_SITE/browse/PROJ-XXXX
```

### Section guidance

| Section | Content |
|---------|---------|
| **Description** | What changed and why, in plain language. Bullet points preferred. |
| **Stakeholders** | @ mention people who need to know or review. Omit if obvious. |
| **References** | Jira ticket link. Add Slack threads, Confluence pages, or related PRs if relevant. |

## Pre-PR Checks

Run these before `gh pr create`:

### 1. Check for merge conflicts

```bash
git fetch origin main
git rebase origin/main
```

If rebase succeeds, force-push the rebased branch. If rebase fails (conflicts can't be auto-resolved), `git rebase --abort` and warn the user.

### 2. Verify commits and diff

```bash
git log origin/main..HEAD --oneline
git diff origin/main...HEAD --stat
```

Sanity-check: are these the commits and files you expect? Use best judgement -- if something looks wrong (unrelated commits, unexpected files, merge commits from another branch), fix it (drop, squash, amend). If it looks clean, proceed.

## Post-PR Monitoring

After creating the PR, enter a monitoring loop. No maximum iterations -- loop until CI is green and all comments are resolved.

### Loop body

1. **Sleep 5 minutes** -- `sleep 300`
2. **Check CI status**:
   - GitHub Actions: `gh pr checks <number>`
   - Azure DevOps: use `az pipelines` commands (discover the right invocation for the repo)
   - If checks are still running, go back to sleep
   - If checks failed, investigate the logs, fix the issue, push, go back to sleep
3. **Fetch inline comments**:
   ```bash
   gh api repos/{owner}/{repo}/pulls/{number}/comments \
     --jq '.[] | {id: .id, user: .user.login, body: .body[:120], path: .path, line: .line}'
   ```
   - Use best judgement: if a comment is actionable (from Gemini bot or a colleague), fix the code, push, and reply inline
   - If a comment needs human decision, surface it to the user
   - See the `reviewing-github-prs` skill for how to reply to comment threads

### Exit condition

Loop ends when **both** are true:
- All CI checks pass
- No unresolved inline comments remain
