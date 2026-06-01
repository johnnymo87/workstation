# opencode-launch `--mcp` Flag Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans (or
> superpowers:subagent-driven-development) to implement this plan task-by-task.

**Goal:** Add a repeatable `--mcp <server>` flag to `opencode-launch` so a
headless session can be spawned with a specific MCP server's tools enabled
(primary case: `--mcp slack` → read+write Slack), without globally enabling
MCP tools.

**Architecture:** `opencode-launch` is a `pkgs.writeShellApplication` defined
inline in `users/dev/home.base.nix`. It talks to the local `opencode serve`
HTTP API. The new flag collects server names; after creating the session and
before sending the prompt, the script `POST`s `/mcp/<srv>/connect` for each
(workspace-scoped via the `x-opencode-directory` header — there is **no
auto-connect**), then folds `{"<srv>_*": true}` into the `tools` map on the
`prompt_async` body (the per-message tools override, which supports the
`<srv>_*` glob). This composes with the existing `--model` flag.

**Tech Stack:** Nix/home-manager, bash (`writeShellApplication` → shellcheck at
build time), `curl`, `jq`, opencode-serve HTTP API (verified 1.15.13).

**Design source:** `docs/research/2026-06-01-opencode-launch-mcp-enable.md`
(all API behavior verified live there). **User decisions:** `--mcp`-only
surface (no `--enable-tools`, no `--agent`); `--mcp slack` enables full
`slack_*` (read **and** write).

**Key facts the implementer must respect:**
- The script body is a Nix `''…''` string: write shell `${VAR}` as `''${VAR}`,
  and `$VAR` / `"$VAR"` are fine as-is. Command substitutions `$(...)` are fine.
- `writeShellApplication` runs `shellcheck`; lint failures fail the Nix build.
- `/mcp/<srv>/connect` returns `200` on success (incl. already-connected),
  `404` when the server is not in config (e.g. slack on devbox/crostini, or no
  token). Treat 404 as a clear user error, non-200/404 as a hard failure.
- slack MCP is only configured on **macOS + cloudbox**. On cloudbox it is
  present but `enabled:false`; the connect step is what activates it.
- The relevant script lives at `users/dev/home.base.nix` lines ~7-160
  (`opencode-launch = pkgs.writeShellApplication { … }`). Arg parsing is the
  `while [ $# -gt 0 ]` loop (~42-75); session create is ~114; payload build is
  ~126-134; prompt send is ~137-143.

---

### Task 1: Test harness for the tools-JSON builder

Factor the new logic into a shell function `build_mcp_tools_json` so it is unit
testable the same way `pkgs/oc-auto-attach/test-project-key.sh` mirrors its
helpers.

**Files:**
- Create: `users/dev/test-opencode-launch-mcp.sh`

**Step 1: Write the failing test (mirror the helper, assert behavior)**

```bash
#!/usr/bin/env bash
# Unit tests for opencode-launch --mcp tools-JSON builder.
# Mirrors build_mcp_tools_json from users/dev/home.base.nix.
# Run: bash users/dev/test-opencode-launch-mcp.sh
set -o errexit -o nounset -o pipefail

# ---- helper under test (mirror of home.base.nix) ----------------------------
# Given server names as args, print a compact JSON object mapping each
# "<server>_*" -> true, de-duplicated and stable-ordered. No args -> {}.
build_mcp_tools_json() {
  local tools_json='{}'
  local srv
  for srv in $(printf '%s\n' "$@" | awk 'NF' | sort -u); do
    tools_json=$(jq -c --arg k "${srv}_*" '. + {($k): true}' <<<"$tools_json")
  done
  printf '%s\n' "$tools_json"
}

fail=0
check() { # check <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "ok: $1"; else
    echo "FAIL: $1"; echo "  expected: $2"; echo "  actual:   $3"; fail=1; fi
}

check "no servers -> {}" '{}' "$(build_mcp_tools_json)"
check "slack -> slack_*"  '{"slack_*":true}' "$(build_mcp_tools_json slack)"
check "two servers"       '{"atlassian_*":true,"slack_*":true}' \
  "$(build_mcp_tools_json slack atlassian)"
check "dedup"             '{"slack_*":true}' "$(build_mcp_tools_json slack slack)"

[ "$fail" -eq 0 ] && echo "ALL PASS" || { echo "SOME TESTS FAILED"; exit 1; }
```

**Step 2: Run it and watch it pass for the helper-as-written**

Run: `bash users/dev/test-opencode-launch-mcp.sh`
Expected: `ALL PASS`. (The helper here is the reference implementation; Task 2
copies it verbatim into the Nix file. If jq orders keys differently, adjust the
expected strings to match `jq -c` output — verify by running.)

**Step 3: Commit**

```bash
git add users/dev/test-opencode-launch-mcp.sh
git commit -m "test(opencode-launch): tools-JSON builder for --mcp flag"
```

---

### Task 2: Add `--mcp` parsing + connect + tools merge to opencode-launch

**Files:**
- Modify: `users/dev/home.base.nix` (the `opencode-launch` script, ~7-160)

**Step 1: Declare state alongside `model_spec`**

Just before the `while [ $# -gt 0 ]` arg loop (after `model_spec=""`), add:

```bash
      mcp_servers=()
```

**Step 2: Add the helper function (mirror of the tested helper)**

Add near the top of the script `text` (e.g. right after `usage() { … }`), using
Nix escaping for `$@`/`$k` (those are `$@` and `$k`, fine; only `${…}` needs
`''${…}`):

```bash
      build_mcp_tools_json() {
        local tools_json='{}'
        local srv
        for srv in $(printf '%s\n' "$@" | awk 'NF' | sort -u); do
          tools_json=$(jq -c --arg k "''${srv}_*" '. + {($k): true}' <<<"$tools_json")
        done
        printf '%s\n' "$tools_json"
      }
```

**Step 3: Add `--mcp` cases to the arg loop**

Inside the `case "$1" in` block, alongside the `--model` cases:

```bash
          --mcp)
            if [ $# -lt 2 ] || [ -z "$2" ]; then
              echo "Error: --mcp requires a server name" >&2
              exit 1
            fi
            mcp_servers+=("$2")
            shift 2
            ;;
          --mcp=*)
            mcp_server="''${1#--mcp=}"
            if [ -z "$mcp_server" ]; then
              echo "Error: --mcp requires a server name" >&2
              exit 1
            fi
            mcp_servers+=("$mcp_server")
            shift
            ;;
```

**Step 4: Connect each requested server after session create, before prompt**

After `session_id` is validated (~124) and before the `if [ -n "$model_spec" ]`
payload block (~126), add. Note `''${#mcp_servers[@]}` and
`''${mcp_servers[@]}` need Nix escaping:

```bash
      mcp_tools_json='{}'
      if [ "''${#mcp_servers[@]}" -gt 0 ]; then
        for srv in $(printf '%s\n' "''${mcp_servers[@]}" | awk 'NF' | sort -u); do
          connect_code=$(curl -s -o /dev/null -w '%{http_code}' \
            -X POST "$OPENCODE_URL/mcp/$srv/connect" \
            -H "x-opencode-directory: $directory")
          if [ "$connect_code" = "404" ]; then
            echo "Error: MCP server '$srv' is not configured on this host" >&2
            exit 1
          elif [ "$connect_code" != "200" ]; then
            echo "Error: failed to connect MCP server '$srv' (HTTP $connect_code)" >&2
            exit 1
          fi
        done
        mcp_tools_json=$(build_mcp_tools_json "''${mcp_servers[@]}")
      fi
```

**Step 5: Fold `mcp_tools_json` into BOTH prompt payload branches**

Replace the existing payload build (~126-134) so the `tools` key is merged when
non-empty, in both the `--model` and no-model branches:

```bash
      if [ -n "$model_spec" ]; then
        prompt_payload=$(jq -n \
          --arg p "$prompt" \
          --arg provider "$model_provider" \
          --arg model "$model_id" \
          --argjson tools "$mcp_tools_json" \
          '{parts: [{type: "text", text: $p}], model: {providerID: $provider, modelID: $model}}
           + (if ($tools | length) > 0 then {tools: $tools} else {} end)')
      else
        prompt_payload=$(jq -n \
          --arg p "$prompt" \
          --argjson tools "$mcp_tools_json" \
          '{parts: [{type: "text", text: $p}]}
           + (if ($tools | length) > 0 then {tools: $tools} else {} end)')
      fi
```

**Step 6: Update `usage()` help text**

Add the `--mcp` option line and an example to the `usage()` heredoc/echos
(~17-39):

```bash
        echo "  --mcp <server>                 Enable an MCP server's tools (repeatable)"
```
and under Examples:
```bash
        echo "  opencode-launch --mcp slack ~/projects/pigeon \"summarize #incidents today\""
```

**Step 7: Verify the standalone test still passes**

The Task 1 helper and the Task 2 Step 2 helper must be byte-identical except for
Nix escaping. Run: `bash users/dev/test-opencode-launch-mcp.sh` → `ALL PASS`.

**Step 8: Commit**

```bash
git add users/dev/home.base.nix
git commit -m "feat(opencode-launch): add --mcp flag to enable MCP server tools per session"
```

---

### Task 3: Build verification (shellcheck via Nix)

**Step 1: Build the home-manager activation package (runs shellcheck)**

Run (cloudbox target):
```bash
nix build .#homeConfigurations.cloudbox.activationPackage --no-link 2>&1 | tail -20
```
Expected: builds successfully. A shellcheck error in the script fails here with
a `SC####` code — fix and rebuild before proceeding. (If the flake attr path
differs, discover it with `nix flake show 2>/dev/null | grep -A3 homeConfigurations`.)

---

### Task 4: Deploy + live smoke test (cloudbox)

**Files:** none (deploy + verify only)

**Step 1: Deploy**

```bash
nix run home-manager -- switch --flake .#cloudbox
```
Expected: activation succeeds; `opencode-launch` on PATH is the new build
(`opencode-launch --help` shows the `--mcp` line).

**Step 2: Argument-error smoke checks (no session created)**

```bash
opencode-launch --mcp           # -> "Error: --mcp requires a server name", exit 1
opencode-launch --mcp= "hi"     # -> same error
```

**Step 3: 404 path (server not configured) — only meaningful where slack is absent**

On cloudbox slack IS configured, so instead test a bogus server name:
```bash
opencode-launch --mcp nonesuch /home/dev/projects/workstation "noop"
```
Expected: `Error: MCP server 'nonesuch' is not configured on this host`, exit 1,
and (acceptable) a session may have been created first — confirm via the printed
behavior. (If we want connect-before-create, that is a future refinement; the
research doc's flow creates the session first.)

**Step 4: Happy path — read**

```bash
opencode-launch --model google-vertex/gemini-3.5-flash --mcp slack \
  /home/dev/projects/workstation \
  "Call slack_channels_list once with limit 3 and reply ONLY the channel names. Do not post."
```
Then poll the printed session id:
```bash
SID=<printed>; U=http://localhost:4096; D=/home/dev/projects/workstation
curl -s "$U/session/$SID/message" -H "x-opencode-directory: $D" \
 | jq -r '.[].parts[]? | select(.type=="tool" or .type=="text")
          | if .type=="tool" then "TOOL "+.tool+" "+(.state.status//"?") else "TEXT "+((.text//"")[0:120]) end'
```
Expected: a `TOOL slack_channels_list completed` part and channel names in text.

**Step 5: Verify write is available (read+write decision)**

Confirm the post tool is in scope (do NOT actually spam a channel; post to a
self/test DM or a scratch channel only if one exists, otherwise just assert the
tool is callable by a benign prompt that the agent can decline). Minimal check:
launch with `--mcp slack` and a prompt that asks the agent to *confirm it has*
`slack_conversations_add_message` available (reply YES/NO). Expected: YES.

**Step 6: Clean up test sessions**

```bash
for s in <ids>; do curl -s -X POST "$U/session/$s/abort" -H "x-opencode-directory: $D" >/dev/null; \
  curl -s -X DELETE "$U/session/$s" -H "x-opencode-directory: $D" >/dev/null; done
# leave slack connected (low blast radius) or disconnect to restore baseline:
curl -s -X POST "$U/mcp/slack/disconnect" -H "x-opencode-directory: $D" >/dev/null
```

---

### Task 5: Update the opencode-launch skill doc

**Files:**
- Modify: `assets/opencode/skills/opencode-launch/SKILL.md`

**Step 1: Document the `--mcp` flag**

Add a section after "What This Does" describing `--mcp <server>` (repeatable):
what it does (connect the server + enable `<server>_*` for the launched
session's first prompt), the no-auto-connect fact, host availability (slack:
macOS + cloudbox only), the per-message scope caveat (follow-up prompts via
`opencode-send` would need their own enablement), and the slack read+write note
(it grants the post-message tool — use deliberately for swarm workers).

**Step 2: Add a usage example**

```bash
opencode-launch --mcp slack ~/projects/pigeon "summarize the last hour of #incidents"
```

**Step 3: Commit**

```bash
git add assets/opencode/skills/opencode-launch/SKILL.md
git commit -m "docs(opencode-launch): document --mcp flag"
```

---

### Task 6: Land

**Step 1: Verify everything is committed and tests pass**

```bash
git status            # clean (besides unrelated pre-existing untracked files)
bash users/dev/test-opencode-launch-mcp.sh   # ALL PASS
```

**Step 2: Push** (per repo "Landing the Plane" norm)

```bash
git pull --rebase && git push && git status
```

---

## Out of scope (explicitly deferred)

- `--enable-tools <glob,...>` fine-grained surface (user chose `--mcp`-only).
- `--agent <name>` session pin (orthogonal; cheap to add later via the
  `agent` field on `POST /session` / `prompt_async`).
- Read-only slack mode (would be `{"slack_*":true,"slack_conversations_add_message":false}`;
  exact-key-beats-glob precedence verified in the research doc appendix).
- Teaching `opencode-send` / pigeon `/launch` the same flag (multi-turn slack).
