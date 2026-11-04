#!/usr/bin/env bash
# inspect-wiz-mcp.sh -- deterministic check of what the stored Wiz MCP grant can do.
#
# Prints the granted scope, the access token's audience/expiry claims, and the
# server's tool list (name, annotations, first line of description). Never
# prints the token. Calls only MCP `initialize` and `tools/list`, which list
# tools and do not run any of them.
#
# Usage: inspect-wiz-mcp.sh        (needs curl, jq; run after `opencode mcp auth wiz`)
set -euo pipefail

auth="${XDG_DATA_HOME:-$HOME/.local/share}/opencode/mcp-auth.json"
url="https://mcp.app.wiz.io/"

token="$(jq -r '.wiz.tokens.accessToken // empty' "$auth")"
if [ -z "$token" ]; then
  echo "No wiz tokens in $auth -- run: opencode mcp auth wiz" >&2
  exit 1
fi

echo "== granted scope (as recorded at token exchange)"
jq -r '.wiz.tokens.scope // "(not recorded)"' "$auth"

echo "== token claims (aud, scope, exp) -- empty if the token is opaque"
payload="$(printf '%s' "$token" | cut -d. -f2 | tr '_-' '/+')"
while [ $(( ${#payload} % 4 )) -ne 0 ]; do payload="$payload="; done
printf '%s' "$payload" | base64 -d 2>/dev/null | jq -c '{aud, scope, scp, exp}' 2>/dev/null || echo "(opaque token)"

hdr="$(mktemp)"; trap 'rm -f "$hdr"' EXIT
post() {  # $1 = JSON-RPC body; prints the JSON payload (plain JSON or SSE data lines)
  curl -sS -m 30 -D "$hdr" "$url" \
    -H "Authorization: Bearer $token" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    ${sid:+-H "Mcp-Session-Id: $sid"} \
    -d "$1" | sed -n 's/^data: //p; /^{/p'
}

sid=""
post '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"inspect-wiz-mcp","version":"1"}}}' \
  | jq -c '.result.serverInfo // .error'
sid="$(grep -i '^mcp-session-id:' "$hdr" | cut -d' ' -f2 | tr -d '\r' || true)"
post '{"jsonrpc":"2.0","method":"notifications/initialized"}' >/dev/null || true

echo "== tools"
post '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  | jq -r '.result.tools[]? | "\(.name)\t\(.annotations // {} | tostring)\t\((.description // "") | split("\n")[0][:100])"'
