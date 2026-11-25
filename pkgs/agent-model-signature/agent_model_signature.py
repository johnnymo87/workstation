#!/usr/bin/env python3
"""Resolve the active agent session's model family and rewrite trailing Slack/post signatures.

Reads the live session database (read-only, short timeout) so mid-life model
switches (e.g. stall-watch's Opus <-> Gemini 4 Neon switch) take effect
immediately without restarting the session or its MCP child processes.

Subcommands:
  family   Print the active session's model family (Claude, Gemini, GPT) and
           exit 0; print nothing and exit 1 if unknown or unavailable.
  rewrite  Read a message body from stdin (never argv) and, if its last
           non-blank line is a standalone model signature (--Claude, — Claude,
           --Gemini, etc.), swap only the model name to the active session's
           family while preserving dash style and whitespace. Unsigned messages
           and any lookup errors pass through unchanged (fail-open).
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sqlite3
import sys
from pathlib import Path
from typing import Mapping
from urllib.parse import quote

DEFAULT_GOOSE_DB = "~/.local/share/goose/sessions/sessions.db"
DEFAULT_OPENCODE_DB = "~/.local/share/opencode/opencode.db"
SQLITE_TIMEOUT_SECS = 0.2

# Matches a standalone trailing signature line such as "--Claude", "— Claude",
# "– Gemini", "--GPT", with optional leading/trailing whitespace and newline.
# Deliberately does NOT match prose like "-- Claude suggested reverting this."
_SIGNATURE_LINE_RE = re.compile(
    r"^([ \t]*(?:--|—|–)[ \t]*)(Claude|Gemini|GPT|Codex)([ \t]*\r?\n?)$",
    re.IGNORECASE,
)


def classify_model_family(raw_model: str | None) -> str | None:
    """Map a raw model ID (e.g. 'gcp_vertex_ai/gemini-4-neon@default') to a short family name."""
    if not raw_model or not isinstance(raw_model, str):
        return None
    model = raw_model.strip()
    if not model:
        return None
    if "/" in model:
        model = model.rsplit("/", 1)[-1]
    lower = model.lower()
    if lower.startswith("anthropic."):
        lower = lower[len("anthropic.") :]
    if lower.startswith("claude"):
        return "Claude"
    if lower.startswith("gemini"):
        return "Gemini"
    if lower.startswith(("gpt", "codex", "o1", "o3", "o4")):
        return "GPT"
    return None


def _connect_ro(db_path: Path) -> sqlite3.Connection:
    uri = f"file:{quote(str(db_path))}?mode=ro"
    conn = sqlite3.connect(uri, uri=True, timeout=SQLITE_TIMEOUT_SECS)
    conn.execute(f"PRAGMA busy_timeout = {int(SQLITE_TIMEOUT_SECS * 1000)}")
    return conn


def lookup_goose_model(session_id: str, db_path: Path) -> str | None:
    """Look up the live model_name for a goose session from sessions.db."""
    if not session_id or not db_path.is_file():
        return None
    conn = None
    try:
        conn = _connect_ro(db_path)
        row = conn.execute(
            "SELECT model_config_json FROM sessions WHERE id = ?",
            (session_id,),
        ).fetchone()
        if not row or not row[0]:
            return None
        cfg = json.loads(row[0])
        if isinstance(cfg, dict):
            name = cfg.get("model_name")
            if isinstance(name, str) and name.strip():
                return name.strip()
        return None
    except (sqlite3.Error, json.JSONDecodeError, OSError, TypeError):
        return None
    finally:
        if conn is not None:
            try:
                conn.close()
            except sqlite3.Error:
                pass


def lookup_opencode_model(session_id: str, db_path: Path) -> str | None:
    """Look up the live model ID for an OpenCode session from opencode.db."""
    if not session_id or not db_path.is_file():
        return None
    conn = None
    try:
        conn = _connect_ro(db_path)
        # Prefer the most recent assistant message's modelID (tracks mid-session switches).
        try:
            row = conn.execute(
                "SELECT json_extract(data, '$.modelID') "
                "FROM message "
                "WHERE session_id = ? AND json_extract(data, '$.role') = 'assistant' "
                "ORDER BY time_created DESC LIMIT 1",
                (session_id,),
            ).fetchone()
            if row and isinstance(row[0], str) and row[0].strip():
                return row[0].strip()
        except sqlite3.Error:
            pass

        # Fallback: session.model JSON ({"id": "...", "providerID": "..."}).
        row = conn.execute(
            "SELECT model FROM session WHERE id = ?",
            (session_id,),
        ).fetchone()
        if not row or not row[0]:
            return None
        raw = row[0]
        if isinstance(raw, str):
            try:
                parsed = json.loads(raw)
                if isinstance(parsed, dict):
                    mid = parsed.get("id") or parsed.get("modelID")
                    if isinstance(mid, str) and mid.strip():
                        return mid.strip()
            except json.JSONDecodeError:
                if raw.strip():
                    return raw.strip()
        return None
    except (sqlite3.Error, OSError, TypeError):
        return None
    finally:
        if conn is not None:
            try:
                conn.close()
            except sqlite3.Error:
                pass


def _resolve_goose_db_path(env: Mapping[str, str], override: str | None) -> Path:
    """Resolve goose's sessions.db path, honouring GOOSE_SESSIONS_DB, GOOSE_PATH_ROOT, and XDG_DATA_HOME."""
    if override:
        return Path(override).expanduser()
    if env.get("GOOSE_SESSIONS_DB"):
        return Path(env["GOOSE_SESSIONS_DB"]).expanduser()
    if env.get("GOOSE_PATH_ROOT"):
        return Path(env["GOOSE_PATH_ROOT"]).expanduser() / "data" / "sessions" / "sessions.db"
    if env.get("XDG_DATA_HOME"):
        return Path(env["XDG_DATA_HOME"]).expanduser() / "goose" / "sessions" / "sessions.db"
    return Path(DEFAULT_GOOSE_DB).expanduser()


def resolve_family(
    *,
    env: Mapping[str, str] = os.environ,
    harness: str | None = None,
    session_id: str | None = None,
    goose_db: str | None = None,
    opencode_db: str | None = None,
) -> str | None:
    """Resolve the active session's model family from environment + local session DB."""
    if harness is None:
        if env.get("AGENT_SESSION_ID"):
            harness = "goose"
            session_id = session_id or env.get("AGENT_SESSION_ID")
        elif env.get("OPENCODE_SESSION_ID"):
            harness = "opencode"
            session_id = session_id or env.get("OPENCODE_SESSION_ID")
        else:
            return None
    elif harness == "goose":
        session_id = session_id or env.get("AGENT_SESSION_ID")
    elif harness == "opencode":
        session_id = session_id or env.get("OPENCODE_SESSION_ID")
    else:
        return None

    if not session_id:
        return None

    if harness == "goose":
        raw_model = lookup_goose_model(session_id, _resolve_goose_db_path(env, goose_db))
    else:
        db_str = opencode_db or env.get("OPENCODE_DB") or DEFAULT_OPENCODE_DB
        raw_model = lookup_opencode_model(session_id, Path(db_str).expanduser())

    return classify_model_family(raw_model)


def rewrite_signature(text: str, family: str | None) -> str:
    """If the last non-blank line of text is a standalone model signature, swap its model name."""
    if not text or not family:
        return text
    lines = text.splitlines(keepends=True)
    last_idx = None
    for idx in range(len(lines) - 1, -1, -1):
        if lines[idx].strip():
            last_idx = idx
            break
    if last_idx is None:
        return text

    m = _SIGNATURE_LINE_RE.match(lines[last_idx])
    if not m:
        return text

    lines[last_idx] = f"{m.group(1)}{family}{m.group(3)}"
    return "".join(lines)


def _add_lookup_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--harness", choices=("goose", "opencode"), default=None)
    parser.add_argument("--session-id", default=None)
    parser.add_argument("--goose-db", default=None)
    parser.add_argument("--opencode-db", default=None)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="agent-model-signature",
        description="Resolve active agent model family and rewrite trailing signatures.",
    )
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_fam = sub.add_parser("family", help="Print the active session's model family.")
    _add_lookup_args(p_fam)

    p_rew = sub.add_parser(
        "rewrite",
        help="Rewrite a trailing model signature on stdin to match the active model family.",
    )
    _add_lookup_args(p_rew)
    p_rew.add_argument("--family", default=None, help="Explicit model family or model ID.")

    args = parser.parse_args(argv)

    if args.cmd == "family":
        fam = resolve_family(
            harness=args.harness,
            session_id=args.session_id,
            goose_db=args.goose_db,
            opencode_db=args.opencode_db,
        )
        if not fam:
            return 1
        sys.stdout.write(f"{fam}\n")
        return 0

    if args.cmd == "rewrite":
        body = sys.stdin.read()
        fam: str | None
        if args.family:
            fam = classify_model_family(args.family)
        else:
            fam = resolve_family(
                harness=args.harness,
                session_id=args.session_id,
                goose_db=args.goose_db,
                opencode_db=args.opencode_db,
            )
        sys.stdout.write(rewrite_signature(body, fam))
        return 0

    return 2


if __name__ == "__main__":
    raise SystemExit(main())
