#!/usr/bin/env bash
# Regenerate the committed /doc fixture used by the vitest leg of the route gate.
#
# WHY A SCRIPT: the fixture must be a faithful PROJECTION of the pinned opencode's
# /doc. Hand-editing it (or lifting it from a live serve, which may be a stale
# binary) silently decouples the fixture from the pin, and the vitest leg then
# checks a fiction while reporting green. This script boots the PINNED binary the
# same way route-gate.nix does and projects only what the gate actually reads:
#
#   paths -> {method} -> responses -> {status} -> content -> {mediaType}
#
# Check A/B read paths x methods; Check C reads the declared response media types.
# Nothing else in /doc is consulted, so nothing else is kept — a 486KB full dump
# would churn the repo on every pin bump for data no check looks at.
#
# Usage:  ./audit/regen-doc-fixture.sh [output-path]
#         OPENCODE_BIN=/nix/store/...-opencode-patched-X/bin/opencode ./audit/regen-doc-fixture.sh
#
# After running, the script prints a census and a pair-count diff against the
# previous fixture. REVIEW THAT DIFF — an unexpected change means the pin moved
# and the gate's expectations (kind census, Check C) may need a decision, which
# is the whole point of the gate failing loudly at bump time.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:-test/fixtures/doc.pinned-1.18.18.1.json}"

# Same resolution rule as test.sh: the profile symlink IS the pin. Never hardcode
# a store path — it rots on the next bump or GC and would validate the wrong binary.
OPENCODE_BIN="${OPENCODE_BIN:-$(command -v opencode 2>/dev/null || true)}"
if [ -z "$OPENCODE_BIN" ] || [ ! -x "$OPENCODE_BIN" ]; then
  echo "ERROR: opencode binary not found (OPENCODE_BIN='${OPENCODE_BIN}')." >&2
  exit 1
fi
echo "Using opencode: $(readlink -f "$OPENCODE_BIN")"

TMP=$(mktemp -d)
export HOME="$TMP/home"
export XDG_CONFIG_HOME="$TMP/config"
export XDG_DATA_HOME="$TMP/data"
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME"

# Scrubbing HOME/XDG_* is NOT enough — see the long incident comment in ../test.sh.
# An opencode bash tool call carries OPENCODE_SERVE_ID + OPENCODE_ROUTING_DB, so a
# throwaway serve spawned from inside a session hijacks the live pool slot `serve-1`
# via registerSelf's unfenced upsert and points it at this script's random port,
# which does NOT self-heal (the real serve keeps the row heartbeating and healthy).
# That wedged 76 sessions on 2026-07-25. Keep this list in sync with test.sh.
SERVE_ENV_SCRUB=(
  env
  -u OPENCODE_SERVE_ID                 # registry slot identity — the hijack vector
  -u OPENCODE_ROUTING_DB               # pigeon's live routing DB
  -u OPENCODE_DB                       # the shared opencode.db (real session state)
  -u OPENCODE_WORKSPACE_ID
  -u OPENCODE_EXPERIMENTAL_WORKSPACES
  -u OPENCODE_HEARTBEAT_INTERVAL_MS
  -u OPENCODE_DISABLE_CHANNEL_DB       # set in sessions; changes serve behavior => non-hermetic
  -u OPENCODE_SESSION_ID               # a throwaway serve has no business inheriting a session id
)

PORT=$(( 40000 + RANDOM % 20000 ))
DOC_RAW="$TMP/doc.raw.json"

"${SERVE_ENV_SCRUB[@]}" "$OPENCODE_BIN" serve --port "$PORT" --hostname 127.0.0.1 < /dev/null > "$TMP/serve.log" 2>&1 &
SERVE_PID=$!
cleanup() {
  if [ -n "${SERVE_PID:-}" ] && kill -0 "$SERVE_PID" 2>/dev/null; then
    # TERM first so the Effect finalizer can run `markDead` (draining=1); `kill -9`
    # skips it, which is what made the incident permanent instead of self-healing.
    kill -TERM "$SERVE_PID" 2>/dev/null || true
    for _ in $(seq 1 20); do
      kill -0 "$SERVE_PID" 2>/dev/null || break
      sleep 0.25
    done
    if kill -0 "$SERVE_PID" 2>/dev/null; then
      kill -9 "$SERVE_PID" 2>/dev/null || true
    fi
    wait "$SERVE_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP" 2>/dev/null || true
}
trap cleanup EXIT

SUCCESS=0
for _ in $(seq 1 120); do
  if curl -sf --connect-timeout 1 --max-time 3 "http://127.0.0.1:$PORT/doc" -o "$DOC_RAW" 2>/dev/null \
     && [ -s "$DOC_RAW" ]; then
    SUCCESS=1
    break
  fi
  if ! kill -0 "$SERVE_PID" 2>/dev/null; then
    echo "ERROR: opencode serve exited before answering /doc." >&2
    cat "$TMP/serve.log" >&2 || true
    exit 1
  fi
  sleep 0.5
done
# Regression test for the 2026-07-25 slot-hijack incident — see the same check in
# ../test.sh for the full reasoning. `serve heartbeat started` is logged IFF the serve
# registered itself in the routing DB, which a throwaway must never do. Asserting the
# OUTCOME is what holds the line; the env denylist above cannot self-certify.
if grep -q "serve heartbeat started" "$TMP/serve.log" 2>/dev/null; then
  echo "FATAL: the throwaway serve REGISTERED ITSELF in the routing DB." >&2
  echo "       The env scrub is broken; it may have hijacked a live pool slot, which" >&2
  echo "       does NOT self-heal. Check serve_instance.endpoint for every serve_id." >&2
  cat "$TMP/serve.log" >&2 || true
  exit 1
fi

[ "$SUCCESS" -eq 1 ] || { echo "ERROR: /doc not answered in time" >&2; cat "$TMP/serve.log" >&2; exit 1; }

PREV="$OUT"
node - "$DOC_RAW" "$OUT" "$PREV" <<'NODE'
const fs = require('node:fs');
const [rawPath, outPath, prevPath] = process.argv.slice(2);
const raw = JSON.parse(fs.readFileSync(rawPath, 'utf8'));
const METHODS = new Set(['get', 'put', 'post', 'delete', 'patch']);

// Guard the projection's core assumption: pathItem keys are ONLY http methods.
// If upstream ever adds e.g. `parameters` or `$ref` at the pathItem level, the
// projection would silently drop it — so fail loudly instead.
const unexpected = [];
for (const [p, item] of Object.entries(raw.paths ?? {})) {
  for (const k of Object.keys(item ?? {})) {
    if (!METHODS.has(k.toLowerCase())) unexpected.push(`${p} -> ${k}`);
  }
}
if (unexpected.length) {
  console.error('ERROR: non-method pathItem keys present; projection would drop them:');
  for (const u of unexpected) console.error('  ' + u);
  process.exit(1);
}

const out = { openapi: raw.openapi, paths: {} };
const mediaCensus = {};
let pairs = 0;
for (const [p, item] of Object.entries(raw.paths ?? {})) {
  out.paths[p] = {};
  for (const [m, op] of Object.entries(item ?? {})) {
    pairs++;
    const responses = {};
    for (const [code, r] of Object.entries((op && op.responses) || {})) {
      const content = {};
      for (const ct of Object.keys((r && r.content) || {})) {
        content[ct] = {};
        mediaCensus[ct] = (mediaCensus[ct] || 0) + 1;
      }
      // Keep the status key even with no content, so "declares no body" stays visible.
      responses[code] = Object.keys(content).length ? { content } : {};
    }
    out.paths[p][m] = Object.keys(responses).length ? { responses } : {};
  }
}

let prevPairs = null;
try {
  const prev = JSON.parse(fs.readFileSync(prevPath, 'utf8'));
  prevPairs = new Set();
  for (const [p, item] of Object.entries(prev.paths ?? {})) {
    for (const m of Object.keys(item ?? {})) prevPairs.add(`${m.toUpperCase()} ${p}`);
  }
} catch { /* first run */ }

const newPairs = new Set();
for (const [p, item] of Object.entries(out.paths)) {
  for (const m of Object.keys(item)) newPairs.add(`${m.toUpperCase()} ${p}`);
}

fs.writeFileSync(outPath, JSON.stringify(out, null, 1) + '\n');

console.log(`\nWrote ${outPath}`);
console.log(`path x method pairs: ${pairs}`);
console.log('declared response media types:', mediaCensus);
if (prevPairs) {
  const added = [...newPairs].filter(x => !prevPairs.has(x));
  const removed = [...prevPairs].filter(x => !newPairs.has(x));
  console.log(`pairs added vs previous fixture: ${added.length}`, added.slice(0, 20));
  console.log(`pairs removed vs previous fixture: ${removed.length}`, removed.slice(0, 20));
} else {
  console.log('(no previous fixture to diff against)');
}
NODE
