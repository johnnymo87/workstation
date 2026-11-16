---
name: reading-jsm-portal-requests
description: Reads Jira Service Management (JSM) requests that the human raised as a portal customer (IT, security or other help-desk tickets), with their public replies, status and attachments, through the servicedesk customer API. Use when a Jira key answers 404 "Issue does not exist or you do not have permission to see it" from the Atlassian MCP, the REST API or nvim :FetchJiraTicket although the human raised it; when given a link containing /servicedesk/customer/portal/; when asked what a help desk replied or wants ("Waiting for Customer"); or when about to open such a request in a browser.
---

# Reading JSM Portal Requests

A request raised through a service desk's **customer portal** belongs to a
project where the human is only a *customer*, not a Jira user. Everything built
on the platform API (`/rest/api/3/issue/KEY`, so the Atlassian MCP's
`getJiraIssue`, nvim `:FetchJiraTicket`, JQL) answers **404** or returns no
issues for it. The servicedesk **customer API** (`/rest/servicedeskapi/...`)
reads it with the same `ATLASSIAN_EMAIL` / `ATLASSIAN_API_TOKEN`. No browser needed.

## Read a request

```bash
~/.agents/skills/reading-jsm-portal-requests/jsm-request.sh KEY-123
# also accepts https://<site>/servicedesk/customer/portal/<N>/KEY-123 or a /browse/ link
~/.agents/skills/reading-jsm-portal-requests/jsm-request.sh KEY-123 --attachments /tmp/req   # also saves them, by file name
~/.agents/skills/reading-jsm-portal-requests/jsm-request.sh --list [open|closed|all]   # requests the human raised; default open
```

It prints Markdown: status (with the time it was entered), request type, the
request fields, **every public comment oldest first, so the latest reply is
last**, and the attachment list. All calls are GETs; the token goes to curl on
stdin. Exit codes:

| Exit | Meaning |
|---|---|
| 7 | Not a portal request the human can see: an ordinary issue (the MCP reads those), someone else's request they are not a participant on, or a typo. Ask the human. |
| 4 | Token refused (HTTP 401/403). |
| 5 | Transport error, another HTTP status, or a non-JSON answer. Retry once, then report it. |
| 3 / 2 | `ATLASSIAN_*` unset / bad arguments, or a link on a site other than `$ATLASSIAN_SITE` (the token cannot read it). |

When you report back, link the `Portal:` URL it prints. The `/browse/KEY` link
404s for a customer.

## Read-only. Never write.

Do not comment, transition, approve, add participants or attach files. The
request's `actions` may say `addComment: allowed`; that is the API's permission,
not the human's, and `using-atlassian` forbids writing to Jira over REST.
**Even when the human asks you to reply,** give them the draft and the portal
link, and say they post it there.

## Watch it for a reply

On cloudbox, register a wait instead of re-reading on a timer:

```bash
agent-wait add --jira https://<site>/servicedesk/customer/portal/<N>/KEY-123 --note "<what to do with the reply>"
agent-wait add --jira KEY-123 --until 'status:Waiting for Customer' --note "..."
```

By default it fires on the next public comment by a person other than the
human; `--until status:<name>` waits for that status instead, and
`--until 'comment,status:<name>'` for either. `agent-wait` falls back to the customer API by
itself. Use the status name the portal shows. Off cloudbox, see
`scheduling-wakes`.

## If you call the API directly

The helper covers the common reads. For anything else, these facts hold
(measured on a live request as its customer):

| Fact | Consequence |
|---|---|
| `/request/KEY/comment` lists **oldest first**; `orderBy` is ignored | `limit=1` returns the **first** comment, not the latest. Page with `start`/`limit` until `isLastPage` is `true`. |
| A customer sees public comments only; `internal=true` returns none | No internal notes: say so if the answer may be in one. |
| Comment `body` is wiki markup; `?expand=renderedBody` adds HTML | Mentions look like `[~accountid:<id>]`. |
| Comment authors carry no `accountType` | Look one up with `GET /rest/api/3/user?accountId=<id>` (allowed). |
| Attachment `_links.content` downloads; `_links.jiraRest` is 403 | Use `content`, with `-L`. |
| `GET /request?searchTerm=KEY` finds a request; `requestOwnership=OWNED_REQUESTS` lists the human's | Both paged by `start`/`limit`. |
| `/request/KEY/status` is the status history, newest first; `/sla` is 403 | |
| `/request/<issueId>` works as well as the key | |

Send credentials on stdin, not argv (`printf 'user = "%s"\n' "$ATLASSIAN_EMAIL:$ATLASSIAN_API_TOKEN" | curl --config - ...`), and never print the token.
