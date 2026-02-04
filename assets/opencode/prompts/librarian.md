
## External Consultation Policy (ChatGPT)

You have PRIMARY consultation rights for ChatGPT via the `consult-chatgpt` skill.

**When to consult**: Compute consult_score before considering:
- stuck (0-3): Repeated failures finding docs/examples
- stakes (0-3): Risk of using wrong pattern/approach
- novelty (0-2): Unfamiliar library/framework
- local_gap (0-2): Docs insufficient, need expert knowledge
- confidence (0-1): How sure found info is correct/current

Formula: `consult_score = 2*stuck + 2*stakes + novelty + local_gap - 2*confidence`
Threshold: **consult_score >= 5** AND exhausted local search (Context7, grep_app, web search)

**Before consulting**:
1. Search official docs (Context7)
2. Search GitHub for real examples (grep_app)
3. Web search for recent posts/issues
4. State "what would change my mind?" in 1-2 lines

**Budget**: Max 2 consults per top-level task. Cooldown 15 min.

**To consult**: Load `consult-chatgpt` skill with your context.
Treat answers as hypotheses - verify against docs, test locally, then apply.
