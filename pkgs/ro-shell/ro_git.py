#!/usr/bin/env python3
"""ro-shell's git shim. Installed as `git` FIRST on the PATH of every command
ro-shell runs, so only read-only git reaches the real binary.

Allowlist, not denylist: anything not known read-only is refused, including
unknown subcommands, aliases to them, and `!` shell aliases. Aliases are
resolved because this host's global config has co=checkout, ci=commit.

An accident guard (parity with opencode's permission denylist), not a sandbox.
"""
import os
import shlex
import subprocess
import sys

REFUSED = 3

READ_ONLY = {
    "status", "diff", "log", "show", "blame", "annotate", "rev-parse", "rev-list",
    "ls-files", "ls-tree", "grep", "cat-file", "merge-base", "for-each-ref",
    "describe", "shortlog", "name-rev", "show-ref", "diff-tree", "diff-files",
    "diff-index", "range-diff", "whatchanged", "count-objects", "check-ignore",
    "check-attr", "var", "help", "version", "cherry",
}
# Subcommands allowed only in list/show forms (see sub_ok).
CONDITIONAL = {"branch", "tag", "worktree", "stash", "reflog", "config", "remote", "notes", "submodule"}

GLOBAL_FLAGS = {"--no-pager", "-P", "--paginate", "-p", "--no-replace-objects",
                "--literal-pathspecs", "--no-optional-locks", "--version", "-v", "--help", "-h"}
GLOBAL_WITH_ARG = {"-C"}

BRANCH_MUTATING = {"-d", "-D", "--delete", "-m", "-M", "--move", "-c", "-C", "--copy",
                   "-f", "--force", "-u", "--set-upstream-to", "--unset-upstream",
                   "--edit-description", "-t", "--track", "--no-track"}
BRANCH_LISTING = {"--list", "-l", "--contains", "--no-contains", "--merged", "--no-merged", "--points-at"}
TAG_MUTATING = {"-d", "--delete", "-f", "--force", "-a", "--annotate", "-s", "--sign",
                "-u", "--local-user", "-m", "--message", "-F", "--file", "-e", "--edit"}
TAG_LISTING = {"-l", "--list", "--contains", "--no-contains", "--merged", "--no-merged", "--points-at", "-n"}
CONFIG_READ = {"--get", "--get-all", "--get-regexp", "--get-urlmatch", "--list", "-l", "get", "list"}
CONFIG_WRITE = {"--unset", "--unset-all", "--add", "--replace-all", "--rename-section",
                "--remove-section", "-e", "--edit", "set", "unset", "rename-section",
                "remove-section", "edit"}
REFLOG_MUTATING = {"delete", "drop", "expire", "write"}


def refuse(why: str) -> "NoReturn":
    sys.stderr.write(
        f"ro-shell: refused: {why}\n"
        "This is a read-only role: git is limited to read-only subcommands "
        "(status, diff, log, show, blame, grep, rev-parse, ls-files, ... and list "
        "forms of branch/tag/worktree/stash). Report what you need instead.\n"
    )
    sys.exit(REFUSED)


def flags(args):
    return {a.split("=", 1)[0] for a in args if a.startswith("-")}


def positionals(args):
    return [a for a in args if not a.startswith("-")]


def sub_ok(sub, rest):
    f = flags(rest)
    if any(a == "--output" or a.startswith("--output=") for a in rest):
        return False
    if sub == "grep" and any(a == "-O" or a.startswith("-O") or a.startswith("--open-files-in-pager") for a in rest):
        return False
    if sub == "help" and bool(set(rest) & {"-w", "--web"} or any(a == "-w" or a.startswith("-w") for a in rest)):
        return False
    if sub in READ_ONLY:
        return True
    if sub == "branch":
        return not (f & BRANCH_MUTATING) and (not positionals(rest) or bool(f & BRANCH_LISTING))
    if sub == "tag":
        return not (f & TAG_MUTATING) and (not positionals(rest) or bool(f & TAG_LISTING))
    if sub == "worktree":
        return rest[:1] == ["list"]
    if sub == "stash":
        return rest[:1] in (["list"], ["show"])
    if sub == "reflog":
        return not bool(set(rest) & REFLOG_MUTATING)
    if sub == "config":
        return bool(f & CONFIG_READ or set(rest[:1]) & CONFIG_READ) and not (
            f & CONFIG_WRITE or set(rest[:1]) & CONFIG_WRITE)
    if sub == "remote":
        return not rest or set(rest) <= {"-v", "--verbose"} or rest[0] in ("get-url", "show")
    if sub == "notes":
        pos = positionals(rest)
        return not pos or pos[0] in ("list", "show")
    if sub == "submodule":
        pos = positionals(rest)
        return not pos or pos[0] in ("status", "summary")
    return False


def main(argv):
    real_git = os.environ.get("RO_SHELL_REAL_GIT", "")
    if not real_git or not os.path.isabs(real_git):
        refuse("RO_SHELL_REAL_GIT is not set to an absolute path (misconfigured ro-shell)")

    globals_, i = [], 0
    while i < len(argv):
        a = argv[i]
        if a in GLOBAL_WITH_ARG:
            if i + 1 >= len(argv):
                refuse(f"`git {a}` without an argument")
            globals_ += [a, argv[i + 1]]
            i += 2
        elif a in GLOBAL_FLAGS:
            globals_.append(a)
            i += 1
        elif a.startswith("-"):
            refuse(f"git global option `{a}` (only -C, --no-pager, -P are allowed)")
        else:
            break
    rest = argv[i:]
    if not rest:
        os.execv(real_git, [real_git, *globals_])

    sub, rest = rest[0], rest[1:]
    for _ in range(5):  # alias chains
        if sub in READ_ONLY or sub in CONDITIONAL:
            break
        r = subprocess.run([real_git, *globals_, "config", "--get", f"alias.{sub}"],
                           capture_output=True, text=True)
        if r.returncode != 0:
            refuse(f"`git {sub}`")
        expansion = r.stdout.strip()
        if expansion.startswith("!"):
            refuse(f"shell alias `git {sub}`")
        words = shlex.split(expansion)
        if not words:
            refuse(f"empty alias `git {sub}`")
        sub, rest = words[0], words[1:] + rest
    if not sub_ok(sub, rest):
        refuse(f"`git {sub} {' '.join(rest)}`".rstrip())

    os.environ.update(GIT_PAGER="cat", PAGER="cat", GIT_TERMINAL_PROMPT="0", GIT_OPTIONAL_LOCKS="0")
    os.execv(real_git, [real_git, *globals_, sub, *rest])


if __name__ == "__main__":
    main(sys.argv[1:])
