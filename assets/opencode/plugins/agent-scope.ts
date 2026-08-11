import type { Plugin } from "@opencode-ai/plugin"
import { execFile } from "node:child_process"
import { promisify } from "node:util"

const execFileAsync = promisify(execFile)

/**
 * agent-scope: run every bash-tool command inside its own systemd scope, so a
 * runaway subprocess can no longer OOM-kill the opencode serve it was spawned
 * from.
 *
 * THE DEFECT (bead workstation-yt0p). opencode's bash tool spawns each command
 * as a DIRECT CHILD of `opencode serve`, so the command is charged to that
 * serve's cgroup:
 *
 *   $ cat /proc/self/cgroup                       # from inside a bash tool call
 *   0::/system.slice/system-opencode\x2dserve.slice/opencode-serve@4099.service
 *
 * That unit is MemoryMax=14G and OOMPolicy=stop, so ANY OOM anywhere in the
 * cgroup restarts the serve and destroys every agent session on it. bazel did
 * this until pkgs/bazel-scope shimmed it; vitest then did it twice on
 * 2026-08-09 -- the slot's anon went 1.61G -> 13.00G in 48 seconds while its
 * page cache was reclaimed out from under it (9.10G -> 0.39G), and it was dead
 * ~30s later.
 *
 * Those figures were CORRECTED on 2026-08-11 (bead workstation-h1y6). This
 * comment previously said "2.51G -> 13.29G in 33 seconds", which came from a
 * positional read across sampler schema versions rather than a read by column
 * name; 13.29G is the known-bogus output of that mistake and the spine document
 * had already recorded it as such. A peer trying to reproduce the ramp is what
 * surfaced it. The phenomenon is real -- re-derived by header name from
 * samples-v3.tsv -- but do not quote the old numbers, and note the accompanying
 * "swap saturated" claim was simply false: swap never moved.
 *
 * WHY NOT MORE PATH SHIMS. `vitest` is not on PATH -- the chain is `npm test`
 * -> `npm run --workspaces test` -> N x `vitest run`, each spawning an
 * nproc-sized worker pool. And a PATH shim could not win anyway, because npm
 * PREPENDS node_modules/.bin ahead of the inherited PATH (measured with a
 * fixture: node_modules/.bin won over a shim placed first in PATH). Shimming
 * the launchers instead (npm/npx/pnpm/...) is an endless list: across 130,091
 * distinct agent commands the memory-capable tail runs from bazel and python3
 * down to `./run-tests.sh`, which no first-token list can name. The killers
 * arrive via launchers whose first token does not name the hog.
 *
 * So this wraps EVERYTHING rather than a list of known-heavy binaries. A
 * selector's wrong guess is fail-open into the serve cgroup, which is precisely
 * the bug. The cost of wrapping is 9.0ms per command (measured, vs 0.11ms
 * bare) -- noise beside an LLM round-trip.
 *
 * See docs/plans/2026-08-10-agent-subprocess-scope.md for the full measurement
 * record.
 */

/** Per-command memory budget. Matches the bazel per-invocation budget. */
const SCOPE_MEMORY_MAX = "10G"
const SCOPE_SWAP_MAX = "2G"

/**
 * Slice the scopes are parented to. MUST name a slice unit that actually ships:
 * if it does not, systemd-run silently creates a transient slice of that name
 * with NO limits, the aggregate cap vanishes, and nothing goes red until the
 * host OOMs. users/dev/home.cloudbox.nix is the single source of truth and
 * flake.nix asserts the two agree -- same arrangement as bazel.slice.
 */
const SLICE_NAME = "oc-agent"

/** Health-probe cache. Healthy is cached longer than unhealthy so that recovery
 *  is picked up quickly without probing on every single command. */
const HEALTHY_TTL_MS = 60_000
const UNHEALTHY_TTL_MS = 10_000

/**
 * Quote a command so the outer shell passes it through untouched.
 *
 * ONE layer, deliberately. opencode runs our returned string via `bash -c`, so
 * the payload is wrapped in POSIX single quotes, which are inert for everything
 * except `'` itself.
 *
 * There USED to be a second layer here, and killing it is the single best
 * simplification in this change. systemd expands the command it is handed, so
 * unescaped `$$` collapses to `$` and a strip-suffix expansion errors outright:
 *
 *   $ systemd-run --user --scope -q -- bash -c 'echo "pid=$$ h=<strip-expr>"'
 *   Invalid environment variable name evaluates to an empty string: ...
 *   pid=$ h=
 *
 * The fix was to double every `$` and let systemd un-escape it. That worked,
 * but it made correctness depend on a second, subtler invariant AND inflated
 * the command against the 128 KiB MAX_ARG_STRLEN ceiling. `--expand-environment=no`
 * (systemd 258.7, see buildWrapped) turns the expansion off entirely, so the
 * payload reaches bash byte-for-byte and only shell quoting remains.
 */
function quoteForShell(command: string): string {
  return "'" + command.replace(/'/g, "'\\''") + "'"
}

/**
 * A unit name that is NOT derived from a PID.
 *
 * Load-bearing, and the least obvious requirement here. systemd-run's automatic
 * name is `run-p<PID>-i<id>.scope`, and because `--scope` execs the payload IN
 * PLACE -- and `bash -c` exec-optimizes a final simple command -- a NESTED
 * systemd-run (the bazel shim, now running inside an agent scope) can inherit
 * the very PID that named the outer scope:
 *
 *   Failed to start transient scope unit: Unit run-p2048880-i442317018.scope
 *     was already loaded or has a fragment file.
 *
 * The inner shim then takes its degrade path and loses both its 10G budget and
 * its bazel.slice placement -- silently. Giving the outer scope an `oc-agent-`
 * name makes the collision impossible by construction, since it can never
 * match `run-p*`. (This also falsifies a comment in pkgs/bazel-scope: the auto
 * name is unique standalone, but not under nesting.)
 */
let counter = 0
function scopeUnitName(): string {
  counter += 1
  const rand = Math.random().toString(36).slice(2, 10)
  return `oc-agent-${process.pid}-${counter}-${rand}`
}

/**
 * Commands that must NOT be wrapped, because wrapping would disable a security
 * control. This is the one place where wrapping is unsafe, and it is not about
 * memory at all.
 *
 * opencode evaluates bash permissions INSIDE the tool's execute, i.e. AFTER
 * `tool.execute.before` has already rewritten the command (verified in the
 * shipped binary: the hook fires, then `r.execute(g,c)`, and `ShellTool.ask`
 * tree-sitter-parses `r.command` to derive the patterns it matches). So a
 * wrapped command is parsed as `systemd-run ...` and a rule like
 * `"git reset*": deny` can never match again -- while the accompanying
 * `"*": allow` matches everything. Five shipped agents
 * (assets/opencode/agents/*.md) rely on exactly those deny rules, and AGENTS.md
 * calls them "structural enforcement" precisely because a subagent already
 * destroyed a peer session's uncommitted data once.
 *
 * So: any command mentioning a permission-guarded binary runs unwrapped. The
 * cost is that such commands keep today's memory behaviour; the benefit is the
 * safety net keeps working. That trade is one-sided -- every shipped deny rule
 * is a `git` subcommand, and across 130,091 historical agent commands `git`
 * (47,754 of them) has never been implicated in a serve kill.
 *
 * Matched anywhere in the command, not just at the front, because the permission
 * parser sees every command in a compound: `echo hi && git stash` must not be
 * launderable into an allow by wrapping it. Over-skipping is the safe direction
 * -- it degrades to exactly today's behaviour.
 *
 * The list is asserted against the repo's actual deny rules by a unit test, so
 * adding a deny rule for a new binary fails the build rather than silently
 * opening this hole.
 */
const PERMISSION_GUARDED = ["git"]

function isPermissionGuarded(command: string): boolean {
  return PERMISSION_GUARDED.some((bin) =>
    new RegExp(String.raw`(^|[\s;&|(){}\`])` + bin + String.raw`(\s|$)`).test(command),
  )
}

/**
 * Can we create a scope at all?
 *
 * Needed because the fallback CANNOT live in the shell. A shell-level
 * `systemd-run ... || bash -c ...` cannot distinguish "systemd-run failed to
 * start" from "the payload exited non-zero", so a failing command would run
 * TWICE -- unacceptable for anything like `psql -c 'DELETE ...'`. Deciding in
 * the plugin keeps the emitted command a single unambiguous execution.
 *
 * Failure is real and has been hit here: a full /run/user/$UID surfaces as the
 * misleading "Failed to start transient scope unit: ... not found".
 */
let probeCache: { ok: boolean; at: number } | null = null
async function scopeAvailable(env: NodeJS.ProcessEnv, now: number): Promise<boolean> {
  const ttl = probeCache?.ok ? HEALTHY_TTL_MS : UNHEALTHY_TTL_MS
  if (probeCache && now - probeCache.at < ttl) return probeCache.ok
  let ok = false
  try {
    // ASYNC, and short. A synchronous probe would block the serve's event loop
    // -- and therefore every session on that serve -- for the whole timeout
    // whenever the user bus is WEDGED rather than fast-failing. That is not
    // hypothetical on this box; "alive but frozen" is a documented serve
    // failure mode with its own skill. 2s is far above the measured 9ms.
    await execFileAsync(
      "systemd-run",
      [
        "--user",
        "--scope",
        "--collect",
        "--quiet",
        `--unit=oc-agent-probe-${process.pid}-${Math.random().toString(36).slice(2, 8)}`,
        "--",
        "true",
      ],
      { env, timeout: 2_000 },
    )
    ok = true
  } catch {
    ok = false
  }
  probeCache = { ok, at: now }
  return ok
}

/**
 * XDG_RUNTIME_DIR is ABSENT from the bash-tool environment (measured). Without
 * it systemd-run cannot reach the user bus at all -- "Failed to connect to user
 * scope bus" -- which would put 100% of commands on the degrade path, silently.
 * It is injected into both the probe and the emitted command.
 */
function runtimeDir(uid: number): string {
  return `/run/user/${uid}`
}

function buildWrapped(command: string, uid: number): string {
  return (
    `XDG_RUNTIME_DIR=${runtimeDir(uid)} exec systemd-run --user --scope --collect --quiet` +
    ` --unit=${scopeUnitName()}` +
    // -p MemoryMax: MANDATORY. node and the JVM are container-aware and size
    // themselves against the host's 62G if the scope is uncapped.
    ` -p MemoryMax=${SCOPE_MEMORY_MAX}` +
    ` -p MemorySwapMax=${SCOPE_SWAP_MAX}` +
    // -p OOMPolicy=continue: set EXPLICITLY. Measured on systemd 258.7, a scope
    // defaults to OOMPolicy=stop -- the "scopes default to continue" folklore is
    // wrong, and the default is exactly the behaviour this plugin exists to stop.
    ` -p OOMPolicy=continue` +
    // --expand-environment=no: systemd otherwise EXPANDS the command it is
    // handed, which silently corrupts the payload -- `$$` collapses to `$` and
    // `${VAR}` is substituted or errors. Turning it off is what lets the
    // payload through byte-for-byte with shell quoting as the only invariant.
    // (The same flag is missing from pkgs/bazel-scope, where it is a live bug:
    // `systemd-run -- printf '%s\n' 'both=$$ and ${FOO}'` prints `both=$ and `.)
    ` --expand-environment=no` +
    ` --slice=${SLICE_NAME}` +
    // --collect: GC the scope once it empties, or every OOM-killed command
    // leaves a failed scope loaded forever (130k commands of unit litter).
    ` -- bash -c ${quoteForShell(command)}`
  )
}

/**
 * The rewrite itself.
 *
 * Returns the command UNCHANGED (fail-open) when scoping is unavailable or
 * anything at all goes wrong. Refusing to run would brick every agent on the
 * host in order to avoid a RISK of one serve death that serve-canary already
 * backstops -- a far worse trade.
 */
async function rewriteCommand(deps: {
  command: unknown
  env: NodeJS.ProcessEnv
  uid: number | undefined
  now: number
  log?: (msg: string) => void
}): Promise<string | undefined> {
  const { command, env, uid, now } = deps
  if (typeof command !== "string" || command.length === 0) return undefined
  if (uid === undefined) return undefined

  // Never launder a permission-guarded command into an allow. See
  // PERMISSION_GUARDED above -- this is a safety check, not a memory one.
  if (isPermissionGuarded(command)) return undefined

  const probeEnv = { ...env, XDG_RUNTIME_DIR: env.XDG_RUNTIME_DIR ?? runtimeDir(uid) }
  if (!(await scopeAvailable(probeEnv, now))) {
    deps.log?.(
      "agent-scope: systemd scope creation unavailable; running command UNSCOPED " +
        "inside the serve cgroup (a memory runaway can now kill this serve)",
    )
    return undefined
  }
  return buildWrapped(command, uid)
}

const plugin: Plugin = async () => ({
  "tool.execute.before": async (input, output) => {
    // Only the bash tool spawns OS processes; everything else runs in-process
    // and is guarded by the serve's own MemoryMax.
    if (input.tool !== "bash") return
    try {
      const args = output.args as { command?: unknown } | undefined
      if (!args) return
      const rewritten = await rewriteCommand({
        command: args.command,
        env: process.env,
        uid: process.getuid ? process.getuid() : undefined,
        now: Date.now(),
        log: (m) => console.error(m),
      })
      if (rewritten !== undefined) args.command = rewritten
    } catch (err) {
      // A throw here would break EVERY tool call in the serve. Fail open: the
      // command runs unwrapped, exactly as it does today.
      console.error(`agent-scope: rewrite failed, running unscoped: ${err}`)
    }
  },
})

/**
 * v1 plugin shape. Load-bearing, not cosmetic -- see the long comment on the
 * same export in shell-env.ts. Under the legacy shape, the `internals` named
 * export below would trip `TypeError: Plugin export is not a function` and
 * silently disable this entire file, which would put every command back in the
 * serve cgroup with no signal.
 */
export default { id: "agent-scope", server: plugin }

/** Unit-test surface. Safe ONLY because of the v1 default export above. */
export const internals = {
  quoteForShell,
  buildWrapped,
  rewriteCommand,
  scopeUnitName,
  isPermissionGuarded,
  PERMISSION_GUARDED,
  resetProbeCache: () => {
    probeCache = null
  },
  SLICE_NAME,
  SCOPE_MEMORY_MAX,
}
