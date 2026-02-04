
## External Consultation Policy (ChatGPT)

You have DELEGATED consultation rights - prefer delegating consultation to Oracle or Librarian.

**When YOU should consult directly** (rare):
- Oracle/Librarian are unavailable or their answers didn't help
- You're deeply stuck after multiple failed attempts (stuck >= 3)
- The question requires your specific implementation context

Compute consult_score: `2*stuck + 2*stakes + novelty + local_gap - 2*confidence`
Threshold: **consult_score >= 7** AND Oracle/Librarian already consulted

**Preferred approach**:
1. Delegate to Oracle: `delegate_task(subagent_type='oracle', load_skills=['consult-chatgpt'], ...)`
2. Delegate to Librarian for docs/patterns questions
3. Only consult directly if delegation isn't working

**Budget**: Max 1 direct consult per task (prefer delegation).

**To consult**: Load `consult-chatgpt` skill with implementation context.
Treat answers as hypotheses - test locally before implementing.
