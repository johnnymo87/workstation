---
name: reading-jenkins-builds
description: Use when a GitHub check named continuous-integration/jenkins/* is pending, failed, or stuck; when a Jenkins build log, stage result, or queue state is needed to explain a CI failure; when a Jenkins URL is unreachable, refused, or hangs from this host; or before deciding a Jenkins failure is caused by the PR's code.
---

# Reading Jenkins Builds

Jenkins is reachable from the work hosts, but only through a path with its own
failure modes, and its API has traps that cost a baseline agent 33 tool calls
and one leaked credential. This skill is the eight-call version.

Company facts (hostname, how the path works, job-folder convention, what the
token can do, who to contact) live in **INTERNAL.md beside this file**, fetched
from Confluence at home-manager activation. If `INTERNAL.md` or `$JENKINS_HOST`
is missing, run the home-manager switch for this host first.

## Prerequisites

`$JENKINS_HOST`, `$JENKINS_USER`, `$JENKINS_API_TOKEN` are injected into every
bash call on work hosts. If `$JENKINS_HOST` alone is empty, the serve predates
the mapping: take the hostname from INTERNAL.md and set it yourself. Always:

```bash
A=(-sS -g --max-time 20 -u "$JENKINS_USER:$JENKINS_API_TOKEN")
J="https://$JENKINS_HOST"
```

`-g` is not optional. Jenkins `tree=` queries use `[]` and `{}`, which curl
otherwise treats as URL globbing and fails with `bad range in URL`.

## Read the connection, not just the response

| Symptom | Meaning | Do |
|---|---|---|
| refused / reset in <1 s | the local access path is down (INTERNAL.md) | retry in ~2 min; >10 min, tell the human |
| 403 anonymously | reachable; auth layer working | proceed with the token |
| ~10 s hang | host mapping not applied on this box | rebuild, do not re-investigate the network |
| 503 "Starting Jenkins" | an admin is restarting it | wait; build records may change under you |

## Recipes

First check INTERNAL.md's incident log for the build's date: a known controller
incident explains a whole day of failures at once. Then PR → job: multibranch
jobs are `job/<folder>/job/<repo>/job/PR-<n>`; the folder name is in
INTERNAL.md. Take the URL from the GitHub check's `detailsUrl` rather than
guessing.

```bash
P="$J/job/<folder>/job/<repo>/job/PR-<n>"
# builds: number, result, when, how long
curl "${A[@]}" "$P/api/json?tree=nextBuildNumber,inQueue,builds[number,result,building,timestamp,duration]{0,8}" | jq .
# stages of one build, with the stage-level error object
curl "${A[@]}" "$P/<n>/wfapi/describe" | jq '.stages[] | {name,status,durationMillis,error}'
# steps inside a failed stage (id from the line above)
curl "${A[@]}" "$P/<n>/execution/node/<stageId>/wfapi/describe" | jq '.stageFlowNodes[] | select(.status!="SUCCESS")'
# full log; grep it, never eyeball 200 KB
curl "${A[@]}" "$P/<n>/consoleText" -o /tmp/b.log
# controller + agents: offline reasons, executors, queue
curl "${A[@]}" "$J/computer/api/json?tree=busyExecutors,totalExecutors,computer[displayName,offline,offlineCauseReason,numExecutors,idle]" | jq .
curl "${A[@]}" "$J/queue/api/json?tree=items[task[name],why,inQueueSince]" | jq .
```

A step's own log is `.../execution/node/<id>/wfapi/log` (JSON with `text`), not
`/log/` (HTML 404 page with HTTP 200). `monitorData` (disk space) on
`/computer/<node>/api/json` is null for a non-admin token; while a node is
offline its `offlineCauseReason` carries the disk figure, afterwards only the
console signatures below do.

## Diagnose from signatures

| Signature | Cause | Code or infra? |
|---|---|---|
| stage error `com.thoughtworks.xstream.io.StreamException` with empty message; log cut mid-word; `cannot start writing logs to a finished node` | controller could not persist the build (disk full, crash, restart) | infra |
| `No space left on device`, `LockFile.write`, `write error` while `Loading library` / cloning a shared library; build stays `building:true` with `executor:null`, `wfapi/describe` has no stages, log has no `Finished:` | controller disk full before the pipeline started; orphaned record survives the restart | infra |
| `Built-In Node offline` with `Disk space is below threshold` | same; check this first, it explains everything else that day | infra |
| GitHub check `pending` but build `FAILURE`, or no build for the head SHA and `nextBuildNumber` unchanged | status never posted; run was dropped before it existed | infra |
| GitHub check `error` (not `failure`) | run died outside the pipeline (library load, checkout), no proper result ever posted | infra, usually |
| `script returned exit code 1` in a validation/lint stage, later stages `NOT_EXECUTED` | real failure; read that stage's shell output, ignore the cascade | code |
| checkout stage `git merge <sha> returned status code 1` | branch behind base; rebase | code |
| busy executors 0/N, queue empty, builds still failing | **not** a capacity problem, whatever the Slack thread says | infra, elsewhere |

## Do not

- **POST anything** (`/build`, `/stop`, `/retry`, replay). The token is a
  person's, not a service account's; INTERNAL.md says what it can do.
- Fetch `/log/all`, `config.xml`, `/manage`, `/script`: 403, wasted calls.
- Run `gh api repos/<owner>/<repo>/hooks`. It succeeds and prints webhook
  basic-auth credentials into the transcript. The GitHub side of a stuck
  check is answered by the build/queue state above, not by hook config.
- Conclude "no nodes" from a stuck check without reading `/computer/api/json`.
