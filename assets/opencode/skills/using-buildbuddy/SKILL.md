---
name: using-buildbuddy
description: Use when fetching raw test logs or build logs from a BuildBuddy invocation by URL/invocation ID — bypasses the bazel/UI truncation that hides large test stdout (multi-MB JUnit logs, dependency dumps, etc.). Provides the bb-test-log helper and the underlying enterprise API flow.
---

# Using BuildBuddy

Two tools available, both deployed by home-manager (work-only: macOS + cloudbox):

| Tool | Use it for |
|------|-----------|
| `bb` | Bazelisk wrapper. `bb login`, `bb view`, `bb download`, `bb remote`, etc. **Whole-build log only**, subject to truncation. |
| `bb-test-log` | Custom helper. **Per-target raw test.log**, no truncation. The escape hatch when a failing test produced multi-MB stdout. |

Auth lives in env vars `BUILDBUDDY_HOST` (org-branded subdomain, no scheme) and
`BUILDBUDDY_API_KEY`. Provisioned per-platform:

| Platform | Storage | Loaded by |
|---------|---------|-----------|
| Cloudbox | sops (`secrets/cloudbox.yaml` → `/run/secrets/buildbuddy_*`) | `home.cloudbox.nix` initExtra |
| macOS | Keychain (`buildbuddy-host`, `buildbuddy-api-key`) | `home.darwin.nix` initExtra |

If `bb-test-log` reports the env vars are unset on macOS, provision them with:

```bash
security add-generic-password -a "$USER" -s buildbuddy-host    -w 'your-org.buildbuddy.io'
security add-generic-password -a "$USER" -s buildbuddy-api-key -w 'YOUR_KEY'
# Re-source ~/.bashrc or open a new shell.
```

## Fetching a raw test log

```bash
bb-test-log <invocation-id-or-url> <target-label> [attempt]
```

- `invocation-id-or-url`: bare UUID or full BuildBuddy invocation URL (script
  parses either).
- `target-label`: bazel label like `//path/to:test_target`.
- `attempt`: optional, 1-based; defaults to `last`. Use this when a flaky test
  was retried and you want a specific run.

Examples:

```bash
# By URL, last attempt, write to file
bb-test-log "$BB_URL" //some/pkg:my_test > /tmp/test.log

# By bare ID, attempt #2 (after a flaky retry)
bb-test-log 3be19ca0-XXXX-XXXX-XXXX-XXXXXXXXXXXX //some/pkg:my_test 2 > /tmp/attempt2.log
```

The output is the **raw `test.log` blob** — same bytes the bazel test runner
wrote, no truncation. For a 7+ MB JUnit log with stack traces and DEBUG
spam, this is the only way to get all of it.

## When to reach for which tool

| Symptom | Tool |
|---------|------|
| "I want to see the bazel build console output for this invocation" | `bb view -target=grpcs://$BUILDBUDDY_HOST <invocation_id>` |
| "A specific test failed and the UI says `[truncated]`" | `bb-test-log <invocation> <label>` |
| "I need a single artifact (binary, .lcov, etc.) by digest" | `bb download` |
| "I want to programmatically iterate every failing target" | Hit the API directly (see below) |

## Manual API flow

When you need something `bb-test-log` doesn't expose (e.g. enumerate every
failing target in an invocation, fetch `test.xml` instead of `test.log`,
filter by tag), call the API directly. Three endpoints:

```bash
H="x-buildbuddy-api-key: $BUILDBUDDY_API_KEY"
API="https://$BUILDBUDDY_HOST/api/v1"
INVOCATION=...

# 1. Invocation summary (status, exit code, command, repo, etc.)
curl -sS -H "$H" -H 'Content-Type: application/json' \
  -d "{\"selector\":{\"invocation_id\":\"$INVOCATION\"}}" \
  "$API/GetInvocation" | jq .

# 2. Targets (filter status=FAILED to find what to investigate)
curl -sS -H "$H" -H 'Content-Type: application/json' \
  -d "{\"selector\":{\"invocation_id\":\"$INVOCATION\"}}" \
  "$API/GetTarget" | jq '.target[] | select(.status=="FAILED") | .label'

# 3. Actions for a target (each has shard/run/attempt + file URIs)
curl -sS -H "$H" -H 'Content-Type: application/json' \
  -d "{\"selector\":{\"invocation_id\":\"$INVOCATION\",\"target_label\":\"$LABEL\"}}" \
  "$API/GetAction" | jq '.action[] | select(.file)'

# 4. Fetch any file by URI (response body IS the bytes, no JSON wrapper)
curl -sS -H "$H" -H 'Content-Type: application/json' \
  -d "{\"uri\":\"$BYTESTREAM_URI\"}" \
  "$API/GetFile" > out.bin
```

Full API reference: <https://www.buildbuddy.io/docs/enterprise-api>

## Notes and gotchas

- **`bb` itself doesn't have a "give me test.log of target X" subcommand**.
  `bb view` only shows the invocation-level bazel console log; that's
  what you'd see scrolling past during the build. The actual test stdout
  ends up in CAS as `test.log` and is reachable only via the API. Hence
  `bb-test-log`.
- **`GetFile` returns raw bytes**, not JSON. Don't pipe through `jq`.
- **Bytestream URIs in API responses point to `remote.buildbuddy.io`** (the
  shared CAS endpoint), not your org-branded host. Pass the URI to your org's
  `/api/v1/GetFile` anyway — the org backend proxies the read.
- **Multiple attempts**: if a test was retried, `GetAction` returns one
  `action` entry per `(shard, run, attempt)`. The `bb-test-log` helper
  defaults to the last (most recent). Pass an explicit attempt number to grab
  earlier runs.
- **`bb login` is separate from the API key flow**. If you want to use `bb`'s
  authenticated subcommands (`bb remote`, `bb ask`, etc.) you'd run
  `bb login -url=https://$BUILDBUDDY_HOST -target=grpcs://$BUILDBUDDY_HOST` to
  get a per-user API key written to `~/.config/buildbuddy/`. The org key in
  env vars is independent of that and is what `bb-test-log` uses.
