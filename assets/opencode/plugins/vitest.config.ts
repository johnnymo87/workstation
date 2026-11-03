import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    environment: "node",
    include: ["test/**/*.test.ts"],
    // Keep test runs out of the live ~/.local/state/opencode/self-compact.log,
    // which is the forensic record for real self-compact incidents.
    env: { OPENCODE_SELF_COMPACT_LOG: "/tmp/self-compact-vitest.log" },
  },
});
