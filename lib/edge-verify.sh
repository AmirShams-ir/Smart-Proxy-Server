#!/usr/bin/env bash
# Smart Proxy Server - Edge Verification
set -Eeuo pipefail
BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$BASE_DIR/config/defaults.conf"

CANDIDATE_FILE="${EDGE_CANDIDATE_FILE:-$BASE_DIR/cache/candidates.json}"
OUT="${EDGE_VERIFIED_FILE:-$BASE_DIR/cache/verified.json}"
TIMEOUT="${EDGE_TIMEOUT:-2}"
TOP="${EDGE_VERIFY_TOP:-100}"
mkdir -p "$(dirname "$OUT")"

[[ -f "$CANDIDATE_FILE" ]] || { echo "candidate file not found: $CANDIDATE_FILE" >&2; exit 2; }
python3 - "$CANDIDATE_FILE" "$OUT" "$TIMEOUT" "$TOP" <<'PY'
import json, socket, ssl, sys, time, http.client
from urllib.parse import urlparse

src,dst,timeout,top=sys.argv[1],sys.argv[2],float(sys.argv[3]),int(sys.argv[4])
data=json.load(open(src,encoding='utf-8'))
port=int(data.get('port',443)); transport=data.get('transport',''); security=data.get('security',''); sni=data.get('sni') or '' ; host=data.get('host') or sni
items=data.get('candidates',[])[:top]

def verify(item):
    ip=item['ip']; t=time.perf_counter()
    try:
        if security=='tls' or port in {443,2053,2083,2087,2096,8443}:
            ctx=ssl.create_default_context()
            with socket.create_connection((ip,port),timeout=timeout) as raw:
                with ctx.wrap_socket(raw,server_hostname=sni or host or ip) as ss:
                    cert_ok=bool(ss.cipher())
                    ms=(time.perf_counter()-t)*1000
        else:
            with socket.create_connection((ip,port),timeout=timeout):
                cert_ok=True; ms=(time.perf_counter()-t)*1000
        return {**item,'verify_ms':round(ms,3),'tls_ok':cert_ok,'status':'verified'}
    except Exception as e:
        return None

verified=[]
for item in items:
    r=verify(item)
    if r: verified.append(r)
verified.sort(key=lambda x:(x.get('verify_ms',999999),x['tcp_ms']))
outdata={**{k:data.get(k) for k in ('profile','timestamp','port','transport','security','sni','host')},'verified_at':int(time.time()),'candidates':verified}
with open(dst,'w',encoding='utf-8') as f: json.dump(outdata,f,indent=2); f.write('\n')
print(json.dumps({'checked':len(items),'verified':len(verified),'output':dst},indent=2))
PY
