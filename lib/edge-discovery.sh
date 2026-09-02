#!/usr/bin/env bash
# Smart Proxy Server - Edge Discovery
set -Eeuo pipefail
BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$BASE_DIR/config/defaults.conf"

CIDR_FILE="${EDGE_CIDR_FILE:-$BASE_DIR/config/cf-ipv4.txt}"
CANDIDATES="${EDGE_CANDIDATES:-256}"
PORT="${EDGE_PORT:-443}"
TIMEOUT="${EDGE_TIMEOUT:-2}"
OUT="${EDGE_CANDIDATE_FILE:-$BASE_DIR/cache/candidates.json}"
WORKERS="${EDGE_WORKERS:-32}"
mkdir -p "$(dirname "$OUT")"

[[ $# -ge 1 ]] || { echo "Usage: $0 <profile-file>" >&2; exit 2; }
PROFILE="$1"
[[ -f "$PROFILE" ]] || { echo "profile not found: $PROFILE" >&2; exit 2; }

URI="$(head -n1 "$PROFILE" | tr -d '\r')"
python3 - "$URI" "$CIDR_FILE" "$CANDIDATES" "$PORT" "$OUT" "$TIMEOUT" "$WORKERS" <<'PY'
import concurrent.futures, ipaddress, json, random, re, socket, sys, time
from urllib.parse import parse_qs, unquote, urlparse

uri,cidr_file,count,port,outfile,timeout,workers=sys.argv[1:]
count=int(count); port=int(port); timeout=float(timeout); workers=int(workers)
q=parse_qs(urlparse(uri).query)
transport=q.get('type',[''])[0].lower()
security=q.get('security',[''])[0].lower()
sni=q.get('sni',[''])[0] or urlparse(uri).hostname
host=q.get('host',[''])[0]
networks=[]
for line in open(cidr_file,encoding='utf-8'):
    line=line.strip()
    if not line or line.startswith('#'): continue
    try:
        n=ipaddress.ip_network(line,strict=False)
        if n.version==4: networks.append(n)
    except ValueError: pass
if not networks: raise SystemExit('no IPv4 CIDRs found')
random.shuffle(networks)
seen=set(); ips=[]
for n in networks:
    if len(ips)>=count: break
    if n.num_addresses<=2:
        ip=str(n.network_address)
    else:
        # Sample several addresses per CIDR without requiring full expansion.
        for _ in range(min(16,max(1,(count-len(ips))//max(1,len(networks))))):
            ip=str(n.network_address+random.randrange(1,n.num_addresses-1))
            if ip not in seen:
                seen.add(ip); ips.append(ip)
                if len(ips)>=count: break
while len(ips)<count and networks:
    n=random.choice(networks)
    if n.num_addresses<=2: continue
    ip=str(n.network_address+random.randrange(1,n.num_addresses-1))
    if ip not in seen: seen.add(ip); ips.append(ip)

def probe(ip):
    t=time.perf_counter()
    try:
        with socket.create_connection((ip,port),timeout=timeout):
            ms=(time.perf_counter()-t)*1000
            return {'ip':ip,'port':port,'tcp_ms':round(ms,3),'status':'tcp'}
    except Exception:
        return None

with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as ex:
    results=[r for r in ex.map(probe,ips) if r]
results.sort(key=lambda x:x['tcp_ms'])
data={'profile':profile.split('/')[-1],'timestamp':int(time.time()),'port':port,'transport':transport,'security':security,'sni':sni,'host':host,'candidates':results}
with open(outfile,'w',encoding='utf-8') as f: json.dump(data,f,indent=2); f.write('\n')
print(json.dumps({'tested':len(ips),'alive':len(results),'output':outfile},indent=2))
PY
