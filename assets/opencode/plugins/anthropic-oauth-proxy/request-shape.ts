function stripObjectCacheFields(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(stripObjectCacheFields)
  if (!value || typeof value !== "object") return value

  const entries = Object.entries(value)
    .filter(([key]) => key != "cache_control" && key != "cacheControl")
    .map(([key, child]) => [key, stripObjectCacheFields(child)])

  return Object.fromEntries(entries)
}

export function stripAnthropicCacheMarkers(body: Record<string, any>) {
  return stripObjectCacheFields(body) as Record<string, any>
}

export function rewriteAnthropicSystemPrompt(body: Record<string, any>) {
  if (!Array.isArray(body.system)) return body

  body.system = body.system.map((block) => {
    if (!block || typeof block != "object" || block.type != "text" || typeof block.text != "string") return block
    return {
      ...block,
      text: block.text.replace(/OpenCode/g, "Claude Code").replace(/opencode/gi, "Claude"),
    }
  })

  return body
}
