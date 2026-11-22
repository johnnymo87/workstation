#!/usr/bin/env python3
"""Rewrite pkgs/goose/default.nix onto a newer johnnymo87/goose patched release.

Used by .github/workflows/update-goose.yml (upgrade lane, workstation-6w7i.27.4).

  update-goose-pin.py plan RELEASES_JSON        -> prints `tag=...`, `version=...`, `major=...`
                                                  (nothing when the pin is current)
  update-goose-pin.py rewrite TAG SHA256SUMS    -> rewrites pkgs/goose/default.nix in place

The pin moves only to a COMPLETE release (every asset the pin fetches, and SHA256SUMS):
the fork watcher's tag push lands before patched-release.yml has published anything.
A `platforms` entry that carries its own `tag` is held there (e.g. darwin while the Mac
waits on A10) and is left alone. Hashes come from the release's SHA256SUMS; the workflow
verifies the downloaded assets against it first.

Verified by test: .github/scripts/test_update_goose_pin.py
"""
from __future__ import annotations

import base64
import json
import re
import sys
from pathlib import Path

NIX = Path(__file__).resolve().parents[2] / "pkgs/goose/default.nix"
TAG_RE = re.compile(r"patched-(\d+)\.(\d+)\.(\d+)\.(\d+)")
ENTRY_RE = re.compile(r'(\n    "(?P<system>[^"]+)" = \{\n)(?P<body>.*?)(\n    \};)', re.S)


def parse_tag(tag: str):
    m = TAG_RE.fullmatch(tag)
    return tuple(int(x) for x in m.groups()) if m else None


def current_tag(text: str) -> str:
    m = re.search(r'^  tag = "([^"]+)";$', text, re.M)
    if not m:
        raise ValueError("no top-level `tag = \"...\";` in pkgs/goose/default.nix")
    return m.group(1)


def entries(text: str) -> list[dict]:
    out = []
    for m in ENTRY_RE.finditer(text):
        body = m.group("body")
        asset = re.search(r'asset = "([^"]+)";', body)
        out.append({"system": m.group("system"), "asset": asset.group(1) if asset else None,
                    "held": bool(re.search(r"^\s*tag = ", body, re.M))})
    return out


def required_assets(text: str) -> set[str]:
    return {e["asset"] for e in entries(text) if not e["held"] and e["asset"]} | {"SHA256SUMS"}


def pick_latest_complete(releases: list[dict], required: set[str]):
    best = None
    for r in releases:
        v = parse_tag(r["tag_name"])
        if not v or r.get("draft") or r.get("prerelease"):
            continue
        names = {a["name"] for a in r.get("assets", [])}
        if required <= names and (best is None or v > best[0]):
            best = (v, r["tag_name"])
    return best[1] if best else None


def plan(text: str, releases: list[dict]) -> dict:
    cur = current_tag(text)
    new = pick_latest_complete(releases, required_assets(text))
    if not new or parse_tag(new) <= parse_tag(cur):
        return {}
    a, b, c, n = parse_tag(new)
    return {"tag": new, "version": f"{a}.{b}.{c}-patched.{n}", "major": str(a > parse_tag(cur)[0]).lower(),
            "current": cur}


def sums_to_sri(sums: str) -> dict[str, str]:
    out = {}
    for line in sums.splitlines():
        parts = line.split()
        if len(parts) == 2 and re.fullmatch(r"[0-9a-f]{64}", parts[0]):
            out[parts[1].lstrip("*")] = "sha256-" + base64.b64encode(bytes.fromhex(parts[0])).decode()
    return out


def rewrite(text: str, tag: str, sums: str) -> str:
    a, b, c, n = parse_tag(tag)
    sri = sums_to_sri(sums)
    text, k1 = re.subn(r'^  version = "[^"]*";$', f'  version = "{a}.{b}.{c}-patched.{n}";', text, count=1, flags=re.M)
    text, k2 = re.subn(r'^  tag = "[^"]*";$', f'  tag = "{tag}";', text, count=1, flags=re.M)
    if k1 != 1 or k2 != 1:
        raise ValueError("top-level version/tag lines not found")

    def entry(m: re.Match) -> str:
        body = m.group("body")
        if re.search(r"^\s*tag = ", body, re.M):
            return m.group(0)
        asset = re.search(r'asset = "([^"]+)";', body).group(1)
        if asset not in sri:
            raise ValueError(f"{tag} SHA256SUMS has no {asset}")
        body, k = re.subn(r'hash = "sha256-[^"]*";', f'hash = "{sri[asset]}";', body, count=1)
        if k != 1:
            raise ValueError(f"no hash line in the {m.group('system')} entry")
        return m.group(1) + body + m.group(4)

    return ENTRY_RE.sub(entry, text)


def main(argv: list[str]) -> int:
    text = NIX.read_text()
    if argv[1:2] == ["plan"]:
        for k, v in plan(text, json.loads(Path(argv[2]).read_text())).items():
            print(f"{k}={v}")
        return 0
    if argv[1:2] == ["rewrite"]:
        NIX.write_text(rewrite(text, argv[2], Path(argv[3]).read_text()))
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
