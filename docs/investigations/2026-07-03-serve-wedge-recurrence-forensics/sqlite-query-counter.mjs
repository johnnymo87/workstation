// Usage: node sqlpatch.mjs <ws-url> patch|read
const wsUrl = process.argv[2];
const mode = process.argv[3];
setTimeout(() => { console.log("GLOBAL TIMEOUT"); process.exit(3); }, 120000);
let id = 0; const pending = new Map();
const ws = new WebSocket(wsUrl);
function send(method, params) {
  return new Promise((resolve, reject) => {
    const msgId = ++id;
    pending.set(msgId, { resolve, reject });
    ws.send(JSON.stringify({ id: msgId, method, params: params || {} }));
    setTimeout(() => { if (pending.has(msgId)) { pending.delete(msgId); reject(new Error("timeout " + method)); } }, 90000);
  });
}
ws.onmessage = (ev) => {
  const m = JSON.parse(ev.data);
  if (m.id && pending.has(m.id)) { const p = pending.get(m.id); pending.delete(m.id); m.error ? p.reject(new Error(JSON.stringify(m.error))) : p.resolve(m.result); }
};
ws.onerror = (e) => { console.log("ws error", e?.message || ""); process.exit(2); };
await new Promise((res, rej) => { ws.onopen = res; setTimeout(rej, 5000); }).catch(() => { console.log("open timeout"); process.exit(2); });
await send("Inspector.enable").catch(() => {});
await send("Runtime.enable").catch(() => {});
await send("Inspector.initialized").catch(() => {});

const PATCH = `(function(){
  try{
    if (globalThis.__q) return 'already-patched';
    Error.stackTraceLimit = 60;
    const mod = (process.getBuiltinModule && process.getBuiltinModule('bun:sqlite')) || require('bun:sqlite');
    const DB = mod.Database;
    const m = new Map(); globalThis.__q = m; globalThis.__qt0 = Date.now(); globalThis.__qb = new Map();
    const gb = Map.groupBy.bind(Map); globalThis.__gb = {n:0, stacks:[]};
    Map.groupBy = function(...a){ globalThis.__gb.n++; if(globalThis.__gb.stacks.length<3 && (globalThis.__gb.n===1||globalThis.__gb.n===20||globalThis.__gb.n===200)) globalThis.__gb.stacks.push(String(new Error().stack).slice(0,1500)); return gb(...a); };
    for (const name of ['query','prepare']) {
      const orig = DB.prototype[name];
      if (!orig) continue;
      DB.prototype[name] = function(sql){
        const k = name + ': ' + String(sql).replace(/\\s+/g,' ').slice(0,220);
        let e = m.get(k);
        if(!e){ e={n:0,first:Date.now(),last:0,stacks:[]}; m.set(k,e); }
        e.n++; e.last=Date.now();
        const bucket = Math.floor((Date.now()-globalThis.__qt0)/10000);
        globalThis.__qb.set(bucket, (globalThis.__qb.get(bucket)||0)+1);
        if((e.n===1||e.n===500||e.n===2500) && e.stacks.length<3){ e.stacks.push(String(new Error().stack).slice(0,2000)); }
        return orig.apply(this,arguments);
      };
    }
    return 'patched';
  }catch(err){ return 'ERR '+(err && err.message); }
})()`;

const READ = `(function(){
  if(!globalThis.__q) return 'NOT PATCHED';
  const rows=[...globalThis.__q].map(([k,v])=>({sql:k,n:v.n,first:v.first-globalThis.__qt0,last:v.last-globalThis.__qt0,stacks:v.stacks}));
  rows.sort((a,b)=>b.n-a.n);
  const total=rows.reduce((s,r)=>s+r.n,0);
  const buckets=[...globalThis.__qb].sort((a,b)=>a[0]-b[0]).map(([b,n])=>b+':'+n).join(' ');
  return JSON.stringify({total, buckets, groupBy: globalThis.__gb, top:rows.slice(0,12)});
})()`;

const res = await send("Runtime.evaluate", { expression: mode === "patch" ? PATCH : READ, returnByValue: true });
const val = res?.result?.value;
if (mode === "read" && typeof val === "string" && val.startsWith("{")) {
  const data = JSON.parse(val);
  console.log("TOTAL queries:", data.total);
  console.log("10s-buckets:", data.buckets);
  console.log("Map.groupBy calls:", data.groupBy.n);
  for (const s of (data.groupBy.stacks||[])) console.log("  --gb stack--\n" + s.split("\n").slice(0,10).map(l=>"   "+l).join("\n"));
  for (const r of data.top) {
    console.log(`\n== n=${r.n} first=+${r.first}ms last=+${r.last}ms\n   ${r.sql}`);
    for (const s of r.stacks) console.log("   ---stack---\n" + s.split("\n").slice(0, 14).map(l => "   " + l).join("\n"));
  }
} else {
  console.log(val);
}
process.exit(0);
