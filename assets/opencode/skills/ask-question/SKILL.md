---
name: ask-question
description: Draft a technical research question and send to ChatGPT for investigation
argument-hint: [draft]
allowed-tools: [Read, Glob, Grep, Bash]
---

Help me draft a technical research question about a problem I've encountered, then send it to ChatGPT for research.

**Arguments:** $ARGUMENTS

- If first word is `draft`: Only write the question file, skip sending to ChatGPT
- Otherwise: Write question, send to ChatGPT, read answer, and discuss

## Ethos

**You're briefing a researcher, not filing a ticket.** ChatGPT will do deep web research on our behalf -- sometimes reading through hundreds of pages to synthesize an answer. The quality of what comes back depends entirely on the honesty, clarity, and richness of what we send. Think of it as equipping someone who is thorough and capable but knows nothing about our specific situation.

**Be generous with context.** More relevant context means better research. Include the surrounding code, the config files, the dependency versions, the things you tried that didn't work and why. Don't over-optimize for brevity -- a researcher exploring dozens of sources on your behalf can absolutely make use of a detailed briefing. What would waste their time is *missing* context that forces them to guess, not *extra* context that helps them understand.

**Be honest about what you know.** Distinguish verified facts from hypotheses. If you haven't tested something, say so -- don't let it pass as established. ChatGPT can't help if it's reasoning from our wrong assumptions, and wrong assumptions are far more costly than admitted uncertainty.

**Show the problem, don't just describe it.** Code and exact error messages are worth more than prose summaries. Include version numbers -- they change behavior.

**State real constraints, not preferences.** "Must use Bazel" is a constraint that should shape the research. "We prefer Bazel" is context. Confusing them narrows the solution space unnecessarily.

**Scrub sensitive information.** No credentials, internal URLs, or company names.

## Process

1. **Understand the problem**
   - If a topic is provided, research it in the codebase
   - Look at recent errors, code changes, or discussions in our conversation
   - Identify the specific technical issue

2. **Gather context generously**
   - Check language/framework versions (package.json, build.gradle, pom.xml, MODULE.bazel, etc.)
   - Identify relevant dependencies and their versions
   - Pull in surrounding code, config files, build system details
   - Note what you've already tried and what happened

3. **Write the question**

   Write to `/tmp/` using pattern `research-{topic-slug}-question.md`.

   A good research question typically covers these areas (use judgment about which matter for your specific question):

   - **Title** -- a specific question, not "Problem with X"
   - **Keywords** -- help orient the researcher to the domain
   - **The situation** -- what you're trying to do and what's going wrong
   - **Environment** -- versions, platform, build system
   - **Code and config** -- the relevant pieces, with enough surrounding context to understand them
   - **Error or unexpected behavior** -- exact messages, not paraphrases
   - **What we know vs. what we're uncertain about** -- clearly separated, with how we verified the knowns and our confidence level on the unknowns
   - **Specific questions** -- what we actually need answered
   - **Constraints** -- hard limits on acceptable solutions

   Use "we" throughout -- collaborative tone with the user.

4. **Send to ChatGPT (unless draft mode)**

   If $ARGUMENTS starts with `draft`, skip this step -- just tell the user where the file was saved.

   Otherwise, send the question using the ask-question CLI:

   ```bash
   ask-question -f /tmp/research-{topic-slug}-question.md \
                -o /tmp/research-{topic-slug}-answer.md \
                -t 1200000
   ```

   Always use a timeout of at least 20 minutes (`-t 1200000`). ChatGPT's deep research mode can take several minutes for complex questions.

   After ask-question returns, discuss the response with the user. Summarize key insights and recommendations.
