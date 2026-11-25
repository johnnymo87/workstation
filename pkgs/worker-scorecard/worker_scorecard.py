#!/usr/bin/env python3
"""worker-scorecard: per-worker cost and outcome for a program's worker sessions,
both harnesses (opencode and goose), with a per-arm headline of total $ / merged PR.

Bead workstation-6w7i.4 (stage-1 measurement for moving worker launches to goose).
See README.md for the cost basis and every heuristic, and why each one is there.

Read-only against every store it touches: opencode.db and goose's sessions.db are
opened `mode=ro`, the gateway ledger is SELECTed through psql, lgtm's attribution
cache is read, and GitHub is queried through `gh api graphql`.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import sqlite3
import subprocess
import sys
from dataclasses import dataclass, field
from typing import Callable, Iterable

# --------------------------------------------------------------------------
# Rate cards ($ per million tokens)
# --------------------------------------------------------------------------

# The gateway ledger's own Opus card, verified 2026-11-17 from
# gateway_request_log (dollars / tokens per column, both context tiers).
# Claude is priced from the harness DBs, never the ledger: cfp's Max overflow
# leaves no ledger row, so the ledger alone silently drops Claude calls.
CLAUDE_CARD = {"input": 4.0, "output": 20.0, "cache_read": 0.2, "cache_write": 5.0, "cache_write_1h": 8.0}

# The gateway's own gemini-3.8-flash card (same derivation, flat across tiers).
# Used ONLY for Gemini calls that have no ledger row with a session id: the
# gateway started recording session ids at 2026-11-16 23:55Z.
# Also used for ledger rows the gateway recorded with tokens but NULL dollars
# (a model missing from the gateway's own price table, e.g. gemini-4-neon).
# Gemini 4 Neon: global list price; cache writes are free until 2027-01-12 and
# implicit caching reports none per request, so cache_write is 0 here.
GEMINI_CARD = {
    "gemini-3.8-flash": {"input": 0.75, "output": 3.75, "cache_read": 0.075, "cache_write": 0.0, "cache_write_1h": 0.0},
    "gemini-4-neon": {"input": 3.0, "output": 15.0, "cache_read": 0.15, "cache_write": 0.0, "cache_write_1h": 0.0},
}
# Vertex non-global regions list Gemini at +10% over the global price.
GEMINI_NON_GLOBAL_MULTIPLIER = 1.1

CLAUDE_CARD_MODEL = "claude-opus"

ET = None
try:  # display only; the sandbox may lack tzdata
    from zoneinfo import ZoneInfo

    ET = ZoneInfo("America/New_York")
except Exception:  # pragma: no cover
    ET = None

DEFAULT_OC_DB = os.path.expanduser("~/.local/share/opencode/opencode.db")
DEFAULT_GOOSE_DB = os.path.expanduser("~/.local/share/goose/sessions/sessions.db")
DEFAULT_LGTM_CACHE = os.path.expanduser("~/.local/state/lgtm/shepherd/attribution-cache.json")
DEFAULT_PSQL = "docker exec -i dev-postgres-1 psql -U aigateway -d aigateway"

GOOSE_PREFIX = "goose:"

# --------------------------------------------------------------------------
# Brief parsing: worker detection and arm
# --------------------------------------------------------------------------

# Coordinator briefs are LLM-written, but every one so far opens with
# "sent by the <tag> program's stall-watch coordinator". A bare mention of
# "stall-watch coordinators" is NOT enough: briefs that a worker writes for its
# own sub-workers talk about the coordinators too.
_WORKER_RE = re.compile(r"sent by (?:the )?[\w.-]+ program's stall-watch coordinator", re.I)
# 6w7i.1's "ab" mode records the coin in the brief as `Stage-1 arm: goose`.
_ARM_RE = re.compile(r"\barm\s*[:=]\s*\**\s*`?(goose|opencode)\b", re.I)


def parse_arm(brief: str) -> str | None:
    m = _ARM_RE.search(brief or "")
    return m.group(1).lower() if m else None


def is_worker_brief(brief: str) -> bool:
    return bool(_WORKER_RE.search(brief or "")) or parse_arm(brief) is not None


# eng-agent-platform #502 (2026-11-24) retired the coin flip, so briefs from then
# on carry no arm line, and their wording varies by coordinator ("You're a worker
# for the <tag> program", "a <tag>-program worker, started by ...", "Program tag:
# <tag>"). Brief text cannot tell a coordinator's worker from a worker's own
# sub-worker that copies its shape. The coordinator's launch record can: the
# launch prints into the coordinator's goose session (stallwatch/launches.py
# reads the same lines). Applied only to roots created on or after this instant
# (2026-11-24 00:00 America/New_York), so earlier A/B numbers do not move.
LAUNCH_RECORD_FROM_MS = 1795496400000


def launch_needles(worker_id: str) -> list[str]:
    """What a coordinator's tool output shows when it launched worker_id.

    opencode-launch prints "Session launched: <id>", session-tags prints
    "Tagged session '<id>'", the attach hint ends "--session <id>"; `honk launch`
    prints "native=<native> gse=... tag=...".
    """
    out = [f"Tagged session '{worker_id}'", f"Session launched: {worker_id}", f"--session {worker_id}"]
    if worker_id.startswith(GOOSE_PREFIX):
        out.append(f"native={worker_id[len(GOOSE_PREFIX):]} ")
    return out


def coordinator_launch_output(goose: sqlite3.Connection | None, tag: str) -> str:
    """All tool output seen by this tag's coordinator sessions (coord-sessions/<tag>-<ms>).

    Only tool responses (role=user rows carrying a toolResponse in goose), so
    an id the coordinator merely wrote about does not count as a launch.
    """
    if goose is None:
        return ""
    home = re.compile(rf"/coord-sessions/{re.escape(tag)}-\d+/?$")
    ids = [r["id"] for r in goose.execute("SELECT id, working_dir FROM sessions WHERE working_dir LIKE ?",
                                          (f"%/coord-sessions/{tag}-%",)) if home.search(r["working_dir"] or "")]
    if not ids:
        return ""
    q = ",".join("?" * len(ids))
    rows = goose.execute(f"SELECT content_json FROM messages WHERE session_id IN ({q}) AND role = 'user' "
                         "AND content_json LIKE '%toolResponse%'", ids)
    return "\n".join(r["content_json"] or "" for r in rows)


def coordinator_launched(worker_id: str, launch_output: str) -> bool:
    return any(n in launch_output for n in launch_needles(worker_id))


# --------------------------------------------------------------------------
# Message classification (step-ins)
# --------------------------------------------------------------------------

_SWARM_FROM_RE = re.compile(r'^\s*<swarm_message\b[^>]*\bfrom="([^"]*)"[^>]*>\s*(.*)', re.S)
# stall-watch sends to an opencode worker as from="stall-watch", but to a goose
# worker from the coordinator's own gse_ id (stallwatch/messages.py), so the
# payload's opening words are what identify it on both harnesses.
_SW_PAYLOAD_RE = re.compile(r"^(?:From )?stall-watch(?:'s coordinator\b| here\b)", re.I)


def classify_user_text(text: str) -> str:
    """'swarm:<from>' | 'hook' | 'human' for a non-first, non-synthetic user text."""
    t = (text or "").lstrip()
    m = _SWARM_FROM_RE.match(t)
    if m:
        if m.group(1) == "stall-watch" or _SW_PAYLOAD_RE.match(m.group(2)):
            return "swarm:stall-watch"
        return "swarm:" + m.group(1)
    if t.startswith("<swarm_message"):
        return "swarm:"
    if t.startswith("<beads-context>") or t.startswith("<turn-context>") or t.startswith("<system-reminder>"):
        return "hook"
    if not t:
        return "hook"
    return "human"


def count_step_ins(user_msgs: list[dict]) -> tuple[int, int]:
    """(jonathan_msgs, stallwatch_msgs) over a ROOT session's user messages.

    Each item: {"text": str, "synthetic": bool, "compaction": bool}, oldest
    first. The first item is the brief. A compaction message and the message
    right after it (the agent-written resume prompt) are not human.
    """
    human = sw = 0
    after_compaction = False
    for i, m in enumerate(user_msgs):
        if i == 0:
            continue
        if m.get("compaction"):
            after_compaction = True
            continue
        if m.get("synthetic"):
            continue
        kind = classify_user_text(m.get("text", ""))
        if after_compaction and kind == "human":
            after_compaction = False
            continue
        after_compaction = False
        if kind == "human":
            human += 1
        elif kind == "swarm:stall-watch":
            sw += 1
    return human, sw


# --------------------------------------------------------------------------
# Pricing
# --------------------------------------------------------------------------


@dataclass
class Tokens:
    input: int = 0  # UNCACHED input
    output: int = 0  # output + reasoning
    cache_read: int = 0
    cache_write: int = 0  # 5-minute TTL
    calls: int = 0
    cache_write_1h: int = 0  # goose sessions run with request_params.cache_ttl = "1h"

    def add(self, other: "Tokens") -> None:
        self.input += other.input
        self.output += other.output
        self.cache_read += other.cache_read
        self.cache_write += other.cache_write
        self.cache_write_1h += other.cache_write_1h
        self.calls += other.calls


def price(t: Tokens, card: dict) -> float:
    return (
        t.input * card["input"]
        + t.output * card["output"]
        + t.cache_read * card["cache_read"]
        + t.cache_write * card["cache_write"]
        + t.cache_write_1h * card["cache_write_1h"]
    ) / 1e6


def is_claude(model: str | None) -> bool:
    return bool(model) and "claude" in model.lower()


def is_gemini(model: str | None) -> bool:
    return bool(model) and "gemini" in model.lower()


def gemini_card_for(model: str) -> dict | None:
    base = model.split("@")[0]
    return GEMINI_CARD.get(base)


@dataclass
class Call:
    """One LLM call in a session tree, tokens already normalised."""

    session_id: str
    ts_ms: int
    model: str
    tokens: Tokens


def gemini_cost(calls: list[Call], ledger: list[dict], warnings: list[str]) -> tuple[float, int, int]:
    """Gemini $ for one tree: (dollars, ledger_calls, card_calls).

    Per session: every ledger row whose client_session_id is that session, at
    its recorded dollars; plus the harness's own Gemini calls made BEFORE that
    session's first ledger row, priced at the gateway card. A session with no
    ledger row at all is priced wholly from the card.
    """
    by_session: dict[str, list[dict]] = {}
    for r in ledger:
        by_session.setdefault(r["client_session_id"], []).append(r)
    total = 0.0
    n_ledger = n_card = 0
    unpriced: dict[str, int] = {}
    sessions = {c.session_id for c in calls} | set(by_session)
    for sid in sessions:
        rows = by_session.get(sid, [])
        cutoff = min((r["ts_ms"] for r in rows), default=None)
        for r in rows:
            if r.get("dollars") is None:
                card = gemini_card_for(r.get("model") or "")
                toks = r.get("tokens")
                if card is None or toks is None:
                    unpriced[r.get("model") or "?"] = unpriced.get(r.get("model") or "?", 0) + 1
                    continue
                mult = 1.0 if (r.get("region") or "global") == "global" else GEMINI_NON_GLOBAL_MULTIPLIER
                total += price(toks, card) * mult
            else:
                total += float(r["dollars"])
            n_ledger += 1
        for c in calls:
            if c.session_id != sid:
                continue
            # 2s of slack: the harness stamps a call at completion, the ledger at start.
            if cutoff is not None and c.ts_ms >= cutoff - 2000:
                continue
            card = gemini_card_for(c.model)
            if card is None:
                unpriced[c.model] = unpriced.get(c.model, 0) + 1
                continue
            total += price(c.tokens, card)
            n_card += 1
    for m, n in sorted(unpriced.items()):
        warnings.append(f"{n} Gemini call(s) on {m} with no price in the ledger or the card (counted as $0)")
    return total, n_ledger, n_card


def claude_cost(calls: list[Call], warnings: list[str]) -> float:
    tot = Tokens()
    other: dict[str, int] = {}
    for c in calls:
        tot.add(c.tokens)
        if CLAUDE_CARD_MODEL not in c.model.lower():
            other[c.model] = other.get(c.model, 0) + 1
    for m, n in sorted(other.items()):
        warnings.append(f"{n} call(s) on {m} priced at the Opus card")
    return price(tot, CLAUDE_CARD)


# --------------------------------------------------------------------------
# Session facts, per harness
# --------------------------------------------------------------------------


@dataclass
class Session:
    worker_id: str  # as session-tags prints it (goose ones prefixed)
    harness: str
    native_id: str
    title: str = ""
    directory: str = ""
    created_ms: int = 0
    first_ms: int | None = None
    last_ms: int | None = None
    brief: str = ""
    user_msgs: list[dict] = field(default_factory=list)
    claude_calls: list[Call] = field(default_factory=list)
    gemini_calls: list[Call] = field(default_factory=list)
    other_calls: int = 0
    tree: list[str] = field(default_factory=list)
    # per tree session: (first, last) message ms, to bound its ledger rows
    spans: dict[str, tuple[int, int]] = field(default_factory=dict)


def _ro(path: str) -> sqlite3.Connection:
    con = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    con.row_factory = sqlite3.Row
    return con


def _bump(s: Session, ts: int | None, sid: str | None = None) -> None:
    if ts is None:
        return
    if sid is not None:
        a, b = s.spans.get(sid, (ts, ts))
        s.spans[sid] = (min(a, ts), max(b, ts))
    s.first_ms = ts if s.first_ms is None else min(s.first_ms, ts)
    s.last_ms = ts if s.last_ms is None else max(s.last_ms, ts)


def oc_tree(con: sqlite3.Connection, root: str) -> list[str]:
    rows = con.execute(
        """WITH RECURSIVE t(id) AS (SELECT ? UNION ALL
             SELECT s.id FROM session s JOIN t ON s.parent_id = t.id)
           SELECT id FROM t""",
        (root,),
    ).fetchall()
    return [r[0] for r in rows]


def load_oc_session(con: sqlite3.Connection, worker_id: str) -> Session | None:
    row = con.execute("SELECT id, title, directory, time_created FROM session WHERE id = ?", (worker_id,)).fetchone()
    if row is None:
        return None
    s = Session(worker_id, "opencode", worker_id, row["title"] or "", row["directory"] or "", row["time_created"])
    s.tree = oc_tree(con, worker_id)
    qmarks = ",".join("?" * len(s.tree))
    for m in con.execute(
        f"SELECT id, session_id, time_created, data FROM message WHERE session_id IN ({qmarks}) ORDER BY time_created, id",
        s.tree,
    ):
        _bump(s, m["time_created"], m["session_id"])
        d = json.loads(m["data"])
        role = d.get("role")
        if role == "assistant":
            t = d.get("tokens") or {}
            cache = t.get("cache") or {}
            tok = Tokens(
                input=int(t.get("input") or 0),
                output=int(t.get("output") or 0) + int(t.get("reasoning") or 0),
                cache_read=int(cache.get("read") or 0),
                cache_write=int(cache.get("write") or 0),
                calls=1,
            )
            if tok.input + tok.output + tok.cache_read + tok.cache_write == 0:
                continue  # aborted or errored before any usage
            model = d.get("modelID") or ""
            call = Call(m["session_id"], int((d.get("time") or {}).get("created") or m["time_created"]), model, tok)
            if is_claude(model):
                s.claude_calls.append(call)
            elif is_gemini(model):
                s.gemini_calls.append(call)
            else:
                s.other_calls += 1
        elif role == "user" and m["session_id"] == worker_id:
            parts = [json.loads(p[0]) for p in con.execute("SELECT data FROM part WHERE message_id = ? ORDER BY id", (m["id"],))]
            texts = [p.get("text", "") for p in parts if p.get("type") == "text"]
            s.user_msgs.append({
                "text": "\n".join(texts),
                "synthetic": bool(parts) and all(p.get("synthetic") for p in parts if p.get("type") == "text") and bool(texts),
                "compaction": any(p.get("type") == "compaction" for p in parts),
            })
    s.brief = s.user_msgs[0]["text"] if s.user_msgs else ""
    return s


def _goose_ts(text: str | None) -> int:
    if not text:
        return 0
    t = dt.datetime.fromisoformat(str(text).replace("Z", "")).replace(tzinfo=dt.timezone.utc)
    return int(t.timestamp() * 1000)


def goose_tree(con: sqlite3.Connection, root: str) -> list[str]:
    rows = con.execute(
        """WITH RECURSIVE t(id) AS (SELECT ? UNION ALL
             SELECT s.id FROM sessions s JOIN t ON s.parent_session_id = t.id)
           SELECT id FROM t""",
        (root,),
    ).fetchall()
    return [r[0] for r in rows]


def load_goose_session(con: sqlite3.Connection, worker_id: str, warnings: list[str]) -> Session | None:
    native = worker_id[len(GOOSE_PREFIX):] if worker_id.startswith(GOOSE_PREFIX) else worker_id
    row = con.execute("SELECT id, name, working_dir, created_at FROM sessions WHERE id = ?", (native,)).fetchone()
    if row is None:
        return None
    s = Session(worker_id, "goose", native, row["name"] or "", row["working_dir"] or "", _goose_ts(row["created_at"]))
    s.tree = goose_tree(con, native)
    qmarks = ",".join("?" * len(s.tree))
    one_hour: set[str] = set()
    for r in con.execute(f"SELECT id, model_config_json FROM sessions WHERE id IN ({qmarks})", s.tree):
        try:
            cfg = json.loads(r["model_config_json"] or "{}") or {}
        except ValueError:
            cfg = {}
        if ((cfg.get("request_params") or {}).get("cache_ttl")) == "1h":
            one_hour.add(r["id"])
    skipped = 0
    for u in con.execute(
        f"""SELECT session_id, created_timestamp, model, input_tokens, output_tokens,
                   cache_read_tokens, cache_write_tokens
            FROM usage_ledger WHERE session_id IN ({qmarks}) ORDER BY created_timestamp, id""",
        s.tree,
    ):
        model = u["model"]
        if not model:
            skipped += 1  # carried_forward rows: totals from before the ledger, no model
            continue
        cr = int(u["cache_read_tokens"] or 0)
        cw = int(u["cache_write_tokens"] or 0)
        # goose's input_tokens INCLUDES cache read and write (checked against
        # the gateway's own split), so uncached is the remainder.
        tok = Tokens(max(0, int(u["input_tokens"] or 0) - cr - cw), int(u["output_tokens"] or 0), cr, cw, 1)
        if u["session_id"] in one_hour:
            tok.cache_write, tok.cache_write_1h = 0, cw
        call = Call(u["session_id"], int(u["created_timestamp"]) * 1000, model, tok)
        if is_claude(model):
            s.claude_calls.append(call)
        elif is_gemini(model):
            s.gemini_calls.append(call)
        else:
            s.other_calls += 1
    if skipped:
        warnings.append(f"{worker_id}: {skipped} usage_ledger row(s) without a model skipped")
    for m in con.execute(
        f"""SELECT session_id, role, content_json, metadata_json, created_timestamp
            FROM messages WHERE session_id IN ({qmarks}) ORDER BY created_timestamp, id""",
        s.tree,
    ):
        _bump(s, int(m["created_timestamp"]) * 1000, m["session_id"])
        if m["role"] != "user" or m["session_id"] != native:
            continue
        meta = json.loads(m["metadata_json"] or "{}")
        try:
            content = json.loads(m["content_json"] or "[]")
        except ValueError:
            content = []
        if any(c.get("type") != "text" for c in content):
            continue  # tool responses ride on role=user in goose
        text = "\n".join(c.get("text", "") for c in content)
        # agentVisible is NOT a signal: goose's compaction flips every earlier
        # message (the brief and Jonathan's replies included) to agentVisible
        # false. The compaction itself is the summary row the user never saw.
        if meta.get("turnContext"):
            s.user_msgs.append({"text": text, "synthetic": True, "compaction": False})
        elif meta.get("userVisible") is False:
            s.user_msgs.append({"text": text, "synthetic": False, "compaction": True})
        else:
            s.user_msgs.append({"text": text, "synthetic": False, "compaction": False})
    firsts = [m for m in s.user_msgs if not m["synthetic"] and not m["compaction"]]
    s.brief = firsts[0]["text"] if firsts else ""
    if firsts and s.user_msgs[0] is not firsts[0]:
        s.user_msgs = [firsts[0]] + [m for m in s.user_msgs if m is not firsts[0]]
    return s


# --------------------------------------------------------------------------
# Gateway ledger (Gemini)
# --------------------------------------------------------------------------

_ID_RE = re.compile(r"^[A-Za-z0-9_\-]+$")


def fetch_gemini_ledger(session_ids: Iterable[str], psql: str, run=subprocess.run) -> list[dict] | None:
    ids = sorted({i for i in session_ids if _ID_RE.match(i)})
    if not ids:
        return []
    lit = ",".join("'" + i + "'" for i in ids)
    sql = (
        "SELECT client_session_id, (extract(epoch from request_started_at)*1000)::bigint, model, total_dollars, "
        "input_tokens, output_tokens, cache_read_tokens, cache_creation_5m_tokens + cache_creation_1h_tokens, region "
        f"FROM gateway_request_log WHERE model LIKE 'gemini%' AND client_session_id IN ({lit})"
    )
    try:
        p = run(psql.split() + ["-At", "-F", "\t", "-c", sql], capture_output=True, text=True, timeout=120)
    except (OSError, subprocess.TimeoutExpired) as e:
        sys.stderr.write(f"warning: gateway ledger unavailable ({e}); Gemini priced from the card only\n")
        return None
    if p.returncode != 0:
        sys.stderr.write(f"warning: gateway ledger query failed: {p.stderr.strip()[:300]}; Gemini priced from the card only\n")
        return None
    out = []
    for line in p.stdout.splitlines():
        if not line.strip():
            continue
        f = line.split("\t")
        sid, ts, model, dollars = f[:4]
        toks = None
        if len(f) >= 8 and f[4] != "":
            toks = Tokens(input=int(f[4]), output=int(f[5]), cache_read=int(f[6]), cache_write=int(f[7] or 0), calls=1)
        out.append({"client_session_id": sid, "ts_ms": int(ts), "model": model,
                    "dollars": float(dollars) if dollars else None,
                    "tokens": toks, "region": f[8] if len(f) >= 9 else None})
    return out


# --------------------------------------------------------------------------
# PR attribution: lgtm's cache + a port of its selection rules
# --------------------------------------------------------------------------
# Source: ~/projects/lgtm/src/prAttribution.ts (selectAttribution,
# resolveAttribution, attributionMatchesPr). Keep in step with it.

CREATED_AT_SKEW_MS = 5_000
WEAK_EVIDENCE_MAX_PART_MS = 10 * 60_000


def _parse_iso_ms(s: str | None) -> int | None:
    if not s:
        return None
    try:
        return int(dt.datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp() * 1000)
    except ValueError:
        return None


def _strict(c: dict) -> bool:
    return (c.get("evidence") or "url") == "url"


def select_attribution(cands: list[dict] | None, pr_created_at: str | None) -> tuple[dict | None, str | None]:
    pool = [c for c in (cands or []) if _strict(c)]
    if not pool:
        return None, "none"
    created = _parse_iso_ms(pr_created_at)
    if created is None:
        return None, "no-created-at"

    def latest(xs):
        best, tied = None, False
        for c in xs:
            if best is None or c["createdAt"] > best["createdAt"]:
                best, tied = c, False
            elif c["createdAt"] == best["createdAt"] and c["rootSessionId"] != best["rootSessionId"]:
                tied = True
        return best, tied

    best, tied = latest([c for c in pool if c["createdAt"] <= created])
    if best is None:
        best, tied = latest([c for c in pool if created >= c["createdAt"] - CREATED_AT_SKEW_MS])
    if best is None:
        return None, "foreign"
    if tied:
        return None, "ambiguous"
    return best, None


def _created_during(created: int, start: int, end: int | None) -> bool:
    return (
        isinstance(end, int)
        and end - start <= WEAK_EVIDENCE_MAX_PART_MS
        and created >= start - CREATED_AT_SKEW_MS
        and created <= end + CREATED_AT_SKEW_MS
    )


def resolve_attribution(cache: dict, repo: str, number: int, pr_created_at: str | None, head: str | None = None):
    cands = (cache.get("candidates") or {}).get(f"{repo}#{number}")
    pick, refused = select_attribution(cands, pr_created_at)
    if pick or refused in ("ambiguous", "no-created-at"):
        return pick, refused
    created = _parse_iso_ms(pr_created_at)
    if created is None:
        return pick, refused
    fits = [c for c in (cands or []) if c.get("evidence") == "loose-url" and _created_during(created, c["createdAt"], c.get("endedAt"))]
    for b in ((cache.get("branchCandidates") or {}).get(head) or []) if head else []:
        if b.get("branch") != head or (b.get("repo") is not None and b.get("repo") != repo):
            continue
        if not _created_during(created, b["createdAt"], b.get("endedAt")):
            continue
        fits.append({**b, "repo": repo, "prNumber": number, "evidence": "branch"})
    if not fits:
        return pick, refused
    if len({c["rootSessionId"] for c in fits}) > 1:
        return None, "ambiguous"
    return max(fits, key=lambda c: c["createdAt"]), None


def cache_root_id(c: dict) -> str:
    """The cache's root id in session-tags' form (goose ids are prefixed)."""
    rid = c["rootSessionId"]
    return GOOSE_PREFIX + rid if c.get("harness") == "goose" and not rid.startswith(GOOSE_PREFIX) else rid


def candidate_prs(cache: dict, workers: set[str]) -> tuple[set[tuple[str, int]], set[tuple[str | None, str]]]:
    """PR keys and (repo, branch) heads any worker has evidence for."""
    keys: set[tuple[str, int]] = set()
    for k, cands in (cache.get("candidates") or {}).items():
        if any(cache_root_id(c) in workers for c in cands):
            repo, _, n = k.rpartition("#")
            keys.add((repo, int(n)))
    heads: set[tuple[str | None, str]] = set()
    for branch, bs in (cache.get("branchCandidates") or {}).items():
        for b in bs:
            if cache_root_id(b) in workers:
                # repo None: the create named no --repo; GitHub is searched by head.
                heads.add((b.get("repo"), branch))
    return keys, heads


# --------------------------------------------------------------------------
# GitHub
# --------------------------------------------------------------------------

_PR_FIELDS = """number title state createdAt mergedAt closedAt headRefName author { login }
  commits(last: 100) { nodes { commit { oid committedDate statusCheckRollup { state } } } }
  reviews(first: 100) { nodes { author { login } submittedAt state } }"""


class GitHub:
    def __init__(self, run=subprocess.run):
        self.run = run

    def _graphql(self, query: str, **vars) -> dict:
        args = ["gh", "api", "graphql", "-f", f"query={query}"]
        for k, v in vars.items():
            args += ["-F" if isinstance(v, int) else "-f", f"{k}={v}"]
        p = self.run(args, capture_output=True, text=True, timeout=120)
        if p.returncode != 0:
            raise RuntimeError(p.stderr.strip()[:300])
        return json.loads(p.stdout)["data"]

    def pr(self, repo: str, number: int) -> dict | None:
        owner, name = repo.split("/", 1)
        q = f"query($o:String!,$n:String!,$num:Int!){{repository(owner:$o,name:$n){{pullRequest(number:$num){{{_PR_FIELDS}}}}}}}"
        return ((self._graphql(q, o=owner, n=name, num=number).get("repository") or {}).get("pullRequest"))

    def prs_for_head(self, repo: str, branch: str) -> list[dict]:
        owner, name = repo.split("/", 1)
        q = (f"query($o:String!,$n:String!,$b:String!){{repository(owner:$o,name:$n){{"
             f"pullRequests(headRefName:$b,first:10){{nodes{{{_PR_FIELDS}}}}}}}}}")
        return ((self._graphql(q, o=owner, n=name, b=branch).get("repository") or {}).get("pullRequests") or {}).get("nodes") or []

    def search_heads(self, branch: str) -> list[tuple[str, int]]:
        """(repo, number) of PRs I authored from this head branch, any repo."""
        q = ("query($q:String!){search(query:$q,type:ISSUE,first:20){nodes{... on PullRequest"
             "{number repository{nameWithOwner}}}}}")
        nodes = self._graphql(q, q=f"is:pr author:@me head:{branch}")["search"]["nodes"]
        return [(n["repository"]["nameWithOwner"], n["number"]) for n in nodes if n]

    def search_prs(self, query: str) -> list[dict]:
        q = "query($q:String!){search(query:$q,type:ISSUE,first:30){nodes{... on PullRequest{number title body createdAt}}}}"
        return [n for n in self._graphql(q, q=query)["search"]["nodes"] if n]


def is_revert_of(candidate: dict, repo: str, number: int, title: str) -> bool:
    ct = candidate.get("title") or ""
    body = candidate.get("body") or ""
    if "revert" not in ct.lower():
        return False
    if title and f'"{title}"' in ct:
        return True
    return bool(re.search(rf"(?:{re.escape(repo)}#|(?<![\w/])#|/pull/){number}\b", body))


def pr_outcome(pr: dict) -> dict:
    """State, CI-red rounds and review-fix rounds from one GraphQL PR node."""
    author = ((pr.get("author") or {}).get("login") or "").lower()
    commits = [n["commit"] for n in ((pr.get("commits") or {}).get("nodes") or [])]
    ci_red = sum(1 for c in commits if ((c.get("statusCheckRollup") or {}).get("state") in ("FAILURE", "ERROR")))
    reviews = [r for r in ((pr.get("reviews") or {}).get("nodes") or [])
               if r.get("submittedAt") and ((r.get("author") or {}).get("login") or "").lower() != author]
    first_review = min((t for r in reviews if (t := _parse_iso_ms(r["submittedAt"])) is not None), default=None)
    fixes = 0
    if first_review is not None:
        fixes = sum(1 for c in commits if (_parse_iso_ms(c.get("committedDate")) or 0) > first_review)
    state = "merged" if pr.get("mergedAt") else ("closed" if pr.get("state") == "CLOSED" else "open")
    return {"state": state, "ci_red": ci_red, "review_fixes": fixes}


def check_reverted(gh: GitHub, repo: str, pr: dict) -> bool:
    merged = _parse_iso_ms(pr.get("mergedAt"))
    if merged is None:
        return False
    d0 = dt.datetime.fromtimestamp(merged / 1000, dt.timezone.utc).date()
    d1 = d0 + dt.timedelta(days=7)
    for c in gh.search_prs(f"repo:{repo} is:pr revert in:title created:{d0.isoformat()}..{d1.isoformat()}"):
        c_ms = _parse_iso_ms(c.get("createdAt"))
        if c_ms is not None and merged <= c_ms <= merged + 7 * 86400_000 and is_revert_of(c, repo, pr["number"], pr.get("title") or ""):
            return True
    return False


def attribute_prs(cache: dict, workers: set[str], gh: GitHub, warnings: list[str]) -> dict[str, list[dict]]:
    """worker id -> [PR facts], only PRs lgtm's rules attribute to that worker."""
    keys, heads = candidate_prs(cache, workers)
    nodes: dict[tuple[str, int], dict] = {}
    for repo, n in sorted(keys):
        try:
            node = gh.pr(repo, n)
        except Exception as e:  # noqa: BLE001
            warnings.append(f"{repo}#{n}: GitHub lookup failed ({e}); PR not counted")
            continue
        if node:
            nodes[(repo, n)] = node
    for repo, branch in sorted(heads, key=lambda h: (h[0] or "", h[1])):
        try:
            if repo:
                for node in gh.prs_for_head(repo, branch):
                    nodes.setdefault((repo, node["number"]), node)
            else:
                for r, n in gh.search_heads(branch):
                    if (r, n) not in nodes and (node := gh.pr(r, n)):
                        nodes[(r, n)] = node
        except Exception as e:  # noqa: BLE001
            warnings.append(f"{repo or '*'} head {branch}: GitHub lookup failed ({e})")
    out: dict[str, list[dict]] = {}
    for (repo, n), node in sorted(nodes.items()):
        pick, _ = resolve_attribution(cache, repo, n, node.get("createdAt"), node.get("headRefName"))
        if not pick:
            continue
        root = cache_root_id(pick)
        if root not in workers:
            continue
        facts = {"repo": repo, "number": n, "title": node.get("title") or "", **pr_outcome(node)}
        facts["reverted"] = False
        if facts["state"] == "merged":
            try:
                facts["reverted"] = check_reverted(gh, repo, node)
            except Exception as e:  # noqa: BLE001
                warnings.append(f"{repo}#{n}: revert search failed ({e})")
        out.setdefault(root, []).append(facts)
    return out


# --------------------------------------------------------------------------
# Assembly
# --------------------------------------------------------------------------


@dataclass
class Row:
    worker_id: str
    harness: str
    arm: str
    arm_mismatch: bool
    created_ms: int
    wall_h: float
    claude_usd: float
    gemini_usd: float
    gemini_ledger_calls: int
    gemini_card_calls: int
    prs: list[dict]
    jonathan_msgs: int
    stallwatch_msgs: int
    title: str

    @property
    def total_usd(self) -> float:
        return self.claude_usd + self.gemini_usd

    def n(self, state: str) -> int:
        return sum(1 for p in self.prs if p["state"] == state)


def build_row(s: Session, ledger: list[dict] | None, prs: list[dict], warnings: list[str]) -> Row:
    w: list[str] = []
    claude = claude_cost(s.claude_calls, w)
    rows = []
    for r in ledger or []:
        span = s.spans.get(r["client_session_id"])
        # goose ids (YYYYMMDD_N) are a per-store counter, and other goose stores
        # (test instances) send the same ids to the same gateway: keep only rows
        # inside the session's own lifetime.
        if span and span[0] - 5_000 <= r["ts_ms"] <= span[1] + 60_000:
            rows.append(r)
    gem, nl, nc = gemini_cost(s.gemini_calls, rows, w)
    if s.other_calls:
        w.append(f"{s.other_calls} call(s) on other providers not priced")
    warnings.extend(f"{s.worker_id}: {x}" for x in w)
    marked = parse_arm(s.brief)
    arm = marked or f"{s.harness}-baseline"
    human, sw = count_step_ins(s.user_msgs)
    wall = ((s.last_ms or s.created_ms) - (s.first_ms or s.created_ms)) / 3.6e6
    return Row(s.worker_id, s.harness, arm, bool(marked and marked != s.harness), s.created_ms, wall,
               claude, gem, nl, nc, prs, human, sw, s.title)


def summarize(rows: list[Row]) -> list[dict]:
    arms: dict[str, list[Row]] = {}
    for r in rows:
        arms.setdefault(r.arm, []).append(r)
    out = []
    for arm, rs in sorted(arms.items()):
        total = sum(r.total_usd for r in rs)
        merged = sum(r.n("merged") for r in rs)
        out.append({
            "arm": arm,
            "workers": len(rs),
            "workers_with_merge": sum(1 for r in rs if r.n("merged")),
            "total_usd": total,
            "claude_usd": sum(r.claude_usd for r in rs),
            "gemini_usd": sum(r.gemini_usd for r in rs),
            "prs": sum(len(r.prs) for r in rs),
            "merged": merged,
            "reverted": sum(1 for r in rs for p in r.prs if p.get("reverted")),
            "usd_per_merged_pr": (total / merged) if merged else None,
            "jonathan_msgs": sum(r.jonathan_msgs for r in rs),
            "stallwatch_msgs": sum(r.stallwatch_msgs for r in rs),
        })
    return out


def _date(ms: int) -> str:
    t = dt.datetime.fromtimestamp(ms / 1000, ET or dt.timezone.utc)
    return t.strftime("%Y-%m-%d")


def render_markdown(rows: list[Row], summary: list[dict], excluded: list[tuple[str, str]], warnings: list[str],
                    window: tuple[int, int], tag: str) -> str:
    L = []
    L.append(f"worker-scorecard {tag}, {_date(window[0])} .. {_date(window[1])} (root sessions created in window)")
    L.append("")
    L.append("| arm | workers | w/ merge | total $ | Claude $ | Gemini $ | PRs | merged | reverted | $/merged PR | J msgs | sw msgs |")
    L.append("|---|---|---|---|---|---|---|---|---|---|---|---|")
    for a in summary:
        per = f"{a['usd_per_merged_pr']:.2f}" if a["usd_per_merged_pr"] is not None else "n/a"
        L.append(f"| {a['arm']} | {a['workers']} | {a['workers_with_merge']} | {a['total_usd']:.2f} | {a['claude_usd']:.2f} | "
                 f"{a['gemini_usd']:.2f} | {a['prs']} | {a['merged']} | {a['reverted']} | {per} | {a['jonathan_msgs']} | {a['stallwatch_msgs']} |")
    L.append("")
    L.append("| worker | arm | start | wall h | Claude $ | Gemini $ (ledger/card calls) | total $ | PRs m/c/o | rev | CI-red | rev-fix | J | sw | title |")
    L.append("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
    for r in sorted(rows, key=lambda r: r.created_ms):
        arm = r.arm + (" (MISMATCH)" if r.arm_mismatch else "")
        L.append(
            f"| {r.worker_id} | {arm} | {_date(r.created_ms)} | {r.wall_h:.1f} | {r.claude_usd:.2f} | "
            f"{r.gemini_usd:.2f} ({r.gemini_ledger_calls}/{r.gemini_card_calls}) | {r.total_usd:.2f} | "
            f"{r.n('merged')}/{r.n('closed')}/{r.n('open')} | {sum(1 for p in r.prs if p['reverted'])} | "
            f"{sum(p['ci_red'] for p in r.prs)} | {sum(p['review_fixes'] for p in r.prs)} | "
            f"{r.jonathan_msgs} | {r.stallwatch_msgs} | {r.title[:60].replace('|', '/')} |"
        )
    prs = [(r.worker_id, p) for r in rows for p in r.prs]
    if prs:
        L.append("")
        L.append("PRs: " + ", ".join(f"{p['repo']}#{p['number']} {p['state']}{' REVERTED' if p['reverted'] else ''} ({w[-6:]})" for w, p in prs))
    if excluded:
        L.append("")
        L.append("Excluded: " + "; ".join(f"{i} ({why})" for i, why in excluded))
    if warnings:
        L.append("")
        L.append("Warnings:")
        L.extend(f"- {w}" for w in warnings)
    return "\n".join(L) + "\n"


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------


def parse_args(argv: list[str]) -> argparse.Namespace:
    p = argparse.ArgumentParser(prog="worker-scorecard", description=(__doc__ or "").split("\n\n")[0])
    p.add_argument("tag", help="session-tags program tag (e.g. goose)")
    g = p.add_mutually_exclusive_group()
    g.add_argument("--days", type=int, default=None, help="window: the last N days (default 30)")
    g.add_argument("--since", help="window start, YYYY-MM-DD (UTC)")
    p.add_argument("--until", help="window end, YYYY-MM-DD (UTC, exclusive); default now")
    p.add_argument("--include", action="append", default=[], help="count this root id as a worker regardless of its brief")
    p.add_argument("--exclude", action="append", default=[], help="never count this root id")
    p.add_argument("--json", action="store_true")
    p.add_argument("--db", default=DEFAULT_OC_DB)
    p.add_argument("--goose-db", default=DEFAULT_GOOSE_DB)
    p.add_argument("--lgtm-cache", default=DEFAULT_LGTM_CACHE)
    p.add_argument("--psql", default=DEFAULT_PSQL, help="command that runs psql against the aigateway DB")
    a = p.parse_args(argv)
    if a.days is not None and a.days <= 0:
        p.error("--days must be positive")
    if a.until and a.days is not None:
        p.error("--until goes with --since, not --days")
    return a


def window_ms(a: argparse.Namespace, now: dt.datetime) -> tuple[int, int]:
    def day(s):
        return dt.datetime.fromisoformat(s).replace(tzinfo=dt.timezone.utc)

    end = day(a.until) if a.until else now
    start = day(a.since) if a.since else end - dt.timedelta(days=a.days or 30)
    return int(start.timestamp() * 1000), int(end.timestamp() * 1000)


def tagged_ids(tag: str, run=subprocess.run) -> list[str]:
    p = run(["session-tags", "sessions", tag], capture_output=True, text=True, timeout=60)
    if p.returncode != 0:
        raise SystemExit(f"session-tags sessions {tag} failed: {p.stderr.strip()}")
    return [l.strip() for l in p.stdout.splitlines() if l.strip()]


def main(argv: list[str] | None = None, *, run=subprocess.run, gh: GitHub | None = None,
         now: dt.datetime | None = None, out=sys.stdout) -> int:
    a = parse_args(sys.argv[1:] if argv is None else argv)
    start, end = window_ms(a, now or dt.datetime.now(dt.timezone.utc))
    warnings: list[str] = []
    ids = tagged_ids(a.tag, run)
    oc = _ro(a.db) if os.path.exists(a.db) else None
    gs = _ro(a.goose_db) if os.path.exists(a.goose_db) else None
    sessions: list[Session] = []
    loaded: list[Session] = []
    excluded: list[tuple[str, str]] = []
    launch_output = coordinator_launch_output(gs, a.tag)
    for i in ids:
        if i.startswith(GOOSE_PREFIX):
            s = load_goose_session(gs, i, warnings) if gs else None
        else:
            s = load_oc_session(oc, i) if oc else None
        if s is None:
            continue  # not in a local store (another machine, or deleted)
        if not (start <= s.created_ms < end):
            continue
        loaded.append(s)
        if i in a.exclude:
            excluded.append((i, "--exclude"))
        elif i in a.include or is_worker_brief(s.brief):
            sessions.append(s)
        elif s.created_ms >= LAUNCH_RECORD_FROM_MS and coordinator_launched(i, launch_output):
            sessions.append(s)
        else:
            excluded.append((i, "brief is not a coordinator launch"))
    excluded_sessions = {s.worker_id: s for s in loaded if s.worker_id in dict(excluded)}
    everyone = sessions + list(excluded_sessions.values())
    tree_ids = [t for s in everyone for t in s.tree]
    ledger = fetch_gemini_ledger(tree_ids, a.psql, run)
    if ledger is None:
        warnings.append("gateway ledger unavailable: all Gemini priced from the card")
    cache = {}
    if os.path.exists(a.lgtm_cache):
        with open(a.lgtm_cache) as f:
            cache = json.load(f)
    else:
        warnings.append(f"no lgtm attribution cache at {a.lgtm_cache}: PRs not counted")
    prs = attribute_prs(cache, {s.worker_id for s in everyone}, gh or GitHub(run), warnings) if cache else {}
    rows = [build_row(s, ledger, prs.get(s.worker_id, []), warnings) for s in sessions]
    # Shown, not counted: what was left out, so a reviewer can see its weight.
    ex_rows = {i: build_row(s, ledger, prs.get(i, []), []) for i, s in excluded_sessions.items()}
    excluded = [(i, f"{why}; ${ex_rows[i].total_usd:.2f}, {len(ex_rows[i].prs)} PR(s)" if i in ex_rows else why)
                for i, why in excluded]
    summary = summarize(rows)
    if a.json:
        json.dump({
            "tag": a.tag, "since_ms": start, "until_ms": end,
            "cards": {"claude": CLAUDE_CARD, "gemini": GEMINI_CARD},
            "summary": summary,
            "workers": [{**{k: v for k, v in r.__dict__.items()}, "total_usd": r.total_usd} for r in rows],
            "excluded": excluded, "warnings": warnings,
        }, out, indent=2)
        out.write("\n")
    else:
        out.write(render_markdown(rows, summary, excluded, warnings, (start, end), a.tag))
    return 0


if __name__ == "__main__":
    sys.exit(main())
