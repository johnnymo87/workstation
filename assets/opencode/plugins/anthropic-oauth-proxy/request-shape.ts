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
