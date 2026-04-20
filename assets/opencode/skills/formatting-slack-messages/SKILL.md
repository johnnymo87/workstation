---
name: formatting-slack-messages
description: Use when composing or posting messages to Slack via the Slack MCP (or any Slack API). Slack's mrkdwn dialect is similar to but NOT the same as CommonMark — bold uses single asterisks, italic uses underscores, headers don't exist, and links use angle-bracket syntax. Apply this whenever drafting Slack content or you'll post mangled formatting.
---

# Formatting Slack Messages

Slack uses its own format called **mrkdwn**. It looks like Markdown but the rules are different. If you reach for CommonMark/GitHub-flavored Markdown habits, your message will render with literal asterisks, broken links, or invisible headers.

This skill is the cheat sheet. Read it before writing any Slack message.

## The Cheat Sheet

| What you want | Slack mrkdwn | NOT this (CommonMark) |
|---|---|---|
| **Bold** | `*bold*` | `**bold**` |
| *Italic* | `_italic_` | `*italic*` or `_italic_` |
| ~~Strike~~ | `~strike~` | `~~strike~~` |
| `inline code` | `` `code` `` | same — backticks work |
| Code block | ` ```code``` ` | same — triple backticks work |
| Block quote | `> quoted` (per line) | same |
| Header | (none — use `*Bold:*` on its own line) | `# Header`, `## Header` render literally |
| Link with label | `<https://url\|label>` | `[label](https://url)` |
| Bare link | `https://url` (auto-linkified) | same |
| User mention | `<@U012AB3CD>` | — |
| Channel link | `<#C012AB3CD>` | — |
| User group ping | `<!subteam^S012AB3CD>` | — |
| Special mention | `<!here>`, `<!channel>`, `<!everyone>` | — |
| Bullet list | `- item` or `• item` per line | same — bullets work |
| Numbered list | `1. item` per line | same |
| Nested list | unreliable — avoid; flatten or use sub-bullets at one level | — |
| Line break | `\n` in the API string, real newline in editors | — |

## The Most Common Mistake

Using `**double asterisks**` for bold. This is the GitHub/CommonMark default and it's what most Markdown writers reach for by reflex. In Slack it renders **literally** — readers see the asterisks, not bold text.

**Always single asterisks for bold.** When proofreading a Slack draft, scan for `**` and convert to `*`.

## Headers Don't Exist

There is no `#` / `##` / `###` syntax in mrkdwn. They render as literal `#` characters at the start of the line.

The conventional substitute is a bold label on its own line:

```
*Section title:*
Body text follows here.
```

Or, for stronger separation, an emoji + bold label:

```
:bulb: *Key insight:* ...
```

## Links

Slack uses **angle brackets with a pipe**, not Markdown's `[text](url)`:

```
<https://example.com|click here>
```

A bare URL without angle brackets gets auto-linkified — fine if you don't need custom label text. Note: URLs containing spaces will break; encode them.

## Escaping

Three characters are control characters in mrkdwn and must be HTML-escaped if you want them to render literally:

| Character | Escape as |
|---|---|
| `&` | `&amp;` |
| `<` | `&lt;` |
| `>` | `&gt;` |

You don't need to escape the entire message — only these specific characters.

## Code Blocks Are Literal

Inside backticks (single or triple), Slack disables all other formatting. So `` `*not bold*` `` shows the asterisks literally. Useful when you want to show formatting examples in a message.

Triple-backtick code blocks **do not** support a language hint — `` ```python `` is fine syntax but the `python` is rendered as part of the first line of code. Just use plain triple backticks.

## When Posting via the Slack MCP

The MCP exposes a `content_type` parameter on `slack_conversations_add_message`:

| `content_type` | What happens |
|---|---|
| `text/markdown` (default) | MCP attempts to translate CommonMark → mrkdwn before sending. Translation is incomplete (in particular, `**bold**` → literal `**bold**` is a known failure). |
| `text/plain` | Sent as-is. **Recommended when you've written native mrkdwn yourself.** |

**Workflow:** write the message in native mrkdwn (single asterisks for bold, etc.) and pass `content_type: "text/plain"` to bypass the translation layer.

If you forget and use the default `text/markdown`, the safe rewrite is: convert all `**bold**` to `*bold*`, all `[label](url)` to `<url|label>`, drop all `#`/`##` headers (replace with `*Bold label:*` on its own line), and resend.

## The Verification Habit

Before sending any non-trivial Slack message via the MCP:

1. Scan for `**` — there should be none.
2. Scan for `[` followed eventually by `](` — convert to angle-bracket links.
3. Scan for lines starting with `#` — drop the hashes, bold the line if you want emphasis.
4. If using bullet lists with nesting beyond one level, flatten — Slack's nested-list rendering is inconsistent.
5. Pass `content_type: "text/plain"` to the MCP.

## Why Slack Did This

Slack's mrkdwn predates CommonMark's market dominance. They chose a syntax inspired by IRC/early-2010s chat conventions (single `*` for bold, `_` for italic) and have kept it for backward compatibility. It's not going to change. Treat mrkdwn as a separate dialect and you'll stop fighting it.

## Reference

- Slack official docs: https://docs.slack.dev/messaging/formatting-message-text
- Block Kit Builder (visual previewer for mrkdwn + blocks): https://app.slack.com/block-kit-builder/
