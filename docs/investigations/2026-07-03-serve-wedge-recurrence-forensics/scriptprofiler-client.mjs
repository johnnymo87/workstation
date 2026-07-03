// ScriptProfiler capture: JSC sampling profiler via inspector protocol.
// Usage: node/bun sp.mjs <wsUrl> <trackMs>
const wsUrl = process.argv[2];
const TRACK_MS = parseInt(process.argv[3] || "8000", 10);
setTimeout(() => { console.log("GLOBAL TIMEOUT"); process.exit(3); }, 300000);
let id = 0;
const pending = new Map();
const ws = new WebSocket(wsUrl);
function send(method, params = {}) {
  return new Promise((resolve, reject) => {
    const msgId = ++id;
    pending.set(msgId, { resolve, reject });
    ws.send(JSON.stringify({ id: msgId, method, params }));
    setTimeout(() => { if (pending.has(msgId)) { pending.delete(msgId); reject(new Error("timeout " + method)); } }, 240000);
  });
}
const scripts = new Map();
let trackingDone = null;
const trackingP = new Promise((r) => (trackingDone = r));
ws.onmessage = (ev) => {
  const m = JSON.parse(ev.data);
  if (m.id && pending.has(m.id)) {
    const p = pending.get(m.id); pending.delete(m.id);
    if (m.error) p.reject(new Error(JSON.stringify(m.error))); else p.resolve(m.result);
    return;
  }
  if (m.method === "Debugger.scriptParsed") scripts.set(m.params.scriptId, m.params.url || "<anon>");
  else if (m.method === "ScriptProfiler.trackingComplete") trackingDone(m.params);
};
await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej; setTimeout(rej, 5000); })
  .catch(() => { console.log("ws open failed"); process.exit(2); });
console.log("connected " + new Date().toISOString());
await send("Inspector.enable").catch(() => {});
// Debugger.enable gives us scriptId->url mapping for sample frames
await send("Debugger.enable").catch((e) => console.log("dbg enable: " + e.message));
await send("Inspector.initialized").catch(() => {});
console.log("enabled " + new Date().toISOString() + " scripts=" + scripts.size);
await send("ScriptProfiler.startTracking", { includeSamples: true });
console.log("tracking started " + new Date().toISOString());
await new Promise((r) => setTimeout(r, TRACK_MS));
await send("ScriptProfiler.stopTracking", {});
console.log("stop requested " + new Date().toISOString());
const result = await Promise.race([trackingP, new Promise((_, rej) => setTimeout(() => rej(new Error("trackingComplete timeout")), 240000))]);
const samples = result?.samples?.stackTraces || [];
console.log("stackTraces: " + samples.length);
// Histogram of frames across all samples
const counts = new Map();
const topCounts = new Map();
for (const st of samples) {
  const frames = st.frames || [];
  if (frames.length) {
    const f = frames[0];
    const key = (f.name || "<anon>") + " @ " + (scripts.get(String(f.sourceID)) || f.sourceID) + ":" + f.line;
    topCounts.set(key, (topCounts.get(key) || 0) + 1);
  }
  const seen = new Set();
  for (const f of frames) {
    const key = (f.name || "<anon>") + " @ " + (scripts.get(String(f.sourceID)) || f.sourceID) + ":" + f.line;
    if (seen.has(key)) continue;
    seen.add(key);
    counts.set(key, (counts.get(key) || 0) + 1);
  }
}
console.log("== top-of-stack histogram:");
[...topCounts.entries()].sort((a, b) => b[1] - a[1]).slice(0, 15).forEach(([k, v]) => console.log(v + "\t" + k));
console.log("== present-anywhere-in-stack histogram:");
[...counts.entries()].sort((a, b) => b[1] - a[1]).slice(0, 30).forEach(([k, v]) => console.log(v + "\t" + k));
// Dump a few full stacks
console.log("== example stacks:");
for (const st of samples.filter((s) => (s.frames || []).length > 3).slice(0, 5)) {
  console.log("---");
  for (const f of st.frames.slice(0, 25)) {
    console.log((f.name || "<anon>") + " @ " + (scripts.get(String(f.sourceID)) || f.sourceID) + ":" + f.line);
  }
}
process.exit(0);
