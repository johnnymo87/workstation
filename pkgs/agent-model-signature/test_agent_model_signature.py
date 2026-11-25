#!/usr/bin/env python3
"""Unit tests for agent_model_signature."""

from __future__ import annotations

import io
import json
import sqlite3
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import agent_model_signature as ams


class TestClassifyModelFamily(unittest.TestCase):
    def test_claude_variants(self) -> None:
        for raw in (
            "claude-opus-5-5",
            "claude-fable-5-2",
            "claude-haiku-5-5",
            "google-vertex-anthropic/claude-opus-5-5@default",
            "anthropic.claude-3-7-sonnet",
            "Claude",
        ):
            self.assertEqual(ams.classify_model_family(raw), "Claude", raw)

    def test_gemini_variants(self) -> None:
        for raw in (
            "gemini-4-neon",
            "gemini-3.8-flash",
            "google-vertex/gemini-4-neon@default",
            "GEMINI-4-ARGON",
            "Gemini",
        ):
            self.assertEqual(ams.classify_model_family(raw), "Gemini", raw)

    def test_gpt_variants(self) -> None:
        for raw in (
            "gpt-6-astra",
            "codex_lb/gpt-6.1-sol",
            "openai/gpt-5.6-terra",
            "o3-mini",
            "GPT",
        ):
            self.assertEqual(ams.classify_model_family(raw), "GPT", raw)

    def test_unknown_and_empty(self) -> None:
        for raw in (None, "", "   ", "llama-3.3-70b", "unknown-model"):
            self.assertIsNone(ams.classify_model_family(raw), repr(raw))


class TestRewriteSignature(unittest.TestCase):
    def test_rewrites_double_dash_claude_to_gemini(self) -> None:
        self.assertEqual(
            ams.rewrite_signature("Done.\n\n--Claude", "Gemini"),
            "Done.\n\n--Gemini",
        )

    def test_preserves_em_dash_and_spacing_and_trailing_newline(self) -> None:
        self.assertEqual(
            ams.rewrite_signature("Done.\n\n— Claude\n", "Gemini"),
            "Done.\n\n— Gemini\n",
        )

    def test_preserves_en_dash(self) -> None:
        self.assertEqual(
            ams.rewrite_signature("Done.\n– Claude", "GPT"),
            "Done.\n– GPT",
        )

    def test_idempotent(self) -> None:
        once = ams.rewrite_signature("Done.\n\n--Claude\n", "Gemini")
        twice = ams.rewrite_signature(once, "Gemini")
        self.assertEqual(once, "Done.\n\n--Gemini\n")
        self.assertEqual(twice, once)

    def test_preserves_trailing_blank_lines(self) -> None:
        self.assertEqual(
            ams.rewrite_signature("Done.\n\n--Claude\n\n", "Gemini"),
            "Done.\n\n--Gemini\n\n",
        )

    def test_leaves_unsigned_text_verbatim(self) -> None:
        msg = "Jonathan's dictated message with no signature."
        self.assertEqual(ams.rewrite_signature(msg, "Gemini"), msg)

    def test_ignores_signature_in_middle_of_message(self) -> None:
        msg = "Quoted example:\n--Claude\nThat was the old format."
        self.assertEqual(ams.rewrite_signature(msg, "Gemini"), msg)

    def test_ignores_prose_starting_with_dash_model(self) -> None:
        msg = "Summary:\n-- Claude suggested reverting the commit."
        self.assertEqual(ams.rewrite_signature(msg, "Gemini"), msg)

    def test_fail_open_on_none_family(self) -> None:
        msg = "Done.\n\n--Claude"
        self.assertEqual(ams.rewrite_signature(msg, None), msg)


class TestSqliteLookups(unittest.TestCase):
    def test_goose_lookup_tracks_mid_life_switch(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            db = Path(td) / "sessions.db"
            conn = sqlite3.connect(db)
            conn.execute("PRAGMA journal_mode=WAL")
            conn.execute("CREATE TABLE sessions (id TEXT PRIMARY KEY, model_config_json TEXT)")
            conn.execute(
                "INSERT INTO sessions VALUES (?, ?)",
                ("20261125_114", json.dumps({"model_name": "claude-opus-5-5"})),
            )
            conn.commit()

            env = {"AGENT_SESSION_ID": "20261125_114", "GOOSE_SESSIONS_DB": str(db)}
            self.assertEqual(ams.resolve_family(env=env), "Claude")

            # Simulate modelswitch flipping the session to Gemini 4 Neon in WAL mode.
            conn.execute(
                "UPDATE sessions SET model_config_json = ? WHERE id = ?",
                (json.dumps({"model_name": "gemini-4-neon"}), "20261125_114"),
            )
            conn.commit()
            self.assertEqual(ams.resolve_family(env=env), "Gemini")
            conn.close()

    def test_opencode_lookup_prefers_latest_assistant_message(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            db = Path(td) / "opencode.db"
            conn = sqlite3.connect(db)
            conn.execute("CREATE TABLE session (id TEXT PRIMARY KEY, model TEXT)")
            conn.execute(
                "CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, data TEXT)"
            )
            conn.execute(
                "INSERT INTO session VALUES (?, ?)",
                ("ses_1", json.dumps({"id": "claude-opus-5-5@default"})),
            )
            conn.execute(
                "INSERT INTO message VALUES (?, ?, ?, ?)",
                ("m1", "ses_1", 100, json.dumps({"role": "assistant", "modelID": "claude-opus-5-5@default"})),
            )
            conn.execute(
                "INSERT INTO message VALUES (?, ?, ?, ?)",
                ("m2", "ses_1", 200, json.dumps({"role": "assistant", "modelID": "gemini-4-neon@default"})),
            )
            conn.commit()
            conn.close()

            env = {"OPENCODE_SESSION_ID": "ses_1", "OPENCODE_DB": str(db)}
            self.assertEqual(ams.resolve_family(env=env), "Gemini")

    def test_opencode_fallback_to_session_table(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            db = Path(td) / "opencode.db"
            conn = sqlite3.connect(db)
            conn.execute("CREATE TABLE session (id TEXT PRIMARY KEY, model TEXT)")
            conn.execute(
                "CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, data TEXT)"
            )
            conn.execute(
                "INSERT INTO session VALUES (?, ?)",
                ("ses_2", json.dumps({"id": "claude-opus-5-5@default"})),
            )
            conn.commit()
            conn.close()

            env = {"OPENCODE_SESSION_ID": "ses_2", "OPENCODE_DB": str(db)}
            self.assertEqual(ams.resolve_family(env=env), "Claude")

    def test_goose_lookup_honours_goose_path_root_and_xdg_data_home(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td) / "private-root"
            db = root / "data" / "sessions" / "sessions.db"
            db.parent.mkdir(parents=True)
            conn = sqlite3.connect(db)
            conn.execute("CREATE TABLE sessions (id TEXT PRIMARY KEY, model_config_json TEXT)")
            conn.execute(
                "INSERT INTO sessions VALUES (?, ?)",
                ("20261125_1", json.dumps({"model_name": "gemini-4-neon"})),
            )
            conn.commit()
            conn.close()

            self.assertEqual(
                ams.resolve_family(env={"AGENT_SESSION_ID": "20261125_1", "GOOSE_PATH_ROOT": str(root)}),
                "Gemini",
            )

            xdg = Path(td) / "xdg-data"
            xdb = xdg / "goose" / "sessions" / "sessions.db"
            xdb.parent.mkdir(parents=True)
            conn = sqlite3.connect(xdb)
            conn.execute("CREATE TABLE sessions (id TEXT PRIMARY KEY, model_config_json TEXT)")
            conn.execute(
                "INSERT INTO sessions VALUES (?, ?)",
                ("20261125_1", json.dumps({"model_name": "claude-opus-5-5"})),
            )
            conn.commit()
            conn.close()

            self.assertEqual(
                ams.resolve_family(env={"AGENT_SESSION_ID": "20261125_1", "XDG_DATA_HOME": str(xdg)}),
                "Claude",
            )

    def test_missing_env_or_db_fails_open(self) -> None:
        self.assertIsNone(ams.resolve_family(env={}))
        self.assertIsNone(
            ams.resolve_family(
                env={"AGENT_SESSION_ID": "nope", "GOOSE_SESSIONS_DB": "/nonexistent/sessions.db"}
            )
        )


class TestCLI(unittest.TestCase):
    def test_cli_rewrite_with_explicit_family(self) -> None:
        out = io.StringIO()
        with mock.patch("sys.stdin", io.StringIO("Hi.\n\n--Claude\n")), mock.patch("sys.stdout", out):
            rc = ams.main(["rewrite", "--family", "gemini-4-neon"])
        self.assertEqual(rc, 0)
        self.assertEqual(out.getvalue(), "Hi.\n\n--Gemini\n")

    def test_cli_family_exits_1_when_unknown(self) -> None:
        out = io.StringIO()
        with mock.patch.dict("os.environ", {}, clear=True), mock.patch("sys.stdout", out):
            rc = ams.main(["family"])
        self.assertEqual(rc, 1)
        self.assertEqual(out.getvalue(), "")


if __name__ == "__main__":
    unittest.main(verbosity=2)
