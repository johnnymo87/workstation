#!/usr/bin/env node
// Analyzes OpenCode prompt caching efficiency from the local SQLite database.
// Usage: node analyze.mjs              # last 14 days
//        DAYS=30 node analyze.mjs      # last 30 days
//
// Auto-wraps with `nix-shell -p sqlite` if sqlite3 is not on PATH.

import { execSync } from "child_process";
import { existsSync } from "fs";
import { homedir } from "os";
import { join } from "path";

// Re-exec under nix-shell if sqlite3 is missing
try {
  execSync("which sqlite3", { stdio: "ignore" });
} catch {
  const scriptPath = new URL(import.meta.url).pathname;
  const env = process.env.DAYS ? `DAYS=${process.env.DAYS} ` : "";
  try {
    execSync(`nix-shell -p sqlite --run "${env}node ${scriptPath}"`, {
      stdio: "inherit",
    });
  } catch {
    // nix-shell exit code propagates; just exit with same code
  }
  process.exit(0);
}

const DB_PATH = join(homedir(), ".local/share/opencode/opencode.db");
const DAYS = parseInt(process.env.DAYS || "14", 10);

if (!existsSync(DB_PATH)) {
  console.error(`Database not found: ${DB_PATH}`);
  process.exit(1);
}

function sql(query) {
  const raw = execSync(`sqlite3 -json "${DB_PATH}"`, {
    input: query,
    encoding: "utf8",
  }).trim();
  if (!raw) return [];
  return JSON.parse(raw);
}

// Anthropic pricing per million tokens (USD)
// https://docs.anthropic.com/en/docs/about-claude/pricing
const PRICES = {
  "claude-opus-4-6": {
    input: 5, output: 25, cache_write: 6.25, cache_read: 0.50,
  },
  "claude-opus-4-5": {
    input: 5, output: 25, cache_write: 6.25, cache_read: 0.50,
  },
  "claude-opus-4-1": {
    input: 15, output: 75, cache_write: 18.75, cache_read: 1.50,
  },
  "claude-opus-4": {
    input: 15, output: 75, cache_write: 18.75, cache_read: 1.50,
  },
  "claude-sonnet-4-6": {
    input: 3, output: 15, cache_write: 3.75, cache_read: 0.30,
  },
  "claude-sonnet-4-5": {
    input: 3, output: 15, cache_write: 3.75, cache_read: 0.30,
  },
  "claude-sonnet-4": {
    input: 3, output: 15, cache_write: 3.75, cache_read: 0.30,
  },
  "claude-haiku-4-5": {
    input: 1, output: 5, cache_write: 1.25, cache_read: 0.10,
  },
  "claude-haiku-3-5": {
    input: 0.80, output: 4, cache_write: 1.0, cache_read: 0.08,
  },
};

function priceFor(modelId) {
  // Strip @default or other suffixes
  const base = modelId.replace(/@.*$/, "");
  if (PRICES[base]) return PRICES[base];
  // Fuzzy match: try progressively shorter prefixes
  for (const key of Object.keys(PRICES)) {
    if (base.startsWith(key)) return PRICES[key];
  }
  return null;
}

function cost(tokens, ratePerMTok) {
  return (tokens * ratePerMTok) / 1e6;
}

function fmtUsd(n) {
  return "$" + n.toFixed(2);
}

function pct(part, total) {
  return total > 0 ? ((part / total) * 100).toFixed(1) : "0.0";
}

// ── Daily breakdown ─────────────────────────────────────────────────────────
const daily = sql(`
  SELECT date(time_created/1000, 'unixepoch') as day,
    COUNT(*) as msgs,
    sum(COALESCE(json_extract(data, '$.tokens.cache.read'),0)) as cache_read,
    sum(COALESCE(json_extract(data, '$.tokens.cache.write'),0)) as cache_write,
    sum(COALESCE(json_extract(data, '$.tokens.input'),0)) as uncached,
    sum(COALESCE(json_extract(data, '$.tokens.output'),0)) as output
  FROM message
  WHERE json_extract(data, '$.role') = 'assistant'
    AND json_extract(data, '$.tokens.cache.read') IS NOT NULL
    AND date(time_created/1000, 'unixepoch') >= date('now', '-${DAYS} days')
  GROUP BY day ORDER BY day;
`);

if (daily.length === 0) {
  console.error("No usage data found in the specified period.");
  process.exit(1);
}

console.log(`\n  OpenCode Usage Report (last ${DAYS} days)\n`);
console.log("DATE        MSGS   READ%  WRITE%  UNCACHED%");
console.log("-".repeat(52));
for (const d of daily) {
  const total = d.cache_read + d.cache_write + d.uncached;
  console.log(
    `${d.day}  ${String(d.msgs).padStart(5)}  ` +
    `${pct(d.cache_read, total).padStart(5)}%  ` +
    `${pct(d.cache_write, total).padStart(5)}%    ` +
    `${pct(d.uncached, total).padStart(5)}%`
  );
}

// ── Per-model breakdown ─────────────────────────────────────────────────────
const byModel = sql(`
  SELECT
    json_extract(data, '$.modelID') as model,
    COUNT(*) as msgs,
    sum(COALESCE(json_extract(data, '$.tokens.cache.read'),0)) as cache_read,
    sum(COALESCE(json_extract(data, '$.tokens.cache.write'),0)) as cache_write,
    sum(COALESCE(json_extract(data, '$.tokens.input'),0)) as uncached,
    sum(COALESCE(json_extract(data, '$.tokens.output'),0)) as output
  FROM message
  WHERE json_extract(data, '$.role') = 'assistant'
    AND json_extract(data, '$.tokens.cache.read') IS NOT NULL
    AND date(time_created/1000, 'unixepoch') >= date('now', '-${DAYS} days')
  GROUP BY model ORDER BY cache_read DESC;
`);

console.log("\n\n  Per-Model Cost Breakdown\n");
console.log("MODEL                          MSGS   CACHE_RD(M)  CACHE_WR(M)  OUTPUT(M)   COST");
console.log("-".repeat(90));

let grandTotal = 0;
let grandCacheRead = 0;
let grandCacheWrite = 0;
let grandUncached = 0;
let grandOutput = 0;

for (const m of byModel) {
  const p = priceFor(m.model);
  const cr_M = m.cache_read / 1e6;
  const cw_M = m.cache_write / 1e6;
  const out_M = m.output / 1e6;
  const modelCost = p
    ? cost(m.cache_read, p.cache_read) +
      cost(m.cache_write, p.cache_write) +
      cost(m.uncached, p.input) +
      cost(m.output, p.output)
    : 0;
  grandTotal += modelCost;
  grandCacheRead += m.cache_read;
  grandCacheWrite += m.cache_write;
  grandUncached += m.uncached;
  grandOutput += m.output;

  const name = m.model.length > 28 ? m.model.slice(0, 28) + ".." : m.model;
  const priceTag = p ? fmtUsd(modelCost).padStart(10) : "  (no rate)";
  console.log(
    `${name.padEnd(30)} ${String(m.msgs).padStart(5)}  ` +
    `${cr_M.toFixed(1).padStart(10)}  ${cw_M.toFixed(1).padStart(10)}  ` +
    `${out_M.toFixed(1).padStart(8)}  ${priceTag}`
  );
}

console.log("-".repeat(90));
console.log(
  `${"TOTAL".padEnd(30)} ${" ".repeat(5)}  ` +
  `${(grandCacheRead / 1e6).toFixed(1).padStart(10)}  ` +
  `${(grandCacheWrite / 1e6).toFixed(1).padStart(10)}  ` +
  `${(grandOutput / 1e6).toFixed(1).padStart(8)}  ${fmtUsd(grandTotal).padStart(10)}`
);

// ── Cost component breakdown ────────────────────────────────────────────────
// Use the dominant model's rates for the summary
const dominantModel = byModel[0]?.model || "claude-opus-4-6";
const dp = priceFor(dominantModel) || PRICES["claude-opus-4-6"];

const cw_cost = cost(grandCacheWrite, dp.cache_write);
const cr_cost = cost(grandCacheRead, dp.cache_read);
const in_cost = cost(grandUncached, dp.input);
const out_cost = cost(grandOutput, dp.output);
const total_cost = cw_cost + cr_cost + in_cost + out_cost;

console.log(`\n\n  Cost Components (${dominantModel} rates)\n`);
console.log(`  Cache reads:   ${fmtUsd(cr_cost).padStart(10)}  (${pct(cr_cost, total_cost)}%)`);
console.log(`  Cache writes:  ${fmtUsd(cw_cost).padStart(10)}  (${pct(cw_cost, total_cost)}%)`);
console.log(`  Uncached in:   ${fmtUsd(in_cost).padStart(10)}  (${pct(in_cost, total_cost)}%)`);
console.log(`  Output:        ${fmtUsd(out_cost).padStart(10)}  (${pct(out_cost, total_cost)}%)`);
console.log(`  ${"─".repeat(30)}`);
console.log(`  Total:         ${fmtUsd(total_cost).padStart(10)}`);
console.log(`  Daily avg:     ${fmtUsd(total_cost / daily.length).padStart(10)}`);
console.log(`  Monthly proj:  ${fmtUsd((total_cost / daily.length) * 30).padStart(10)}`);

// ── Prompt size tiers ───────────────────────────────────────────────────────
const tiers = sql(`
  WITH per_msg AS (
    SELECT
      COALESCE(json_extract(data, '$.tokens.cache.read'),0) +
      COALESCE(json_extract(data, '$.tokens.cache.write'),0) +
      COALESCE(json_extract(data, '$.tokens.input'),0) as prompt_size
    FROM message
    WHERE json_extract(data, '$.role') = 'assistant'
      AND json_extract(data, '$.tokens.cache.read') IS NOT NULL
      AND date(time_created/1000, 'unixepoch') >= date('now', '-${DAYS} days')
  )
  SELECT
    CASE
      WHEN prompt_size <= 50000 THEN '0-50k'
      WHEN prompt_size <= 100000 THEN '50-100k'
      WHEN prompt_size <= 150000 THEN '100-150k'
      WHEN prompt_size <= 200000 THEN '150-200k'
      WHEN prompt_size <= 300000 THEN '200-300k'
      ELSE '300k+'
    END as bucket,
    COUNT(*) as msgs,
    MIN(prompt_size) as min_size,
    MAX(prompt_size) as max_size
  FROM per_msg
  GROUP BY bucket ORDER BY MIN(prompt_size);
`);

const totalMsgs = tiers.reduce((sum, t) => sum + t.msgs, 0);
console.log("\n\n  Prompt Size Distribution\n");
console.log("BUCKET       MSGS    %     MIN(k)   MAX(k)");
console.log("-".repeat(50));
for (const t of tiers) {
  console.log(
    `${t.bucket.padEnd(12)} ${String(t.msgs).padStart(5)}  ` +
    `${pct(t.msgs, totalMsgs).padStart(5)}%  ` +
    `${(t.min_size / 1000).toFixed(1).padStart(7)}  ` +
    `${(t.max_size / 1000).toFixed(1).padStart(7)}`
  );
}

console.log(`\nNote: Opus 4.6 and Sonnet 4.6 have flat pricing across the full 1M context window.`);
console.log(`Older models (Opus 4, 4.1) may have different >200k pricing not reflected here.`);

console.log(`\nPeriod: ${daily[0].day} to ${daily[daily.length - 1].day} (${daily.length} active days)`);
console.log(`Database: ${DB_PATH}\n`);
