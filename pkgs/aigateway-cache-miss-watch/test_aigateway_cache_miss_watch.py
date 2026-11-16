"""Tests for aigateway-cache-miss-watch.

Run: python3 pkgs/aigateway-cache-miss-watch/test_aigateway_cache_miss_watch.py
"""

from __future__ import annotations

import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
SCRIPT = Path(os.environ.get("ACM_WATCH_BIN") or (HERE / "aigateway_cache_miss_watch.py"))

NOW_EPOCH = 1_795_000_000


def row(
    row_id: int,
    *,
    age_sec: int = 60,
    model: str = "gemini-3.8-flash",
    ctx: int = 120_000,
    cache_read: int = 0,
    dollars: str = "0.10",
    session_id: str = "ses_child",
    parent_id: str = "ses_parent",
    prefix_hash: str = "aaaa1111bbbb2222",
    first_hash: str = "cccc3333dddd4444",
) -> str:
    return "\t".join([
        str(row_id),
        str(NOW_EPOCH - age_sec),
        model,
        str(ctx),
        str(cache_read),
        dollars,
        session_id,
        parent_id,
        prefix_hash,
        first_hash,
    ])


class WatchHarness:
    def __init__(self, tmp: Path) -> None:
        self.tmp = tmp
        self.flag = tmp / "enabled"
        self.flag.write_text("", encoding="utf-8")
        self.state_dir = tmp / "state"
        self.alerts_log = tmp / "alerts.tsv"
        self.psql_calls = tmp / "psql_calls.log"
        self.schema_out = "1\n"
        self.rows_out = ""
        self.psql_rc = 0
        self._write_stubs()

    def _write_stubs(self) -> None:
        self.alert_cmd = self.tmp / "alert-stub"
        # Records every invocation to alerts.tsv and writes the state file,
        # mirroring opencode-drift-alert's state-file ownership.
        self.alert_cmd.write_text(
            f"#!{sys.executable}\n"
            "import pathlib, sys\n"
            "state, sig, text = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]\n"
            "ttl = int(sys.argv[4]) if len(sys.argv) > 4 else 0\n"
            "state.parent.mkdir(parents=True, exist_ok=True)\n"
            "state.write_text(sig + '\\n1\\n0\\n')\n"
            f"with open({str(self.alerts_log)!r}, 'a') as f:\n"
            "    f.write(f'{state.name}\\t{sig}\\t{ttl}\\t' + text.replace('\\n', ' | ') + '\\n')\n",
            encoding="utf-8",
        )
        self.alert_cmd.chmod(0o755)

        self.psql_cmd = self.tmp / "psql-stub"
        self.psql_cmd.write_text(
            f"#!{sys.executable}\n"
            "import os, sys\n"
            "sql = sys.argv[-1]\n"
            f"with open({str(self.psql_calls)!r}, 'a') as f:\n"
            "    f.write(sql.replace('\\n', ' ') + '\\n')\n"
            "rc = int(os.environ['STUB_PSQL_RC'])\n"
            "if rc != 0:\n"
            "    sys.stderr.write('psql: connection refused\\n')\n"
            "    sys.exit(rc)\n"
            "if 'information_schema.columns' in sql:\n"
            "    sys.stdout.write(os.environ['STUB_SCHEMA_OUT'])\n"
            "else:\n"
            "    sys.stdout.write(os.environ['STUB_ROWS_OUT'])\n",
            encoding="utf-8",
        )
        self.psql_cmd.chmod(0o755)

    def run(self, rows: list[str] | None = None) -> subprocess.CompletedProcess[str]:
        if rows is not None:
            self.rows_out = "\n".join(rows) + ("\n" if rows else "")
        env = os.environ.copy()
        env.update({
            "ACM_FLAG_FILE": str(self.flag),
            "ACM_STATE_DIR": str(self.state_dir),
            "ACM_ALERT_CMD": str(self.alert_cmd),
            "ACM_PSQL_CMD": str(self.psql_cmd),
            "ACM_NOW_EPOCH": str(NOW_EPOCH),
            "STUB_SCHEMA_OUT": self.schema_out,
            "STUB_ROWS_OUT": self.rows_out,
            "STUB_PSQL_RC": str(self.psql_rc),
        })
        cmd = [str(SCRIPT)] if os.access(SCRIPT, os.X_OK) else [sys.executable, str(SCRIPT)]
        return subprocess.run(cmd, env=env, text=True, capture_output=True, check=False)

    def alerts(self) -> list[tuple[str, str, int, str]]:
        if not self.alerts_log.exists():
            return []
        out = []
        for line in self.alerts_log.read_text(encoding="utf-8").splitlines():
            name, sig, ttl, text = line.split("\t", 3)
            out.append((name, sig, int(ttl), text))
        return out


class AigatewayCacheMissWatchTest(unittest.TestCase):
    def test_disabled_flag_skips_without_touching_db(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            h = WatchHarness(Path(td))
            h.flag.unlink()
            res = h.run([row(i) for i in range(1, 15)])
            self.assertEqual(res.returncode, 0, res.stderr)
            self.assertFalse(h.psql_calls.exists())
            self.assertEqual(h.alerts(), [])

    def test_unmigrated_schema_exits_cleanly_without_alert(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            h = WatchHarness(Path(td))
            h.schema_out = "0\n"
            res = h.run([row(i) for i in range(1, 15)])
            self.assertEqual(res.returncode, 0, res.stderr)
            self.assertIn("not migrated", res.stdout)
            self.assertEqual(h.alerts(), [])

    def test_healthy_hits_and_sub_50k_steps_do_not_trip(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            h = WatchHarness(Path(td))
            rows = [row(i, cache_read=0) for i in range(1, 10)]  # 9 misses
            rows.append(row(10, ctx=30_000, cache_read=0))  # <50K ignored
            rows.append(row(11, cache_read=90_000))  # hit resets
            rows.extend(row(i, cache_read=0) for i in range(12, 21))  # 9 more misses
            res = h.run(rows)
            self.assertEqual(res.returncode, 0, res.stderr)
            self.assertEqual(h.alerts(), [])

    def test_sub_50k_steps_neither_advance_nor_reset_streak(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            h = WatchHarness(Path(td))
            rows = [row(i, cache_read=0) for i in range(1, 6)]
            rows.append(row(6, ctx=40_000, cache_read=9000))
            rows.extend(row(i, cache_read=0) for i in range(7, 12))  # 5 + 5 = 10 >=50K misses
            res = h.run(rows)
            self.assertEqual(res.returncode, 0, res.stderr)
            self.assertEqual(len(h.alerts()), 1)

    def test_stable_prefix_streak_diagnoses_vertex_side(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            h = WatchHarness(Path(td))
            res = h.run([row(i, dollars="0.25") for i in range(1, 11)])
            self.assertEqual(res.returncode, 0, res.stderr)
            alerts = h.alerts()
            self.assertEqual(len(alerts), 1)
            _, sig, ttl, text = alerts[0]
            self.assertEqual(sig, "ses_child")
            self.assertEqual(ttl, 900)
            self.assertIn("ses_child", text)
            self.assertIn("subagent of ses_parent", text)
            self.assertIn("prefix stable (aaaa1111bbbb2222", text)
            self.assertIn("Vertex-side", text)
            self.assertIn("$2.50", text)

    def test_changing_prefix_diagnoses_client_side_churn(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            h = WatchHarness(Path(td))
            rows = [
                row(i, parent_id="", session_id="ses_top", prefix_hash=f"pref_{i % 3:011d}")
                for i in range(1, 11)
            ]
            res = h.run(rows)
            self.assertEqual(res.returncode, 0, res.stderr)
            _, _, _, text = h.alerts()[0]
            self.assertIn("top-level / non-opencode", text)
            self.assertIn("client-side prefix churn", text)

    def test_falls_back_to_first_content_hash_when_no_session_header(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            h = WatchHarness(Path(td))
            unk = [row(i, session_id="", parent_id="", first_hash="") for i in range(1, 15)]
            goose = [row(100 + i, session_id="", parent_id="", first_hash="goose_open_hash1") for i in range(1, 11)]
            res = h.run(unk + goose)
            self.assertEqual(res.returncode, 0, res.stderr)
            alerts = h.alerts()
            self.assertEqual(len(alerts), 1)
            self.assertIn("first_content=goose_open_hash1", alerts[0][3])

    def test_stopped_session_is_quiet_while_growing_or_new_episode_calls_drift_alert(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            h = WatchHarness(Path(td))
            # Stopped at 11 steps: second tick sees same max_id -> does NOT call alert_cmd again.
            rows = [row(i) for i in range(1, 12)]
            h.run(rows)
            h.run(rows)
            self.assertEqual(len(h.alerts()), 1)

            # Still burning to 15 steps: calls alert_cmd with stable sig + TTL=900 so
            # opencode-drift-alert's exponential backoff + escalation govern repeats.
            rows15 = [row(i) for i in range(1, 16)]
            h.run(rows15)
            self.assertEqual(len(h.alerts()), 2)
            self.assertEqual(h.alerts()[1][1], "ses_child")
            self.assertEqual(h.alerts()[1][2], 900)

            # Recovers on a hit (clears state), then gets stuck again -> fresh alert.
            h.run(rows15 + [row(16, cache_read=80_000)])
            self.assertEqual(list(h.state_dir.glob("episode-*")), [])
            h.run(rows15 + [row(16, cache_read=80_000)] + [row(i) for i in range(17, 27)])
            self.assertEqual(len(h.alerts()), 3)

    def test_partial_deploy_with_all_null_keys_alerts(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            h = WatchHarness(Path(td))
            rows = [row(i, session_id="", parent_id="", prefix_hash="", first_hash="") for i in range(1, 22)]
            res = h.run(rows)
            self.assertEqual(res.returncode, 0, res.stderr)
            self.assertEqual(len(h.alerts()), 1)
            self.assertEqual(h.alerts()[0][1], "partial-deploy")

    def test_ignores_streaks_whose_latest_step_is_stale(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            h = WatchHarness(Path(td))
            rows = [row(i, age_sec=3600) for i in range(1, 12)]
            res = h.run(rows)
            self.assertEqual(res.returncode, 0, res.stderr)
            self.assertEqual(h.alerts(), [])

    def test_db_failure_alerts_only_after_two_consecutive_failures(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            h = WatchHarness(Path(td))
            h.psql_rc = 2
            r1 = h.run([])
            self.assertEqual(r1.returncode, 0)
            self.assertEqual(h.alerts(), [])
            r2 = h.run([])
            self.assertEqual(r2.returncode, 0)
            self.assertEqual(len(h.alerts()), 1)
            self.assertEqual(h.alerts()[0][1], "psql-failed")
            self.assertEqual(h.alerts()[0][2], 900)


if __name__ == "__main__":
    unittest.main(verbosity=2)
