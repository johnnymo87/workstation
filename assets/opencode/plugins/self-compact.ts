export async function findActiveModel(input: {
  fetch: typeof fetch
  serverUrl: URL
  sessionID: string
}): Promise<{ providerID: string; modelID: string } | null> {
  const url = new URL(`/session/${encodeURIComponent(input.sessionID)}/message`, input.serverUrl)
  let res: Response
  try {
    res = await input.fetch(new Request(url.toString(), { method: "GET" }))
  } catch {
    return null
  }
  if (!res.ok) return null
  const messages = (await res.json()) as Array<{
    info: { role: string; model?: { providerID?: string; modelID?: string } }
  }>
  for (let i = messages.length - 1; i >= 0; i--) {
    const m = messages[i]
    if (
      m.info.role === "user" &&
      m.info.model?.providerID &&
      m.info.model?.modelID
    ) {
      return { providerID: m.info.model.providerID, modelID: m.info.model.modelID }
    }
  }
  return null
}
