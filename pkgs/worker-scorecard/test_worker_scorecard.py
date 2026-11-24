"""Tests for worker-scorecard. Run: python3 pkgs/worker-scorecard/test_worker_scorecard.py

Hermetic: sqlite fixtures in a temp dir, fake subprocess runner for
session-tags / psql, fake GitHub. Nothing here reads a real store.
"""

from __future__ import annotations

import datetime as dt
import io
import json
import os
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parent))

import worker_scorecard as ws  # noqa: E402

BRIEF = "You're working for Jonathan, sent by the goose program's stall-watch coordinator. Do X."
T0 = 1_794_000_000_000  # 2026-11-06-ish, ms


# --------------------------------------------------------------------------
# fixtures
# --------------------------------------------------------------------------


def make_oc_db(path: str) -> sqlite3.Connection:
    con = sqlite3.connect(path)
    con.executescript("""
        CREATE TABLE session (id TEXT PRIMARY KEY, parent_id TEXT, title TEXT, directory TEXT, time_created INTEGER);
        CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, data TEXT);
        CREATE TABLE part (id TEXT PRIMARY KEY, message_id TEXT, session_id TEXT, time_created INTEGER, data TEXT);
    """)
    return con


class OcBuilder:
    def __init__(self, con):
        self.con = con
        self.n = 0

    def session(self, sid, parent=None, t=T0, title="t"):
        self.con.execute("INSERT INTO session VALUES (?,?,?,?,?)", (sid, parent, title, "/w", t))

    def user(self, sid, t, *parts):
        self.n += 1
        mid = f"msg_{self.n:05d}"
        self.con.execute("INSERT INTO message VALUES (?,?,?,?)", (mid, sid, t, json.dumps({"role": "user"})))
        for i, p in enumerate(parts):
            self.con.execute("INSERT INTO part VALUES (?,?,?,?,?)", (f"prt_{self.n:05d}_{i}", mid, sid, t, json.dumps(p)))

    def asst(self, sid, t, model, inp=0, out=0, reas=0, cr=0, cw=0):
        self.n += 1
        d = {"role": "assistant", "modelID": model, "time": {"created": t},
             "tokens": {"input": inp, "output": out, "reasoning": reas, "cache": {"read": cr, "write": cw}}}
        self.con.execute("INSERT INTO message VALUES (?,?,?,?)", (f"msg_{self.n:05d}", sid, t, json.dumps(d)))


def make_goose_db(path: str) -> sqlite3.Connection:
    con = sqlite3.connect(path)
    con.executescript("""
        CREATE TABLE sessions (id TEXT PRIMARY KEY, name TEXT, working_dir TEXT, created_at TIMESTAMP, parent_session_id TEXT,
                               model_config_json TEXT);
        CREATE TABLE messages (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, role TEXT, content_json TEXT,
                               created_timestamp INTEGER, metadata_json TEXT);
        CREATE TABLE usage_ledger (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, created_timestamp INTEGER, model TEXT,
                                   input_tokens INTEGER, output_tokens INTEGER, cache_read_tokens INTEGER, cache_write_tokens INTEGER);
    """)
    return con


def text(t, **kw):
    return {"type": "text", "text": t, **kw}


class FakeRun:
    """Stands in for subprocess.run: session-tags and psql."""

    def __init__(self, tagged=(), ledger_lines=(), psql_rc=0):
        self.tagged = list(tagged)
        self.ledger_lines = list(ledger_lines)
        self.psql_rc = psql_rc
        self.calls = []

    def __call__(self, args, **kw):
        self.calls.append(args)
        if args[0] == "session-tags":
            return SimpleNamespace(returncode=0, stdout="\n".join(self.tagged) + "\n", stderr="")
        if "psql" in args:
            return SimpleNamespace(returncode=self.psql_rc, stdout="\n".join(self.ledger_lines) + "\n", stderr="boom")
        raise AssertionError(f"unexpected command {args}")


class FakeGitHub(ws.GitHub):
    def __init__(self, prs=None, heads=None, searches=None):
        self.prs = prs or {}
        self.heads = heads or {}
        self.searches = searches or []
        self.queries = []

    def pr(self, repo, number):
        return self.prs.get((repo, number))

    def prs_for_head(self, repo, branch):
        return self.heads.get((repo, branch), [])

    def search_heads(self, branch):
        return []

    def search_prs(self, query):
        self.queries.append(query)
        return self.searches


def pr_node(n, created, merged=None, state="MERGED", title="Fix it", head="b", commits=(), reviews=(), author="me"):
    return {"number": n, "title": title, "state": state, "createdAt": created, "mergedAt": merged,
            "headRefName": head, "author": {"login": author},
            "commits": {"nodes": [{"commit": c} for c in commits]},
            "reviews": {"nodes": list(reviews)}}


def iso(ms):
    return dt.datetime.fromtimestamp(ms / 1000, dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# --------------------------------------------------------------------------
# brief parsing
# --------------------------------------------------------------------------


class TestBrief(unittest.TestCase):
    def test_arm_exact_line(self):
        self.assertEqual(ws.parse_arm("blah\nStage-1 arm: goose\nmore"), "goose")
        self.assertEqual(ws.parse_arm("Stage-1 arm: opencode"), "opencode")

    def test_arm_tolerant_forms(self):
        self.assertEqual(ws.parse_arm("**Arm:** GOOSE"), "goose")
        self.assertEqual(ws.parse_arm("arm=`opencode`"), "opencode")

    def test_no_arm(self):
        self.assertIsNone(ws.parse_arm("the A/B coin from 6w7i.1 and its arm"))
        self.assertIsNone(ws.parse_arm(""))

    def test_coordinator_brief_is_worker(self):
        self.assertTrue(ws.is_worker_brief(BRIEF))
        self.assertTrue(ws.is_worker_brief("You're working for Jonathan, sent by the lgtm program's stall-watch coordinator."))

    def test_mentioning_coordinators_is_not_a_worker(self):
        # A lead's brief for its own sub-worker talks about the coordinators.
        self.assertFalse(ws.is_worker_brief("goose-serve restarts kill about 22 stall-watch coordinators."))
        self.assertFalse(ws.is_worker_brief("please read this blog post"))

    def test_arm_marker_alone_makes_a_worker(self):
        self.assertTrue(ws.is_worker_brief("Do X.\nStage-1 arm: goose"))


# --------------------------------------------------------------------------
# step-ins
# --------------------------------------------------------------------------


class TestStepIns(unittest.TestCase):
    def test_classify(self):
        self.assertEqual(ws.classify_user_text('<swarm_message v="1" kind="chat" from="stall-watch" to="x">hi'), "swarm:stall-watch")
        self.assertEqual(ws.classify_user_text('<swarm_message v="1" from="lgtm-shepherd">'), "swarm:lgtm-shepherd")
        self.assertEqual(ws.classify_user_text("<beads-context>\n..."), "hook")
        self.assertEqual(ws.classify_user_text("<turn-context>..."), "hook")
        self.assertEqual(ws.classify_user_text("   "), "hook")
        self.assertEqual(ws.classify_user_text("merged please deploy"), "human")

    def test_count(self):
        msgs = [
            {"text": BRIEF},
            {"text": "<beads-context>", "synthetic": True},
            {"text": '<swarm_message v="1" from="stall-watch">nudge'},
            {"text": '<swarm_message v="1" from="lgtm-shepherd">merged'},
            {"text": "green light"},
            {"text": "", "compaction": True},
            {"text": "Resume for Jonathan: bead X ..."},  # agent-written resume prompt
            {"text": "<beads-context>", "synthetic": True},
            {"text": "please deploy"},
        ]
        self.assertEqual(ws.count_step_ins(msgs), (2, 1))

    def test_resume_skip_is_only_the_message_right_after_compaction(self):
        # The resume prompt is queued with the compaction, so it is the next
        # non-hook message. Once anything else arrives, a human text is human.
        msgs = [{"text": BRIEF}, {"text": "", "compaction": True},
                {"text": '<swarm_message from="stall-watch">'}, {"text": "hello"}]
        self.assertEqual(ws.count_step_ins(msgs), (1, 1))

    def test_brief_not_counted(self):
        self.assertEqual(ws.count_step_ins([{"text": "please do X"}]), (0, 0))


# --------------------------------------------------------------------------
# pricing
# --------------------------------------------------------------------------


class TestPricing(unittest.TestCase):
    def test_claude_card(self):
        t = ws.Tokens(input=1_000_000, output=1_000_000, cache_read=1_000_000, cache_write=1_000_000)
        self.assertAlmostEqual(ws.price(t, ws.CLAUDE_CARD), 4 + 20 + 0.2 + 5)

    def test_claude_cost_warns_for_non_opus(self):
        w = []
        calls = [ws.Call("s", 0, "claude-opus-5-5@default", ws.Tokens(output=1_000_000, calls=1)),
                 ws.Call("s", 0, "claude-fable-5-2@default", ws.Tokens(output=1_000_000, calls=1))]
        self.assertAlmostEqual(ws.claude_cost(calls, w), 40.0)
        self.assertEqual(len(w), 1)
        self.assertIn("claude-fable-5-2@default", w[0])

    def test_gemini_ledger_only(self):
        w = []
        led = [{"client_session_id": "a", "ts_ms": 100, "model": "gemini-3.8-flash", "dollars": 0.5},
               {"client_session_id": "a", "ts_ms": 200, "model": "gemini-3.8-flash", "dollars": 0.25}]
        calls = [ws.Call("a", 150, "gemini-3.8-flash", ws.Tokens(input=10**6, calls=1))]
        self.assertEqual(ws.gemini_cost(calls, led, w), (0.75, 2, 0))
        self.assertEqual(w, [])

    def test_gemini_card_only(self):
        calls = [ws.Call("a", 1, "gemini-3.8-flash", ws.Tokens(input=10**6, output=10**6, cache_read=10**6, calls=1))]
        usd, nl, nc = ws.gemini_cost(calls, [], [])
        self.assertAlmostEqual(usd, 0.75 + 3.75 + 0.075)
        self.assertEqual((nl, nc), (0, 1))

    def test_gemini_split_at_first_ledger_row(self):
        # Headers started mid-session: calls before the first ledger row are carded.
        led = [{"client_session_id": "a", "ts_ms": 10_000, "model": "gemini-3.8-flash", "dollars": 1.0}]
        calls = [ws.Call("a", 1_000, "gemini-3.8-flash", ws.Tokens(input=10**6, calls=1)),
                 ws.Call("a", 10_500, "gemini-3.8-flash", ws.Tokens(input=10**6, calls=1)),
                 ws.Call("b", 20_000, "gemini-3.8-flash", ws.Tokens(input=10**6, calls=1))]
        usd, nl, nc = ws.gemini_cost(calls, led, [])
        self.assertAlmostEqual(usd, 1.0 + 0.75 + 0.75)
        self.assertEqual((nl, nc), (1, 2))

    def test_gemini_null_dollar_row_priced_from_card(self):
        # The gateway ledgers tokens with NULL dollars for models its own price
        # table lacks (gemini-4-neon on day one). Price those rows from the card.
        w = []
        led = [{"client_session_id": "a", "ts_ms": 1, "model": "gemini-4-neon", "dollars": None,
                "tokens": ws.Tokens(input=1_000_000, output=100_000, cache_read=2_000_000), "region": "global"},
               {"client_session_id": "a", "ts_ms": 2, "model": "gemini-4-neon", "dollars": None,
                "tokens": ws.Tokens(input=1_000_000), "region": "us-east5"}]
        usd, nl, nc = ws.gemini_cost([], led, w)
        self.assertAlmostEqual(usd, (3.0 + 1.5 + 0.3) + 3.0 * 1.1)
        self.assertEqual((nl, nc, w), (2, 0, []))

    def test_gemini_unpriced_warns(self):
        w = []
        led = [{"client_session_id": "a", "ts_ms": 1, "model": "gemini-3.8-flash", "dollars": None}]
        calls = [ws.Call("b", 1, "gemini-4-carbon", ws.Tokens(input=1, calls=1))]
        self.assertEqual(ws.gemini_cost(calls, led, w), (0.0, 0, 0))
        self.assertEqual(len(w), 2)


# --------------------------------------------------------------------------
# attribution (port of lgtm's prAttribution.ts)
# --------------------------------------------------------------------------


def cand(root, t, **kw):
    return {"repo": "o/r", "prNumber": 1, "rootSessionId": root, "originSessionId": root, "parentage": "main", "createdAt": t, **kw}


class TestAttribution(unittest.TestCase):
    def test_latest_before_created_wins(self):
        pick, why = ws.select_attribution([cand("A", 1000), cand("B", 5000), cand("C", 20_000)], iso(10_000))
        self.assertEqual(pick["rootSessionId"], "B")
        self.assertIsNone(why)

    def test_skew_pass_only_without_an_earlier_part(self):
        pick, _ = ws.select_attribution([cand("A", 12_000)], iso(10_000))
        self.assertEqual(pick["rootSessionId"], "A")
        pick, why = ws.select_attribution([cand("A", 16_000)], iso(10_000))
        self.assertIsNone(pick)
        self.assertEqual(why, "foreign")

    def test_tie_between_roots_is_ambiguous(self):
        self.assertEqual(ws.select_attribution([cand("A", 1000), cand("B", 1000)], iso(10_000)), (None, "ambiguous"))

    def test_no_created_at(self):
        self.assertEqual(ws.select_attribution([cand("A", 1000)], None), (None, "no-created-at"))

    def test_weak_evidence_is_not_strict(self):
        self.assertEqual(ws.select_attribution([cand("A", 1000, evidence="loose-url")], iso(10_000)), (None, "none"))

    def test_resolve_loose_url_within_part(self):
        cache = {"candidates": {"o/r#1": [cand("A", 9_000, evidence="loose-url", endedAt=12_000)]}}
        pick, _ = ws.resolve_attribution(cache, "o/r", 1, iso(10_000))
        self.assertEqual(pick["rootSessionId"], "A")

    def test_resolve_loose_url_long_part_refused(self):
        cache = {"candidates": {"o/r#1": [cand("A", 0, evidence="loose-url", endedAt=11 * 60_000)]}}
        self.assertIsNone(ws.resolve_attribution(cache, "o/r", 1, iso(10_000))[0])

    def test_resolve_branch(self):
        cache = {"candidates": {}, "branchCandidates": {"feat": [
            {"repo": "o/r", "branch": "feat", "rootSessionId": "G", "originSessionId": "G", "parentage": "main",
             "createdAt": 9_000, "endedAt": 11_000, "harness": "goose"}]}}
        pick, _ = ws.resolve_attribution(cache, "o/r", 7, iso(10_000), "feat")
        self.assertEqual(ws.cache_root_id(pick), "goose:G")
        self.assertIsNone(ws.resolve_attribution(cache, "o/other", 7, iso(10_000), "feat")[0])

    def test_resolve_two_weak_roots_ambiguous(self):
        cache = {"candidates": {"o/r#1": [cand("A", 9_000, evidence="loose-url", endedAt=12_000),
                                          cand("B", 9_500, evidence="loose-url", endedAt=12_000)]}}
        self.assertEqual(ws.resolve_attribution(cache, "o/r", 1, iso(10_000)), (None, "ambiguous"))

    def test_resolve_strict_wins_over_weak(self):
        cache = {"candidates": {"o/r#1": [cand("A", 9_000), cand("B", 9_500, evidence="loose-url", endedAt=12_000)]}}
        self.assertEqual(ws.resolve_attribution(cache, "o/r", 1, iso(10_000))[0]["rootSessionId"], "A")

    def test_candidate_prs_maps_goose_ids(self):
        cache = {"candidates": {"o/r#3": [cand("20261117_4", 1, harness="goose")], "o/r#4": [cand("other", 1)]},
                 "branchCandidates": {"b": [{"repo": "o/r", "branch": "b", "rootSessionId": "ses_x", "createdAt": 1},
                                            {"repo": None, "branch": "b", "rootSessionId": "ses_x", "createdAt": 1}]}}
        keys, heads = ws.candidate_prs(cache, {"goose:20261117_4", "ses_x"})
        self.assertEqual(keys, {("o/r", 3)})
        self.assertEqual(heads, {("o/r", "b"), (None, "b")})


# --------------------------------------------------------------------------
# PR outcomes
# --------------------------------------------------------------------------


class TestOutcome(unittest.TestCase):
    def test_states(self):
        self.assertEqual(ws.pr_outcome(pr_node(1, iso(0), merged=iso(1)))["state"], "merged")
        self.assertEqual(ws.pr_outcome(pr_node(1, iso(0), state="CLOSED"))["state"], "closed")
        self.assertEqual(ws.pr_outcome(pr_node(1, iso(0), state="OPEN"))["state"], "open")

    def test_ci_red_and_review_fixes(self):
        commits = [
            {"oid": "a", "committedDate": iso(1000), "statusCheckRollup": {"state": "FAILURE"}},
            {"oid": "b", "committedDate": iso(5000), "statusCheckRollup": {"state": "ERROR"}},
            {"oid": "c", "committedDate": iso(9000), "statusCheckRollup": {"state": "SUCCESS"}},
            {"oid": "d", "committedDate": iso(12000), "statusCheckRollup": None},
        ]
        reviews = [{"author": {"login": "me"}, "submittedAt": iso(2000), "state": "COMMENTED"},  # author: ignored
                   {"author": {"login": "gemini-code-assist"}, "submittedAt": iso(6000), "state": "COMMENTED"}]
        o = ws.pr_outcome(pr_node(1, iso(0), merged=iso(20000), commits=commits, reviews=reviews))
        self.assertEqual(o["ci_red"], 2)
        self.assertEqual(o["review_fixes"], 2)

    def test_is_revert_of(self):
        self.assertTrue(ws.is_revert_of({"title": 'Revert "Fix it"', "body": ""}, "o/r", 5, "Fix it"))
        self.assertTrue(ws.is_revert_of({"title": "Revert the thing", "body": "Reverts o/r#5"}, "o/r", 5, "x"))
        self.assertFalse(ws.is_revert_of({"title": "Revert the thing", "body": "Reverts o/r#55"}, "o/r", 5, "x"))
        self.assertFalse(ws.is_revert_of({"title": "Fix it again", "body": "#5"}, "o/r", 5, "Fix it"))

    def test_attribute_prs_end_to_end(self):
        cache = {"candidates": {
            "o/r#1": [cand("W", 1_000)],
            "o/r#2": [cand("W", 1_000), cand("X", 3_000)],  # X created it later; W only printed it
        }}
        gh = FakeGitHub(
            prs={("o/r", 1): pr_node(1, iso(2_000), merged=iso(100_000)),
                 ("o/r", 2): pr_node(2, iso(4_000), state="OPEN")},
            searches=[{"number": 9, "title": 'Revert "Fix it"', "body": "", "createdAt": iso(200_000)}])
        out = ws.attribute_prs(cache, {"W"}, gh, [])
        self.assertEqual([(p["number"], p["state"], p["reverted"]) for p in out["W"]], [(1, "merged", True)])
        self.assertIn("repo:o/r is:pr revert in:title", gh.queries[0])

    def test_revert_outside_seven_days_does_not_count(self):
        cache = {"candidates": {"o/r#1": [cand("W", 1_000)]}}
        gh = FakeGitHub(prs={("o/r", 1): pr_node(1, iso(2_000), merged=iso(100_000))},
                        searches=[{"number": 9, "title": 'Revert "Fix it"', "body": "", "createdAt": iso(100_000 + 8 * 86400_000)}])
        self.assertFalse(ws.attribute_prs(cache, {"W"}, gh, [])["W"][0]["reverted"])


# --------------------------------------------------------------------------
# harness loaders
# --------------------------------------------------------------------------


class TempDir(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = self.tmp.name

    def tearDown(self):
        self.tmp.cleanup()


class TestOcLoader(TempDir):
    def test_tree_tokens_and_messages(self):
        path = os.path.join(self.dir, "oc.db")
        con = make_oc_db(path)
        b = OcBuilder(con)
        b.session("ses_root", t=T0)
        b.session("ses_sub", parent="ses_root", t=T0 + 10)
        b.session("ses_subsub", parent="ses_sub", t=T0 + 20)
        b.session("ses_other", t=T0)
        b.user("ses_root", T0, text(BRIEF))
        b.user("ses_root", T0 + 1, text("<beads-context>", synthetic=True))
        b.asst("ses_root", T0 + 2, "claude-opus-5-5@default", inp=100, out=10, reas=5, cr=1000, cw=50)
        b.asst("ses_root", T0 + 3, "claude-opus-5-5@default")  # zero usage: dropped
        b.user("ses_sub", T0 + 4, text("subagent prompt"))  # not a root user message
        b.asst("ses_sub", T0 + 5, "gemini-3.8-flash", inp=7, out=1, reas=2, cr=3)
        b.asst("ses_subsub", T0 + 3_600_000, "claude-opus-5-5@default", out=1)
        b.asst("ses_other", T0 + 9, "claude-opus-5-5@default", out=999)
        b.user("ses_root", T0 + 6, {"type": "compaction", "auto": False})
        con.commit()
        s = ws.load_oc_session(ws._ro(path), "ses_root")
        self.assertEqual(sorted(s.tree), ["ses_root", "ses_sub", "ses_subsub"])
        self.assertEqual(len(s.claude_calls), 2)
        t = s.claude_calls[0].tokens
        self.assertEqual((t.input, t.output, t.cache_read, t.cache_write), (100, 15, 1000, 50))
        self.assertEqual(len(s.gemini_calls), 1)
        self.assertEqual(s.gemini_calls[0].tokens.output, 3)
        self.assertEqual(s.brief, BRIEF)
        self.assertEqual(len(s.user_msgs), 3)
        self.assertTrue(s.user_msgs[1]["synthetic"])
        self.assertTrue(s.user_msgs[2]["compaction"])
        self.assertEqual(s.last_ms - s.first_ms, 3_600_000)

    def test_missing_session(self):
        path = os.path.join(self.dir, "oc.db")
        make_oc_db(path).commit()
        self.assertIsNone(ws.load_oc_session(ws._ro(path), "ses_nope"))


class TestGooseLoader(TempDir):
    def test_inclusive_input_and_messages(self):
        path = os.path.join(self.dir, "g.db")
        con = make_goose_db(path)
        con.execute("INSERT INTO sessions VALUES ('20261117_4','w','/w','2026-11-17 02:15:50',NULL,NULL)")
        con.execute("INSERT INTO sessions VALUES ('20261117_5','d','/w','2026-11-17 02:16:00','20261117_4',NULL)")
        con.execute("INSERT INTO sessions VALUES ('20261117_9','x','/w','2026-11-17 02:16:00',NULL,NULL)")
        L = "INSERT INTO usage_ledger (session_id,created_timestamp,model,input_tokens,output_tokens,cache_read_tokens,cache_write_tokens) VALUES (?,?,?,?,?,?,?)"
        con.execute(L, ("20261117_4", 1_794_900_000, "claude-opus-5-5", 1000, 10, 700, 200))
        con.execute(L, ("20261117_5", 1_794_900_010, "gemini-3.8-flash", 500, 5, 400, None))
        con.execute(L, ("20261117_4", 1_794_900_020, None, 99, 9, 0, 0))  # carried_forward
        con.execute(L, ("20261117_9", 1_794_900_020, "claude-opus-5-5", 5, 5, 0, 0))
        M = "INSERT INTO messages (session_id,role,content_json,created_timestamp,metadata_json) VALUES (?,?,?,?,?)"
        vis = json.dumps({"userVisible": True, "agentVisible": True})
        con.execute(M, ("20261117_4", "user", json.dumps([text("<turn-context>x")]), 1_794_900_000,
                        json.dumps({"userVisible": False, "agentVisible": True, "turnContext": True})))
        con.execute(M, ("20261117_4", "user", json.dumps([text(BRIEF + "\nStage-1 arm: goose")]), 1_794_900_000, vis))
        con.execute(M, ("20261117_4", "user", json.dumps([{"type": "toolResponse", "id": "c"}]), 1_794_900_005, vis))
        con.execute(M, ("20261117_4", "assistant", json.dumps([text("ok")]), 1_794_900_006, vis))
        con.execute(M, ("20261117_4", "user", json.dumps([text("please deploy")]), 1_794_903_600, vis))
        con.execute(M, ("20261117_5", "user", json.dumps([text("delegate prompt")]), 1_794_900_001, vis))
        con.commit()
        w = []
        s = ws.load_goose_session(ws._ro(path), "goose:20261117_4", w)
        self.assertEqual(s.native_id, "20261117_4")
        self.assertEqual(sorted(s.tree), ["20261117_4", "20261117_5"])
        t = s.claude_calls[0].tokens
        self.assertEqual((t.input, t.output, t.cache_read, t.cache_write), (100, 10, 700, 200))
        g = s.gemini_calls[0].tokens
        self.assertEqual((g.input, g.cache_read, g.cache_write), (100, 400, 0))
        self.assertEqual(len(w), 1)
        self.assertTrue(s.brief.startswith("You're working"))
        self.assertEqual(ws.parse_arm(s.brief), "goose")
        self.assertEqual(ws.count_step_ins(s.user_msgs), (1, 0))
        self.assertEqual(s.last_ms - s.first_ms, 3_600_000)
        self.assertEqual(s.created_ms, int(dt.datetime(2026, 11, 17, 2, 15, 50, tzinfo=dt.timezone.utc).timestamp() * 1000))


class TestGooseCompaction(TempDir):
    """Real goose shape (sessions.db, 2026-10): compaction flips every earlier
    message to agentVisible false, writes a userVisible-false summary row, and
    queues the resume prompt as a steer."""

    def test_brief_and_replies_survive_compaction(self):
        path = os.path.join(self.dir, "g.db")
        con = make_goose_db(path)
        cfg = json.dumps({"model_name": "claude-opus-5-5", "request_params": {"cache_ttl": "1h"}})
        con.execute("INSERT INTO sessions VALUES ('20261120_7','w','/w','2026-11-20 00:00:00',NULL,?)", (cfg,))
        M = "INSERT INTO messages (session_id,role,content_json,created_timestamp,metadata_json) VALUES (?,?,?,?,?)"
        old = json.dumps({"userVisible": True, "agentVisible": False})
        rows = [
            (BRIEF + "\nStage-1 arm: goose", old),
            ("<turn-context>x", json.dumps({"userVisible": False, "agentVisible": False, "turnContext": True})),
            ("green light", old),
            ('<swarm_message v="1" kind="chat" from="gse_abc" to="20261120_7">From stall-watch\'s coordinator for goose, working for Jonathan.', old),
            ('<swarm_message v="1" kind="chat" from="gse_abc" to="20261120_7">honk coordinator here', old),
            ("# Conversation Summary\n...", json.dumps({"userVisible": False, "agentVisible": True})),
            ("You are goose session 20261120_7, resuming after a self-compaction", json.dumps({"userVisible": True, "agentVisible": True, "steer": True})),
            ("*skip", json.dumps({"userVisible": True, "agentVisible": True, "steer": True})),
            ("merged, please deploy", json.dumps({"userVisible": True, "agentVisible": True})),
        ]
        for i, (t, meta) in enumerate(rows):
            con.execute(M, ("20261120_7", "user", json.dumps([text(t)]), 1_795_000_000 + i, meta))
        L = "INSERT INTO usage_ledger (session_id,created_timestamp,model,input_tokens,output_tokens,cache_read_tokens,cache_write_tokens) VALUES (?,?,?,?,?,?,?)"
        con.execute(L, ("20261120_7", 1_795_000_001, "claude-opus-5-5", 1_000_000, 0, 0, 1_000_000))
        con.commit()
        s = ws.load_goose_session(ws._ro(path), "goose:20261120_7", [])
        self.assertTrue(ws.is_worker_brief(s.brief))
        self.assertEqual(ws.parse_arm(s.brief), "goose")
        # green light, *skip, merged please deploy; the resume steer is not Jonathan
        self.assertEqual(ws.count_step_ins(s.user_msgs), (3, 1))
        # 1h cache writes at 8 $/M, not 5
        self.assertAlmostEqual(ws.claude_cost(s.claude_calls, []), 8.0)


class TestReviewFixes(unittest.TestCase):
    def test_ledger_rows_bounded_by_session_lifetime(self):
        # Another goose store reuses the id 20261117_1 at the same gateway.
        sess = ws.Session("goose:20261117_1", "goose", "20261117_1", created_ms=0)
        sess.tree = ["20261117_1"]
        sess.spans = {"20261117_1": (100_000, 200_000)}
        sess.gemini_calls = []
        led = [{"client_session_id": "20261117_1", "ts_ms": 150_000, "model": "gemini-3.8-flash", "dollars": 1.0},
               {"client_session_id": "20261117_1", "ts_ms": 9_000_000, "model": "gemini-3.8-flash", "dollars": 50.0},
               {"client_session_id": "20261117_1", "ts_ms": 90_000, "model": "gemini-3.8-flash", "dollars": 50.0}]
        r = ws.build_row(sess, led, [], [])
        self.assertAlmostEqual(r.gemini_usd, 1.0)

    def test_null_repo_branch_found_by_search(self):
        class GH(FakeGitHub):
            def search_heads(self, branch):
                return [("o/r", 7)] if branch == "feat" else []
        cache = {"candidates": {}, "branchCandidates": {"feat": [
            {"repo": None, "branch": "feat", "rootSessionId": "W", "originSessionId": "W", "parentage": "main",
             "createdAt": 9_000, "endedAt": 11_000}]}}
        gh = GH(prs={("o/r", 7): pr_node(7, iso(10_000), merged=iso(20_000), head="feat")})
        out = ws.attribute_prs(cache, {"W"}, gh, [])
        self.assertEqual([p["number"] for p in out["W"]], [7])

    def test_stallwatch_payload_from_coordinator_id(self):
        self.assertEqual(ws.classify_user_text(
            '<swarm_message v="1" from="gse_x" to="y">stall-watch here, checking in'), "swarm:stall-watch")
        self.assertEqual(ws.classify_user_text(
            '<swarm_message v="1" from="gse_x" to="y">honk coordinator re: x'), "swarm:gse_x")


# --------------------------------------------------------------------------
# ledger fetch
# --------------------------------------------------------------------------


class TestLedger(unittest.TestCase):
    def test_parse_and_sanitise(self):
        run = FakeRun(ledger_lines=["ses_a\t1000\tgemini-3.8-flash\t0.5\t10\t2\t30\t0\tglobal",
                                    "ses_a\t2000\tgemini-4-carbon\t\t\t\t\t\tglobal"])
        rows = ws.fetch_gemini_ledger(["ses_a", "bad'; drop table x;--"], "psql -U x", run)
        self.assertEqual(rows, [{"client_session_id": "ses_a", "ts_ms": 1000, "model": "gemini-3.8-flash", "dollars": 0.5,
                                 "tokens": ws.Tokens(input=10, output=2, cache_read=30, calls=1), "region": "global"},
                                {"client_session_id": "ses_a", "ts_ms": 2000, "model": "gemini-4-carbon", "dollars": None,
                                 "tokens": None, "region": "global"}])
        sql = run.calls[0][-1]
        self.assertIn("'ses_a'", sql)
        self.assertNotIn("drop", sql)

    def test_failure_returns_none(self):
        self.assertIsNone(ws.fetch_gemini_ledger(["ses_a"], "psql", FakeRun(psql_rc=2)))

    def test_no_ids_no_query(self):
        run = FakeRun()
        self.assertEqual(ws.fetch_gemini_ledger([], "psql", run), [])
        self.assertEqual(run.calls, [])


# --------------------------------------------------------------------------
# summary and CLI
# --------------------------------------------------------------------------


def row(arm, usd, states):
    return ws.Row("w", "opencode", arm, False, 0, 1.0, usd, 0.0, 0, 0,
                  [{"state": s, "reverted": False, "ci_red": 0, "review_fixes": 0} for s in states], 0, 0, "t")


class TestSummary(unittest.TestCase):
    def test_total_over_merged_counts_abandoned_cost(self):
        s = ws.summarize([row("goose", 10, ["merged", "merged"]), row("goose", 6, []), row("opencode", 3, ["closed"])])
        g = next(a for a in s if a["arm"] == "goose")
        self.assertEqual((g["workers"], g["workers_with_merge"], g["merged"]), (3 - 1, 1, 2))
        self.assertAlmostEqual(g["usd_per_merged_pr"], 8.0)
        o = next(a for a in s if a["arm"] == "opencode")
        self.assertIsNone(o["usd_per_merged_pr"])


class TestArgs(unittest.TestCase):
    def test_days_positive(self):
        with self.assertRaises(SystemExit):
            ws.parse_args(["goose", "--days", "0"])

    def test_until_needs_since(self):
        with self.assertRaises(SystemExit):
            ws.parse_args(["goose", "--days", "3", "--until", "2026-11-01"])

    def test_window(self):
        now = dt.datetime(2026, 11, 17, tzinfo=dt.timezone.utc)
        a = ws.parse_args(["goose"])
        s, e = ws.window_ms(a, now)
        self.assertEqual(e - s, 30 * 86400_000)
        a = ws.parse_args(["goose", "--since", "2026-11-01", "--until", "2026-11-02"])
        s, e = ws.window_ms(a, now)
        self.assertEqual(e - s, 86400_000)


class TestMain(TempDir):
    def build(self):
        oc = os.path.join(self.dir, "oc.db")
        con = make_oc_db(oc)
        b = OcBuilder(con)
        now_ms = int(dt.datetime(2026, 11, 17, tzinfo=dt.timezone.utc).timestamp() * 1000)
        t = now_ms - 5 * 86400_000
        for sid, brief in [("ses_w1", BRIEF), ("ses_human", "please read this"), ("ses_w2", BRIEF + "\nStage-1 arm: goose")]:
            b.session(sid, t=t, title=sid)
            b.user(sid, t, text(brief))
            b.asst(sid, t + 1, "claude-opus-5-5@default", out=1_000_000)
        b.session("ses_old", t=now_ms - 40 * 86400_000)
        b.user("ses_old", now_ms - 40 * 86400_000, text(BRIEF))
        b.session("ses_w1_sub", parent="ses_w1", t=t)
        b.asst("ses_w1_sub", t + 2, "gemini-3.8-flash", inp=1_000_000)
        con.commit()
        g = os.path.join(self.dir, "g.db")
        make_goose_db(g).commit()
        cache = os.path.join(self.dir, "cache.json")
        with open(cache, "w") as f:
            json.dump({"version": 3, "scannedThrough": 0, "candidates": {"o/r#1": [cand("ses_w1", t + 5)]}}, f)
        run = FakeRun(tagged=["ses_w1", "ses_human", "ses_w2", "ses_old", "goose:missing"],
                      ledger_lines=[f"ses_w1_sub\t{t + 10_000}\tgemini-3.8-flash\t2.0"])
        gh = FakeGitHub(prs={("o/r", 1): pr_node(1, iso(t + 10), merged=iso(t + 100))})
        return oc, g, cache, run, gh, dt.datetime(2026, 11, 17, tzinfo=dt.timezone.utc)

    def test_markdown(self):
        oc, g, cache, run, gh, now = self.build()
        out = io.StringIO()
        ws.main(["goose", "--db", oc, "--goose-db", g, "--lgtm-cache", cache, "--psql", "psql"],
                run=run, gh=gh, now=now, out=out)
        text_out = out.getvalue()
        # 20 Claude + 2.00 ledger Gemini + 0.75 carded Gemini from before the first ledger row
        self.assertIn("| opencode-baseline | 1 | 1 | 22.75 | 20.00 | 2.75 |", text_out)
        self.assertIn("2.75 (1/1)", text_out)
        self.assertIn("| goose | 1 | 0 | 20.00 |", text_out)
        self.assertIn("ses_w2 | goose (MISMATCH)", text_out)
        self.assertIn("ses_human (brief is not a coordinator launch; $20.00, 0 PR(s))", text_out)
        self.assertNotIn("ses_old", text_out)

    def test_json_include_exclude(self):
        oc, g, cache, run, gh, now = self.build()
        out = io.StringIO()
        ws.main(["goose", "--json", "--db", oc, "--goose-db", g, "--lgtm-cache", cache, "--psql", "psql",
                 "--include", "ses_human", "--exclude", "ses_w2"], run=run, gh=gh, now=now, out=out)
        d = json.loads(out.getvalue())
        ids = sorted(w["worker_id"] for w in d["workers"])
        self.assertEqual(ids, ["ses_human", "ses_w1"])
        self.assertEqual(d["excluded"], [["ses_w2", "--exclude; $20.00, 0 PR(s)"]])
        base = d["summary"][0]
        self.assertEqual(base["merged"], 1)
        self.assertAlmostEqual(base["usd_per_merged_pr"], 42.75)

    def test_ledger_down_still_reports(self):
        oc, g, cache, run, gh, now = self.build()
        run.psql_rc = 1
        out = io.StringIO()
        ws.main(["goose", "--json", "--db", oc, "--goose-db", g, "--lgtm-cache", cache, "--psql", "psql"],
                run=run, gh=gh, now=now, out=out)
        d = json.loads(out.getvalue())
        self.assertIn("gateway ledger unavailable: all Gemini priced from the card", d["warnings"])


if __name__ == "__main__":
    unittest.main()
