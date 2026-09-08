# oc-tags Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Ship `oc-tags`, a Python-stdlib CLI that tags opencode sessions and serves a stacked-area chart of list-price LLM consumption per tag, viewable from the laptop over an SSH tunnel.

**Architecture:** One `buildPythonApplication` derivation, `pkgs/oc-tags`, containing a single module `oc_tags.py`. It reads `~/.local/share/opencode/opencode.db` **read-only** and writes a sidecar `~/.local/share/oc-tags/tags.db` holding tags. Dollars come from the **stored** `message.data->>'$.cost'` — no rate book. A `serve` subcommand renders an SVG server-side with zero client JavaScript, all state in GET params.

**Tech Stack:** Python 3 stdlib only (`sqlite3`, `json`, `http.server`, `zoneinfo`, `argparse`, `unittest`). Nix `buildPythonApplication`, `format = "other"`. Tests wired as a real `flake.nix` check via `runCommand`.

**Design doc:** `docs/plans/2026-09-08-oc-tags-design.md`. Read it before starting — it records why metered dollars were rejected, why the rate book was rejected, and why one tag per session is mandatory.

**Beads:** epic `workstation-3umv`; Task N below is bead `workstation-3umv.N`. Claim
with `bd update workstation-3umv.N --claim` before starting and `bd close` it when the
task's commit lands. The dependency graph is already wired, so `bd ready` shows exactly
what is unblocked. The out-of-scope oc-cost rate-book correction is `workstation-xuq2`.

**Worktree:** `.worktrees/oc-tags`, branch `oc-tags`. Never commit at the primary root.

---

## Ground rules for every task

1. **TDD.** Write the failing test, run it, watch it fail for the right reason, then implement.
2. **The test count is PINNED** in `flake.nix`. Every task that adds tests must update the `Ran N tests` gate in the same commit. Get the real number from the test run output; never guess.
3. **Never open `opencode.db` for writing.** Always `file:...?mode=ro`. Never `immutable=1`.
4. **Work in this worktree** (`.worktrees/oc-tags`), never the primary root.
5. **Commit after every task.**
6. Run the whole suite with:
   ```bash
   python3 pkgs/oc-tags/test_oc_tags.py 2>&1 | tail -5
   ```
   `unittest` writes its summary to **stderr**, so `2>&1` is load-bearing.

---

## Task 1: Scaffold the package and wire a check that can fail

**Files:**
- Create: `pkgs/oc-tags/oc_tags.py`
- Create: `pkgs/oc-tags/test_oc_tags.py`
- Create: `pkgs/oc-tags/default.nix`
- Modify: `flake.nix` (local packages list, near `oc-cost = p.callPackage ./pkgs/oc-cost { };` at ~line 78)
- Modify: `flake.nix` (checks, after the `oc-cost-tests` block at ~line 682-702)
- Modify: `users/dev/home.base.nix:599` area (add `localPkgs.oc-tags` next to `localPkgs.oc-cost`)

**Step 1: Write the failing test**

`pkgs/oc-tags/test_oc_tags.py`:

```python
"""Tests for oc-tags. Run: python3 pkgs/oc-tags/test_oc_tags.py"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

# Allow `import oc_tags` when running from repo root or anywhere else.
sys.path.insert(0, str(Path(__file__).resolve().parent))

import oc_tags  # noqa: E402


class TestParseArgs(unittest.TestCase):
    def test_report_defaults(self):
        args = oc_tags.parse_args(["report"])
        self.assertEqual(args.command, "report")
        self.assertEqual(args.days, 14)


# Without this guard, `python3 test_oc_tags.py` imports the module, defines
# every test, runs NONE, prints nothing and exits 0 -- the exact failure mode
# documented at the bottom of pkgs/oc-cost/test_oc_cost.py. The flake check
# runs this file directly, so the guard is what makes the check able to fail.
if __name__ == "__main__":
    unittest.main()
```

**Step 2: Run it and watch it fail**

```bash
python3 pkgs/oc-tags/test_oc_tags.py 2>&1 | tail -5
```
Expected: `ModuleNotFoundError: No module named 'oc_tags'`.

**Step 3: Minimal implementation**

`pkgs/oc-tags/oc_tags.py`:

```python
#!/usr/bin/env python3
"""oc-tags: tag opencode sessions and chart list-price consumption per tag.

The dollar figure is opencode's own recorded per-message cost. It is LIST
PRICE CONSUMED, not money billed: two $100/day ceilings in
claude-failover-proxy cap real spend near $210/day and everything past them
runs on a flat-rate Max subscription. See
docs/plans/2026-09-08-oc-tags-design.md.
"""

from __future__ import annotations

import argparse
import sys

VERSION = "0.1.0"


def parse_args(argv: list[str]) -> argparse.Namespace:
    p = argparse.ArgumentParser(prog="oc-tags", description=__doc__.splitlines()[0])
    sub = p.add_subparsers(dest="command", required=True)

    rep = sub.add_parser("report", help="text table of dollars by tag by day")
    rep.add_argument("--days", type=int, default=14)

    return p.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    parse_args(sys.argv[1:] if argv is None else argv)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
```

**Step 4: Run tests — expect PASS, `Ran 1 test`**

**Step 5: Package it**

`pkgs/oc-tags/default.nix` — copy `pkgs/oc-cost/default.nix` exactly, changing `pname` to `oc-tags`, the copied filename to `oc_tags.py`, the installed name to `oc-tags`, `mainProgram = "oc-tags"`, and the description to
`"Tag opencode sessions and chart list-price consumption per tag"`.

`flake.nix`, alongside the other `oc-*` entries (~line 78, keep alphabetical):

```nix
      oc-tags = p.callPackage ./pkgs/oc-tags { };
```

`flake.nix` checks, modelled on `oc-cost-tests`. **`python3Packages.tzdata` is mandatory** — `zoneinfo.ZoneInfo("America/New_York")` raises `ZoneInfoNotFoundError` inside the `runCommand` sandbox without it, so the suite would pass locally and fail only under `nix flake check`:

```nix
      oc-tags-tests = devboxPkgs.runCommand "oc-tags-tests" {
        nativeBuildInputs = [
          devboxPkgs.python3
          # zoneinfo has no tzdata inside the sandbox; ET bucketing needs it.
          devboxPkgs.python3Packages.tzdata
        ];
      } ''
        cd ${self}
        export HOME="$TMPDIR"
        export PYTHONPATH="${devboxPkgs.python3Packages.tzdata}/${devboxPkgs.python3.sitePackages}"
        # unittest writes its summary to STDERR, so 2>&1 is load-bearing here.
        python3 pkgs/oc-tags/test_oc_tags.py 2>&1 | tee "$TMPDIR/out.txt"

        # The count is PINNED, following checks.oc-cost-tests. "OK" alone is
        # also what a suite that silently stopped collecting tests prints.
        grep -q '^Ran 1 test' "$TMPDIR/out.txt" || {
          echo "GATE FAILURE: expected 'Ran 1 test'. If you added or removed" >&2
          echo "tests deliberately, update the count here in the same commit." >&2
          exit 1
        }
        grep -q '^OK$' "$TMPDIR/out.txt" || {
          echo "GATE FAILURE: oc-tags suite did not report OK." >&2
          exit 1
        }
        touch $out
      '';
```

`users/dev/home.base.nix`, next to `localPkgs.oc-cost`:

```nix
    localPkgs.oc-tags
```

**Step 6: Verify the check actually runs and can fail**

```bash
nix build .#checks.aarch64-linux.oc-tags-tests -L 2>&1 | tail -20
```
Expected: builds, prints `Ran 1 test` and `OK`.

Now prove the gate bites — temporarily change the pin to `Ran 99 tests`, rebuild, confirm `GATE FAILURE`, then revert. A check that cannot fail is the artifact `users/dev/test-unwired-tests.sh` exists to catch.

**Step 7: Commit**

```bash
git add pkgs/oc-tags flake.nix users/dev/home.base.nix
git commit -m "feat(oc-tags): scaffold package with a wired, failing-capable check"
```

---

## Task 2: The auto-key rule

The fallback label for a session with no manual tag. **Keep the worktree slug** — it is the epic signal, and stripping it folded $15k into one band in an earlier draft.

**Files:** Modify `pkgs/oc-tags/oc_tags.py`, `pkgs/oc-tags/test_oc_tags.py`, `flake.nix` (count).

**Step 1: Failing tests**

```python
class TestAutoKey(unittest.TestCase):
    def test_worktree_keeps_slug(self):
        self.assertEqual(
            oc_tags.auto_key("/home/dev/projects/mono/.worktrees/fbm-transform-evidence"),
            "auto:mono/fbm-transform-evidence",
        )

    def test_primary_root(self):
        self.assertEqual(oc_tags.auto_key("/home/dev/projects/mono"), "auto:mono")

    def test_tmp_collapses(self):
        self.assertEqual(oc_tags.auto_key("/tmp/yt0p-verify"), "auto:tmp")
        self.assertEqual(oc_tags.auto_key("/tmp"), "auto:tmp")

    def test_nested_worktree_path(self):
        self.assertEqual(
            oc_tags.auto_key("/home/dev/projects/mono/.worktrees/w3-pr2/sub/dir"),
            "auto:mono/w3-pr2",
        )

    def test_missing_directory(self):
        self.assertEqual(oc_tags.auto_key(None), "auto:no-dir")
        self.assertEqual(oc_tags.auto_key(""), "auto:no-dir")

    def test_trailing_slash(self):
        self.assertEqual(oc_tags.auto_key("/home/dev/projects/mono/"), "auto:mono")
```

**Step 2: Run — expect `AttributeError: module 'oc_tags' has no attribute 'auto_key'`**

**Step 3: Implement**

```python
import os
import posixpath

_WORKTREE_MARKER = "/.worktrees/"


def auto_key(directory: str | None) -> str:
    """Fallback tag for an untagged root session, derived from its directory.

    Worktrees KEEP their slug: `mono/.worktrees/w3-pr2` -> `auto:mono/w3-pr2`.
    The slug is the epic/ticket signal and is the only free attribution this
    tool gets. Collapsing it merges ~$15k of distinct work into one band.
    """
    if not directory:
        return "auto:no-dir"
    d = directory.rstrip("/") or "/"
    if d == "/tmp" or d.startswith("/tmp/"):
        return "auto:tmp"
    if _WORKTREE_MARKER in d:
        head, _, tail = d.partition(_WORKTREE_MARKER)
        project = posixpath.basename(head) or head
        slug = tail.split("/", 1)[0]
        return f"auto:{project}/{slug}"
    return f"auto:{posixpath.basename(d) or d}"
```

**Step 4: Run — expect PASS, `Ran 7 tests`. Update the pin in `flake.nix` to `Ran 7 tests`.**

**Step 5: Commit**

```bash
git add pkgs/oc-tags flake.nix
git commit -m "feat(oc-tags): auto-key rule preserving worktree slugs"
```

---

## Task 3: Root resolution with dangling parents

**Files:** Modify `oc_tags.py`, `test_oc_tags.py`, `flake.nix`.

Measured on the live DB: depth is ≤1, but **983 sessions carry a `parent_id` that is not in the `session` table**. Those must resolve to the topmost *existing* ancestor, or their dollars vanish silently.

**Step 1: Failing tests**

```python
class TestRootOf(unittest.TestCase):
    def test_root_is_itself(self):
        self.assertEqual(oc_tags.root_of("a", {"a": None}), "a")

    def test_child_resolves_to_parent(self):
        self.assertEqual(oc_tags.root_of("b", {"a": None, "b": "a"}), "a")

    def test_dangling_parent_stops_at_self(self):
        # 983 live sessions point at a deleted parent. Attribute to the
        # topmost EXISTING ancestor -- here, the child itself.
        self.assertEqual(oc_tags.root_of("b", {"b": "gone"}), "b")

    def test_dangling_grandparent_stops_at_existing(self):
        self.assertEqual(oc_tags.root_of("c", {"b": "gone", "c": "b"}), "b")

    def test_cycle_guard(self):
        self.assertEqual(oc_tags.root_of("a", {"a": "b", "b": "a"}), "a")

    def test_unknown_session(self):
        self.assertEqual(oc_tags.root_of("zzz", {"a": None}), "zzz")
```

**Step 2: Run — expect failure**

**Step 3: Implement**

```python
def root_of(session_id: str, parents: dict[str, str | None]) -> str:
    """Topmost EXISTING ancestor of `session_id`.

    `parents` maps session id -> parent id (or None). A parent that is absent
    from the map is a deleted session; we stop at the last id that exists
    rather than dropping the row. Visited-set guards a cycle.
    """
    cur = session_id
    seen: set[str] = set()
    while True:
        if cur in seen:
            return cur
        seen.add(cur)
        parent = parents.get(cur)
        if not parent or parent not in parents:
            return cur
        cur = parent
```

**Step 4: Run — `Ran 13 tests`. Update the pin.**

**Step 5: Commit**

```bash
git commit -am "feat(oc-tags): root resolution handling dangling parents and cycles"
```

---

## Task 4: The tag store

**Files:** Modify `oc_tags.py`, `test_oc_tags.py`, `flake.nix`.

Two tables. `session_tag` has a **primary key on `session_id`**, which is what enforces the one-tag-per-session partition the stacked area needs.

**Step 1: Failing tests**

```python
import tempfile


class TestStore(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = str(Path(self.tmp.name) / "tags.db")

    def tearDown(self):
        self.tmp.cleanup()

    def test_set_and_get_session_tag(self):
        with oc_tags.open_store(self.path) as st:
            oc_tags.set_session_tag(st, "ses_a", "billing")
            self.assertEqual(oc_tags.session_tags(st), {"ses_a": "billing"})

    def test_one_tag_per_session_overwrites(self):
        with oc_tags.open_store(self.path) as st:
            oc_tags.set_session_tag(st, "ses_a", "billing")
            oc_tags.set_session_tag(st, "ses_a", "infra")
            # A stacked area's top edge must equal the total; two tags on one
            # session would double count. Last write wins.
            self.assertEqual(oc_tags.session_tags(st), {"ses_a": "infra"})

    def test_tag_normalised_to_lowercase(self):
        with oc_tags.open_store(self.path) as st:
            oc_tags.set_session_tag(st, "ses_a", "  Infra  ")
            self.assertEqual(oc_tags.session_tags(st), {"ses_a": "infra"})

    def test_empty_tag_rejected(self):
        with oc_tags.open_store(self.path) as st:
            with self.assertRaises(ValueError):
                oc_tags.set_session_tag(st, "ses_a", "   ")

    def test_dir_tag_roundtrip(self):
        with oc_tags.open_store(self.path) as st:
            oc_tags.set_dir_tag(st, "/home/dev/projects/mono/.worktrees/fbm-*", "fbm")
            self.assertEqual(
                oc_tags.dir_tags(st),
                {"/home/dev/projects/mono/.worktrees/fbm-*": "fbm"},
            )

    def test_rm_session_tag(self):
        with oc_tags.open_store(self.path) as st:
            oc_tags.set_session_tag(st, "ses_a", "billing")
            self.assertTrue(oc_tags.rm_session_tag(st, "ses_a"))
            self.assertEqual(oc_tags.session_tags(st), {})
            self.assertFalse(oc_tags.rm_session_tag(st, "ses_a"))

    def test_schema_created_idempotently(self):
        with oc_tags.open_store(self.path) as st:
            oc_tags.set_session_tag(st, "ses_a", "billing")
        with oc_tags.open_store(self.path) as st:
            self.assertEqual(oc_tags.session_tags(st), {"ses_a": "billing"})
```

**Step 2: Run — expect failure**

**Step 3: Implement**

```python
import contextlib
import sqlite3
import time

DEFAULT_TAGS_DB = os.path.expanduser("~/.local/share/oc-tags/tags.db")

_SCHEMA = """
CREATE TABLE IF NOT EXISTS session_tag (
    session_id TEXT PRIMARY KEY,
    tag        TEXT NOT NULL,
    created_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS dir_tag (
    pattern    TEXT PRIMARY KEY,
    tag        TEXT NOT NULL,
    created_at INTEGER NOT NULL
);
"""


def normalise_tag(tag: str) -> str:
    t = (tag or "").strip().lower()
    if not t:
        raise ValueError("tag must not be empty")
    return t


@contextlib.contextmanager
def open_store(path: str = DEFAULT_TAGS_DB):
    """Open (creating if needed) the sidecar tag DB.

    Deliberately NOT beside opencode.db: `rm ~/.local/share/opencode/*.db*`
    is a documented remedy and must not take hand-made tags with it.
    """
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    conn = sqlite3.connect(path)
    try:
        conn.executescript(_SCHEMA)
        conn.commit()
        yield conn
        conn.commit()
    finally:
        conn.close()


def set_session_tag(conn, session_id: str, tag: str) -> None:
    conn.execute(
        "INSERT INTO session_tag(session_id, tag, created_at) VALUES (?,?,?) "
        "ON CONFLICT(session_id) DO UPDATE SET tag=excluded.tag, created_at=excluded.created_at",
        (session_id, normalise_tag(tag), int(time.time() * 1000)),
    )


def set_dir_tag(conn, pattern: str, tag: str) -> None:
    conn.execute(
        "INSERT INTO dir_tag(pattern, tag, created_at) VALUES (?,?,?) "
        "ON CONFLICT(pattern) DO UPDATE SET tag=excluded.tag, created_at=excluded.created_at",
        (pattern, normalise_tag(tag), int(time.time() * 1000)),
    )


def session_tags(conn) -> dict[str, str]:
    return dict(conn.execute("SELECT session_id, tag FROM session_tag"))


def dir_tags(conn) -> dict[str, str]:
    return dict(conn.execute("SELECT pattern, tag FROM dir_tag"))


def rm_session_tag(conn, session_id: str) -> bool:
    return conn.execute("DELETE FROM session_tag WHERE session_id=?", (session_id,)).rowcount > 0


def rm_dir_tag(conn, pattern: str) -> bool:
    return conn.execute("DELETE FROM dir_tag WHERE pattern=?", (pattern,)).rowcount > 0
```

**Step 4: Run — `Ran 20 tests`. Update the pin.**

**Step 5: Commit**

```bash
git commit -am "feat(oc-tags): sidecar tag store with one-tag-per-session PK"
```

---

## Task 5: Effective-tag resolution

**Files:** Modify `oc_tags.py`, `test_oc_tags.py`, `flake.nix`.

Precedence: session tag → directory-pattern tag → auto key.

**Step 1: Failing tests**

```python
class TestEffectiveTag(unittest.TestCase):
    def test_session_tag_wins(self):
        self.assertEqual(
            oc_tags.effective_tag(
                "ses_a", "/home/dev/projects/mono",
                session_tags={"ses_a": "billing"},
                dir_tags={"/home/dev/projects/mono": "monorepo"},
            ),
            ("billing", "manual"),
        )

    def test_dir_pattern_next(self):
        self.assertEqual(
            oc_tags.effective_tag(
                "ses_a", "/home/dev/projects/mono/.worktrees/fbm-webhook-res",
                session_tags={},
                dir_tags={"/home/dev/projects/mono/.worktrees/fbm-*": "fbm"},
            ),
            ("fbm", "manual"),
        )

    def test_auto_fallback(self):
        self.assertEqual(
            oc_tags.effective_tag("ses_a", "/home/dev/projects/mono", {}, {}),
            ("auto:mono", "auto"),
        )

    def test_longest_pattern_wins(self):
        # Specific beats general, so a broad `mono/*` rule never shadows a
        # narrow one added later.
        self.assertEqual(
            oc_tags.effective_tag(
                "ses_a", "/home/dev/projects/mono/.worktrees/fbm-webhook-res",
                session_tags={},
                dir_tags={
                    "/home/dev/projects/mono/*": "mono-all",
                    "/home/dev/projects/mono/.worktrees/fbm-*": "fbm",
                },
            ),
            ("fbm", "manual"),
        )

    def test_no_directory(self):
        self.assertEqual(
            oc_tags.effective_tag("ses_a", None, {}, {}), ("auto:no-dir", "auto")
        )
```

**Step 2: Run — expect failure**

**Step 3: Implement**

```python
import fnmatch


def effective_tag(session_id, directory, session_tags, dir_tags):
    """Resolve a ROOT session's tag. Returns (tag, source) where source is
    'manual' or 'auto'. `oc-tags top` treats 'auto' as untagged so the
    backlog stays visible rather than hidden behind a plausible label.
    """
    tag = session_tags.get(session_id)
    if tag:
        return tag, "manual"
    if directory:
        matches = [p for p in dir_tags if fnmatch.fnmatch(directory, p)]
        if matches:
            # Longest pattern wins: specific beats general.
            return dir_tags[max(matches, key=len)], "manual"
    return auto_key(directory), "auto"
```

**Step 4: Run — `Ran 25 tests`. Update the pin.**

**Step 5: Commit**

```bash
git commit -am "feat(oc-tags): effective-tag precedence (session > dir pattern > auto)"
```

---

## Task 6: ET bucketing

**Files:** Modify `oc_tags.py`, `test_oc_tags.py`, `flake.nix`.

Buckets are **America/New_York**, because the spend ceilings reset at 0 ET. UTC buckets would smear the cap edge across two days. Hourly for windows ≤ 3 days, daily beyond — 720 hourly bars × 15 series is unreadable.

**Step 1: Failing tests**

```python
class TestBucketing(unittest.TestCase):
    def test_hour_bucket_et(self):
        # 1788874200000 == 2026-09-08 09:30 ET (EDT, UTC-4)
        self.assertEqual(oc_tags.bucket_key(1788874200000, "hour"), "2026-09-08T09")

    def test_day_bucket_et(self):
        self.assertEqual(oc_tags.bucket_key(1788874200000, "day"), "2026-09-08")

    def test_utc_midnight_is_previous_et_day(self):
        # 1788832800000 is 2026-09-07 22:00 ET (2026-09-08 02:00Z). A UTC bucket would put
        # this on the wrong side of the 0-ET spend-cap reset.
        self.assertEqual(oc_tags.bucket_key(1788832800000, "day"), "2026-09-07")

    def test_choose_bucket_size(self):
        self.assertEqual(oc_tags.choose_bucket(1), "hour")
        self.assertEqual(oc_tags.choose_bucket(3), "hour")
        self.assertEqual(oc_tags.choose_bucket(4), "day")
        self.assertEqual(oc_tags.choose_bucket(30), "day")
```

Verify the two epoch-ms constants before writing them into the test:

```bash
python3 -c "
import datetime,zoneinfo
for ms in (1788874200000, 1788832800000):
    print(ms, datetime.datetime.fromtimestamp(ms/1000, zoneinfo.ZoneInfo('America/New_York')))"
```

If they do not print `2026-09-08 09:30` and `2026-09-07 22:00`, recompute the constants from those wall-clock times rather than adjusting the expectations.

**Step 2: Run — expect failure**

**Step 3: Implement**

```python
import datetime
import zoneinfo

ET = zoneinfo.ZoneInfo("America/New_York")


def bucket_key(epoch_ms: int, size: str) -> str:
    dt = datetime.datetime.fromtimestamp(epoch_ms / 1000, ET)
    return dt.strftime("%Y-%m-%dT%H") if size == "hour" else dt.strftime("%Y-%m-%d")


def choose_bucket(days: int) -> str:
    """Hourly only for short windows. 720 hourly bars x 15 series is noise."""
    return "hour" if days <= 3 else "day"
```

**Step 4: Run — `Ran 29 tests`. Update the pin.**

**Step 5: Commit**

```bash
git commit -am "feat(oc-tags): ET bucketing aligned to the 0-ET spend-cap reset"
```

---

## Task 7: The cost aggregation query

**Files:** Modify `oc_tags.py`, `test_oc_tags.py`, `flake.nix`.

**One SQL aggregate**, not a per-session loop. Measured warm on the live 8.9 GB DB: full-scan `GROUP BY session_id` = 0.4 s; a session-first index loop = 0.5 s. Session-first buys nothing and costs complexity.

**Step 1: Failing tests** — build a fixture DB in `setUp` covering every hazard the design names.

```python
import json


def _fixture_db(path):
    conn = sqlite3.connect(path)
    conn.executescript(
        """
        CREATE TABLE session (id TEXT PRIMARY KEY, parent_id TEXT,
                              directory TEXT, title TEXT, cost REAL,
                              time_created INTEGER, time_updated INTEGER);
        CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT,
                              time_created INTEGER, data TEXT);
        """
    )
    sessions = [
        # id,        parent,   directory,                                       title
        ("root_a", None, "/home/dev/projects/mono", "FBM OOS webhook investigation"),
        ("kid_a", "root_a", "/home/dev/projects/mono", "subagent"),
        ("root_b", None, "/home/dev/projects/mono/.worktrees/w3-pr2", "w3 pr2"),
        # dangling parent: parent row does not exist
        ("orphan", "deleted_parent", "/home/dev/projects/salmon", "orphan"),
        ("tmp_s", None, "/tmp/yt0p-verify", "throwaway"),
    ]
    for sid, par, d, title in sessions:
        conn.execute(
            "INSERT INTO session VALUES (?,?,?,?,0,?,?)",
            (sid, par, d, title, 1788874200000, 1788874200000),
        )

    def msg(mid, sid, ts, cost, model="claude-opus-5@default",
            provider="google-vertex-anthropic", role="assistant", tokens=None):
        data = {
            "role": role, "cost": cost, "modelID": model, "providerID": provider,
            "time": {"created": ts},
            "tokens": tokens or {"input": 10, "output": 20,
                                 "cache": {"read": 100, "write": 5}},
        }
        conn.execute("INSERT INTO message VALUES (?,?,?,?)",
                     (mid, sid, ts, json.dumps(data)))

    t = 1788874200000                    # 2026-09-08 09:30 ET
    msg("m1", "root_a", t, 1.50)
    msg("m2", "kid_a", t, 0.50)          # rolls up to root_a
    msg("m3", "root_b", t, 2.00)
    msg("m4", "orphan", t, 0.25)
    msg("m5", "tmp_s", t, 0.10)
    # zero-token error row: $0 is correct, must not crash
    msg("m6", "root_a", t, 0.0, tokens={"input": 0, "output": 0,
                                        "cache": {"read": 0, "write": 0}})
    # a user message must never be counted
    msg("m7", "root_a", t, 99.0, role="user")
    # unpriced model: cost recorded as 0 but tokens present
    msg("m8", "root_b", t, 0.0, model="claude-brand-new@default",
        tokens={"input": 1000, "output": 2000, "cache": {"read": 0, "write": 0}})
    # outside the window (much older)
    msg("m9", "root_a", t - 90 * 86400 * 1000, 5.00)
    conn.commit()
    conn.close()


class TestAggregate(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.db = str(Path(self.tmp.name) / "opencode.db")
        _fixture_db(self.db)

    def tearDown(self):
        self.tmp.cleanup()

    def _agg(self, session_tags=None, dir_tags=None):
        return oc_tags.aggregate(
            self.db,
            since_ms=1788874200000 - 86400 * 1000,
            until_ms=1788874200000 + 86400 * 1000,
            bucket="day",
            session_tags=session_tags or {},
            dir_tags=dir_tags or {},
        )

    def test_child_cost_rolls_up_to_root(self):
        rows = self._agg()
        # root_a: 1.50 + 0.50 (child) + 0.0 = 2.00; the $99 user row excluded
        self.assertAlmostEqual(rows.totals["auto:mono"], 2.00)

    def test_worktree_slug_preserved(self):
        rows = self._agg()
        self.assertIn("auto:mono/w3-pr2", rows.totals)

    def test_orphan_attributed_not_dropped(self):
        rows = self._agg()
        self.assertAlmostEqual(rows.totals["auto:salmon"], 0.25)

    def test_manual_tag_applied(self):
        rows = self._agg(session_tags={"root_a": "billing"})
        self.assertAlmostEqual(rows.totals["billing"], 2.00)
        self.assertNotIn("auto:mono", rows.totals)

    def test_window_excludes_old_rows(self):
        rows = self._agg()
        self.assertNotIn(5.00, rows.totals.values())

    def test_unpriced_models_reported(self):
        rows = self._agg()
        self.assertIn("claude-brand-new@default", rows.unpriced)
        self.assertEqual(rows.unpriced["claude-brand-new@default"]["messages"], 1)
        self.assertEqual(rows.unpriced["claude-brand-new@default"]["tokens"], 3000)

    def test_buckets_are_populated(self):
        rows = self._agg()
        self.assertEqual(set(rows.series["auto:mono"]), {"2026-09-08"})
```

**Step 2: Run — expect failure**

**Step 3: Implement**

```python
import collections
from dataclasses import dataclass, field

DEFAULT_OPENCODE_DB = os.path.expanduser("~/.local/share/opencode/opencode.db")


@dataclass
class Aggregate:
    series: dict = field(default_factory=lambda: collections.defaultdict(dict))
    totals: dict = field(default_factory=dict)
    buckets: list = field(default_factory=list)
    sources: dict = field(default_factory=dict)   # tag -> 'manual' | 'auto'
    unpriced: dict = field(default_factory=dict)  # model -> {messages, tokens}
    partial_bucket: str | None = None


def connect_ro(db_path: str) -> sqlite3.Connection:
    """Read-only connection to opencode.db.

    NEVER immutable=1: WAL needs a writable -shm, which exists while any serve
    runs. busy_timeout because ~15 serves write concurrently.
    """
    conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    conn.execute("PRAGMA busy_timeout=5000")
    return conn


def aggregate(db_path, since_ms, until_ms, bucket, session_tags, dir_tags):
    conn = connect_ro(db_path)
    try:
        parents = dict(conn.execute("SELECT id, parent_id FROM session"))
        dirs = dict(conn.execute("SELECT id, directory FROM session"))

        rows = conn.execute(
            """
            SELECT session_id,
                   time_created,
                   json_extract(data, '$.cost'),
                   json_extract(data, '$.modelID'),
                   json_extract(data, '$.tokens.input'),
                   json_extract(data, '$.tokens.output')
              FROM message
             WHERE time_created >= ? AND time_created < ?
               AND json_extract(data, '$.role') = 'assistant'
            """,
            (since_ms, until_ms),
        ).fetchall()
    finally:
        conn.close()

    agg = Aggregate()
    tag_cache: dict[str, tuple[str, str]] = {}
    per_bucket = collections.defaultdict(lambda: collections.defaultdict(float))
    buckets = set()

    for sid, ts, cost, model, tin, tout in rows:
        cost = cost or 0.0
        root = root_of(sid, parents)
        if root not in tag_cache:
            tag_cache[root] = effective_tag(root, dirs.get(root), session_tags, dir_tags)
        tag, source = tag_cache[root]
        agg.sources[tag] = source

        key = bucket_key(ts, bucket)
        buckets.add(key)
        per_bucket[tag][key] += cost

        # A model with no recorded price must be LOUD. Rendering it as $0
        # would silently under-report on exactly the day a new model ships.
        if cost == 0 and ((tin or 0) + (tout or 0)) > 0:
            u = agg.unpriced.setdefault(model, {"messages": 0, "tokens": 0})
            u["messages"] += 1
            u["tokens"] += (tin or 0) + (tout or 0)

    agg.buckets = sorted(buckets)
    agg.series = {t: dict(b) for t, b in per_bucket.items()}
    agg.totals = {t: sum(b.values()) for t, b in agg.series.items()}
    # In-flight turns carry no cost until they complete, so the newest bucket
    # always under-reads and must be labelled.
    agg.partial_bucket = agg.buckets[-1] if agg.buckets else None
    return agg
```

**Step 4: Run — `Ran 36 tests`. Update the pin.**

**Step 5: Smoke-test against the real DB** (read-only; must not error and must finish in about a second):

```bash
python3 -c "
import sys, time; sys.path.insert(0,'pkgs/oc-tags')
import oc_tags
now=int(time.time()*1000)
t=time.time()
a=oc_tags.aggregate(oc_tags.DEFAULT_OPENCODE_DB, now-7*86400*1000, now, 'day', {}, {})
print(f'{time.time()-t:.2f}s', len(a.totals), 'tags,', f'\${sum(a.totals.values()):,.0f}')
for k,v in sorted(a.totals.items(), key=lambda kv:-kv[1])[:8]: print(f'  {k:38} \${v:9,.0f}')
print('unpriced:', a.unpriced)"
```

**Step 6: Commit**

```bash
git commit -am "feat(oc-tags): single-pass cost aggregation with root rollup"
```

---

## Task 8: `report`, `set`, `ls`, `rm`

**Files:** Modify `oc_tags.py`, `test_oc_tags.py`, `flake.nix`.

CLI surface:

```
oc-tags set <tag> [session-id]      # defaults to $OPENCODE_SESSION_ID, resolved to root
oc-tags set --dir <path> <tag>
oc-tags ls [--counts]
oc-tags rm <session-id> | --dir <path>
oc-tags report [--days N] [--db PATH] [--tags-db PATH]
```

`$OPENCODE_SESSION_ID` is injected into every bash call by
`assets/opencode/plugins/shell-env.ts:248`, so an agent can tag its own work with
no argument.

**Tests to write:** `set` with no session id reads `OPENCODE_SESSION_ID` from the
environment and resolves it to its root before writing; `set` with neither an
argument nor the env var exits non-zero with a clear message; `--dir` writes a
`dir_tag`; `rm --dir` removes one; `report` prints a table containing a tag name
and a dollar figure; `report` on an empty window exits 0 and says so rather than
printing an empty table.

Route every command through `main(argv)` returning an int, and capture stdout
with `contextlib.redirect_stdout` — the same shape `test_oc_cost.py` uses at its
tail.

**Report output shape:**

```
Consumed at list price (USD) -- not billed.  Window: 2026-09-01..2026-09-08 (ET)

tag                                    total     share
------------------------------------------------------
auto:mono                            8524.11     32.2%
auto:mono/w3-pr2                      630.05      2.4%
billing                               412.90      1.6%
...
------------------------------------------------------
total                               26498.00

Billed via cfp (capped $100+$100/day): $1,463   coverage vs cfp notional: 98%
Unpriced models: claude-brand-new@default (1 msg, 3.0K tok)
Newest bucket is PARTIAL (in-flight turns carry no cost until they complete).
```

Update the pin. Commit as `feat(oc-tags): set/ls/rm/report CLI`.

---

## Task 9: `top` — the tagging backlog

**Files:** Modify `oc_tags.py`, `test_oc_tags.py`, `flake.nix`.

`oc-tags top [--days N] [--min N]` lists the highest-dollar **root** sessions whose
effective tag source is `auto`, so auto-labelling never hides the backlog.

Columns: dollars, session id, `session.title`, directory. Titles are already good
labels on this host ("FBM OOS webhook investigation" $1,051; "LGTM timer: NYC
hours" $1,038), which is the point — 66% of dollars sit in primary-root sessions
where the directory says nothing.

Print a `--dir` hint under any group of ≥3 untagged roots sharing a directory
prefix, since one `set --dir` covers past and future sessions at once.

**Tests:** auto-source roots appear; manually-tagged roots do not; ordering is by
dollars descending; `--min` filters. Update the pin. Commit as
`feat(oc-tags): top, ranking untagged roots by dollars`.

---

## Task 10: The cfp reference line

**Files:** Modify `oc_tags.py`, `test_oc_tags.py`, `flake.nix`.

Read **`/var/lib/claude-failover-proxy/history.jsonl`** (69 pre-aggregated ET days,
fields `spend` + `enterpriseSpend`), plus `spend.json` and `spend-enterprise.json`
for the current day. **Do not parse the 70 MB `events.jsonl`** — it costs ~1 s and
1.7 GB RSS per render and buys nothing here.

```python
CFP_DIR = "/var/lib/claude-failover-proxy"


def cfp_metered_by_day(cfp_dir: str = CFP_DIR) -> dict[str, float]:
    """Actual billed dollars per ET day. Returns {} if cfp is absent.

    This is a REFERENCE LINE, never a band: it is pinned near $210/day by two
    $100 ceilings, so per-tag metered dollars would measure which work reached
    the cap first, i.e. time of day. See the design doc.
    """
```

**Tests:** a temp `history.jsonl` sums `spend + enterpriseSpend` per day; a missing
directory returns `{}` rather than raising; a malformed line is skipped (cfp's own
reader does the same, and the last line can be torn mid-append); today's totals come
from the two `spend*.json` files.

Update the pin. Commit as `feat(oc-tags): cfp metered reference line from history.jsonl`.

---

## Task 11: SVG rendering (pure function)

**Files:** Modify `oc_tags.py`, `test_oc_tags.py`, `flake.nix`.

`render_svg(agg, metered_by_day, hide=frozenset(), top_n=12) -> str`, a pure function
so it is testable without a socket.

Requirements:
- Stacked areas, one band per tag, ordered by total descending, Top-N plus an `other` band.
- Auto-source tags rendered desaturated (lower saturation fill), manual tags saturated.
- An `unpriced` band pinned in the legend regardless of Top-N, **labelled in tokens, not dollars**.
- The metered reference line drawn as a thin stroke over the stack, labelled "billed (capped)".
- The newest bucket hatched and labelled *partial*.
- Axis title exactly: `Consumed at list price (USD) — not billed`.
- Headline above the chart: `cap hit at HH:MM` for the most recent day where metered ≥ $195.
- Every tag string passed through an `html_escape` helper. Tags are CLI-sourced, but escaping is free.
- Footer: coverage vs cfp notional, unpriced summary, and the drift warning when the per-day ratio falls outside 0.90–1.05.

**Tests:** output starts with `<svg` and is well-formed per `xml.etree.ElementTree.fromstring`; a tag containing `<script>` appears escaped and not as a live element; `hide` removes a band and its legend entry; more than `top_n` tags produces an `other` band whose value equals the sum of the tail; the `unpriced` legend entry survives Top-N truncation; an empty aggregate renders a valid "no data" SVG rather than raising.

Update the pin. Commit as `feat(oc-tags): server-rendered stacked-area SVG`.

---

## Task 12: `serve`

**Files:** Modify `oc_tags.py`, `test_oc_tags.py`, `flake.nix`.

```
oc-tags serve [--port 4710] [--host 127.0.0.1]
```

- stdlib `HTTPServer` (one user; threading is unnecessary complexity).
- Binds `127.0.0.1` only. It never addresses the serve pool (`:4096-4099`), so the
  front-door opacity guard is not engaged; it must not route through the front door
  either, which is a serve proxy rather than a dashboard host.
- All state in GET params: `?days=7&bucket=day&hide=auto:mono,other`. **Zero client
  JavaScript** — so the back button works and URLs are shareable.
- Bucket defaults via `choose_bucket(days)`; an explicit `bucket` param overrides.
- A fresh read-only connection per request; close it in a `finally`.
- `sqlite3.OperationalError` ("database is locked") renders an HTTP 503 error page,
  never a dead socket.
- Unknown paths return 404. `/healthz` returns `ok`.

**Tests:** drive the handler through `http.server`'s machinery on an ephemeral port
in a background thread, or factor request handling into
`handle_request(path, query) -> (status, content_type, body)` and test that pure
function directly — preferred, since it needs no socket in the sandbox. Assert:
`/` returns 200 with `image/svg+xml` or an HTML wrapper; `?days=1` selects hourly
bucketing; `?hide=` is parsed into a set; a bad `days` value returns 400 rather than
tracebacking; `/nope` returns 404.

Update the pin. Commit as `feat(oc-tags): loopback HTTP server with GET-param state`.

---

## Task 13: SSH exposure

**Files:** Modify `scripts/update-ssh-config.sh` (after the `cloudbox-cutover` block, ~line 140).

```
# On-demand chart tunnel: forwards this Mac's 4710 to cloudbox's loopback 4710
# where `oc-tags serve` runs. Deliberately NOT in the always-on
# `cloudbox-tunnel` block above: that runs under ExitOnForwardFailure=yes from
# a LaunchAgent, so a busy :4710 on this Mac would kill the whole tunnel,
# taking gclpr (2850), chatgpt-relay (3033) and the Jenkins :8443 forward with
# it. Note this is a LocalForward -- the opposite direction to
# `cloudbox-cutover`'s RemoteForward.
Host cloudbox-chart
    HostName $CLOUDBOX_IP
    User dev
    ForwardAgent yes
    ServerAliveInterval 60
    ServerAliveCountMax 3
    LocalForward 4710 127.0.0.1:4710
```

**Verify:**

```bash
bash -n scripts/update-ssh-config.sh
grep -n "cloudbox-chart" -A9 scripts/update-ssh-config.sh
```

Confirm the block sits **outside** the `cloudbox-tunnel` block and that `4710`
appears nowhere else in the file. Commit as
`feat(oc-tags): on-demand cloudbox-chart SSH forward`.

---

## Task 14: Documentation and final verification

**Files:**
- Create: `pkgs/oc-tags/README.md`
- Modify: `AGENTS.md` (the repo skills/structure table)

README must state, in this order: the axis means list price consumed and **not**
money billed; real spend is capped near $210/day so per-tag metered dollars are a
routing artifact; the dollar figure is opencode's stored `$.cost`, which matched
five of seven material models to the cent, with `oc-cost --reconcile` as the place
rate-book disagreement is surfaced; one tag per session, because a stacked area's
top edge must equal the total; and the usage recipe:

```bash
oc-tags top --days 7            # find what to tag
oc-tags set billing             # tag the current session
oc-tags set --dir '/home/dev/projects/mono/.worktrees/fbm-*' fbm
oc-tags report --days 7
oc-tags serve                   # then, from the Mac: ssh -N cloudbox-chart
                                # and open http://127.0.0.1:4710
```

**Final gates — all must pass:**

```bash
python3 pkgs/oc-tags/test_oc_tags.py 2>&1 | tail -3
nix build .#checks.aarch64-linux.oc-tags-tests -L 2>&1 | tail -5
nix flake check --keep-going 2>&1 | tail -30
```

Never add `--no-build` to `nix flake check`: cloudbox's evaluation depends on
import-from-derivation, and the failure is a misleading "path ... is not valid".

Then the end-to-end check on real data:

```bash
oc-tags top --days 7
oc-tags report --days 7
oc-tags serve --port 4710 &
curl -s localhost:4710 | head -c 400
curl -s -o /dev/null -w '%{http_code}\n' localhost:4710/nope   # expect 404
kill %1
```

Sanity-check the total against a known figure — 30 days should land near $26.5K,
and the `report` footer's coverage ratio should read ~98%.

**Commit, then open the PR** and shepherd it (@shepherding-pull-requests): PR
creation is not a terminal state.

---

## Out of scope — do not build

- Drill-down from chart to sessions; tag editing in the browser
- Many tags per session
- Any materialised rollup table (rows are *updated* when a turn completes, so an
  incremental rollup keyed on `time_created` silently misses late-landing cost)
- Parsing `events.jsonl` at render time
- A systemd user unit for `serve` — run it ad hoc until it earns one
- **Fixing `oc_cost.RATES`** (the missing `claude-fable-5-1` row, the disputed
  `gemini-3.6` intro rate, and making unknown models fail loud instead of
  prefix-pricing). That is a separate correctness PR against `oc-cost` and is not
  a dependency of this work.
