import { readConfig } from "./config"
import { startProxyServer } from "./index"
import { consoleSink } from "./log"

const port = Number(process.env.ANTHROPIC_PROXY_PORT || 4318)
const server = startProxyServer(readConfig(), port, consoleSink)

console.log(`anthropic-oauth-proxy listening on http://127.0.0.1:${server.port}`)
