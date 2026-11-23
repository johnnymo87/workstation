#!/usr/bin/env python3
"""check_grafana_dashboards.py: Lint and execution guard for Grafana dashboards.

Validates that Grafana dashboard JSON files in hosts/cloudbox/grafana-dashboards:
1. Comply with security and styling lint rules (no '@', no account filters, editable=false, etc.).
2. Execute cleanly against an in-memory SQLite schema populated with test fixtures.
3. Include self-tests proving that planted violations are caught by the lint rules.
"""

from __future__ import annotations

import copy
import json
import re
import sqlite3
import sys
from pathlib import Path
from typing import Any

# Ensure pkgs/llm-ledger and pkgs/oc-tags are on PYTHONPATH if not already
repo_root = Path(__file__).resolve().parent.parent.parent
for pkg_dir in [repo_root / "pkgs" / "llm-ledger", repo_root / "pkgs" / "oc-tags"]:
    if str(pkg_dir) not in sys.path and pkg_dir.exists():
        sys.path.insert(0, str(pkg_dir))

import llm_ledger  # type: ignore  # noqa: E402


def lint_dashboard(path: Path, raw_text: str, data: dict[str, Any], seen_uids: set[str]) -> list[str]:
    """Run lint checks on a single dashboard JSON file."""
    errors: list[str] = []

    # 1. No '@' anywhere in the raw text
    if "@" in raw_text:
        errors.append(f"{path}: contains forbidden '@' character")

    # 2. editable must be false
    if data.get("editable") is not False:
        errors.append(f"{path}: editable must be false, got {data.get('editable')}")

    # 3. Unique, non-empty uid
    uid = data.get("uid")
    if not uid or not isinstance(uid, str):
        errors.append(f"{path}: missing or invalid 'uid'")
    elif uid in seen_uids:
        errors.append(f"{path}: duplicate dashboard uid '{uid}'")
    else:
        seen_uids.add(uid)

    expected_ds = {"type": "frser-sqlite-datasource", "uid": "llm-ledger"}

    # 4. Templating variables linting
    templating = data.get("templating", {})
    var_list = templating.get("list", [])
    for var in var_list:
        vname = var.get("name", "<unnamed>")
        if var.get("type") == "query":
            v_ds = var.get("datasource")
            if v_ds != expected_ds:
                errors.append(f"{path}: variable '{vname}' datasource must be {expected_ds}, got {v_ds}")
            v_query = var.get("query", "")
            if isinstance(v_query, str):
                if re.search(r"\baccount\s*(=|IN\b|LIKE\b)", v_query, re.IGNORECASE):
                    errors.append(f"{path}: variable '{vname}' SQL contains forbidden account filter: {v_query}")

    # 5. Panel & target linting
    panels = data.get("panels", [])
    for p_idx, panel in enumerate(panels):
        p_title = panel.get("title", f"panel[{p_idx}]")
        p_ds = panel.get("datasource")
        if p_ds != expected_ds:
            errors.append(f"{path}: panel '{p_title}' datasource must be {expected_ds}, got {p_ds}")

        targets = panel.get("targets", [])
        for t_idx, target in enumerate(targets):
            t_ref = target.get("refId", f"target[{t_idx}]")
            t_ds = target.get("datasource")
            if t_ds != expected_ds:
                errors.append(f"{path}: panel '{p_title}' target '{t_ref}' datasource must be {expected_ds}, got {t_ds}")

            raw_qt = target.get("rawQueryText")
            qt = target.get("queryText")
            if raw_qt != qt:
                errors.append(f"{path}: panel '{p_title}' target '{t_ref}' rawQueryText does not match queryText")

            sql = raw_qt or ""
            # No account literal comparisons (account = / IN / LIKE)
            if re.search(r"\baccount\s*(=|IN\b|LIKE\b)", sql, re.IGNORECASE):
                errors.append(f"{path}: panel '{p_title}' target '{t_ref}' contains forbidden account filter")

            # Every query reading requests/hourly/quota_samples must have $__from and $__to
            reads_bounded_tables = any(
                re.search(rf"\b{table}\b", sql, re.IGNORECASE)
                for table in ["requests", "hourly", "quota_samples"]
            )
            if reads_bounded_tables:
                if "$__from" not in sql or "$__to" not in sql:
                    errors.append(
                        f"{path}: panel '{p_title}' target '{t_ref}' reads bounded table but lacks $__from or $__to: {sql}"
                    )

    return errors


def substitute_query(sql: str, params: dict[str, Any]) -> str:
    """Substitute Grafana macros and template variables in SQL query."""
    res = sql
    for k, v in params.items():
        res = res.replace(f"${k}", str(v))
        res = res.replace(f"${{{k}}}", str(v))
        res = res.replace(f"${{{k}:sqlstring}}", str(v))
    return res


def build_fixture_db() -> sqlite3.Connection:
    """Create in-memory SQLite database and populate with test fixtures."""
    conn = sqlite3.connect(":memory:")
    conn.executescript(llm_ledger.SCHEMA_SQL)

    t_now = 1795000000000  # Nov 2026 ms epoch
    t_next = t_now + 86400 * 1000

    # 1. session_program: manual tag, auto tag with '/', and leave attr-orphan without a row
    conn.execute(
        """
        INSERT INTO session_program (attr_key, tag, source, root, title, updated_at) VALUES
          ('attr-manual', 'lgtm', 'manual', 'ses_1', 'Manual Session', ?),
          ('attr-auto', 'auto:mono/branch-fix', 'auto', 'ses_2', 'Auto Session', ?)
        """,
        (t_now, t_now),
    )

    # 2. hourly: rows for attr-manual, attr-auto, and attr-orphan
    conn.execute(
        """
        INSERT INTO hourly (hour, attr_key, backend, model, n, input, output, cache_read, cache_write, cost_usd) VALUES
          (?, 'attr-manual', 'max', 'claude-opus-5-5', 10, 1000, 500, 200, 100, 1.5),
          (?, 'attr-auto', 'vertex', 'claude-opus-5-5', 5, 500, 250, 100, 50, 2.0),
          (?, 'attr-orphan', 'enterprise', 'claude-haiku-4-5', 2, 200, 100, 50, 20, 0.5)
        """,
        (t_now, t_now, t_now),
    )

    # 3. route & requests
    conn.execute(
        """
        INSERT INTO route (request_id, ts, session_id, model, desired, chosen) VALUES
          ('req-1', ?, 'ses_2', 'claude-opus-5-5', 'max', 'vertex'),
          ('req-2', ?, 'ses_1', 'claude-opus-5-5', 'vertex', 'vertex')
        """,
        (t_now, t_now),
    )
    conn.execute(
        """
        INSERT INTO requests (request_id, ts, host, session_id, attr_key, backend, model, input, output, cache_read, cache_write, cost_usd, status, duration_ms) VALUES
          ('req-1', ?, 'cloudbox', 'ses_2', 'attr-auto', 'vertex', 'claude-opus-5-5', 500, 250, 100, 50, 2.0, 200, 500),
          ('req-2', ?, 'cloudbox', 'ses_1', 'attr-manual', 'vertex', 'claude-opus-5-5', 100, 50, 0, 0, 0.5, 200, 400)
        """,
        (t_now, t_now),
    )

    # 4. quota_samples: two fake accounts acct-a/acct-b, one with null u7d
    conn.execute(
        """
        INSERT INTO quota_samples (ts, account, s, u5h, u7d, u7d_fable, fw, r7d, r5h) VALUES
          (?, 'acct-a', 'active', 0.1, 0.85, 0.1, 0, ?, ?),
          (?, 'acct-b', 'active', 0.2, NULL, 0.2, 0, ?, ?)
        """,
        (t_now, t_next, t_now + 18000000, t_now, t_next, t_now + 18000000),
    )

    # 5. quota_watch_runs
    conn.execute(
        """
        INSERT INTO quota_watch_runs (ts, h0, burn_h, burn_6h, burn_24h, spill_6h, spill_24h, k, zero_h, vertex_usd, next_refill_ts, next_refill_amt, pool_n, source) VALUES
          (?, 1.25, 0.05, 0.04, 0.05, 0.0, 0.0, 100.0, 0.0, 0.0, ?, 0.4, 5, 'live')
        """,
        (t_now, t_next),
    )

    # 6. quota_forecast
    conn.execute(
        """
        INSERT INTO quota_forecast (ts, headroom, run_ts) VALUES
          (?, 1.25, ?),
          (?, 1.20, ?)
        """,
        (t_now, t_now, t_now + 300000, t_now),
    )

    conn.commit()
    return conn


def execute_dashboard_queries(dash_path: Path, data: dict[str, Any], conn: sqlite3.Connection) -> None:
    """Execute all variable and panel queries against the fixture database."""
    t_now = 1795000000000
    sub_params: dict[str, Any] = {
        "__from": t_now - 7 * 86400 * 1000,
        "__to": t_now + 86400 * 1000,
        "__interval_ms": 3600000,
    }

    # Execute variable queries and gather their values
    templating = data.get("templating", {})
    var_list = templating.get("list", [])
    for var in var_list:
        vname = var.get("name")
        vquery = var.get("query")
        if var.get("type") == "query" and isinstance(vquery, str):
            cur = conn.execute(vquery)
            rows = cur.fetchall()
            vals = [str(r[0]) for r in rows if r and r[0] is not None]
            # Format as SQL comma-separated quoted list: 'val1','val2'
            quoted = ",".join(f"'{v}'" for v in vals) if vals else "'__none__'"
            sub_params[vname] = quoted

    # Execute panel queries
    for p_idx, panel in enumerate(data.get("panels", [])):
        p_title = panel.get("title", f"panel[{p_idx}]")
        targets = panel.get("targets", [])
        for t_idx, target in enumerate(targets):
            t_ref = target.get("refId", f"target[{t_idx}]")
            raw_sql = target.get("rawQueryText", "")
            if not raw_sql:
                continue

            substituted_sql = substitute_query(raw_sql, sub_params)
            try:
                cur = conn.execute(substituted_sql)
                rows = cur.fetchall()
            except Exception as e:
                raise RuntimeError(
                    f"{dash_path}: panel '{p_title}' target '{t_ref}' SQL execution failed:\n"
                    f"Query: {substituted_sql}\nError: {e}"
                ) from e

            col_names = [d[0] for d in cur.description] if cur.description else []
            if target.get("queryType") == "time series":
                if "time" not in col_names:
                    raise AssertionError(
                        f"{dash_path}: panel '{p_title}' target '{t_ref}' is time series but returns no 'time' column (got {col_names}):\n"
                        f"{substituted_sql}"
                    )


def run_self_tests() -> None:
    """Verify that the lint rules catch planted violations."""
    dummy_path = Path("planted_test.json")

    base_valid = {
        "uid": "test-valid",
        "editable": False,
        "panels": [
            {
                "title": "Valid Panel",
                "datasource": {"type": "frser-sqlite-datasource", "uid": "llm-ledger"},
                "targets": [
                    {
                        "refId": "A",
                        "datasource": {"type": "frser-sqlite-datasource", "uid": "llm-ledger"},
                        "rawQueryText": "SELECT hour AS time FROM hourly WHERE hour >= $__from AND hour < $__to",
                        "queryText": "SELECT hour AS time FROM hourly WHERE hour >= $__from AND hour < $__to",
                        "queryType": "time series",
                    }
                ],
            }
        ],
        "templating": {
            "list": [
                {
                    "name": "backend",
                    "type": "query",
                    "datasource": {"type": "frser-sqlite-datasource", "uid": "llm-ledger"},
                    "query": "SELECT DISTINCT backend FROM hourly",
                }
            ]
        },
    }

    # Valid check should have 0 errors
    errs = lint_dashboard(dummy_path, json.dumps(base_valid), base_valid, set())
    assert len(errs) == 0, f"Base valid fixture failed lint: {errs}"

    planted_cases: list[tuple[str, str, dict[str, Any], set[str]]] = []

    # 1. Contains '@'
    d1 = copy.deepcopy(base_valid)
    raw1 = json.dumps(d1) + "\n// test@example.com"
    planted_cases.append(("contains '@'", raw1, d1, set()))

    # 2. editable is true
    d2 = copy.deepcopy(base_valid)
    d2["editable"] = True
    planted_cases.append(("editable is true", json.dumps(d2), d2, set()))

    # 3. Duplicate uid
    d3 = copy.deepcopy(base_valid)
    planted_cases.append(("duplicate uid", json.dumps(d3), d3, {"test-valid"}))

    # 4. Wrong panel datasource
    d4 = copy.deepcopy(base_valid)
    d4["panels"][0]["datasource"] = {"type": "frser-sqlite-datasource", "uid": "wrong-ds"}
    planted_cases.append(("wrong panel datasource", json.dumps(d4), d4, set()))

    # 5. Wrong target datasource
    d5 = copy.deepcopy(base_valid)
    d5["panels"][0]["targets"][0]["datasource"] = {"type": "frser-sqlite-datasource", "uid": "wrong-ds"}
    planted_cases.append(("wrong target datasource", json.dumps(d5), d5, set()))

    # 6. Wrong variable datasource
    d6 = copy.deepcopy(base_valid)
    d6["templating"]["list"][0]["datasource"] = {"type": "frser-sqlite-datasource", "uid": "wrong-ds"}
    planted_cases.append(("wrong variable datasource", json.dumps(d6), d6, set()))

    # 7. rawQueryText != queryText
    d7 = copy.deepcopy(base_valid)
    d7["panels"][0]["targets"][0]["queryText"] = "SELECT 1"
    planted_cases.append(("rawQueryText mismatch", json.dumps(d7), d7, set()))

    # 8. Query on hourly missing $__to
    d8 = copy.deepcopy(base_valid)
    bad_sql8 = "SELECT hour AS time FROM hourly WHERE hour >= $__from"
    d8["panels"][0]["targets"][0]["rawQueryText"] = bad_sql8
    d8["panels"][0]["targets"][0]["queryText"] = bad_sql8
    planted_cases.append(("missing $__to", json.dumps(d8), d8, set()))

    # 9. Query on requests missing $__from
    d9 = copy.deepcopy(base_valid)
    bad_sql9 = "SELECT ts AS time FROM requests WHERE ts < $__to"
    d9["panels"][0]["targets"][0]["rawQueryText"] = bad_sql9
    d9["panels"][0]["targets"][0]["queryText"] = bad_sql9
    planted_cases.append(("missing $__from", json.dumps(d9), d9, set()))

    # 10. Query with forbidden account = '...'
    d10 = copy.deepcopy(base_valid)
    bad_sql10 = "SELECT ts AS time FROM quota_samples WHERE ts >= $__from AND ts < $__to AND account = 'acct-a'"
    d10["panels"][0]["targets"][0]["rawQueryText"] = bad_sql10
    d10["panels"][0]["targets"][0]["queryText"] = bad_sql10
    planted_cases.append(("forbidden account =", json.dumps(d10), d10, set()))

    # 11. Query with forbidden account IN (...)
    d11 = copy.deepcopy(base_valid)
    bad_sql11 = "SELECT ts AS time FROM quota_samples WHERE ts >= $__from AND ts < $__to AND account IN ('acct-a')"
    d11["panels"][0]["targets"][0]["rawQueryText"] = bad_sql11
    d11["panels"][0]["targets"][0]["queryText"] = bad_sql11
    planted_cases.append(("forbidden account IN", json.dumps(d11), d11, set()))

    # 12. Query with forbidden account LIKE '...'
    d12 = copy.deepcopy(base_valid)
    bad_sql12 = "SELECT ts AS time FROM quota_samples WHERE ts >= $__from AND ts < $__to AND account LIKE 'acct%'"
    d12["panels"][0]["targets"][0]["rawQueryText"] = bad_sql12
    d12["panels"][0]["targets"][0]["queryText"] = bad_sql12
    planted_cases.append(("forbidden account LIKE", json.dumps(d12), d12, set()))

    for name, raw_text, data, seen in planted_cases:
        caught_errs = lint_dashboard(dummy_path, raw_text, data, seen)
        if not caught_errs:
            raise AssertionError(f"SELF-TEST FAILURE: planted violation '{name}' was not caught by linter!")

    # 13. Time series query execution missing 'time' column
    conn = build_fixture_db()
    d13 = copy.deepcopy(base_valid)
    bad_sql13 = "SELECT hour AS not_time FROM hourly WHERE hour >= $__from AND hour < $__to"
    d13["panels"][0]["targets"][0]["rawQueryText"] = bad_sql13
    d13["panels"][0]["targets"][0]["queryText"] = bad_sql13
    try:
        execute_dashboard_queries(dummy_path, d13, conn)
        raise AssertionError("SELF-TEST FAILURE: time series query missing 'time' column was not caught!")
    except AssertionError:
        pass  # Expected

    print(f"check_grafana_dashboards: {len(planted_cases) + 1} self-test cases verified successfully")


def main() -> None:
    # 1. Run self-tests first
    run_self_tests()

    dashboards_dir = Path(sys.argv[1]) if len(sys.argv) > 1 else repo_root / "hosts" / "cloudbox" / "grafana-dashboards"
    if not dashboards_dir.is_dir():
        print(f"Error: {dashboards_dir} is not a directory", file=sys.stderr)
        sys.exit(1)

    json_files = sorted(dashboards_dir.glob("*.json"))
    if not json_files:
        print(f"Error: no .json files found in {dashboards_dir}", file=sys.stderr)
        sys.exit(1)

    seen_uids: set[str] = set()
    all_errors: list[str] = []
    parsed_dashboards: list[tuple[Path, dict[str, Any]]] = []

    # 2. Lint phase
    for path in json_files:
        raw_text = path.read_text(encoding="utf-8")
        try:
            data = json.loads(raw_text)
        except Exception as e:
            all_errors.append(f"{path}: JSON parse error: {e}")
            continue

        errors = lint_dashboard(path, raw_text, data, seen_uids)
        all_errors.extend(errors)
        parsed_dashboards.append((path, data))

    if all_errors:
        print("GATE FAILURE: Grafana dashboard linting failed:", file=sys.stderr)
        for err in all_errors:
            print(f"  * {err}", file=sys.stderr)
        sys.exit(1)

    # 3. Execution phase against fixture DB
    conn = build_fixture_db()
    for path, data in parsed_dashboards:
        try:
            execute_dashboard_queries(path, data, conn)
        except Exception as e:
            print(f"GATE FAILURE: {e}", file=sys.stderr)
            sys.exit(1)

    print(f"check_grafana_dashboards: {len(parsed_dashboards)} dashboards passed lint and execution checks")


if __name__ == "__main__":
    main()
