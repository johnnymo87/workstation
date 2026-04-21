Your root-cause analysis is mostly right.

The key point is not really prompt_async being fire-and-forget. That is a bug worth fixing, and there are already adjacent reports around async session-state/race handling, but it is not the thing that explains multiple simultaneous LLM turns on one session. The crux is that session-execution state is bound to the current Instance context, while HTTP request routing still derives that context from x-opencode-directory; on current dev, prompt_async still does not await SessionPrompt.prompt, InstanceMiddleware still binds the instance from x-opencode-directory, and SessionRunState is still backed by InstanceState, whose cache key is the current directory. 
GitHub
+5
GitHub
+5
GitHub
+5

That means your “busy” invariant is still effectively directory-partitioned, not truly session-partitioned. So your hypothesis generalizes beyond the older Instance.state(() => …) implementation you quoted: the code has been refactored, but the same architectural seam is still there. I think your diagnosis is directionally correct, and I also think your secondary suspicion is right: inserting a user message before exclusivity is established is a separate correctness problem. 
GitHub
+3
GitHub
+3
GitHub
+3

My ranking of fixes, combining correctness and blast radius:

Bind all session-scoped routes to the session’s stored directory, not the caller’s header/query directory.
For any route of the form /session/:sessionID/..., load the session first and re-enter Instance.provide using session.directory. Keep x-opencode-directory for session creation and non-session-scoped routes. This is the smallest fix that restores the right ownership model for a session and should make the existing per-instance runner actually serialize a given session again. It also lines up with a separate upstream complaint that session operations can run under the wrong directory context. 
GitHub
+2
GitHub
+2

Make the run lock itself process-global and keyed by sessionID.
This is the right invariant in principle: one process, one active run per session ID. I do not think a process-global Map<sessionID, Runner> is unsafe by itself; session IDs are already global identifiers, and status/cancel semantics are already session-keyed. What you must not do is globalize the lock while leaving execution context request-owned, because then you serialize correctly but still run tools/shell/path logic under the wrong cwd. So: good lock invariant, but best paired with session-derived context. 
GitHub
+3
GitHub
+3
GitHub
+3

Change prompt admission so “busy” is checked before inserting a new user message, or introduce a real per-session inbox/FIFO.
This is the deeper semantic fix. Right now, current dev still inserts the user message and only then enters the runner path; when the runner is already busy, ensureRunning just waits on the current run’s deferred result instead of enqueueing a distinct future run. That is not a true queue. 
GitHub
+1

Provider-side trailing-assistant normalization as a compatibility shim.
This is worth doing defensively for Claude 4.6/4.7-family providers, but it is not the right fix for your race. It papers over conversation corruption after the fact. OpenCode already has an upstream issue in a neighboring area for Claude/Azure prefill breakage after aborts, which is the same family of symptom but a different root cause. 
GitHub
+2
Claude
+2

So for your specific options:

1. “Key the busy map by sessionID, not by directory” — right or wrong?
Right as the locking invariant, incomplete as the full fix. A process-global session lock is the cleanest concurrency invariant. What breaks is mainly lifecycle bookkeeping: today instance disposal invalidates instance-scoped state; with a global session map you need explicit cleanup on cancel/completion/shutdown. That is manageable. The bigger risk is not the map itself; it is forgetting to also run the session under session.directory. 
GitHub
+2
GitHub
+2

2. Which layer is best?
Option 2a is the best narrow upstream patch. Rebind session routes from the session record. It has the fewest knock-on effects because it preserves the current InstanceState/SessionRunState design and fixes both the lock split and wrong-cwd execution for that session. Option 2b is the best architectural backstop, but slightly broader. Option 2c is probably necessary eventually if you want correct mailbox semantics, but it is the least “small and reviewable” of the three because it changes how concurrent prompts are represented and may affect TUI/subagent flows. 
GitHub
+4
GitHub
+4
GitHub
+4

3. Cleanest no-patch workaround?
Your “fixed coordinator cwd” idea should eliminate this specific multi-directory parallel-turn race as long as every coordinator-targeted request uses the same effective directory header, because all requests then collapse onto the same Instance and the same session runner. I would still add an external per-session lock in opencode-send if you need reliability today. flock /tmp/opencode-$sessionID.lock ... is uglier than the fixed-cwd trick but safer, because it prevents concurrent admission before OpenCode sees the requests at all. Fixed cwd removes the directory split; flock removes the burst entirely. 
GitHub
+3
GitHub
+3
GitHub
+3

4. Are queued callbacks safe?
For the exact older code you quoted, I cannot prove the callback-drain behavior without the drain snippet, so I would not overclaim. But I agree with your concern: if prompts insert user messages before they are actually admitted, then even a “working” callback list can still leave the tree semantically wrong. On current dev, the situation is clearer: Runner.ensureRunning() returns Deferred.await(st.run.done) when already running, so extra callers wait for the current run’s result rather than scheduling a distinct next run. That means “many concurrent prompts to one session” is still not a real FIFO inbox. Some messages may be folded into the active loop if timing is lucky; others can be left needing another trigger. 
GitHub
+1

5. Is the Claude/Vertex “assistant prefill” rule real?
Yes for your model. Anthropic’s current docs explicitly say Claude Opus 4.7, Opus 4.6, and Sonnet 4.6 do not support prefilling assistant messages and return a 400 when the final message is assistant-role. Anthropic’s migration guide says continuations should be moved into a user message instead. Google’s Vertex Claude docs still contain a generic statement saying a final assistant message continues the response, which looks stale or model-agnostic. So I would trust Anthropic’s model-specific docs over Vertex’s generic Claude page here. This does not look like an AI SDK-only validation layer. 
Google Cloud Documentation
+3
Claude
+3
Claude
+3

A synthetic empty user message can work as an emergency escape hatch, but I would treat it as a compatibility shim, not a rescue strategy for this bug. It unblocks the provider, but it hides the fact that your session sequencing already drifted. The right place for that shim is provider normalization for known no-prefill providers/models, not as a substitute for fixing the race. There is already adjacent ecosystem evidence of the same provider-side 400 showing up when frameworks accidentally build a final assistant turn for Anthropic 4.6-era models. 
GitHub
+2
GitHub
+2

6. Recommended swarm topology on one opencode serve?
The practical rule is: many sessions can run in parallel; one session should have one writer.
Your workers can absolutely stay parallel, but they should not all write directly into the coordinator session concurrently. The clean pattern is a single-writer mailbox: workers write to an inbox file/SQLite table/Redis list/per-session lock-protected outbox, and one feeder process turns inbox items into coordinator prompts. If you want zero infrastructure, even “append JSON line to a coordinator inbox file + one tailing feeder” is better than multi-writer prompt_async into one session. OpenCode sessions behave much more like agent state machines than like concurrent chatroom mailboxes. The nearby upstream async-race issues reinforce that session concurrency is still fragile. 
GitHub
+2
GitHub
+2

7. What repro should you attach to the PR?
For the issue report: yes, a small shell or Node script that fires N concurrent POST /session/:id/prompt_async requests against one session with N different x-opencode-directory values is enough.
For the actual PR, I would add a TS integration test with a dummy/mock provider that sleeps briefly and records entries into the critical section. The assertion should be “for one session ID, concurrent requests from different directories must not produce more than one active run.” Avoid making Anthropic/Vertex itself part of CI; use the provider only as the human-visible symptom in the bug report. The current route/middleware/run-state code makes that test target very clear. 
GitHub
+3
GitHub
+3
GitHub
+3

On prior upstream references: I found adjacent issues, not your exact one. The closest are wrong-directory/session-context bugs, prompt_async session-state/race bugs, and Claude prefill bugs after abort/tool flows. I did not find an existing OpenCode issue that already names the exact “same session + different x-opencode-directory splits the busy guard” failure mode. 
GitHub
+3
GitHub
+3
GitHub
+3

My concrete recommendation:

Ship a same-day local patch that rebinds all session-scoped routes to session.directory.

Also patch prompt_async to await or at least explicitly detach/log failures; it is a separate bug.

In your wrapper, immediately force coordinator sends to the coordinator directory and add a per-session flock as belt-and-suspenders until the patch is deployed.

For upstream, propose the narrow session-route rebind first, and mention a follow-up for true process-global per-session run locking.

If you want, I’ll turn that into a PR-ready patch sketch against the current OpenCode route/middleware layout.