# oc-tags: naming and maintaining tags

`oc-tags` attributes session spend to a tag. What makes the resulting report
useful or useless is entirely the tag vocabulary, and that vocabulary decays
unless someone maintains it. This file is the policy; the actual tag list —
which names internal programs and ticket keys — lives in Confluence and is not
in source control. See [Where the map lives](#where-the-map-lives).

## Naming

**Tags name programs of work, not repos, worktrees, or ticket numbers.**

A tag should still make sense to someone reading a spend report six months from
now. That rules out three things which are all tempting because they are to
hand at the moment you need a tag:

| Don't | Why |
|---|---|
| A worktree slug | Branches are deleted; the program outlives them. Twelve worktrees on one program produce twelve tags and no total. |
| A system or service name | Names the thing you touched, not the outcome you were after. Two unrelated efforts in the same service collide. |
| A ticket key | Unreadable in a report, and it pins the tag to one ticket when the program outgrows it. |
| Anything containing "new" | It will not be new for long, and renaming later loses continuity. |

Prefer the phrasing you would use to describe the work to someone outside the
team. If a tag needs a gloss to be understood, it is the wrong tag.

## One tag, one home

Each work tag maps to exactly one tracker item, at roughly epic granularity.
Implementation detail does not get its own tag *or* its own ticket — the epic
is the unit, and sequenced execution lives in plan documents and in beads.

Consequences worth stating, because both get violated in the moment:

- **New work needing a new tag needs a new epic.** If it does not deserve an
  epic, it belongs to an existing program; reuse that tag.
- **A tag with no home is a finding.** It means real effort is going somewhere
  the tracker cannot see.

Tags for personal tooling are the deliberate exception: they consume real
budget and are worth measuring, but filing them in a shared tracker would only
add noise to a board other people read.

## Operating rules

1. **Don't guess.** A mislabelled tag is worse than an untagged session: the
   report then reads as authoritative while being wrong, and nothing about it
   looks wrong. Leave the session on its `auto:` fallback and come back to it.
2. **`auto:` tags are a to-do, not a category.** They are the directory
   basename, standing in for a tag nobody set. Seeing one in a report means go
   and tag that session.
3. **Retagging is destructive.** `oc-tags set` is an upsert with no history, so
   a bulk retag silently overwrites the previous attribution and the old report
   cannot be reproduced. Snapshot `~/.local/share/oc-tags/tags.db` first.
4. **Spend is a coverage detector, not a ranking.** It measures one person's
   LLM iteration over a short window — not effort, not value, not how much
   anyone else cares. Use it to find work that has no home in the tracker. Do
   not use it to size or prioritise programs, and do not put the dollar figures
   in front of stakeholders.

## Where the map lives

The tag-to-epic map names internal programs, ticket keys and vendor systems, so
it is kept in Confluence rather than here, following the same split as the
`INTERNAL.md` companions described in
`.opencode/skills/scrubbing-company-references/SKILL.md`. Keep the policy above
generic; put anything org-identifying in the Confluence page.
