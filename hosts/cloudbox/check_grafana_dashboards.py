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


def collect_panels(panels: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Flatten panel list, recursing into nested panel['panels'] (row panels)."""
    res: list[dict[str, Any]] = []
    for p in panels:
        res.append(p)
        nested = p.get("panels")
        if isinstance(nested, list):
            res.extend(collect_panels(nested))
    return res


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
                if re.search(r"\baccount\s*(!=|<>|=|IN\b|LIKE\b)", v_query, re.IGNORECASE):
                    errors.append(f"{path}: variable '{vname}' SQL contains forbidden account filter: {v_query}")

    # 5. Panel & target linting (recursing into nested row panels)
    panels = collect_panels(data.get("panels", []))
    for p_idx, panel in enumerate(panels):
        p_title = panel.get("title", f"panel[{p_idx}]")
        p_type = panel.get("type", "")
        p_ds = panel.get("datasource")
        if p_type == "row":
            if p_ds is not None and p_ds != expected_ds:
                errors.append(f"{path}: row panel '{p_title}' datasource must be {expected_ds}, got {p_ds}")
        else:
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
            # No account literal comparisons (account = / != / <> / IN / LIKE)
            if re.search(r"\baccount\s*(!=|<>|=|IN\b|LIKE\b)", sql, re.IGNORECASE):
                errors.append(f"{path}: panel '{p_title}' target '{t_ref}' contains forbidden account filter")

            # (a) Every target with queryType "time series" must list "time" in timeColumns
            if target.get("queryType") == "time series":
                time_cols = target.get("timeColumns", [])
                if "time" not in time_cols:
                    errors.append(
                        f"{path}: panel '{p_title}' target '{t_ref}' queryType is 'time series' but 'time' is not in timeColumns: {time_cols}"
                    )

            # Every query reading bounded tables/views must have $__from/${__from} and $__to/${__to}
            reads_bounded_tables = bool(
                re.search(
                    r"\b(?:FROM|JOIN)\s+(?:[A-Za-z0-9_]+\.)?(?:requests|hourly|fleet_hourly|remote_hourly|teamclaude_usage|teamclaude_hourly|fleet_account_hourly|quota_samples)\b",
                    sql,
                    re.IGNORECASE,
                )
            )
            if reads_bounded_tables:
                has_from = "$__from" in sql or "${__from}" in sql
                has_to = "$__to" in sql or "${__to}" in sql
                if not (has_from and has_to):
                    errors.append(
                        f"{path}: panel '{p_title}' target '{t_ref}' reads bounded table but lacks $__from or $__to: {sql}"
                    )

        # 6. Override matchers and fieldConfig links linting
        fc = panel.get("fieldConfig", {})
        overrides = fc.get("overrides", [])
        for ov_idx, override in enumerate(overrides):
            matcher = override.get("matcher", {})
            if matcher.get("id") == "byName":
                opt = matcher.get("options")
                if isinstance(opt, str):
                    pat = rf'(?i:\bAS\s+)(?:\"{re.escape(opt)}\"(?!\w)|{re.escape(opt)}\b)'
                    found = any(
                        re.search(pat, target.get("rawQueryText") or "")
                        for target in targets
                    )
                    if not found:
                        errors.append(
                            f"{path}: panel '{p_title}' override[{ov_idx}] matcher byName option '{opt}' does not appear as column alias in any target"
                        )

        links_to_check: list[dict[str, Any]] = []
        for link in fc.get("defaults", {}).get("links", []):
            if isinstance(link, dict):
                links_to_check.append(link)
        for override in overrides:
            for prop in override.get("properties", []):
                if prop.get("id") == "links":
                    val = prop.get("value")
                    if isinstance(val, list):
                        for link in val:
                            if isinstance(link, dict):
                                links_to_check.append(link)
        for link in links_to_check:
            url = link.get("url", "")
            if "${__url}" in url:
                errors.append(
                    f"{path}: panel '{p_title}' data link URL contains forbidden '${{__url}}': {url}"
                )
            if not url.startswith("/d/"):
                errors.append(
                    f"{path}: panel '{p_title}' data link URL must start with '/d/': {url}"
                )

        # 7. (d) Stat panel with dateTime override and empty timeColumns must not use default reduceOptions.fields: ""
        if p_type == "stat":
            all_target_time_cols: list[str] = []
            for t in targets:
                all_target_time_cols.extend(t.get("timeColumns", []))
            if not all_target_time_cols:
                has_datetime_override = False
                for ov in overrides:
                    for prop in ov.get("properties", []):
                        if prop.get("id") == "unit":
                            val_str = str(prop.get("value", ""))
                            if "datetime" in val_str.lower() or val_str.startswith("dateTime"):
                                has_datetime_override = True
                                break
                    if has_datetime_override:
                        break
                if has_datetime_override:
                    r_fields = panel.get("options", {}).get("reduceOptions", {}).get("fields")
                    if r_fields == "":
                        errors.append(
                            f"{path}: panel '{p_title}' is a stat panel with dateTime override and empty timeColumns, "
                            f"but uses default numeric-only reduceOptions.fields: '' (must include '/.*/')"
                        )

    return errors


def quote_sql_str(s: Any) -> str:
    """Format string or value for SQL literal with doubled single quotes."""
    return "'" + str(s).replace("'", "''") + "'"


def substitute_query(sql: str, params: dict[str, Any]) -> str:
    """Substitute Grafana macros and template variables in SQL query."""
    res = sql
    for k, v in params.items():
        if isinstance(v, list):
            sqlstring_val = ",".join(quote_sql_str(item) for item in v) if v else "'__none__'"
            plain_val = ",".join(str(item) for item in v)
        elif isinstance(v, str):
            if v.startswith("'") and v.endswith("'"):
                sqlstring_val = v
            else:
                sqlstring_val = quote_sql_str(v)
            plain_val = v
        else:
            sqlstring_val = str(v)
            plain_val = str(v)

        res = res.replace(f"${{{k}:sqlstring}}", sqlstring_val)
        res = res.replace(f"${{{k}}}", plain_val)
        res = re.sub(rf"\${re.escape(k)}\b", plain_val, res)
    return res


def build_fixture_db() -> sqlite3.Connection:
    """Create in-memory SQLite database and populate with test fixtures."""
    conn = sqlite3.connect(":memory:")
    conn.executescript(llm_ledger.SCHEMA_SQL)
    llm_ledger.ensure_fleet_objects(conn, "cloudbox")

    t_now = 1795000000000  # Nov 2026 ms epoch
    t_next = t_now + 86400 * 1000

    # 1. session_program: manual tag, auto tag with '/', tag with apostrophe, and leave attr-orphan without a row
    conn.execute(
        """
        INSERT INTO session_program (attr_key, tag, source, root, title, updated_at) VALUES
          ('attr-manual', 'lgtm', 'manual', 'ses_1', 'Manual Session', ?),
          ('attr-auto', 'auto:mono/branch-fix', 'auto', 'ses_2', 'Auto Session', ?),
          ('attr-quote', "team's-feature", 'manual', 'ses_3', 'Quote Session', ?)
        """,
        (t_now, t_now, t_now),
    )

    # 2. hourly: rows for attr-manual, attr-auto, attr-orphan, attr-quote, and agy
    conn.execute(
        """
        INSERT INTO hourly (hour, attr_key, backend, model, n, input, output, cache_read, cache_write, cost_usd) VALUES
          (?, 'attr-manual', 'max', 'claude-opus-5-5', 10, 1000, 500, 200, 100, 1.5),
          (?, 'attr-auto', 'vertex', 'claude-opus-5-5', 5, 500, 250, 100, 50, 2.0),
          (?, 'attr-orphan', 'enterprise', 'claude-haiku-4-5', 2, 200, 100, 50, 20, 0.5),
          (?, 'attr-quote', 'vertex', 'claude-opus-5-5', 3, 300, 150, 60, 30, 0.8),
          (?, 'attr-manual', 'agy', 'claude-opus-5-5', 4, 400, 200, 80, 40, 1.2)
        """,
        (t_now, t_now, t_now, t_now, t_now),
    )

    # 2b. remote_hosts & remote_hourly: devbox fixtures
    conn.execute(
        """
        INSERT INTO remote_hosts (host, first_hour, exported_through, imported_at) VALUES
          ('devbox', ?, ?, ?)
        """,
        (t_now - 86400 * 1000, t_now - 1800 * 1000, t_now),
    )
    conn.execute(
        """
        INSERT INTO remote_hourly (host, hour, account, backend, model, requests, input, output, cache_read, cache_write_5m, cache_write_1h, cost_usd) VALUES
          ('devbox', ?, 'acct-dev', 'max', 'claude-opus-5-5', 6, 600, 300, 120, 30, 30, 1.8)
        """,
        (t_now,),
    )
    conn.execute(
        """
        INSERT INTO teamclaude_hourly (hour, host, account, model, n, input, output, cache_read, cache_write_5m, cache_write_1h, cost_usd) VALUES
          (?, 'cloudbox', 'acct-a', 'claude-opus-5-5', 5, 500, 250, 100, 50, 0, 1.5)
        """,
        (t_now,),
    )
    llm_ledger.ensure_fleet_objects(conn, "cloudbox")

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
        INSERT INTO quota_watch_runs (ts, h0, burn_h, burn_6h, burn_24h, spill_6h, spill_24h, k, zero_h, vertex_usd, next_refill_ts, next_refill_amt, pool_n, source, verdict) VALUES
          (?, 0.20, 0.12, 0.10, 0.12, 0.0, 0.0, 100.0, 5.0, 0.0, ?, 0.4, 5, 'live', 'dry'),
          (?, 0.85, 0.08, 0.07, 0.08, 0.0, 0.0, 100.0, 1.5, 0.0, ?, 0.4, 5, 'live', 'tight'),
          (?, 1.25, 0.05, 0.04, 0.05, 0.0, 0.0, 100.0, 0.0, 0.0, ?, 0.4, 5, 'live', 'ample')
        """,
        (t_now - 7200000, t_next, t_now - 3600000, t_next, t_now, t_next),
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
            # Format as SQL comma-separated quoted list with doubled single quotes
            quoted = ",".join(quote_sql_str(v) for v in vals) if vals else "'__none__'"
            sub_params[vname] = quoted

    # Execute panel queries (recursing into nested row panels)
    for p_idx, panel in enumerate(collect_panels(data.get("panels", []))):
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
                interval_s = sub_params["__interval_ms"] / 1000.0
                min_time_s = sub_params["__from"] / 1000.0 - interval_s
                max_time_s = sub_params["__to"] / 1000.0
                time_cols = target.get("timeColumns", [])
                for tcol in time_cols:
                    if tcol not in col_names:
                        raise AssertionError(
                            f"{dash_path}: panel '{p_title}' target '{t_ref}' timeColumn '{tcol}' not in returned columns {col_names}"
                        )
                    c_idx = col_names.index(tcol)
                    for row in rows:
                        val = row[c_idx]
                        if val is not None:
                            try:
                                val_f = float(val)
                            except (ValueError, TypeError):
                                raise AssertionError(
                                    f"{dash_path}: panel '{p_title}' target '{t_ref}' column '{tcol}' value {val!r} is not numeric"
                                )
                            if not (min_time_s <= val_f <= max_time_s):
                                raise AssertionError(
                                    f"{dash_path}: panel '{p_title}' target '{t_ref}' column '{tcol}' value {val_f} "
                                    f"out of bounds [{min_time_s}, {max_time_s}] (seconds, not ms):\n"
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
                        "rawQueryText": "SELECT (hour / $__interval_ms) * $__interval_ms / 1000 AS time FROM hourly WHERE hour >= $__from AND hour < $__to",
                        "queryText": "SELECT (hour / $__interval_ms) * $__interval_ms / 1000 AS time FROM hourly WHERE hour >= $__from AND hour < $__to",
                        "queryType": "time series",
                        "timeColumns": ["time"],
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
    d_12 = copy.deepcopy(base_valid)
    bad_sql12 = "SELECT ts AS time FROM quota_samples WHERE ts >= $__from AND ts < $__to AND account LIKE 'acct%'"
    d_12["panels"][0]["targets"][0]["rawQueryText"] = bad_sql12
    d_12["panels"][0]["targets"][0]["queryText"] = bad_sql12
    planted_cases.append(("forbidden account LIKE", json.dumps(d_12), d_12, set()))

    # 13. (b) Bounded-table detection: JOIN hourly missing $__from
    d_b1 = copy.deepcopy(base_valid)
    d_b1["panels"][0]["targets"][0]["rawQueryText"] = "SELECT ts AS time FROM session_program sp JOIN hourly h ON sp.attr_key = h.attr_key WHERE h.hour < $__to"
    d_b1["panels"][0]["targets"][0]["queryText"] = d_b1["panels"][0]["targets"][0]["rawQueryText"]
    planted_cases.append(("bounded-table JOIN hourly missing $__from", json.dumps(d_b1), d_b1, set()))

    # 14. (b) Bounded-table detection: FROM main.requests missing $__to
    d_b2 = copy.deepcopy(base_valid)
    d_b2["panels"][0]["targets"][0]["rawQueryText"] = "SELECT ts AS time FROM main.requests WHERE ts >= $__from"
    d_b2["panels"][0]["targets"][0]["queryText"] = d_b2["panels"][0]["targets"][0]["rawQueryText"]
    planted_cases.append(("bounded-table FROM schema.requests missing $__to", json.dumps(d_b2), d_b2, set()))

    # 14b. Bounded-table detection: FROM fleet_hourly missing $__to
    d_fh = copy.deepcopy(base_valid)
    bad_sql_fh = "SELECT hour AS time FROM fleet_hourly WHERE hour >= $__from"
    d_fh["panels"][0]["targets"][0]["rawQueryText"] = bad_sql_fh
    d_fh["panels"][0]["targets"][0]["queryText"] = bad_sql_fh
    planted_cases.append(("missing $__to on fleet_hourly", json.dumps(d_fh), d_fh, set()))

    # 14c. Bounded-table detection: FROM remote_hourly missing $__from
    d_rh = copy.deepcopy(base_valid)
    bad_sql_rh = "SELECT hour AS time FROM remote_hourly WHERE hour < $__to"
    d_rh["panels"][0]["targets"][0]["rawQueryText"] = bad_sql_rh
    d_rh["panels"][0]["targets"][0]["queryText"] = bad_sql_rh
    planted_cases.append(("missing $__from on remote_hourly", json.dumps(d_rh), d_rh, set()))

    # 15. (d) Forbidden account != '...'
    d_d1 = copy.deepcopy(base_valid)
    bad_sql_d1 = "SELECT ts AS time FROM quota_samples WHERE ts >= $__from AND ts < $__to AND account != 'acct-a'"
    d_d1["panels"][0]["targets"][0]["rawQueryText"] = bad_sql_d1
    d_d1["panels"][0]["targets"][0]["queryText"] = bad_sql_d1
    planted_cases.append(("forbidden account !=", json.dumps(d_d1), d_d1, set()))

    # 16. (d) Forbidden account <> '...'
    d_d2 = copy.deepcopy(base_valid)
    bad_sql_d2 = "SELECT ts AS time FROM quota_samples WHERE ts >= $__from AND ts < $__to AND account <> 'acct-a'"
    d_d2["panels"][0]["targets"][0]["rawQueryText"] = bad_sql_d2
    d_d2["panels"][0]["targets"][0]["queryText"] = bad_sql_d2
    planted_cases.append(("forbidden account <>", json.dumps(d_d2), d_d2, set()))

    # 17. (e) byName override option missing as column alias in panel targets
    d_e = copy.deepcopy(base_valid)
    d_e["panels"][0]["fieldConfig"] = {
        "overrides": [
            {
                "matcher": {
                    "id": "byName",
                    "options": "missing_alias",
                },
                "properties": [],
            }
        ]
    }
    planted_cases.append(("byName override alias missing in targets", json.dumps(d_e), d_e, set()))

    # 18. (f) Data link URL contains ${__url}
    d_f1 = copy.deepcopy(base_valid)
    d_f1["panels"][0]["fieldConfig"] = {
        "overrides": [
            {
                "matcher": {"id": "byName", "options": "time"},
                "properties": [
                    {
                        "id": "links",
                        "value": [{"title": "Link", "url": "${__url}&var-x=1"}],
                    }
                ],
            }
        ]
    }
    planted_cases.append(("link URL contains ${__url}", json.dumps(d_f1), d_f1, set()))

    # 19. (f) Data link URL does not start with /d/
    d_f2 = copy.deepcopy(base_valid)
    d_f2["panels"][0]["fieldConfig"] = {
        "overrides": [
            {
                "matcher": {"id": "byName", "options": "time"},
                "properties": [
                    {
                        "id": "links",
                        "value": [{"title": "Link", "url": "https://external.example.com"}],
                    }
                ],
            }
        ]
    }
    planted_cases.append(("link URL does not start with /d/", json.dumps(d_f2), d_f2, set()))

    # 20. (a) Time series in ms with empty timeColumns
    d_ts_empty = copy.deepcopy(base_valid)
    d_ts_empty["panels"][0]["targets"][0]["timeColumns"] = []
    d_ts_empty["panels"][0]["targets"][0]["rawQueryText"] = (
        "SELECT hour AS time FROM hourly WHERE hour >= $__from AND hour < $__to"
    )
    d_ts_empty["panels"][0]["targets"][0]["queryText"] = (
        d_ts_empty["panels"][0]["targets"][0]["rawQueryText"]
    )
    planted_cases.append(("time series in ms with empty timeColumns", json.dumps(d_ts_empty), d_ts_empty, set()))

    # 21. (c) Nested row panel with wrong datasource
    d_nested_row = copy.deepcopy(base_valid)
    d_nested_row["panels"] = [
        {
            "type": "row",
            "title": "Row Panel",
            "panels": [
                {
                    "title": "Nested Panel in Row",
                    "datasource": {"type": "frser-sqlite-datasource", "uid": "wrong-ds"},
                    "targets": [
                        {
                            "refId": "A",
                            "datasource": {"type": "frser-sqlite-datasource", "uid": "llm-ledger"},
                            "rawQueryText": "SELECT (hour / $__interval_ms) * $__interval_ms / 1000 AS time FROM hourly WHERE hour >= $__from AND hour < $__to",
                            "queryText": "SELECT (hour / $__interval_ms) * $__interval_ms / 1000 AS time FROM hourly WHERE hour >= $__from AND hour < $__to",
                            "queryType": "time series",
                            "timeColumns": ["time"],
                        }
                    ],
                }
            ],
        }
    ]
    planted_cases.append(("nested row panel with wrong datasource", json.dumps(d_nested_row), d_nested_row, set()))

    # 22. (d) Stat panel with dateTime override and empty reduceOptions.fields
    d_stat_dt = copy.deepcopy(base_valid)
    d_stat_dt["panels"][0]["type"] = "stat"
    d_stat_dt["panels"][0]["targets"][0]["queryType"] = "table"
    d_stat_dt["panels"][0]["targets"][0]["timeColumns"] = []
    d_stat_dt["panels"][0]["targets"][0]["rawQueryText"] = "SELECT ts AS next_refill FROM quota_watch_runs"
    d_stat_dt["panels"][0]["targets"][0]["queryText"] = "SELECT ts AS next_refill FROM quota_watch_runs"
    d_stat_dt["panels"][0]["options"] = {"reduceOptions": {"fields": "", "calcs": ["lastNotNull"]}}
    d_stat_dt["panels"][0]["fieldConfig"] = {
        "overrides": [
            {
                "matcher": {"id": "byName", "options": "next_refill"},
                "properties": [{"id": "unit", "value": "dateTimeAsLocal"}],
            }
        ]
    }
    planted_cases.append(("stat panel with dateTime override and empty reduceOptions.fields", json.dumps(d_stat_dt), d_stat_dt, set()))

    for name, raw_text, data, seen in planted_cases:
        caught_errs = lint_dashboard(dummy_path, raw_text, data, seen)
        if not caught_errs:
            raise AssertionError(f"SELF-TEST FAILURE: planted violation '{name}' was not caught by linter!")

    # Verify non-bounded query mentioning requests does not fail lint (b)
    d_b_ok = copy.deepcopy(base_valid)
    d_b_ok["panels"][0]["targets"][0]["rawQueryText"] = "SELECT 1 AS requests FROM other_table"
    d_b_ok["panels"][0]["targets"][0]["queryText"] = "SELECT 1 AS requests FROM other_table"
    assert len(lint_dashboard(dummy_path, json.dumps(d_b_ok), d_b_ok, set())) == 0, (
        "Query with 'AS requests' falsely flagged as reading bounded table!"
    )

    # Verify ${__from} and ${__to} syntax is accepted in lint (c)
    d_c_ok = copy.deepcopy(base_valid)
    d_c_ok["panels"][0]["targets"][0]["rawQueryText"] = (
        "SELECT (hour / $__interval_ms) * $__interval_ms / 1000 AS time FROM hourly WHERE hour >= ${__from} AND hour < ${__to}"
    )
    d_c_ok["panels"][0]["targets"][0]["queryText"] = d_c_ok["panels"][0]["targets"][0]["rawQueryText"]
    assert len(lint_dashboard(dummy_path, json.dumps(d_c_ok), d_c_ok, set())) == 0, (
        "Query with ${__from}/${__to} failed lint!"
    )

    conn = build_fixture_db()

    # Time series query execution missing 'time' column
    d_missing_time = copy.deepcopy(base_valid)
    bad_sql_time = (
        "SELECT (hour / $__interval_ms) * $__interval_ms / 1000 AS not_time FROM hourly WHERE hour >= $__from AND hour < $__to"
    )
    d_missing_time["panels"][0]["targets"][0]["rawQueryText"] = bad_sql_time
    d_missing_time["panels"][0]["targets"][0]["queryText"] = bad_sql_time
    try:
        execute_dashboard_queries(dummy_path, d_missing_time, conn)
        raise AssertionError("SELF-TEST FAILURE: time series query missing 'time' column was not caught!")
    except AssertionError:
        pass  # Expected

    # (b) Time series query returning ms out of bounds [min_s, max_s] must fail execute
    d_ts_ms = copy.deepcopy(base_valid)
    bad_sql_ms = "SELECT hour AS time FROM hourly WHERE hour >= $__from AND hour < $__to"
    d_ts_ms["panels"][0]["targets"][0]["rawQueryText"] = bad_sql_ms
    d_ts_ms["panels"][0]["targets"][0]["queryText"] = bad_sql_ms
    try:
        execute_dashboard_queries(dummy_path, d_ts_ms, conn)
        raise AssertionError("SELF-TEST FAILURE: time series query returning ms was not caught by executor bounds check!")
    except AssertionError:
        pass  # Expected

    # (c) Nested row panel execution succeeds for valid nested queries
    d_nested_valid = copy.deepcopy(base_valid)
    d_nested_valid["panels"] = [
        {
            "type": "row",
            "title": "Row Panel",
            "panels": [copy.deepcopy(base_valid["panels"][0])],
        }
    ]
    execute_dashboard_queries(dummy_path, d_nested_valid, conn)

    # (a) sqlstring expansion doubles embedded single quotes
    assert substitute_query("${x:sqlstring}", {"x": ["it's", "o'clock"]}) == "'it''s','o''clock'"
    assert substitute_query("${x:sqlstring}", {"x": "it's"}) == "'it''s'"

    # Planted execution failure for (a): unescaped single quote in SQL causes failure
    d_bad_quote = copy.deepcopy(base_valid)
    bad_quote_sql = (
        "SELECT (hour / $__interval_ms) * $__interval_ms / 1000 AS time FROM hourly WHERE hour >= $__from AND hour < $__to AND 'it's' = 'x'"
    )
    d_bad_quote["panels"][0]["targets"][0]["rawQueryText"] = bad_quote_sql
    d_bad_quote["panels"][0]["targets"][0]["queryText"] = bad_quote_sql
    try:
        execute_dashboard_queries(dummy_path, d_bad_quote, conn)
        raise AssertionError("SELF-TEST FAILURE: unescaped single quote was not caught by executor!")
    except RuntimeError:
        pass  # Expected

    # Verified execution with tag containing apostrophe from fixture DB
    d_good_quote = copy.deepcopy(base_valid)
    good_quote_sql = (
        "SELECT (hour / $__interval_ms) * $__interval_ms / 1000 AS time FROM hourly WHERE hour >= $__from AND hour < $__to AND 'team''s-feature' IN (${backend:sqlstring})"
    )
    d_good_quote["panels"][0]["targets"][0]["rawQueryText"] = good_quote_sql
    d_good_quote["panels"][0]["targets"][0]["queryText"] = good_quote_sql
    execute_dashboard_queries(dummy_path, d_good_quote, conn)

    print(f"check_grafana_dashboards: {len(planted_cases) + 3} self-test cases verified successfully")


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
