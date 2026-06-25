#!/usr/bin/env bash
# serve-profile.sh — re-runnable snapshot to isolate the serve-0 stall MECHANISM (xci9).
# Baseline at a HEALTHY time; re-run when a serve feels slow EOD; diff.
# Mechanism fingerprints (no perf needed):
#   fan-out      : main JS thread CPU high + high event_rate_M + high client N + health latency up
#   jsdiff/spin  : main JS thread CPU ~100% one core, LOW event_rate_M (bursty, correlates w/ edits)
#   GC           : HeapHelper threads hot + high RSS/swap; main thread spiky not steady
#   accept-stall : listen_RecvQ > 0 (kernel backlog), health TIMEOUT
set -u
PORTS=(4096 4097 4098 4099)
DB=/home/dev/projects/pigeon/packages/daemon/data/pigeon-daemon.db
TS=$(date -u +%Y%m%dT%H%M%SZ)
OUT=/tmp/serve-profile-$TS.txt
CLK=$(getconf CLK_TCK)

# ticks(pid) -> "<tid> <comm> <utime+stime_ticks>" per thread, comm-space-safe
ticks() {
  local pid=$1 t tid content rest comm
  for t in /proc/$pid/task/*/stat; do
    [ -r "$t" ] || continue
    tid=$(basename "$(dirname "$t")")
    content=$(<"$t"); rest=${content##*\) }        # fields from 'state' onward
    set -- $rest; local u=${12} s=${13}            # field14 utime, field15 stime
    comm=$(<"/proc/$pid/task/$tid/comm" 2>/dev/null)
    echo "$tid ${comm// /_} $((u+s))"
  done
}

{
echo "=== serve-profile $TS (host $(hostname)) ==="
echo "loadavg=$(cut -d' ' -f1-3 /proc/loadavg)  CLK_TCK=$CLK"
echo
for p in "${PORTS[@]}"; do
  pid=$(ss -tlnp 2>/dev/null | grep ":$p " | grep -oP 'pid=\K[0-9]+' | head -1)
  echo "----- serve :$p  pid=${pid:-NONE} -----"
  [ -z "$pid" ] && { echo "  (no listener)"; echo; continue; }
  etime=$(ps -o etime= -p "$pid" 2>/dev/null | tr -d ' ')
  rss=$(awk '/VmRSS/{print int($2/1024)}' /proc/$pid/status 2>/dev/null)
  swap=$(awk '/VmSwap/{print int($2/1024)}' /proc/$pid/status 2>/dev/null)
  thr=$(ls /proc/$pid/task 2>/dev/null | wc -l)
  kids=$(pgrep -P "$pid" 2>/dev/null | wc -l)
  echo "  uptime=$etime rss=${rss}MB swap=${swap:-0}MB threads=$thr child_procs(LSP)=$kids"

  # CPU over 1s: whole-proc + per-thread
  read u1 s1 < <(awk '{print $14,$15}' /proc/$pid/stat 2>/dev/null)
  declare -A A=(); while read -r tid comm tk; do A["$tid"]="$tk"; done < <(ticks "$pid")
  sleep 1
  read u2 s2 < <(awk '{print $14,$15}' /proc/$pid/stat 2>/dev/null)
  cpu=$(awk -v a=$((u1+s1)) -v b=$((u2+s2)) -v c=$CLK 'BEGIN{printf "%.0f",(b-a)*100.0/c}')
  echo "  proc_cpu=${cpu}% of one core"
  echo "  hottest threads (comm %core):"
  while read -r tid comm tk; do d=$((tk-${A[$tid]:-0})); echo "$d $tid $comm"; done < <(ticks "$pid") \
    | sort -rn | head -4 | awk -v c=$CLK '$1>0{printf "    %-18s tid=%s %.0f%%\n",$3,$2,$1*100.0/c}'
  unset A

  est=$(ss -tan 2>/dev/null | awk -v port=":$p" '$1=="ESTAB" && ($4 ~ port"$"||$4 ~ port" ")' | wc -l)
  cw=$(ss -tan 2>/dev/null | awk -v port=":$p" '$1=="CLOSE-WAIT" && ($4 ~ port"$"||$4 ~ port" ")' | wc -l)
  recvq=$(ss -tln 2>/dev/null | grep ":$p " | awk '{print $2}' | head -1)
  echo "  conns: ESTAB=$est CLOSE_WAIT=$cw listen_RecvQ=${recvq:-?}"

  lat=""
  for i in 1 2 3 4 5; do
    t=$(curl -s -o /dev/null -w "%{time_total}" --max-time 8 "http://127.0.0.1:$p/global/health" 2>/dev/null || echo TIMEOUT)
    lat="$lat $t"
  done
  echo "  health_latency_s(x5):$lat  (snappy<0.05 | stalled>1/TIMEOUT)"

  m=$(timeout 5 curl -sN "http://127.0.0.1:$p/global/event" 2>/dev/null | grep -c '^data:')
  echo "  event_rate_M=~$(awk -v m=${m:-0} 'BEGIN{printf "%.1f",m/4.0}')/s (4s sample; fanout cost = N x M)"
  echo
done

echo "=== pigeon session_assignment distribution (concentration) ==="
bun -e '
const {Database}=require("bun:sqlite");
const db=new Database(process.argv[1],{readonly:true});
const ep=Object.fromEntries(db.query("select serve_id,endpoint from serve_instance").all().map(r=>[r.serve_id,r.endpoint]));
for (const r of db.query("select desired_serve_id s,state,count(*) c from session_assignment group by desired_serve_id,state order by s,state").all())
  console.log(`  ${r.s} (${ep[r.s]||"?"}) ${r.state}: ${r.c}`);
' "$DB" 2>/dev/null || echo "  (pigeon DB query failed)"
} | tee "$OUT"
echo; echo "WROTE: $OUT"
