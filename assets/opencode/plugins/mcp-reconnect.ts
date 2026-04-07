import type { Plugin } from "@opencode-ai/plugin"

const MCP_NAME = "tec"
const MCP_PROBE_URL = "http://localhost:4006/mcp"
const TOOL_PREFIX = "mcp_tec_"
const TTL_MS = 30_000

let lastHealthy = 0

async function isReachable(): Promise<boolean> {
  try {
    // GET /mcp returns 406 (Not Acceptable) when FastMCP is alive.
    // Any HTTP response means the server is up. Only connection
    // refused / timeout means it's down.
    await fetch(MCP_PROBE_URL, { signal: AbortSignal.timeout(2000) })
    return true
  } catch {
    return false
  }
}

const plugin: Plugin = async (ctx) => ({
  "tool.execute.before": async (input, output) => {
    if (!input.tool.startsWith(TOOL_PREFIX)) return

    const now = Date.now()
    if (now - lastHealthy < TTL_MS) return

    if (await isReachable()) {
      lastHealthy = now
      return
    }

    // MCP server unreachable — force reconnect
    console.log(`[mcp-reconnect] ${MCP_NAME} unreachable, triggering reconnect...`)
    try {
      await ctx.client.mcp.connect({ path: { name: MCP_NAME } })
      console.log(`[mcp-reconnect] ${MCP_NAME} reconnected`)
      lastHealthy = Date.now()
    } catch (err) {
      console.error(`[mcp-reconnect] reconnect failed:`, err)
      // Let the tool call proceed — it will fail with a clear error
    }
  },
})

export default plugin
