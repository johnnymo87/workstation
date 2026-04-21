# oc-cost Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.
> **READ THE RESUMPTION NOTES BELOW FIRST.** Several plan details have been corrected during execution.

---

## Resumption Notes (2026-04-21)

**Tasks 0-6 are DONE and pushed to origin/main.** The current state is captured in
the most recent commits on `main`:

```
58bd535 feat(oc-cost): compute cost components per-model     ← Task 6 (unsigned)
b1ff41c feat(oc-cost): add SQL queries against in-memory fixtures   ← Task 5
6344c44 feat(oc-cost): add resolve_window() for time bounds          ← Task 4
ae98a50 feat(oc-cost): add CLI arg parsing with mutex windows        ← Task 3
f8bb04f test(oc-cost): pin longest-prefix invariant against dict order ← Task 2 + extra regression test
d0900e1 chore: ignore Python __pycache__ and bytecode                ← infrastructure
8179aab feat(oc-cost): add PRICES table and price_for()              ← Task 2
180192b feat(oc-cost): scaffold package (no-op CLI)                  ← Task 1
```

(SHAs are from a parallel chain produced by another session; they replaced the
SHAs shown in early portions of this plan. Tree contents are identical.)

**Working mode going forward:** Work directly on `main`, not on a feature branch.
The user (Jonathan) keeps `origin/main` constantly fast-forwarded across multiple
machines (cloudbox, devbox, darwin) and multiple parallel Claude sessions. He has
told the other Claudes the same thing: **don't worry about coordinating commits;
just FF and push.** Conflicts on `pkgs/oc-cost/` are unlikely because no other
session is touching it.

**Push protocol per AGENTS.md "Landing the Plane":**
1. `git pull --rebase` before each push (origin moves frequently; expect it)
2. `git push` — required-status-check rule violation messages are normal
3. `git status` — must show "up to date with origin/main"

**Do NOT push without rebasing first.** Multiple machines push to main at the
same time; force-push is forbidden.

**Plan corrections discovered during execution (already applied to commits, NOT
re-edited into the task bodies below — fix as you encounter):**

1. **Task 4 timestamp constants** — plan body shows `1808841600000` (2027-04-20)
   and `1806796800000` (2027-04-01). The committed test file uses the correct
   2026 values: `1776686400000` and `1775001600000`. If you re-derive constants,
   ALWAYS pass `-u` to `date`: `date -u -d "2026-04-20T12:00:00Z" +%s%3N`.

2. **Task 4 `test_until_only` math** — plan body shows `+ 14 * 86_400_000`. Correct
   value is `+ 15 * 86_400_000` (consistent with `test_since_and_until` two lines
   above). End-of-day-inclusive semantics push the bound to next-day midnight.

3. **Task 2 has an extra regression test** committed beyond the plan: in
   `pkgs/oc-cost/test_oc_cost.py`, `test_longest_prefix_wins_regardless_of_dict_order`
   monkeypatches PRICES with adversarial insertion order to actually pin the
   longest-prefix invariant (the original `test_prefix_fallback` was order-dependent).
   Total test count is **30** at end of Task 6 (not 29 as plan body says).

**Subtle gotcha pre-flagged for Task 7:** The Task 3 mutex check uses
`"--days" in (argv or [])` to detect explicit `--days` (vs default 14). This is
a string-membership check on raw argv — works for current tests but brittle
(would also trigger on `--days-since-foo` if such a flag existed; misses `--days=7`
short-form). Don't refactor it during Task 7 unless `main()` integration exposes
the brittleness.

**SSH commit signing is NOW WORKING** on cloudbox after `home-manager switch`.
Future commits sign automatically with `~/.ssh/id_ed25519_signing.pub`. The
unsigned `58bd535` (Task 6) on origin/main is the one exception; live with it.

**Stash to PRESERVE — do not drop:** `stash@{0}` is the user's in-progress
work (datadog-mcp-cli removal + opencode-config tweak). Earlier in this session
the stash got dropped and was recovered from `git fsck --unreachable`. If it
goes missing again, recover via:

```
git fsck --unreachable 2>&1 | grep "unreachable commit"
# Find the one with subject "WIP: datadog-mcp-cli removal..."
git stash store -m "WIP: datadog-mcp-cli removal + opencode-config tweak (mine, in progress) [restored]" <SHA>
```

**Test count by task (running total, including the extra regression test):**
| Task | Tests added | Cumulative |
|---|---|---|
| 2 | 6 (5 from plan + 1 extra) | 6 |
| 3 | 8 | 14 |
| 4 | 6 | 20 |
| 5 | 5 | 25 |
| 6 | 5 | 30 |
| 7 | 3 | **33** (not 32) |

**Verification at the end of each task:**
- `python3 -m unittest pkgs/oc-cost/test_oc_cost.py 2>&1 | tail -3` → "OK"
- `git add pkgs/oc-cost && nix build .#oc-cost` → succeeds (must `git add` first; nix flakes ignore untracked files)
- After Task 7: `./result/bin/oc-cost --days 7` → real report against live opencode.db

---

**Goal:** Ship a Python CLI `oc-cost` that reads `~/.local/share/opencode/opencode.db` and prints OpenCode token usage and API cost, replacing the ad-hoc `analyze.mjs` script in `.opencode/skills/tracking-cache-costs/`.

**Architecture:** Single-file Python script with no third-party dependencies, packaged via `python3.pkgs.buildPythonApplication` (matching `pkgs/pinentry-op/`). Source lives inline at `pkgs/oc-cost/oc_cost.py`. Wired into the Nix package set in `flake.nix:54-58` and added to the user package list in `users/dev/home.base.nix:197`. Deployed on cloudbox via `nix run home-manager -- switch --flake .#cloudbox` (NOTE: `.#dev` is for devbox; cloudbox uses `.#cloudbox` despite earlier text saying "shares the `dev` home config").

**Tech Stack:** Python 3 stdlib only (`sqlite3`, `argparse`, `json`, `datetime`, `unittest`); Nix (`buildPythonApplication`); home-manager.

**Design doc:** `docs/plans/2026-04-20-oc-cost-design.md`

---

## Conventions used in this plan

- All file paths are repo-relative unless absolute.
- "Run" commands assume `cwd = /home/dev/projects/workstation`.
- "Cloudbox" deployment uses `nix run home-manager -- switch --flake .#cloudbox` (corrected from `.#dev` which fails with "flake target #dev is for devbox, but running on cloudbox").
- ~~Each task ends with a commit. Trunk-based; commits land on a feature branch (see Task 0).~~ **OBSOLETE per resumption notes:** Each task ends with a commit on `main`, immediately pushed (with `pull --rebase` first).
- Skills referenced with `@`: @verification-before-completion, @test-driven-development, @systematic-debugging.

---

## Task 0: Create feature branch and explore existing patterns

**Goal:** Confirm the working tree is clean, branch off main, and read the precedent files so later tasks reference real, current line numbers.

**Files:** none modified.

**Step 1: Confirm clean working tree**

Run: `git status`
Expected: `nothing to commit, working tree clean` (the design doc was committed already in `6994c5a`).

If dirty, stop and resolve before proceeding.

**Step 2: Branch**

Run: `git switch -c feat/oc-cost`

**Step 3: Read precedent files**

Read in full:
- `pkgs/pinentry-op/default.nix` — closest analog (inline Python, `buildPythonApplication`, `format = "other"`)
- `pkgs/pinentry-op/pinentry-op.py` — confirms the shebang convention (`#!/usr/bin/env python3` at top, then `cp` + `chmod +x` in installPhase)
- `flake.nix` lines 52-62 — the `localPkgsFor` block where new packages get registered
- `users/dev/home.base.nix` lines 196-226 — the `home.packages` list where `localPkgs.<x>` entries are added
- `.opencode/skills/tracking-cache-costs/analyze.mjs` — the reference behaviour we are porting
- `.opencode/skills/tracking-cache-costs/SKILL.md` — needs rewriting in Task 8

No commit; this is read-only orientation.

---

## Task 1: Scaffold pkgs/oc-cost/ with a no-op CLI

**Goal:** Land an empty-but-importable Python module and a Nix derivation that builds. Defers all logic. Verifies the packaging plumbing before we have anything to package.

**Files:**
- Create: `pkgs/oc-cost/oc_cost.py`
- Create: `pkgs/oc-cost/default.nix`
- Create: `pkgs/oc-cost/README.md`

**Step 1: Create `pkgs/oc-cost/oc_cost.py`**

```python
#!/usr/bin/env python3
"""oc-cost: report OpenCode usage and cost from the local SQLite database."""

from __future__ import annotations

import sys


def main(argv: list[str] | None = None) -> int:
    print("oc-cost: not implemented yet", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
```

**Step 2: Create `pkgs/oc-cost/default.nix`**

Mirror `pkgs/pinentry-op/default.nix` but without the `wrapProgram` (no env vars to inject, no external binaries to bind):

```nix
{ lib
, python3
}:

python3.pkgs.buildPythonApplication {
  pname = "oc-cost";
  version = "0.1.0";
  format = "other";

  src = ./.;

  dontBuild = true;

  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin
    cp oc_cost.py $out/bin/oc-cost
    chmod +x $out/bin/oc-cost

    runHook postInstall
  '';

  meta = with lib; {
    description = "Report OpenCode token usage and API cost from opencode.db";
    license = licenses.mit;
    platforms = platforms.unix;
    mainProgram = "oc-cost";
  };
}
```

**Step 3: Create `pkgs/oc-cost/README.md`**

```markdown
# oc-cost

Report OpenCode token usage and API cost from the local SQLite database
(`~/.local/share/opencode/opencode.db`).

Replaces the older `analyze.mjs` script under
`.opencode/skills/tracking-cache-costs/`.

## Usage

    oc-cost                              # last 14 days, formatted text
    oc-cost --days 30                    # last 30 days
    oc-cost --since 2026-04-01           # from date to now
    oc-cost --since 2026-04-01 --until 2026-04-15
    oc-cost --json                       # machine-readable
    oc-cost --db /path/to/opencode.db    # override DB location

`--days` and `--since/--until` are mutually exclusive.

## Pricing

Anthropic per-model rates are hardcoded in `oc_cost.py` (`PRICES` dict).
Update manually when Anthropic changes rates or you start using a new model.
Source: <https://docs.anthropic.com/en/docs/about-claude/pricing>.

Unknown models appear as `(no rate)` in text output and in the
`unpriced_models` list of JSON output. Their tokens are excluded from the
cost total.

## Design

See `docs/plans/2026-04-20-oc-cost-design.md`.
```

**Step 4: Register in `flake.nix`**

In `flake.nix`, edit lines 52-59 to add `oc-cost` to the `localPkgsFor` set, alphabetically:

```nix
    # Self-packaged tools (updated via nix-update in CI)
    localPkgsFor = system: let p = pkgsFor system; in {
      acli = p.callPackage ./pkgs/acli { };
      beads = p.callPackage ./pkgs/beads { };
      datadog-mcp-cli = p.callPackage ./pkgs/datadog-mcp-cli { };
      gclpr = p.callPackage ./pkgs/gclpr { };
      gws = p.callPackage ./pkgs/gws { };
      oc-cost = p.callPackage ./pkgs/oc-cost { };
    };
```

**Step 5: Verify the package builds**

Run: `nix build .#oc-cost`
Expected: build succeeds, creates `./result` symlink.

Run: `./result/bin/oc-cost`
Expected: prints `oc-cost: not implemented yet` to stderr and exits 0.

If build fails, do not proceed. Fix and retry.

**Step 6: Commit**

```bash
git add pkgs/oc-cost flake.nix
git commit -m "feat(oc-cost): scaffold package (no-op CLI)

Adds pkgs/oc-cost/ with a minimal Python script and Nix derivation
mirroring pkgs/pinentry-op/. Wires into flake.nix's localPkgsFor.
The CLI does nothing yet — subsequent commits add pricing, queries,
and rendering. Source lives inline in this repo (new pattern for
pkgs/) per docs/plans/2026-04-20-oc-cost-design.md."
```

---

## Task 2: Add PRICES table and price_for() with tests

**Goal:** Land the pricing data and lookup function with unit tests. Pure function, no I/O.

**Files:**
- Modify: `pkgs/oc-cost/oc_cost.py`
- Create: `pkgs/oc-cost/test_oc_cost.py`

**Step 1: Write the failing tests**

Create `pkgs/oc-cost/test_oc_cost.py`:

```python
"""Tests for oc-cost. Run: python3 -m unittest pkgs/oc-cost/test_oc_cost.py"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

# Allow `import oc_cost` when running from repo root or anywhere else.
sys.path.insert(0, str(Path(__file__).resolve().parent))

import oc_cost  # noqa: E402


class TestPriceFor(unittest.TestCase):
    def test_exact_match(self):
        rates = oc_cost.price_for("claude-opus-4-6")
        self.assertIsNotNone(rates)
        self.assertEqual(rates["input"], 5)
        self.assertEqual(rates["output"], 25)
        self.assertEqual(rates["cache_write"], 6.25)
        self.assertEqual(rates["cache_read"], 0.50)

    def test_strips_at_suffix(self):
        # Real-world model IDs from opencode.db look like
        # "claude-opus-4-6@default" or "...@vertex".
        rates = oc_cost.price_for("claude-opus-4-6@default")
        self.assertIsNotNone(rates)
        self.assertEqual(rates["input"], 5)

    def test_prefix_fallback(self):
        # Variants like "claude-sonnet-4-5-20251022" should match
        # claude-sonnet-4-5 by prefix.
        rates = oc_cost.price_for("claude-sonnet-4-5-20251022")
        self.assertIsNotNone(rates)
        self.assertEqual(rates["input"], 3)  # sonnet-4-5 input rate

    def test_unknown_returns_none(self):
        self.assertIsNone(oc_cost.price_for("totally-unknown-model"))

    def test_unknown_with_at_suffix_returns_none(self):
        self.assertIsNone(oc_cost.price_for("totally-unknown@default"))


if __name__ == "__main__":
    unittest.main()
```

**Step 2: Run tests, expect failure**

Run: `python3 -m unittest pkgs/oc-cost/test_oc_cost.py -v`
Expected: AttributeError on `oc_cost.price_for` (function not defined yet).

**Step 3: Implement PRICES and price_for**

Edit `pkgs/oc-cost/oc_cost.py` — replace the entire file with:

```python
#!/usr/bin/env python3
"""oc-cost: report OpenCode usage and cost from the local SQLite database."""

from __future__ import annotations

import sys
from typing import Optional

# Anthropic per-model rates in USD per million tokens.
# Source: https://docs.anthropic.com/en/docs/about-claude/pricing
# Update manually when rates change or new models land.
PRICES: dict[str, dict[str, float]] = {
    "claude-opus-4-7": {
        "input": 5, "output": 25, "cache_write": 6.25, "cache_read": 0.50,
    },
    "claude-opus-4-6": {
        "input": 5, "output": 25, "cache_write": 6.25, "cache_read": 0.50,
    },
    "claude-opus-4-5": {
        "input": 5, "output": 25, "cache_write": 6.25, "cache_read": 0.50,
    },
    "claude-opus-4-1": {
        "input": 15, "output": 75, "cache_write": 18.75, "cache_read": 1.50,
    },
    "claude-opus-4": {
        "input": 15, "output": 75, "cache_write": 18.75, "cache_read": 1.50,
    },
    "claude-sonnet-4-6": {
        "input": 3, "output": 15, "cache_write": 3.75, "cache_read": 0.30,
    },
    "claude-sonnet-4-5": {
        "input": 3, "output": 15, "cache_write": 3.75, "cache_read": 0.30,
    },
    "claude-sonnet-4": {
        "input": 3, "output": 15, "cache_write": 3.75, "cache_read": 0.30,
    },
    "claude-haiku-4-5": {
        "input": 1, "output": 5, "cache_write": 1.25, "cache_read": 0.10,
    },
    "claude-haiku-3-5": {
        "input": 0.80, "output": 4, "cache_write": 1.0, "cache_read": 0.08,
    },
}


def price_for(model_id: str) -> Optional[dict[str, float]]:
    """Look up per-million-token rates for a model id.

    Strips an @suffix (e.g. "@default", "@vertex"), tries an exact match,
    then falls back to the longest prefix match in PRICES.
    Returns None if no match is found.
    """
    base = model_id.split("@", 1)[0]
    if base in PRICES:
        return PRICES[base]
    # Longest-prefix match so claude-opus-4-6-foo prefers 4-6 over 4.
    best_key: Optional[str] = None
    for key in PRICES:
        if base.startswith(key):
            if best_key is None or len(key) > len(best_key):
                best_key = key
    return PRICES[best_key] if best_key else None


def main(argv: list[str] | None = None) -> int:
    print("oc-cost: not implemented yet", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
```

Note the **longest-prefix** improvement vs. analyze.mjs's first-match prefix loop. analyze.mjs would happily match `claude-opus-4-1` against the `claude-opus-4` key, returning the older Opus 4 rates instead of the 4.1 rates. Test case `test_prefix_fallback` doesn't catch this because we have a real `claude-sonnet-4-5` entry; we'd notice if 4.1 rates ever changed.

**Step 4: Run tests, expect pass**

Run: `python3 -m unittest pkgs/oc-cost/test_oc_cost.py -v`
Expected: 5 tests, all pass.

**Step 5: Verify nix build still works**

Run: `nix build .#oc-cost && ./result/bin/oc-cost`
Expected: build succeeds; CLI still prints `not implemented yet` (we have not wired anything into main yet).

**Step 6: Commit**

```bash
git add pkgs/oc-cost
git commit -m "feat(oc-cost): add PRICES table and price_for()

Hardcoded Anthropic per-model rates lifted from analyze.mjs, with two
improvements: (1) longest-prefix fallback so claude-opus-4-1 doesn't
silently match the older claude-opus-4 rates, (2) explicit @suffix
stripping. Five unit tests cover exact match, suffix stripping, prefix
fallback, and unknown-model handling."
```

---

## Task 3: Add argparse with --days / --since / --until / --json / --db

**Goal:** Wire up CLI argument parsing. No queries yet; main() just echoes the parsed args so we can test the parsing layer in isolation.

**Files:**
- Modify: `pkgs/oc-cost/oc_cost.py`
- Modify: `pkgs/oc-cost/test_oc_cost.py`

**Step 1: Write the failing tests**

Append to `pkgs/oc-cost/test_oc_cost.py`:

```python
class TestParseArgs(unittest.TestCase):
    def test_defaults(self):
        args = oc_cost.parse_args([])
        self.assertEqual(args.days, 14)
        self.assertIsNone(args.since)
        self.assertIsNone(args.until)
        self.assertFalse(args.json)
        self.assertIsNone(args.db)

    def test_days(self):
        args = oc_cost.parse_args(["--days", "30"])
        self.assertEqual(args.days, 30)

    def test_days_must_be_positive(self):
        with self.assertRaises(SystemExit):
            oc_cost.parse_args(["--days", "0"])
        with self.assertRaises(SystemExit):
            oc_cost.parse_args(["--days", "-1"])

    def test_since_until(self):
        args = oc_cost.parse_args(["--since", "2026-04-01", "--until", "2026-04-15"])
        self.assertEqual(args.since, "2026-04-01")
        self.assertEqual(args.until, "2026-04-15")

    def test_days_mutex_with_since(self):
        with self.assertRaises(SystemExit):
            oc_cost.parse_args(["--days", "7", "--since", "2026-04-01"])

    def test_days_mutex_with_until(self):
        with self.assertRaises(SystemExit):
            oc_cost.parse_args(["--days", "7", "--until", "2026-04-15"])

    def test_json_flag(self):
        args = oc_cost.parse_args(["--json"])
        self.assertTrue(args.json)

    def test_db_path(self):
        args = oc_cost.parse_args(["--db", "/tmp/x.db"])
        self.assertEqual(args.db, "/tmp/x.db")
```

**Step 2: Run tests, expect failure**

Run: `python3 -m unittest pkgs/oc-cost/test_oc_cost.py -v`
Expected: AttributeError on `oc_cost.parse_args`.

**Step 3: Implement parse_args**

In `pkgs/oc-cost/oc_cost.py`, add this above `main()`:

```python
import argparse


def _positive_int(value: str) -> int:
    n = int(value)
    if n <= 0:
        raise argparse.ArgumentTypeError(f"must be a positive integer, got {value}")
    return n


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    """Parse CLI arguments.

    --days and --since/--until are mutually exclusive. We enforce this with
    a custom check rather than argparse's add_mutually_exclusive_group
    because we want --days to coexist with neither --since nor --until being
    given (the default), but reject --days alongside *either* of them.
    """
    parser = argparse.ArgumentParser(
        prog="oc-cost",
        description=(
            "Report OpenCode token usage and API cost "
            "from ~/.local/share/opencode/opencode.db."
        ),
    )
    parser.add_argument(
        "--days", type=_positive_int, default=14,
        help="Look back N days (default: 14). Mutually exclusive with --since/--until.",
    )
    parser.add_argument("--since", help="ISO date YYYY-MM-DD (UTC midnight).")
    parser.add_argument("--until", help="ISO date YYYY-MM-DD (exclusive UTC midnight).")
    parser.add_argument("--json", action="store_true", help="Emit JSON instead of formatted text.")
    parser.add_argument("--db", help="Override path to opencode.db.")

    args = parser.parse_args(argv)

    days_explicit = "--days" in (argv or [])
    if days_explicit and (args.since or args.until):
        parser.error("--days cannot be combined with --since/--until")

    return args
```

Replace `main()` to echo for now:

```python
def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    print(f"args = {args!r}", file=sys.stderr)
    return 0
```

**Step 4: Run tests, expect pass**

Run: `python3 -m unittest pkgs/oc-cost/test_oc_cost.py -v`
Expected: all tests pass (5 from Task 2 + 8 new = 13).

**Step 5: Smoke-check the CLI**

Run: `nix build .#oc-cost && ./result/bin/oc-cost --days 7`
Expected: stderr shows `args = Namespace(days=7, since=None, until=None, json=False, db=None)`, exit 0.

Run: `./result/bin/oc-cost --days 7 --since 2026-04-01`
Expected: stderr shows argparse error, non-zero exit.

**Step 6: Commit**

```bash
git add pkgs/oc-cost
git commit -m "feat(oc-cost): add CLI arg parsing with mutex windows

argparse-based: --days N (positive int, default 14), --since/--until
(YYYY-MM-DD), --json, --db. --days is mutually exclusive with
--since/--until. 8 new tests cover defaults, mutex enforcement, and
positive-int validation."
```

---

## Task 4: Add resolve_window() with tests

**Goal:** Convert parsed args into `(start_ms, end_ms)` unix-millisecond bounds. Pure function; takes `now_ms` as a parameter so tests can pin time.

**Files:**
- Modify: `pkgs/oc-cost/oc_cost.py`
- Modify: `pkgs/oc-cost/test_oc_cost.py`

**Step 1: Write the failing tests**

Append to `pkgs/oc-cost/test_oc_cost.py`:

```python
class TestResolveWindow(unittest.TestCase):
    # Pinned "now" for deterministic tests: 2026-04-20T12:00:00Z
    NOW_MS = 1808841600000  # see: date -d 2026-04-20T12:00:00Z +%s%3N

    def test_days_default(self):
        args = oc_cost.parse_args([])
        start, end = oc_cost.resolve_window(args, self.NOW_MS)
        self.assertEqual(end, self.NOW_MS)
        self.assertEqual(start, self.NOW_MS - 14 * 86_400_000)

    def test_days_custom(self):
        args = oc_cost.parse_args(["--days", "7"])
        start, end = oc_cost.resolve_window(args, self.NOW_MS)
        self.assertEqual(end - start, 7 * 86_400_000)

    def test_since_only(self):
        args = oc_cost.parse_args(["--since", "2026-04-01"])
        start, end = oc_cost.resolve_window(args, self.NOW_MS)
        # 2026-04-01T00:00:00Z = 1806796800000
        self.assertEqual(start, 1806796800000)
        self.assertEqual(end, self.NOW_MS)

    def test_since_and_until(self):
        args = oc_cost.parse_args(["--since", "2026-04-01", "--until", "2026-04-15"])
        start, end = oc_cost.resolve_window(args, self.NOW_MS)
        self.assertEqual(start, 1806796800000)            # 2026-04-01
        # --until is *exclusive* end-of-day: 2026-04-16T00:00:00Z
        self.assertEqual(end, 1806796800000 + 15 * 86_400_000)

    def test_until_only(self):
        args = oc_cost.parse_args(["--until", "2026-04-15"])
        start, end = oc_cost.resolve_window(args, self.NOW_MS)
        self.assertEqual(start, 0)
        self.assertEqual(end, 1806796800000 + 14 * 86_400_000)  # 2026-04-16T00:00:00Z

    def test_malformed_since(self):
        args = oc_cost.parse_args(["--since", "not-a-date"])
        with self.assertRaises(ValueError):
            oc_cost.resolve_window(args, self.NOW_MS)
```

**Step 2: Run tests, expect failure**

Run: `python3 -m unittest pkgs/oc-cost/test_oc_cost.py -v`
Expected: AttributeError on `oc_cost.resolve_window`.

**Step 3: Implement resolve_window**

Add to `oc_cost.py`:

```python
from datetime import datetime, timezone


def _parse_date_to_ms(s: str, end_of_day: bool = False) -> int:
    """Parse YYYY-MM-DD as UTC midnight, return unix milliseconds.

    If end_of_day, return the *next* day's UTC midnight (exclusive end).
    Raises ValueError on malformed input.
    """
    dt = datetime.strptime(s, "%Y-%m-%d").replace(tzinfo=timezone.utc)
    if end_of_day:
        # Add 1 day so --until 2026-04-15 includes all of April 15.
        dt = dt.replace(hour=0, minute=0, second=0)
        return int(dt.timestamp() * 1000) + 86_400_000
    return int(dt.timestamp() * 1000)


def resolve_window(args: argparse.Namespace, now_ms: int) -> tuple[int, int]:
    """Return (start_ms, end_ms) for the requested window."""
    if args.since or args.until:
        start = _parse_date_to_ms(args.since) if args.since else 0
        end = _parse_date_to_ms(args.until, end_of_day=True) if args.until else now_ms
        return start, end
    return now_ms - args.days * 86_400_000, now_ms
```

**Step 4: Run tests**

Run: `python3 -m unittest pkgs/oc-cost/test_oc_cost.py -v`
Expected: 13 + 6 = 19 tests pass.

**Step 5: Sanity-check NOW_MS values**

Verify the magic numbers in tests are right:

Run: `date -u -d "2026-04-20T12:00:00Z" +%s%3N`
Expected: `1808841600000`

Run: `date -u -d "2026-04-01T00:00:00Z" +%s%3N`
Expected: `1806796800000`

If either is off, fix the test constants — the implementation is correct.

**Step 6: Commit**

```bash
git add pkgs/oc-cost
git commit -m "feat(oc-cost): add resolve_window() for time bounds

Converts parsed args into (start_ms, end_ms) unix-millisecond bounds
suitable for SQL parameter binding. --since/--until both UTC; --until
is end-of-day inclusive (i.e. exclusive next-day midnight). 6 new
tests pin time deterministically via injected now_ms."
```

---

## Task 5: Add SQL queries with in-memory fixture tests

**Goal:** Three query functions (`query_daily`, `query_by_model`, `query_size_buckets`) that take a sqlite3 connection plus `(start_ms, end_ms)` and return list-of-dict results. Tests build in-memory DBs matching opencode.db's schema.

**Files:**
- Modify: `pkgs/oc-cost/oc_cost.py`
- Modify: `pkgs/oc-cost/test_oc_cost.py`

**Step 1: Write the test fixture helper**

Append to `pkgs/oc-cost/test_oc_cost.py`:

```python
import json
import sqlite3


def make_test_db(messages: list[dict]) -> sqlite3.Connection:
    """Build an in-memory SQLite DB matching opencode.db's schema.

    Each `messages` dict needs keys: id, session_id, time_created (ms),
    and message-data fields (role, modelID, providerID, tokens). We wrap
    the message-data fields into a JSON string for the `data` column.
    """
    conn = sqlite3.connect(":memory:")
    conn.execute(
        """
        CREATE TABLE message (
            id text PRIMARY KEY,
            session_id text NOT NULL,
            time_created integer NOT NULL,
            time_updated integer NOT NULL,
            data text NOT NULL
        )
        """
    )
    for m in messages:
        data = {k: v for k, v in m.items() if k not in ("id", "session_id", "time_created")}
        conn.execute(
            "INSERT INTO message (id, session_id, time_created, time_updated, data) "
            "VALUES (?, ?, ?, ?, ?)",
            (m["id"], m["session_id"], m["time_created"], m["time_created"], json.dumps(data)),
        )
    conn.commit()
    conn.row_factory = sqlite3.Row
    return conn


def assistant_msg(
    msg_id: str,
    session_id: str,
    time_ms: int,
    model: str = "claude-opus-4-6",
    provider: str = "anthropic",
    cache_read: int = 0,
    cache_write: int = 0,
    inp: int = 0,
    out: int = 0,
) -> dict:
    return {
        "id": msg_id,
        "session_id": session_id,
        "time_created": time_ms,
        "role": "assistant",
        "modelID": model,
        "providerID": provider,
        "tokens": {
            "input": inp,
            "output": out,
            "cache": {"read": cache_read, "write": cache_write},
        },
    }
```

**Step 2: Write the failing query tests**

Append to `pkgs/oc-cost/test_oc_cost.py`:

```python
DAY_MS = 86_400_000


class TestQueryDaily(unittest.TestCase):
    def test_groups_by_day_and_sums_tokens(self):
        # Three messages on day 0, one on day 1.
        d0 = 1800000000000  # arbitrary base
        msgs = [
            assistant_msg("m1", "s1", d0 + 1000, cache_read=100, cache_write=10, inp=5, out=20),
            assistant_msg("m2", "s1", d0 + 2000, cache_read=200, cache_write=20, inp=5, out=40),
            assistant_msg("m3", "s2", d0 + 3000, cache_read=300, cache_write=30, inp=5, out=60),
            assistant_msg("m4", "s1", d0 + DAY_MS + 1000, cache_read=50, cache_write=5, inp=1, out=10),
        ]
        conn = make_test_db(msgs)
        rows = oc_cost.query_daily(conn, d0, d0 + 2 * DAY_MS)
        self.assertEqual(len(rows), 2)
        self.assertEqual(rows[0]["msgs"], 3)
        self.assertEqual(rows[0]["cache_read"], 600)
        self.assertEqual(rows[0]["cache_write"], 60)
        self.assertEqual(rows[0]["uncached"], 15)
        self.assertEqual(rows[0]["output"], 120)
        self.assertEqual(rows[1]["msgs"], 1)

    def test_excludes_messages_without_cache_read(self):
        d0 = 1800000000000
        good = assistant_msg("m1", "s1", d0 + 1000, cache_read=100, inp=5, out=20)
        # User message; should be filtered by role.
        user = {
            "id": "u1", "session_id": "s1", "time_created": d0 + 1500,
            "role": "user", "tokens": {"input": 0, "output": 0, "cache": {"read": 0}},
        }
        # Assistant but no cache.read field — non-Anthropic provider.
        no_cache = {
            "id": "m2", "session_id": "s1", "time_created": d0 + 2000,
            "role": "assistant", "modelID": "gpt-5", "providerID": "openai",
            "tokens": {"input": 100, "output": 50},  # no cache key
        }
        conn = make_test_db([good, user, no_cache])
        rows = oc_cost.query_daily(conn, d0, d0 + DAY_MS)
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["msgs"], 1)

    def test_filters_by_window(self):
        d0 = 1800000000000
        before = assistant_msg("m0", "s1", d0 - 1000, cache_read=999)
        inside = assistant_msg("m1", "s1", d0 + 1000, cache_read=100, inp=5)
        after = assistant_msg("m2", "s1", d0 + DAY_MS + 1, cache_read=999)
        conn = make_test_db([before, inside, after])
        rows = oc_cost.query_daily(conn, d0, d0 + DAY_MS)
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["cache_read"], 100)


class TestQueryByModel(unittest.TestCase):
    def test_groups_by_model_orders_by_cache_read_desc(self):
        d0 = 1800000000000
        msgs = [
            assistant_msg("m1", "s1", d0 + 1000, model="claude-opus-4-6", cache_read=500, out=100),
            assistant_msg("m2", "s1", d0 + 2000, model="claude-sonnet-4-6", cache_read=1000, out=50),
            assistant_msg("m3", "s1", d0 + 3000, model="claude-opus-4-6", cache_read=200, out=30),
        ]
        conn = make_test_db(msgs)
        rows = oc_cost.query_by_model(conn, d0, d0 + DAY_MS)
        self.assertEqual(len(rows), 2)
        self.assertEqual(rows[0]["model"], "claude-sonnet-4-6")
        self.assertEqual(rows[0]["cache_read"], 1000)
        self.assertEqual(rows[1]["model"], "claude-opus-4-6")
        self.assertEqual(rows[1]["cache_read"], 700)
        self.assertEqual(rows[1]["output"], 130)


class TestQuerySizeBuckets(unittest.TestCase):
    def test_buckets(self):
        d0 = 1800000000000
        # prompt_size = cache_read + cache_write + input
        msgs = [
            assistant_msg("a", "s", d0 + 1, cache_read=10_000),    # 0-50k
            assistant_msg("b", "s", d0 + 2, cache_read=60_000),    # 50-100k
            assistant_msg("c", "s", d0 + 3, cache_read=120_000),   # 100-150k
            assistant_msg("d", "s", d0 + 4, cache_read=180_000),   # 150-200k
            assistant_msg("e", "s", d0 + 5, cache_read=250_000),   # 200-300k
            assistant_msg("f", "s", d0 + 6, cache_read=400_000),   # 300k+
        ]
        conn = make_test_db(msgs)
        rows = oc_cost.query_size_buckets(conn, d0, d0 + DAY_MS)
        buckets = {r["bucket"]: r["msgs"] for r in rows}
        self.assertEqual(buckets["0-50k"], 1)
        self.assertEqual(buckets["50-100k"], 1)
        self.assertEqual(buckets["100-150k"], 1)
        self.assertEqual(buckets["150-200k"], 1)
        self.assertEqual(buckets["200-300k"], 1)
        self.assertEqual(buckets["300k+"], 1)
```

**Step 3: Run tests, expect failure**

Run: `python3 -m unittest pkgs/oc-cost/test_oc_cost.py -v`
Expected: AttributeError on the three query functions.

**Step 4: Implement the queries**

Add to `oc_cost.py`:

```python
import sqlite3


# Reused WHERE clause keeps the three queries in sync.
_BASE_WHERE = """
    json_extract(data, '$.role') = 'assistant'
    AND json_extract(data, '$.tokens.cache.read') IS NOT NULL
    AND time_created BETWEEN :start_ms AND :end_ms
"""


def query_daily(conn: sqlite3.Connection, start_ms: int, end_ms: int) -> list[dict]:
    cur = conn.execute(
        f"""
        SELECT date(time_created/1000, 'unixepoch') AS day,
               COUNT(*) AS msgs,
               SUM(COALESCE(json_extract(data, '$.tokens.cache.read'),  0)) AS cache_read,
               SUM(COALESCE(json_extract(data, '$.tokens.cache.write'), 0)) AS cache_write,
               SUM(COALESCE(json_extract(data, '$.tokens.input'),       0)) AS uncached,
               SUM(COALESCE(json_extract(data, '$.tokens.output'),      0)) AS output
        FROM message
        WHERE {_BASE_WHERE}
        GROUP BY day ORDER BY day
        """,
        {"start_ms": start_ms, "end_ms": end_ms},
    )
    return [dict(r) for r in cur.fetchall()]


def query_by_model(conn: sqlite3.Connection, start_ms: int, end_ms: int) -> list[dict]:
    cur = conn.execute(
        f"""
        SELECT json_extract(data, '$.modelID') AS model,
               COUNT(*) AS msgs,
               SUM(COALESCE(json_extract(data, '$.tokens.cache.read'),  0)) AS cache_read,
               SUM(COALESCE(json_extract(data, '$.tokens.cache.write'), 0)) AS cache_write,
               SUM(COALESCE(json_extract(data, '$.tokens.input'),       0)) AS uncached,
               SUM(COALESCE(json_extract(data, '$.tokens.output'),      0)) AS output
        FROM message
        WHERE {_BASE_WHERE}
        GROUP BY model ORDER BY cache_read DESC
        """,
        {"start_ms": start_ms, "end_ms": end_ms},
    )
    return [dict(r) for r in cur.fetchall()]


def query_size_buckets(conn: sqlite3.Connection, start_ms: int, end_ms: int) -> list[dict]:
    cur = conn.execute(
        f"""
        WITH per_msg AS (
            SELECT
                COALESCE(json_extract(data, '$.tokens.cache.read'),  0) +
                COALESCE(json_extract(data, '$.tokens.cache.write'), 0) +
                COALESCE(json_extract(data, '$.tokens.input'),       0) AS prompt_size
            FROM message
            WHERE {_BASE_WHERE}
        )
        SELECT
            CASE
                WHEN prompt_size <=  50000 THEN '0-50k'
                WHEN prompt_size <= 100000 THEN '50-100k'
                WHEN prompt_size <= 150000 THEN '100-150k'
                WHEN prompt_size <= 200000 THEN '150-200k'
                WHEN prompt_size <= 300000 THEN '200-300k'
                ELSE '300k+'
            END AS bucket,
            COUNT(*) AS msgs,
            MIN(prompt_size) AS min_size,
            MAX(prompt_size) AS max_size
        FROM per_msg
        GROUP BY bucket ORDER BY MIN(prompt_size)
        """,
        {"start_ms": start_ms, "end_ms": end_ms},
    )
    return [dict(r) for r in cur.fetchall()]
```

The `conn.row_factory = sqlite3.Row` set by `make_test_db` makes `dict(r)` work naturally. We'll set the same on the real connection in Task 7.

**Step 5: Run tests**

Run: `python3 -m unittest pkgs/oc-cost/test_oc_cost.py -v`
Expected: 19 + (3 + 1 + 1) = 24 tests pass.

**Step 6: Commit**

```bash
git add pkgs/oc-cost
git commit -m "feat(oc-cost): add SQL queries against in-memory fixtures

Three functions query the message table for daily, per-model, and
prompt-size aggregations, all with bound :start_ms/:end_ms parameters
and the same role/cache-read filter. 5 new tests build in-memory
DBs matching opencode.db's schema and verify grouping, ordering,
filtering, and bucket boundaries."
```

---

## Task 6: Add cost components computation with two correctness fixes

**Goal:** Compute `cost_components` from per-model query results, applying each model's own rates per component and surfacing unknown models. This is where the two correctness improvements over `analyze.mjs` live.

**Files:**
- Modify: `pkgs/oc-cost/oc_cost.py`
- Modify: `pkgs/oc-cost/test_oc_cost.py`

**Step 1: Write the failing tests**

Append to `pkgs/oc-cost/test_oc_cost.py`:

```python
class TestCostComponents(unittest.TestCase):
    def test_per_model_rates_applied_separately(self):
        # CORRECTNESS FIX #1: components must use each model's own rates,
        # not the dominant model's rates.
        by_model = [
            {"model": "claude-opus-4-6", "msgs": 1, "cache_read": 1_000_000,
             "cache_write": 0, "uncached": 0, "output": 0},
            {"model": "claude-sonnet-4-6", "msgs": 1, "cache_read": 1_000_000,
             "cache_write": 0, "uncached": 0, "output": 0},
        ]
        components = oc_cost.compute_cost_components(by_model, active_days=1)
        # Opus cache_read = $0.50/M, Sonnet cache_read = $0.30/M.
        # Total cache_reads = 1.00 * 0.50 + 1.00 * 0.30 = $0.80
        self.assertAlmostEqual(components["cache_reads"], 0.80, places=4)
        self.assertAlmostEqual(components["total"], 0.80, places=4)
        self.assertEqual(components["unpriced_models"], [])

    def test_unknown_models_excluded_from_total(self):
        # CORRECTNESS FIX #2: unknown-rate rows are excluded from cost
        # totals and surfaced in unpriced_models.
        by_model = [
            {"model": "claude-opus-4-6", "msgs": 1, "cache_read": 1_000_000,
             "cache_write": 0, "uncached": 0, "output": 0},
            {"model": "future-model-9000", "msgs": 1, "cache_read": 999_999_999,
             "cache_write": 0, "uncached": 0, "output": 0},
        ]
        components = oc_cost.compute_cost_components(by_model, active_days=1)
        # Only the priced opus row contributes: 1.0M * $0.50 = $0.50
        self.assertAlmostEqual(components["cache_reads"], 0.50, places=4)
        self.assertAlmostEqual(components["total"], 0.50, places=4)
        self.assertEqual(components["unpriced_models"], ["future-model-9000"])

    def test_includes_per_model_cost_in_by_model(self):
        # by_model rows should be annotated with their own cost_usd in place.
        by_model = [
            {"model": "claude-opus-4-6", "msgs": 1, "cache_read": 1_000_000,
             "cache_write": 0, "uncached": 0, "output": 0},
        ]
        oc_cost.compute_cost_components(by_model, active_days=1)
        self.assertAlmostEqual(by_model[0]["cost_usd"], 0.50, places=4)

    def test_unknown_model_gets_none_cost(self):
        by_model = [
            {"model": "future-model-9000", "msgs": 1, "cache_read": 1_000_000,
             "cache_write": 0, "uncached": 0, "output": 0},
        ]
        oc_cost.compute_cost_components(by_model, active_days=1)
        self.assertIsNone(by_model[0]["cost_usd"])

    def test_daily_avg_and_monthly_proj(self):
        by_model = [
            {"model": "claude-opus-4-6", "msgs": 1, "cache_read": 0,
             "cache_write": 1_000_000, "uncached": 0, "output": 0},
        ]
        components = oc_cost.compute_cost_components(by_model, active_days=2)
        # 1.0M * $6.25 cache_write = $6.25 over 2 days.
        self.assertAlmostEqual(components["total"], 6.25, places=4)
        self.assertAlmostEqual(components["daily_avg"], 3.125, places=4)
        self.assertAlmostEqual(components["monthly_proj"], 3.125 * 30, places=4)
```

**Step 2: Run tests, expect failure**

Run: `python3 -m unittest pkgs/oc-cost/test_oc_cost.py -v`
Expected: AttributeError on `compute_cost_components`.

**Step 3: Implement compute_cost_components**

Add to `oc_cost.py`:

```python
def compute_cost_components(by_model: list[dict], active_days: int) -> dict:
    """Compute cost components, applying each model's own rates.

    Mutates each `by_model` row in place to add `cost_usd` (None for
    unknown models). Returns a dict with per-component totals plus
    daily_avg, monthly_proj, and a list of unpriced model names.
    """
    cache_reads = cache_writes = uncached_input = output = 0.0
    unpriced: list[str] = []

    for row in by_model:
        rates = price_for(row["model"])
        if rates is None:
            row["cost_usd"] = None
            unpriced.append(row["model"])
            continue
        # USD = tokens * rate / 1e6
        cr = row["cache_read"]  * rates["cache_read"]  / 1e6
        cw = row["cache_write"] * rates["cache_write"] / 1e6
        un = row["uncached"]    * rates["input"]       / 1e6
        ou = row["output"]      * rates["output"]      / 1e6
        row["cost_usd"] = cr + cw + un + ou
        cache_reads    += cr
        cache_writes   += cw
        uncached_input += un
        output         += ou

    total = cache_reads + cache_writes + uncached_input + output
    daily_avg = total / active_days if active_days > 0 else 0.0

    return {
        "cache_reads":     cache_reads,
        "cache_writes":    cache_writes,
        "uncached_input":  uncached_input,
        "output":          output,
        "total":           total,
        "daily_avg":       daily_avg,
        "monthly_proj":    daily_avg * 30,
        "unpriced_models": unpriced,
    }
```

**Step 4: Run tests**

Run: `python3 -m unittest pkgs/oc-cost/test_oc_cost.py -v`
Expected: 24 + 5 = 29 tests pass.

**Step 5: Commit**

```bash
git add pkgs/oc-cost
git commit -m "feat(oc-cost): compute cost components per-model

Applies each model's own rates per component, instead of analyze.mjs's
dominant-model approximation, and surfaces unknown-model token counts
via an unpriced_models list rather than including them silently in
totals at zero cost. Mutates each by_model row in place to add a
cost_usd field (None when no rate is found). 5 new tests cover both
correctness fixes plus daily_avg / monthly_proj math."
```

---

## Task 7: Wire main() — connect, query, render text and JSON

**Goal:** Make the CLI actually work end-to-end. Adds DB connection (read-only), top-level orchestration in `main()`, text renderer (mirrors `analyze.mjs` layout), and JSON renderer.

**Files:**
- Modify: `pkgs/oc-cost/oc_cost.py`
- Modify: `pkgs/oc-cost/test_oc_cost.py`

**Step 1: Write the failing tests**

Append to `pkgs/oc-cost/test_oc_cost.py`:

```python
class TestRenderJson(unittest.TestCase):
    def test_schema(self):
        report = {
            "meta": {
                "db_path": "/x/y.db",
                "window": {"start": "2026-04-06T00:00:00Z", "end": "2026-04-20T00:00:00Z"},
                "active_days": 14,
            },
            "daily": [{"day": "2026-04-06", "msgs": 1, "cache_read": 100,
                       "cache_write": 10, "uncached": 5, "output": 20}],
            "by_model": [{"model": "claude-opus-4-6", "msgs": 1,
                          "cache_read": 100, "cache_write": 10,
                          "uncached": 5, "output": 20, "cost_usd": 0.5}],
            "cost_components": {
                "cache_reads": 0.1, "cache_writes": 0.2, "uncached_input": 0.3,
                "output": 0.4, "total": 1.0, "daily_avg": 0.07,
                "monthly_proj": 2.1, "unpriced_models": [],
            },
            "size_buckets": [{"bucket": "0-50k", "msgs": 1, "min_size": 100, "max_size": 100}],
        }
        out = oc_cost.render_json(report)
        parsed = json.loads(out)
        self.assertEqual(set(parsed.keys()),
                         {"meta", "daily", "by_model", "cost_components", "size_buckets"})
        self.assertEqual(parsed["cost_components"]["total"], 1.0)


class TestConnect(unittest.TestCase):
    def test_missing_db_raises_systemexit(self):
        with self.assertRaises(SystemExit):
            oc_cost.connect("/nonexistent/path/to/opencode.db")

    def test_wrong_schema_raises_systemexit(self):
        # Create a real (but empty) sqlite file with no `message` table.
        import tempfile
        with tempfile.NamedTemporaryFile(suffix=".db", delete=False) as f:
            path = f.name
        try:
            sqlite3.connect(path).execute("CREATE TABLE other (x int)").connection.commit()
            with self.assertRaises(SystemExit):
                oc_cost.connect(path)
        finally:
            import os
            os.unlink(path)
```

**Step 2: Run tests, expect failure**

Run: `python3 -m unittest pkgs/oc-cost/test_oc_cost.py -v`
Expected: AttributeError on `render_json` and `connect`.

**Step 3: Implement connect, renderers, and updated main()**

Add to `oc_cost.py`:

```python
import json
import os
from datetime import datetime, timezone


_DEFAULT_DB = os.path.expanduser("~/.local/share/opencode/opencode.db")


def connect(db_path: str) -> sqlite3.Connection:
    """Open opencode.db in read-only mode. Exits 1 on missing or wrong-schema DB."""
    if not os.path.exists(db_path):
        print(
            f"Database not found: {db_path}. "
            f"Set --db or check OPENCODE_DATA_DIR.",
            file=sys.stderr,
        )
        sys.exit(1)
    uri = f"file:{db_path}?mode=ro"
    conn = sqlite3.connect(uri, uri=True)
    conn.row_factory = sqlite3.Row
    # Confirm it's an OpenCode DB.
    cur = conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='message'"
    )
    if cur.fetchone() is None:
        print(
            f"Not an OpenCode database (missing 'message' table): {db_path}",
            file=sys.stderr,
        )
        sys.exit(1)
    return conn


def _fmt_usd(n: float) -> str:
    return f"${n:.2f}"


def _pct(part: float, total: float) -> str:
    return f"{(part / total * 100):.1f}" if total > 0 else "0.0"


def _ms_to_iso(ms: int) -> str:
    return datetime.fromtimestamp(ms / 1000, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def render_json(report: dict) -> str:
    return json.dumps(report, indent=2, sort_keys=True)


def render_text(report: dict) -> str:
    lines: list[str] = []
    daily = report["daily"]
    by_model = report["by_model"]
    components = report["cost_components"]
    buckets = report["size_buckets"]
    meta = report["meta"]

    if not daily:
        lines.append(
            f"\n  No usage data in window {meta['window']['start']} → "
            f"{meta['window']['end']}.\n"
        )
        lines.append(f"Database: {meta['db_path']}\n")
        return "\n".join(lines)

    # Daily section
    lines.append(f"\n  OpenCode Usage Report ({meta['active_days']} active days)\n")
    lines.append("DATE        MSGS   READ%  WRITE%  UNCACHED%")
    lines.append("-" * 52)
    for d in daily:
        total = d["cache_read"] + d["cache_write"] + d["uncached"]
        lines.append(
            f"{d['day']}  {str(d['msgs']):>5}  "
            f"{_pct(d['cache_read'], total):>5}%  "
            f"{_pct(d['cache_write'], total):>5}%    "
            f"{_pct(d['uncached'], total):>5}%"
        )

    # Per-model section
    lines.append("\n\n  Per-Model Cost Breakdown\n")
    lines.append("MODEL                          MSGS   CACHE_RD(M)  CACHE_WR(M)  OUTPUT(M)   COST")
    lines.append("-" * 90)
    grand_cache_read = grand_cache_write = grand_output = 0
    grand_total = 0.0
    for m in by_model:
        cr_M = m["cache_read"]  / 1e6
        cw_M = m["cache_write"] / 1e6
        ou_M = m["output"]      / 1e6
        grand_cache_read  += m["cache_read"]
        grand_cache_write += m["cache_write"]
        grand_output      += m["output"]
        if m["cost_usd"] is not None:
            grand_total += m["cost_usd"]
            cost_tag = _fmt_usd(m["cost_usd"]).rjust(10)
        else:
            cost_tag = "  (no rate)"
        name = m["model"][:28] + ".." if len(m["model"]) > 28 else m["model"]
        lines.append(
            f"{name:<30} {str(m['msgs']):>5}  "
            f"{cr_M:>10.1f}  {cw_M:>10.1f}  {ou_M:>8.1f}  {cost_tag}"
        )
    lines.append("-" * 90)
    lines.append(
        f"{'TOTAL':<30} {'':>5}  "
        f"{grand_cache_read / 1e6:>10.1f}  "
        f"{grand_cache_write / 1e6:>10.1f}  "
        f"{grand_output / 1e6:>8.1f}  "
        f"{_fmt_usd(grand_total):>10}"
    )

    # Cost components section
    total = components["total"]
    lines.append("\n\n  Cost Components (per-model rates applied separately)\n")
    lines.append(
        f"  Cache reads:   {_fmt_usd(components['cache_reads']):>10}  "
        f"({_pct(components['cache_reads'], total)}%)"
    )
    lines.append(
        f"  Cache writes:  {_fmt_usd(components['cache_writes']):>10}  "
        f"({_pct(components['cache_writes'], total)}%)"
    )
    lines.append(
        f"  Uncached in:   {_fmt_usd(components['uncached_input']):>10}  "
        f"({_pct(components['uncached_input'], total)}%)"
    )
    lines.append(
        f"  Output:        {_fmt_usd(components['output']):>10}  "
        f"({_pct(components['output'], total)}%)"
    )
    lines.append(f"  {'─' * 30}")
    lines.append(f"  Total:         {_fmt_usd(total):>10}")
    lines.append(f"  Daily avg:     {_fmt_usd(components['daily_avg']):>10}")
    lines.append(f"  Monthly proj:  {_fmt_usd(components['monthly_proj']):>10}")
    if components["unpriced_models"]:
        lines.append(
            f"\n  Unpriced models (excluded from total): "
            f"{', '.join(components['unpriced_models'])}"
        )

    # Size buckets section
    total_msgs = sum(b["msgs"] for b in buckets)
    lines.append("\n\n  Prompt Size Distribution\n")
    lines.append("BUCKET       MSGS    %     MIN(k)   MAX(k)")
    lines.append("-" * 50)
    for b in buckets:
        lines.append(
            f"{b['bucket']:<12} {str(b['msgs']):>5}  "
            f"{_pct(b['msgs'], total_msgs):>5}%  "
            f"{b['min_size'] / 1000:>7.1f}  "
            f"{b['max_size'] / 1000:>7.1f}"
        )

    lines.append(
        f"\nPeriod: {daily[0]['day']} to {daily[-1]['day']} "
        f"({len(daily)} active days)"
    )
    lines.append(f"Database: {meta['db_path']}\n")
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    db_path = args.db or _DEFAULT_DB
    now_ms = int(datetime.now(tz=timezone.utc).timestamp() * 1000)
    start_ms, end_ms = resolve_window(args, now_ms)

    try:
        conn = connect(db_path)
    except SystemExit:
        raise

    try:
        daily   = query_daily(conn, start_ms, end_ms)
        by_model = query_by_model(conn, start_ms, end_ms)
        buckets = query_size_buckets(conn, start_ms, end_ms)
    except sqlite3.OperationalError as e:
        if "locked" in str(e).lower():
            print("Database busy. Retry in a moment.", file=sys.stderr)
            return 2
        raise

    components = compute_cost_components(by_model, active_days=max(len(daily), 1))

    report = {
        "meta": {
            "db_path": db_path,
            "window": {"start": _ms_to_iso(start_ms), "end": _ms_to_iso(end_ms)},
            "active_days": len(daily),
        },
        "daily": daily,
        "by_model": by_model,
        "cost_components": components,
        "size_buckets": buckets,
    }

    if args.json:
        print(render_json(report))
    else:
        print(render_text(report))
    return 0
```

**Step 4: Run tests**

Run: `python3 -m unittest pkgs/oc-cost/test_oc_cost.py -v`
Expected: 29 + 3 = 32 tests pass.

**Step 5: Verify build and end-to-end behaviour**

Run: `nix build .#oc-cost`
Expected: success.

Run: `./result/bin/oc-cost --days 7`
Expected: Real output similar to `analyze.mjs`'s, against the live opencode.db on cloudbox.

Run: `./result/bin/oc-cost --days 7 --json | python3 -c "import json, sys; print(sorted(json.load(sys.stdin).keys()))"`
Expected: `['by_model', 'cost_components', 'daily', 'meta', 'size_buckets']`

Run: `./result/bin/oc-cost --since 2099-01-01`
Expected: prints "No usage data in window..." message, exits 0.

Run: `./result/bin/oc-cost --db /nonexistent`
Expected: prints "Database not found: ..." to stderr, exits 1.

Optional sanity check (eyeball comparison):

Run: `./result/bin/oc-cost --days 14 > /tmp/oc-cost.out`
Run: `node .opencode/skills/tracking-cache-costs/analyze.mjs > /tmp/analyze.out 2>&1`
Run: `diff /tmp/analyze.out /tmp/oc-cost.out | head -50`

Expected: differences only in:
- Header text ("OpenCode Usage Report (last 14 days)" vs "(N active days)")
- Cost Components header (notes "per-model rates" in oc-cost)
- Per-model cost subtotals (different because of fix #1)
- Cost component values (different because of fix #1)
- "Unpriced models" line if any unknown models present (fix #2)
- Trailing pricing-note paragraph from analyze.mjs absent in oc-cost

Numerical totals at the per-model level (`COST` column) should match exactly except where a model is unpriced.

**Step 6: Commit**

```bash
git add pkgs/oc-cost
git commit -m "feat(oc-cost): wire end-to-end CLI

Adds connect() (read-only with schema check), text renderer mirroring
analyze.mjs's layout, JSON renderer with the documented schema, and
main() orchestration. Catches database-locked errors specifically and
returns exit 2; lets unexpected SQLite errors propagate. 3 new tests
cover JSON shape and connect()'s exit codes; full test count is now
32. Verified against cloudbox's live opencode.db."
```

---

## Task 8: Add to user package list and apply on cloudbox

**Goal:** Land `oc-cost` on `$PATH` for everyday use. Cloudbox-specific deployment.

**Files:**
- Modify: `users/dev/home.base.nix:197-226`

**Step 1: Add to home.packages**

In `users/dev/home.base.nix`, find the `home.packages = [` block at line 197 and add `localPkgs.oc-cost` alongside the other `localPkgs.*` entries. Place it adjacent to `localPkgs.gws` for grouping with other always-on tools (i.e. above the work-only `lib.optionals` block):

```nix
    # Google Workspace CLI
    localPkgs.gws

    # OpenCode usage and cost reporting
    localPkgs.oc-cost
```

**Step 2: Verify the home configuration evaluates**

Run: `nix build .#homeConfigurations.dev.activationPackage`
Expected: build succeeds.

**Step 3: Apply on cloudbox**

Run: `nix run home-manager -- switch --flake .#dev`
Expected: succeeds; no errors.

**Step 4: Verify oc-cost is on PATH**

Run: `which oc-cost`
Expected: a path under `~/.nix-profile/bin/oc-cost` or similar.

Run: `oc-cost --days 7`
Expected: real report against the live DB.

**Step 5: Commit**

```bash
git add users/dev/home.base.nix
git commit -m "feat(oc-cost): add to user package list

Wires oc-cost into home.packages so it's on \$PATH for the dev user
on every machine using the standard home config. Verified by applying
on cloudbox via nix run home-manager -- switch --flake .#dev."
```

---

## Task 9: Retire analyze.mjs and rewrite the skill doc

**Goal:** Delete the old script and rewrite `SKILL.md` to point at `oc-cost` for routine use, while preserving the interpretation guidance and the raw-SQL fallback example.

**Files:**
- Delete: `.opencode/skills/tracking-cache-costs/analyze.mjs`
- Modify: `.opencode/skills/tracking-cache-costs/SKILL.md`

**Step 1: Read the current SKILL.md in full**

Read `.opencode/skills/tracking-cache-costs/SKILL.md` (78 lines). Note which sections are analyzer-agnostic (Interpreting Results, Pricing Notes, Check Upstream Progress) and which need rewriting (Quick Check, Ad-Hoc Queries).

**Step 2: Rewrite SKILL.md**

Replace the entire file with:

````markdown
---
name: tracking-cache-costs
description: Measures OpenCode prompt caching efficiency and API costs via SQLite analysis. Use when investigating API costs, evaluating cache hit rates, or checking if upstream caching fixes have landed.
---

# Tracking OpenCode Cache Costs

## Quick Check

```bash
oc-cost                              # last 14 days
oc-cost --days 30                    # custom window
oc-cost --since 2026-04-01           # date-bounded
oc-cost --json | jq '.cost_components.monthly_proj'
```

`oc-cost` is a packaged Python CLI in `pkgs/oc-cost/` that queries the
OpenCode SQLite database (`~/.local/share/opencode/opencode.db`) directly.
It replaces the older `analyze.mjs` script that used to live in this skill
directory.

Output sections:
- Daily cache read/write/uncached ratios
- Per-model cost breakdown (Anthropic API rates)
- Cost components — applies each model's own rates, not a dominant-model
  approximation
- Daily average and monthly projection
- Prompt size distribution (bucketed)
- Unpriced models (any model id not in `oc-cost`'s pricing table)

## Interpreting Results

| Write % | Assessment | Action |
|---------|-----------|--------|
| <10% | Healthy | No action needed |
| 10-20% | Moderate | Check for short sessions or frequent subagent spawning |
| 20-40% | Poor | Cache busting likely -- tool reordering or file tree churn |
| >40% | Severe | Investigate immediately, major cost impact |

**Root causes of high writes**: tool definition order instability (prefix-based cache busted by reordering), file tree changes in system prompt, only 4 cache breakpoints in current opencode, short sessions / subagent spawning.

## Pricing Notes

- **Opus 4.6 and Sonnet 4.6**: flat pricing across the full 1M context window. No >200k surcharge.
- **Older models (Opus 4, 4.1)**: may have different pricing tiers for >200k context. `oc-cost` uses flat rates.
- **Vertex AI / Bedrock**: pricing may differ from Anthropic direct API rates. `oc-cost` uses Anthropic's published rates.
- Pricing source: https://docs.anthropic.com/en/docs/about-claude/pricing
- New models without an entry in the `PRICES` dict appear in `unpriced_models` and are excluded from the cost total. Add them to `pkgs/oc-cost/oc_cost.py`.

## Ad-Hoc Queries

For most investigations, prefer `oc-cost --json | jq` to ad-hoc SQL:

```bash
# Top-line monthly projection
oc-cost --json | jq .cost_components.monthly_proj

# Per-model cost subtotals
oc-cost --json | jq '.by_model[] | {model, cost_usd}'

# Daily totals as TSV
oc-cost --json | jq -r '.daily[] | [.day, .msgs, .cache_read, .cache_write] | @tsv'
```

For shapes `oc-cost` doesn't expose, query the DB directly:

```bash
nix-shell -p sqlite --run "sqlite3 -header -column ~/.local/share/opencode/opencode.db \"
SELECT date(time_created/1000, 'unixepoch') as day,
  sum(json_extract(data, '\$.tokens.cache.read')) as cache_read,
  sum(json_extract(data, '\$.tokens.cache.write')) as cache_write,
  sum(json_extract(data, '\$.tokens.input')) as uncached,
  ROUND(100.0 * sum(json_extract(data, '\$.tokens.cache.read')) /
    (sum(json_extract(data, '\$.tokens.cache.read')) + sum(json_extract(data, '\$.tokens.cache.write')) + sum(json_extract(data, '\$.tokens.input'))), 1) as read_pct
FROM message
WHERE json_extract(data, '\$.role') = 'assistant'
  AND json_extract(data, '\$.tokens.cache.read') IS NOT NULL
GROUP BY day ORDER BY day DESC LIMIT 14;
\""
```

## Check Upstream Progress

### OpenCode caching (anomalyco/opencode)

```bash
gh pr list --repo anomalyco/opencode --search "cache" --state merged --limit 5 --json number,title,mergedAt
```

Key items:
- [PR #5422](https://github.com/anomalyco/opencode/pull/5422) -- provider-specific cache config (not merged)
- [Issue #5416](https://github.com/anomalyco/opencode/issues/5416) -- caching improvement request
- [Issue #5224](https://github.com/anomalyco/opencode/issues/5224) -- system prompt cache invalidation
- Any PR touching `packages/opencode/src/provider/transform.ts` signals caching work
````

**Step 3: Delete analyze.mjs**

Run: `git rm .opencode/skills/tracking-cache-costs/analyze.mjs`

**Step 4: Verify the skill is still well-formed**

Run: `head -5 .opencode/skills/tracking-cache-costs/SKILL.md`
Expected: starts with `---\nname: tracking-cache-costs\n...` (the YAML frontmatter is intact).

Run: `ls .opencode/skills/tracking-cache-costs/`
Expected: only `SKILL.md`.

**Step 5: Commit**

```bash
git add .opencode/skills/tracking-cache-costs
git commit -m "chore: retire analyze.mjs in favour of oc-cost

Deletes .opencode/skills/tracking-cache-costs/analyze.mjs and rewrites
the skill doc to point at the packaged oc-cost CLI for routine use.
The Interpreting Results, Pricing Notes, and Check Upstream Progress
sections are preserved unchanged. Ad-Hoc Queries now leads with
oc-cost --json | jq examples and keeps the raw SQL example as a
fallback for queries oc-cost doesn't expose."
```

---

## Task 10: Final verification and PR

**Goal:** Run all verification commands one more time, push the branch, open a PR against `main`.

**Files:** none modified.

**Step 1: Re-run all tests against the final tree**

Run: `python3 -m unittest pkgs/oc-cost/test_oc_cost.py -v`
Expected: 32 tests, all pass.

Run: `nix build .#oc-cost`
Expected: success.

Run: `oc-cost --days 7`
Expected: real, populated report (cloudbox).

Run: `oc-cost --json | python3 -c "import json, sys; print(sorted(json.load(sys.stdin).keys()))"`
Expected: `['by_model', 'cost_components', 'daily', 'meta', 'size_buckets']`

**Step 2: Verify the diff against main is what we expect**

Run: `git log --oneline main..HEAD`
Expected: 6 commits (Tasks 1, 2, 3, 4, 5, 6, 7, 8, 9 — counting only the ones that committed; Tasks 0 and 10 don't commit).

Run: `git diff --stat main..HEAD`
Expected: roughly:
- `pkgs/oc-cost/default.nix` (new, ~25 lines)
- `pkgs/oc-cost/oc_cost.py` (new, ~350 lines)
- `pkgs/oc-cost/test_oc_cost.py` (new, ~250 lines)
- `pkgs/oc-cost/README.md` (new, ~30 lines)
- `flake.nix` (+1 line)
- `users/dev/home.base.nix` (+3 lines)
- `.opencode/skills/tracking-cache-costs/analyze.mjs` (deleted, -260 lines)
- `.opencode/skills/tracking-cache-costs/SKILL.md` (rewritten)
- `docs/plans/2026-04-20-oc-cost-design.md` (already in main from `6994c5a`)
- `docs/plans/2026-04-20-oc-cost-plan.md` (this file, committed before Task 0 — see note below)

Note: the design doc landed on main pre-branch. The plan doc (this file) should also land on main before Task 0 — see "Pre-flight" below.

**Step 3: Push and open PR**

Use the `creating-pull-requests` skill. Suggested PR title:

> feat(oc-cost): replace analyze.mjs with packaged Python CLI

PR body should reference `docs/plans/2026-04-20-oc-cost-design.md` and link to ccusage issue #845.

---

## Pre-flight: commit this plan doc

Before starting Task 0, commit this plan to `main`:

Run: `git status`
Expected: `docs/plans/2026-04-20-oc-cost-plan.md` is the only change.

Run:
```bash
git add docs/plans/2026-04-20-oc-cost-plan.md
git commit -m "docs: add oc-cost implementation plan"
```

Then proceed to Task 0.
