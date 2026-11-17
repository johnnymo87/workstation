# Raising, commenting on and closing portal requests

Details for `jsm-write.sh`. When to use it at all is in [SKILL.md](SKILL.md).

## Contents

- Exit codes
- What `create` checks before it writes
- Closing or cancelling a request
- Measured API facts

## Exit codes

| Exit | Meaning |
|---|---|
| 0 | Sent, or a dry run (no `--send`): the JSON that would be sent is on stdout. |
| 2 | Bad arguments, or a field the request type does not have, an option it does not offer, or a field type the helper does not shape (anything but text and options). Nothing was sent. |
| 3 | `ATLASSIAN_*` unset. |
| 4 | Token refused (HTTP 401). |
| 5 | Transport error, an unexpected HTTP status, or non-JSON. **After `--send` this does not prove nothing was sent.** Before retrying `create`, run `jsm-request.sh --list` (the duplicate guard may not see a request raised seconds ago); before retrying `comment`, read the request: nothing stops a second identical comment. |
| 6 | One of the human's open requests on this desk already has exactly this summary. It prints the key; comment there instead. |
| 7 | HTTP 404: no such desk, request type or request. |
| 8 | HTTP 400: the desk rejected the fields; its message is printed. |
| 9 | HTTP 403: the human cannot raise this type on this desk, or comment on this request. |
| 10 | `transition`: the request's reporter is not the token's owner. Nothing was sent. |
| 11 | `transition`: the desk does not offer that move to the human; the moves it does offer are printed (often "none"). Nothing was sent. |
| 12 | `transition`: the move is offered but its name is not a close (cancel, close, resolve, withdraw, done), e.g. "Escalate". Nothing was sent. |

## What `create` checks before it writes

1. Fetches the request type's own field list and builds the payload from it:
   an option field gets `{"id": ...}` (an array field `[{"id": ...}]`) for the
   label or id you gave; text fields are sent as given. Required fields you
   left out, unknown field ids and unknown options stop it with exit 2.
2. Lists the human's open requests on the desk and refuses an exact summary
   match (exit 6).
3. Only then, and only with `--send`, POSTs `/rest/servicedeskapi/request`.

`comment` reads the request first (so a typo is a 404 before anything is sent),
then POSTs `{"body": ..., "public": true}` to `/request/KEY/comment`. On many
desks a customer comment on a resolved request reopens it; say so to the human
before commenting on one.

Bodies are Jira wiki markup, read verbatim from a file: write the text with
the file-writing tool, not an inline shell string.

## Closing or cancelling a request

Only a request the human raised, and only when they asked to close it.

1. Read it with `jsm-request.sh`. Already in a done status (`DONE` category):
   stop and report it; a comment could reopen it. A help-desk reply that
   changes the picture: report it instead of closing.
2. `$W transitions KEY` lists the moves offered to the human. Pick the one
   that matches the ask ("Cancel request" if nobody acted, "Resolve" if it was
   handled). The helper refuses any other move (exit 12): escalating or
   reopening is not closing.
3. `$W transition KEY --to NAME --comment-file why.txt` (dry run), then with
   `--send`. The comment rides along as the transition's public comment, so
   do not also post it with `comment`. On success it prints
   `KEY<TAB>status now<TAB>portal link`, and warns if that status is not in
   the DONE category (a "Resolve" can land in an approval step); report it.
4. `agent-wait cancel` any `--jira` wait registered on it (`agent-wait list`), or expect the desk's
   closing notice to fire it.

`transition` checks, before anything is sent, that the request's reporter is
the token's owner (`/rest/api/3/myself`), exit 10 otherwise; that the move
is in the offered list, exit 11 otherwise; and that its name is a close,
exit 12 otherwise. It never sets a status directly.

**No transition offered (exit 11, "none"):** the desk lets only its agents
close requests. Post a public `comment` asking them to close it, with the
reason, once the human has approved that wording. Do not look for another API
route to force it.

## Measured API facts

From a live desk as a portal customer (2026-11-16):

| Fact | Consequence |
|---|---|
| `POST /request` with an ordinary API token raises the request as the token's owner (HTTP 201, status "Waiting for support") | No browser needed. |
| `GET /servicedesk/<id>/requesttype/<type>/field` reports `canRaiseOnBehalfOf: false` for a customer | Never set `raiseOnBehalfOf`; the human is always the reporter. |
| An option field's `validValues[].value` is the option id | The payload needs `{"id": "<value>"}`, not the label. |
| `GET /request?searchTerm=<full summary>` finds nothing when the summary has punctuation (`:`, `(`, `/`); single words match | The duplicate guard lists the desk's open requests and compares exactly instead. |
| The portal number in `/servicedesk/customer/portal/<N>` was the service desk id on the desk measured | Confirm with `GET /servicedesk` (id and project key) if a desk disagrees. |
| A request's `requestTypeId` and `serviceDeskId` are on `GET /request/KEY` | To match an earlier request, copy them from it. |

Transitions, measured on the same site as a customer (2026-11-17):

| Fact | Consequence |
|---|---|
| `GET /request/KEY/transition` returned an empty list on 5 of 6 of the human's requests, open and done, across three desks; one desk offered only "Escalate" | Expect exit 11 and the comment fallback more often than a close. |
| `GET /request/KEY` carries `reporter.accountId`, which equals `/rest/api/3/myself` `.accountId` for the human's own request | The ownership check behind exit 10. |
| A done request offers no transitions | Reading the status first saves a pointless call. |

`comment --send` and `transition --send` follow the same API and auth, but
neither had been run live when this was written (no desk measured offered a
close). Per Atlassian's API reference, the transition POST answers 204 with
no body and takes `{"id": ..., "additionalComment": {"body": ...}}`; the first
live use checks it (exit 8 or 9 means the desk refused it).
