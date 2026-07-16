import { describe, expect, test } from "vitest";
import { identify } from "../src/identity.js";
import type { IncomingMessage } from "node:http";

describe("identity", () => {
  test("identify returns trusted true for any request", () => {
    const dummyReq = {} as IncomingMessage;
    const result = identify(dummyReq);
    expect(result).toEqual({ trusted: true });
  });
});
