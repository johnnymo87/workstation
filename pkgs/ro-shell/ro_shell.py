#!/usr/bin/env python3
"""ro-shell: stdio MCP server with one `shell` tool for goose's read-only roles.

Runs `bash -c <command>` with the ro-git shim first on PATH, so every git the
command reaches -- directly, via sh -c, xargs, find -exec, scripts -- is
filtered to read-only subcommands. check_command() refuses the few forms that
would skip the shim (git by absolute path, PATH rewrites, `command -p`).
Broad matching of paths ending in `/git` (including arguments like `cd /srv/git`)
is a deliberate fail-closed policy: the refusal tells the agent to use plain git.

An accident guard with parity to opencode's denylist, not a sandbox: `sed -i`
and `echo >` still write. Env (set by the Nix wrapper): RO_SHELL_SHIM_DIR,
RO_SHELL_REAL_GIT, RO_SHELL_BASH.
"""
import os
import re
import signal
import subprocess

MAX_OUTPUT = 100_000
DEFAULT_TIMEOUT = 300

_SEP = r"(?:^|[\s;&|(`'\"=])"
ABS_GIT = re.compile(_SEP + r"[^\s;&|()`'\"]*/git(?=$|[\s;&|)`'\"])")
PATH_ASSIGN = re.compile(r"(?:^|[\s;&|(`])(?:export\s+)?PATH\+?=")
COMMAND_P = re.compile(r"\bcommand\s+-p\b")
LOGIN_SHELL = re.compile(
    r"(?:^|[\s;&|(`'\"])(?:[^\s;&|()`'\"]*/)?(?:bash|sh|zsh|dash)"
    r"(?:\s+-[a-bd-zA-BD-Z0-9]+)*"
    r"\s+(?:--login|-[a-zA-Z]*l[a-zA-Z]*)"
    r"(?=$|[\s;&|)`'\"])"
)


def check_command(command: str):
    """Return a refusal message, or None if the command may run."""
    if ABS_GIT.search(command):
        return "ro-shell: refused: git by path bypasses the read-only git shim; call plain `git`."
    if PATH_ASSIGN.search(command) or COMMAND_P.search(command):
        return "ro-shell: refused: changing PATH (or `command -p`) bypasses the read-only git shim."
    if LOGIN_SHELL.search(command):
        return "ro-shell: refused: login shell options bypass the read-only git shim via /etc/profile; run plain commands or non-login subshells."
    return None


def run_command(command: str, cwd: str, timeout: int):
    env = dict(os.environ)
    env["PATH"] = os.environ["RO_SHELL_SHIM_DIR"] + os.pathsep + env.get("PATH", "")
    env.update(GIT_PAGER="cat", PAGER="cat", GIT_TERMINAL_PROMPT="0", GIT_OPTIONAL_LOCKS="0")
    bash = os.environ.get("RO_SHELL_BASH", "bash")
    proc = subprocess.Popen([bash, "-c", command], cwd=cwd, env=env, stdin=subprocess.DEVNULL,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)
    try:
        out, _ = proc.communicate(timeout=timeout)
        code = proc.returncode
        text = out.decode("utf-8", "replace")
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except (ProcessLookupError, OSError):
            pass
        try:
            out, _ = proc.communicate(timeout=5)
        except subprocess.TimeoutExpired as exc:
            if proc.stdout:
                try:
                    proc.stdout.close()
                except OSError:
                    pass
            out = exc.stdout or b""
        code = -1
        text = out.decode("utf-8", "replace") + f"\n[ro-shell: timed out after {timeout}s]"
    if len(text) > MAX_OUTPUT:
        text = f"[ro-shell: output truncated to last {MAX_OUTPUT} chars]\n" + text[-MAX_OUTPUT:]
    return code, text


def working_dir_from(ctx):
    """goose sends the subagent's working dir as _meta["agent-working-dir"] on each call."""
    try:
        meta = ctx.request_context.meta
    except Exception:
        return None
    extra = (getattr(meta, "model_extra", None) or {}) if meta is not None else {}
    wd = extra.get("agent-working-dir")
    return wd if isinstance(wd, str) and os.path.isdir(wd) else None


def main():
    from mcp.server.fastmcp import Context, FastMCP

    mcp = FastMCP("ro-shell")

    @mcp.tool()
    def shell(command: str, timeout_secs: int = DEFAULT_TIMEOUT, ctx: Context = None) -> str:
        """Run a bash command in the working directory and return combined stdout/stderr
        and the exit code. git is limited to read-only subcommands (status, diff, log,
        show, blame, grep, rev-parse, ls-files, list forms of branch/tag/worktree/stash);
        anything else is refused. Use rg/cat/sed -n for reading files."""
        refusal = check_command(command)
        if refusal:
            raise ValueError(refusal)
        cwd = working_dir_from(ctx) or os.getcwd()
        code, out = run_command(command, cwd, max(1, min(timeout_secs, 3600)))
        return f"{out.rstrip()}\n[exit code: {code}]"

    mcp.run()  # stdio


if __name__ == "__main__":
    main()
