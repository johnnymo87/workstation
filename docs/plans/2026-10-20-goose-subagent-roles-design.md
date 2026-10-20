# goose subagent roles: design

Date: 2026-10-20. Status: approved (user + adversarial-reviewer-opus, with changes folded in).

## Goal

Offer the opencode subagents in `assets/opencode/agents/` to goose sessions on
cloudbox (`honk chat`). The roles are oracle, adversarial-reviewer, code-reviewer,
spec-reviewer and implementer. Read-only roles must be **structurally** unable to
write files or run destructive git. This matches opencode's
`permission: {write: deny, edit: deny, bash: <git denylist>}`. Peers share
worktrees, and a "read-only" reviewer once ran `git stash`/`git checkout` and
destroyed a peer's uncommitted data.

## Where goose stands (fork patched-1.54.0.8)

- The `summon` platform extension's `delegate` tool runs ad-hoc tasks, recipes
  and agent `.md` files. Agent frontmatter parses only name, description and
  model.
- In 1.54, a delegate inherits the parent's extensions. `recipe.extensions` is
  ignored. The only narrowing is the model-supplied `extensions` filter.
- Subagents are forced into `GooseMode::Auto` and get an empty `HookManager`.
- Upstream #12802 (v1.55) binds subagents to the parent's hooks, mode and
  approvals. Upstream #12938 (merged, unreleased; not in 1.55) applies a
  delegated recipe's declared `extensions:`. Maintainers point to recipes with
  `extensions` + `available_tools` for scoped tool limits (#12921, #7808).
- `available_tools` is enforced at tool-list time
  (`extension_manager/mod.rs:234`) and at dispatch (`lease.rs:563-610`).
- developer's tools are `write, edit, shell, tree, read_image`. Reading goes
  through `shell`, so `available_tools` cannot express "shell, but no
  destructive git".
- The per-call `extensions` param is model-controlled, so it is not a
  guardrail. Omitting it inherits everything, and unmatched names are not
  fail-closed (open #12430). Rejected as the mechanism.
- cfp (:8789, `GCP_VERTEX_HOST`) is Claude-only. goose has a single Vertex
  host, so goose roles must use Claude models. There is no Gemini rewrite.

Research trail: `/tmp/research-goose-readonly-subagents-{question,answer}.md`
(ChatGPT), plus upstream PRs #12802, #12938, #12430, #7160 (closed "reader"
extension) and issue #12921.

## Design

### 1. goose fork patch `.9` (goose-patched, `patched/v1.54.0`)

In `summon.rs` `build_task_config`, the single choke point used by the sync,
background and state-machine paths:

- **Port the delegation half of #12938.** Use
  `resolve_extensions_for_new_session(recipe.extensions, Some(parent))`, then
  narrow by `params.extensions`. The filter can only narrow. Port upstream's
  `delegate_extension_selection` test.
- **Unscoped delegates default to read-only.** When the resolved recipe declares
  no extensions (ad-hoc delegates and Agent `.md` sources), the child gets the
  read-only set instead of the parent's set. Repo-local agents such as
  `.claude/agents/change-reviewer.md` keep working but cannot write. The set's
  source is TBD in the plan: a config.yaml key, or a named global recipe.
- **No shadowing of global roles.** Local sources (`<cwd>/.agents/recipes`,
  `.claude/agents`, ...) are scanned first and the first name wins. A name
  defined in the global recipes dir must resolve to the global file. Either
  refuse the local duplicate or prefer the global one.
- **Fail loudly on missing extensions.** A recipe-declared extension that fails
  to load is currently a debug log (`subagent_handler.rs:364-371`). Make it an
  error, or at least `warn` plus a failed delegate.

This patch is carried through the 1.55 upgrade (re-ported onto upstream's
`resolve_subagent_config`). Drop the #12938 part at ≥1.56. The read-only
default and the shadowing rule stay until upstream has an equivalent.

### 2. `pkgs/ro-shell` (workstation)

A stdio MCP server with one `shell` tool: command, optional timeout, combined
stdout/stderr, exit code.

- Its cwd defaults to goose's per-call `_meta["agent-working-dir"]`.
- Commands run with a PATH whose first entry is a **git shim**. The shim
  resolves aliases (`git config --get alias.X`; this host has `co=checkout`,
  `ci=commit`), refuses `-c`, `--exec-path` and `--git-dir` overrides, and
  **allowlists** subcommands:
  - status, diff, log, show, blame, rev-parse, ls-files, ls-tree, grep,
    cat-file, merge-base, for-each-ref, describe, shortlog, reflog (show only)
  - `branch`, `tag`, `worktree` in list-only forms
  - everything else is refused with a clear message
- Parse-time rule: refuse invocations of git by absolute path (anything that
  bypasses the shim).
- Table-driven tests: allowed forms, aliases, `sh -c`, `xargs git`,
  `find -exec git`, `checkout-index`, `branch -D`, `worktree remove`,
  `update-ref`, `/nix/store/.../git`.

Scope, stated honestly: this is an accident guard against "cleanup" git, as
strong as or stronger than opencode's denylist. It is not a filesystem sandbox.
`echo > file` and `sed -i` remain possible. An OS-level read-only sandbox
(bwrap) is a possible later tier.

### 3. Role recipes (workstation nix)

Generated from `assets/opencode/agents/{oracle,adversarial-reviewer,code-reviewer,spec-reviewer,implementer}.md`:

- `title`/`description` come from the frontmatter and `instructions` from the
  body, with opencode-only prose rewritten (Task tool, astra-probe, twin
  handles).
- `settings`: `goose_provider: gcp_vertex_ai`. Opus roles get
  `claude-opus-5-5`. Sonnet-tier roles get a Claude model that Vertex serves
  through cfp; verify the ID in planning, with `claude-opus-5-5` as fallback.
- **Read-only class** comes from the source's `write: deny`, not a hand list:
  - developer with `available_tools: [tree, read_image]`
  - `analyze`
  - `skills`
  - `ro-shell`
- **implementer:** full developer + analyze + skills.
- No role gets `summon`. Subagents already cannot delegate (`summon.rs:1337`).
- Build-time asserts: every `available_tools` is non-empty (empty means
  *all*); no `{{`, `{%` or `{#` in bodies (instructions are templates); the
  frontmatter shape is what we expect; `goose recipe validate` passes on each
  output.
- **Deployment must not use per-file symlinks.** Recipe and agent scans open
  files with `O_NOFOLLOW` (`skills/supporting_files.rs:303`), so home-manager
  per-file symlinks are silently skipped. Symlink the whole directory
  (scanning canonicalizes the dir) or copy at activation. Target dir:
  `~/.agents/recipes` or `~/.config/goose/recipes`, whichever the
  no-shadowing rule in patch `.9` treats as global.
- Cloudbox only.

### 4. Enablement

- `~/.config/goose/config.yaml`: set `summon: enabled: true`, plus a line in
  `config.yaml.README.md`. The file is hand-managed.
- pigeon sends its own extension list and still has no `delegate`. Lanes are
  unaffected.
- `GOOSE_MODE=auto` in the goose-serve env wins over config.yaml's
  `smart_approve` (`config/base.rs:766`), so delegation adds no approval
  bypass today.
- The parent learns the roles from summon's source listing and `@role`
  mentions. Whether a short AGENTS.md note helps is a plan-time question.

### 5. Acceptance (live, cloudbox, through honk chat)

- `delegate(source: "code-reviewer")`: the child's tools are exactly
  tree, read_image, analyze, skills and ro-shell `shell`. `git diff` works.
  `git stash`, `git co x` and `git checkout-index -a -f` are refused. `write`
  returns "Tool not found".
- An ad-hoc delegate and a repo `.claude/agents/*.md` agent get the read-only
  set.
- A repo-local `code-reviewer` does not shadow the global role.
- implementer can write and commit in a throwaway worktree.
- A broken ro-shell store path makes the delegate fail visibly.
- Roles are listed by `load` (proves the symlink issue is avoided).
- The model actually used by each role is confirmed in the cfp logs.
- A pigeon session still has no `delegate`.

## Out of scope (follow-up beads)

- goose fork upgrade to 1.55+: hooks for subagents, approval forwarding
  through honk, re-port of `.9`
- astra/fable twins and astra-probe failover
- devbox and macOS
- librarian and explore roles
- honk rendering of subagent progress (`honk-9qf.15.3`)
- lane-guard interaction for honk sessions in eng-agent-platform paths
  (unverified)
