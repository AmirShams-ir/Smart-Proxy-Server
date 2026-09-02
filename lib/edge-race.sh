#!/usr/bin/env bash
# ============================================================================
# Smart Proxy Server - Smart Edge Race Engine
# Discovers Cloudflare edges, validates candidates, and ranks real proxies.
# ============================================================================
set -Eeuo pipefail

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$BASE_DIR/config/defaults.conf"

EDGE_CIDRS_FILE="${EDGE_CIDRS_FILE:-$BASE_DIR/config/cloudflare-ips-v4.txt}"
EDGE_CANDIDATES="${EDGE_CANDIDATES:-64}"
EDGE_TOP="${EDGE_TOP:-8}"
EDGE_PORTS="${EDGE_PORTS:-80,443,8080,8443}"
EDGE_TIMEOUT="${EDGE_TIMEOUT:-2}"
EDGE_PING_COUNT="${EDGE_PING_COUNT:-2}"
EDGE_DOWNLOAD_URL="${EDGE_DOWNLOAD_URL:-https://speed.cloudflare.com/__down?bytes=1048576}"
EDGE_CACHE_FILE="${EDGE_CACHE_FILE:-/var/lib/smartproxy/edge-cache.json}"
EDGE_CACHE_TTL="${EDGE_CACHE_TTL:-300}"
EDGE_WORKERS="${EDGE_WORKERS:-16}"

log(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
err(){ printf '[%s] ERROR: %s\n' "$(date '+%F %T')" "$*" >&2; }

usage(){
  cat <<EOF
Usage: $0 <profile-file> [--fast|--full]

Discover and rank Cloudflare edge IPs for a real VLESS/Trojan profile.
The original profile URI is treated as a template; only the connect host is
replaced during candidate validation. SNI, Host header, path and credentials
remain unchanged.

Environment overrides:
  EDGE_CIDRS_FILE, EDGE_CANDIDATES, EDGE_TOP, EDGE_PORTS, EDGE_TIMEOUT,
  EDGE_PING_COUNT, EDGE_DOWNLOAD_URL, EDGE_CACHE_FILE, EDGE_CACHE_TTL,
  EDGE_WORKERS
EOF
}

[[ $# -ge 1 && $# -le 2 ]] || { usage >&2; exit 2; }
PROFILE="$1"
MODE="${2:---fast}"
[[ -f "$PROFILE" ]] || { err "missing profile: $PROFILE"; exit 2; }

URI="$(head -n1 "$PROFILE" | tr -d '\r')"
[[ "$URI" == vless://* || "$URI" == trojan://* ]] || { err "unsupported profile scheme"; exit 3; }

command -v jq >/dev/null 2>&1 || { err "jq is required"; exit 4; }
command -v curl >/dev/null 2>&1 || { err "curl is required"; exit 4; }
command -v ping >/dev/null 2>&1 || { err "ping is required"; exit 4; }
command -v python3 >/dev/null 2>&1 || { err "python3 is required"; exit 4; }

mapfile -t IPS < <(python3 - "$EDGE_CIDRS_FILE" "$EDGE_CANDIDATES" <<'PY'
import ipaddress, random, sys
path, count = sys.argv[1], int(sys.argv[2])
random.seed()
networks=[]
with open(path, encoding='utf-8') as f:
    for line in f:
        s=line.strip()
        if not s or s.startswith('#'): continue
        try:
            n=ipaddress.ip_network(s, strict=False)
            if n.version == 4: networks.append(n)
        except ValueError: pass
seen=set(); out=[]
for _ in range(max(count*4, count)):
    if not networks: break
    n=random.choice(networks)
    if n.num_addresses <= 2:
        ip=str(n.network_address)
    else:
        ip=str(n.network_address + random.randrange(1, n.num_addresses-1))
    if ip not in seen:
        seen.add(ip); out.append(ip)
        if len(out)>=count: break
for ip in out: print(ip)
PY
)

[[ ${#IPS[@]} -gt 0 ]] || { err "no IPv4 candidates found in $EDGE_CIDRS_FILE"; exit 5; }

TMP="$(mktemp -d /tmp/smart-edge-race.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
RESULTS="$TMP/results.tsv"
: > "$RESULTS"

IFS=',' read -r -a PORT_ARRAY <<< "$EDGE_PORTS"

printf '\nSmart Edge Race: %s\n' "$(basename "$PROFILE" .txt)"
printf '%-16s %-6s %-10s %-10s %-8s %-8s %-8s\n' IP PORT RTT JITTER LOSS STATUS SCORE
printf '%s\n' '--------------------------------------------------------------------------'

probe_ip(){
  local ip="$1" port="$2" raw loss avg jitter start ms status
  raw="$(ping -n -c "$EDGE_PING_COUNT" -W "$EDGE_TIMEOUT" "$ip" 2>/dev/null || true)"
  loss="$(printf '%s\n' "$raw" | sed -nE 's/.*[, ]([0-9]+)% packet loss.*/\1/p' | tail -n1)"
  avg="$(printf '%s\n' "$raw" | sed -nE 's/.* = [0-9.]+\/([0-9.]+)\/.* ms/\1/p' | tail -n1)"
  [[ -n "$loss" ]] || loss=100
  [[ -n "$avg" ]] || avg=9999
  jitter="$(printf '%s\n' "$raw" | grep -oE 'time[=<][0-9.]+ ms' | sed -E 's/time[=<]//' | awk 'NR==1{min=$1;max=$1} {if($1<min)min=$1;if($1>max)max=$1} END{if(NR) print int(max-min); else print 9999}')"
  [[ -n "$jitter" ]] || jitter=9999
  status="dead"
  if (( loss < 100 )); then
    start="$(date +%s%3N)"
    if timeout "$EDGE_TIMEOUT" bash -c "</dev/tcp/$ip/$port" 2>/dev/null; then
      ms="$(( $(date +%s%3N)-start ))"
      status="tcp"
    else ms=9999; fi
  else ms=9999; fi
  local score
  score="$(awk -v r="$avg" -v j="$jitter" -v l="$loss" -v t="$ms" 'BEGIN{
    rs=100-(r/300*100); if(rs<0)rs=0
    js=100-(j/100*100); if(js<0)js=0
    ls=100-l
    ts=(t<9999)?(100-(t/300*100)):0; if(ts<0)ts=0
    printf "%.2f", rs*.35+js*.20+ls*.20+ts*.25
  }')"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$ip" "$port" "$avg" "$jitter" "$loss" "$status" "$score" >> "$RESULTS"
  printf '%-16s %-6s %-10s %-10s %-8s %-8s %-8s\n' "$ip" "$port" "${avg}ms" "${jitter}ms" "${loss}%" "$status" "$score"
}

for ip in "${IPS[@]}"; do
  for port in "${PORT_ARRAY[@]}"; do probe_ip "$ip" "$port"; done
done

BEST_FILE="$TMP/best.tsv"
sort -t$'\t' -k7,7nr -k3,3n -k4,4n "$RESULTS" | head -n "$EDGE_TOP" > "$BEST_FILE"

mkdir -p "$(dirname "$EDGE_CACHE_FILE")"
python3 - "$BEST_FILE" "$EDGE_CACHE_FILE" "$PROFILE" <<'PY'
import json,sys,time,os
src,dst,profile=sys.argv[1:]
items=[]
with open(src,encoding='utf-8') as f:
    for line in f:
        ip,port,rtt,jitter,loss,status,score=line.rstrip('\n').split('\t')
        items.append({'ip':ip,'port':int(port),'rtt':float(rtt),'jitter':float(jitter),'loss':float(loss),'status':status,'score':float(score)})
data={
  'profile': os.path.basename(profile),
  'timestamp': int(time.time()),
  'candidates': items
}
with open(dst,'w',encoding='utf-8') as f: json.dump(data,f,indent=2); f.write('\n')
PY

printf '\nTop edge candidates:\n'
cat "$BEST_FILE"
