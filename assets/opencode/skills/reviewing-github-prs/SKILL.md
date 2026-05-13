---
name: reviewing-github-prs
description: Use when posting any reply to a GitHub PR — whether reviewing fresh, replying to a Gemini/human inline comment, or summarizing a session's work. Covers the response-shape decision (threaded vs top-level), inline comment posting via gh CLI, and the gh API gotchas.
---

# Reviewing GitHub PRs

## Overview

This skill covers two things that look related but aren't quite the same:

1. **The decision**: when responding to a PR, what shape should your reply take? Threaded reply to a specific inline comment, a fresh review with inline comments, or a top-level issue comment? Picking the wrong one looks lazy or evasive — even when the content is good.
2. **The mechanics**: how to post each shape via the `gh` CLI, including the workarounds for the API quirks that make `gh pr review` and naive `gh api` flag invocations break.

Read §"Decision: which response shape?" first. The mechanics are reference material below it.

## Decision: which response shape?

Before posting anything, identify what you are responding to and what the existing conversation structure is. Then apply this table — **the row order matters**, top-down is "first match wins":

| If you are... | Use this shape | Why |
|---|---|---|
| ...replying to a specific existing inline comment (Gemini, human, prior agent — anything posted as an inline review comment on a line of the diff) | **Threaded reply** via `POST /pulls/{n}/comments/{comment_id}/replies` | Preserves the conversation thread on that line; reviewer gets a notification on the thread they care about; future readers see your reasoning attached to the code in question |
| ...you have several things to say, some inline-attachable to lines of the diff and some general | **Fresh review** with `event=COMMENT` and a `comments[]` array (each comment with `path` + `line` + `side`) | One submission, one notification, properly threaded per file/line |
| ...you have to address an existing inline comment AND post unrelated session notes | **Threaded reply** to the inline comment first, **then** a separate top-level issue comment for the session notes | Don't bury the threaded reply inside a wall-of-text issue comment. The reviewer subscribed to the inline thread, not to the issue feed |
| ...your response is genuinely PR-wide (session summary, status update, "I'm bailing because X", "auto-merge enabled") and there are no specific inline comments to address | **Top-level issue comment** via `POST /issues/{n}/comments` | Fits the scope of what you're saying |
| ...you're approving / requesting changes / blocking the PR | **Fresh review** with `event=APPROVE` / `REQUEST_CHANGES` / `COMMENT` | The review verdict is a first-class concept distinct from comments |

### Why this matters

GitHub's inline review comments form **threaded conversations** anchored to specific lines of code. A reviewer (human or bot) who left an inline comment will get notified on that thread when someone replies in-thread; they will *not* be notified by a top-level issue comment that mentions the same topic. Worse, future readers of the PR scrolling through the diff see "comment received no reply" next to the line in question, which reads as ignored or evaded.

**The most common failure mode** for an agent: there's an existing inline comment from Gemini (or a human) flagging a concern; the agent posts a top-level issue comment with a paragraph addressing it. From the reviewer's perspective the comment appears unanswered. From the future reader's perspective the diff thread looks abandoned. This is wrong even when the content is good.

**Default**: if the thing you're addressing was posted inline, your response should also be inline.

### Worked example

A Gemini bot posted an inline comment on `src/foo.ts:42` saying "this could throw NPE." You investigate and decide it's a false positive because the value is type-narrowed three lines above.

- ❌ **Wrong**: post a top-level issue comment titled "Re: Gemini's NPE concern — false positive because…"
- ✅ **Right**: reply in-thread to comment id `1234567` with body "False positive — `bar` is narrowed to non-null on line 39 by the `if (bar)` guard."

If you also want to leave a session summary ("dispatched here by lgtm, all checks green, auto-merge enabled"), post that as a *separate* top-level issue comment after the threaded reply.

### Finding existing inline comments before you reply

Before posting any response, list the inline comments on the PR so you don't accidentally post over them:

```bash
gh api repos/{owner}/{repo}/pulls/{number}/comments \
  --jq '.[] | {id: .id, user: .user.login, path: .path, line: .line, in_reply_to_id: .in_reply_to_id, body_preview: (.body[0:120])}'
```

`in_reply_to_id` shows which comments are themselves replies (already part of a thread). Top-level inline comments — the ones you should consider replying to — have `in_reply_to_id: null`.

To group by thread (useful when there's already back-and-forth):

```bash
gh api repos/{owner}/{repo}/pulls/{number}/comments \
  --jq 'group_by(.in_reply_to_id // .id) | map({thread_root: .[0].id, count: length, last_user: .[-1].user.login, path: .[0].path, line: .[0].line})'
```

## Mechanics: how to post each shape

### Threaded reply to an existing inline comment

This is what you should reach for first when there's an inline comment to address. Use the dedicated `/replies` endpoint:

```bash
gh api -X POST repos/{owner}/{repo}/pulls/{number}/comments/{comment_id}/replies \
  -f body='Your reply text here.'
```

`{comment_id}` is the integer `id` field from the listing query above (the parent comment id, in the URL path — not in the body). The body is just `{"body": "..."}` — no `path`, `line`, or `side` needed; those are inherited from the parent.

The reply will appear threaded under the original comment in the GitHub UI, and the comment author gets a notification on the thread they originally subscribed to.

**Verify it threaded correctly** by re-listing comments and confirming your new comment has `in_reply_to_id == {comment_id}`:

```bash
gh api repos/{owner}/{repo}/pulls/{number}/comments \
  --jq '.[] | select(.in_reply_to_id == {comment_id}) | {id, user: .user.login, body_preview: (.body[0:80])}'
```

**After replying, mark the thread resolved** — see §"Resolving review threads" below. Replying without resolving leaves the thread visually unresolved on the diff, even when you've discharged your end of the conversation.

#### Constraints

- `{comment_id}` must be a **thread-root** comment (`in_reply_to_id: null` in listings). GitHub does not support replies-to-replies; you can only reply to the top of a thread. If you want to add to an existing back-and-forth, still reply to the root — your reply will appear at the bottom of the thread.
- The reply inherits the parent's `path`, `line`, `side`, and `commit_id`. You cannot retarget.

#### Alternative form (less recommended)

The same effect can be achieved via `POST /pulls/{n}/comments` with an `in_reply_to` body parameter:

```bash
gh api -X POST repos/{owner}/{repo}/pulls/{number}/comments \
  -f body='Your reply text here.' \
  -F in_reply_to={comment_id}
```

Per GitHub's API docs: *"When in_reply_to is specified, all parameters other than body in the request body are ignored."* So `path`/`line`/`side`/`commit_id` are silently dropped. This works but is easier to misuse — prefer the dedicated `/replies` endpoint above.

### Resolving review threads

GitHub tracks two separate things on an inline comment thread:

- **The reply chain** — what you posted via the threaded-reply mechanism above.
- **Resolution state** — a separate boolean (`isResolved`) that controls whether the thread is collapsed/struck-through in the diff UI.

These are independent. Posting a reply does **not** resolve the thread. A reviewer scrolling the diff sees an unresolved thread regardless of how many replies are on it. You have to mark resolved explicitly.

**When to resolve:** as soon as you've posted your reply — whether the reply was an acceptance ("fixed in <sha>"), a pushback with reasoning, or a deferral with explanation. You've discharged your end of the thread; resolution signals "no further action from me." If the reviewer disagrees, they reopen with one click. Leaving threads unresolved out of caution is worse — the reviewer can't tell which threads still need your attention from which are awaiting their judgment.

**Mechanics — two-step:**

The REST `pulls/{n}/comments` endpoints don't expose resolution state. You need GraphQL: first fetch the thread's GraphQL node ID for the comment you replied to, then call the `resolveReviewThread` mutation.

Step 1: Get thread node IDs (do this once per loop iteration, not per thread):

```bash
gh api graphql -f query='
  query($owner: String!, $repo: String!, $number: Int!) {
    repository(owner: $owner, name: $repo) {
      pullRequest(number: $number) {
        reviewThreads(first: 100) {
          nodes {
            id
            isResolved
            comments(first: 1) { nodes { databaseId } }
          }
        }
      }
    }
  }' \
  -F owner={owner} -F repo={repo} -F number={number} \
  --jq '.data.repository.pullRequest.reviewThreads.nodes[] | {thread_id: .id, resolved: .isResolved, root_comment_id: .comments.nodes[0].databaseId}'
```

This gives you a mapping from REST comment IDs (the same `id` you used when replying via `/comments/{id}/replies`) to GraphQL thread node IDs (`PRRT_…`).

Step 2: Resolve the thread for the comment you just replied to:

```bash
gh api graphql -f query='
  mutation($threadId: ID!) {
    resolveReviewThread(input: { threadId: $threadId }) {
      thread { isResolved }
    }
  }' \
  -f threadId={thread_node_id} \
  --jq '.data.resolveReviewThread.thread.isResolved'
```

Returns `true` on success.

**Reopening:** the symmetric mutation is `unresolveReviewThread` with the same input shape. Use sparingly — if you're reopening your own resolution it usually means you didn't actually finish the thread.

**Filtering to unresolved threads** (useful in the shepherding loop to find what still needs attention):

```bash
gh api graphql -f query='
  query($owner: String!, $repo: String!, $number: Int!) {
    repository(owner: $owner, name: $repo) {
      pullRequest(number: $number) {
        reviewThreads(first: 100) {
          nodes {
            id
            isResolved
            comments(first: 1) { nodes { databaseId author { login } body } }
          }
        }
      }
    }
  }' \
  -F owner={owner} -F repo={repo} -F number={number} \
  --jq '.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == false) | {thread_id: .id, root_id: .comments.nodes[0].databaseId, author: .comments.nodes[0].author.login, preview: (.comments.nodes[0].body[0:120])}'
```

### Fresh review with inline comments

Use when you have several things to say at once, especially a mix of inline and summary content, or when you want to set a review verdict (`APPROVE`, `REQUEST_CHANGES`, `COMMENT`) at the same time.

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

#### Fields

| Field | Value | Notes |
|-------|-------|-------|
| `event` | `COMMENT`, `APPROVE`, `REQUEST_CHANGES` | Review verdict |
| `body` | string | Top-level review summary |
| `comments[].path` | string | File path relative to repo root |
| `comments[].line` | integer | Line number in the **new file** (for RIGHT side) |
| `comments[].side` | `RIGHT` or `LEFT` | RIGHT = new version, LEFT = old version |
| `comments[].body` | string | The inline comment text |

**Important**: `comments[]` here creates *new* inline comments. It does **not** reply to existing ones. If you want to reply to an existing inline thread, use the threaded-reply mechanism above, not this.

### Review without inline comments (verdict + summary only)

```bash
cat <<'JSONEOF' | gh api repos/{owner}/{repo}/pulls/{number}/reviews --method POST --input -
{
  "event": "COMMENT",
  "body": "Summary only, no inline comments."
}
JSONEOF
```

### Top-level issue comment

For PR-wide content with no specific line to attach it to (session summaries, status notes, "I'm bailing because…").

```bash
gh api repos/{owner}/{repo}/issues/{number}/comments \
  --method POST \
  -f body="Top-level comment text."
```

Note the endpoint is `/issues/{n}/comments`, not `/pulls/{n}/comments` — GitHub treats PRs as issues for this purpose, and the `/pulls/{n}/comments` endpoint is *only* for inline comments.

## Common Mistakes

**Posting a top-level issue comment in response to an inline comment.** The most common mistake. See §"Decision" above. The reviewer doesn't get notified on the thread they care about, and the diff thread reads as abandoned.

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

**Inline comments must be on lines in the diff.** You can comment on added lines, removed lines, and context lines within diff hunks. You cannot comment on lines outside the diff. If you want to discuss a line outside the diff, use a top-level issue comment and reference the file/line in prose.

**Don't conflate `in_reply_to` (the alternative-form body parameter) with `in_reply_to_id` (the field name returned in listings).** Only matters if you're using the alternative `POST /pulls/{n}/comments` form — when *posting* you'd send `in_reply_to=N`, but when *reading* comments back the same relationship is exposed as `in_reply_to_id`. The dedicated `/replies` endpoint avoids this entirely (the parent id is in the URL path, not the body).

**Threaded replies don't take a `path`/`line`/`side`.** They inherit those from the parent comment. If you find yourself wanting to attach a reply to a *different* line, that's not a reply — that's a new inline comment, post it as part of a fresh review.

**Replying without resolving.** Posting a reply does not change the thread's `isResolved` state. The reviewer scrolling the diff sees an unresolved thread regardless of how many replies are on it. After every reply (acceptance, pushback, or deferral), call `resolveReviewThread` — see §"Resolving review threads" above. The two are independent operations and both are required to discharge the thread.

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

# List all inline comments on a PR (use this BEFORE replying so you don't miss threads)
gh api repos/{owner}/{repo}/pulls/{number}/comments \
  --jq '.[] | {id, user: .user.login, path, line, in_reply_to_id, body_preview: (.body[0:120])}'

# List all top-level issue comments on a PR
gh api repos/{owner}/{repo}/issues/{number}/comments \
  --jq '.[] | {id, user: .user.login, body_preview: (.body[0:120])}'
```
