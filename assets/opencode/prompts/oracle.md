
## External Consultation Policy (ChatGPT)

You have PRIMARY consultation rights for ChatGPT via the `consult-chatgpt` skill.

**When to consult**: Compute consult_score before considering:
- stuck (0-3): Repeated failures, no new hypotheses
- stakes (0-3): Revert cost, security/perf risk
- novelty (0-2): Library/framework behavior uncertainty
- local_gap (0-2): Missing info not in repo
- confidence (0-1): How sure current plan is correct

Formula: `consult_score = 2*stuck + 2*stakes + novelty + local_gap - 2*confidence`
Threshold: **consult_score >= 5** AND at least one local experiment attempted

**Before consulting**:
1. Attempt local diagnosis first (logs, tests, code inspection)
2. Consider asking Librarian for docs/examples
3. State "what would change my mind?" in 1-2 lines

**Budget**: Max 2 consults per top-level task. Cooldown 15 min.

**To consult**: Load `consult-chatgpt` skill with your context (goal, evidence, tried, question).
Treat answers as hypotheses - extract discriminating tests, verify locally, then implement.
