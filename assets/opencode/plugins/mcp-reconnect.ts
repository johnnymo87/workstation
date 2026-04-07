import type { Plugin } from "@opencode-ai/plugin"

const MCP_NAME = "tec"
const MCP_PROBE_URL = "http://localhost:4006/mcp"
const TOOL_PREFIX = "mcp_tec_"
const HEALTHY_TTL_MS = 30_000

let lastHealthy = 0
let reconnecting = false

async function isServerUp(): Promise<boolean> {
  try {
    await fetch(MCP_PROBE_URL, { signal: AbortSignal.timeout(2000) })
    return true
  } catch {
    return false
  }
}

const plugin: Plugin = async (ctx) => ({
  "tool.execute.before": async (input, output) => {
    if (!input.tool.startsWith(TOOL_PREFIX)) return
    if (reconnecting) return

    const now = Date.now()
    if (now - lastHealthy < HEALTHY_TTL_MS) return

    // TTL expired — check if server is up, then force a fresh session.
    // We can't tell from outside whether OpenCode's cached MCP session
    // ID is still valid (server restart invalidates it), so we
    // disconnect+reconnect to guarantee a fresh handshake.
    if (!(await isServerUp())) {
      // Server truly down — nothing to reconnect to. Let the tool
      // call fail naturally with a clear error.
      return
    }

    reconnecting = true
    try {
      console.log(`[mcp-reconnect] refreshing ${MCP_NAME} session...`)
      await ctx.client.mcp.disconnect({ path: { name: MCP_NAME } })
      await ctx.client.mcp.connect({ path: { name: MCP_NAME } })
      console.log(`[mcp-reconnect] ${MCP_NAME} session refreshed`)
      lastHealthy = Date.now()
    } catch (err) {
      console.error(`[mcp-reconnect] refresh failed:`, err)
    } finally {
      reconnecting = false
    }
  },
})

export default plugin
