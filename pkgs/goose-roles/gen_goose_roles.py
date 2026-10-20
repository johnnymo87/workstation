#!/usr/bin/env python3
"""Generate goose role recipes from opencode agent .md files.

Read-only class comes from the source's own `permission: {write: deny, edit: deny}`,
so a new reviewer is read-only by construction. Every unexpected shape dies
(house style: the Nix build fails rather than shipping a degraded role).
Design: docs/plans/2026-10-20-goose-subagent-roles-design.md
"""
import argparse
import os
import re
import sys

import yaml

ROLES = ["oracle", "adversarial-reviewer", "code-reviewer", "spec-reviewer", "implementer"]

READ_ONLY_NOTE = """

## Running under goose (read-only role)

You are a delegated goose subagent in a read-only role. You have no write or edit
tool. Your `shell` tool is ro-shell: git is limited to read-only subcommands and
anything else is refused. Do not try to work around the refusal. You cannot ask the
caller questions mid-task, so state your assumptions and proceed. Your final message
is your whole report to the caller."""

IMPLEMENTER_NOTE = """

## Running under goose

You are a delegated goose subagent. You cannot ask the caller questions mid-task.
If the task is ambiguous or blocked, stop and report what you need instead of guessing.
Your final message is your whole report to the caller."""


class GenError(Exception):
    pass


def split_frontmatter(text):
    if not text.startswith("---\n"):
        raise GenError("no frontmatter")
    end = text.find("\n---\n", 4)
    if end < 0:
        raise GenError("unterminated frontmatter")
    return yaml.safe_load(text[4:end]) or {}, text[end + 5:]


def map_model(model, opus_model, sonnet_model):
    if re.fullmatch(r"anthropic/claude-opus-\d+(?:-\d+)*", model or ""):
        return opus_model
    if re.fullmatch(r"anthropic/claude-sonnet-\d+(?:-\d+)*", model or ""):
        return sonnet_model
    raise GenError(f"unmapped model {model!r}")


def is_read_only(fm):
    perm = fm.get("permission") or {}
    w, e = perm.get("write"), perm.get("edit")
    if w == "deny" and e == "deny":
        return True
    if w is None and e is None:
        return False
    raise GenError(f"inconsistent write/edit permissions: write={w!r} edit={e!r}")


def clean_description(desc):
    d = str(desc).split("<example>")[0]
    d = re.sub(r"\s*Examples:\s*$", "", d.strip())
    d = re.sub(r"\s*\((?:opus|sonnet|fable|gpt)[^)]*model\)", "", d)
    d = re.sub(r"\s+", " ", d).strip()
    if not d:
        raise GenError("empty description")
    return d


def ro_extensions(ro_shell_cmd):
    return [
        {"type": "platform", "name": "developer", "available_tools": ["tree", "read_image"]},
        {"type": "platform", "name": "analyze"},
        {"type": "platform", "name": "skills"},
        {"type": "stdio", "name": "ro-shell", "cmd": ro_shell_cmd, "args": [], "timeout": 600,
         "description": "Read-only shell", "available_tools": ["shell"]},
    ]


def rw_extensions():
    return [{"type": "platform", "name": n} for n in ("developer", "analyze", "skills")]


def _assert_extensions(exts):
    for e in exts:
        if "available_tools" in e and not e["available_tools"]:
            raise GenError(f"{e['name']}: empty available_tools means ALL tools")
        if e["name"] == "summon":
            raise GenError("roles must not get summon")


def build_role(role, text, *, ro_shell_cmd, provider, opus_model, sonnet_model):
    fm, body = split_frontmatter(text)
    for tok in ("{{", "{%", "{#"):
        if tok in body:
            raise GenError(f"{role}: body contains template syntax {tok!r}")
    ro = is_read_only(fm)
    exts = ro_extensions(ro_shell_cmd) if ro else rw_extensions()
    _assert_extensions(exts)
    return {
        "version": "1.0.0",
        "title": role,
        "description": clean_description(fm.get("description", "")),
        "instructions": body.strip() + (READ_ONLY_NOTE if ro else IMPLEMENTER_NOTE),
        "extensions": exts,
        "settings": {"goose_provider": provider,
                     "goose_model": map_model(fm.get("model"), opus_model, sonnet_model)},
    }


def build_unscoped(ro_shell_cmd):
    exts = ro_extensions(ro_shell_cmd)
    _assert_extensions(exts)
    return {
        "version": "1.0.0",
        "title": "unscoped delegate",
        "description": "Extension set for delegates that declare none (GOOSE_SUBAGENT_DEFAULT_RECIPE)",
        "instructions": "Read-only delegated task." + READ_ONLY_NOTE,
        "extensions": exts,
    }


def _dump(obj, path):
    with open(path, "w") as fh:
        yaml.safe_dump(obj, fh, sort_keys=False, allow_unicode=True, width=1000)


def generate(agents_dir, out_dir, roles, **kw):
    os.makedirs(os.path.join(out_dir, "roles"), exist_ok=True)
    for role in roles:
        with open(os.path.join(agents_dir, f"{role}.md")) as fh:
            recipe = build_role(role, fh.read(), **kw)
        _dump(recipe, os.path.join(out_dir, "roles", f"{role}.yaml"))
    _dump(build_unscoped(kw["ro_shell_cmd"]), os.path.join(out_dir, "unscoped.yaml"))


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--agents-dir", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--ro-shell-cmd", required=True)
    p.add_argument("--provider", default="gcp_vertex_ai")
    p.add_argument("--opus-model", required=True)
    p.add_argument("--sonnet-model", required=True)
    a = p.parse_args()
    try:
        generate(a.agents_dir, a.out, ROLES, ro_shell_cmd=a.ro_shell_cmd, provider=a.provider,
                 opus_model=a.opus_model, sonnet_model=a.sonnet_model)
    except GenError as e:
        sys.exit(f"gen_goose_roles: {e}")


if __name__ == "__main__":
    main()
