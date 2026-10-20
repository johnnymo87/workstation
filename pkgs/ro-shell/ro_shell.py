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
import ctypes
import os
import re
import select
import signal
import subprocess
import sys
import threading

MAX_OUTPUT = 100_000
DEFAULT_TIMEOUT = 300
# Goose extension timeout is 600s (gen_goose_roles.py ro_extensions).
# Clamp tool timeout to at most 540s so commands timeout before goose aborts the extension.
MAX_TIMEOUT = 540

_ACTIVE_PGIDS = set()
_PGIDS_LOCK = threading.Lock()


def _preexec_child():
    try:
        try:
            libc = ctypes.CDLL(None)
        except Exception:
            libc = ctypes.CDLL("libc.so.6")
        # PR_SET_PDEATHSIG = 1
        libc.prctl(1, signal.SIGKILL, 0, 0, 0)
    except Exception:
        pass


def cleanup_active_process_groups():
    with _PGIDS_LOCK:
        pgids = list(_ACTIVE_PGIDS)
        _ACTIVE_PGIDS.clear()
    for pgid in pgids:
        try:
            os.killpg(pgid, signal.SIGKILL)
        except (ProcessLookupError, OSError):
            pass


def _handle_signal(signum, frame):
    cleanup_active_process_groups()
    sys.exit(128 + signum)


def _watch_stdin():
    p = select.poll()
    try:
        p.register(sys.stdin.fileno(), select.POLLHUP | select.POLLERR)
    except (ValueError, OSError):
        return
    while True:
        try:
            events = p.poll(250)
            for fd, ev in events:
                if ev & (select.POLLHUP | select.POLLERR):
                    cleanup_active_process_groups()
                    os._exit(0)
        except Exception:
            return

_SEP = r"(?:^|[\s;&|(`'\"=])"
ABS_GIT = re.compile(_SEP + r"[^\s;&|()`'\"]*/git(?=$|[\s;&|)`'\"])")
PATH_ASSIGN = re.compile(r"(?:^|[\s;&|(`])(?:export\s+)?PATH\+?=")
COMMAND_P = re.compile(r"\bcommand\s+-p\b")
TMP_ROOTS_ASSIGN = re.compile(r"(?:^|[\s;&|(`])(?:export\s+)?RO_SHELL_TMP_ROOTS\+?=")
LOGIN_SHELL = re.compile(
    r"(?:^|[\s;&|(`'\"])(?:[^\s;&|()`'\"]*/)?(?:bash|sh|zsh|dash)"
    r"(?:\s+-[a-bd-zA-BD-Z0-9]+)*"
    r"\s+(?:--login|--interactive|-[a-zA-Z]*[li][a-zA-Z]*)"
    r"(?=$|[\s;&|)`'\"])"
)


def check_command(command: str):
    """Return a refusal message, or None if the command may run."""
    if ABS_GIT.search(command):
        return "ro-shell: refused: git by path bypasses the read-only git shim; call plain `git`."
    if PATH_ASSIGN.search(command) or COMMAND_P.search(command) or TMP_ROOTS_ASSIGN.search(command):
        return "ro-shell: refused: changing PATH (or `command -p` or RO_SHELL_TMP_ROOTS) bypasses the read-only git shim."
    if LOGIN_SHELL.search(command):
        return "ro-shell: refused: login shell options bypass the read-only git shim via /etc/profile; run plain commands or non-login subshells."
    return None


def run_command(command: str, cwd: str, timeout: int):
    env = dict(os.environ)
    env.pop("RO_SHELL_REAL_GIT", None)
    env.pop("RO_SHELL_TMP_ROOTS", None)
    env["PATH"] = os.environ["RO_SHELL_SHIM_DIR"] + os.pathsep + env.get("PATH", "")
    env.update(
        GIT_PAGER="cat",
        PAGER="cat",
        GIT_TERMINAL_PROMPT="0",
        GIT_OPTIONAL_LOCKS="0",
        __ETC_PROFILE_DONE="1",
        __NIXOS_SET_ENVIRONMENT_DONE="1",
        __HM_SESS_VARS_SOURCED="1",
    )
    bash = os.environ.get("RO_SHELL_BASH", "bash")
    proc = subprocess.Popen([bash, "-c", command], cwd=cwd, env=env, stdin=subprocess.DEVNULL,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            start_new_session=True, preexec_fn=_preexec_child)
    with _PGIDS_LOCK:
        _ACTIVE_PGIDS.add(proc.pid)
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
    finally:
        with _PGIDS_LOCK:
            _ACTIVE_PGIDS.discard(proc.pid)
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
    signal.signal(signal.SIGTERM, _handle_signal)
    signal.signal(signal.SIGHUP, _handle_signal)

    # Watch stdin in a background thread so if stdin closes (e.g. goose disconnects)
    # during an in-flight tool execution, running child processes are killed immediately.
    threading.Thread(target=_watch_stdin, daemon=True).start()

    from mcp.server.fastmcp import Context, FastMCP

    mcp = FastMCP("ro-shell")

    @mcp.tool()
    def shell(command: str, timeout_secs: int = DEFAULT_TIMEOUT, ctx: Context = None) -> str:
        """Run a bash command in the working directory and return combined stdout/stderr
        and the exit code. timeout_secs is clamped to 1..540s (so ro-shell cleanly
        times out before goose's 600s extension ceiling). git is limited to read-only
        subcommands (status, diff, log, show, blame, grep, rev-parse, ls-files,
        list forms of branch/tag/worktree/stash; throwaway repos under /tmp are
        unrestricted); anything else is refused. Use rg/cat/sed -n for reading files."""
        refusal = check_command(command)
        if refusal:
            raise ValueError(refusal)
        cwd = working_dir_from(ctx) or os.getcwd()
        code, out = run_command(command, cwd, max(1, min(timeout_secs, MAX_TIMEOUT)))
        return f"{out.rstrip()}\n[exit code: {code}]"

    try:
        mcp.run()  # stdio
    finally:
        cleanup_active_process_groups()


if __name__ == "__main__":
    main()
