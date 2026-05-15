/**
 * Helper for the context-usage plugin: fetches the most recent assistant
 * message's accumulated token count.
 *
 * Lives in a separate file from the plugin entrypoint because opencode's
 * plugin loader iterates `Object.entries(mod)` and invokes every exported
 * function as a plugin factory. Test-only helpers must therefore not be
 * exported from `context-usage.ts`. (Same constraint as `self-compact.ts`;
 * see its header comment for the canonical statement.)
 */
export async function fetchLatestAssistantUsage(input: {
  fetch: typeof fetch
  serverUrl: URL
  sessionID: string
}): Promise<number | null> {
  const url = new URL(
    `/session/${encodeURIComponent(input.sessionID)}/message`,
    input.serverUrl,
  )
  let res: Response
  try {
    res = await input.fetch(new Request(url.toString(), { method: "GET" }))
  } catch {
    return null
  }
  if (!res.ok) return null

  let parsed: unknown
  try {
    parsed = await res.json()
  } catch {
    return null
  }
  if (!Array.isArray(parsed)) return null

  for (let i = parsed.length - 1; i >= 0; i--) {
    const m = parsed[i] as { info?: { role?: string; tokens?: any } } | null
    if (!m || m.info?.role !== "assistant") continue
    const t = m.info?.tokens
    if (!t) continue
    // Match overflow.ts:24 and acp/agent.ts:114.
    const used =
      typeof t.total === "number"
        ? t.total
        : (t.input ?? 0) +
          (t.output ?? 0) +
          (t.cache?.read ?? 0) +
          (t.cache?.write ?? 0)
    if (used > 0) return used
  }
  return null
}