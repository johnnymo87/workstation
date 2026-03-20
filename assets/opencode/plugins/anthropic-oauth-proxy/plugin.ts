type OAuthAuth = {
  type: "oauth"
  access: string
  refresh: string
  expires: number
}

type LoaderProvider = {
  models: Record<string, { cost?: Record<string, number> }>
}

type PluginInput = {
  client: {
    auth: {
      set: (input: unknown) => Promise<void>
    }
  }
}

const CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
const PLATFORM_CALLBACK_URL = "https://platform.claude.com/oauth/code/callback"
const OAUTH_SCOPE = "org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"

let pendingExchange: { code: string; promise: Promise<{ type: "failed" } | { type: "success"; refresh: string; access: string; expires: number }> } | undefined

function proxyBaseURL() {
  return process.env.ANTHROPIC_PROXY_BASE_URL || "http://127.0.0.1:4318"
}

function base64UrlEncode(input: Uint8Array) {
  return Buffer.from(input).toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "")
}

async function generatePKCE() {
  const verifierBytes = crypto.getRandomValues(new Uint8Array(32))
  const verifier = base64UrlEncode(verifierBytes)
  const challengeBytes = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier)))
  const challenge = base64UrlEncode(challengeBytes)
  return { verifier, challenge }
}

async function authorize(mode: "max" | "console") {
  const pkce = await generatePKCE()
  const url = new URL(`https://${mode == "console" ? "platform.claude.com" : "claude.ai"}/oauth/authorize`)
  url.searchParams.set("code", "true")
  url.searchParams.set("client_id", CLIENT_ID)
  url.searchParams.set("response_type", "code")
  url.searchParams.set("redirect_uri", PLATFORM_CALLBACK_URL)
  url.searchParams.set("scope", OAUTH_SCOPE)
  url.searchParams.set("code_challenge", pkce.challenge)
  url.searchParams.set("code_challenge_method", "S256")
  url.searchParams.set("state", pkce.verifier)
  return { url: url.toString(), verifier: pkce.verifier }
}

async function exchange(code: string, verifier: string) {
  const normalized = code.replace(/\s+/g, "")
  if (pendingExchange && pendingExchange.code == normalized) return pendingExchange.promise
  const promise = exchangeOnce(normalized, verifier)
  pendingExchange = { code: normalized, promise }
  try {
    return await promise
  } finally {
    if (pendingExchange?.code == normalized) pendingExchange = undefined
  }
}

async function exchangeOnce(normalized: string, verifier: string) {
  const splits = normalized.split("#")
  const result = await fetch(`${proxyBaseURL()}/oauth/exchange`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      code: splits[0],
      state: splits[1],
      client_id: CLIENT_ID,
      redirect_uri: PLATFORM_CALLBACK_URL,
      code_verifier: verifier,
    }),
  })
  if (!result.ok) {
    const text = await result.text().catch(() => "")
    console.error(`Anthropic OAuth exchange failed: ${result.status}${text ? ` ${text}` : ""}`)
    return { type: "failed" as const }
  }
  const json = await result.json()
  return {
    type: "success" as const,
    refresh: json.refresh_token,
    access: json.access_token,
    expires: Date.now() + json.expires_in * 1000,
  }
}

async function refreshViaProxy(auth: OAuthAuth, client: PluginInput["client"]) {
  const response = await fetch(`${proxyBaseURL()}/oauth/refresh`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ refresh_token: auth.refresh }),
  })
  if (!response.ok) throw new Error(`Token refresh failed: ${response.status}`)
  const json = await response.json()
  await client.auth.set({
    path: { id: "anthropic" },
    body: {
      type: "oauth",
      refresh: json.refresh_token,
      access: json.access_token,
      expires: Date.now() + json.expires_in * 1000,
    },
  })
  return {
    access: json.access_token as string,
    refresh: json.refresh_token as string,
    expires: Date.now() + Number(json.expires_in) * 1000,
  }
}

function resolveRequestInput(input: RequestInfo | URL, baseURL: string) {
  if (typeof input === "string") {
    return input.startsWith("http://") || input.startsWith("https://") ? input : new URL(input, baseURL).toString()
  }
  if (input instanceof URL) return input.toString()
  return input.url.startsWith("http://") || input.url.startsWith("https://") ? input : new Request(new URL(input.url, baseURL), input)
}

function routeViaProxy(input: RequestInfo | URL, baseURL: string) {
  const resolved = resolveRequestInput(input, baseURL)
  const url = typeof resolved === "string" ? new URL(resolved) : resolved instanceof URL ? resolved : new URL(resolved.url)
  if (url.hostname === "api.anthropic.com" || url.hostname === "platform.claude.com" || url.hostname === "console.anthropic.com") {
    return new URL(`${url.pathname}${url.search}`, baseURL).toString()
  }
  return resolved
}

async function createAnthropicProxyPlugin(input: PluginInput) {
  return {
    auth: {
      provider: "anthropic",
      async loader(getAuth: () => Promise<OAuthAuth>, provider: LoaderProvider) {
        const auth = await getAuth()
        if (auth.type !== "oauth") return {}
        for (const model of Object.values(provider.models)) model.cost = { input: 0, output: 0 }
        return {
          apiKey: "",
          async fetch(requestInput: RequestInfo | URL, requestInit?: RequestInit) {
            let current = await getAuth()
            if (current.expires < Date.now()) {
              current = { type: "oauth", ...(await refreshViaProxy(current, input.client)) }
            }

            const headers = new Headers(requestInit?.headers)
            headers.set("authorization", `Bearer ${current.access}`)
            headers.delete("x-api-key")

            return fetch(routeViaProxy(requestInput, proxyBaseURL()), {
              ...requestInit,
              headers,
            })
          },
        }
      },
      methods: [
        {
          label: "Claude Pro/Max",
          type: "oauth",
          authorize: async () => {
            const { url, verifier } = await authorize("max")
            return {
              url,
              instructions: "Paste the authorization code here: ",
              method: "code",
              callback: async (code: string) => exchange(code, verifier),
            }
          },
        },
        {
          label: "Create an API Key",
          type: "oauth",
          authorize: async () => {
            const { url, verifier } = await authorize("console")
            return {
              url,
              instructions: "Paste the authorization code here: ",
              method: "code",
              callback: async (code: string) => {
                const credentials = await exchange(code, verifier)
                if (credentials.type === "failed") return credentials
                const response = await fetch("https://api.anthropic.com/api/oauth/claude_cli/create_api_key", {
                  method: "POST",
                  headers: {
                    "Content-Type": "application/json",
                    authorization: `Bearer ${credentials.access}`,
                  },
                })
                const result = await response.json()
                return { type: "success" as const, key: result.raw_key }
              },
            }
          },
        },
        {
          provider: "anthropic",
          label: "Manually enter API Key",
          type: "api",
        },
      ],
    },
  }
}

export default async function AnthropicProxyPlugin({ client }: { client: PluginInput["client"] }) {
  return createAnthropicProxyPlugin({ client })
}
