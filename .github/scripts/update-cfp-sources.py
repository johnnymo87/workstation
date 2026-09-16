#!/usr/bin/env python3
"""Rewrite pkgs/claude-failover-proxy/default.nix for a new cfp release.

Bumps `version`, and rewrites the asset id + hash INSIDE EACH `sources` entry
separately.

Why this exists as a script rather than three `sed -i` calls (which is what
.github/workflows/update-claude-failover-proxy.yml used to do): cfp now ships
one asset per host that runs it, so `sources` has an `aarch64-linux` entry and
an `aarch64-darwin` entry, each with its own asset id and its own hash. An
unanchored `s|releases/assets/[0-9]*|...|` rewrites BOTH, giving the darwin
entry the linux asset id and the linux hash.

That failure is silent all the way to the affected machine: the hash genuinely
matches the bytes being fetched (they are the linux file's), so Nix verifies it,
installs an ELF binary as the darwin `claude-failover-proxy`, and the Mac's
launchd agent then fails with an exec format error and respawns every 10
seconds forever. Nothing in CI goes red, because CI only realises the
aarch64-linux entry.

Verified by test: .github/scripts/test_update_cfp_sources.py
"""

from __future__ import annotations

import argparse
import re
import sys

# One (asset id, SRI hash) pair per Nix system attribute in `sources`.
TARGET_FLAGS = {
    "aarch64-linux": ("linux-asset-id", "linux-hash"),
    "aarch64-darwin": ("darwin-asset-id", "darwin-hash"),
}


def bump_version(text: str, current: str, version: str) -> str:
    """Replace the single `version = "<current>"` binding."""
    needle = f'version = "{current}"'
    if needle not in text:
        raise SystemExit(f"version line {needle!r} not found")
    return text.replace(needle, f'version = "{version}"', 1)


def rewrite_source(text: str, system: str, asset_id: str, sri: str) -> str:
    """Rewrite the url asset id and hash within ONE `sources` entry.

    The block is delimited by the system attribute on one side and the entry's
    closing `};` at four-space indentation on the other, so a non-greedy match
    covers exactly one fetchurl and cannot bleed into its sibling.
    """
    pattern = re.compile(
        r'("' + re.escape(system) + r'" = fetchurl \{)(.*?)(\n    \};)',
        re.DOTALL,
    )
    match = pattern.search(text)
    if not match:
        raise SystemExit(f"no sources block for {system}")

    body = match.group(2)
    body, n_url = re.subn(r"releases/assets/[0-9]+", f"releases/assets/{asset_id}", body)
    body, n_hash = re.subn(r'hash = "sha256-[^"]*"', f'hash = "{sri}"', body)
    if n_url != 1 or n_hash != 1:
        raise SystemExit(
            f"{system}: expected exactly 1 url and 1 hash, got {n_url} and {n_hash}"
        )

    return text[: match.start()] + match.group(1) + body + match.group(3) + text[match.end() :]


def rewrite(text: str, current: str, version: str, targets: dict[str, tuple[str, str]]) -> str:
    text = bump_version(text, current, version)
    for system, (asset_id, sri) in targets.items():
        text = rewrite_source(text, system, asset_id, sri)

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
        system: (
            getattr(args, asset_flag.replace("-", "_")),
            getattr(args, hash_flag.replace("-", "_")),
        )
        for system, (asset_flag, hash_flag) in TARGET_FLAGS.items()
    }

    with open(args.file) as handle:
        text = handle.read()
    text = rewrite(text, args.current, args.version, targets)
    with open(args.file, "w") as handle:
        handle.write(text)

    print(f"Updated {args.file} to {args.version}")
    for system, (asset_id, sri) in targets.items():
        print(f"  {system}: asset {asset_id} {sri}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
