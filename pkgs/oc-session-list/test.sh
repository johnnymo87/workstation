#!/usr/bin/env bash
# Integration and unit test runner for oc-session-list.
# Run: bash pkgs/oc-session-list/test.sh
set -o errexit -o nounset -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

echo "== 1. Running bun unit tests =="
bun test assets/opencode/plugins/test/oc-session-list.spec.ts || fail "unit tests failed"
pass "unit tests passed"

echo "== 2. Building nix derivation .#oc-session-list =="
OUT_PATH="$(nix build .#oc-session-list --no-link --print-out-paths)" || fail "nix build failed"
[ -x "$OUT_PATH/bin/oc-session-list" ] || fail "binary $OUT_PATH/bin/oc-session-list not found or not executable"
pass "built derivation at $OUT_PATH"

echo "== 3. Testing --help output =="
HELP_OUT="$("$OUT_PATH/bin/oc-session-list" --help)" || fail "--help exited non-zero"
echo "$HELP_OUT" | grep -q "Usage: oc-session-list" || fail "--help missing usage text"
pass "--help works"

echo "== 4. Testing binary against fixture DB =="
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
TEST_DB="$TMP_DIR/test.db"

bun -e '
import { Database } from "bun:sqlite";
const db = new Database("'$TEST_DB'");
db.exec(`
  CREATE TABLE session (
    id TEXT PRIMARY KEY,
    project_id TEXT NOT NULL,
    parent_id TEXT,
    slug TEXT NOT NULL,
    directory TEXT NOT NULL,
    title TEXT NOT NULL,
    version TEXT NOT NULL,
    time_created INTEGER NOT NULL,
    time_updated INTEGER NOT NULL,
    time_archived INTEGER
  );

  -- 3-level tree: root_1 -> child_1 -> grandchild_1
  INSERT INTO session VALUES ("root_1", "p1", NULL, "root-1", "/proj", "Root 1", "1.0", 1000, 1000, NULL);
  INSERT INTO session VALUES ("child_1", "p1", "root_1", "child-1", "/proj", "Child 1", "1.0", 1000, 2000, NULL);
  INSERT INTO session VALUES ("grandchild_1", "p1", "child_1", "grandchild-1", "/proj", "Grandchild 1", "1.0", 1000, 3000, NULL);

  -- Archived session
  INSERT INTO session VALUES ("archived_1", "p1", NULL, "archived-1", "/proj", "Archived 1", "1.0", 1000, 4000, 4001);
`);
'

JSON_OUT="$("$OUT_PATH/bin/oc-session-list" --db "$TEST_DB" --limit 10)" || fail "oc-session-list failed on fixture DB"

# Assert JSON output includes 3-level tree items and excludes archived_1.
#
# These greps MUST anchor on the "id" field. A bare `grep -q "child_1"` is
# satisfied by "grandchild_1", and a bare `grep -q "root_1"` is satisfied by any
# row's "root_id" value -- so the built artifact could drop child_1's row
# entirely and this file would stay green. This is the only test that exercises
# the nix-built binary, so vacuity here is expensive.
echo "$JSON_OUT" | grep -q '"id": "grandchild_1"' || fail "grandchild_1 missing from output"
echo "$JSON_OUT" | grep -q '"id": "child_1"'      || fail "child_1 missing from output"
echo "$JSON_OUT" | grep -q '"id": "root_1"'       || fail "root_1 missing from output"

# And the walk must resolve the grandchild to the TRUE root, not the middle
# session -- the defect the recursive CTE exists to prevent.
echo "$JSON_OUT" | grep -q '"root_id": "child_1"' && fail "grandchild resolved to the MIDDLE session, not the true root"

if echo "$JSON_OUT" | grep -q '"id": "archived_1"'; then
  fail "archived_1 was NOT excluded from query output"
fi

pass "fixture DB query assertions passed (3-level nesting + archived exclusion)"

# Hermetic: pass EXPLICIT empty overlay/routing paths. Without these the run
# reads the real ~/.local/share/opencode/session-state.d and the real routing
# DB. It is non-mutating today (no --gc), but this project has already had a
# test destroy a live serve's overlay file, so the isolation is by construction.
EMPTY_OVERLAY_DIR="$TMP_DIR/empty-overlays"
mkdir -p "$EMPTY_OVERLAY_DIR"
JSON_STATE_OUT="$("$OUT_PATH/bin/oc-session-list" --db "$TEST_DB" --with-state --limit 10 \
  --overlay-dir "$EMPTY_OVERLAY_DIR" --routing-db "$TMP_DIR/no-routing.db" 2>/dev/null)" \
  || fail "oc-session-list --with-state failed on fixture DB"

# An empty overlay dir means NO writer was watching, so the honest answer is
# `nodata`. This fixture is literally the shape of the 2026-08-01 outage (every
# overlay file gone), and asserting `idle` here is what made that outage look
# normal for ~9 hours -- the assertion was encoding the bug as the expectation.
echo "$JSON_STATE_OUT" | grep -q '"activity": "nodata"' \
  || fail "--with-state on an empty overlay dir must report nodata, not a confident status"
echo "$JSON_STATE_OUT" | grep -q '"activity": "idle"' \
  && fail "--with-state claimed idle with no live writer -- that is the S3 regression"

# And the converse, so the above cannot pass by simply never emitting idle: with
# a LIVE overlay file covering the fixture rows' owner, absence means idle.
LIVE_OVERLAY_DIR="$TMP_DIR/live-overlays"
mkdir -p "$LIVE_OVERLAY_DIR"
cat > "$LIVE_OVERLAY_DIR/serve-t-fixture.json" <<JSON
{"version":1,"instanceStamp":1,"pid":$$,"serveId":"serve-t","directory":"/fixture",
 "heartbeat":$(($(date +%s) * 1000)),"sessions":{}}
JSON
JSON_LIVE_OUT="$("$OUT_PATH/bin/oc-session-list" --db "$TEST_DB" --with-state --limit 10 \
  --overlay-dir "$LIVE_OVERLAY_DIR" --routing-db "$TMP_DIR/no-routing.db" 2>/dev/null)" \
  || fail "oc-session-list --with-state failed with a live overlay"
echo "$JSON_LIVE_OUT" | grep -q '"activity": "idle"' \
  || fail "--with-state must report idle when a live writer is present and silent"
pass "--with-state distinguishes nodata (no writer) from idle (live writer, silent)"

echo "ALL PASS (oc-session-list)"
