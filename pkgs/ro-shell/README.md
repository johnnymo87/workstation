# ro-shell

A stdio MCP server providing a single `shell` tool for goose's read-only
subagent roles (reviewers, oracle) in place of developer's shell.

Commands run in `bash` with a git shim (`ro-git`) installed first on PATH,
ensuring git operations are limited to read-only subcommands (e.g. `status`,
`diff`, `log`, `show`, `blame`, `grep`, `rev-parse`, `ls-files`, and listing
forms of `branch`, `tag`, `worktree`, `stash`). Any mutating git invocation,
absolute path to git, PATH override, or `command -p` is refused.

Scope: an accident guard (parity with opencode's permission denylist), not an
OS sandbox.
