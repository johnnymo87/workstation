#!/usr/bin/env python3
"""Rewrite pkgs/claude-failover-proxy/default.nix for a new cfp release.

Bumps `version`, and rewrites the asset id + hash INSIDE EACH source block
separately (claude-failover-proxy linux-arm64, claude-failover-proxy darwin-arm64,
and cfp-shaper linux-arm64).

Why this exists as a script rather than unanchored sed calls: cfp ships multiple
assets across targets and binaries, each with its own asset id and its own hash.
An unanchored `s|releases/assets/[0-9]*|...|` would rewrite multiple blocks,
giving other entries the wrong asset id and hash.

Anchoring per block ensures each entry is updated independently and cannot bleed
into sibling blocks.

Verified by test: .github/scripts/test_update_cfp_sources.py
"""

from __future__ import annotations

import argparse
import re
import sys

# One (asset id, SRI hash) pair per target block in default.nix.
TARGET_FLAGS = {
    "aarch64-linux": ("linux-asset-id", "linux-hash"),
    "aarch64-darwin": ("darwin-asset-id", "darwin-hash"),
    "cfp-shaper-linux": ("shaper-asset-id", "shaper-hash"),
}

BLOCK_PATTERNS = {
    "aarch64-linux": r'(sources\s*=\s*\{.*?["\']aarch64-linux["\']\s*=\s*fetchurl\s*\{)(.*?)(\n    \};)',
    "aarch64-darwin": r'(sources\s*=\s*\{.*?["\']aarch64-darwin["\']\s*=\s*fetchurl\s*\{)(.*?)(\n    \};)',
    "cfp-shaper-linux": r'(shaperSources\s*=\s*\{.*?["\']aarch64-linux["\']\s*=\s*fetchurl\s*\{)(.*?)(\n    \};)',
}


def bump_version(text: str, current: str, version: str) -> str:
    """Replace the single `version = "<current>"` binding."""
    needle = f'version = "{current}"'
    if needle not in text:
        raise SystemExit(f"version line {needle!r} not found")
    return text.replace(needle, f'version = "{version}"', 1)


def rewrite_source(text: str, target: str, asset_id: str, sri: str) -> str:
    """Rewrite the url asset id and hash within ONE source block.

    The block is delimited by its section/target on one side and the entry's
    closing `};` at four-space indentation on the other, so a non-greedy match
    covers exactly one fetchurl and cannot bleed into its sibling.
    """
    if target in BLOCK_PATTERNS:
        pattern = re.compile(BLOCK_PATTERNS[target], re.DOTALL)
    else:
        pattern = re.compile(
            r'("' + re.escape(target) + r'" = fetchurl \{)(.*?)(\n    \};)',
            re.DOTALL,
        )
    match = pattern.search(text)
    if not match:
        raise SystemExit(f"no sources block for {target}")

    body = match.group(2)
    body, n_url = re.subn(r"releases/assets/[0-9]+", f"releases/assets/{asset_id}", body)
    body, n_hash = re.subn(r'hash = "sha256-[^"]*"', f'hash = "{sri}"', body)
    if n_url != 1 or n_hash != 1:
        raise SystemExit(
            f"{target}: expected exactly 1 url and 1 hash, got {n_url} and {n_hash}"
        )

    return text[: match.start()] + match.group(1) + body + match.group(3) + text[match.end() :]


def rewrite(text: str, current: str, version: str, targets: dict[str, tuple[str, str]]) -> str:
    text = bump_version(text, current, version)
    for target, (asset_id, sri) in targets.items():
        text = rewrite_source(text, target, asset_id, sri)

    # The corruption this script exists to prevent is two entries sharing an id
    # or a hash. Assert it directly rather than trusting the anchoring above.
    for label, values in (
        ("asset id", [asset_id for asset_id, _ in targets.values()]),
        ("hash", [sri for _, sri in targets.values()]),
    ):
        for value in values:
            if text.count(value) != 1:
                raise SystemExit(
                    f"{label} {value!r} appears {text.count(value)} times; "
                    "sources blocks got crossed"
                )
    return text


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--file", default="pkgs/claude-failover-proxy/default.nix")
    parser.add_argument("--current", required=True, help="version currently in the file")
    parser.add_argument("--version", required=True, help="version to write")
    for asset_flag, hash_flag in TARGET_FLAGS.values():
        parser.add_argument(f"--{asset_flag}", required=True)
        parser.add_argument(f"--{hash_flag}", required=True)
    args = parser.parse_args(argv)

    targets = {
        target: (
            getattr(args, asset_flag.replace("-", "_")),
            getattr(args, hash_flag.replace("-", "_")),
        )
        for target, (asset_flag, hash_flag) in TARGET_FLAGS.items()
    }

    with open(args.file) as handle:
        text = handle.read()
    text = rewrite(text, args.current, args.version, targets)
    with open(args.file, "w") as handle:
        handle.write(text)

    print(f"Updated {args.file} to {args.version}")
    for target, (asset_id, sri) in targets.items():
        print(f"  {target}: asset {asset_id} {sri}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
