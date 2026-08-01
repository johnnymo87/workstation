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

# Assert JSON output includes 3-level tree items and excludes archived_1
echo "$JSON_OUT" | grep -q "grandchild_1" || fail "grandchild_1 missing from output"
echo "$JSON_OUT" | grep -q "child_1" || fail "child_1 missing from output"
echo "$JSON_OUT" | grep -q "root_1" || fail "root_1 missing from output"

if echo "$JSON_OUT" | grep -q "archived_1"; then
  fail "archived_1 was NOT excluded from query output"
fi

pass "fixture DB query assertions passed (3-level nesting + archived exclusion)"

echo "ALL PASS (oc-session-list)"
