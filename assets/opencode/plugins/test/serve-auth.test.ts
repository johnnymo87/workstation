import { describe, it, expect, beforeEach, afterEach, vi } from "vitest"
import * as fs from "node:fs"
import * as path from "node:path"
import * as os from "node:os"
import {
  resolveServeAuthHeader,
  invalidateServeAuthHeader,
  wrapFetchWithAuth,
} from "../serve-auth"

describe("serve-auth resolver", () => {
  let tempDir: string
  const originalEnv = { ...process.env }

  beforeEach(() => {
    tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "serve-auth-test-"))
    invalidateServeAuthHeader()
    delete process.env.OPENCODE_SERVER_PASSWORD
    delete process.env.OPENCODE_SERVER_PASSWORD_FILE
    delete process.env.OPENCODE_SERVER_USERNAME
  })

  afterEach(() => {
    fs.rmSync(tempDir, { recursive: true, force: true })
    process.env = { ...originalEnv }
    invalidateServeAuthHeader()
  })

  it("base64 test vector: opencode:hunter2 produces Basic b3BlbmNvZGU6aHVudGVyMg==", () => {
    process.env.OPENCODE_SERVER_PASSWORD = "hunter2"
    process.env.OPENCODE_SERVER_USERNAME = "opencode"
    const header = resolveServeAuthHeader()
    expect(header).toBe("Basic b3BlbmNvZGU6aHVudGVyMg==")
  })

  it("returns undefined when password is unset and secret file is absent", () => {
    const header = resolveServeAuthHeader({
      passwordFilePath: path.join(tempDir, "nonexistent"),
    })
    expect(header).toBeUndefined()
  })

  it("returns undefined when password env is empty string or whitespace-only", () => {
    process.env.OPENCODE_SERVER_PASSWORD = "   \n\t  "
    const header = resolveServeAuthHeader({
      passwordFilePath: path.join(tempDir, "nonexistent"),
    })
    expect(header).toBeUndefined()
  })

  it("uses OPENCODE_SERVER_PASSWORD env when set (trimming whitespace)", () => {
    process.env.OPENCODE_SERVER_PASSWORD = "  mysecretpassword  \n"
    const header = resolveServeAuthHeader({
      passwordFilePath: path.join(tempDir, "nonexistent"),
    })
    // opencode:mysecretpassword -> b3BlbmNvZGU6bXlzZWNyZXRwYXNzd29yZA==
    const expectedBase64 = Buffer.from("opencode:mysecretpassword").toString("base64")
    expect(header).toBe(`Basic ${expectedBase64}`)
  })

  it("env password beats secret file", () => {
    const secretFile = path.join(tempDir, "secret_file")
    fs.writeFileSync(secretFile, "filepassword\n", "utf8")
    process.env.OPENCODE_SERVER_PASSWORD = "envpassword"

    const header = resolveServeAuthHeader({ passwordFilePath: secretFile })
    const expectedBase64 = Buffer.from("opencode:envpassword").toString("base64")
    expect(header).toBe(`Basic ${expectedBase64}`)
  })

  it("reads secret file when OPENCODE_SERVER_PASSWORD is absent and trims trailing newline", () => {
    const secretFile = path.join(tempDir, "secret_file")
    fs.writeFileSync(secretFile, "filepassword\r\n", "utf8")

    const header = resolveServeAuthHeader({ passwordFilePath: secretFile })
    const expectedBase64 = Buffer.from("opencode:filepassword").toString("base64")
    expect(header).toBe(`Basic ${expectedBase64}`)
  })

  it("returns undefined when secret file is empty or whitespace-only", () => {
    const secretFile = path.join(tempDir, "secret_file")
    fs.writeFileSync(secretFile, "  \n\t ", "utf8")

    const header = resolveServeAuthHeader({ passwordFilePath: secretFile })
    expect(header).toBeUndefined()
  })

  it("swallows read errors for unreadable secret file and returns undefined", () => {
    const unreadableFile = path.join(tempDir, "unreadable")
    // non-existent file path inside non-existent directory structure
    const header = resolveServeAuthHeader({
      passwordFilePath: path.join(unreadableFile, "sub", "file"),
    })
    expect(header).toBeUndefined()
  })

  it("uses custom OPENCODE_SERVER_USERNAME when provided", () => {
    process.env.OPENCODE_SERVER_PASSWORD = "secret"
    process.env.OPENCODE_SERVER_USERNAME = "  admin_user  "

    const header = resolveServeAuthHeader({
      passwordFilePath: path.join(tempDir, "nonexistent"),
    })
    const expectedBase64 = Buffer.from("admin_user:secret").toString("base64")
    expect(header).toBe(`Basic ${expectedBase64}`)
  })

  it("falls back to 'opencode' when OPENCODE_SERVER_USERNAME is whitespace-only", () => {
    process.env.OPENCODE_SERVER_PASSWORD = "secret"
    process.env.OPENCODE_SERVER_USERNAME = "   \n\t "

    const header = resolveServeAuthHeader({
      passwordFilePath: path.join(tempDir, "nonexistent"),
    })
    const expectedBase64 = Buffer.from("opencode:secret").toString("base64")
    expect(header).toBe(`Basic ${expectedBase64}`)
  })

  it("caches resolved header and invalidateServeAuthHeader clears cache", () => {
    process.env.OPENCODE_SERVER_PASSWORD = "first_password"
    const header1 = resolveServeAuthHeader({
      passwordFilePath: path.join(tempDir, "nonexistent"),
    })
    const expected1 = `Basic ${Buffer.from("opencode:first_password").toString("base64")}`
    expect(header1).toBe(expected1)

    // Change env without invalidating
    process.env.OPENCODE_SERVER_PASSWORD = "second_password"
    const header2 = resolveServeAuthHeader({
      passwordFilePath: path.join(tempDir, "nonexistent"),
    })
    // Must return cached first value
    expect(header2).toBe(expected1)

    // Now invalidate
    invalidateServeAuthHeader()
    const header3 = resolveServeAuthHeader({
      passwordFilePath: path.join(tempDir, "nonexistent"),
    })
    const expected3 = `Basic ${Buffer.from("opencode:second_password").toString("base64")}`
    expect(header3).toBe(expected3)
  })

  it("caches undefined when no password exists until invalidated", () => {
    const header1 = resolveServeAuthHeader({
      passwordFilePath: path.join(tempDir, "nonexistent"),
    })
    expect(header1).toBeUndefined()

    // Set env without invalidating
    process.env.OPENCODE_SERVER_PASSWORD = "new_password"
    const header2 = resolveServeAuthHeader({
      passwordFilePath: path.join(tempDir, "nonexistent"),
    })
    expect(header2).toBeUndefined()

    invalidateServeAuthHeader()
    const header3 = resolveServeAuthHeader({
      passwordFilePath: path.join(tempDir, "nonexistent"),
    })
    expect(header3).toBe(`Basic ${Buffer.from("opencode:new_password").toString("base64")}`)
  })
})

describe("wrapFetchWithAuth", () => {
  let tempDir: string
  const originalEnv = { ...process.env }

  beforeEach(() => {
    tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "serve-auth-fetch-test-"))
    invalidateServeAuthHeader()
    delete process.env.OPENCODE_SERVER_PASSWORD
    delete process.env.OPENCODE_SERVER_PASSWORD_FILE
    delete process.env.OPENCODE_SERVER_USERNAME
  })

  afterEach(() => {
    fs.rmSync(tempDir, { recursive: true, force: true })
    process.env = { ...originalEnv }
    invalidateServeAuthHeader()
  })

  it("inert when unset: passes original request unchanged with NO Authorization header key", async () => {
    const mockBaseFetch = vi.fn().mockImplementation(async (req: Request) => {
      return new Response("ok", { status: 200 })
    })

    const fetchAuth = wrapFetchWithAuth(mockBaseFetch, {
      passwordFilePath: path.join(tempDir, "nonexistent"),
    })

    const request = new Request("http://localhost:58432/session/status", {
      method: "GET",
      headers: { "X-Custom-Header": "value" },
    })

    await fetchAuth(request)

    expect(mockBaseFetch).toHaveBeenCalledOnce()
    const passedReq = mockBaseFetch.mock.calls[0][0] as Request

    // Must be the exact same request object or have no Authorization header
    expect(passedReq.headers.has("Authorization")).toBe(false)
    expect(passedReq.headers.has("authorization")).toBe(false)
    expect(Object.fromEntries(passedReq.headers.entries())).not.toHaveProperty("authorization")
    expect(Object.fromEntries(passedReq.headers.entries())).not.toHaveProperty("Authorization")
  })

  it("attaches Authorization header when password is set", async () => {
    process.env.OPENCODE_SERVER_PASSWORD = "hunter2"

    const mockBaseFetch = vi.fn().mockImplementation(async (req: Request) => {
      return new Response("ok", { status: 200 })
    })

    const fetchAuth = wrapFetchWithAuth(mockBaseFetch, {
      passwordFilePath: path.join(tempDir, "nonexistent"),
    })

    const request = new Request("http://localhost:58432/session/status", {
      method: "GET",
      headers: { "Content-Type": "application/json" },
    })

    await fetchAuth(request)

    expect(mockBaseFetch).toHaveBeenCalledOnce()
    const passedReq = mockBaseFetch.mock.calls[0][0] as Request

    expect(passedReq.headers.get("Authorization")).toBe("Basic b3BlbmNvZGU6aHVudGVyMg==")
    expect(passedReq.headers.get("Content-Type")).toBe("application/json")
  })

  it("invalidates cached auth header on 401 response", async () => {
    process.env.OPENCODE_SERVER_PASSWORD = "wrong_password"

    const mockBaseFetch = vi.fn().mockImplementation(async () => {
      return new Response("Unauthorized", { status: 401 })
    })

    const fetchAuth = wrapFetchWithAuth(mockBaseFetch, {
      passwordFilePath: path.join(tempDir, "nonexistent"),
    })

    await fetchAuth(new Request("http://localhost:58432/session/status"))

    // Change password in env
    process.env.OPENCODE_SERVER_PASSWORD = "right_password"

    // Next call should re-read env because 401 invalidated cache
    await fetchAuth(new Request("http://localhost:58432/session/status"))

    const secondReq = mockBaseFetch.mock.calls[1][0] as Request
    const expectedHeader = `Basic ${Buffer.from("opencode:right_password").toString("base64")}`
    expect(secondReq.headers.get("Authorization")).toBe(expectedHeader)
  })
})
