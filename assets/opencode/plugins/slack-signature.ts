import type { Plugin } from "@opencode-ai/plugin"

/**
 * Keeps trailing model signatures on Slack MCP posts accurate for OpenCode
 * sessions (e.g. rewriting "--Claude" to "--Gemini" when a session is running
 * on Gemini, including after a mid-session model switch).
 *
 * Goose sessions handle the same rewrite inside `slack-mcp-server` via
 * `AGENT_SESSION_ID` + `SLACK_MCP_SIGNATURE_CMD` (goose spawns one MCP process
 * per session). OpenCode shares one `slack-mcp-server` process across all
 * sessions on a serve, so the MCP process cannot know which session sent a
 * tool call; this plugin fills that half in-process with zero DB/subprocess I/O.
 *
 * Policy: rewrite-only on a standalone trailing signature line. Unsigned
 * messages (such as text dictated verbatim by the human) are never modified.
 * Fail-open everywhere: any error leaves the tool arguments untouched.
 */

const MAX_TRACKED_SESSIONS = 500
const SLACK_POST_TOOL = "slack_conversations_add_message"
const SLACK_UPLOAD_TOOL = "slack_file_upload"
// Auxiliary agents (title generation, compaction, summary) run on small_model
// under the parent session's sessionID; never let them overwrite the session's
// main model family.
const IGNORED_AGENTS = new Set(["title", "compaction", "summary"])

// Matches a standalone trailing signature line ("--Claude", "— Claude",
// "– Gemini", "--GPT") with optional leading/trailing spaces and newline.
// Deliberately does NOT match prose like "-- Claude suggested reverting."
const SIGNATURE_LINE_RE =
  /^([ \t]*(?:--|—|–)[ \t]*)(Claude|Gemini|GPT|Codex)([ \t]*\r?\n?)$/i

function classifyModelFamily(rawModel: string | undefined | null): string | undefined {
  if (!rawModel || typeof rawModel !== "string") return undefined
  let model = rawModel.trim()
  if (!model) return undefined
  const slash = model.lastIndexOf("/")
  if (slash !== -1) model = model.slice(slash + 1)
  let lower = model.toLowerCase()
  if (lower.startsWith("anthropic.")) lower = lower.slice("anthropic.".length)
  if (lower.startsWith("claude")) return "Claude"
  if (lower.startsWith("gemini")) return "Gemini"
  if (
    lower.startsWith("gpt") ||
    lower.startsWith("codex") ||
    lower.startsWith("o1") ||
    lower.startsWith("o3") ||
    lower.startsWith("o4")
  ) {
    return "GPT"
  }
  return undefined
}

function rewriteSignature(text: string, family: string | undefined): string {
  if (!text || !family) return text
  // Split preserving line endings so formatting and trailing newlines stay intact.
  const lines = text.match(/[^\r\n]*(?:\r?\n|$)/g)
  if (!lines) return text
  // match() with trailing $ appends an empty string at the end; drop it.
  if (lines.length > 0 && lines[lines.length - 1] === "") lines.pop()

  let lastIdx = -1
  for (let i = lines.length - 1; i >= 0; i--) {
    if (lines[i].trim() !== "") {
      lastIdx = i
      break
    }
  }
  if (lastIdx === -1) return text

  const m = SIGNATURE_LINE_RE.exec(lines[lastIdx])
  if (!m) return text

  lines[lastIdx] = `${m[1]}${family}${m[3]}`
  return lines.join("")
}

function extractModelId(model: unknown): string | undefined {
  if (!model || typeof model !== "object") return undefined
  const m = model as { id?: unknown; modelID?: unknown }
  if (typeof m.id === "string" && m.id.trim()) return m.id
  if (typeof m.modelID === "string" && m.modelID.trim()) return m.modelID
  return undefined
}

function rememberSessionFamily(
  cache: Map<string, string>,
  sessionID: string | undefined,
  model: unknown,
  agent?: unknown,
): void {
  if (!sessionID) return
  if (typeof agent === "string" && IGNORED_AGENTS.has(agent)) return
  const fam = classifyModelFamily(extractModelId(model))
  if (!fam) return
  // Refresh insertion order for LRU-like eviction.
  if (cache.has(sessionID)) cache.delete(sessionID)
  cache.set(sessionID, fam)
  if (cache.size > MAX_TRACKED_SESSIONS) {
    const oldest = cache.keys().next().value
    if (oldest !== undefined) cache.delete(oldest)
  }
}

const plugin: Plugin = async () => {
  const sessionFamilies = new Map<string, string>()

  return {
    "chat.params": async (input) => {
      try {
        rememberSessionFamily(sessionFamilies, input?.sessionID, input?.model, input?.agent)
      } catch {
        // Fail open: never block a model call.
      }
    },
    "chat.headers": async (input) => {
      try {
        rememberSessionFamily(sessionFamilies, input?.sessionID, input?.model, input?.agent)
      } catch {
        // Fail open: never block a model call.
      }
    },
    "tool.execute.before": async (input, output) => {
      try {
        if (!input?.sessionID || !output?.args || typeof output.args !== "object") return
        const family = sessionFamilies.get(input.sessionID)
        if (!family) return

        if (input.tool === SLACK_POST_TOOL && typeof output.args.text === "string") {
          output.args.text = rewriteSignature(output.args.text, family)
        } else if (
          input.tool === SLACK_UPLOAD_TOOL &&
          typeof output.args.initial_comment === "string"
        ) {
          output.args.initial_comment = rewriteSignature(output.args.initial_comment, family)
        }
      } catch {
        // Fail open: never abort a Slack post on a signature-rewrite error.
      }
    },
  }
}

export default { id: "slack-signature", server: plugin }

export const internals = {
  classifyModelFamily,
  rewriteSignature,
  extractModelId,
  rememberSessionFamily,
}
