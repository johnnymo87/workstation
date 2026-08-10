# Agent subprocess scoping — moving bash-tool commands out of the serve cgroup

Bead: `workstation-yt0p` (P1). Unblocks `workstation-8rou`.
Predecessor: `workstation-mqp3` (`pkgs/bazel-scope`), which fixed this for one binary.

## The defect

opencode's bash tool spawns each command as a **direct child of `opencode serve`**.
Measured, not inferred — from inside a bash tool call:

```
$ cat /proc/self/cgroup
0::/system.slice/system-opencode\x2dserve.slice/opencode-serve@4099.service
$ ps -o args= -p $PPID
/home/dev/.nix-profile/bin/opencode serve --port 4099 ...
```

So every command an agent runs is charged to that serve's cgroup:

```
$ systemctl show opencode-serve@4099.service -p LoadState -p OOMPolicy -p MemoryMax -p Restart
LoadState=loaded
OOMPolicy=stop
MemoryMax=15032385536      # 14.0 GiB
Restart=always
```

`OOMPolicy=stop` means **any** OOM anywhere in that cgroup takes down the serve and
every agent session on it.

`bazel` did this until `mqp3` shimmed it. `vitest` now does it: two kills of
`opencode-serve@4097` on 2026-08-09, anon 2.51 G → 13.29 G in 33 s, page cache
evicted, swap saturated. Raising the cap was rejected in `h1y6` and is not
re-litigated here: at ~10 G/33 s a 16 G cap buys about four seconds.

> **Read the unit as a SYSTEM unit.** `systemctl --user show opencode-serve@4099`
> returns `LoadState=not-found` and then happily prints `MemoryMax=infinity`,
> `OOMPolicy=`, `Restart=no` — all defaults for a unit that does not exist. That
> false reading was taken once while writing this spec. Always print `LoadState`
> in the same command as the property you are trusting.

## Why the obvious fix does not work

Option (a) from the bead was "shim `vitest` the way we shimmed `bazel`". **It has no
reachable target**, for two independently fatal reasons:

1. `vitest` is not on `PATH` at all. The real chain is
   `npm test` → `npm run --workspaces test` → 3 workspaces → `vitest run` each →
   each spawns a worker pool sized to `nproc` (16 here). That is the ramp.
2. Even if a `vitest` shim existed, it could never win. npm **prepends**
   `node_modules/.bin` ahead of the inherited PATH. Verified with a fixture
   holding a shim first in PATH and a `node_modules/.bin/vitest`:

   ```
   $ PATH="$d/fake:$PATH" npm run --silent test
   WINNER=node_modules_bin
   ```

Shimming the *entry* binaries (`npm`, `npx`, `pnpm`) would catch this case, but the
population says that is an endless list. Of 130,091 distinct agent bash commands in
session history, the memory-capable first tokens are: bazel 5309 (shimmed), python3
2415, python 1203, npm 1139, npx 1032, bun 824, nix 669, uv 408, node 283, docker
223, pnpm 87, pytest 15, tsc 11, jest 7, make 7, tsx 7, yarn 4, gradle 3, go 1,
cargo 1 — plus an unbounded tail of `./run-tests.sh` that no first-token list can
name. **The killers arrive via launchers whose first token does not name the hog.**

## The fix

A single opencode plugin rewrites the bash tool's command to run inside a transient
systemd scope, outside the serve's cgroup.

```
XDG_RUNTIME_DIR=/run/user/$(id -u) exec systemd-run --user --scope --collect -q \
  --unit=oc-agent-<nonce> \
  -p MemoryMax=10G -p MemorySwapMax=2G -p OOMPolicy=continue \
  --slice=<agentSliceName> \
  -- bash -c '<escaped original>'
```

`--scope` execs the payload **in place** — no intermediary process — so the
process-tree shape, stdio, signal delivery, cancellation and exit codes are
unchanged from today by construction. Proof it moves the process, both halves
measured:

| | cgroup |
|---|---|
| unwrapped (today) | `/system.slice/system-opencode\x2dserve.slice/opencode-serve@4099.service` |
| wrapped | `/user.slice/user-1000.slice/user@1000.service/<slice>/run-*.scope` |

### Wrap everything, no binary selector

A selector's wrong guess is **fail-open into the serve cgroup**, which is exactly the
bug — and per the population above the tail is not merely long but unlabelable. The
two arguments for a selector both fail on measurement:

- *Cost*: `systemd-run --user --scope` measured at **9.0 ms** vs 0.11 ms bare (30
  iterations). Against an LLM round-trip this is noise, even × 130k.
- *Risk*: escaping correctness is binary, not probabilistic. A uniform path is
  exercised by every command and breaks loudly on day one; a gated path rots.

### Escaping: one layer, because the second one can be turned off

This is the part that looks solved and is not. `systemd-run` passes the command
as an argv element that **systemd expands**, so `$` is mangled before bash ever
sees it:

```
$ systemd-run --user --scope -q -- bash -c 'echo "pid=$$ h=${HOME##*/}"'
Invalid environment variable name evaluates to an empty string: HOME##*/
pid=$ h=
```

The first working version escaped this by doubling every `$` (systemd un-escapes
it) on top of a POSIX single-quote wrap. That passed a hostile corpus, but it
made correctness depend on a second, subtler invariant and inflated the command
against the 128 KiB `MAX_ARG_STRLEN` ceiling.

`--expand-environment=no` removes the problem instead of testing it:

```
$ systemd-run --user --scope -q --expand-environment=no -- \
    bash -c 'echo "pid=$$ h=${HOME##*/} awk=$(echo ok)"'
pid=2387438 h=dev awk=ok          # identical to running it unwrapped
```

So the payload reaches bash byte-for-byte and **single-quote wrapping is the
only invariant**. The corpus (heredocs, nested quotes, newlines, backslashes,
unicode, command substitution, backticks, ANSI-C quoting, `awk '{print $2}'`, a
60 KB payload, exit codes) is verified against an unwrapped control.

> **The same flag was missing from `pkgs/bazel-scope`, where it is a live bug**,
> found by review of this change rather than by symptom:
> `systemd-run --user --scope -q -- printf '%s\n' 'both=$$ and ${FOO}'`
> prints `both=$ and `. Any bazel flag or target pattern containing `$$` or
> `${...}` has been silently mangled since that shim shipped. Fixed here, with a
> shim-test assertion so it cannot regress.

### Permission-guarded commands are NOT wrapped

The one place where wrapping is actively unsafe, and it has nothing to do with
memory. opencode evaluates bash permissions **inside** the tool's execute — i.e.
*after* `tool.execute.before` has rewritten the command. In the shipped binary
the hook fires and then `r.execute(g,c)` runs, and `ShellTool.ask` tree-sitter
parses `r.command` to derive the patterns it matches against.

So a wrapped command is parsed as `systemd-run ...`, and a rule like
`"git reset*": deny` can never match it again — while the `"*": allow` that
accompanies it matches everything. Five shipped agents depend on exactly those
rules, and AGENTS.md calls them "structural enforcement" precisely because a
review subagent once destroyed a peer session's uncommitted data.

Every deny pattern in the repo is a `git` subcommand, so any command mentioning
`git` runs unwrapped. Matching is anywhere in the command, not just the first
token, because the permission parser sees every command in a compound —
`echo hi && git stash` must not be launderable into an allow. Over-skipping is
the safe direction: it degrades to exactly today's behaviour, and across 130,091
historical commands `git` (47,754 of them) has never been implicated in a kill.
A unit test asserts the skip list covers every binary the repo actually denies,
so adding `"rm -rf*": deny` to an agent fails the build instead of silently
opening the hole.

### The scope MUST have an explicit non-PID-derived unit name

`systemd-run`'s auto name is `run-p<PID>-i<id>.scope`. Because `--scope` **execs the
payload in place** and `bash -c` exec-optimizes a final simple command, a nested
`systemd-run` (i.e. the bazel shim, running inside an agent scope) can inherit the
PID that named the outer scope and collide:

```
# outer auto-named, inner is the last simple command  -> the bazel case
Failed to start transient scope unit: Unit run-p2048880-i442317018.scope
  was already loaded or has a fragment file.

# identical, but outer uses --unit=oc-agent-<nonce>
0::/user.slice/.../bazel.slice/run-p2048893-i442317031.scope
```

Without the explicit name, **bazel-scope silently takes its degrade path** and loses
both its 10 G budget and its `bazel.slice` placement. This also falsifies a comment
shipped in `pkgs/bazel-scope/default.nix` ("No `--unit=`; the auto `run-pNNN.scope`
name is unique by construction") — true standalone, false under nesting. That comment
is corrected as part of this change.

### Explicit properties, because the defaults are wrong

- `-p OOMPolicy=continue` — measured on systemd 258.7, a scope's default is **`stop`**,
  not the folklore `continue`:
  `systemd-run --user --scope -q -- ... systemctl --user show <scope> -p OOMPolicy`
  → `OOMPolicy=stop`.
- `-p MemoryMax` is mandatory. Node and the JVM are container-aware and size
  themselves against the host's 62 G if the scope is uncapped.
- `--collect`, or every OOM-killed command leaves a failed scope loaded forever.
- `XDG_RUNTIME_DIR` **must be injected**: the bash-tool environment does not have it
  (`XDG_RUNTIME_DIR=[ABSENT]`, measured). Omit it and `systemd-run` fails with
  "Failed to connect to user scope bus" — i.e. 100 % of commands take the degrade
  path, silently.

### Degrade path: fail-open, loud

If scope creation is unavailable (user manager down, `/run/user/$UID` full — a
failure this repo has hit), the command still runs, unwrapped, and the plugin logs.
Refusing would brick every agent on the host to avoid a *risk* of one serve death
that `serve-canary` already backstops.

The fallback is decided **in the plugin, never in shell**. A shell
`systemd-run ... || bash -c ...` cannot distinguish "systemd-run failed to start"
from "the payload exited non-zero", so a failing payload would run twice — an
unacceptable hazard for a command like `psql -c 'DELETE ...'`.

The hook is wrapped in try/catch and returns the command unmodified on any internal
error: a plugin bug must never take down every tool call in the serve.

## Budget

Host is 62 G / 16 CPU. Per-command `MemoryMax=10G` matches the bazel per-invocation
budget and still kills the vitest ramp (which wanted ≥13.29 G) well before it can
reach a serve. Scopes are parented to a declared slice with an aggregate cap so N
concurrent commands cannot sum to the host, mirroring `bazel.slice`.

## Non-goals

- Not lowering the serve `MemoryMax` — that is `workstation-8rou`, unblocked by this.
- Not the aggregate serve-slice cap — that is `workstation-le0a`.
- In-process tool work (read/grep/LSP/MCP) stays in the serve cgroup by construction;
  the serve's own `MemoryMax` still guards it.
- `bazel-scope` is kept. A generic per-command scope cannot replace it: the bazel
  server JVM outlives the command that started it and needs a durable, named home
  rather than an ephemeral per-command scope.

## Verification

1. Unit tests over the escaping and command construction (hostile payload corpus,
   degrade path, non-bash tools untouched), run by `nix flake check`.
2. A generation check asserting the plugin's `--slice=` names a slice that ships,
   mirroring the existing bazel one — a mismatch would make systemd-run create an
   uncapped transient slice and the aggregate cap would silently vanish.
3. Post-deploy, on the box: a wrapped command reports a cgroup under the agent slice;
   a memory hog is killed at the scope cap with the serve surviving; bazel still
   lands in `bazel.slice` (the nesting case).
