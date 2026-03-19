import { createHash } from "crypto"

type Message = {
  role?: string
  content?: unknown
}

type BillingOptions = {
  enabled: boolean
  version: string
  salt: string
  entrypoint: string
}

function firstUserMessageText(messages: Message[]) {
  for (const message of messages) {
    if (message.role !== "user") continue
    const content = message.content
    if (typeof content === "string") return content
    if (Array.isArray(content)) {
      for (const block of content) {
        if (block && typeof block === "object" && "text" in block && typeof block.text === "string") return block.text
      }
    }
  }
  return ""
}

function sampleJsCodeUnit(text: string, index: number) {
  const units = Array.from(text).flatMap((char) => {
    const encoded = Buffer.from(char, "utf16le")
    const values: number[] = []
    for (let i = 0; i < encoded.length; i += 2) values.push(encoded.readUInt16LE(i))
    return values
  })
  const unit = units[index]
  return typeof unit === "number" ? String.fromCharCode(unit) : "0"
}

export function buildBillingHeader(input: {
  messages: Message[]
  version: string
  salt: string
  entrypoint: string
}) {
  const text = firstUserMessageText(input.messages)
  const sampled = [4, 7, 20].map((idx) => sampleJsCodeUnit(text, idx)).join("")
  const digest = createHash("sha256").update(`${input.salt}${sampled}${input.version}`).digest("hex")
  return `x-anthropic-billing-header: cc_version=${input.version}.${digest.slice(0, 3)}; cc_entrypoint=${input.entrypoint}; cch=00000;`
}

export function injectBillingHeader(body: Record<string, any>, options: BillingOptions) {
  if (!options.enabled) return body
  const header = buildBillingHeader({
    messages: Array.isArray(body.messages) ? body.messages : [],
    version: options.version,
    salt: options.salt,
    entrypoint: options.entrypoint,
  })
  const billingBlock = { type: "text", text: header }
  const existing = body.system
  if (typeof existing === "string" && existing.trim()) {
    body.system = [billingBlock, { type: "text", text: existing }]
    return body
  }
  if (Array.isArray(existing)) {
    body.system = [billingBlock, ...existing]
    return body
  }
  body.system = [billingBlock]
  return body
}
