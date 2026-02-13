#!/usr/bin/env node
// Analyzes OpenCode prompt caching efficiency from ccusage-opencode data.
// Usage: node analyze.mjs
//        REDUCTION=0.30 node analyze.mjs   # custom write-reduction scenario

import { execSync } from "child_process";

const raw = execSync("ccusage-opencode daily --json 2>&1", {
  encoding: "utf8",
});
// ccusage-opencode prefixes log lines before JSON; extract the JSON object
const jsonStart = raw.indexOf("{");
if (jsonStart === -1) {
  console.error("No JSON output from ccusage-opencode");
  process.exit(1);
}
const data = JSON.parse(raw.slice(jsonStart));

// --- Per-day breakdown ---
console.log("DATE        COST       READ%  WRITE%  UNCACHED%  MODELS");
console.log("-".repeat(80));
for (const d of data.daily) {
  const inp = d.inputTokens;
  const cw = d.cacheCreationTokens;
  const cr = d.cacheReadTokens;
  const total_in = inp + cw + cr;
  const rr = total_in > 0 ? ((cr / total_in) * 100).toFixed(1) : "0.0";
  const wr = total_in > 0 ? ((cw / total_in) * 100).toFixed(1) : "0.0";
  const ur = total_in > 0 ? ((inp / total_in) * 100).toFixed(1) : "0.0";
  console.log(
    `${d.date}  $${d.totalCost.toFixed(2).padStart(8)}  ${rr.padStart(5)}%  ${wr.padStart(5)}%    ${ur.padStart(5)}%  ${d.modelsUsed.join(",")}`,
  );
}

// --- Totals ---
const t = data.totals;
const total_in = t.inputTokens + t.cacheCreationTokens + t.cacheReadTokens;
console.log("-".repeat(80));
console.log(`TOTALS: $${t.totalCost.toFixed(2)}`);
console.log(
  `  Input: ${t.inputTokens.toLocaleString()} | Output: ${t.outputTokens.toLocaleString()}`,
);
console.log(
  `  Cache write: ${t.cacheCreationTokens.toLocaleString()} (${((t.cacheCreationTokens / total_in) * 100).toFixed(1)}%)`,
);
console.log(
  `  Cache read:  ${t.cacheReadTokens.toLocaleString()} (${((t.cacheReadTokens / total_in) * 100).toFixed(1)}%)`,
);
console.log(
  `  Uncached:    ${t.inputTokens.toLocaleString()} (${((t.inputTokens / total_in) * 100).toFixed(1)}%)`,
);

// --- Cost breakdown at Opus rates ---
// Anthropic pricing per million tokens: https://docs.anthropic.com/en/docs/about-claude/pricing
const prices = {
  "claude-opus-4-6": {
    input: 15,
    output: 75,
    cache_write: 18.75,
    cache_read: 1.5,
  },
  "claude-sonnet-4-6": {
    input: 3,
    output: 15,
    cache_write: 3.75,
    cache_read: 0.3,
  },
  "claude-haiku-3.5": {
    input: 0.8,
    output: 4,
    cache_write: 1.0,
    cache_read: 0.08,
  },
};
const p = prices["claude-opus-4-6"]; // conservative default
const cw_cost = (t.cacheCreationTokens * p.cache_write) / 1e6;
const cr_cost = (t.cacheReadTokens * p.cache_read) / 1e6;
const in_cost = (t.inputTokens * p.input) / 1e6;
const out_cost = (t.outputTokens * p.output) / 1e6;
const total = cw_cost + cr_cost + in_cost + out_cost;

console.log("");
console.log("Cost breakdown (Opus 4.6 rates):");
console.log(
  `  Cache writes: $${cw_cost.toFixed(2)} (${((cw_cost / total) * 100).toFixed(1)}%)`,
);
console.log(
  `  Cache reads:  $${cr_cost.toFixed(2)} (${((cr_cost / total) * 100).toFixed(1)}%)`,
);
console.log(
  `  Uncached in:  $${in_cost.toFixed(2)} (${((in_cost / total) * 100).toFixed(1)}%)`,
);
console.log(
  `  Output:       $${out_cost.toFixed(2)} (${((out_cost / total) * 100).toFixed(1)}%)`,
);

// --- Savings estimate ---
const r = parseFloat(process.env.REDUCTION || "0.44");
const saved_cw = t.cacheCreationTokens * r;
const saved_cost = (saved_cw * p.cache_write) / 1e6;
const extra_read = (saved_cw * p.cache_read) / 1e6;
const net = saved_cost - extra_read;
const days = data.daily.length;

console.log("");
console.log(`If cache writes reduced ${(r * 100).toFixed(0)}%:`);
console.log(`  Saved write cost:  $${saved_cost.toFixed(2)}`);
console.log(`  Extra read cost:   $${extra_read.toFixed(2)}`);
console.log(
  `  Net savings:       $${net.toFixed(2)}/period (${((net / t.totalCost) * 100).toFixed(1)}% of reported total)`,
);
console.log(`  Projected monthly: ~$${((net / days) * 30).toFixed(0)}`);
console.log("");
console.log(
  `Period: ${data.daily[0].date} to ${data.daily[data.daily.length - 1].date} (${days} active days)`,
);
