# goose subagent roles: implementation plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans (or subagent-driven-development) to implement this plan task-by-task.

**Goal:** goose sessions on cloudbox can delegate to the five opencode roles
(oracle, adversarial-reviewer, code-reviewer, spec-reviewer, implementer). The
read-only roles are structurally unable to write files or run destructive git.

**Design:** `docs/plans/2026-10-20-goose-subagent-roles-design.md` (read it
first). Tracking bead: `honk-9qf` child "goose subagent roles" (run
`bd search "subagent roles"` in `~/projects/honk`).

**Architecture:** There are three parts.

- **Part A, goose fork patch `.9`.** Delegation applies a recipe's declared
  `extensions:`. A configured roles directory is scanned first, so repo files
  cannot shadow it. Unscoped delegates (ad-hoc delegates and agent `.md` files)
  get the extension set of a configured default recipe. In that mode, a
  subagent extension that fails to start fails the delegate.
- **Part B, workstation.**
  - A `ro-shell` stdio MCP server. Its `shell` tool runs bash with a git shim
    first on PATH. The shim allowlists read-only git.
  - A generator that turns `assets/opencode/agents/*.md` into goose recipes.
  - A cloudbox home-manager module that deploys them as a directory symlink.
    Per-file symlinks are skipped by goose's `O_NOFOLLOW` source reads.
- **Part C, deploy and live acceptance.** This part is user-gated.

**Tech stack:** Rust (goose fork), Python 3.13 stdlib plus `python3Packages.mcp`
1.15 and `pyyaml`, and Nix (flake checks on `aarch64-linux`).

---

## Ground rules (read before any task)

- **goose fork:**
  - Work in a new worktree off `fork/patched/v1.54.0` (`598e31514` =
    `patched-1.54.0.8`). The local branch `patched/v1.54.0` is stale (= `.3`).
    Do not use it.
  - Never push to `origin` (that is upstream block/goose). Only push to `fork`,
    always with an explicit refspec, and never force-push.
  - Never create a `v*` tag, and never move or delete a tag.
  - Format only with `cargo fmt -p goose`. Never use `--all`.
  - Commit style: `<area>: <sentence>`.
  - Add a one-line
    `// Modified by Jonathan Mohrbacher, 2026: <what>.` notice at the top of
    each upstream file you modify (Apache-2.0 §4(b); see `526b1f468`). If the
    file already has a notice, extend its line.
  - Cargo builds exceed the bash tool's 120s limit. Run them as a capped user
    unit that writes a log, then poll the log:
    ```bash
    export XDG_RUNTIME_DIR=/run/user/$(id -u)
    systemd-run --user --unit="gp-$RANDOM" --collect --working-directory="$FORK_WT" \
      -p MemoryMax=8G -p MemorySwapMax=0 \
      --setenv=PATH="$PATH" --setenv=HOME="$HOME" --setenv=CARGO_BUILD_JOBS=8 \
      --expand-environment=no \
      bash -c 'nix develop -c cargo test -p goose --lib -- subagent_policy > /tmp/opencode/gp.log 2>&1; echo "exit=$?" >> /tmp/opencode/gp.log'
    ```
- **workstation:**
  - Work in `~/projects/workstation/.worktrees/goose-subagent-roles`. Never
    commit at the root.
  - Commit bare, with no identity flags.
  - Commit style: `[NO-JIRA] <sentence>`.
  - Checks live at `checks.aarch64-linux.<name>`. Run one with
    `nix build --no-link .#checks.aarch64-linux.<name>`.
  - Every `test_*.py` must be executed by a check, with the full repo-relative
    path in the check script; `checks.test-reachability` enforces this. Pin
    `^Ran N tests` as well as `^OK`.
- **No deploys** (`nixos-rebuild`, `home-manager switch`, service restarts,
  `config.yaml` edits) until Part C. Part C is run by or with the user.

---

## Part A: goose fork patch `.9`

Setup (once):

```bash
cd ~/projects/goose-patched && git fetch fork
git worktree add -b subagent-policy .worktrees/subagent-policy fork/patched/v1.54.0
export FORK_WT=~/projects/goose-patched/.worktrees/subagent-policy
F=crates/goose/src/agents/platform_extensions/summon.rs
```

Name every new test `subagent_policy_<what>`, so that a single filter
(`subagent_policy`) selects all of them, locally and in CI.

Mark every test that sets env with `#[serial]` and use `env_lock::lock_env`.
Both crates are already dev-deps. If `lock_env` requires `&'static str` for
values, use `Box::leak(path.into_boxed_str())`. Global goose config is read from
env first (`config/base.rs:765`), so `GOOSE_SUBAGENT_*` keys can be driven from
tests through env.

### Task A1: Roles directory is scanned first and cannot be shadowed

**Files:** Modify `$F`. In `discover_filesystem_sources` (~`:370`), add a
helper next to `max_background_tasks` (~`:518`), plus tests in `mod tests`.

**Step 1: Write the failing test** (append to `mod tests`):

```rust
#[test]
#[serial]
fn subagent_policy_roles_dir_wins_over_local_sources() {
    let roles = TempDir::new().unwrap();
    let wd = TempDir::new().unwrap();
    fs::write(
        roles.path().join("code-reviewer.yaml"),
        "version: 1.0.0\ntitle: Role\ndescription: global role\ninstructions: role body\n",
    )
    .unwrap();
    fs::create_dir_all(wd.path().join(".claude/agents")).unwrap();
    fs::write(
        wd.path().join(".claude/agents/cr.md"),
        "---\nname: code-reviewer\ndescription: local impostor\n---\nimpostor",
    )
    .unwrap();
    fs::create_dir_all(wd.path().join(".goose/recipes")).unwrap();
    fs::write(
        wd.path().join(".goose/recipes/code-reviewer.yaml"),
        "version: 1.0.0\ntitle: X\ndescription: local recipe impostor\ninstructions: x\n",
    )
    .unwrap();
    let roles_dir: &'static str = Box::leak(roles.path().to_str().unwrap().to_string().into_boxed_str());
    let _env = env_lock::lock_env([("GOOSE_SUBAGENT_ROLES_DIR", Some(roles_dir))]);

    let sources = discover_filesystem_sources(wd.path());
    let hits: Vec<_> = sources.iter().filter(|s| s.name == "code-reviewer").collect();
    assert_eq!(hits.len(), 1);
    assert_eq!(hits[0].description, "global role");
    assert!(hits[0].path.starts_with(roles.path().canonicalize().unwrap().to_str().unwrap()));
}

#[test]
#[serial]
fn subagent_policy_roles_dir_unset_keeps_upstream_order() {
    let wd = TempDir::new().unwrap();
    fs::create_dir_all(wd.path().join(".claude/agents")).unwrap();
    fs::write(
        wd.path().join(".claude/agents/cr.md"),
        "---\nname: code-reviewer\ndescription: local agent\n---\nbody",
    )
    .unwrap();
    let _env = env_lock::lock_env([("GOOSE_SUBAGENT_ROLES_DIR", None::<&str>)]);
    let sources = discover_filesystem_sources(wd.path());
    let hit = sources.iter().find(|s| s.name == "code-reviewer").unwrap();
    assert_eq!(hit.description, "local agent");
}
```

**Step 2: Run it.** Use the systemd-run recipe with the filter
`subagent_policy_roles_dir`. Expected: the first test FAILS (impostor found),
and the second passes.

**Step 3: Implement.** Add the helper:

```rust
/// Directory of operator-managed role recipes (fork patch). Scanned before every
/// other source so a repo's `.claude/agents/<name>.md` or `.goose/recipes/<name>.yaml`
/// cannot shadow a role. Unset/empty = upstream behaviour.
fn subagent_roles_dir() -> Option<PathBuf> {
    Config::global()
        .get_param::<String>("GOOSE_SUBAGENT_ROLES_DIR")
        .ok()
        .filter(|s| !s.is_empty())
        .map(PathBuf::from)
}
```

In `discover_filesystem_sources`, insert the following right after
`let config = Paths::config_dir();` and before the first
`scan_recipes_from_dir(working_dir, ...)`:

```rust
    if let Some(dir) = subagent_roles_dir() {
        scan_recipes_from_dir(&dir, SourceType::Recipe, false, &mut sources, &mut seen);
    }
```

Note: session `sub_recipes` are still merged ahead of filesystem sources
(`get_sources`, ~`:780`). That is the session's own recipe, which is
operator-controlled, so it is accepted.

**Step 4: Run.** Expected: both PASS.

**Step 5: Commit.** `git commit -am "summon: GOOSE_SUBAGENT_ROLES_DIR is scanned first so local sources cannot shadow a role"`

### Task A2: Delegation honours a recipe's declared extensions (port of upstream #12938, delegation half)

**Files:** Modify `$F` `build_task_config` (~`:1723-1753`), the imports, and
`mod tests`.

**Step 1: Write the failing tests.** Add a helper and tests. The helper is
modelled on `test_build_task_config_recreates_registered_parent_provider`
(~`:3328`):

```rust
fn subagent_policy_platform(name: &str, tools: &[&str]) -> ExtensionConfig {
    ExtensionConfig::Platform {
        name: name.to_string(),
        description: String::new(),
        display_name: None,
        bundled: None,
        available_tools: tools.iter().map(|t| t.to_string()).collect(),
    }
}

async fn subagent_policy_resolve(
    declared: Option<Vec<ExtensionConfig>>,
    filter: Option<Vec<&str>>,
) -> anyhow::Result<Vec<ExtensionConfig>> {
    let temp_dir = TempDir::new().unwrap();
    let parent_provider = providers::create("openai", Vec::new()).await.unwrap();
    let mut context = create_test_context();
    context.provider = Arc::new(tokio::sync::Mutex::new(Some(Arc::clone(&parent_provider))));
    let client = SummonClient::new(context).unwrap();
    let mut session = crate::session::Session {
        provider_name: Some(parent_provider.get_name().to_string()),
        model_config: Some(goose_providers::model::ModelConfig::new("test-model")),
        working_dir: temp_dir.path().to_path_buf(),
        ..Default::default()
    };
    EnabledExtensionsState::new(vec![
        subagent_policy_platform("summon", &[]),
        subagent_policy_platform("developer", &[]),
    ])
    .to_extension_data(&mut session.extension_data)
    .unwrap();
    let mut recipe = empty_recipe();
    recipe.extensions = declared;
    let params = DelegateParams {
        extensions: filter.map(|f| f.into_iter().map(String::from).collect()),
        provider: Some(parent_provider.get_name().to_string()),
        model: Some("test-model".to_string()),
        ..Default::default()
    };
    Ok(client.build_task_config(&params, &recipe, &session).await?.extensions)
}

fn names(exts: &[ExtensionConfig]) -> Vec<String> {
    exts.iter().map(|e| e.name()).collect()
}

#[tokio::test]
#[serial]
async fn subagent_policy_declared_extensions_replace_parent() {
    let _env = env_lock::lock_env([("GOOSE_SUBAGENT_DEFAULT_RECIPE", None::<&str>)]);
    let declared = vec![
        subagent_policy_platform("developer", &["tree", "read_image"]),
        subagent_policy_platform("todo", &[]),
    ];
    let got = subagent_policy_resolve(Some(declared.clone()), None).await.unwrap();
    assert_eq!(got, declared); // available_tools preserved, summon NOT inherited
}

#[tokio::test]
#[serial]
async fn subagent_policy_filter_only_narrows_declared() {
    let _env = env_lock::lock_env([("GOOSE_SUBAGENT_DEFAULT_RECIPE", None::<&str>)]);
    let declared = vec![
        subagent_policy_platform("developer", &["tree"]),
        subagent_policy_platform("todo", &[]),
    ];
    let got = subagent_policy_resolve(Some(declared), Some(vec!["developer", "summon"]))
        .await
        .unwrap();
    assert_eq!(got, vec![subagent_policy_platform("developer", &["tree"])]);
}

#[tokio::test]
#[serial]
async fn subagent_policy_undeclared_inherits_parent_when_unconfigured() {
    let _env = env_lock::lock_env([("GOOSE_SUBAGENT_DEFAULT_RECIPE", None::<&str>)]);
    let got = subagent_policy_resolve(None, None).await.unwrap();
    assert_eq!(names(&got), vec!["summon", "developer"]);
}
```

Imports: `ExtensionConfig` (`crate::agents::extension::ExtensionConfig`) and
`EnabledExtensionsState` are probably already in scope through `use super::*`.
Add them if the compiler says otherwise.

**Step 2: Run** with the filter `subagent_policy`. Expected:
`declared_extensions_replace_parent` and `filter_only_narrows_declared` FAIL.

**Step 3: Implement.** Change the import to
`use crate::config::{resolve_extensions_for_new_session, Config, GooseMode};`.
Then replace the opening of `build_task_config`, the
`let mut extensions = EnabledExtensionsState::extensions_or_default(...)`
statement, with:

```rust
        let mut extensions = match recipe.extensions.as_deref() {
            // Port of upstream #12938 (delegation half): a delegated recipe's
            // declared extensions replace the parent's.
            Some(declared) => resolve_extensions_for_new_session(Some(declared), None),
            None => EnabledExtensionsState::extensions_or_default(
                Some(&session.extension_data),
                Config::global(),
            ),
        };
```

Leave the existing `params.extensions` filter block unchanged. It only ever
`retain`s, so it can only narrow. Update the `extensions` parameter description
in the delegate tool schema (~`:711`) to upstream's text: `"Restrict extensions by
name. Omit to use the source recipe's declared extensions, or inherit the parent's
if none are declared. Empty array for none."`.

**Step 4: Run.** Expected: all three PASS. Then run the whole summon module
(filter `platform_extensions::summon`). Expected: PASS.

**Step 5: Commit.** `git commit -am "summon: a delegated recipe's declared extensions replace the parent's (port of upstream #12938)"`

### Task A3: Unscoped delegates get the default recipe's extensions

**Files:** Modify `$F`: add a helper near `subagent_roles_dir`, change
`build_task_config`, and add tests.

**Step 1: Write the failing tests:**

```rust
fn subagent_policy_write_default(dir: &TempDir, body: &str) -> &'static str {
    let p = dir.path().join("unscoped.yaml");
    fs::write(&p, body).unwrap();
    Box::leak(p.to_str().unwrap().to_string().into_boxed_str())
}

#[tokio::test]
#[serial]
async fn subagent_policy_unscoped_gets_default_recipe_extensions() {
    let d = TempDir::new().unwrap();
    let p = subagent_policy_write_default(
        &d,
        "version: 1.0.0\ntitle: U\ndescription: U\ninstructions: u\nextensions:\n  - type: platform\n    name: developer\n    available_tools: [tree]\n",
    );
    let _env = env_lock::lock_env([("GOOSE_SUBAGENT_DEFAULT_RECIPE", Some(p))]);
    let got = subagent_policy_resolve(None, None).await.unwrap();
    assert_eq!(got, vec![subagent_policy_platform("developer", &["tree"])]);
}

#[tokio::test]
#[serial]
async fn subagent_policy_declared_recipe_ignores_default() {
    let d = TempDir::new().unwrap();
    let p = subagent_policy_write_default(
        &d,
        "version: 1.0.0\ntitle: U\ndescription: U\ninstructions: u\nextensions:\n  - type: platform\n    name: todo\n",
    );
    let _env = env_lock::lock_env([("GOOSE_SUBAGENT_DEFAULT_RECIPE", Some(p))]);
    let declared = vec![subagent_policy_platform("developer", &[])];
    let got = subagent_policy_resolve(Some(declared.clone()), None).await.unwrap();
    assert_eq!(got, declared);
}

#[tokio::test]
#[serial]
async fn subagent_policy_missing_default_recipe_fails_closed() {
    let _env = env_lock::lock_env([("GOOSE_SUBAGENT_DEFAULT_RECIPE", Some("/nonexistent/unscoped.yaml"))]);
    let err = subagent_policy_resolve(None, None).await.unwrap_err();
    assert!(err.to_string().contains("GOOSE_SUBAGENT_DEFAULT_RECIPE"), "{err}");
}

#[tokio::test]
#[serial]
async fn subagent_policy_default_recipe_without_extensions_fails_closed() {
    let d = TempDir::new().unwrap();
    let p = subagent_policy_write_default(&d, "version: 1.0.0\ntitle: U\ndescription: U\ninstructions: u\n");
    let _env = env_lock::lock_env([("GOOSE_SUBAGENT_DEFAULT_RECIPE", Some(p))]);
    let err = subagent_policy_resolve(None, None).await.unwrap_err();
    assert!(err.to_string().contains("declares no extensions"), "{err}");
}
```

**Step 2: Run** with the filter `subagent_policy`. Expected: the four new tests
FAIL.

**Step 3: Implement.** Add the helper:

```rust
/// Fork patch: when set, a delegate whose recipe declares no extensions (ad-hoc
/// tasks, agent `.md` files, undeclared sub-recipes) gets THIS recipe's
/// extensions instead of inheriting the parent's. Fails closed: a set-but-broken
/// value is an error, never a silent fallback to the parent's tools.
pub(crate) fn subagent_default_recipe_path() -> Option<String> {
    Config::global()
        .get_param::<String>("GOOSE_SUBAGENT_DEFAULT_RECIPE")
        .ok()
        .filter(|s| !s.is_empty())
}

fn unscoped_subagent_extensions() -> anyhow::Result<Option<Vec<ExtensionConfig>>> {
    let Some(path) = subagent_default_recipe_path() else {
        return Ok(None);
    };
    let content = std::fs::read_to_string(&path).map_err(|e| {
        anyhow::anyhow!("GOOSE_SUBAGENT_DEFAULT_RECIPE: cannot read {path}: {e}")
    })?;
    let recipe = Recipe::from_content(&content).map_err(|e| {
        anyhow::anyhow!("GOOSE_SUBAGENT_DEFAULT_RECIPE: {path} is not a valid recipe: {e}")
    })?;
    let declared = recipe.extensions.ok_or_else(|| {
        anyhow::anyhow!("GOOSE_SUBAGENT_DEFAULT_RECIPE: {path} declares no extensions")
    })?;
    Ok(Some(resolve_extensions_for_new_session(Some(&declared), None)))
}
```

Change the `None =>` arm from Task A2 to:

```rust
            None => match unscoped_subagent_extensions()? {
                Some(defaults) => defaults,
                None => EnabledExtensionsState::extensions_or_default(
                    Some(&session.extension_data),
                    Config::global(),
                ),
            },
```

**Step 4: Run.** Expected: all `subagent_policy*` tests PASS.

**Step 5: Commit.** `git commit -am "summon: GOOSE_SUBAGENT_DEFAULT_RECIPE scopes delegates that declare no extensions, failing closed"`

### Task A4: When the policy is on, a subagent extension that fails to start fails the delegate

**Files:** Modify `crates/goose/src/agents/subagent_handler.rs` at both add
loops (`:127-131` in `from_foreground_subagent_session` and `:364-371` in
`get_agent_messages`). Add a test in that file's `mod tests`, or create one if
none exists.

**Step 1: Write the failing test.** First find how existing tests in
`subagent_handler.rs` or `agents/` build an `Agent`; search with
`git grep -n "Agent::with_config" -- crates/goose/src`. Extract a helper and
test it:

```rust
#[tokio::test]
async fn subagent_policy_strict_extension_failure_is_an_error() {
    let agent = /* construct a test Agent the way neighbouring tests do */;
    let bad = ExtensionConfig::Stdio {
        name: "ro-shell".into(), description: String::new(),
        cmd: "/nonexistent/ro-shell".into(), args: vec![], envs: Default::default(),
        env_keys: vec![], timeout: Some(5), cwd: None, bundled: None, available_tools: vec![],
    };
    assert!(add_subagent_extensions(&agent, vec![bad.clone()], "s1", true).await.is_err());
    assert!(add_subagent_extensions(&agent, vec![bad], "s1", false).await.is_ok());
}
```

**Step 2: Run.** Expected: FAIL to compile (`add_subagent_extensions` does not
exist).

**Step 3: Implement.** In `subagent_handler.rs`:

```rust
/// Fork patch: with GOOSE_SUBAGENT_DEFAULT_RECIPE set (the subagent policy), an
/// extension the subagent was given but could not start is an error -- a reviewer
/// whose ro-shell failed must not run on with no shell and report anyway.
async fn add_subagent_extensions(
    agent: &Agent,
    extensions: Vec<ExtensionConfig>,
    session_id: &str,
    strict: bool,
) -> Result<()> {
    for extension in extensions {
        let name = extension.name();
        if let Err(e) = agent.add_extension_inner(extension, session_id).await {
            if strict {
                return Err(anyhow!("Failed to start extension '{name}' for subagent: {e}"));
            }
            debug!("Failed to add extension '{}' to subagent: {}", name, e);
        }
    }
    Ok(())
}
```

Use it at `:127` as
`add_subagent_extensions(&agent, extensions, session_id, strict).await?;`.
For `:364`, the existing code calls `agent.add_extension` (an `Arc<Agent>`),
not `add_extension_inner`. If the two differ in more than visibility, give the
helper a closure parameter or write two thin loops. Keep the semantics
identical: error when `strict`, debug log otherwise.

`strict` is
`crate::agents::platform_extensions::summon::subagent_default_recipe_path().is_some()`.
Make that function `pub(crate)` if the module path requires it.

**Step 4: Run** with the filters `subagent_policy` and `subagent_handler`.
Expected: PASS.

**Step 5: Commit.** `git commit -am "subagents: with the subagent policy on, an extension that fails to start fails the delegate"`

### Task A5: Notices, CI filter, lint, full module tests

**Step 1:** Add or extend the modification-notice line at the top of
`summon.rs` and `subagent_handler.rs`. Suggested text: `// Modified by
Jonathan Mohrbacher, 2026: subagent policy (roles dir, declared/default
extensions, strict start).`

**Step 2:** In `.github/workflows/patched-release.yml`, append ` subagent_policy`
to the end of the long
`cargo test --release -p goose --features "$F" --lib -- gcpvertexai ...` line.

**Step 3:** Run `nix develop -c cargo fmt -p goose`, then
`nix develop -c cargo clippy -p goose --all-targets -- -D warnings` (as a unit).
Then run `cargo test -p goose --lib -- platform_extensions::summon subagent_handler subagent_policy`.
Expected: clean, all PASS.

**Step 4: Commit.** `git commit -am "ci: run the subagent policy tests before releasing"`

### Task A6: Fork PR, merge, tag `patched-1.54.0.9`, release. USER-GATED: pushes to GitHub.

Ask the user before Step 1. Mirror how `.4`–`.8` shipped (squash-merged PRs
`#1`–`#7`).

1. `git -C "$FORK_WT" push fork subagent-policy:refs/heads/subagent-policy`
2. `gh pr create -R johnnymo87/goose --base patched/v1.54.0 --head subagent-policy`.
   Use the title `[NO-JIRA] Subagent policy: role recipes dir, declared/default
   delegate extensions, strict start`. The body must say that all of it is
   inert unless `GOOSE_SUBAGENT_ROLES_DIR` / `GOOSE_SUBAGENT_DEFAULT_RECIPE`
   are set, list the four behaviours, and link the design doc.
3. After the user merges: `git fetch fork`. Tag the squash commit with an
   SSH-signed annotated tag, the same way previous tags were made:
   `git tag -s patched-1.54.0.9 -m "patched-1.54.0.9: subagent policy (#N), on top of .8" <sha>`.
   Push it with `git push fork refs/tags/patched-1.54.0.9`.
4. Watch the run:
   ```bash
   RUN=$(gh run list -R johnnymo87/goose --workflow patched-release.yml --branch patched-1.54.0.9 -L1 --json databaseId -q '.[0].databaseId')
   gh run view "$RUN" -R johnnymo87/goose --json status,conclusion,jobs
   ```
   Expect `build`, `test-patches` and `release` to all succeed (~30 min). If
   one fails: fix it, and cut `.10`. Never move the tag.
5. `gh release view patched-1.54.0.9 -R johnnymo87/goose --json assets` should
   list the 4 tarballs plus `SHA256SUMS`.

---

## Part B: workstation

Setup: `cd ~/projects/workstation/.worktrees/goose-subagent-roles`.

### Task B1: `ro-git` shim (allowlist) and its tests

**Files:**
- Create `pkgs/ro-shell/ro_git.py`
- Create `pkgs/ro-shell/test_ro_shell.py` (the shim section; B2 adds more)

**Step 1: Write the failing tests** (`test_ro_shell.py`, stdlib unittest):

```python
#!/usr/bin/env python3
"""Tests for ro-shell: the read-only git shim and the MCP shell tool.

Env:
  RO_SHELL_BIN       the packaged ro-shell (MCP server) -- B2 tests
  RO_SHELL_SHIM_DIR  dir containing the shim installed as `git`
  RO_SHELL_REAL_GIT  the real git binary
"""
import json, os, shutil, subprocess, sys, tempfile, unittest

SHIM_DIR = os.environ["RO_SHELL_SHIM_DIR"]
REAL_GIT = os.environ["RO_SHELL_REAL_GIT"]
REFUSED = 3


def real(repo, *args):
    return subprocess.run([REAL_GIT, "-C", repo, *args], capture_output=True, text=True, check=True).stdout


def make_repo():
    d = tempfile.mkdtemp()
    real(d, "init", "-q", "-b", "main")
    real(d, "config", "user.email", "t@example.com")
    real(d, "config", "user.name", "t")
    real(d, "config", "alias.st", "status")
    real(d, "config", "alias.lg", "log --oneline")
    real(d, "config", "alias.co", "checkout")
    real(d, "config", "alias.ci", "commit")
    real(d, "config", "alias.bang", "!rm -rf .")
    with open(os.path.join(d, "f.txt"), "w") as fh:
        fh.write("one\n")
    real(d, "add", "f.txt")
    real(d, "commit", "-qm", "init")
    with open(os.path.join(d, "f.txt"), "a") as fh:
        fh.write("uncommitted\n")  # the peer's precious uncommitted work
    return d


def snapshot(repo):
    return (real(repo, "status", "--porcelain"), real(repo, "stash", "list"),
            real(repo, "for-each-ref"), open(os.path.join(repo, "f.txt")).read())


def shim(repo, args):
    env = dict(os.environ, RO_SHELL_REAL_GIT=REAL_GIT)
    return subprocess.run([os.path.join(SHIM_DIR, "git"), *args], cwd=repo, env=env,
                          capture_output=True, text=True)


ALLOWED = [
    ["status"], ["diff"], ["diff", "--stat", "HEAD"], ["log", "--oneline"], ["show", "HEAD"],
    ["blame", "f.txt"], ["rev-parse", "HEAD"], ["ls-files"], ["grep", "one"],
    ["branch"], ["branch", "-a"], ["branch", "--contains", "HEAD"], ["tag"], ["tag", "-l"],
    ["worktree", "list"], ["stash", "list"], ["reflog"], ["config", "--get", "user.name"],
    ["config", "--list"], ["remote", "-v"], ["--no-pager", "log", "-1"], ["-C", ".", "status"],
    ["st"], ["lg"], ["--version"], ["merge-base", "HEAD", "HEAD"], ["cat-file", "-p", "HEAD"],
]

REFUSED_CASES = [
    ["stash"], ["stash", "push"], ["checkout", "."], ["checkout", "--", "f.txt"], ["co", "."],
    ["ci", "-am", "x"], ["reset", "--hard"], ["restore", "f.txt"], ["clean", "-fd"],
    ["switch", "-c", "x"], ["commit", "-am", "x"], ["push"], ["pull"], ["fetch"],
    ["rebase", "main"], ["merge", "main"], ["cherry-pick", "HEAD"], ["revert", "HEAD"],
    ["apply", "x.patch"], ["am"], ["rm", "f.txt"], ["mv", "f.txt", "g.txt"],
    ["checkout-index", "-a", "-f"], ["read-tree", "-u", "HEAD"], ["update-ref", "refs/heads/x", "HEAD"],
    ["branch", "-D", "main"], ["branch", "newbranch"], ["branch", "-m", "x"], ["tag", "v1"],
    ["tag", "-d", "v1"], ["worktree", "remove", "x"], ["worktree", "add", "x"],
    ["submodule", "update"], ["gc"], ["reflog", "expire", "--all"], ["config", "user.name", "x"],
    ["config", "--unset", "user.name"], ["diff", "--output=/tmp/ro-shell-test-out"],
    ["-c", "alias.x=reset", "x", "--hard"], ["-c", "core.pager=sh", "log"],
    ["--exec-path=/tmp", "status"], ["bang"], ["stash", "pop"], ["notes", "add", "-m", "x"],
]


class ShimTest(unittest.TestCase):
    def setUp(self):
        self.repo = make_repo()

    def tearDown(self):
        shutil.rmtree(self.repo, ignore_errors=True)

    def test_allowed(self):
        for args in ALLOWED:
            with self.subTest(args=args):
                r = shim(self.repo, args)
                self.assertNotEqual(r.returncode, REFUSED, r.stderr)
                self.assertNotIn("ro-shell: refused", r.stderr)

    def test_refused_and_repo_untouched(self):
        before = snapshot(self.repo)
        for args in REFUSED_CASES:
            with self.subTest(args=args):
                r = shim(self.repo, args)
                self.assertEqual(r.returncode, REFUSED, (args, r.stdout, r.stderr))
                self.assertIn("ro-shell: refused", r.stderr)
        self.assertEqual(snapshot(self.repo), before)
        self.assertFalse(os.path.exists("/tmp/ro-shell-test-out"))

    def test_misconfigured_shim_refuses(self):
        env = dict(os.environ)
        env.pop("RO_SHELL_REAL_GIT", None)
        r = subprocess.run([os.path.join(SHIM_DIR, "git"), "status"], cwd=self.repo, env=env,
                           capture_output=True, text=True)
        self.assertEqual(r.returncode, REFUSED)


if __name__ == "__main__":
    unittest.main(verbosity=2)
```

**Step 2: Run** with a throwaway shim dir. Expected: FAIL, because the shim
does not exist:

```bash
d=$(mktemp -d); ln -s "$PWD/pkgs/ro-shell/ro_git.py" "$d/git"
RO_SHELL_SHIM_DIR=$d RO_SHELL_REAL_GIT=$(command -v git) python3 pkgs/ro-shell/test_ro_shell.py
```

**Step 3: Implement** `pkgs/ro-shell/ro_git.py` and `chmod +x` it:

```python
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
    if any(a.startswith("--output") for a in rest):
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
        return not rest or rest[0] == "show" or rest[0].startswith("-")
    if sub == "config":
        return bool(f & CONFIG_READ or set(rest[:1]) & CONFIG_READ) and not (
            f & CONFIG_WRITE or set(rest[:1]) & CONFIG_WRITE)
    if sub == "remote":
        return not rest or set(rest) <= {"-v", "--verbose"} or rest[0] in ("get-url", "show")
    if sub == "notes":
        return rest[:1] in (["list"], ["show"])
    if sub == "submodule":
        return not rest or rest[0] in ("status", "summary")
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
```

**Step 4: Run** the command from Step 2. Expected: `OK`. If a case is
miscategorized, fix `sub_ok`. Do not delete the test case.

**Step 5: Commit.** `git add pkgs/ro-shell && git commit -m "[NO-JIRA] ro-shell: read-only git shim (allowlist, alias-aware)"`

### Task B2: `ro-shell` MCP server

**Files:**
- Create `pkgs/ro-shell/ro_shell.py`
- Modify `pkgs/ro-shell/test_ro_shell.py`

**Step 1: Write the failing tests.** Append these classes to the test file,
before `if __name__`:

```python
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))


class CheckCommandTest(unittest.TestCase):
    def test_bypasses_refused(self):
        import ro_shell
        for cmd in ["/nix/store/abc-git-2.50/bin/git stash", "/run/current-system/sw/bin/git reset --hard",
                    "PATH=/usr/bin git stash", "env PATH=/x git stash", "export PATH=/x; git stash",
                    "command -p git stash", "x=1 PATH=/y git status"]:
            with self.subTest(cmd=cmd):
                self.assertIsNotNone(ro_shell.check_command(cmd))

    def test_normal_commands_pass(self):
        import ro_shell
        for cmd in ["git diff | head", "rg -n foo src/", "cd sub && git log -1", "echo $PATH",
                    "ls ~/projects/git-tools", "cat .gitignore"]:
            with self.subTest(cmd=cmd):
                self.assertIsNone(ro_shell.check_command(cmd))


class RunCommandTest(unittest.TestCase):
    def setUp(self):
        self.repo = make_repo()
        os.environ["RO_SHELL_SHIM_DIR"] = SHIM_DIR

    def tearDown(self):
        shutil.rmtree(self.repo, ignore_errors=True)

    def test_indirect_git_hits_shim(self):
        import ro_shell
        before = snapshot(self.repo)
        for cmd in ["sh -c 'git stash'", "echo stash | xargs git", "find . -maxdepth 0 -exec git stash \\;",
                    "bash -c 'cd . && git checkout -- f.txt'", "git co .", "(git reset --hard)"]:
            with self.subTest(cmd=cmd):
                code, out = ro_shell.run_command(cmd, self.repo, 30)
                self.assertIn("ro-shell: refused", out)
        self.assertEqual(snapshot(self.repo), before)

    def test_read_only_git_works_and_cwd_honoured(self):
        import ro_shell
        code, out = ro_shell.run_command("git diff --stat && pwd", self.repo, 30)
        self.assertEqual(code, 0, out)
        self.assertIn("f.txt", out)
        self.assertIn(os.path.realpath(self.repo), os.path.realpath(out.strip().splitlines()[-1]))

    def test_timeout(self):
        import ro_shell
        code, out = ro_shell.run_command("sleep 5", self.repo, 1)
        self.assertIn("timed out", out)


class McpStdioTest(unittest.TestCase):
    """End-to-end over stdio JSON-RPC against the PACKAGED binary."""

    def rpc(self, proc, msg):
        proc.stdin.write(json.dumps(msg) + "\n")
        proc.stdin.flush()
        if "id" not in msg:
            return None
        while True:
            line = proc.stdout.readline()
            self.assertTrue(line, "server closed stdout")
            resp = json.loads(line)
            if resp.get("id") == msg["id"]:
                return resp

    def test_tools_list_and_call(self):
        repo = make_repo()
        proc = subprocess.Popen([os.environ["RO_SHELL_BIN"]], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL, text=True)
        try:
            self.rpc(proc, {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
                "protocolVersion": "2025-03-26", "capabilities": {}, "clientInfo": {"name": "t", "version": "0"}}})
            self.rpc(proc, {"jsonrpc": "2.0", "method": "notifications/initialized"})
            tools = self.rpc(proc, {"jsonrpc": "2.0", "id": 2, "method": "tools/list"})["result"]["tools"]
            self.assertEqual([t["name"] for t in tools], ["shell"])
            r = self.rpc(proc, {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {
                "name": "shell", "arguments": {"command": "pwd; git stash"},
                "_meta": {"agent-working-dir": repo}}})["result"]
            text = "".join(c.get("text", "") for c in r["content"])
            self.assertIn(os.path.realpath(repo), text)       # goose's per-call working dir honoured
            self.assertIn("ro-shell: refused", text)
            r = self.rpc(proc, {"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {
                "name": "shell", "arguments": {"command": "/nix/store/x-git/bin/git stash"}}})["result"]
            self.assertTrue(r.get("isError"), r)
        finally:
            proc.kill()
            shutil.rmtree(repo, ignore_errors=True)
```

**Step 2: Run** the command from B1 Step 2. Expected: the new classes FAIL
(`ro_shell` is missing). `McpStdioTest` needs `RO_SHELL_BIN`, so it is only
exercised by the flake check in B3. Locally, skip it by leaving `RO_SHELL_BIN`
unset: add `@unittest.skipUnless(os.environ.get("RO_SHELL_BIN"), "packaged binary only")`
to the class. The flake check sets the variable and pins the count, so the skip
cannot hide anything there.

**Step 3: Implement** `pkgs/ro-shell/ro_shell.py`:

```python
#!/usr/bin/env python3
"""ro-shell: stdio MCP server with one `shell` tool for goose's read-only roles.

Runs `bash -c <command>` with the ro-git shim first on PATH, so every git the
command reaches -- directly, via sh -c, xargs, find -exec, scripts -- is
filtered to read-only subcommands. check_command() refuses the few forms that
would skip the shim (git by absolute path, PATH rewrites, `command -p`).

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


def check_command(command: str):
    """Return a refusal message, or None if the command may run."""
    if ABS_GIT.search(command):
        return "ro-shell: refused: git by path bypasses the read-only git shim; call plain `git`."
    if PATH_ASSIGN.search(command) or COMMAND_P.search(command):
        return "ro-shell: refused: changing PATH (or `command -p`) bypasses the read-only git shim."
    return None


def run_command(command: str, cwd: str, timeout: int):
    env = dict(os.environ)
    env["PATH"] = os.environ["RO_SHELL_SHIM_DIR"] + os.pathsep + env.get("PATH", "")
    env.update(GIT_PAGER="cat", PAGER="cat", GIT_TERMINAL_PROMPT="0")
    bash = os.environ.get("RO_SHELL_BASH", "bash")
    proc = subprocess.Popen([bash, "-c", command], cwd=cwd, env=env, stdin=subprocess.DEVNULL,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)
    try:
        out, _ = proc.communicate(timeout=timeout)
        code = proc.returncode
        text = out.decode("utf-8", "replace")
    except subprocess.TimeoutExpired:
        os.killpg(proc.pid, signal.SIGKILL)
        out, _ = proc.communicate()
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
```

If `working_dir_from` cannot read the meta on mcp 1.15, `McpStdioTest` fails
in B3. In that case inspect `mcp.shared.context.RequestContext.meta` and
`mcp.types.RequestParams.Meta` in the nix store copy and adapt. Do not weaken
the test.

**Step 4: Run** the B1 Step 2 command. Expected: `OK`, with McpStdioTest
skipped locally.

**Step 5: Commit.** `git add pkgs/ro-shell && git commit -m "[NO-JIRA] ro-shell: stdio MCP shell tool that routes git through the read-only shim"`

### Task B3: Package ro-shell and wire its check

**Files:**
- Create `pkgs/ro-shell/default.nix`
- Create `pkgs/ro-shell/README.md` (short)
- Modify `flake.nix`: `localPkgsFor` (~`:64-135`) and `checks.${devboxSystem}`

**Step 1: Package** `pkgs/ro-shell/default.nix`:

```nix
# ro-shell: stdio MCP server whose one `shell` tool runs bash with a read-only
# git shim first on PATH. Declared by goose's read-only role recipes
# (pkgs/goose-roles) in place of developer's shell. Accident guard, not a sandbox.
# Design: docs/plans/2026-10-20-goose-subagent-roles-design.md
{ lib, python3, git, bash, makeWrapper }:

python3.pkgs.buildPythonApplication {
  pname = "ro-shell";
  version = "0.1.0";
  format = "other";
  src = ./.;
  dontBuild = true;
  nativeBuildInputs = [ makeWrapper ];
  propagatedBuildInputs = [ python3.pkgs.mcp ];

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin $out/libexec/ro-shell/bin
    cp ro_shell.py $out/bin/ro-shell
    cp ro_git.py $out/libexec/ro-shell/bin/git
    chmod +x $out/bin/ro-shell $out/libexec/ro-shell/bin/git
    runHook postInstall
  '';

  makeWrapperArgs = [
    "--set" "RO_SHELL_SHIM_DIR" "${placeholder "out"}/libexec/ro-shell/bin"
    "--set" "RO_SHELL_REAL_GIT" "${git}/bin/git"
    "--set" "RO_SHELL_BASH" "${bash}/bin/bash"
  ];

  meta = {
    description = "Read-only shell MCP server for goose subagent roles";
    mainProgram = "ro-shell";
    platforms = lib.platforms.linux;
  };
}
```

Verify that the shim's shebang was patched to a store python:
`head -1 $(nix build --no-link --print-out-paths .#ro-shell)/libexec/ro-shell/bin/git`.

**Step 2: Wire it up.** In `localPkgsFor` add
`ro-shell = p.callPackage ./pkgs/ro-shell { };`. In checks, following the
`oc-revive-tests` shape (~`:1288`):

```nix
      ro-shell-tests = let ro = (localPkgsFor devboxSystem).ro-shell; in
        devboxPkgs.runCommand "ro-shell-tests" {
          nativeBuildInputs = [ (devboxPkgs.python3.withPackages (ps: [ ps.mcp ])) devboxPkgs.git devboxPkgs.gnugrep ];
          RO_SHELL_BIN = "${ro}/bin/ro-shell";
          RO_SHELL_SHIM_DIR = "${ro}/libexec/ro-shell/bin";
          RO_SHELL_REAL_GIT = "${devboxPkgs.git}/bin/git";
        } ''
          export HOME=$TMPDIR
          cd ${self}
          python3 pkgs/ro-shell/test_ro_shell.py 2>&1 | tee "$TMPDIR/ro.txt"
          grep -q '^OK' "$TMPDIR/ro.txt" || { echo "GATE FAILURE: ro-shell suite did not pass." >&2; exit 1; }
          grep -q '^Ran N tests' "$TMPDIR/ro.txt" || { echo "GATE FAILURE: expected N tests." >&2; exit 1; }
          grep -q 'skipped' "$TMPDIR/ro.txt" && { echo "GATE FAILURE: a test was skipped." >&2; exit 1; }
          touch $out
        '';
```

Replace `N` with the count the suite actually prints.

**Step 3: Run**
`nix build --no-link .#checks.aarch64-linux.ro-shell-tests` and
`nix build --no-link .#checks.aarch64-linux.test-reachability`. Expected: both
build.

**Step 4: Commit.** `git commit -am "[NO-JIRA] ro-shell: package and run its suite (incl. MCP stdio e2e) as a flake check"`.
Add the new files first.

### Task B4: Role recipe generator

**Files:**
- Create `pkgs/goose-roles/gen_goose_roles.py`
- Create `pkgs/goose-roles/test_gen_goose_roles.py`
- Create `pkgs/goose-roles/default.nix`

**Step 1: Write the failing tests** (`test_gen_goose_roles.py`):

```python
#!/usr/bin/env python3
import os, sys, tempfile, unittest
import yaml

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_goose_roles as g

RO = """---
description: Read-only advisor (opus-5-5 model) — architecture
mode: subagent
model: anthropic/claude-opus-5-5
variant: high
permission:
  write: deny
  edit: deny
  bash:
    "*": allow
---
You advise.
"""
RW = """---
description: Implementer — does one task
mode: subagent
model: anthropic/claude-sonnet-5-5
tools:
  datadog*: false
---
You implement.
"""
EXAMPLES = """---
description: |
  Use this agent when a step is done. Examples: <example>Context: x user: "y"</example>
model: anthropic/claude-sonnet-5-5
permission:
  write: deny
  edit: deny
---
Review.
"""
KW = dict(ro_shell_cmd="/nix/store/x-ro-shell/bin/ro-shell", provider="gcp_vertex_ai",
          opus_model="claude-opus-5-5", sonnet_model="claude-opus-5-5")


class GenTest(unittest.TestCase):
    def test_read_only_role(self):
        r = g.build_role("oracle", RO, **KW)
        self.assertEqual(r["settings"], {"goose_provider": "gcp_vertex_ai", "goose_model": "claude-opus-5-5"})
        self.assertEqual(r["description"], "Read-only advisor — architecture")
        exts = {e["name"]: e for e in r["extensions"]}
        self.assertEqual(set(exts), {"developer", "analyze", "skills", "ro-shell"})
        self.assertEqual(exts["developer"]["available_tools"], ["tree", "read_image"])
        self.assertEqual(exts["ro-shell"]["cmd"], KW["ro_shell_cmd"])
        self.assertEqual(exts["ro-shell"]["available_tools"], ["shell"])
        self.assertTrue(r["instructions"].startswith("You advise."))
        self.assertIn("read-only", r["instructions"])

    def test_implementer_role(self):
        r = g.build_role("implementer", RW, **KW)
        exts = {e["name"]: e for e in r["extensions"]}
        self.assertEqual(set(exts), {"developer", "analyze", "skills"})
        self.assertNotIn("available_tools", exts["developer"])

    def test_no_role_gets_summon(self):
        for src in (RO, RW, EXAMPLES):
            names = [e["name"] for e in g.build_role("x", src, **KW)["extensions"]]
            self.assertNotIn("summon", names)

    def test_examples_stripped_from_description(self):
        self.assertEqual(g.build_role("cr", EXAMPLES, **KW)["description"], "Use this agent when a step is done.")

    def test_inconsistent_permissions_rejected(self):
        bad = RO.replace("  edit: deny\n", "")
        with self.assertRaises(g.GenError):
            g.build_role("x", bad, **KW)

    def test_template_syntax_rejected(self):
        for tok in ("{{", "{%", "{#"):
            with self.subTest(tok=tok), self.assertRaises(g.GenError):
                g.build_role("x", RO.replace("You advise.", f"bad {tok} x"), **KW)

    def test_unknown_model_rejected(self):
        with self.assertRaises(g.GenError):
            g.build_role("x", RO.replace("anthropic/claude-opus-5-5", "openai/gpt-6-astra"), **KW)

    def test_unscoped_recipe_is_read_only_set(self):
        u = g.build_unscoped(KW["ro_shell_cmd"])
        self.assertEqual(sorted(e["name"] for e in u["extensions"]), ["analyze", "developer", "ro-shell", "skills"])

    def test_real_assets(self):
        agents = os.environ.get("GOOSE_ROLES_AGENTS_DIR")
        if not agents:
            self.skipTest("set GOOSE_ROLES_AGENTS_DIR")
        out = tempfile.mkdtemp()
        g.generate(agents, out, g.ROLES, **KW)
        files = sorted(os.listdir(os.path.join(out, "roles")))
        self.assertEqual(files, sorted(f"{r}.yaml" for r in g.ROLES))
        for role in g.ROLES:
            r = yaml.safe_load(open(os.path.join(out, "roles", f"{role}.yaml")))
            ro = "ro-shell" in [e["name"] for e in r["extensions"]]
            self.assertEqual(ro, role != "implementer", role)
        self.assertTrue(os.path.isfile(os.path.join(out, "unscoped.yaml")))


if __name__ == "__main__":
    unittest.main(verbosity=2)
```

**Step 2: Run**
`GOOSE_ROLES_AGENTS_DIR=assets/opencode/agents python3 pkgs/goose-roles/test_gen_goose_roles.py`
inside `nix shell nixpkgs#python3Packages.pyyaml`, or with
`python3.withPackages`. Expected: FAIL, because the module is missing.

**Step 3: Implement** `gen_goose_roles.py`:

```python
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
```

**Step 4: Package** `pkgs/goose-roles/default.nix`:

```nix
# goose role recipes generated from assets/opencode/agents/*.md (one source of
# truth with opencode). Output: $out/roles/<role>.yaml + $out/unscoped.yaml.
# Deployed as ONE directory symlink (users/dev/goose-roles.nix): goose reads
# recipe files with O_NOFOLLOW, so per-file home-manager symlinks are skipped.
#
# sonnetModel: claude-sonnet-5-5 404s on Vertex here (1002 failed requests via cfp,
# 2026-10-09) and cfp is Claude-only, so goose cannot use opencode's Gemini
# rewrite. Sonnet-tier roles run on Opus until a Vertex Sonnet works.
{ runCommand, python3, ro-shell, goose, agentsDir,
  opusModel ? "claude-opus-5-5", sonnetModel ? "claude-opus-5-5" }:

runCommand "goose-roles" {
  nativeBuildInputs = [ (python3.withPackages (ps: [ ps.pyyaml ])) goose ];
} ''
  python3 ${./gen_goose_roles.py} --agents-dir ${agentsDir} --out $out \
    --ro-shell-cmd ${ro-shell}/bin/ro-shell \
    --opus-model ${opusModel} --sonnet-model ${sonnetModel}
  export HOME=$TMPDIR GOOSE_DISABLE_KEYRING=true
  for f in $out/roles/*.yaml $out/unscoped.yaml; do
    goose recipe validate "$f" || { echo "goose-roles: $f failed goose recipe validate" >&2; exit 1; }
  done
''
```

If `goose recipe validate` needs provider config inside the sandbox, set
`GOOSE_PATH_ROOT=$TMPDIR/goose` and stub what it asks for. Do not drop the
validation.

**Step 5: Wire it up.** In `localPkgsFor`:

```nix
      goose-roles = p.callPackage ./pkgs/goose-roles {
        agentsDir = ./assets/opencode/agents;
        ro-shell = p.callPackage ./pkgs/ro-shell { };
        goose = p.callPackage ./pkgs/goose { };
      };
```

In checks:

```nix
      goose-roles-tests = devboxPkgs.runCommand "goose-roles-tests" {
        nativeBuildInputs = [ (devboxPkgs.python3.withPackages (ps: [ ps.pyyaml ])) devboxPkgs.gnugrep ];
        GOOSE_ROLES_AGENTS_DIR = "${self}/assets/opencode/agents";
        ROLES_OUT = (localPkgsFor devboxSystem).goose-roles;   # forces the build + validate
      } ''
        cd ${self}
        python3 pkgs/goose-roles/test_gen_goose_roles.py 2>&1 | tee "$TMPDIR/gr.txt"
        grep -q '^OK' "$TMPDIR/gr.txt" || { echo "GATE FAILURE: goose-roles suite did not pass." >&2; exit 1; }
        grep -q '^Ran N tests' "$TMPDIR/gr.txt" || { echo "GATE FAILURE: expected N tests." >&2; exit 1; }
        grep -q 'skipped' "$TMPDIR/gr.txt" && { echo "GATE FAILURE: a test was skipped." >&2; exit 1; }
        touch $out
      '';
```

Pin `N`.

**Step 6: Run**
`nix build --no-link .#checks.aarch64-linux.goose-roles-tests`, then
`nix build --no-link --print-out-paths .#goose-roles`. Read
`roles/code-reviewer.yaml` and `roles/implementer.yaml` and check them against
the design.

**Step 7: Commit.** `git add pkgs/goose-roles flake.nix && git commit -m "[NO-JIRA] goose-roles: generate goose role recipes from the opencode agents"`

### Task B5: Deploy module (cloudbox only)

**Files:**
- Create `users/dev/goose-roles.nix`
- Modify `users/dev/home.nix` imports (`:6-23`)

**Step 1:**

```nix
# goose subagent roles (cloudbox): one DIRECTORY symlink, never per-file -- goose
# reads recipe files with O_NOFOLLOW and silently skips symlinked ones.
# Consumed via ~/.config/goose/config.yaml (hand-managed):
#   GOOSE_SUBAGENT_ROLES_DIR: /home/dev/.config/goose/subagent-roles/roles
#   GOOSE_SUBAGENT_DEFAULT_RECIPE: /home/dev/.config/goose/subagent-roles/unscoped.yaml
# Requires goose >= patched-1.54.0.9. Design: docs/plans/2026-10-20-goose-subagent-roles-design.md
{ lib, localPkgs, isCloudbox, ... }:

lib.mkIf isCloudbox {
  home.file.".config/goose/subagent-roles".source = localPkgs.goose-roles;
}
```

Add `./goose-roles.nix` to `home.nix` imports.

**Step 2: Verify** that it is a single directory link:

```bash
ap=$(nix build --no-link --print-out-paths .#homeConfigurations.cloudbox.activationPackage)
readlink "$ap/home-files/.config/goose/subagent-roles"   # -> /nix/store/...-goose-roles
test -L "$ap/home-files/.config/goose/subagent-roles/roles/oracle.yaml" && echo BAD-per-file || echo ok
```

**Step 3: Commit.** `git commit -am "[NO-JIRA] goose-roles: deploy the role recipes to cloudbox as one directory"`.
Add the new file first.

### Task B6: Bump `pkgs/goose` to `patched-1.54.0.9`. Blocked on A6.

**Files:** Modify `pkgs/goose/default.nix`.

1. Get the hashes:
   ```bash
   curl -sL https://github.com/johnnymo87/goose/releases/download/patched-1.54.0.9/SHA256SUMS
   nix hash convert --hash-algo sha256 --to sri <hex for each goose-*-unknown-linux-gnu.tar.gz>
   ```
2. Set `version = "1.54.0-patched.9"`, `tag = "patched-1.54.0.9"` and both
   hashes.
3. Add patch 15 to THE PATCHES:
   ```
   #  15. Subagent policy (inert unless set): GOOSE_SUBAGENT_ROLES_DIR is scanned
   #      first so repo files cannot shadow a role; a delegated recipe's declared
   #      extensions replace the parent's (port of upstream #12938, not in 1.55);
   #      GOOSE_SUBAGENT_DEFAULT_RECIPE scopes delegates that declare none (ad-hoc,
   #      agent .md) and fails closed; with it set, a subagent extension that fails
   #      to start fails the delegate. Used by users/dev/goose-roles.nix.
   ```
4. Add a history line:
   `# patched-1.54.0.9 (<date>) adds patch 15 (johnnymo87/goose#N); no schema change.`
5. Run `nix build --no-link .#goose`. Its installCheck runs `goose --version`.
   Also run `nix build --no-link .#checks.aarch64-linux.goose-roles-tests`,
   since validate now uses `.9`.
6. Commit: `[NO-JIRA] goose: patched-1.54.0.9 (subagent policy)`.

### Task B7: PR

Load `shepherding-pull-requests` and follow it: pre-PR checks (including
`nix flake check --keep-going`), adversarial review of the diff, the PR, and the
monitoring loop. The PR description must state that nothing is enabled until the
Part C `config.yaml` edits.

---

## Part C: Deploy and live acceptance (with the user, after B7 merges)

Order matters. Turning on summon before `.9` and the roles are live would expose
unscoped delegation.

1. **Pull and rebuild** from the main workstation checkout (`rebuilding`
   skill), in a quiet window:
   ```bash
   cd ~/projects/workstation && git pull
   python3 -c "import sqlite3,os,datetime;s=os.path.expanduser('~/.local/share/goose/sessions/sessions.db');sqlite3.connect(s).backup(sqlite3.connect(s+'.bak-'+datetime.date.today().isoformat()))"
   sudo nixos-rebuild switch --flake .#cloudbox
   nix run home-manager -- switch --flake .#cloudbox
   ```
2. **Check the deploy:**
   `readlink ~/.config/goose/subagent-roles` (store dir) and
   `goose --version` (`1.54.0`; the store path contains `patched.9`).
3. **Edit `~/.config/goose/config.yaml`.** First copy it to
   `config.yaml.bak-<date>`. Then:
   - set `extensions.summon.enabled: true`
   - add `GOOSE_SUBAGENT_ROLES_DIR: /home/dev/.config/goose/subagent-roles/roles`
   - add `GOOSE_SUBAGENT_DEFAULT_RECIPE: /home/dev/.config/goose/subagent-roles/unscoped.yaml`

   Add a dated paragraph to `config.yaml.README.md` explaining why summon is now
   on, what the two keys do, and that pigeon and the lanes are unaffected.
4. **Restart:** `sudo systemctl restart goose-serve`, then
   `systemctl --user restart honkd`.
5. **Run the acceptance checks** in a fresh `honk chat --new`, in a throwaway
   worktree of some repo. Record results in the bead.
   - [ ] `load` (no args) lists the five roles. This proves the directory link
         avoids the O_NOFOLLOW skip.
   - [ ] "Delegate to code-reviewer: run `git diff --stat`, then `git stash`,
         then `git co -- .`, then `git checkout-index -a -f`, then try to write a
         file with your write tool. Report each result." Expected: the diff works,
         each git mutation shows `ro-shell: refused`, and no write tool exists.
         The worktree is unchanged (check with `git stash list` and
         `git status`).
   - [ ] An ad-hoc delegate ("delegate, without a source: run `git stash`")
         is refused, so it got the read-only set.
   - [ ] Add a repo-local `.claude/agents/cr.md` with `name: code-reviewer`
         and delegate to `code-reviewer`. The global role runs (read-only note
         present, ro-shell present).
   - [ ] Delegate to implementer to create and commit a file in the throwaway
         worktree. It succeeds.
   - [ ] Temporarily point `GOOSE_SUBAGENT_DEFAULT_RECIPE` at a copy of
         unscoped.yaml whose ro-shell `cmd` is `/nonexistent`. An ad-hoc
         delegate then fails visibly. Restore the setting afterwards.
   - [ ] cfp events show the roles' model:
         `tail -n 200 /var/lib/claude-failover-proxy/events.jsonl | grep claude-opus-5-5`
         during a delegate.
   - [ ] A pigeon-launched goose session still has no `delegate` tool.
6. **Close the bead** with the results. File follow-ups.

## Follow-up beads (create at the end)

- goose fork upgrade to ≥1.55: re-port patch 15 onto upstream's
  `resolve_subagent_config`, add parent hooks as a second layer, and check that
  honk surfaces forwarded subagent approvals.
- astra/fable twins plus astra-probe failover for goose roles.
- devbox/macOS goose roles.
- librarian and explore roles. goose has no webfetch; decide on a research
  extension.
- A Vertex Sonnet for the sonnet-tier roles once one serves through cfp.
- Upstream proposal: role-scoped delegation policy (trusted role identity, a
  ceiling on capabilities).
- `honk-9qf.15.3`: subagent progress rendering (exists).
