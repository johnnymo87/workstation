import type { Plugin } from "@opencode-ai/plugin"

const plugin: Plugin = async (ctx) => ({
  "experimental.session.compacting": async (input, output) => {
    output.context.push(`
## Compaction Context Preservation

When summarizing this conversation for continuation, preserve these categories:

### 1. User Requests
Capture original user requests verbatim. Include exact wording to maintain intent.

### 2. Final Goal
What is the user ultimately trying to achieve? State clearly and concisely.

### 3. Work Completed
- Files created or modified (with paths)
- Features implemented
- Commands run and their outcomes
- Tests written or run
- Commits made

### 4. Remaining Tasks
Work items not yet completed. Be specific about what's left.

### 5. Active Working Context
- Key files currently in focus
- Code patterns being followed
- Important references (documentation, examples, similar code)
- Technical decisions made during this session

### 6. Constraints
User-specified constraints verbatim. These are critical for maintaining alignment.
`)
  },
})

export default plugin
