---
name: tagging-sessions
description: Use when checking or setting which spend tag an opencode session is attributed to, when an oc-tags report shows untagged (auto:) sessions or tags that look like branch names, when asked which programs of work spend is going to, or before adding, renaming, or bulk-retagging oc-tags tags.
---

# Tagging Sessions

`oc-tags` attributes each root session's list-price LLM spend to a tag, and
`oc-tags report` / `oc-tags serve` chart it. The report is only as good as the
tag vocabulary, and that vocabulary decays unless it is maintained. This skill
is the policy; **the actual tag list — which names internal programs and ticket
keys — is in `INTERNAL.md` beside this file**, fetched from Confluence at
home-manager activation on work hosts. On a host without it (devbox), the
policy still applies; there is just no org tag list to pick from.

## Commands

```bash
oc-tags which                  # this session's effective tag ($OPENCODE_SESSION_ID)
oc-tags set <tag>              # tag this session
oc-tags set <tag> <session>    # tag another root session
oc-tags ls --counts            # every tag in use, with session counts
oc-tags top --days 7 --min 20  # most expensive UNTAGGED root sessions
oc-tags report --days 7        # dollars by tag
```

Tags attach to **root** sessions; subagent spend rolls up to its root, and
`set` / `which` from a subagent act on its root. A session with no tag reports
as an `auto:` fallback derived from its directory — `auto:<repo>` at a repo
root, `auto:<repo>/<worktree>` in a worktree, `auto:tmp` under `/tmp`. Those
look like branch names by construction; that is the fallback, not a mistag.

Launching sessions? `opencode-launch --tag` writes the same tag and follows the
same rules below. Without `--tag`, a launch copies the launcher's tag onto the
child (so will Telegram `/launch` from a session's topic or reply, once pigeon
ships it) — only an explicit session tag, never a dir glob or `auto:`. Check
your own tag before spinning up unrelated work, and pass `--tag auto` to opt out.

## Tagging the session you are in

Only when the work clearly belongs to one tag in `INTERNAL.md`. Check first
with `oc-tags which`; if it already has a tag, leave it. If the work does not
obviously match an existing tag, **do not tag it and do not invent a tag** —
mention it to the user instead. An untagged session is visible as a to-do; a
mistagged one is invisible.

**No `INTERNAL.md` here** (devbox, or a work host whose Confluence fetch has
never succeeded): there is no vocabulary to choose from, so don't tag — tell
the user. `oc-tags ls` is not a substitute; it lists retired tags too.

## Naming

**Tags name programs of work, not repos, worktrees, or ticket numbers.** A tag
should still make sense to someone reading a spend report six months from now.

| Don't | Why |
|---|---|
| A worktree slug | Branches are deleted; the program outlives them. Twelve worktrees on one program produce twelve tags and no total. |
| A system or service name | Names the thing you touched, not the outcome you were after. Two unrelated efforts in the same service collide. |
| A ticket key | Unreadable in a report, and it pins the tag to one ticket when the program outgrows it. |
| Anything containing "new" | It will not be new for long, and renaming later loses continuity. |

Prefer the phrasing you would use to describe the work to someone outside the
team. If a tag needs a gloss to be understood, it is the wrong tag.

## One tag, one home

Each work tag maps to exactly one tracker item at roughly epic granularity.
Implementation detail gets neither its own tag nor its own ticket — the epic is
the unit, and sequenced execution lives in plan documents and beads.

- **New work needing a new tag needs a new epic.** If it does not deserve one,
  it belongs to an existing program; reuse that tag.
- **A tag with no home is a finding.** Real effort is going somewhere the
  tracker cannot see. Report it; don't quietly create the tag.

Tags for personal tooling are the deliberate exception: worth measuring, not
worth putting on a board other people read. `INTERNAL.md` lists them.

A new or renamed tag is a change to the Confluence page, not just an
`oc-tags set`. Otherwise the next session cannot find it.

## Operating rules

1. **Don't guess.** A mislabelled tag is worse than an untagged session: the
   report then reads as authoritative while being wrong, and nothing about it
   looks wrong.
2. **`auto:` tags are a to-do, not a category.** Seeing one in a report means
   a session needs tagging — or needs the user to say what it was.
3. **No directory patterns on worktrees.** `oc-tags top` will suggest
   `oc-tags set --dir '<repo>/.worktrees/*' <tag>` whenever several untagged
   sessions share a prefix. Don't. A pattern covers every *future* session
   under it, whatever it turns out to be, and takes them all out of `top` — the
   detector goes blind for that path permanently. Use `--dir` only for a
   directory that is by definition one program forever (a dedicated repo), and
   otherwise tag sessions one at a time.
4. **Retagging is destructive.** `oc-tags set` is an upsert with no history.
   Before any bulk retag, snapshot the store and save the report you are about
   to change:
   ```bash
   cp ~/.local/share/oc-tags/tags.db /tmp/tags.db.bak-$(date +%Y%m%d-%H%M%S)
   oc-tags report --days 30 > /tmp/oc-tags-report-before.txt
   ```
   Classify with a dry run first, print the plan, and leave anything ambiguous
   untouched. Substring rules misfire (`pack` matches `package`); use word
   boundaries.
5. **Spend is a coverage detector, not a ranking.** It measures one person's
   LLM iteration over a short window — not effort, not value, not what anyone
   else cares about. Use it to find work with no tracker home. Do not use it to
   size or prioritise programs, and do not put the dollar figures in front of
   stakeholders.

## Keep org names out of source

The tag list lives in Confluence because tag names and their tracker homes
identify the org. The same applies anywhere else you write about tags in a
public repo: describe the mechanism, not the programs.
