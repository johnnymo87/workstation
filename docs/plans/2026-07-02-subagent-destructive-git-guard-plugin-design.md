# Design proposal: obfuscation-proof destructive-git guard for opencode subagents

Status: **PROPOSAL — awaiting operator sign-off. NOT implemented.**
Date: 2026-07-02
Author: swarm worker (git-safety task), for coordinator + operator review.

## Motivating incident

In a swarm operating out of a **shared git worktree**, a code-review /
verification subagent ran a destructive git op (`git stash` / `git checkout`)
in the shared `main` worktree and clobbered a peer session's *uncommitted,
tracked* data — a SQLite DB — causing real data loss. Prompt-level "please
don't" guidance is per-session best-effort and did **not** prevent it.

## What already shipped (interim, low-risk — layer 1 + 2)

These are live on devbox as of 2026-07-02 (uncommitted in the workstation
working tree pending operator review):

1. **Permission denylist (declarative, per-agent).** The four read-only
   review/advisor subagents — `code-reviewer`, `spec-reviewer`,
   `adversarial-reviewer`, `oracle` — had `bash: allow` (unrestricted) sitting
   behind `write: deny` / `edit: deny`. Because bash can run any git command
   (and can even write files via redirection), the edit/write deny was
   cosmetic. Each now uses the object form:

   ```yaml
   bash:
     "*": allow
     "git reset*": deny
     "git checkout*": deny
     "git restore*": deny
     "git stash*": deny
     "git clean*": deny
     "git switch*": deny
     "git commit*": deny
     "git push*": deny
     "git rebase*": deny
     "git merge*": deny
     "git cherry-pick*": deny
     "git revert*": deny
     "git apply*": deny
     "git am*": deny
     "git rm*": deny
     "git mv*": deny
   ```

   Read-only git (`diff`/`show`/`log`/`status`/`blame`/`rev-parse`) and
   `git worktree add <tmp> <sha>` remain allowed, so the throwaway-worktree
   pattern still works. This is enforced structurally: opencode ships a bash
   parser (`parseAnd` / tree-sitter) plus a `PermissionRuleset` matcher, so a
   compound command like `cd x && git checkout -- .` has each sub-command
   matched against the patterns — the deny is not a naive whole-string glob.

2. **Codified convention (global AGENTS.md).** A new "Git Safety in Shared
   Worktrees" section in `assets/opencode/AGENTS.md` (deployed to
   `~/.config/opencode/AGENTS.md`, loaded into every session) states the rule
   for all sessions and subagents, and points to the throwaway-worktree
   pattern.

## Residual gap this proposal addresses (layer 3)

The permission denylist is a **glob over the parsed sub-command's leading
tokens**. It reliably catches the naive forms (which is what the incident was),
but a determined or unlucky command shape can slip past:

- `git -C <path> checkout ...` — the destructive verb is not the first token
  after `git`, so `"git checkout*"` does not match.
- `git --git-dir=… --work-tree=… reset --hard`.
- an aliased or env-prefixed invocation, or a heredoc/script that runs the op
  indirectly.

For a **good-faith** agent (the incident was naive, not adversarial) layers 1+2
are likely sufficient. Layer 3 is defense-in-depth for the "constructed a
destructive command in a form the glob missed" case.

## Proposed layer 3: a `tool.execute.before` plugin

A single global plugin, e.g. `assets/opencode/plugins/git-worktree-guard.ts`,
deployed via `users/dev/opencode-config.nix` like the other plugins.

### Mechanism

```ts
export default (async ({ client }) => ({
  "tool.execute.before": async (input, output) => {
    if (input.tool !== "bash") return
    const agent = await resolveAgentName(client, input.sessionID) // see open Q1
    if (!GUARDED_AGENTS.has(agent)) return                        // scope: the 4 review agents
    const cmd = String(output.args?.command ?? "")
    const hit = findDestructiveGit(cmd)                           // robust parse, see below
    if (hit) {
      throw new Error(
        `git-worktree-guard: '${hit}' is a tree-wide destructive git op and is ` +
        `blocked for review/verification subagents. Use read-only git ` +
        `(diff/show/log) or a throwaway 'git worktree add "$(mktemp -d)" <sha>'.`)
    }
  },
}))
```

`findDestructiveGit(cmd)` is the robust part: split the command on shell
operators (`&&`, `||`, `;`, `|`, newlines), and for each segment that invokes
`git`, skip git's *global* options (`-C <path>`, `--git-dir=…`,
`--work-tree=…`, `-c k=v`, `--namespace=…`) to find the real subcommand verb,
then test that verb against the destructive set (`reset`, `checkout`, `restore`,
`stash`, `clean`, `switch`, `commit`, `push`, `rebase`, `merge`, `cherry-pick`,
`revert`, `apply`, `am`, `rm`, `mv`). This catches `git -C <path> checkout`,
which the glob denylist cannot.

### Scope recommendation

Mirror the layer-1 set exactly: guard **only** `code-reviewer`, `spec-reviewer`,
`adversarial-reviewer`, `oracle`. Explicitly do **not** guard `implementer`
(legitimately commits) or normal primary sessions (developers run
`git checkout`/`stash` constantly — a global block would be intolerable). The
plugin's only job is to make the same 4-agent policy obfuscation-proof.

## Risks (this is the "broad/global" part)

- **Global blast radius.** `tool.execute.before` runs on *every* bash call in
  *every* session. A bug (bad split, thrown exception outside the guarded set)
  could break bash everywhere. Mitigation: the guard body must early-return for
  non-bash tools and non-guarded agents *before* any parsing, wrap the parse in
  try/catch, and only ever `throw` on a **positive** destructive match — never
  fail-closed on a parse error.
- **Agent resolution cost.** If identifying the agent requires an async
  `client.session.get` on every bash call, that's per-call latency. Mitigation:
  cache sessionID→agent; or gate on a cheaper signal if opencode exposes the
  agent name directly on the hook input (Open Q1).
- **False positives.** e.g. `git apply --check` (read-only patch validation) or
  a commit-message linter that greps for the string "git commit". Mitigation:
  match only when `git` is the actual argv[0] of a segment; treat `--check`/
  `--stat`/`--numstat` on `apply`/`diff` as read-only; keep the set tight.
- **Maintenance.** A hand-rolled shell tokenizer is a liability. Prefer reusing
  opencode's own parsed representation if a plugin hook exposes it (Open Q2),
  rather than re-implementing bash splitting.

## Open questions for the operator / implementation spike

1. **Does `tool.execute.before` expose the current agent name?** If not, what is
   the cheapest reliable way to resolve subagent→agent from `input.sessionID`
   (session metadata field vs. `client.session.get`)? This is the crux; the
   whole design hinges on cheaply knowing "is this one of the 4 guarded
   agents."
2. **Does any hook expose opencode's already-parsed command tree** (the one the
   permission layer uses), so the plugin can reuse it instead of re-tokenizing?
3. **Is layer 3 worth it at all,** given layers 1+2 already stop the good-faith
   case? Recommendation: only build it if (a) Q1 has a cheap answer and (b)
   we've actually observed a review agent construct a bypassing form. Otherwise
   the interim guard + the freeze + the AGENTS.md rule are adequate, and a
   global bash-intercepting plugin is not worth its blast radius.

## Rollback

Layer 3 is a single plugin file plus one `xdg.configFile` line in
`opencode-config.nix`; removing both and re-switching fully reverts it. Layers
1+2 are independent and stay regardless.
