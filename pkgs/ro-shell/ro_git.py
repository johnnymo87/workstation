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
REAL_GIT_BAKED = "@realGit@"
TMP_ROOTS_BAKED = "@tmpRoots@"

READ_ONLY = {
    "status", "diff", "log", "show", "blame", "annotate", "rev-parse", "rev-list",
    "ls-files", "ls-tree", "grep", "cat-file", "merge-base", "for-each-ref",
    "describe", "shortlog", "name-rev", "show-ref", "diff-tree", "diff-files",
    "diff-index", "range-diff", "whatchanged", "count-objects", "check-ignore",
    "check-attr", "var", "help", "version", "cherry",
}
# Subcommands allowed only in list/show forms (see sub_ok).
CONDITIONAL = {"branch", "tag", "worktree", "stash", "reflog", "config", "remote", "notes", "submodule", "init", "clone"}
DISABLING_ENV_VARS = {"GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY"}
CLONE_WITH_ARG = {
    "-b", "--branch", "-o", "--origin", "-u", "--upload-pack",
    "--reference", "--reference-if-able", "--depth", "--shallow-since",
    "--shallow-exclude", "-c", "--config", "-j", "--jobs", "--filter"
}

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


def get_real_git():
    if not REAL_GIT_BAKED.startswith("@"):
        return REAL_GIT_BAKED
    real_git = os.environ.get("RO_SHELL_REAL_GIT", "")
    if not real_git or not os.path.isabs(real_git):
        refuse("RO_SHELL_REAL_GIT is not set to an absolute path (misconfigured ro-shell)")
    return real_git


def get_temp_roots():
    if not TMP_ROOTS_BAKED.startswith("@"):
        return [os.path.realpath(p) for p in TMP_ROOTS_BAKED.split(":") if p]
    if "RO_SHELL_TMP_ROOTS" in os.environ:
        return [os.path.realpath(p) for p in os.environ["RO_SHELL_TMP_ROOTS"].split(":") if p]
    return [os.path.realpath("/tmp")]


def under_root(path, roots):
    real_p = os.path.realpath(path)
    for r in roots:
        real_r = os.path.realpath(r)
        if real_p == real_r:
            return True
        prefix = real_r if real_r == "/" else real_r.rstrip(os.sep) + os.sep
        if real_p.startswith(prefix):
            return True
    return False


def refuse(why: str) -> "NoReturn":
    sys.stderr.write(
        f"ro-shell: refused: {why}\n"
        "This is a read-only role: git is limited to read-only subcommands "
        "(status, diff, log, show, blame, grep, rev-parse, ls-files, ... and list "
        "forms of branch/tag/worktree/stash; throwaway repos under /tmp are unrestricted). "
        "Report what you need instead.\n"
    )
    sys.exit(REFUSED)


def flags(args):
    return {a.split("=", 1)[0] for a in args if a.startswith("-")}


def positionals(args):
    return [a for a in args if not a.startswith("-")]


def sub_ok(sub, rest, effective_cwd, roots, real_git, globals_):
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
        if rest[:1] == ["list"]:
            return True
        if rest[:1] == ["add"]:
            args = rest[1:]
            has_detach = False
            path = None
            i = 0
            while i < len(args):
                a = args[i]
                if a in ("-b", "-B") or a.startswith("-b") or a.startswith("-B") or a == "--orphan" or a.startswith("--orphan="):
                    return False
                if a == "--reason":
                    i += 2
                    continue
                if a.startswith("--reason="):
                    i += 1
                    continue
                if a in ("-d", "--detach") or (a.startswith("-") and not a.startswith("--") and "d" in a):
                    has_detach = True
                    i += 1
                    continue
                if a.startswith("-"):
                    i += 1
                    continue
                if path is None:
                    path = a
                i += 1
            if not has_detach or not path:
                return False
            real_path = os.path.realpath(os.path.join(effective_cwd, path)) if not os.path.isabs(path) else os.path.realpath(path)
            return under_root(real_path, roots)
        if rest[:1] == ["remove"]:
            args = rest[1:]
            target = None
            for a in args:
                if a in ("-f", "--force"):
                    continue
                if a.startswith("-"):
                    return False
                if target is not None:
                    return False
                target = a
            if not target:
                return False
            r = subprocess.run([real_git, *globals_, "worktree", "list", "--porcelain"],
                               capture_output=True, text=True)
            if r.returncode != 0:
                return False
            registered = []
            for line in r.stdout.splitlines():
                if line.startswith("worktree "):
                    registered.append(line.split(" ", 1)[1].strip())
            target_real = os.path.realpath(os.path.join(effective_cwd, target)) if not os.path.isabs(target) else os.path.realpath(target)
            matched = None
            for rp in registered:
                if os.path.realpath(rp) == target_real or os.path.basename(rp) == target:
                    matched = os.path.realpath(rp)
                    break
            if not matched:
                return False
            return under_root(matched, roots)
        return False
    if sub == "init":
        target_dir = None
        i = 0
        while i < len(rest):
            a = rest[i]
            if a in ("--separate-git-dir", "--template", "--shared", "-s") or \
               a.startswith("--separate-git-dir=") or a.startswith("--template=") or \
               a.startswith("--shared="):
                return False
            if a in ("-b", "--initial-branch"):
                i += 2
                continue
            if a.startswith("--initial-branch="):
                i += 1
                continue
            if a.startswith("-"):
                i += 1
                continue
            if target_dir is None:
                target_dir = a
            i += 1
        dest = target_dir if target_dir is not None else effective_cwd
        dest_real = os.path.realpath(os.path.join(effective_cwd, dest)) if not os.path.isabs(dest) else os.path.realpath(dest)
        return under_root(dest_real, roots)
    if sub == "clone":
        pos = []
        i = 0
        while i < len(rest):
            a = rest[i]
            if a in ("--separate-git-dir", "--template") or \
               a.startswith("--separate-git-dir=") or a.startswith("--template="):
                return False
            if a in CLONE_WITH_ARG:
                i += 2
                continue
            if a.startswith("-"):
                i += 1
                continue
            pos.append(a)
            i += 1
        if len(pos) >= 2:
            dest = pos[1]
        else:
            dest = effective_cwd
        dest_real = os.path.realpath(os.path.join(effective_cwd, dest)) if not os.path.isabs(dest) else os.path.realpath(dest)
        return under_root(dest_real, roots)
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
    real_git = get_real_git()

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

    # Determine effective cwd for resolving relative paths and checking common dir
    cwd = os.getcwd()
    for idx, arg in enumerate(globals_):
        if arg == "-C" and idx + 1 < len(globals_):
            cwd = os.path.realpath(os.path.join(cwd, globals_[idx + 1]))

    roots = get_temp_roots()

    # Throwaway classification requires ALL of:
    # 1. No disabling environment variables set
    # 2. Common dir under a root
    # 3. Worktree toplevel (if repo has a work tree) under a root
    is_throwaway = False
    if not (DISABLING_ENV_VARS & set(os.environ.keys())):
        r_common = subprocess.run([real_git, *globals_, "rev-parse", "--path-format=absolute", "--git-common-dir"],
                                  capture_output=True, text=True)
        if r_common.returncode == 0:
            common_dir = r_common.stdout.strip()
            if under_root(common_dir, roots):
                r_top = subprocess.run([real_git, *globals_, "rev-parse", "--show-toplevel"],
                                       capture_output=True, text=True)
                if r_top.returncode == 0:
                    toplevel = r_top.stdout.strip()
                    if under_root(toplevel, roots):
                        is_throwaway = True
                else:
                    is_throwaway = True

    if is_throwaway:
        os.environ.update(GIT_PAGER="cat", PAGER="cat", GIT_TERMINAL_PROMPT="0", GIT_OPTIONAL_LOCKS="0")
        os.execv(real_git, [real_git, *globals_, *rest])

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
    if not sub_ok(sub, rest, cwd, roots, real_git, globals_):
        refuse(f"`git {sub} {' '.join(rest)}`".rstrip())

    os.environ.update(GIT_PAGER="cat", PAGER="cat", GIT_TERMINAL_PROMPT="0", GIT_OPTIONAL_LOCKS="0")
    os.execv(real_git, [real_git, *globals_, sub, *rest])


if __name__ == "__main__":
    main(sys.argv[1:])
