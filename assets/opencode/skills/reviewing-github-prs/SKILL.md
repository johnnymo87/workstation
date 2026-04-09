---
name: reviewing-github-prs
description: Use when posting PR reviews on GitHub with inline comments via gh CLI, especially when gh pr review lacks inline comment support
---

# Reviewing GitHub PRs

## Overview

Post PR reviews with inline line-level comments using `gh api`. The `gh pr review` command doesn't support inline comments, so use the REST API directly with JSON piped via `--input -`.

## Quick Reference

### Post a review with inline comments

```bash
cat <<'JSONEOF' | gh api repos/{owner}/{repo}/pulls/{number}/reviews --method POST --input -
{
  "event": "COMMENT",
  "body": "Overall review summary here.",
  "comments": [
    {
      "path": "src/foo.ts",
      "line": 42,
      "side": "RIGHT",
      "body": "Inline comment on this line."
    }
  ]
}
JSONEOF
```

### Fields

| Field | Value | Notes |
|-------|-------|-------|
| `event` | `COMMENT`, `APPROVE`, `REQUEST_CHANGES` | Review verdict |
| `body` | string | Top-level review summary |
| `comments[].path` | string | File path relative to repo root |
| `comments[].line` | integer | Line number in the **new file** (for RIGHT side) |
| `comments[].side` | `RIGHT` or `LEFT` | RIGHT = new version, LEFT = old version |
| `comments[].body` | string | The inline comment text |

### Review without inline comments

```bash
cat <<'JSONEOF' | gh api repos/{owner}/{repo}/pulls/{number}/reviews --method POST --input -
{
  "event": "COMMENT",
  "body": "Summary only, no inline comments."
}
JSONEOF
```

### Reply to an existing comment thread

```bash
gh api repos/{owner}/{repo}/pulls/{number}/comments \
  --method POST \
  -f body="Reply text" \
  -F in_reply_to={comment_id}
```

To find comment IDs for replying:
```bash
gh api repos/{owner}/{repo}/pulls/{number}/comments \
  --jq '.[] | {id: .id, user: .user.login, body: .body[:80], path: .path}'
```

## Common Mistakes

**Don't use the `comments[][]` array syntax with `gh api` flags.** It mangles the JSON and produces 422 errors. Always use `--input -` with a heredoc JSON payload.

```bash
# BAD - 422 Unprocessable Entity
gh api repos/o/r/pulls/1/reviews --method POST \
  -f 'comments[][path]=file.rb' \
  -F 'comments[][line]=10' \
  -f 'comments[][body]=comment'

# GOOD - pipe proper JSON
cat <<'JSONEOF' | gh api repos/o/r/pulls/1/reviews --method POST --input -
{ "event": "COMMENT", "comments": [...] }
JSONEOF
```

**Don't use `position` (diff-relative offset).** Use `line` + `side` instead. The `position` field is the legacy API and requires counting lines in the unified diff, which is error-prone.

**Inline comments must be on lines in the diff.** You can comment on added lines, removed lines, and context lines within diff hunks. You cannot comment on lines outside the diff.

## Useful companion commands

```bash
# View PR details
gh pr view {number} --json title,body,files,additions,deletions

# Get the diff
gh pr diff {number}

# Check CI status
gh pr checks {number}

# Checkout the PR branch
git checkout {branch-name}
```
