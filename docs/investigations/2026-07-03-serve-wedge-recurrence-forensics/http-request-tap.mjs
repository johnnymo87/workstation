const wsUrl = process.argv[2]; const mode = process.argv[3];
setTimeout(() => process.exit(3), 60000);
let id = 0; const pending = new Map();
const ws = new WebSocket(wsUrl);
function send(m, p) { return new Promise((res, rej) => { const i = ++id; pending.set(i, {res, rej}); ws.send(JSON.stringify({id: i, method: m, params: p || {}})); setTimeout(() => { if (pending.has(i)) { pending.delete(i); rej(new Error('to')); } }, 30000); }); }
ws.onmessage = (ev) => { const m = JSON.parse(ev.data); if (m.id && pending.has(m.id)) { const p = pending.get(m.id); pending.delete(m.id); m.error ? p.rej(new Error(JSON.stringify(m.error))) : p.res(m.result); } };
await new Promise((res, rej) => { ws.onopen = res; setTimeout(rej, 5000); });
await send("Runtime.enable").catch(()=>{});
const PATCH = `(function(){
  if (globalThis.__ht) return 'already';
  const http = process.getBuiltinModule('node:http');
  const ring = []; globalThis.__ht = ring;
  const orig = http.Server.prototype.emit;
  http.Server.prototype.emit = function(ev, ...a){
    if (ev === 'request' && a[0] && a[0].url) { ring.push(Date.now() + ' ' + a[0].method + ' ' + a[0].url.slice(0,120)); if (ring.length > 400) ring.shift(); }
    return orig.call(this, ev, ...a);
  };
  return 'patched';
})()`;
const READ = `globalThis.__ht ? globalThis.__ht.join('\\n') : 'NOT PATCHED'`;
const r = await send("Runtime.evaluate", { expression: mode === 'patch' ? PATCH : READ, returnByValue: true });
console.log(r?.result?.value);
process.exit(0);
