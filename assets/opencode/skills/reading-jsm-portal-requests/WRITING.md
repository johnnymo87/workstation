# Raising and commenting on portal requests

Details for `jsm-write.sh`. When to use it at all is in [SKILL.md](SKILL.md).

## Contents

- Exit codes
- What `create` checks before it writes
- Measured API facts

## Exit codes

| Exit | Meaning |
|---|---|
| 0 | Sent, or a dry run (no `--send`): the JSON that would be sent is on stdout. |
| 2 | Bad arguments, or a field the request type does not have, an option it does not offer, or a field type the helper does not shape (anything but text and options). Nothing was sent. |
| 3 | `ATLASSIAN_*` unset. |
| 4 | Token refused (HTTP 401). |
| 5 | Transport error, an unexpected HTTP status, or non-JSON. **After `--send` this does not prove nothing was raised:** run `jsm-request.sh --list` before retrying. A retry of `create` is refused anyway if the first one landed (exit 6). |
| 6 | One of the human's open requests on this desk already has exactly this summary. It prints the key; comment there instead. |
| 7 | HTTP 404: no such desk, request type or request. |
| 8 | HTTP 400: the desk rejected the fields; its message is printed. |
| 9 | HTTP 403: the human cannot raise this type on this desk, or comment on this request. |

## What `create` checks before it writes

1. Fetches the request type's own field list and builds the payload from it:
   an option field gets `{"id": ...}` (an array field `[{"id": ...}]`) for the
   label or id you gave; text fields are sent as given. Required fields you
   left out, unknown field ids and unknown options stop it with exit 2.
2. Lists the human's open requests on the desk and refuses an exact summary
   match (exit 6).
3. Only then, and only with `--send`, POSTs `/rest/servicedeskapi/request`.

`comment` reads the request first (so a typo is a 404 before anything is sent),
then POSTs `{"body": ..., "public": true}` to `/request/KEY/comment`.

Bodies are Jira wiki markup, read verbatim from a file: write the text with
the file-writing tool, not an inline shell string.

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

`comment --send` follows the same API and auth, but had not been run live when
this was written; the first live use checks it (exit 8 or 9 means the desk
refused it).
