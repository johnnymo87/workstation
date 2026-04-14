---
name: creating-pull-requests
description: Use when creating pull requests on macOS or cloudbox. Enforces PR title format, description template, and tone conventions.
---

# Creating Pull Requests

## PR Title

Format: `[COPS-XXXX] Sentence case description`

- Bracket the Jira ticket: `[COPS-6082]`, not `COPS-6082:`
- After the prefix, sentence case — first word is an imperative verb
- Examples:
  - `[COPS-6082] Add cutover date to WonderProduct`
  - `[SUPPLY-2740] Fix order closure race condition`
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

- https://wonder.atlassian.net/browse/COPS-XXXX
```

### Section guidance

| Section | Content |
|---------|---------|
| **Description** | What changed and why, in plain language. Bullet points preferred. |
| **Stakeholders** | @ mention people who need to know or review. Omit if obvious. |
| **References** | Jira ticket link. Add Slack threads, Confluence pages, or related PRs if relevant. |
