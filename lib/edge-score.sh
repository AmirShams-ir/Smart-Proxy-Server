#!/usr/bin/env bash
# Smart Proxy Server - Edge Score
set -Eeuo pipefail
BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$BASE_DIR/config/defaults.conf"

INPUT="${EDGE_PROBE_FILE:-$BASE_DIR/cache/probed.json}"
OUTPUT="${EDGE_WINNERS_FILE:-$BASE_DIR/cache/winners.json}"
TOP="${EDGE_WINNERS:-4}"
mkdir -p "$(dirname "$OUTPUT")"
[[ -f "$INPUT" ]] || { echo "probe result not found: $INPUT" >&2; exit 2; }
python3 - "$INPUT" "$OUTPUT" "$TOP" <<'PY'
import json,sys,time
src,dst,top=sys.argv[1],sys.argv[2],int(sys.argv[3])
d=json.load(open(src,encoding='utf-8'))
items=[]
for x in d.get('candidates',[]):
    # Only candidates that passed the real proxy probe can win.
    if not x.get('proxy_ok'): continue
    r=float(x.get('tcp_ms',9999)); p=float(x.get('proxy_ms',9999)); v=float(x.get('verify_ms',9999))
    # Lower latency is better. Real proxy latency has the largest weight.
    rtt=max(0.0,100.0-min(r,3000.0)/3000.0*100.0)
    verify=max(0.0,100.0-min(v,3000.0)/3000.0*100.0)
    proxy=max(0.0,100.0-min(p,30000.0)/30000.0*100.0)
    score=rtt*.20+verify*.20+proxy*.60
    items.append({**x,'score':round(score,2),'rtt_score':round(rtt,2),'verify_score':round(verify,2),'proxy_score':round(proxy,2)})
items.sort(key=lambda x:(-x['score'],x.get('proxy_ms',999999),x.get('verify_ms',999999),x['ip']))
winners=items[:top]
out={'profile':d.get('profile',''),'port':d.get('port'),'transport':d.get('transport'),'security':d.get('security'),'selected_at':int(time.time()),'winners':winners}
with open(dst,'w',encoding='utf-8') as f: json.dump(out,f,indent=2); f.write('\n')
print(json.dumps({'eligible':len(items),'winners':len(winners),'output':dst},indent=2))
PY
