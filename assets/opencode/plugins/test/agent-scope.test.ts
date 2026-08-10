import { describe, it, expect, beforeEach, afterAll } from "vitest"
import { execFileSync } from "node:child_process"
import * as fs from "node:fs"
import * as os from "node:os"
import * as path from "node:path"
import pluginModule, { internals } from "../agent-scope"

const {
  quoteForShell,
  buildWrapped,
  rewriteCommand,
  scopeUnitName,
  isPermissionGuarded,
  PERMISSION_GUARDED,
  resetProbeCache,
  SLICE_NAME,
} = internals

// Resolve bash absolutely: the nix build sandbox has no /usr/bin/env, so a
// `#!/usr/bin/env bash` stub silently fails to exec and every wrapped run comes
// back empty (which is how this was found).
const bashPath = execFileSync("bash", ["-c", "command -v bash"], { encoding: "utf8" }).trim()

/**
 * A stub `systemd-run` that replays the one behaviour of the real thing that
 * can corrupt a payload: systemd EXPANDS the command it is handed, UNLESS
 * `--expand-environment=no` is passed. Measured on systemd 258.7:
 *
 *   $ systemd-run --user --scope -q -- printf '%s\n' 'both=$$ and ${FOO}'
 *   both=$ and
 *   $ systemd-run --user --scope -q --expand-environment=no -- ... same ...
 *   both=$$ and ${FOO}
 *
 * The stub honours the flag on purpose: that makes these tests fail if the flag
 * is ever dropped from buildWrapped, instead of the corruption only showing up
 * on the box. A stub is used because the nix build sandbox has no user bus.
 *
 * Note the modelled expansion is deliberately a SUPERSET of the real one (real
 * systemd-run leaves a bare `$NAME` in argv alone). Superset is the safe
 * direction for a guard: it cannot hide a bug, only over-report one.
 */
const stubDir = fs.mkdtempSync(path.join(os.tmpdir(), "agent-scope-test-"))
const stubPath = path.join(stubDir, "systemd-run")
fs.writeFileSync(
  stubPath,
  `#!${bashPath}
args=(); seen=0; expand=1
for a in "$@"; do
  if [[ $a == "--expand-environment=no" ]]; then expand=0; fi
  if [[ $a == "--" && $seen == 0 ]]; then seen=1; continue; fi
  [[ $seen == 1 ]] || continue
  if [[ $expand == 0 ]]; then args+=("$a"); continue; fi
  out=""; i=0
  while (( i < \${#a} )); do
    c=\${a:i:1}
    if [[ $c != '$' ]]; then out+=$c; ((i++)); continue; fi
    n=\${a:i+1:1}
    if [[ $n == '$' ]]; then out+='$'; ((i+=2)); continue; fi
    if [[ $n == '{' ]]; then
      j=$((i+2)); name=""
      while (( j < \${#a} )) && [[ \${a:j:1} != '}' ]]; do name+=\${a:j:1}; ((j++)); done
      if [[ $name =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then out+="\${!name}"; fi
      i=$((j+1)); continue
    fi
    if [[ $n =~ [A-Za-z_] ]]; then
      j=$((i+1)); name=""
      while (( j < \${#a} )) && [[ \${a:j:1} =~ [A-Za-z0-9_] ]]; do name+=\${a:j:1}; ((j++)); done
      out+="\${!name}"; i=$j; continue
    fi
    out+='$'; ((i++))
  done
  args+=("$out")
done
exec "\${args[@]}"
`,
  { mode: 0o755 },
)
afterAll(() => fs.rmSync(stubDir, { recursive: true, force: true }))

const stubEnv = { ...process.env, PATH: `${stubDir}:${process.env.PATH}` }

function runControl(payload: string) {
  try {
    return { out: execFileSync("bash", ["-c", payload], { encoding: "utf8" }), code: 0 }
  } catch (e: any) {
    return { out: e.stdout ?? "", code: e.status }
  }
}

function runWrapped(payload: string) {
  try {
    return {
      out: execFileSync("bash", ["-c", buildWrapped(payload, 1000)], {
        encoding: "utf8",
        env: stubEnv,
      }),
      code: 0,
    }
  } catch (e: any) {
    return { out: e.stdout ?? "", code: e.status }
  }
}

describe("quoteForShell", () => {
  it("escapes single quotes POSIX-style", () => {
    expect(quoteForShell("echo 'hi'")).toBe("'echo '\\''hi'\\'''")
  })

  it("passes $ through untouched, because expansion is disabled at the flag", () => {
    expect(quoteForShell("echo $$")).toBe("'echo $$'")
  })
})

describe("command construction", () => {
  const wrapped = buildWrapped("echo hi", 1000)

  it("injects XDG_RUNTIME_DIR, which the bash-tool env does not have", () => {
    // Measured: XDG_RUNTIME_DIR is ABSENT in the bash tool environment. Without
    // it systemd-run cannot reach the user bus and EVERY command silently
    // degrades to running inside the serve cgroup.
    expect(wrapped).toContain("XDG_RUNTIME_DIR=/run/user/1000")
  })

  it("disables systemd's environment expansion", () => {
    // Without this, `$$` collapses to `$` and `${VAR}` is substituted, silently
    // corrupting the payload. The stub above honours the flag, so the corpus
    // below fails too if it is dropped.
    expect(wrapped).toContain("--expand-environment=no")
  })

  it("caps memory, because node/JVM size themselves against the host otherwise", () => {
    expect(wrapped).toContain("-p MemoryMax=10G")
  })

  it("sets OOMPolicy=continue explicitly (a scope's measured default is stop)", () => {
    expect(wrapped).toContain("-p OOMPolicy=continue")
  })

  it("collects the scope so OOM-killed commands leave no unit litter", () => {
    expect(wrapped).toContain("--collect")
  })

  it("parents the scope to the declared slice", () => {
    expect(wrapped).toContain(`--slice=${SLICE_NAME}`)
  })

  it("uses a unit name that can never collide with a nested systemd-run", () => {
    // systemd-run's auto name is run-p<PID>-i<id>.scope. Because --scope execs
    // in place and `bash -c` exec-optimizes a final simple command, a nested
    // systemd-run (the bazel shim) can inherit the PID that named the outer
    // scope and fail with "was already loaded or has a fragment file" -- which
    // makes the shim silently lose its budget and its slice.
    const unit = /--unit=(\S+)/.exec(wrapped)?.[1] ?? ""
    expect(unit).toMatch(/^oc-agent-/)
    expect(unit.startsWith("run-p")).toBe(false)
  })

  it("generates distinct unit names for concurrent commands", () => {
    const names = new Set(Array.from({ length: 50 }, () => scopeUnitName()))
    expect(names.size).toBe(50)
  })
})

describe("payloads survive quoting byte-identically", () => {
  const cases: Record<string, string> = {
    "parameter expansion": 'echo "h=${HOME##*/}"',
    "command substitution": 'echo "n=$(echo 3)"',
    "pid variable": "echo $$ | wc -w",
    "single quotes": `echo 'it'"'"'s quoted'`,
    "nested quotes": `echo "outer 'inner' done"`,
    heredoc: "cat <<'EOF'\nline $$ ${nope} 'quoted'\nEOF",
    newlines: "echo a\necho b",
    backslashes: 'echo "back\\\\slash"',
    unicode: 'echo "café → ✅"',
    "globs and pipes": "echo abc | head -1",
    "awk positional": `echo "a b" | awk '{print $2}'`,
    "literal dollar": 'echo "\\$notavar"',
    "trailing lone dollar": 'echo "ends with $"',
    "ansi-c quoting": `printf '%s' $'a\\tb'`,
    backticks: "echo `echo nested`",
    "nested systemd-run text": `echo 'systemd-run --unit=x-$$ -- true'`,
  }

  for (const [name, payload] of Object.entries(cases)) {
    it(`preserves ${name}`, () => {
      const control = runControl(payload)
      const wrapped = runWrapped(payload)
      expect(wrapped.out).toBe(control.out)
      expect(wrapped.code).toBe(control.code)
    })
  }

  it("preserves a non-zero exit code", () => {
    expect(runWrapped("exit 7").code).toBe(7)
  })

  it("handles a large payload without truncation", () => {
    const payload = `echo "${"x".repeat(60_000)}" | wc -c`
    expect(runWrapped(payload).out).toBe(runControl(payload).out)
  })
})

describe("permission-guarded commands are never wrapped", () => {
  // Wrapping happens BEFORE opencode evaluates bash permissions, so a wrapped
  // command is parsed as `systemd-run ...` and a `"git reset*": deny` rule can
  // never match it again. These commands therefore run unwrapped.
  it.each([
    "git stash",
    "git reset --hard",
    "git clean -fd",
    "echo hi && git stash",
    "foo; git checkout main",
    "(git switch main)",
    "ls | grep x && git push",
  ])("skips %s", (cmd) => {
    expect(isPermissionGuarded(cmd)).toBe(true)
  })

  it.each(["npm test", "digital forensics", "legitimate", "echo gitlab", "./git-like.sh"])(
    "does not over-skip %s",
    (cmd) => {
      expect(isPermissionGuarded(cmd)).toBe(false)
    },
  )

  it("covers every binary the repo actually denies", () => {
    // If someone adds `"rm -rf*": deny` to an agent, wrapping would launder it
    // into the accompanying `"*": allow`. This fails the build instead.
    const agentsDir = path.resolve(__dirname, "../../agents")
    const denied = new Set<string>()
    for (const f of fs.readdirSync(agentsDir).filter((f) => f.endsWith(".md"))) {
      const body = fs.readFileSync(path.join(agentsDir, f), "utf8")
      for (const m of body.matchAll(/"([^"]+)"\s*:\s*deny/g)) {
        const first = m[1].trim().split(/\s+/)[0]
        if (first !== "*") denied.add(first)
      }
    }
    expect(denied.size).toBeGreaterThan(0) // non-vacuous
    for (const bin of denied) expect(PERMISSION_GUARDED).toContain(bin)
  })
})

describe("the happy path actually wraps", () => {
  // Without these, a mutant that makes scopeAvailable always false passes the
  // whole suite -- i.e. 100% silent degradation, which is the exact bug class
  // this plugin exists to remove.
  beforeEach(() => resetProbeCache())

  it("returns a systemd-run command when scoping is available", async () => {
    const got = await rewriteCommand({
      command: "echo hi",
      env: stubEnv,
      uid: 1000,
      now: Date.now(),
    })
    expect(got).toContain("systemd-run")
    expect(got).toContain(`--slice=${SLICE_NAME}`)
    expect(got).toContain("'echo hi'")
  })

  it("rewrites args.command through the real hook", async () => {
    const hooks = await (pluginModule.server as any)({} as any)
    const output = { args: { command: "echo hi" } }
    const saved = process.env.PATH
    process.env.PATH = `${stubDir}:${saved}`
    try {
      await hooks["tool.execute.before"]({ tool: "bash", sessionID: "s", callID: "c" }, output)
    } finally {
      process.env.PATH = saved
    }
    expect(output.args.command).toContain("systemd-run")
  })
})

describe("degrade path", () => {
  beforeEach(() => resetProbeCache())

  it("returns the command unchanged when scope creation is unavailable", async () => {
    const logs: string[] = []
    const got = await rewriteCommand({
      command: "echo hi",
      env: { PATH: "/nonexistent" },
      uid: 1000,
      now: Date.now(),
      log: (m) => logs.push(m),
    })
    expect(got).toBeUndefined()
    expect(logs.join(" ")).toContain("UNSCOPED")
  })

  it("is loud about degrading, because a silent degrade is the bug returning", async () => {
    const logs: string[] = []
    await rewriteCommand({
      command: "echo hi",
      env: { PATH: "/nonexistent" },
      uid: 1000,
      now: Date.now(),
      log: (m) => logs.push(m),
    })
    expect(logs).toHaveLength(1)
    expect(logs[0]).toContain("kill this serve")
  })

  it("does not rewrite when uid is unknown", async () => {
    expect(
      await rewriteCommand({ command: "echo hi", env: {}, uid: undefined, now: Date.now() }),
    ).toBeUndefined()
  })

  it("does not rewrite a non-string or empty command", async () => {
    expect(
      await rewriteCommand({ command: 42, env: {}, uid: 1000, now: Date.now() }),
    ).toBeUndefined()
    expect(
      await rewriteCommand({ command: "", env: {}, uid: 1000, now: Date.now() }),
    ).toBeUndefined()
  })
})

describe("plugin hook", () => {
  async function hookFor(tool: string, args: Record<string, unknown>) {
    const hooks = await (pluginModule.server as any)({} as any)
    const output = { args }
    await hooks["tool.execute.before"]({ tool, sessionID: "s", callID: "c" } as any, output as any)
    return output.args
  }

  it("leaves non-bash tools completely alone", async () => {
    const args = await hookFor("read", { filePath: "/etc/hostname" })
    expect(args).toEqual({ filePath: "/etc/hostname" })
  })

  it("never throws, so a bug here cannot break every tool call", async () => {
    await expect(hookFor("bash", {})).resolves.toBeDefined()
    await expect(hookFor("bash", { command: null })).resolves.toBeDefined()
  })
})

describe("plugin shape", () => {
  it("uses the v1 shape, which is what makes the internals export safe", () => {
    // Under the legacy shape the named export below trips
    // "TypeError: Plugin export is not a function" and silently disables the
    // whole file -- putting every command back in the serve cgroup with no
    // signal at all. See the same comment in shell-env.ts.
    expect(pluginModule.id).toBe("agent-scope")
    expect(typeof pluginModule.server).toBe("function")
  })
})
