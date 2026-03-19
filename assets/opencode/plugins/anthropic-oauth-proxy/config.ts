import { DEFAULT_PROXY_CONFIG, type ProxyConfig } from "./index"

export function readConfig(env: NodeJS.ProcessEnv = process.env): ProxyConfig {
  return {
    anthropicApiBaseURL: env.ANTHROPIC_API_BASE_URL || DEFAULT_PROXY_CONFIG.anthropicApiBaseURL,
    anthropicConsoleBaseURL: env.ANTHROPIC_CONSOLE_BASE_URL || DEFAULT_PROXY_CONFIG.anthropicConsoleBaseURL,
    clientID: env.ANTHROPIC_OAUTH_CLIENT_ID || DEFAULT_PROXY_CONFIG.clientID,
    userAgent: env.ANTHROPIC_PROXY_USER_AGENT || DEFAULT_PROXY_CONFIG.userAgent,
    overrideUserAgent: env.ANTHROPIC_PROXY_OVERRIDE_UA != "false",
    injectBillingHeader: env.ANTHROPIC_PROXY_INJECT_BILLING != "false",
    stripCacheMarkers: env.ANTHROPIC_PROXY_STRIP_CACHE_MARKERS == "true",
    billingSalt: env.ANTHROPIC_PROXY_BILLING_SALT || DEFAULT_PROXY_CONFIG.billingSalt,
    billingVersion: env.ANTHROPIC_PROXY_BILLING_VERSION || DEFAULT_PROXY_CONFIG.billingVersion,
    billingEntrypoint: env.ANTHROPIC_PROXY_BILLING_ENTRYPOINT || DEFAULT_PROXY_CONFIG.billingEntrypoint,
  }
}
