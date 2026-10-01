#!/usr/bin/env python3
"""oc-revive: revive an opencode session whose worktree directory was deleted."""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import re
import signal
import sqlite3
import subprocess
import sys
import time
import urllib.error
import urllib.request
from typing import Any

DEFAULT_DB_PATH = "~/.local/share/opencode/opencode.db"
DEFAULT_FRONTDOOR_URL = "http://127.0.0.1:4700"

# MOVE_TIMEOUT_SECONDS derived as:
# door_forward (60s) + door_resolve_worst_case (~15s) + margin (15s) = 90s
# The door validates and forwards to upstream with a 60s timeout, but prior to
# forwarding it runs owner resolution which in worst-case takes ~15s (pigeon retry + root walk).
# Hence a client timeout strictly >= 90s is required so the client never times out
# while the door is still awaiting upstream resolution.
DOOR_FORWARD_TIMEOUT_SECONDS = 60
DOOR_RESOLVE_WORST_CASE_SECONDS = 15
TIMEOUT_MARGIN_SECONDS = 15
MOVE_TIMEOUT_SECONDS = (
    DOOR_FORWARD_TIMEOUT_SECONDS + DOOR_RESOLVE_WORST_CASE_SECONDS + TIMEOUT_MARGIN_SECONDS
)
LOCK_TIMEOUT_SECONDS = 15


def get_lock_timeout_seconds() -> float:
    val = os.environ.get("OPENCODE_LOCK_TIMEOUT_SECONDS")
    if val:
        try:
            return float(val)
        except ValueError:
            pass
    return float(LOCK_TIMEOUT_SECONDS)


class ReviveError(Exception):
    """Raised when revival planning or application fails."""


def compute_base_slug(slug: str) -> str:
    """Strip any trailing -r\\d{10} so repeated revives produce base-r<new>, not base-r1-r2."""
    return re.sub(r"-r\d{10}$", "", slug)


def sanitize_slug(slug: str) -> str:
    """Sanitize slug per git-work's sanitize_branch rule: s/[^A-Za-z0-9._/-]/-/g."""
    return re.sub(r"[^A-Za-z0-9._/-]", "-", slug)


def get_git_worktrees(repo: str) -> set[str]:
    """Return all worktree paths from git worktree list --porcelain, including prunable ones."""
    res = subprocess.run(
        ["git", "worktree", "list", "--porcelain"],
        cwd=repo,
        capture_output=True,
        text=True,
        check=True,
    )
    paths = set()
    for line in res.stdout.splitlines():
        if line.startswith("worktree "):
            paths.add(line[len("worktree ") :].strip())
    return paths


def get_worktree_entries(repo: str) -> list[dict[str, Any]]:
    """Parse git worktree list --porcelain into a list of entry dicts."""
    res = subprocess.run(
        ["git", "worktree", "list", "--porcelain"],
        cwd=repo,
        capture_output=True,
        text=True,
        check=True,
    )
    entries: list[dict[str, Any]] = []
    current: dict[str, Any] = {}
    for line in res.stdout.splitlines():
        line = line.strip()
        if not line:
            if current:
                entries.append(current)
                current = {}
            continue
        if line.startswith("worktree "):
            if current:
                entries.append(current)
                current = {}
            current["path"] = line[len("worktree ") :].strip()
            current["branch"] = None
            current["prunable"] = False
        elif line.startswith("branch refs/heads/"):
            current["branch"] = line[len("branch refs/heads/") :].strip()
        elif line.startswith("prunable"):
            current["prunable"] = True
    if current:
        entries.append(current)
    return entries


def get_checked_out_branches(repo: str) -> set[str]:
    """Return branch names currently checked out in any non-prunable worktree (including root)."""
    branches = set()
    for entry in get_worktree_entries(repo):
        if not entry.get("prunable") and entry.get("branch"):
            branches.add(entry["branch"])
    return branches


def get_branch_to_active_worktree(repo: str) -> dict[str, str]:
    """Return a mapping of branch name -> active (non-prunable) worktree path."""
    mapping: dict[str, str] = {}
    for entry in get_worktree_entries(repo):
        if not entry.get("prunable") and entry.get("branch") and entry.get("path"):
            mapping[entry["branch"]] = entry["path"]
    return mapping


def get_trunk_branch(repo: str) -> str | None:
    """Resolve the trunk branch (origin/HEAD short name, minus 'origin/'). Prints empty on failure."""
    res = subprocess.run(
        ["git", "symbolic-ref", "--short", "refs/remotes/origin/HEAD"],
        cwd=repo,
        capture_output=True,
        text=True,
    )
    if res.returncode == 0 and res.stdout.strip():
        out = res.stdout.strip()
        if out.startswith("origin/"):
            return out[len("origin/") :]
        return out
    # Fallback to local main / master if origin/HEAD is not configured
    for cand in ("main", "master"):
        check = subprocess.run(
            ["git", "rev-parse", "--verify", "--quiet", f"refs/heads/{cand}"],
            cwd=repo,
            capture_output=True,
        )
        if check.returncode == 0:
            return cand
    return None


def get_primary_root_branch(repo: str) -> str | None:
    """Return the branch currently checked out in the primary root repo."""
    res = subprocess.run(
        ["git", "symbolic-ref", "--short", "HEAD"],
        cwd=repo,
        capture_output=True,
        text=True,
    )
    if res.returncode == 0 and res.stdout.strip():
        return res.stdout.strip()
    return None


def is_path_referenced_in_db(conn: sqlite3.Connection, path: str) -> bool:
    """Check if path or any subdirectory of it is referenced by any session row."""
    cur = conn.cursor()
    paths_to_check = {path, os.path.realpath(path)}
    for p in paths_to_check:
        cur.execute(
            "SELECT 1 FROM session WHERE directory = ? OR directory LIKE ? || '/%' LIMIT 1",
            (p, p),
        )
        if cur.fetchone() is not None:
            return True
    return False


def choose_revive_path(
    repo: str,
    dead_dir: str,
    db_conn: sqlite3.Connection,
    start_epoch: int | None = None,
) -> str:
    """Choose a revive path P = <repo>/.worktrees/<base>-r<epoch+k> that has never been seen by any serve."""
    base = compute_base_slug(os.path.basename(dead_dir))
    worktrees_dir = os.path.join(repo, ".worktrees")
    epoch = start_epoch if start_epoch is not None else int(time.time())

    wt_paths = get_git_worktrees(repo)
    wt_realpaths = {os.path.realpath(p) for p in wt_paths}
    dead_dir_real = os.path.realpath(dead_dir)

    k = 0
    while True:
        candidate = os.path.join(worktrees_dir, f"{base}-r{epoch + k}")
        cand_real = os.path.realpath(candidate)

        # 1. Never the dead dir
        if candidate == dead_dir or cand_real == dead_dir_real:
            k += 1
            continue

        # 2. Absent on disk
        if os.path.exists(candidate) or os.path.islink(candidate):
            k += 1
            continue

        # 3. Absent from git worktree list --porcelain (including prunable)
        if candidate in wt_paths or cand_real in wt_realpaths:
            k += 1
            continue

        # 4. Not referenced by ANY session row (literal or realpath)
        if is_path_referenced_in_db(db_conn, candidate):
            k += 1
            continue

        return candidate


# Matches [branch sha], [branch (root-commit) sha], or [detached HEAD sha]
COMMIT_OUTPUT_RE = re.compile(
    r"\[(?:(detached HEAD)|([^\s\]]+)(?:\s+\(root-commit\))?)\s+([0-9a-fA-F]{7,40})\]"
)


def extract_last_commit_evidence(
    db_conn: sqlite3.Connection,
    session_id: str,
) -> tuple[str, str] | None:
    """Extract the LAST (branch, sha) from the session's bash tool outputs, ignoring detached HEAD."""
    cur = db_conn.cursor()
    cur.execute(
        "SELECT data FROM part WHERE session_id = ? ORDER BY time_created ASC, id ASC",
        (session_id,),
    )
    last_evidence = None
    for (data_raw,) in cur.fetchall():
        try:
            data = json.loads(data_raw)
        except Exception:
            continue

        output = None
        if isinstance(data.get("state"), dict):
            output = data["state"].get("output")
        if output is None:
            output = data.get("output")
        if output is None and data.get("tool") == "bash":
            output = data.get("text")

        if not isinstance(output, str):
            continue

        for m in COMMIT_OUTPUT_RE.finditer(output):
            if m.group(1):  # detached HEAD
                continue
            branch = m.group(2)
            sha = m.group(3)
            if branch in ("detached", "HEAD"):
                continue
            last_evidence = (branch, sha)

    return last_evidence


def is_branch_merged(repo: str, tip_sha: str, trunk: str | None) -> bool:
    """Check if tip_sha is an ancestor of origin/<trunk> or local trunk."""
    if not trunk:
        return False
    origin_trunk = f"origin/{trunk}"
    has_origin = subprocess.run(
        ["git", "rev-parse", "--verify", "--quiet", origin_trunk],
        cwd=repo,
        capture_output=True,
    ).returncode == 0
    ref_to_check = origin_trunk if has_origin else f"refs/heads/{trunk}"

    res = subprocess.run(
        ["git", "merge-base", "--is-ancestor", tip_sha, ref_to_check],
        cwd=repo,
        capture_output=True,
    )
    return res.returncode == 0


def find_branch_candidates(
    repo: str,
    session_id: str,
    dead_dir: str,
    db_conn: sqlite3.Connection,
) -> list[dict[str, Any]]:
    """Find and validate branch candidates for reviving dead_dir."""
    slug = os.path.basename(dead_dir)
    slug_branch = sanitize_slug(slug)

    # 1. Rule 1: slug-based branch
    slug_cand = None
    has_slug_branch = subprocess.run(
        ["git", "rev-parse", "--verify", "--quiet", f"refs/heads/{slug_branch}"],
        cwd=repo,
        capture_output=True,
    ).returncode == 0
    if has_slug_branch:
        slug_cand = slug_branch

    # 2. Rule 2: bash-evidence branch
    evidence = extract_last_commit_evidence(db_conn, session_id)
    bash_cand = None
    if evidence:
        ev_branch, ev_sha = evidence
        has_ev_branch = subprocess.run(
            ["git", "rev-parse", "--verify", "--quiet", f"refs/heads/{ev_branch}"],
            cwd=repo,
            capture_output=True,
        ).returncode == 0
        if has_ev_branch:
            is_ancestor = subprocess.run(
                ["git", "merge-base", "--is-ancestor", ev_sha, f"refs/heads/{ev_branch}"],
                cwd=repo,
                capture_output=True,
            ).returncode == 0
            if is_ancestor:
                bash_cand = ev_branch

    # Union candidates
    raw_candidates: list[tuple[str, str]] = []  # (branch, source)
    if slug_cand and bash_cand:
        if slug_cand == bash_cand:
            raw_candidates.append((slug_cand, "both"))
        else:
            raw_candidates.append((slug_cand, "slug"))
            raw_candidates.append((bash_cand, "bash-evidence"))
    elif slug_cand:
        raw_candidates.append((slug_cand, "slug"))
    elif bash_cand:
        raw_candidates.append((bash_cand, "bash-evidence"))

    trunk = get_trunk_branch(repo)
    primary_root_branch = get_primary_root_branch(repo)
    checked_out_branches = get_checked_out_branches(repo)

    candidates: list[dict[str, Any]] = []
    for branch, source in raw_candidates:
        if trunk and branch == trunk:
            continue
        if primary_root_branch and branch == primary_root_branch:
            continue
        if branch in checked_out_branches:
            continue

        tip_res = subprocess.run(
            ["git", "rev-parse", f"refs/heads/{branch}"],
            cwd=repo,
            capture_output=True,
            text=True,
            check=True,
        )
        tip_sha = tip_res.stdout.strip()

        tip_short = subprocess.run(
            ["git", "log", "-1", "--format=%h", f"refs/heads/{branch}"],
            cwd=repo,
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()

        subject = subprocess.run(
            ["git", "log", "-1", "--format=%s", f"refs/heads/{branch}"],
            cwd=repo,
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()

        tip_ct = subprocess.run(
            ["git", "log", "-1", "--format=%cI", f"refs/heads/{branch}"],
            cwd=repo,
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()

        merged = is_branch_merged(repo, tip_sha, trunk)
        revive_p = choose_revive_path(repo, dead_dir, db_conn)

        candidates.append({
            "branch": branch,
            "source": source,
            "tip": tip_sha,
            "tip_short": tip_short,
            "subject": subject,
            "tip_ct": tip_ct,
            "merged": merged,
            "action": "add",
            "path": revive_p,
        })

    return candidates


DEFAULT_BUSY_THRESHOLD_SECONDS = 600


def get_busy_threshold_seconds() -> float:
    val = os.environ.get("OPENCODE_BUSY_THRESHOLD_SECONDS") or os.environ.get("OPENCODE_BUSY_THRESHOLD")
    if val:
        try:
            return float(val)
        except ValueError:
            pass
    return float(DEFAULT_BUSY_THRESHOLD_SECONDS)


def is_session_busy(
    conn: sqlite3.Connection,
    sid: str,
    threshold_seconds: float | None = None,
    now: float | None = None,
) -> bool:
    """Detect if the session is currently busy mid-turn.

    CHEAP GUARD, NOT A PROOF OF IDLENESS:
    This check is a cheap heuristic guard against reviving a session while a turn
    is actively being processed. It does NOT prove that a session is truly idle or
    that a turn will not be initiated immediately after checking.

    WHAT THIS DETECTOR PROVES:
    - If the newest message for this session has role='assistant' and has no completion
      timestamp (time.completed is null/absent), no error, and no finish status recorded,
      AND the message was created recently (younger than threshold_seconds, default 600s),
      the database reflects an active assistant turn that has not concluded.

    WHAT THIS DETECTOR DOES NOT PROVE:
    - It does NOT prove that a serve process is currently running or executing CPU instructions
      for this turn (e.g. an unfinalized message could belong to a dead serve or crashed worker).
    - It does NOT prove that an idle session will remain idle (a new turn could arrive right after
      the check).
    - It does NOT see in-flight turns before their initial message row is committed to SQLite.

    DELIBERATE FALSE NEGATIVES:
    - Incomplete assistant message older than the staleness threshold (default 600s):
      Treated as an abandoned turn (e.g. serve died mid-turn). Allowing revival prevents
      permanent deadlocks where an orphaned session can never be revived.
    - Trailing role='user' message:
      On a dead session (whose git worktree directory was deleted), a trailing user message
      typically means the prompt returned 204 and no assistant reply ever came — which is
      the dead state itself, NOT an in-flight live turn. Treating it as busy would permanently
      refuse revival of such sessions (measured 2/3684 dead sessions in this state on 2026-10-01).
      A genuinely in-flight user turn is near-impossible on a session whose cwd is already gone,
      because new turns cannot start there. DO NOT "fix" this by marking role='user' as busy.
    """
    cur = conn.cursor()
    cur.execute(
        "SELECT time_created, data FROM message WHERE session_id = ? ORDER BY time_created DESC, id DESC LIMIT 1",
        (sid,),
    )
    row = cur.fetchone()
    if not row:
        return False
    raw_time_created, data_raw = row
    try:
        data = json.loads(data_raw)
    except Exception:
        return False

    # Do NOT treat trailing role='user' as busy (see DELIBERATE FALSE NEGATIVES above).
    if data.get("role") != "assistant":
        return False

    time_info = data.get("time") or {}
    completed = time_info.get("completed")
    error = data.get("error")
    finish = data.get("finish")
    if completed or error or finish:
        return False

    # Incomplete assistant message: check staleness window using max(time_updated)
    # across that session's messages and parts — and its children's.
    cur.execute(
        """
        WITH RECURSIVE sids(id) AS (
            VALUES (?)
            UNION ALL
            SELECT s.id FROM session s JOIN sids ON s.parent_id = sids.id
        )
        SELECT MAX(tu) FROM (
            SELECT MAX(time_updated) AS tu FROM message WHERE session_id IN (SELECT id FROM sids)
            UNION ALL
            SELECT MAX(time_updated) AS tu FROM part WHERE session_id IN (SELECT id FROM sids)
        )
        """,
        (sid,),
    )
    max_tu_row = cur.fetchone()
    max_tu = max_tu_row[0] if max_tu_row else None

    if max_tu is not None:
        last_activity_raw = max_tu
    else:
        last_activity_raw = raw_time_created
        if last_activity_raw is None:
            last_activity_raw = time_info.get("created")

    if last_activity_raw is not None:
        last_activity_sec = (
            last_activity_raw / 1000.0 if last_activity_raw > 1e11 else float(last_activity_raw)
        )
    else:
        last_activity_sec = 0.0

    curr_time = now if now is not None else time.time()
    thresh = threshold_seconds if threshold_seconds is not None else get_busy_threshold_seconds()

    age = curr_time - last_activity_sec
    # If younger than threshold, it is considered active/busy.
    # If older, it is an abandoned turn and thus NOT busy.
    if age < thresh:
        return True
    return False


def get_db_connection(db_path: str | None = None) -> sqlite3.Connection:
    """Open opencode.db read-only with a 10s timeout."""
    path = db_path or os.environ.get("OPENCODE_DB", DEFAULT_DB_PATH)
    expanded = os.path.abspath(os.path.expanduser(path))
    conn = sqlite3.connect(f"file:{expanded}?mode=ro", uri=True, timeout=10)
    conn.isolation_level = None
    return conn


def plan_revive(sid: str, db_path: str | None = None) -> dict[str, Any]:
    """Plan revival of session sid. Returns plan dictionary."""
    conn = get_db_connection(db_path)
    try:
        cur = conn.cursor()
        cur.execute(
            "SELECT id, project_id, parent_id, directory, title FROM session WHERE id = ?",
            (sid,),
        )
        row = cur.fetchone()
        if not row:
            return {
                "revivable": False,
                "reason": f"session_not_found: session '{sid}' not found in database",
                "sid": sid,
                "dead_dir": None,
                "repo": None,
                "snapshot": None,
                "candidates": [],
            }

        _id, project_id, parent_id, dead_dir, _title = row

        # Guard: child session
        if parent_id is not None:
            return {
                "revivable": False,
                "reason": f"child_session: session '{sid}' is a child session (parent_id={parent_id})",
                "sid": sid,
                "dead_dir": dead_dir,
                "repo": None,
                "snapshot": None,
                "candidates": [],
            }

        # Guard: directory still exists
        if dead_dir and os.path.exists(dead_dir):
            return {
                "revivable": False,
                "reason": f"directory_exists: directory '{dead_dir}' still exists on disk",
                "sid": sid,
                "dead_dir": dead_dir,
                "repo": None,
                "snapshot": None,
                "candidates": [],
            }

        # Guard: dead directory must be exactly <repo>/.worktrees/<single-segment>
        if not dead_dir:
            return {
                "revivable": False,
                "reason": "invalid_directory_shape: session directory is empty or null",
                "sid": sid,
                "dead_dir": None,
                "repo": None,
                "snapshot": None,
                "candidates": [],
            }

        norm_dead_dir = os.path.normpath(os.path.abspath(dead_dir))
        wt_parent = os.path.dirname(norm_dead_dir)
        repo_dir = os.path.dirname(wt_parent)
        single_segment = os.path.basename(norm_dead_dir)

        if (
            os.path.basename(wt_parent) != ".worktrees"
            or not single_segment
            or single_segment in (".", "..")
            or "/" in single_segment
            or os.path.join(repo_dir, ".worktrees", single_segment) != norm_dead_dir
        ):
            return {
                "revivable": False,
                "reason": f"invalid_directory_shape: directory '{dead_dir}' is not shaped as <repo>/.worktrees/<single-segment>",
                "sid": sid,
                "dead_dir": dead_dir,
                "repo": repo_dir,
                "snapshot": None,
                "candidates": [],
            }

        # Guard: repo must exist and be a git repository
        if not os.path.isdir(repo_dir):
            return {
                "revivable": False,
                "reason": f"not_a_git_repo: enclosing repository '{repo_dir}' does not exist",
                "sid": sid,
                "dead_dir": dead_dir,
                "repo": repo_dir,
                "snapshot": None,
                "candidates": [],
            }

        git_check = subprocess.run(
            ["git", "-C", repo_dir, "rev-parse", "--git-dir"],
            capture_output=True,
        )
        if git_check.returncode != 0:
            return {
                "revivable": False,
                "reason": f"not_a_git_repo: enclosing directory '{repo_dir}' is not a git repository",
                "sid": sid,
                "dead_dir": dead_dir,
                "repo": repo_dir,
                "snapshot": None,
                "candidates": [],
            }

        # Guard: busy session
        if is_session_busy(conn, sid):
            return {
                "revivable": False,
                "reason": f"busy_session: session '{sid}' has an unfinalized assistant turn in progress",
                "sid": sid,
                "dead_dir": dead_dir,
                "repo": repo_dir,
                "snapshot": None,
                "candidates": [],
            }

        # Snapshot reporting
        snapshot_base = os.environ.get(
            "OPENCODE_SNAPSHOT_DIR",
            os.path.expanduser("~/.local/share/opencode/snapshot"),
        )
        sha1_dead_dir = hashlib.sha1(dead_dir.encode("utf-8")).hexdigest()
        snapshot_path = os.path.join(snapshot_base, project_id or "", sha1_dead_dir)
        snapshot = {
            "exists": os.path.exists(snapshot_path),
            "path": snapshot_path,
        }

        # Branch candidates
        candidates = find_branch_candidates(repo_dir, sid, dead_dir, conn)
        if not candidates:
            # Check if blocked by a prior revive worktree matching <base>-r\d{10}
            base = compute_base_slug(os.path.basename(dead_dir))
            pattern = rf"^{re.escape(base)}-r\d{{10}}$"
            branch_to_wt = get_branch_to_active_worktree(repo_dir)

            slug_branch = sanitize_slug(os.path.basename(dead_dir))
            evidence = extract_last_commit_evidence(conn, sid)
            raw_branches = [slug_branch]
            if evidence and evidence[0] not in raw_branches:
                raw_branches.append(evidence[0])

            blocking_reason = None
            for b in raw_branches:
                if b in branch_to_wt:
                    wt_p = branch_to_wt[b]
                    if re.match(pattern, os.path.basename(wt_p)):
                        is_ref = is_path_referenced_in_db(conn, wt_p)
                        blocking_reason = (
                            f"blocked_by_worktree: branch '{b}' is checked out at '{wt_p}' "
                            f"(session row references it: {is_ref})"
                        )
                        break

            reason = blocking_reason or "no_candidates: zero branch candidates survive validation"
            return {
                "revivable": False,
                "reason": reason,
                "sid": sid,
                "dead_dir": dead_dir,
                "repo": repo_dir,
                "snapshot": snapshot,
                "candidates": [],
            }

        return {
            "revivable": True,
            "reason": None,
            "sid": sid,
            "dead_dir": dead_dir,
            "repo": repo_dir,
            "snapshot": snapshot,
            "candidates": candidates,
        }
    finally:
        conn.close()


def fetch_door_session(frontdoor_url: str, sid: str) -> dict[str, Any]:
    """Fetch session info from front door GET /session/<sid>."""
    url = f"{frontdoor_url.rstrip('/')}/session/{sid}"
    req = urllib.request.Request(url, headers={"Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=15) as resp:
        return json.loads(resp.read().decode("utf-8"))


def rollback_if_safe(
    repo: str,
    target_p: str,
    db_conn: sqlite3.Connection,
    sid: str,
    frontdoor_url: str,
) -> bool:
    """Roll back worktree creation ONLY if created AND session is not at P AND no session row references P."""
    cur = db_conn.cursor()
    cur.execute("SELECT directory FROM session WHERE id = ?", (sid,))
    row = cur.fetchone()
    if row and row[0] == target_p:
        return False

    try:
        door_sess = fetch_door_session(frontdoor_url, sid)
        if door_sess.get("directory") == target_p:
            return False
    except Exception:
        pass

    if is_path_referenced_in_db(db_conn, target_p):
        return False

    subprocess.run(
        ["git", "-C", repo, "worktree", "remove", "--force", target_p],
        capture_output=True,
    )
    return True


def apply_revive(
    sid: str,
    branch: str,
    path: str,
    action: str,
    expect_tip: str,
    expect_old_dir: str,
    db_path: str | None = None,
    frontdoor_url: str | None = None,
) -> dict[str, Any]:
    """Execute revival of session sid onto branch at path."""
    if action != "add":
        raise ReviveError(f"Action '{action}' not permitted. Only 'add' is supported in v1.")

    door_url = frontdoor_url or os.environ.get("OPENCODE_FRONTDOOR_URL", DEFAULT_FRONTDOOR_URL)
    conn = get_db_connection(db_path)
    try:
        cur = conn.cursor()
        cur.execute(
            "SELECT id, project_id, parent_id FROM session WHERE id = ?",
            (sid,),
        )
        row = cur.fetchone()
        if not row:
            raise ReviveError(f"Session '{sid}' not found in database")
        _id, project_id, parent_id = row

        if parent_id is not None:
            raise ReviveError(f"Session '{sid}' is a child session (parent_id={parent_id})")

        target_p = os.path.normpath(os.path.abspath(path))
        if os.path.realpath(expect_old_dir) == os.path.realpath(target_p):
            raise ReviveError(
                f"Invalid arguments: expect_old_dir '{expect_old_dir}' cannot be identical to target path '{target_p}'"
            )
        wt_dir = os.path.dirname(target_p)
        repo = os.path.dirname(wt_dir)

        if not os.path.isdir(repo):
            raise ReviveError(f"Repo directory '{repo}' not found")

        res = subprocess.run(
            ["git", "-C", repo, "rev-parse", "--git-common-dir"],
            capture_output=True,
            text=True,
            check=True,
        )
        git_common = res.stdout.strip()
        if not os.path.isabs(git_common):
            git_common = os.path.normpath(os.path.join(repo, git_common))
        lock_path = os.path.join(git_common, "oc-revive.lock")

        lock_fd = os.open(lock_path, os.O_CREAT | os.O_RDWR)
        lock_timeout = get_lock_timeout_seconds()
        start_lock = time.time()
        locked = False
        try:
            while not locked:
                try:
                    fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    locked = True
                except (BlockingIOError, OSError):
                    if time.time() - start_lock > lock_timeout:
                        raise ReviveError(f"Timed out waiting for lock on {lock_path}")
                    time.sleep(0.05)

            # Step 1: Idempotent retry check
            cur.execute("SELECT directory FROM session WHERE id = ?", (sid,))
            fresh_row = cur.fetchone()
            fresh_dir = fresh_row[0] if fresh_row else None

            target_p_real = os.path.realpath(target_p)
            expect_old_real = os.path.realpath(expect_old_dir) if expect_old_dir else None
            fresh_real = os.path.realpath(fresh_dir) if fresh_dir else None

            if fresh_dir == target_p or (fresh_real and fresh_real == target_p_real):
                already_moved = True
            elif fresh_dir == expect_old_dir or (fresh_real and fresh_real == expect_old_real):
                already_moved = False
            else:
                raise ReviveError(
                    f"directory-mismatch: session directory '{fresh_dir}' is neither target path '{target_p}' nor expected old directory '{expect_old_dir}'"
                )

            created = False
            if not already_moved:
                # Schema-drift tripwire: require door's GET /session/<sid> to report directory == expect_old_dir
                try:
                    door_sess = fetch_door_session(door_url, sid)
                except Exception as e:
                    raise ReviveError(f"Failed to query session from door at {door_url}: {e}")
                door_dir = door_sess.get("directory")
                door_dir_real = os.path.realpath(door_dir) if door_dir else None
                if door_dir != expect_old_dir and (not door_dir_real or door_dir_real != expect_old_real):
                    raise ReviveError(
                        f"Door reports session directory '{door_dir}', expected '{expect_old_dir}'"
                    )

                # Check busy inside the lock
                if is_session_busy(conn, sid):
                    raise ReviveError(f"busy_session: session '{sid}' has an unfinalized assistant turn in progress")

                # Step 2: Re-validate inside the lock
                if os.path.exists(target_p):
                    raise ReviveError(f"plan-changed: target path '{target_p}' already exists on disk")

                wt_paths = get_git_worktrees(repo)
                wt_realpaths = {os.path.realpath(p) for p in wt_paths}
                if target_p in wt_paths or os.path.realpath(target_p) in wt_realpaths:
                    raise ReviveError(f"plan-changed: target path '{target_p}' is in git worktree list")

                if is_path_referenced_in_db(conn, target_p):
                    raise ReviveError(f"plan-changed: target path '{target_p}' is referenced in session DB")

                tip_check = subprocess.run(
                    ["git", "-C", repo, "rev-parse", f"refs/heads/{branch}"],
                    capture_output=True,
                    text=True,
                )
                if tip_check.returncode != 0 or tip_check.stdout.strip() != expect_tip:
                    actual = tip_check.stdout.strip() if tip_check.returncode == 0 else "missing"
                    raise ReviveError(
                        f"plan-changed: branch '{branch}' tip changed (expected {expect_tip}, got {actual})"
                    )

                # Step 3: git worktree prune
                subprocess.run(
                    ["git", "-C", repo, "worktree", "prune"],
                    check=True,
                    capture_output=True,
                )

                # Step 4: git worktree add P B (no -b, no --force)
                subprocess.run(
                    ["git", "-C", repo, "worktree", "add", target_p, branch],
                    check=True,
                    capture_output=True,
                )
                created = True

            reconcile_cmd = (
                f"oc-revive apply {sid} --branch {branch} --path {target_p} "
                f"--action add --expect-tip {expect_tip} --expect-old-dir {expect_old_dir}"
            )
            post_sent = False
            reconcile_printed = False

            def print_reconcile() -> None:
                nonlocal reconcile_printed
                if post_sent and not reconcile_printed:
                    print(f"To reconcile, run:\n  {reconcile_cmd}", file=sys.stderr)
                    reconcile_printed = True

            # Steps 5-8 must survive SIGTERM, SIGINT, SIGHUP
            received_signal: int | None = None

            def handle_signal(signum: int, frame: Any) -> None:
                nonlocal received_signal
                received_signal = signum

            old_handlers = {}
            for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
                try:
                    old_handlers[sig] = signal.signal(sig, handle_signal)
                except (ValueError, OSError):
                    pass

            try:
                if not already_moved:
                    # Step 5: The move POST $DOOR/session/<sid>/move
                    move_url = f"{door_url.rstrip('/')}/session/{sid}/move"
                    move_payload = json.dumps({"destination": {"directory": target_p}}).encode("utf-8")
                    move_req = urllib.request.Request(
                        move_url,
                        data=move_payload,
                        headers={"Content-Type": "application/json"},
                        method="POST",
                    )

                    post_sent = True
                    move_status = None
                    move_err_msg = ""
                    try:
                        with urllib.request.urlopen(move_req, timeout=MOVE_TIMEOUT_SECONDS) as resp:
                            move_status = resp.status
                    except urllib.error.HTTPError as e:
                        move_status = e.code
                        try:
                            move_err_msg = e.read().decode("utf-8")
                        except Exception:
                            pass
                    except Exception as e:
                        move_status = 599
                        move_err_msg = str(e)

                    if move_status and 400 <= move_status < 500:
                        is_door_generated = False
                        try:
                            err_obj = json.loads(move_err_msg)
                            if isinstance(err_obj, dict) and err_obj.get("error") in ("bad_request", "payload_too_large"):
                                is_door_generated = True
                        except Exception:
                            pass

                        if is_door_generated:
                            rollback_if_safe(repo, target_p, conn, sid, door_url)
                            raise ReviveError(f"Door returned {move_status}: {move_err_msg}")
                        else:
                            raise ReviveError(f"Upstream returned {move_status}: {move_err_msg}")

                    if move_status != 204:
                        raise ReviveError(
                            f"Move outcome ambiguous: door returned {move_status}: {move_err_msg}"
                        )

                    # Step 6: Verify GET $DOOR/session/<sid> -> directory == P
                    verified = False
                    try:
                        sess_info = fetch_door_session(door_url, sid)
                        if sess_info.get("directory") == target_p:
                            verified = True
                    except Exception:
                        pass

                    if not verified:
                        raise ReviveError(
                            f"Move outcome ambiguous: session directory not verified at '{target_p}'"
                        )

                # Step 7: Notice
                notice_sent = True
                notice_error = None
                marker = f"oc-revive-marker: {sid} {target_p}"
                cur.execute(
                    "SELECT data FROM part WHERE session_id = ? AND instr(data, ?) > 0",
                    (sid, marker),
                )
                if not cur.fetchone():
                    cur.execute(
                        "SELECT data FROM message WHERE session_id = ? ORDER BY time_created DESC, id DESC",
                        (sid,),
                    )
                    user_agent = None
                    user_model = None
                    for (m_data_raw,) in cur.fetchall():
                        try:
                            m_data = json.loads(m_data_raw)
                            if m_data.get("role") == "user":
                                if "agent" in m_data and m_data["agent"] is not None:
                                    user_agent = m_data["agent"]
                                if "model" in m_data and m_data["model"] is not None:
                                    user_model = m_data["model"]
                                break
                        except Exception:
                            continue

                    snapshot_base = os.environ.get(
                        "OPENCODE_SNAPSHOT_DIR",
                        os.path.expanduser("~/.local/share/opencode/snapshot"),
                    )
                    sha1_dead = hashlib.sha1(expect_old_dir.encode("utf-8")).hexdigest()
                    snapshot_path = os.path.join(snapshot_base, project_id or "", sha1_dead)

                    notice_text = (
                        f"Notice: Working directory has moved to {target_p}.\n"
                        f"The previous working directory ({expect_old_dir}) was deleted and must NOT be cd'd into, "
                        f"mkdir'd, or recreated (recreating it creates zombie sessions for any siblings).\n"
                        f"Branch: {branch} (tip: {expect_tip}).\n"
                        f"Uncommitted work was NOT carried over; opencode snapshot reference: {snapshot_path}.\n"
                        f"Please verify HEAD and report what is missing rather than reconstructing from memory.\n"
                        f"Note: Subagent task_ids from prior turns point to the old directory.\n"
                        f"{marker}\n"
                    )

                    notice_body: dict[str, Any] = {
                        "noReply": True,
                        "parts": [
                            {
                                "type": "text",
                                "synthetic": True,
                                "text": notice_text,
                                "metadata": {"source": "oc-revive"},
                            }
                        ],
                    }
                    if user_agent is not None:
                        notice_body["agent"] = user_agent
                    if user_model is not None:
                        notice_body["model"] = user_model

                    prompt_url = f"{door_url.rstrip('/')}/session/{sid}/prompt_async"
                    prompt_payload = json.dumps(notice_body).encode("utf-8")
                    prompt_req = urllib.request.Request(
                        prompt_url,
                        data=prompt_payload,
                        headers={"Content-Type": "application/json"},
                        method="POST",
                    )
                    try:
                        with urllib.request.urlopen(prompt_req, timeout=15):
                            pass
                    except Exception as e:
                        print(f"WARNING: failed to send notice to {prompt_url}: {e}", file=sys.stderr)
                        notice_sent = False
                        notice_error = str(e)
                    else:
                        # Confirm it LANDED by re-reading session parts for the marker
                        landed = False
                        poll_timeout = float(os.environ.get("OPENCODE_NOTICE_POLL_TIMEOUT", "3.0"))
                        start_landed = time.time()
                        while time.time() - start_landed < poll_timeout:
                            cur.execute(
                                "SELECT 1 FROM part WHERE session_id = ? AND instr(data, ?) > 0 LIMIT 1",
                                (sid, marker),
                            )
                            if cur.fetchone():
                                landed = True
                                break
                            time.sleep(0.02)
                        if not landed:
                            print(f"WARNING: notice sent to {sid} but not yet confirmed in parts")

                # Step 8: Re-read DB row to ensure move was not undone, and assert P exists on disk
                cur.execute("SELECT directory FROM session WHERE id = ?", (sid,))
                db_row = cur.fetchone()
                db_dir = db_row[0] if db_row else None
                target_p_real = os.path.realpath(target_p)
                db_dir_real = os.path.realpath(db_dir) if db_dir else None
                if db_dir != target_p and (not db_dir_real or db_dir_real != target_p_real):
                    raise ReviveError(
                        f"Step 8 verification failed: session directory in database is '{db_dir}', expected '{target_p}'"
                    )

                if not os.path.isdir(target_p):
                    raise ReviveError(f"Target path '{target_p}' is missing on disk after move")

                return {
                    "ok": True,
                    "sid": sid,
                    "path": target_p,
                    "branch": branch,
                    "notice_sent": notice_sent,
                    "notice_error": notice_error,
                    "reconcile_cmd": reconcile_cmd,
                }
            finally:
                if sys.exc_info()[0] is not None:
                    print_reconcile()
                for sig, old_h in old_handlers.items():
                    try:
                        signal.signal(sig, old_h)
                    except (ValueError, OSError):
                        pass
                if received_signal is not None:
                    print_reconcile()
                    os.kill(os.getpid(), received_signal)

        finally:
            if locked:
                fcntl.flock(lock_fd, fcntl.LOCK_UN)
            os.close(lock_fd)
    finally:
        conn.close()


def main(argv: list[str] | None = None) -> int:
    """CLI entry point for oc-revive."""
    if argv is None:
        argv = sys.argv[1:]

    parser = argparse.ArgumentParser(
        prog="oc-revive",
        description="Revive OpenCode sessions whose git worktree directory was deleted.",
    )
    subparsers = parser.add_subparsers(dest="command")

    # plan subcommand
    plan_p = subparsers.add_parser("plan", help="Output revival plan as JSON")
    plan_p.add_argument("sid", help="Session ID")
    plan_p.add_argument("--db", help="Path to opencode.db")

    # apply subcommand
    apply_p = subparsers.add_parser("apply", help="Apply revival plan")
    apply_p.add_argument("sid", help="Session ID")
    apply_p.add_argument("--branch", required=True, help="Branch name")
    apply_p.add_argument("--path", required=True, help="New worktree path")
    apply_p.add_argument(
        "--action",
        required=True,
        choices=["add"],
        help="Action (only 'add' is supported in v1)",
    )
    apply_p.add_argument("--expect-tip", required=True, help="Expected tip commit SHA")
    apply_p.add_argument("--expect-old-dir", required=True, help="Expected dead directory")
    apply_p.add_argument("--db", help="Path to opencode.db")
    apply_p.add_argument("--frontdoor-url", help="Frontdoor URL")

    # If first argument is neither 'plan' nor 'apply' and not a help flag:
    if argv and argv[0] not in ("plan", "apply", "-h", "--help"):
        # Interactive mode: oc-revive <sid>
        sid = argv[0]
        # Parse any optional flags like --db or --frontdoor-url
        extra_parser = argparse.ArgumentParser(prog="oc-revive")
        extra_parser.add_argument("sid", help="Session ID")
        extra_parser.add_argument("--db", help="Path to opencode.db")
        extra_parser.add_argument("--frontdoor-url", help="Frontdoor URL")
        try:
            extra_args = extra_parser.parse_args(argv)
        except SystemExit as e:
            return e.code if isinstance(e.code, int) else 2

        try:
            plan = plan_revive(extra_args.sid, db_path=extra_args.db)
        except (sqlite3.Error, OSError) as e:
            print(f"Error opening database: {e}", file=sys.stderr)
            return 2
        if not plan["revivable"]:
            print(f"Session '{extra_args.sid}' cannot be revived: {plan['reason']}")
            return 0

        # Human-readable plan
        print(f"Plan for session: {plan['sid']}")
        print(f"Dead directory:   {plan['dead_dir']}")
        print(f"Repository:       {plan['repo']}")
        if plan.get("snapshot"):
            snap = plan["snapshot"]
            exists_str = "exists" if snap["exists"] else "absent"
            print(f"Snapshot ({exists_str}): {snap['path']}")

        cands = plan["candidates"]
        print(f"\nBranch candidates ({len(cands)}):")
        if len(cands) > 1:
            print("\n" + "=" * 60)
            print("WARNING: Multiple branch candidates discovered!")
            print("The slug rule and commit-evidence rule disagreed.")
            print("=" * 60 + "\n")

        for idx, c in enumerate(cands, 1):
            merged_info = ""
            if c.get("merged"):
                merged_info = " [MERGED - worktree will be swept ~7 days after session idles]"
            print(f"  [{idx}] Branch:  {c['branch']} (source: {c['source']})")
            print(f"      Tip:     {c['tip_short']} - {c['subject']} ({c['tip_ct']}){merged_info}")
            print(f"      New cwd: {c['path']}")

        print("\nNote: Uncommitted files are NOT carried over; snapshot reference above.")

        chosen_cand = cands[0]
        if len(cands) > 1:
            choice = input(f"Select candidate [1-{len(cands)}]: ").strip()
            try:
                c_idx = int(choice) - 1
                if 0 <= c_idx < len(cands):
                    chosen_cand = cands[c_idx]
                else:
                    print("Invalid candidate selection. Aborted.")
                    return 0
            except ValueError:
                print("Invalid input. Aborted.")
                return 0

        confirm = input(f"Apply revival to {chosen_cand['path']}? [y/N]: ").strip().lower()
        if confirm not in ("y", "yes"):
            print("Aborted.")
            return 0

        try:
            res = apply_revive(
                sid=extra_args.sid,
                branch=chosen_cand["branch"],
                path=chosen_cand["path"],
                action=chosen_cand["action"],
                expect_tip=chosen_cand["tip"],
                expect_old_dir=plan["dead_dir"],
                db_path=extra_args.db,
                frontdoor_url=extra_args.frontdoor_url,
            )
            if not res.get("notice_sent", True):
                print(
                    f"Partial success: session '{extra_args.sid}' moved to {res['path']}, "
                    f"but notice failed to send to agent: {res.get('notice_error', 'unknown error')}",
                    file=sys.stderr,
                )
                print(f"To reconcile, run:\n  {res['reconcile_cmd']}", file=sys.stderr)
                return 1
            print(f"Successfully revived session '{extra_args.sid}' at {res['path']}")
            return 0
        except ReviveError as e:
            print(f"Revival failed: {e}", file=sys.stderr)
            return 1

    try:
        args = parser.parse_args(argv)
    except SystemExit as e:
        return e.code if isinstance(e.code, int) else 2

    if args.command == "plan":
        try:
            plan = plan_revive(args.sid, db_path=args.db)
        except (sqlite3.Error, OSError) as e:
            print(f"Error opening database: {e}", file=sys.stderr)
            return 2
        print(json.dumps(plan, indent=2))
        return 0

    if args.command == "apply":
        try:
            res = apply_revive(
                sid=args.sid,
                branch=args.branch,
                path=args.path,
                action=args.action,
                expect_tip=args.expect_tip,
                expect_old_dir=args.expect_old_dir,
                db_path=args.db,
                frontdoor_url=args.frontdoor_url,
            )
            if not res.get("notice_sent", True):
                print(
                    f"Partial success: session '{args.sid}' moved to {res['path']}, "
                    f"but notice failed to send to agent: {res.get('notice_error', 'unknown error')}",
                    file=sys.stderr,
                )
                print(f"To reconcile, run:\n  {res['reconcile_cmd']}", file=sys.stderr)
                return 1
            print(f"Successfully revived session '{args.sid}' at {res['path']}")
            return 0
        except ReviveError as e:
            print(f"Error: {e}", file=sys.stderr)
            return 1

    parser.print_help(sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
