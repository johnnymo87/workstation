// Pause-sampler: connects to bun/JSC inspector, fires the boot reproducer,
// then repeatedly Debugger.pause -> capture callFrames -> resume.
// Usage: bun client.mjs [samples] [intervalMs]
const WS_URL = "ws://127.0.0.1:9230/wedge";
const SERVE = "http://127.0.0.1:4098";
const DIR = "/home/dev/projects/workstation";
const SAMPLES = parseInt(process.argv[2] ?? "40");
const INTERVAL = parseInt(process.argv[3] ?? "2000");

const scripts = new Map(); // scriptId -> url
let id = 0;
const pending = new Map();
const ws = new WebSocket(WS_URL);

function send(method, params = {}) {
  return new Promise((resolve, reject) => {
    const msgId = ++id;
    pending.set(msgId, { resolve, reject });
    ws.send(JSON.stringify({ id: msgId, method, params }));
    setTimeout(() => {
      if (pending.has(msgId)) { pending.delete(msgId); reject(new Error(`timeout ${method}`)); }
    }, 30000);
  });
}

let pausedResolve = null;
ws.onmessage = (ev) => {
  const m = JSON.parse(ev.data);
  if (m.id && pending.has(m.id)) {
    const p = pending.get(m.id); pending.delete(m.id);
    if (m.error) p.reject(new Error(JSON.stringify(m.error))); else p.resolve(m.result);
    return;
  }
  if (m.method === "Debugger.scriptParsed") {
    scripts.set(m.params.scriptId, m.params.url || m.params.sourceURL || "<anon>");
  } else if (m.method === "Debugger.paused") {
    if (pausedResolve) { pausedResolve(m.params); pausedResolve = null; }
  }
};

const opened = new Promise((r) => (ws.onopen = r));
await opened;
console.error("[client] connected");

await send("Inspector.enable").catch(() => {});
await send("Debugger.enable");
await send("Debugger.setBreakpointsActive", { active: true }).catch(() => {});
await send("Inspector.initialized").catch(() => {});
console.error("[client] debugger enabled, scripts known:", scripts.size);

// Fire reproducer (async; don't await — it may block for the whole burn)
fetch(`${SERVE}/find/file?directory=${encodeURIComponent(DIR)}&query=x`)
  .then((r) => console.error(`[client] reproducer responded ${r.status} at ${new Date().toISOString()}`))
  .catch((e) => console.error("[client] reproducer error", e.message));

// give boot a moment to start
await new Promise((r) => setTimeout(r, 2500));

for (let i = 0; i < SAMPLES; i++) {
  try {
    const pausedP = new Promise((r) => (pausedResolve = r));
    await send("Debugger.pause");
    const paused = await Promise.race([
      pausedP,
      new Promise((_, rej) => setTimeout(() => rej(new Error("pause-timeout")), 15000)),
    ]);
    const frames = (paused.callFrames || []).map((f) => {
      const loc = f.location || {};
      const url = scripts.get(loc.scriptId) || loc.scriptId;
      return `${f.functionName || "<anon>"} @ ${url}:${loc.lineNumber}:${loc.columnNumber ?? ""}`;
    });
    console.log(`--- sample ${i} ${new Date().toISOString()}`);
    console.log(frames.slice(0, 25).join("\n") || "<no frames>");
    await send("Debugger.resume");
  } catch (e) {
    console.log(`--- sample ${i} FAILED: ${e.message}`);
    try { await send("Debugger.resume"); } catch {}
  }
  await new Promise((r) => setTimeout(r, INTERVAL));
}
console.error("[client] done");
process.exit(0);
