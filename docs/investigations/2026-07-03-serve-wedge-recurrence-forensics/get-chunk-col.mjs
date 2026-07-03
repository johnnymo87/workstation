const wsUrl = process.argv[2];
const urlSub = process.argv[3];
const line = parseInt(process.argv[4], 10);
const col = parseInt(process.argv[5], 10);
const span = parseInt(process.argv[6] || "600", 10);
setTimeout(() => { console.log("GLOBAL TIMEOUT"); process.exit(3); }, 60000);
let id = 0; const pending = new Map(); let target = null;
const ws = new WebSocket(wsUrl);
function send(method, params) {
  return new Promise((resolve, reject) => {
    const msgId = ++id;
    pending.set(msgId, { resolve, reject });
    ws.send(JSON.stringify({ id: msgId, method, params: params || {} }));
    setTimeout(() => { if (pending.has(msgId)) { pending.delete(msgId); reject(new Error("timeout " + method)); } }, 30000);
  });
}
ws.onmessage = (ev) => {
  const m = JSON.parse(ev.data);
  if (m.id && pending.has(m.id)) { const p = pending.get(m.id); pending.delete(m.id); m.error ? p.reject(new Error(JSON.stringify(m.error))) : p.resolve(m.result); return; }
  if (m.method === "Debugger.scriptParsed") { const u = m.params.url || ""; if (u.includes(urlSub)) target = m.params.scriptId; }
};
ws.onerror = () => { console.log("ws error"); process.exit(2); };
await new Promise((res, rej) => { ws.onopen = res; setTimeout(rej, 5000); }).catch(() => { console.log("open timeout"); process.exit(2); });
await send("Inspector.enable").catch(() => {});
await send("Debugger.enable");
await send("Inspector.initialized").catch(() => {});
await new Promise((r) => setTimeout(r, 3000));
if (!target) { console.log("script not found"); process.exit(1); }
const res = await send("Debugger.getScriptSource", { scriptId: target });
const lines = (res.scriptSource || "").split("\n");
const l = lines[line] || "";
console.log("line " + line + " length=" + l.length);
console.log(l.slice(Math.max(0, col - span), col + span));
process.exit(0);
