#!/usr/bin/env python3
"""Unit tests for the pure parts of goose-upgrade-probe (bead workstation-6w7i.27.1).

The checks themselves drive real processes and are exercised by the self-test
run (candidate == deployed binary); these pin the parts whose failure would be a
FALSE GREEN: skip counting, result aggregation, isolation guards, config stripping.
"""
import importlib.util
import json
import sqlite3
import pathlib
import sys
import tempfile
import unittest

HERE = pathlib.Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("probe", HERE / "goose_upgrade_probe.py")
probe = importlib.util.module_from_spec(spec)
sys.modules["probe"] = probe
spec.loader.exec_module(probe)


CONFIG = """\
GOOSE_MODE: smart_approve
extensions:
  developer:
    enabled: true
    type: platform
    name: developer
  todo:
    enabled: true
    type: builtin
    name: todo
  slack:
    enabled: true
    type: stdio
    cmd: slack-mcp
  remote:
    enabled: true
    type: streamable_http
    uri: http://example
  old:
    enabled: false
    type: sse
    uri: http://example
plugins:
  /x/.agents/plugins/lane-guard:
    enabled: true
GOOSE_SUBAGENT_ROLES_DIR: /r
"""


class StripConfig(unittest.TestCase):
    def test_keeps_only_platform_and_builtin_extensions(self):
        out = probe.yaml_load(probe.strip_config(CONFIG))
        self.assertEqual(sorted(out["extensions"]), ["developer", "todo"])

    def test_drops_plugins(self):
        out = probe.yaml_load(probe.strip_config(CONFIG))
        self.assertNotIn("plugins", out)

    def test_keeps_other_keys(self):
        out = probe.yaml_load(probe.strip_config(CONFIG))
        self.assertEqual(out["GOOSE_SUBAGENT_ROLES_DIR"], "/r")

    def test_extension_without_type_is_dropped(self):
        out = probe.yaml_load(probe.strip_config("extensions:\n  x:\n    enabled: true\n"))
        self.assertEqual(out["extensions"], {})

    def test_no_extensions_key(self):
        out = probe.yaml_load(probe.strip_config("GOOSE_MODE: auto\n"))
        self.assertEqual(out, {"GOOSE_MODE": "auto"})


class CountSkips(unittest.TestCase):
    def test_counts_skip_lines(self):
        text = (
            "running 3 tests\n"
            "skipping stub goose: HONK_GOOSE_BIN unset\n"
            "test a ... ok\n"
            "   skipping activation test: HONK_GOOSE_BIN unset or not found\n"
            "\x1b[33mskipping tail: honkd binary not found (set HONKD_BIN)\x1b[0m\n"
        )
        self.assertEqual(probe.count_skips(text), 3)

    def test_word_inside_a_line_is_not_a_skip(self):
        self.assertEqual(probe.count_skips("test not_skipping_here ... ok\n"), 0)

    def test_zero(self):
        self.assertEqual(probe.count_skips(""), 0)

    def test_skip_sharing_a_line_with_libtest(self):
        # --nocapture: `test x ... ` and the test's eprintln! land on one line.
        self.assertEqual(probe.count_skips("test a::b ... skipping stub goose: unset\nok\n"), 1)


class Rerun(unittest.TestCase):
    def test_parses_and_dedupes(self):
        out = ("error: test failed, to rerun pass `-p honkd --test goose_restart`\n"
               "error: test failed, to rerun pass `-p honk --lib`\n"
               "error: test failed, to rerun pass `-p honkd --test goose_restart`\n")
        self.assertEqual(probe.rerun_targets(out), [["-p", "honkd", "--test", "goose_restart"], ["-p", "honk", "--lib"]])

    def test_none(self):
        self.assertEqual(probe.rerun_targets("test result: ok."), [])

    def test_no_fail_fast_summary(self):
        out = "error: 2 targets failed:\n    `-p honkd --test prompt_e2e`\n    `-p honk --lib`\n"
        self.assertEqual(probe.rerun_targets(out), [["-p", "honkd", "--test", "prompt_e2e"], ["-p", "honk", "--lib"]])


class ExtensionData(unittest.TestCase):
    def test_strips_stdio_keeps_bundled(self):
        raw = json.dumps({"enabled_extensions.v0": {"extensions": [
            {"type": "platform", "name": "analyze"},
            {"type": "builtin", "name": "developer"},
            {"type": "stdio", "name": "swarm", "cmd": "honk"},
            {"type": "streamable_http", "name": "x"},
        ]}, "other": 1})
        out = json.loads(probe.neutralize_extension_data(raw))
        self.assertEqual([e["name"] for e in out["enabled_extensions.v0"]["extensions"]], ["analyze", "developer"])
        self.assertEqual(out["other"], 1)

    def test_none_and_empty(self):
        self.assertIsNone(probe.neutralize_extension_data(None))
        self.assertEqual(probe.neutralize_extension_data(""), "")


class RecipeJson(unittest.TestCase):
    def test_strips_stdio_from_stored_recipe(self):
        raw = json.dumps({"title": "t", "extensions": [
            {"type": "stdio", "name": "slack", "cmd": "slack-mcp-server"},
            {"type": "builtin", "name": "developer"}]})
        out = json.loads(probe.neutralize_recipe_json(raw))
        self.assertEqual(out["extensions"], [{"type": "builtin", "name": "developer"}])
        self.assertEqual(out["title"], "t")

    def test_none_garbage_and_no_extensions(self):
        self.assertIsNone(probe.neutralize_recipe_json(None))
        self.assertEqual(probe.neutralize_recipe_json("not json"), "not json")
        self.assertEqual(json.loads(probe.neutralize_recipe_json('{"title": "x"}')), {"title": "x"})


class Settled(unittest.TestCase):
    def test_assistant_text_is_settled(self):
        self.assertTrue(probe.is_settled("assistant", json.dumps([{"type": "text", "text": "hi"}])))

    def test_tool_request_is_not(self):
        self.assertFalse(probe.is_settled("assistant", json.dumps([{"type": "toolRequest"}])))

    def test_user_last_is_not(self):
        self.assertFalse(probe.is_settled("user", json.dumps([{"type": "text"}])))

    def test_garbage_is_not(self):
        self.assertFalse(probe.is_settled("assistant", "not json"))
        self.assertFalse(probe.is_settled("assistant", "[]"))


class Shapes(unittest.TestCase):
    def _db(self, ddl):
        c = sqlite3.connect(":memory:")
        c.executescript(ddl)
        return c

    def test_alter_appended_equals_created(self):
        a = self._db("create table s (id integer primary key, a text); alter table s add column b text;")
        b = self._db("create table s (id integer primary key, b text, a text);")
        self.assertEqual(probe.diff_shapes(probe.schema_shape(a), probe.schema_shape(b)), [])

    def test_missing_column_reported(self):
        a = self._db("create table s (id integer primary key);")
        b = self._db("create table s (id integer primary key, b text);")
        d = probe.diff_shapes(probe.schema_shape(a), probe.schema_shape(b))
        self.assertEqual(len(d), 1)
        self.assertIn("only in fresh", d[0])

    def test_missing_table_and_index(self):
        a = self._db("create table s (id integer); create index si on s(id);")
        b = self._db("create table s (id integer); create table t (x);")
        d = probe.diff_shapes(probe.schema_shape(a), probe.schema_shape(b))
        self.assertTrue(any("table t" in x for x in d))
        self.assertTrue(any("index si" in x for x in d))


class Results(unittest.TestCase):
    def test_all_pass_is_ok(self):
        r = probe.Results(["a", "b"])
        r.passed("a")
        r.passed("b")
        self.assertTrue(r.ok())

    def test_skip_is_not_ok(self):
        r = probe.Results(["a"])
        r.skipped("a", "no binary")
        self.assertFalse(r.ok())
        self.assertIn("FAIL a -- SKIPPED: no binary", r.lines())

    def test_missing_check_is_fail(self):
        r = probe.Results(["a", "b"])
        r.passed("a")
        self.assertFalse(r.ok())
        self.assertIn("FAIL b -- did not run", r.lines())

    def test_fail_then_pass_stays_fail(self):
        r = probe.Results(["a"])
        r.failed("a", "x")
        r.passed("a")
        self.assertFalse(r.ok())

    def test_unknown_check_rejected(self):
        r = probe.Results(["a"])
        with self.assertRaises(KeyError):
            r.passed("zzz")

    def test_lines_in_declared_order(self):
        r = probe.Results(["a", "b"])
        r.passed("b")
        r.failed("a", "boom")
        self.assertEqual(r.lines(), ["FAIL a -- boom", "PASS b"])


class Ports(unittest.TestCase):
    def test_production_ports_refused(self):
        for p in (4080, 4180, 4181, 4280, 4700, 4731, 4096, 4099, 8789, 38999, 38910):
            with self.assertRaises(probe.ProbeError):
                probe.guard_port(p)

    def test_free_port_never_refused(self):
        for _ in range(20):
            p = probe.free_port()
            self.assertNotIn(p, probe.REFUSED_PORTS)
            probe.guard_port(p)


class Isolation(unittest.TestCase):
    def test_path_root_required(self):
        with self.assertRaises(probe.ProbeError):
            probe.assert_isolated_env({"HOME": "/home/dev"}, pathlib.Path("/var/tmp/r"))

    def test_path_root_must_be_under_work_root(self):
        with self.assertRaises(probe.ProbeError):
            probe.assert_isolated_env({"GOOSE_PATH_ROOT": "/home/dev"}, pathlib.Path("/var/tmp/r"))

    def test_relative_path_root_refused(self):
        with self.assertRaises(probe.ProbeError):
            probe.assert_isolated_env({"GOOSE_PATH_ROOT": "r/goose"}, pathlib.Path("r"))

    def test_ok(self):
        probe.assert_isolated_env({"GOOSE_PATH_ROOT": "/var/tmp/r/goose"}, pathlib.Path("/var/tmp/r"))

    def test_db_copy_must_not_be_production(self):
        with self.assertRaises(probe.ProbeError):
            probe.guard_not_production(probe.PROD_SESSIONS_DB)
        probe.guard_not_production(pathlib.Path("/var/tmp/r/goose/data/sessions/sessions.db"))


class EnvFile(unittest.TestCase):
    def test_round_trip_and_mode(self):
        with tempfile.TemporaryDirectory() as d:
            p = pathlib.Path(d) / "env"
            probe.write_env_file(p, {"A": "1", "B": "two words", "C": 'q"uote'})
            self.assertEqual(p.stat().st_mode & 0o777, 0o600)
            text = p.read_text()
            self.assertIn('A="1"', text)
            self.assertIn('B="two words"', text)
            self.assertIn('C="q\\"uote"', text)

    def test_newline_rejected(self):
        with tempfile.TemporaryDirectory() as d:
            with self.assertRaises(probe.ProbeError):
                probe.write_env_file(pathlib.Path(d) / "env", {"A": "x\ny"})


class ProbeRecipe(unittest.TestCase):
    def test_instructions_replaced_rest_kept(self):
        src = "version: 1.0.0\ntitle: t\ninstructions: |\n  be a coordinator\nextensions:\n- type: builtin\n  name: developer\n"
        out = probe.yaml_load(probe.probe_recipe(src, "SWPROBEOK"))
        self.assertNotIn("be a coordinator", out["instructions"])
        self.assertIn("SWPROBEOK", out["instructions"])
        self.assertEqual(out["extensions"], [{"type": "builtin", "name": "developer"}])
        self.assertEqual(out["title"], "t")


if __name__ == "__main__":
    unittest.main()
