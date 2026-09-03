---
name: formatting-slack-messages
description: Use when composing or posting messages to Slack via the Slack MCP (or any Slack API), when replying in a Slack thread, when reporting an update to people who were not in the session, and when attaching a file, image, chart, or CSV to a Slack message. Slack's mrkdwn dialect is similar to but NOT the same as CommonMark — bold uses single asterisks, italic uses underscores, headers don't exist, and links use angle-bracket syntax. Apply this whenever drafting Slack content or you'll post mangled formatting. Also covers uploading by file_path (do not base64 a large file into the tool call) and the staging directory it requires.
---

# Formatting Slack Messages

Slack uses its own format called **mrkdwn**. It looks like Markdown but the rules are different. If you reach for CommonMark/GitHub-flavored Markdown habits, your message will render with literal asterisks, broken links, or invisible headers.

This skill is the cheat sheet. Read it before writing any Slack message.

## Composing: before the mrkdwn

The MCP authenticates with the human's `xoxp` User OAuth token, so **every message posts under their name and avatar**. Read one back and it reports their `UserName`, distinguished only by a `BotName` field almost nobody looks at. Three consequences.

**Disclose authorship.** Words you composed end with a signature — `— Claude`, or whichever agent you are. Words the human dictated go out verbatim and unsigned. Skip the "I am an AI assistant acting on behalf of" preamble; the signature is the disclosure. Without it, referring to the account owner in the third person reads as them talking about themselves.

**Show the human the draft first.** The first post into a channel or thread, and anything that commits them to something, gets approved before it goes out — notifications carry the full text and cannot be recalled. Once they have approved a thread's shape or said "go ahead", later replies in it do not need re-approval. Reply in-thread (`thread_ts`) unless told otherwise: a top-level post notifies the entire channel. Never `<!here>` or `<!channel>` unasked.

**Write for readers who were not in your context and cannot ask you follow-ups.** Slack does not autolink `#123` or `KEY-456` the way GitHub and Jira do, so link every PR, ticket, commit and dashboard you name — a reader who cannot check a claim has to take it on faith, and an agent's is the least trusted voice in the thread. A *specific* review comment (`<…/pull/N#discussion_r<id>|raised in review>`) usually beats linking the PR. For a claim that is someone else's, name them and link where they said it — a plain name pings nobody, `<@U…>` pings them, so choose deliberately. Nothing the reader cannot open: no issue-tracker ids, session ids, or worktree paths. Absolute dates, not "Monday". Keep proposals labelled as proposals — a decision written into a summary reads as settled. Re-read the thread immediately before posting, in case someone already answered.

**Order paragraphs by whose day they change.** The item with a deadline goes above the item that is merely interesting; if one paragraph changes what somebody does tomorrow, it goes first. Chronological order is the default that needs resisting — the order you *discovered* things in is rarely the order anyone needs to read them.

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
| Table | (none — wrap an aligned plaintext table in a ``` code block ```) | `\| col \| col \|` pipe syntax renders literally |
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

## Tables: Use a Code Block

Slack's mrkdwn has **no table syntax**. The CommonMark `| col | col |` / `|---|---|` pipe-and-dash form renders as literal pipes and dashes, with no column alignment.

The only reliable way to render a table is to format it as monospaced plaintext (column-aligned with spaces) and wrap the whole thing in a triple-backtick code block:

```
Model                       Cost        Messages
claude-opus-4-7@default     $3,016.46   11,935
claude-opus-4-6@default     $  262.06    2,472
gemini-3.1-pro-preview      $  132.91    5,232

Total:                      $3,411.42   (through Apr 29)
```

Notes:
- Pad columns with spaces so they align at the widest cell. Right-align numeric columns by left-padding with spaces.
- Inside the code block, no formatting applies — `*bold*`, `$`, `()`, etc. all render as literal characters, which is usually what you want for tabular data.
- For very wide tables consider transposing (one row per record, with `*Field:*` labels) — Slack's mobile clients wrap long code blocks awkwardly.

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
5. Scan for `|` pipe-and-dash table syntax — convert to a column-aligned plaintext table inside a triple-backtick code block.
6. Pass `content_type: "text/plain"` to the MCP.

## Attaching a File: Use `file_path`, and Stage It First

Do not base64 a file into `content_base64` unless it is genuinely tiny. Tool
arguments are emitted by *you*, so the base64 crosses the context window — a
294 KB chart PNG is ~392 KB of base64, over 100k tokens. It does not fit. A
session hit exactly that, gave up, and a human attached the file by hand.

`slack_file_upload` takes a `file_path` instead, which streams from disk and
costs you a path. It is restricted to one directory:

```bash
mkdir -p /tmp/opencode/slack-uploads
cp outputs/chart-2026-09-02.png /tmp/opencode/slack-uploads/
```

then `file_upload(channel_id=…, file_path="/tmp/opencode/slack-uploads/chart-2026-09-02.png")`.

Better still, skip the copy: have whatever generates the artifact write into
`/tmp/opencode/slack-uploads/` in the first place.

**Errors and what they actually mean:**

| Error | Cause |
|---|---|
| `file_path is not allowed, it resolves outside SLACK_MCP_FILE_UPLOAD_PATHS` | Path is outside the staging dir — **or the staging dir does not exist.** An unresolvable allowlist root is skipped silently and reports this same message. `mkdir -p` it. |
| `file_path must be an absolute path` | Relative paths are rejected before the allowlist is even consulted. |
| `uploading by file_path is disabled` | The allowlist is empty. This host has not had the config applied; fall back to `content_base64` for something small, and see `slack-mcp-setup`. |

A symlink inside the staging dir pointing outside it will **not** work — both the
file and the root are resolved through symlinks before comparison. Copy, don't link.

**Why the restriction exists**, so you don't try to route around it: the upload
cap is 100 MB per call, and `file_path` sends bytes that never appear in the
transcript. A wide allowlist would let one tool call ship 100 MB anywhere with
no record of what was in it. Staging makes the `cp` an explicit, logged step
naming its source. Full reasoning in `slack-mcp-setup`.

## After-Send Verification: Don't Trust the Read APIs as Ground Truth

This is the most common Claude failure mode with this MCP and it has burned multiple sessions. **Read it carefully.**

When you call `slack_conversations_history`, `slack_conversations_replies`, or `slack_conversations_search_messages` to look at a message you just posted, the `Text` field you get back is a **lossy plain-text extraction of the rendered message, not the raw mrkdwn source**. That extraction strips or alters:

- `*` and `_` formatting markers (because they're rendering as bold/italic, not as literal characters).
- Apostrophes — `Karen's` shows up as `Karens`. This is a tokenizer artifact in the extraction layer, NOT something Slack did to your source.
- Em dashes, en dashes, arrows, and other Unicode punctuation — `OnTrac→p44` may come back as `OnTracp44`.
- Triple-backtick code-block markers (the content survives, but the fences are gone).
- Leading `>` on blockquoted lines.
- Most emoji shortcodes get rendered to actual emoji (or stripped from the extraction).
- The `>` and `<` characters get HTML-escaped to `&gt;` / `&lt;` in the extracted text — that does NOT mean Slack stored your message that way. It means Slack rendered your `>` as a literal `>` in the page HTML, and the API serializes that HTML-encoded.

**Cumulative effect:** A perfectly-formatted message can come back from the read API looking like word-soup — no bold, smushed-together words where arrows used to be, missing apostrophes, no code blocks. Naive Claudes (including me, more than once) take one look at that and panic-repost a "corrected" plain-ASCII version, which is both wrong and embarrassing.

**Rules of thumb:**

1. **The substantive words, numbers, and line breaks ARE faithful.** If those are right in the read-API output, your message is almost certainly fine. Trust the structure, not the punctuation.
2. **Missing `*`s mean bold WORKED**, not that it failed. Same for `_` and italics.
3. **`&gt;` in the extraction is normal** for any literal `>` you wrote. It does NOT mean Slack got the wrong character.
4. **Missing apostrophes mean the API tokenizer is lossy**, not that your message lost them.
5. **The only ground-truth verification is to look in the actual Slack UI** (open the channel in a browser if you have one, or have a human eyeball it). The MCP's read APIs cannot confirm formatting fidelity — they can only confirm that the message landed at all.
6. If a human tells you "the message looks fine" and you're staring at scary-looking read-API output, **believe the human**. The read API is the red herring, not the message.

**When you genuinely need to confirm formatting:** ask the human to spot-check, or post a small test message with known-distinctive content into a low-traffic channel and ask. Do not iterate on formatting fixes based solely on read-API roundtrips.

## Why Slack Did This

Slack's mrkdwn predates CommonMark's market dominance. They chose a syntax inspired by IRC/early-2010s chat conventions (single `*` for bold, `_` for italic) and have kept it for backward compatibility. It's not going to change. Treat mrkdwn as a separate dialect and you'll stop fighting it.

## Reference

- Slack official docs: https://docs.slack.dev/messaging/formatting-message-text
- Block Kit Builder (visual previewer for mrkdwn + blocks): https://app.slack.com/block-kit-builder/
