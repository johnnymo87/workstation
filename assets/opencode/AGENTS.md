# User-level OpenCode Instructions

Global instructions that apply to all OpenCode sessions for this user, on any
machine. Repo-specific instructions live in each project's `AGENTS.md`.

## Bash Environment

**Do NOT use `sleep` in bash commands.** It hangs in this environment for
reasons that are not fully understood. If you need to wait for something
(a server to start, a process to exit, a file to appear), use one of:

- Check the condition directly and immediately (most servers are ready
  fast enough that no wait is needed).
- Poll with a bounded loop:
  ```bash
  for i in $(seq 1 20); do
    ss -tlnp | grep -q ":$PORT " && break
  done
  ```
- Use `wait` for backgrounded child processes you actually own.
- Use `timeout` to bound an operation.

This applies to ALL bash invocations, not just gws auth.

## Backgrounding Long-Running Processes

A bare `nohup ... &` can die when the parent shell is interrupted. To fully
detach a process from the shell session (so Ctrl+C / shell exit doesn't kill
it), use:

```bash
setsid nohup <command> < /dev/null > /tmp/log 2>&1 & disown
```

Then verify the process is alive (`ps -p <pid>` or check for its expected
side effect like a listening socket).
