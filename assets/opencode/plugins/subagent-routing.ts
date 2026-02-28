import type { Plugin } from "@opencode-ai/plugin"

const plugin: Plugin = async (ctx) => ({
  "experimental.chat.system.transform": async (_input, output) => {
    ;(output.system ||= []).push(`
<subagent-routing>
## Subagent Routing for Plan Execution

When executing implementation plans (subagent-driven-development), dispatch to these
named agents instead of generic "general-purpose" subagents:

| Superpowers template says | Dispatch to agent | Purpose |
|---------------------------|-------------------|---------|
| \`Task tool (general-purpose)\` for implementation | \`implementer\` | Implements a single plan task (TDD, self-review, commit) |
| \`Task tool (general-purpose)\` for spec review | \`spec-reviewer\` | Verifies implementation matches spec (read-only, skeptical) |
| \`Task tool (superpowers:code-reviewer)\` | \`code-reviewer\` | Code quality review (read-only) |

These agents run on a cost-efficient model for execution work. The orchestrator
(you) stays on the planning model for coordination and decision-making.

**How to dispatch:** Use the Task tool with \`subagent_type\` set to the agent name:
- \`subagent_type: "implementer"\` — for implementation tasks
- \`subagent_type: "spec-reviewer"\` — for spec compliance review
- \`subagent_type: "code-reviewer"\` — for code quality review
</subagent-routing>
`)
  },
})

export default plugin
