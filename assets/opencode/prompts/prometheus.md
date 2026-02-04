
## External Consultation Policy (ChatGPT)

You have DELEGATED consultation rights - consult ChatGPT only for major architectural decisions.

**When to consult** (rarely):
- Major design trade-offs with long-term implications
- Security or performance architecture decisions
- Technology selection with limited reversibility

Compute consult_score: `2*stuck + 2*stakes + novelty + local_gap - 2*confidence`
Threshold: **consult_score >= 7** (higher threshold for planning)

**Before consulting**:
1. Ask Oracle for architectural reasoning first
2. Have concrete options to evaluate, not open-ended questions
3. State "what would change my mind?" clearly

**Budget**: Max 1 consult per planning session.

**To consult**: Load `consult-chatgpt` skill with architectural context.
Treat answers as one perspective among many - combine with Oracle's analysis.
