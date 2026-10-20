#!/usr/bin/env bash
# Integration and unit test runner for oc-session-list.
# Run: bash pkgs/oc-session-list/test.sh
set -o errexit -o nounset -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

# OC_SESSION_LIST_BIN lets a caller supply an ALREADY-BUILT binary and skip
# stages 1-2. That is how the `oc-session-list-bin` flake check runs this file:
# a build sandbox has neither a nix daemon nor a network, so stage 2's inner
# `nix build` cannot work there, and stage 1 is the `plugin-bun` check's job
# (running it twice doubles the cost and blurs which check failed).
#
# Everything below stage 2 is the part worth having in CI -- it is the only
# coverage anywhere of the BUILT ARTIFACT, per the comment at the greps below.
# Run with no env var (`bash pkgs/oc-session-list/test.sh`) and the script still
# does the whole thing locally, including the build.
if [ -n "${OC_SESSION_LIST_BIN:-}" ]; then
  # Echo the path. A stale OC_SESSION_LIST_BIN left exported in a shell would
  # otherwise silently test yesterday's binary while reporting ALL PASS.
  BIN="$OC_SESSION_LIST_BIN"
  echo "== 1-2. SKIPPED -- testing caller-supplied binary: $BIN =="
  [ -x "$BIN" ] || fail "OC_SESSION_LIST_BIN=$BIN is not executable"
else
  echo "== 1. Running bun unit tests =="
  bun test assets/opencode/plugins/test/oc-session-list.spec.ts || fail "unit tests failed"
  pass "unit tests passed"

  echo "== 2. Building nix derivation .#oc-session-list =="
  OUT_PATH="$(nix build .#oc-session-list --no-link --print-out-paths)" || fail "nix build failed"
  BIN="$OUT_PATH/bin/oc-session-list"
  [ -x "$BIN" ] || fail "binary $BIN not found or not executable"
  pass "built derivation at $OUT_PATH"
fi

echo "== 3. Testing --help output =="
HELP_OUT="$("$BIN" --help)" || fail "--help exited non-zero"
grep -q "Usage: oc-session-list" <<<"$HELP_OUT" || fail "--help missing usage text"
pass "--help works"

echo "== 4. Testing binary against fixture DB =="
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
TEST_DB="$TMP_DIR/test.db"

# Every stage gets a fake honk that lists NO goose sessions. Goose rows are
# opt-in (--goose) and no earlier stage passes it, so this is belt and braces:
# a real honk on the caller's PATH (cloudbox) must never reach the fixtures.
# Stage 7 swaps in fakes that do list sessions.
fake_honk() { # fake_honk <path> <bash body>
  printf '#!%s\n%s\n' "$(command -v bash)" "$2" >"$1"
  chmod +x "$1"
}
fake_honk "$TMP_DIR/honk-empty" "echo '[]'"
export OC_SESSION_LIST_HONK="$TMP_DIR/honk-empty"

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

JSON_OUT="$("$BIN" --db "$TEST_DB" --limit 10)" || fail "oc-session-list failed on fixture DB"

# Assert JSON output includes 3-level tree items and excludes archived_1.
#
# These greps MUST anchor on the "id" field. A bare `grep -q "child_1"` is
# satisfied by "grandchild_1", and a bare `grep -q "root_1"` is satisfied by any
# row's "root_id" value -- so the built artifact could drop child_1's row
# entirely and this file would stay green. This is the only test that exercises
# the nix-built binary, so vacuity here is expensive.
grep -q '"id": "grandchild_1"' <<<"$JSON_OUT" || fail "grandchild_1 missing from output"
grep -q '"id": "child_1"' <<<"$JSON_OUT"      || fail "child_1 missing from output"
grep -q '"id": "root_1"' <<<"$JSON_OUT"       || fail "root_1 missing from output"

# And the walk must resolve the grandchild to the TRUE root, not the middle
# session -- the defect the recursive CTE exists to prevent.
grep -q '"root_id": "child_1"' <<<"$JSON_OUT" && fail "grandchild resolved to the MIDDLE session, not the true root"

if grep -q '"id": "archived_1"' <<<"$JSON_OUT"; then
  fail "archived_1 was NOT excluded from query output"
fi

pass "fixture DB query assertions passed (3-level nesting + archived exclusion)"

# Hermetic: pass EXPLICIT empty overlay/routing paths. Without these the run
# reads the real ~/.local/share/opencode/session-state.d and the real routing
# DB. It is non-mutating today (no --gc), but this project has already had a
# test destroy a live serve's overlay file, so the isolation is by construction.
EMPTY_OVERLAY_DIR="$TMP_DIR/empty-overlays"
mkdir -p "$EMPTY_OVERLAY_DIR"
JSON_STATE_OUT="$("$BIN" --db "$TEST_DB" --with-state --limit 10 \
  --overlay-dir "$EMPTY_OVERLAY_DIR" --routing-db "$TMP_DIR/no-routing.db" 2>/dev/null)" \
  || fail "oc-session-list --with-state failed on fixture DB"

# An empty overlay dir means NO writer was watching, so the honest answer is
# `nodata`. This fixture is literally the shape of the 2026-08-01 outage (every
# overlay file gone), and asserting `idle` here is what made that outage look
# normal for ~9 hours -- the assertion was encoding the bug as the expectation.
grep -q '"activity": "nodata"' <<<"$JSON_STATE_OUT" \
  || fail "--with-state on an empty overlay dir must report nodata, not a confident status"
grep -q '"activity": "idle"' <<<"$JSON_STATE_OUT" \
  && fail "--with-state claimed idle with no live writer -- that is the S3 regression"

# And the converse, so the above cannot pass by simply never emitting idle: with
# a LIVE overlay file covering the fixture rows' owner, absence means idle.
LIVE_OVERLAY_DIR="$TMP_DIR/live-overlays"
mkdir -p "$LIVE_OVERLAY_DIR"
cat > "$LIVE_OVERLAY_DIR/serve-t-fixture.json" <<JSON
{"version":1,"instanceStamp":1,"pid":$$,"serveId":"serve-t","directory":"/fixture",
 "heartbeat":$(($(date +%s) * 1000)),"sessions":{}}
JSON
JSON_LIVE_OUT="$("$BIN" --db "$TEST_DB" --with-state --limit 10 \
  --overlay-dir "$LIVE_OVERLAY_DIR" --routing-db "$TMP_DIR/no-routing.db" 2>/dev/null)" \
  || fail "oc-session-list --with-state failed with a live overlay"
grep -q '"activity": "idle"' <<<"$JSON_LIVE_OUT" \
  || fail "--with-state must report idle when a live writer is present and silent"
pass "--with-state distinguishes nodata (no writer) from idle (live writer, silent)"

# --- Stage 5: the S6 row model, end to end through the BUILT binary. ---------
#
# The unit tests cover foldRows in isolation. This asserts the flag is actually
# wired in the shipped artifact -- the gap that let pkgs/oc-session-list/test.sh
# itself sit unrun for months (see default.nix's checkPhase note).
JSON_FOLD_OUT="$("$BIN" --db "$TEST_DB" --with-state --fold --limit 10 \
  --overlay-dir "$LIVE_OVERLAY_DIR" --routing-db "$TMP_DIR/no-routing.db" 2>/dev/null)" \
  || fail "oc-session-list --fold failed on fixture DB"

# Roots only: the 3-level tree collapses to root_1, and its descendants are gone
# as ROWS. Anchored on the "id" field for the reason stage 3 documents.
grep -q '"id": "root_1"' <<<"$JSON_FOLD_OUT" \
  || fail "--fold dropped the root itself"
grep -q '"id": "grandchild_1"' <<<"$JSON_FOLD_OUT" \
  && fail "--fold emitted a DESCENDANT as its own row -- the fold did not happen"
grep -q '"id": "child_1"' <<<"$JSON_FOLD_OUT" \
  && fail "--fold emitted a DESCENDANT as its own row -- the fold did not happen"

# Paired POSITIVE, so the two negatives above cannot pass by the command simply
# failing or printing nothing: the fold must report the children it swallowed.
grep -q '"child_count": 2' <<<"$JSON_FOLD_OUT" \
  || fail "--fold lost the child_count for the 3-level tree (empty output would pass the negatives above)"
grep -q '"effective_state"' <<<"$JSON_FOLD_OUT" \
  || fail "--fold emitted no effective_state"
grep -q '"sort_rank"' <<<"$JSON_FOLD_OUT" \
  || fail "--fold emitted no sort_rank"
grep -q '"attention"' <<<"$JSON_FOLD_OUT" \
  || fail "--fold emitted no attention"

# And --fold must not have leaked into the plain shape.
grep -q '"effective_state"' <<<"$JSON_LIVE_OUT" \
  && fail "--with-state alone emitted row-model fields -- the flag is not gating anything"
pass "--fold folds descendants into one root row and leaves --with-state untouched"

# --- Stage 6: --ids (workstation-p8ch), end to end through the BUILT binary. ---
#
# The bun tests cover queryTreesForIds; this proves the flag is wired in the
# shipped artifact and REPLACES the recency window rather than filtering it.
# old_root is older than every other root, so `--limit 1` alone cannot reach it.
bun -e '
import { Database } from "bun:sqlite";
const db = new Database("'$TEST_DB'");
db.exec(`INSERT INTO session VALUES ("old_root", "p1", NULL, "old-root", "/proj", "Old Root", "1.0", 1, 1, NULL);`);
'
JSON_IDS_OUT="$("$BIN" --db "$TEST_DB" --with-state --fold --limit 1 \
  --ids child_1,archived_1,old_root,never_existed \
  --overlay-dir "$LIVE_OVERLAY_DIR" --routing-db "$TMP_DIR/no-routing.db" 2>/dev/null)" \
  || fail "oc-session-list --ids failed on fixture DB"

grep -q '"id": "root_1"' <<<"$JSON_IDS_OUT" \
  || fail "--ids child_1 did not resolve to its root row root_1"
grep -q '"id": "old_root"' <<<"$JSON_IDS_OUT" \
  || fail "--ids was truncated by --limit 1 (old_root is outside the recency window)"
grep -q '"id": "child_1"' <<<"$JSON_IDS_OUT" \
  && fail "--ids --fold emitted a CHILD as its own row"
grep -q '"id": "archived_1"' <<<"$JSON_IDS_OUT" \
  && fail "--ids resurrected an ARCHIVED session"
grep -q '"id": "never_existed"' <<<"$JSON_IDS_OUT" \
  && fail "--ids invented a row for an unknown id"
[ "$(grep -c '"id": ' <<<"$JSON_IDS_OUT")" = 2 ] \
  || fail "--ids should yield exactly 2 root rows (root_1, old_root)"

bun -e '
const rows = JSON.parse(process.argv[1]);
const r1 = rows.find(r => r.id === "root_1");
const ro = rows.find(r => r.id === "old_root");
if (!r1 || JSON.stringify(r1.matched_ids) !== JSON.stringify(["child_1"])) {
  console.error("root_1 missing or wrong matched_ids:", r1);
  process.exit(1);
}
if (!ro || JSON.stringify(ro.matched_ids) !== JSON.stringify(["old_root"])) {
  console.error("old_root missing or wrong matched_ids:", ro);
  process.exit(1);
}
' "$JSON_IDS_OUT" || fail "--ids root rows missing expected matched_ids"

grep -q '"matched_ids"' <<<"$JSON_FOLD_OUT" \
  && fail "non-ids mode emitted matched_ids -- should only be present in --ids mode"

JSON_EMPTY_OUT="$("$BIN" --db "$TEST_DB" --ids "" 2>/dev/null)" || fail "--ids '' failed"
[ "$(tr -d '[:space:]' <<<"$JSON_EMPTY_OUT")" = "[]" ] \
  || fail "--ids with an empty list must print [] -- not fall back to the recency window"
pass "--ids resolves child->root, drops archived/unknown, ignores --limit"

# --- Stage 7: goose sessions (honk-9qf.15.11), through the BUILT binary. -------
#
# The bun tests cover the mapping; this proves the shipped artifact runs honk
# only when asked (--goose), merges goose rows into the fold, honours
# --ids goose:<id>, and degrades to a WARNING (exit 0, opencode rows intact)
# when honk fails.
fake_honk "$TMP_DIR/honk-two" "[ \"\$1 \$2\" = 'list --json' ] || exit 9
cat <<'EOF'
[{\"sessionId\":\"20261019_7\",\"title\":\"Goose chat\",\"cwd\":\"/proj\",\"held\":true,\"running\":true,
  \"updatedAt\":\"2026-10-19T22:00:00Z\",\"lastMessageAt\":null,\"archivedAt\":null,\"sessionType\":\"acp\",\"hasRecipe\":false},
 {\"sessionId\":\"20261019_8\",\"title\":\"Lane run\",\"cwd\":\"/proj\",\"held\":false,\"running\":false,
  \"updatedAt\":\"2026-10-19T22:01:00Z\",\"lastMessageAt\":null,\"archivedAt\":null,\"sessionType\":\"user\",\"hasRecipe\":true},
 {\"sessionId\":\"20261019_9\",\"title\":\"Ancient chat\",\"cwd\":\"/proj\",\"held\":false,\"running\":false,
  \"updatedAt\":\"1970-01-01T00:00:00.500Z\",\"lastMessageAt\":null,\"archivedAt\":null,\"sessionType\":\"acp\",\"hasRecipe\":false}]
EOF"
GOOSE_OUT="$(OC_SESSION_LIST_HONK="$TMP_DIR/honk-two" "$BIN" --db "$TEST_DB" --with-state --fold --goose --limit 10 \
  --overlay-dir "$LIVE_OVERLAY_DIR" --routing-db "$TMP_DIR/no-routing.db" 2>/dev/null)" \
  || fail "oc-session-list failed with a goose-listing honk"
bun -e '
const rows = JSON.parse(process.argv[1]);
const g = rows.find(r => r.id === "goose:20261019_7");
if (!g) { console.error("goose row missing"); process.exit(1); }
if (g.harness !== "goose" || g.effective_state !== "working" || g.directory !== "/proj") {
  console.error("goose row has the wrong shape:", g); process.exit(1);
}
// A recipe run is listed (so ,fs id search can find it) but marked automated,
// which the ordinary picker hides.
const lane = rows.find(r => r.id === "goose:20261019_8");
if (!lane || lane.automated !== true) { console.error("recipe run missing or not automated:", lane); process.exit(1); }
// The opencode window is not full (2 roots, --limit 10), so it has no floor.
if (!rows.some(r => r.id === "goose:20261019_9")) { console.error("an unfull window dropped an old goose row"); process.exit(1); }
if (!rows.some(r => r.id === "root_1")) { console.error("opencode rows lost"); process.exit(1); }
// Newest first: the goose rows (2026) are newer than every fixture row (epoch 1970).
const order = rows.map(r => r.id);
if (order[0] !== "goose:20261019_8" || order[1] !== "goose:20261019_7") { console.error("goose row not placed by the fold sort:", rows.map(r => r.id)); process.exit(1); }
' "$GOOSE_OUT" || fail "goose rows not merged into the fold correctly"

GOOSE_IDS_OUT="$(OC_SESSION_LIST_HONK="$TMP_DIR/honk-two" "$BIN" --db "$TEST_DB" --with-state --fold --goose \
  --ids goose:20261019_8,child_1 \
  --overlay-dir "$LIVE_OVERLAY_DIR" --routing-db "$TMP_DIR/no-routing.db" 2>/dev/null)" \
  || fail "oc-session-list --ids goose:<id> failed"
bun -e '
const rows = JSON.parse(process.argv[1]);
const ids = rows.map(r => r.id).sort();
if (JSON.stringify(ids) !== JSON.stringify(["goose:20261019_8", "root_1"])) {
  console.error("--ids goose:<id> returned", ids); process.exit(1);
}
const g = rows.find(r => r.id === "goose:20261019_8");
if (g.automated !== true || JSON.stringify(g.matched_ids) !== JSON.stringify(["goose:20261019_8"])) {
  console.error("--ids goose row:", g); process.exit(1);
}
' "$GOOSE_IDS_OUT" || fail "--ids did not resolve goose:<id> (recipe runs included, matched_ids set)"

# With --limit 1 the opencode window IS full; its oldest root (root_1's tree,
# max time 3000 ms) becomes the floor, and the 500 ms goose session falls below it.
FLOOR_OUT="$(OC_SESSION_LIST_HONK="$TMP_DIR/honk-two" "$BIN" --db "$TEST_DB" --with-state --fold --goose --limit 1 \
  --overlay-dir "$LIVE_OVERLAY_DIR" --routing-db "$TMP_DIR/no-routing.db" 2>/dev/null)" \
  || fail "oc-session-list --goose --limit 1 failed"
grep -q '"id": "goose:20261019_7"' <<<"$FLOOR_OUT" || fail "a goose row newer than the floor was dropped"
grep -q '"id": "goose:20261019_9"' <<<"$FLOOR_OUT" && fail "a goose row older than the full opencode window was kept"
grep -q '"id": "goose:20261019_8"' <<<"$FLOOR_OUT" || fail "a recipe run newer than the floor was dropped"

# Recipe runs have their own window, under the same floor. A honk listing ONE
# old recipe run, so only the floor (not --limit 1) can leave it out.
fake_honk "$TMP_DIR/honk-old-recipe" "cat <<'EOF'
[{\"sessionId\":\"20261019_10\",\"title\":\"Ancient lane run\",\"cwd\":\"/proj\",\"held\":false,\"running\":false,
  \"updatedAt\":\"1970-01-01T00:00:00.500Z\",\"lastMessageAt\":null,\"archivedAt\":null,\"sessionType\":\"user\",\"hasRecipe\":true}]
EOF"
OLD_RECIPE_FULL="$(OC_SESSION_LIST_HONK="$TMP_DIR/honk-old-recipe" "$BIN" --db "$TEST_DB" --with-state --fold --goose --limit 1 \
  --overlay-dir "$LIVE_OVERLAY_DIR" --routing-db "$TMP_DIR/no-routing.db" 2>/dev/null)" \
  || fail "oc-session-list --goose --limit 1 (old recipe) failed"
grep -q '"id": "goose:20261019_10"' <<<"$OLD_RECIPE_FULL" && fail "a recipe run older than the full opencode window was kept"
OLD_RECIPE_OPEN="$(OC_SESSION_LIST_HONK="$TMP_DIR/honk-old-recipe" "$BIN" --db "$TEST_DB" --with-state --fold --goose --limit 10 \
  --overlay-dir "$LIVE_OVERLAY_DIR" --routing-db "$TMP_DIR/no-routing.db" 2>/dev/null)" \
  || fail "oc-session-list --goose --limit 10 (old recipe) failed"
grep -q '"id": "goose:20261019_10"' <<<"$OLD_RECIPE_OPEN" || fail "an unfull window dropped an old recipe run"

NO_GOOSE_OUT="$(OC_SESSION_LIST_HONK="$TMP_DIR/honk-two" "$BIN" --db "$TEST_DB" --with-state --fold \
  --overlay-dir "$LIVE_OVERLAY_DIR" --routing-db "$TMP_DIR/no-routing.db" 2>/dev/null)" \
  || fail "--with-state without --goose failed"
grep -q '"id": "goose:' <<<"$NO_GOOSE_OUT" && fail "goose sessions listed without --goose (they are opt-in)"

fake_honk "$TMP_DIR/honk-down" "echo 'connection failed: refused' >&2; exit 1"
DOWN_ERR="$TMP_DIR/down.err"
DOWN_OUT="$(OC_SESSION_LIST_HONK="$TMP_DIR/honk-down" "$BIN" --db "$TEST_DB" --with-state --fold --goose \
  --overlay-dir "$LIVE_OVERLAY_DIR" --routing-db "$TMP_DIR/no-routing.db" 2>"$DOWN_ERR")" \
  || fail "a failing honk must not fail oc-session-list"
grep -q '"id": "root_1"' <<<"$DOWN_OUT" || fail "a failing honk lost the opencode rows"
grep -q 'goose sessions unavailable: honk list exited 1: connection failed: refused' "$DOWN_ERR" \
  || fail "a failing honk must warn on stderr"
pass "--with-state merges goose sessions from honk (--goose only, window floor), --ids goose:<id>, warns when honk fails"

echo "ALL PASS (oc-session-list)"
