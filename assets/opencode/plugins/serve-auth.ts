import * as fs from "node:fs"

let cachedAuthHeader: string | undefined | null = null

/**
 * Resolves HTTP Basic Auth header for local opencode serve instances.
 *
 * Rules:
 * 1. Password: process.env.OPENCODE_SERVER_PASSWORD (trimmed). If unset/empty,
 *    read from process.env.OPENCODE_SERVER_PASSWORD_FILE else
 *    /run/secrets/opencode_server_password (trimmed, read errors swallowed).
 *    If still empty, returns undefined.
 * 2. Username: process.env.OPENCODE_SERVER_USERNAME (trimmed), falling back to "opencode".
 * 3. Header: `Basic ${Buffer.from(`${username}:${password}`).toString("base64")}`
 *
 * Resolved value is cached in module state until invalidateServeAuthHeader() is called.
 */
export function resolveServeAuthHeader(opts?: {
  passwordFilePath?: string
  forceRefresh?: boolean
}): string | undefined {
  if (opts?.forceRefresh) {
    cachedAuthHeader = null
  }

  if (cachedAuthHeader !== null) {
    return cachedAuthHeader
  }

  let password = process.env.OPENCODE_SERVER_PASSWORD?.trim()

  if (!password) {
    const filePath =
      opts?.passwordFilePath ??
      process.env.OPENCODE_SERVER_PASSWORD_FILE ??
      "/run/secrets/opencode_server_password"

    try {
      if (fs.existsSync(filePath)) {
        const fileContent = fs.readFileSync(filePath, "utf8").trim()
        if (fileContent) {
          password = fileContent
        }
      }
    } catch {
      // Swallowed: unreadable file or permission errors
    }
  }

  if (!password) {
    cachedAuthHeader = undefined
    return undefined
  }

  const envUser = process.env.OPENCODE_SERVER_USERNAME?.trim()
  const username = envUser || "opencode"

  const authHeader = `Basic ${Buffer.from(`${username}:${password}`).toString("base64")}`
  cachedAuthHeader = authHeader
  return cachedAuthHeader
}

/**
 * Invalidates the cached serve auth header.
 * Called automatically on 401 response or manually to force re-reading env/file.
 */
export function invalidateServeAuthHeader(): void {
  cachedAuthHeader = null
}

/**
 * Wraps a fetch implementation to inject the Authorization header when a serve password is configured.
 *
 * Guaranteed inert when no password is set: passes original request and init directly to baseFetch
 * without adding or mutating any headers.
 */
export function wrapFetchWithAuth(
  baseFetch: typeof fetch = globalThis.fetch,
  opts?: { passwordFilePath?: string },
): typeof fetch {
  return async (
    input: Parameters<typeof fetch>[0],
    init?: Parameters<typeof fetch>[1],
  ): Promise<Response> => {
    const authHeader = resolveServeAuthHeader(opts)
    if (!authHeader) {
      return baseFetch(input, init)
    }

    let req: Request
    if (input instanceof Request) {
      const headers = new Headers(input.headers)
      if (init?.headers) {
        new Headers(init.headers).forEach((v, k) => headers.set(k, v))
      }
      headers.set("Authorization", authHeader)
      req = new Request(input, { ...init, headers })
    } else {
      const headers = new Headers(init?.headers)
      headers.set("Authorization", authHeader)
      req = new Request(input, { ...init, headers })
    }

    const res = await baseFetch(req)
    if (res.status === 401) {
      invalidateServeAuthHeader()
    }
    return res
  }
}
