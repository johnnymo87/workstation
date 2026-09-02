# bd long-text input ergonomics: the fix already exists, we just weren't using it

**Date:** 2026-09-01
**Host:** cloudbox
**Scope:** research only. No pin changed, no bd upgrade, no writes to any live bd database.
**Filed upstream:** nothing — every facet of the hazard is already reported (see
[Existing upstream reports](#existing-upstream-reports)).

Placed in `docs/notes/` alongside `2026-05-18-bd-1.0-upgrade-study.md`, the existing
precedent for a bd-upstream study that is neither an incident investigation nor a
design/plan document.

## TL;DR

1. `bd` **already supports file and stdin input** for the description and design fields,
   and has since well before our pinned version. `--body-file <path>`, `--body-file -`,
   `--stdin`, `--design-file <path>`. Also `bd note --file/--stdin`, `bd comments add
   --file`, `bd close --reason-file`. We were not using them. That is the fix, and it
   costs nothing to adopt.
2. Our pin is **v1.1.0**; latest stable upstream is **v1.2.2**. The version gap is
   almost entirely cosmetic — v1.2.2 is deliberately *the v1.1.2 code re-released under a
   higher number* after v1.2.0/v1.2.1 were published by accident. Code delta v1.1.0 →
   v1.2.2 is two release-plumbing commits.
3. One genuine **data-safety** item does argue for eventually moving, but it is only fixed
   in the unreleased v1.3.0-rc.1, not in v1.2.2: `bd dolt push` / `bd sync` silently
   adopting a Dolt remote derived from `git remote get-url origin` (upstream #5068).
4. Our **auto-updater has been failing daily** since at least 2026-08-27, which is why the
   pin is stale. Unrelated to bd; it is a `nix-update` 1.16.0 eval failure.
5. Residual upstream gaps: `--notes`, `--append-notes`, and `--acceptance` still have **no**
   file/stdin variant, at our version or at upstream main. Notes/append-notes are already
   tracked upstream (#3102). Acceptance is not tracked by anything I found.

## The hazard, restated

An agent runs:

```
bd create --description="... keeps a merged worktree ONLY if <backtick>git status<backtick> is non-empty ..."
```

(backticks written out longhand above on purpose — see [Writing about this safely](#writing-about-this-safely)).

Bash performs command substitution *inside the double quotes*, before `bd` is exec'd. The
stored description reads "... ONLY if On branch main ... nothing to commit, working tree
clean is non-empty". A second substituted command that writes only to stderr collapses to
the empty string, silently deleting a clause. `bd` exits 0. Nothing looks wrong.

The property that makes this dangerous is not that bash expands backticks — that is
documented bash — it is that the corruption is **silent and permanent**, and that it
targets exactly the content people most want in an issue: shell commands, paths with
globs, code, log lines.

This is 90% ours to fix and 10% upstream's, and the 90% is a one-line change in how we
invoke bd.

## 1. Version and pin

| | Value |
|---|---|
| Installed | `bd version 1.1.0 (dev)`, `/nix/store/kmwf98pwpsdg9aawz1f9jbpz54p1nyjl-beads-1.1.0/bin/bd` |
| Pin | `pkgs/beads/default.nix` — `version = "1.1.0"`, `fetchFromGitHub { owner = "gastownhall"; repo = "beads"; rev = "v1.1.0"; }` |
| Pin last moved | `5fbab7a chore(deps): update beads to 1.1.0 (#183)` |
| Latest stable upstream | **v1.2.2** (2026-08-15) |
| Latest prerelease | v1.3.0-rc.1 (2026-08-31) |

### What is actually in the gap

Upstream's own release notes are unusually blunt about this:

- **v1.1.1 / v1.1.2** (2026-07-26) — release plumbing only. Changelog is literally
  `chore(release): bump version to 1.1.2` plus an MCP lock refresh.
- **v1.2.0 / v1.2.1** (2026-08-11) — *published by accident, untested, do not use*.
  Running the v1.2.1 binary even once migrates the local schema v53 → v65, after which
  every other bd release refuses to run with `schema version mismatch`. Upstream ships a
  recovery guide (`docs/RECOVERY-1.2.1.md`). We never ran these; our pin never moved.
- **v1.2.2** (2026-08-15) — recovery release. "It is the v1.1.2 code under a higher version
  number." The 1.2.x features (work leases, events journal, sync federation, HTTP API
  server, provenance events) are explicitly **not** in it. `go.mod` retracts v1.2.1,
  v1.2.0 and v1.1.1.
- **v1.3.0-rc.1** (2026-08-31) — the real 1.2.x work plus new material, still a prerelease.
  Carries actual schema change.

So: **v1.1.0 → v1.2.2 is materially a no-op upgrade** (two plumbing commits), and it is
also, per the release notes, the same code line — so no schema migration is implied.

### Security- / data-relevant items

All three below are fixed only in **v1.3.0-rc.1**, i.e. we are exposed at v1.1.0 and would
still be exposed at v1.2.2:

- **#5068 — `bd dolt push` / `bd sync` adopt a git-origin-derived Dolt remote without
  consent.** On a rig with no Dolt remote configured, both commands derived one from
  `git remote get-url origin`, added it, persisted `sync.remote` into
  `.beads/config.yaml`, committed that under the user's git identity, and uploaded the
  full issue history. No prompt, no opt-out. A public git origin therefore published the
  whole issue database. Now gated behind consent, fails closed non-interactively,
  `--yes` / `--no-adopt` / `BD_NO_REMOTE_ADOPT=1`. **This is the one item that argues for
  an upgrade,** and it is the reason to watch v1.3.0's final release rather than to rush
  to v1.2.2.
- **Settings plane leaked the KV plane.** `bd kv` keys and `bd remember` memories nested
  under them were listed *with their values* by both the CLI and an unauthenticated
  `GET /v0/beads/config`. Only reachable if `bd serve` is running.
- **bd-m00pb / #4839 — no-ID "last touched issue" fallback is now interactive-only.** A
  scripted `bd update $ID ...` with an accidentally empty `$ID` used to silently mutate
  whatever bead was touched last.

**Recommendation: do not upgrade as part of this work.** v1.2.2 buys nothing but the
version number. The decision worth a human is whether to wait for final v1.3.0 (which
carries a real schema migration across several live databases on this host) — that is a
deliberate, scheduled operation, not a side effect. See the
[migrating-beads-schema skill](../../assets/opencode/skills/migrating-beads-schema/SKILL.md).

### Why the pin is stale

`.github/workflows/update-packages.yml` is supposed to bump this daily. It has failed
every run since at least 2026-08-27 (run `33499816702` and five before it), in
`nix-update --flake beads`:

```
error:
       … while evaluating attribute 'filename'
         at .../nix-update-1.16.0/.../nix_update/eval.nix:118:3
```

This is a `nix-update` 1.16.0 evaluation problem, not a bd problem. Worth its own bead;
out of scope here.

## 2. Does file/stdin input already exist? Yes.

Citations are against our pinned tag **v1.1.0 (`7e7c8b995`)**, not upstream main, so they
describe the binary we are actually running.

### Description — three ways in

`cmd/bd/flags.go` (v1.1.0), `registerCommonIssueFlags`, shared by `bd create` and
`bd update`:

- `cmd/bd/flags.go:19` — `--body-file` "Read description from file (use - for stdin)"
- `cmd/bd/flags.go:20` — `--description-file`, a hidden alias for `--body-file`
- `cmd/bd/flags.go:22` — `--stdin`, "alias for `--body-file -`"
- `cmd/bd/flags.go:42` — `getDescriptionFlag` resolves the precedence and errors on
  conflicting sources
- `cmd/bd/flags.go:188` — `readBodyFile`; `-` means stdin, otherwise `os.Open` and read
  verbatim

`--description=-` / `--body=-` / `--message=-` also route to stdin.

### Design

- `cmd/bd/flags.go:29` — `--design-file` "Read design from file (use - for stdin)"
- `cmd/bd/flags.go:169` — `getDesignFlag`

### Notes / comments / close reason

- `bd note` — `cmd/bd/note.go:132-133`: `--stdin`, `--file`
- `bd comments add` — `cmd/bd/comments.go:213`: `-f, --file`
- `bd close` — `cmd/bd/close.go:299`: `--reason-file` (use `-` for stdin)

### The invocations to use

Verified empirically against a throwaway database in `/tmp/bdtest` (fresh `git init` +
`bd init bdt`; no live database was touched):

```bash
# Long prose in a file. Content is read with os.Open -> io.ReadAll: never re-evaluated.
bd create --title="quoting probe" --body-file=/tmp/desc.txt --type=task -p 2

# Or a quoted-delimiter heredoc straight into stdin.
bd create --title="stdin probe" --stdin --type=task -p 2 <<'PROSE_EOF'
Backticks and $(whoami) survive verbatim.
PROSE_EOF
```

Both round-tripped byte-exact, including backticks, `$(...)`, `rm -rf .worktrees/*/`, and
newlines:

```
'Keeps a merged worktree ONLY if `git status --porcelain` is non-empty.\nGlob check: rm -rf .worktrees/*/ and $(date) must survive verbatim.\n'
```

Note the difference in trailing-newline handling, which is deliberate upstream: file input
is passed through verbatim, stdin has trailing `\r?\n` trimmed.

Also useful: `--metadata @file.json` reads metadata JSON from a file.

### Two traps worth knowing

- **`bd create --file/-f` is NOT "one bead from a file".** It is a batch import that
  creates one issue per top-level markdown heading. Point a briefing document at it and
  you get six garbage beads, silently. The single-issue flag is `--body-file`. Reported
  upstream as **#4643** (open) — the complaint there is exactly that `-f` is the
  discoverable name and does the wrong thing.
- **The workaround we already use — `--description="$(cat file)"` — is safe**, because
  command substitution of a file's *content* does not re-evaluate that content. But it is
  strictly worse than `--body-file`: it still passes the whole payload through the shell's
  argv and through any agent-host bash parser. `--body-file` is the first-class path.

### Still no file input: notes, append-notes, acceptance

`registerCommonIssueFlags` at v1.1.0 (`cmd/bd/flags.go:31-34`) and at upstream main
registers `--acceptance`, `--notes`, `--append-notes` as plain strings only. Confirmed on
the installed binary: `bd create ... --notes-file=...` → `Error: unknown flag: --notes-file`.
For these three fields the shell-quoting hazard is unmitigated, and the `$(cat file)`
workaround remains the only option.

## 3. Editor path (context, not a solution)

`bd edit <id>` opens `$EDITOR` and covers all four long fields —
`cmd/bd/edit.go:54-62`: description (default), `--design`, `--notes`, `--acceptance`. It
errors out with "no editor found" when `$EDITOR`/`$VISUAL` are unset.

Useless to an agent, but it does show that the maintainers think of long-text input as a
first-class problem across *all four* fields — which makes the missing
`--notes-file`/`--acceptance-file` look like an oversight rather than a decision. bd's own
injected agent context already tells agents not to use `bd edit` for exactly this reason
("it opens $EDITOR (vim/nano) which blocks agents").

## Existing upstream reports

Everything about this hazard is already on file upstream. **No new issue was filed** — it
would have been a duplicate on all three axes.

| # | State | What it covers | Link |
|---|---|---|---|
| 5154 | open | *The exact hazard.* "backticks in double-quoted `-m` bodies command-substitute silently — arbitrary command execution". Reports ~600 lines of a session's prime output injected into a message that reported success and looked plausible; notes comments have no edit/delete so the corruption is permanent. Asks for write-time detection, arguing docs nudges alone rely on every agent remembering. | https://github.com/gastownhall/beads/issues/5154 |
| 3102 | open (since 2026-04-07) | *The residual gap.* `feat(update): add --notes-file and --append-notes-file`. Motivated by both shell-quoting brittleness and a Claude Code permission-prompt failure where a markdown-header heredoc makes the bash parser prompt despite an allowlist. | https://github.com/gastownhall/beads/issues/3102 |
| 4643 | open | *The discoverability trap.* `bd create --file/-f is a batch-import trap, not single-bead-from-file`. Cites bd v1.1.0 explicitly. | https://github.com/gastownhall/beads/issues/4643 |
| 6021 | open | Adjacent silent-data-loss: `bd update --notes ""` wipes the field at exit 0 with a success receipt. | https://github.com/gastownhall/beads/issues/6021 |
| 4541 | closed | `--notes` silently replaces the field; agent fleets lose audit history. | https://github.com/gastownhall/beads/issues/4541 |
| 5921 | open PR | `fix(create): say --file is one issue per ## heading` — docs fix for #4643. | https://github.com/gastownhall/beads/pull/5921 |

Search terms used against `gh search issues --repo gastownhall/beads --include-prs`:
`stdin`, `body-file`, `backtick`, `shell quoting`, `command substitution`,
`description corrupt`, `notes file`, `acceptance`, `acceptance criteria flag`,
`design-file`.

The only thing I could not find a report for is a **`--acceptance-file`** flag. If we want
it, the cheapest move is a comment on #3102 asking it to cover `--acceptance` too, rather
than a fourth near-duplicate issue. Not done here — flagging it as an option.

## Recommendations

1. **Adopt `--body-file` / `--stdin` in our agent guidance.** This is the whole fix for the
   reported hazard and needs no upstream change. Candidate: the
   [beads skill](../../assets/opencode/skills/beads/SKILL.md), whose only create example is
   `bd create "title" -d "Full context: ..."` (SKILL.md:77) — inline, and silent on file
   input. Deliberately not changed in this PR to keep it to research; worth a bead.
2. **Do not upgrade bd now.** v1.2.2 is v1.1.2 code; the gap is a version number.
3. **Watch for final v1.3.0** and schedule a deliberate migration for #5068 and the
   settings-plane leak. Several live databases on this host; treat as an operation.
4. **Fix the update-packages workflow** (`nix-update` 1.16.0 eval failure). Separate bead.
5. **Until upstream ships `--notes-file`**, treat `--notes`, `--append-notes` and
   `--acceptance` as the remaining sharp edges and use `"$(cat file)"` for them.

## Writing about this safely

Prose that merely *mentions* a dangerous command is not safe just because it is
documentation. A `bd note` whose text contained a backticked command *as an example of what
not to run* caused bash to run it. This document was written to a file with the `write`
tool, never inlined into a double-quoted shell argument, and the one place it needed to
show a backticked command inside a shell invocation spells the backticks out in words.
The repo-level and user-level `AGENTS.md` both carry this rule; it is repeated here because
this is the document most likely to be quoted into a shell.
