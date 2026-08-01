import { describe, test, expect } from "vitest";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { CLASS_DISPOSITIONS, ROUTE_DISPOSITIONS, OPERATOR_RUNBOOK } from "../src/routes.dispositions.js";

/**
 * Step 2 residual (a), bead `workstation-u417`: THE DOOR MUST NOT MANUFACTURE THE
 * VIOLATIONS ITS GUARD CATCHES.
 *
 * A denial body is an instruction channel — read by automated consumers, agents and TUIs.
 * The repo-side opacity guard (`users/dev/test-frontdoor-opacity.sh`) cannot help here on
 * two counts: it does not scan `pkgs/opencode-frontdoor/src/`, and a string that only
 * exists on the wire is not in any file it could scan. So this test is the wire-side
 * analogue of that guard.
 *
 * Scope is deliberately WIRE-FACING TEXT ONLY: `userMessage`, `remedy`, and the two
 * fallback strings in `proxy.ts`. Repo-facing `rationale` is exempt by design — it cites
 * file:line, describes mechanisms, and several rows legitimately narrate the old wrong
 * hint as history.
 */

const here = dirname(fileURLToPath(import.meta.url));

/** Pool-address shapes. `409[6-9]` mirrors SITE_RE in the repo-side guard. */
const ADDRESS_PATTERNS: Array<{ re: RegExp; why: string }> = [
  { re: /127\.0\.0\.1:\d+/, why: "a literal loopback address" },
  { re: /localhost:\d+/i, why: "a literal localhost address" },
  { re: /:409[0-9]\b/, why: "a serve-pool port" },
  { re: /\bfor\s+p\s+in\b/, why: "a port-enumeration loop" },
];

/**
 * Bypass PHRASING. Matters independently of addresses: "call a serve port directly"
 * names no port but is exactly the instruction that produced this residual.
 */
const BYPASS_PHRASES: RegExp[] = [
  /\b(call|use|hit|curl)\s+(a|the|each|every|one)\s+serve\s+port/i,
  /\bserve\s+port\s+directly/i,
  /\bdirectly\s+against\s+(a|the)\s+serve/i,
  /\bbypass(ing)?\s+the\s+(front\s+)?door/i,
];

function wireStrings(): Array<{ label: string; text: string }> {
  const out: Array<{ label: string; text: string }> = [];
  for (const [table, rows] of [
    ["CLASS_DISPOSITIONS", CLASS_DISPOSITIONS],
    ["ROUTE_DISPOSITIONS", ROUTE_DISPOSITIONS],
  ] as const) {
    for (const [key, row] of Object.entries(rows)) {
      if (row.userMessage) out.push({ label: `${table}["${key}"].userMessage`, text: row.userMessage });
      if (row.remedy) out.push({ label: `${table}["${key}"].remedy`, text: row.remedy });
    }
  }
  return out;
}

/**
 * The two `proxy.ts` fallbacks are template literals built at request time, so they are
 * read as SOURCE TEXT rather than imported. Anchored on their surrounding syntax so the
 * extraction fails loudly if the code is restructured, instead of silently matching
 * nothing (the vacuity failure this project keeps hitting).
 */
function proxyFallbacks(): Array<{ label: string; text: string }> {
  const src = readFileSync(join(here, "..", "src", "proxy.ts"), "utf8");
  const found: Array<{ label: string; text: string }> = [];

  const webUi = src.match(/message:\s*`([^`]*web UI[^`]*)`/);
  if (webUi) found.push({ label: "proxy.ts web-ui 404 message", text: webUi[1] });

  const remedy = src.match(/disposition\?\.remedy\s*\n?\s*\?\?\s*`([^`]*)`/);
  if (remedy) found.push({ label: "proxy.ts generic deny remedy", text: remedy[1] });

  return found;
}

describe("wire-facing text never instructs a front-door bypass", () => {
  test("the extraction is NON-VACUOUS (it would fail if it matched nothing)", () => {
    const rows = wireStrings();
    const fallbacks = proxyFallbacks();
    // If a refactor breaks these regexes, this test fails rather than passing green
    // while policing an empty set.
    expect(rows.length).toBeGreaterThan(0);
    expect(fallbacks).toHaveLength(2);
  });

  test.each([...wireStrings(), ...proxyFallbacks()])("$label names no serve address", ({ text }) => {
    for (const { re, why } of ADDRESS_PATTERNS) {
      expect(
        re.test(text),
        `wire-facing text contains ${why}. Move port-level detail to ${OPERATOR_RUNBOOK} and point at it instead.\nText: ${text}`,
      ).toBe(false);
    }
  });

  test.each([...wireStrings(), ...proxyFallbacks()])("$label uses no bypass phrasing", ({ text }) => {
    for (const re of BYPASS_PHRASES) {
      expect(
        re.test(text),
        `wire-facing text instructs a direct-to-serve bypass (/${re.source}/). Name the CONSTRAINT and point at ${OPERATOR_RUNBOOK}.\nText: ${text}`,
      ).toBe(false);
    }
  });

  test("every terminal-denial row carries wire-facing text of its own", () => {
    // The residual was not "some strings are wrong" but "five rows carry NOTHING, so they
    // inherit the generic hint". A row with no userMessage/remedy is how that recurs.
    const naked = Object.entries(ROUTE_DISPOSITIONS)
      .filter(([, row]) => row.kind === "terminal-denial")
      .filter(([, row]) => !row.userMessage && !row.remedy)
      .map(([key]) => key);

    expect(naked, `terminal-denial rows with no wire-facing text (they inherit the generic fallback): ${naked.join(", ")}`).toEqual([]);
  });

  test("the runbook the wire text points at actually exists", () => {
    // A dangling pointer is worse than no pointer: it reads as authoritative.
    const repoRoot = join(here, "..", "..", "..");
    expect(() => readFileSync(join(repoRoot, OPERATOR_RUNBOOK), "utf8")).not.toThrow();
  });
});
