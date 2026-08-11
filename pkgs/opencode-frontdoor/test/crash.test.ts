import { describe, test, expect, vi } from "vitest";
import { EventEmitter } from "node:events";
import { installCrashHandlers } from "../src/crash.js";

describe("Crash Handlers Backstop", () => {
  test("registers listeners on custom emitter", () => {
    const proc = new EventEmitter();
    const log = vi.fn();
    const exit = vi.fn();

    installCrashHandlers({ proc, log, exit });

    expect(proc.listenerCount("uncaughtException")).toBe(1);
    expect(proc.listenerCount("unhandledRejection")).toBe(1);
  });

  test("uncaughtException logs error and exits with 1", () => {
    const proc = new EventEmitter();
    const log = vi.fn();
    const exit = vi.fn();

    installCrashHandlers({ proc, log, exit });

    const error = new Error("Uncaught boom");
    proc.emit("uncaughtException", error);

    expect(log).toHaveBeenCalledTimes(1);
    const logArg = log.mock.calls[0][0];
    expect(logArg).toContain("[FRONTDOOR FATAL]");
    expect(log.mock.calls[0][1]).toBe(error);

    expect(exit).toHaveBeenCalledWith(1);
  });

  test("unhandledRejection logs reason and does NOT exit", () => {
    const proc = new EventEmitter();
    const log = vi.fn();
    const exit = vi.fn();

    installCrashHandlers({ proc, log, exit });

    const reason = "Unhandled rejection reason";
    proc.emit("unhandledRejection", reason);

    expect(log).toHaveBeenCalledTimes(1);
    const logArg = log.mock.calls[0][0];
    expect(logArg).toContain("[FRONTDOOR WARN]");
    expect(log.mock.calls[0][1]).toBe(reason);

    expect(exit).not.toHaveBeenCalled();
  });
});
