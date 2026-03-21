import { stripAnthropicCacheMarkers } from "./request-shape"

export type RequestType = "messages" | "refresh" | "exchange" | "usage" | "other"

export type LogRecord = {
  type: RequestType
  path: string
  status: number
  flags?: Record<string, boolean>
  headers?: Record<string, string>
  bodySummary?: Record<string, unknown>
  responseSummary?: Record<string, unknown>
}

export type ProxyConfig = {
  anthropicApiBaseURL: string
  anthropicConsoleBaseURL: string
  clientID: string
  userAgent: string
  overrideUserAgent: boolean
  stripCacheMarkers: boolean
  debug: boolean
}

export const DEFAULT_PROXY_CONFIG: ProxyConfig = {
  anthropicApiBaseURL: "https://api.anthropic.com",
  anthropicConsoleBaseURL: "https://platform.claude.com",
  clientID: "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
  userAgent: "claude-code/2.1.80",
  overrideUserAgent: true,
  stripCacheMarkers: false,
  debug: false,
}

function redactValue(key: string, value: unknown) {
  const lowered = key.toLowerCase()
  if (lowered.includes("authorization") || lowered.includes("token")) return "[redacted]"
  return value
}

function sanitizeObject(input: Record<string, unknown> | undefined) {
  if (!input) return undefined
  return Object.fromEntries(Object.entries(input).map(([key, value]) => [key, redactValue(key, value)]))
}

export function classifyRequest(path: string): RequestType {
  if (path == "/messages" || path.includes("/v1/messages")) return "messages"
  if (path.includes("/oauth/refresh") || path.includes("/v1/oauth/token")) return "refresh"
  if (path.includes("/oauth/exchange")) return "exchange"
  if (path.includes("/api/oauth/usage")) return "usage"
  return "other"
}

export function createLogger(sink: (record: LogRecord) => void) {
  return (record: LogRecord) => {
    sink({
      ...record,
      headers: sanitizeObject(record.headers),
      bodySummary: sanitizeObject(record.bodySummary),
      responseSummary: sanitizeObject(record.responseSummary),
    })
  }
}

async function summarizeRequestBody(request: Request) {
  const contentType = request.headers.get("content-type") || ""
  if (!contentType.includes("application/json")) return undefined
  const clone = request.clone()
  const text = await clone.text().catch(() => "")
  if (!text) return undefined
  try {
    const parsed = JSON.parse(text)
    return {
      hasCacheControl: text.includes("cache_control") || text.includes("cacheControl"),
      hasSystem: Boolean(parsed.system),
      hasMessages: Boolean(parsed.messages),
      model: typeof parsed.model === "string" ? parsed.model : undefined,
    }
  } catch {
    return { hasJsonBody: true }
  }
}

async function summarizeResponseBody(response: Response) {
  const contentType = response.headers.get("content-type") || ""
  if (!contentType.includes("application/json")) return undefined
  const clone = response.clone()
  const text = await clone.text().catch(() => "")
  if (!text) return undefined
  try {
    const parsed = JSON.parse(text)
    return {
      type: parsed?.error?.type ?? parsed?.type,
      message: parsed?.error?.message ?? parsed?.error_description,
      code: parsed?.error?.details?.error_code ?? parsed?.error,
    }
  } catch {
    return { hasJsonBody: true }
  }
}

const OAUTH_USER_AGENT = "axios/1.13.6"

function applyUserAgent(headers: Headers, config: ProxyConfig, policy: "oauth" | "api") {
  if (!config.overrideUserAgent) return
  headers.set("user-agent", policy == "oauth" ? OAUTH_USER_AGENT : config.userAgent)
}

function sanitizeOutboundHeaders(headers: Headers) {
  for (const key of ["host", "connection", "content-length", "transfer-encoding", "accept-encoding", "proxy-connection"]) {
    headers.delete(key)
  }
  return headers
}

function mergeAnthropicBetas(headers: Headers) {
  const incoming = (headers.get("anthropic-beta") || "")
    .split(",")
    .map((item) => item.trim())
    .filter(Boolean)
  const required = ["oauth-2025-04-20", "interleaved-thinking-2025-05-14"]
  headers.set("anthropic-beta", [...new Set([...required, ...incoming])].join(","))
}

async function buildRefreshRequest(request: Request, config: ProxyConfig) {
  const payload = await request.json()
  const headers = new Headers({ "Content-Type": "application/json" })
  applyUserAgent(headers, config, "oauth")
  return new Request(`${config.anthropicConsoleBaseURL}/v1/oauth/token`, {
    method: "POST",
    headers,
    body: JSON.stringify({
      grant_type: "refresh_token",
      refresh_token: payload.refresh_token,
      client_id: payload.client_id ?? config.clientID,
    }),
  })
}

async function buildExchangeRequest(request: Request, config: ProxyConfig) {
  const payload = await request.json()
  const headers = new Headers({ "Content-Type": "application/json" })
  applyUserAgent(headers, config, "oauth")
  return new Request(`${config.anthropicConsoleBaseURL}/v1/oauth/token`, {
    method: "POST",
    headers,
    body: JSON.stringify({
      grant_type: "authorization_code",
      code: payload.code,
      state: payload.state,
      client_id: payload.client_id ?? config.clientID,
      redirect_uri: payload.redirect_uri ?? "https://platform.claude.com/oauth/code/callback",
      code_verifier: payload.code_verifier,
    }),
  })
}

async function buildForwardRequest(request: Request, config: ProxyConfig) {
  const url = new URL(request.url)
  const upstreamPath = url.pathname == "/messages" ? "/v1/messages" : url.pathname
  const upstream = new URL(`${config.anthropicApiBaseURL}${upstreamPath}${url.search}`)
  const headers = new Headers(request.headers)
  sanitizeOutboundHeaders(headers)
  applyUserAgent(headers, config, "api")
  mergeAnthropicBetas(headers)

  let body: string | undefined
  if (!(request.method == "GET" || request.method == "HEAD")) {
      body = await request.text()
      if (headers.get("content-type")?.includes("application/json") && url.pathname == "/v1/messages") {
        try {
          let next = JSON.parse(body)
          if (config.stripCacheMarkers) next = stripAnthropicCacheMarkers(next)
          body = JSON.stringify(next)
        } catch {
        }
    }
  }

  return new Request(upstream, {
    method: request.method,
    headers,
    body,
  })
}

export function createProxyHandler(
  config: ProxyConfig = DEFAULT_PROXY_CONFIG,
  upstreamFetch: typeof fetch = fetch,
  sink: (record: LogRecord) => void = () => {},
) {
  const logger = createLogger(sink)

  function sanitizeResponseHeaders(headers: Headers) {
    const next = new Headers(headers)
    next.delete("content-encoding")
    next.delete("content-length")
    next.delete("transfer-encoding")
    return next
  }

  return async function handle(request: Request) {
    const url = new URL(request.url)
    if (url.pathname == "/health") return Response.json({ ok: true })

    const type = classifyRequest(url.pathname)
    const bodySummary = config.debug ? await summarizeRequestBody(request) : undefined
    const upstreamRequest =
      url.pathname == "/oauth/refresh"
        ? await buildRefreshRequest(request, config)
        : url.pathname == "/oauth/exchange"
          ? await buildExchangeRequest(request, config)
          : await buildForwardRequest(request, config)

    const response = await upstreamFetch(upstreamRequest)
    const responseSummary = config.debug && !response.ok ? await summarizeResponseBody(response) : undefined

    logger({
      type,
      path: url.pathname,
      status: response.status,
      flags: {
        overrideUserAgent: config.overrideUserAgent,
        stripCacheMarkers: config.stripCacheMarkers,
        debug: config.debug,
      },
      headers: Object.fromEntries(request.headers.entries()),
      bodySummary,
      responseSummary,
    })

    return new Response(response.body, {
      status: response.status,
      statusText: response.statusText,
      headers: sanitizeResponseHeaders(response.headers),
    })
  }
}

export function startProxyServer(
  config: ProxyConfig = DEFAULT_PROXY_CONFIG,
  port = 4318,
  sink: (record: LogRecord) => void = () => {},
) {
  const handler = createProxyHandler(config, fetch, sink)
  return Bun.serve({ port, fetch: handler })
}
