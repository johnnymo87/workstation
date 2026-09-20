# Devbox defaults the adversarial reviewer to astra

2026-09-19

## What changes

On **devbox only**, `adversarial-reviewer-astra` (`openai/gpt-6-astra` via
codex-lb) becomes the default adversarial reviewer — plan-time *and* the
standing pre-PR diff review. cloudbox and macOS are unchanged: fable stays the
default there, and macOS has no astra twin at all.

Scope was deliberately widened from the original ask ("the pre-PR skill should
say astra") to *all* adversarial reviews on devbox. Two defaults pointing at
different models depending on which mode you are in is a seam nobody will
remember at dispatch time; one rule per host is cheaper to hold. The cost is
blast radius: with the availability policy below, a dead codex-lb blocks every
adversarial review on devbox rather than just PRs.

## Why per-host rendering rather than conditional prose

The alternative was one deployed file whose text says "on devbox use astra,
elsewhere use fable" and lets the model branch on `$OPENCODE_HOSTNAME`. Rejected:
it asks the reader to evaluate a condition on every dispatch, and it puts text
about hosts that cannot run astra in front of hosts that cannot run astra.

Instead the text is rewritten at build time, the same discipline
`mkAgentVariant` already uses for the agent twins: each host's deployed
`SKILL.md` names exactly one agent, and the rewrite is match-or-die so a rename
upstream fails the build instead of silently shipping stale advice.

## The three edits

### 1. `assets/opencode/skills/shepherding-pull-requests/SKILL.md`

Source keeps `adversarial-reviewer-fable` in the dispatch sentence (§Pre-PR
Checks step 3) — it is the majority-host text. Adds a host-neutral availability
paragraph (see "Availability" below).

### 2. `users/dev/opencode-skills.nix`

Takes `isDevbox` (already in specialArgs, previously not destructured here).
Adds `astraShepherdingSkill`, a `runCommand` that perl-rewrites the dispatch
reference, and routes `mkSkill` through it for that one skill on devbox.

Guard hardening, all of it from the plan-time review:

- `-0777` (true slurp) rather than `-0` (NUL-delimited records).
- **Non-empty input assertion.** Under `-p` the body never runs on empty input,
  so a truncated source would emit an empty file and exit 0 — the `die` is
  unreachable in exactly the case that matters most.
- **Exactly-one-match assertion**, not "at least one". The substitution targets
  the dispatch sentence specifically; a second, differently-intended mention of
  the fable handle (e.g. a future fallback instruction) must fail the build
  rather than be silently inverted.

### 3. `users/dev/opencode-config.nix`

`mkAgentVariant` gains a `caution` parameter defaulting to today's string
(`use this <model> variant ONLY when the user explicitly asks for it; otherwise
default to <base>-fable`). `mkAstraVariant` forwards it. On devbox the
adversarial-reviewer twin gets the inverted text instead; `oracle-astra` keeps
the standard caution on every host, and cloudbox's adversarial-reviewer twin
keeps it too.

The appended text must not contain a colon-space — the existing build-time
guard (exactly one `": "` on the `description:` line) enforces this, because a
`": "` inside the YAML scalar makes opencode's gray-matter parse throw, fall
into a racy fallback, and *skip the agent*, leaving a stub that silently runs
the caller's model.

`caution` is interpolated into perl source, not passed as data. Future values
containing `!` (the substitution delimiter), `$`, `@`, or a backslash need
escaping review. The value shipped here contains none.

### 4. `.opencode/skills/opencode-agents/SKILL.md`

Not optional — it currently contradicts this change in executable terms:

- `:37` "do **not** silently substitute the astra twin" into the pre-PR default.
- `:49` "They are opt-in... Do not auto-select them."
- `:103` "Their build output is identical on devbox and cloudbox" — false once
  the caution is host-dependent.

All three become host-qualified.

## Availability

astra is reachable only while `codex-lb.service` is up **and** its upstream
model-catalog refresh is healthy; it fails at *request* time, never at build
time. Policy, stated in the skill: **stop and report to the user.** Do not
silently fall back to the other twin, and do not treat a failed or empty review
as the review having happened.

Falling back was considered and rejected: a fallback that fires silently makes
the host-default meaningless and hides a broken codex-lb for as long as nobody
looks.

## Verification

- `nix flake check --keep-going` — never with `--no-build` (cloudbox evaluation
  is IFD-dependent on `google-guest-configs`).
- **Same-host before/after** store diffs, not only cross-host: cross-host
  comparison cannot prove cloudbox is unchanged from today.
- macOS: assert the astra agent files are *absent*, rather than diffing them.
- Assert unchanged: `oracle-astra`'s caution on every host, both `-fable`
  agents, the `openai/gpt-6-astra` pin, and the agent bodies/permissions.
- Exercise the rewrite's negative cases (empty input, zero matches, two
  matches) against the real derivation script.
