#!/usr/bin/env bash
set -Eeuo pipefail

# ==============================================================================
# Smart Proxy Server - Edge Scanner
# ------------------------------------------------------------------------------
# Stage 1 of the Intelligence Proxy Engine.
#
# Reads Cloudflare CIDRs, probes a bounded sample of edge addresses and keeps
# only the strict top-N candidates using RTT, packet loss, jitter and colo.
# This stage knows nothing about VLESS/Trojan/sing-box configurations.
# ==============================================================================

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${BASE_DIR}/config"
CACHE_DIR="${BASE_DIR}/cache"
OUTPUT_FILE="${CACHE_DIR}/edges.csv"

IPV4_FILE="${CONFIG_DIR}/cf-ipv4.txt"
IPV6_FILE="${CONFIG_DIR}/cf-ipv6.txt"
ASN_FILE="${CONFIG_DIR}/cf-asn13335.txt"

TOP_N="${EDGE_TOP_N:-10}"
MAX_PROBES="${EDGE_MAX_PROBES:-128}"
PING_COUNT="${EDGE_PING_COUNT:-3}"
TIMEOUT="${EDGE_TIMEOUT:-2}"
WORKERS="${EDGE_WORKERS:-8}"

# Strict hard gates. A candidate failing any gate never reaches maker.sh.
MAX_RTT="${EDGE_MAX_RTT:-180}"
MAX_JITTER="${EDGE_MAX_JITTER:-35}"
MAX_LOSS="${EDGE_MAX_LOSS:-20}"

# Weighted quality score. RTT dominates; colo is intentionally a small factor.
RTT_WEIGHT="${EDGE_RTT_WEIGHT:-50}"
JITTER_WEIGHT="${EDGE_JITTER_WEIGHT:-25}"
LOSS_WEIGHT="${EDGE_LOSS_WEIGHT:-20}"
COLO_WEIGHT="${EDGE_COLO_WEIGHT:-5}"

TMP_DIR=""
cleanup() { [[ -n "${TMP_DIR}" && -d "${TMP_DIR}" ]] && rm -rf "$TMP_DIR"; }
trap cleanup EXIT

fatal(){ printf '[✗] %s\n' "$*" >&2; exit 1; }
info(){ printf '[*] %s\n' "$*"; }
success(){ printf '[✓] %s\n' "$*"; }
warning(){ printf '[!] %s\n' "$*" >&2; }
require_cmd(){ command -v "$1" >/dev/null 2>&1 || fatal "Required command not found: $1"; }
is_uint(){ [[ "${1:-}" =~ ^[0-9]+$ ]] && (( 10#$1 > 0 )); }
is_number(){ [[ "${1:-}" =~ ^[0-9]+([.][0-9]+)?$ ]]; }

# Probe the candidate IP itself while preserving Cloudflare SNI/Host.
probe_colo(){
    local ip="$1"
    timeout "${TIMEOUT}s" curl -k -sS --noproxy '*' \
        --connect-timeout "$TIMEOUT" \
        --resolve "www.cloudflare.com:443:${ip}" \
        'https://www.cloudflare.com/cdn-cgi/trace' 2>/dev/null \
        | awk -F= '$1=="colo" {print $2; exit}' || true
}

# Return avg_rtt|jitter(mdev)|loss_percent.
probe_ip(){
    local ip="$1" family="-4"
    [[ "$ip" == *:* ]] && family="-6"
    local out summary avg mdev transmitted received loss
    out="$(ping "$family" -n -c "$PING_COUNT" -W "$TIMEOUT" "$ip" 2>/dev/null || true)"
    [[ -n "$out" ]] || return 1
    summary="$(awk -F' = ' '/min\/avg\/max|rtt min\/avg\/max/{print $2; exit}' <<< "$out")"
    [[ -n "$summary" ]] || return 1
    avg="$(awk '{split($1,v,"/"); print v[2]}' <<< "$summary")"
    mdev="$(awk '{split($1,v,"/"); print v[4]}' <<< "$summary")"
    transmitted="$(awk '/packets transmitted/{print $1; exit}' <<< "$out")"
    received="$(awk '/packets transmitted/{print $4; exit}' <<< "$out")"
    is_number "$transmitted" && is_number "$received" || return 1
    (( transmitted > 0 )) || return 1
    loss="$(awk -v t="$transmitted" -v r="$received" 'BEGIN{printf "%.2f",((t-r)*100)/t}')"
    is_number "$avg" || return 1
    is_number "$mdev" || mdev=0
    printf '%s|%s|%s\n' "$avg" "$mdev" "$loss"
}

colo_score(){
    case "${1:-UNKNOWN}" in
        GYD|TBS|IST|DXB|DOH|BAH|RUH|KWI|JED|TLV|FRA|AMS|LHR|CDG|BER|MAD|MRS|VIE|ZRH|WAW|PRG|ARN|HEL) printf '100\n';;
        NRT|HKG|SIN|ICN|TYO|KIX|SYD|MEL|BOM|DEL|BLR|MAA|BKK|KUL|CGK|MNL) printf '95\n';;
        IAD|ORD|DFW|ATL|MIA|SEA|SFO|LAX|DEN|YYZ|MEX|GRU|EZE|SCL) printf '85\n';;
        *) printf '50\n';;
    esac
}

score_candidate(){
    local rtt="$1" jitter="$2" loss="$3" colo="$4"
    local rs js ls cs
    rs="$(awk -v x="$rtt" -v m="$MAX_RTT" 'BEGIN{s=100-(x/m*100);if(s<0)s=0;if(s>100)s=100;printf "%.4f",s}')"
    js="$(awk -v x="$jitter" -v m="$MAX_JITTER" 'BEGIN{s=100-(x/m*100);if(s<0)s=0;if(s>100)s=100;printf "%.4f",s}')"
    ls="$(awk -v x="$loss" -v m="$MAX_LOSS" 'BEGIN{s=100-(x/m*100);if(s<0)s=0;if(s>100)s=100;printf "%.4f",s}')"
    cs="$(colo_score "$colo")"
    awk -v r="$rs" -v j="$js" -v l="$ls" -v c="$cs" \
        -v rw="$RTT_WEIGHT" -v jw="$JITTER_WEIGHT" -v lw="$LOSS_WEIGHT" -v cw="$COLO_WEIGHT" \
        'BEGIN{printf "%.2f",(r*rw+j*jw+l*lw+c*cw)/(rw+jw+lw+cw)}'
}

read_cidrs(){
    local file="$1"
    [[ -f "$file" ]] || return 0
    awk '
      /^[[:space:]]*#/ {next}
      /^[[:space:]]*$/ {next}
      /^[[:space:]]*[0-9A-Fa-f:.]+\/[0-9]+[[:space:]]*$/ {gsub(/[[:space:]]+/,"",$0); print}
    ' "$file"
}

build_targets(){
    local src="$1" dst="$2"
    python3 - "$src" "$dst" "$MAX_PROBES" <<'PY'
import hashlib, ipaddress, sys
src, dst, limit = sys.argv[1], sys.argv[2], int(sys.argv[3])
seen=set(); items=[]
with open(src,encoding='utf-8') as f:
    cidrs=[x.strip() for x in f if x.strip()]
for cidr in cidrs:
    net=ipaddress.ip_network(cidr,strict=False)
    if net.version==4:
        usable=max(1,net.num_addresses-2)
        offsets=[1+usable//2]
        if net.num_addresses>=4096:
            offsets += [1+usable//4,1+(3*usable)//4]
    else:
        width=min(32,128-net.prefixlen)
        offsets=[int.from_bytes(hashlib.sha256(cidr.encode()).digest()[:8],'big') & ((1<<width)-1)]
    for off in offsets:
        if net.version==4 and net.num_addresses>2:
            ip=ipaddress.ip_address(int(net.network_address)+min(off,net.num_addresses-2))
        else:
            ip=ipaddress.ip_address(int(net.network_address)+off)
        key=str(ip)
        if key not in seen:
            seen.add(key); items.append((key,str(net),f'IPv{net.version}'))
items.sort(key=lambda x:hashlib.sha256((x[1]+'|'+x[0]).encode()).hexdigest())
with open(dst,'w',encoding='utf-8') as f:
    for ip,cidr,family in items[:limit]:
        f.write(f'{ip}|{cidr}|{family}\n')
PY
}

require_cmd awk; require_cmd ping; require_cmd python3; require_cmd sort; require_cmd head; require_cmd timeout; require_cmd curl; require_cmd mktemp
is_uint "$TOP_N" || fatal "EDGE_TOP_N must be a positive integer"
is_uint "$MAX_PROBES" || fatal "EDGE_MAX_PROBES must be a positive integer"
is_uint "$PING_COUNT" || fatal "EDGE_PING_COUNT must be a positive integer"
is_uint "$WORKERS" || fatal "EDGE_WORKERS must be a positive integer"
[[ -f "$IPV4_FILE" ]] || fatal "Missing $IPV4_FILE"
[[ -f "$IPV6_FILE" ]] || warning "Missing $IPV6_FILE; IPv6 scan will be skipped."
[[ -f "$ASN_FILE" ]] || warning "Missing $ASN_FILE; continuing without ASN metadata."
[[ ! -f "$ASN_FILE" ]] || grep -Eq '^AS13335$' "$ASN_FILE" || warning "ASN metadata does not contain AS13335."

mkdir -p "$CACHE_DIR"
TMP_DIR="$(mktemp -d /tmp/smartproxy-scanner.XXXXXX)"
CIDR_FILE="${TMP_DIR}/cidrs.txt"
TARGET_FILE="${TMP_DIR}/targets.txt"
RESULTS_FILE="${TMP_DIR}/results.txt"
DEDUP_FILE="${TMP_DIR}/dedup.txt"
read_cidrs "$IPV4_FILE" > "$CIDR_FILE"
read_cidrs "$IPV6_FILE" >> "$CIDR_FILE" 2>/dev/null || true
[[ -s "$CIDR_FILE" ]] || fatal "No valid Cloudflare CIDRs found."

info "Reading Cloudflare ASN/CIDR sources..."
build_targets "$CIDR_FILE" "$TARGET_FILE"
TARGET_COUNT="$(wc -l < "$TARGET_FILE" | tr -d ' ')"
(( TARGET_COUNT > 0 )) || fatal "No edge targets generated."
(( WORKERS > TARGET_COUNT )) && WORKERS="$TARGET_COUNT"
info "Probing ${TARGET_COUNT} edge candidates (ping=${PING_COUNT}, timeout=${TIMEOUT}s, workers=${WORKERS})..."
for n in $(seq 1 "$WORKERS"); do : > "${TMP_DIR}/result.${n}"; done

job=0
while IFS='|' read -r ip cidr family; do
    job=$((job+1)); shard=$(( (job-1) % WORKERS + 1 ))
    (
      metrics="$(probe_ip "$ip" || true)"; [[ -n "$metrics" ]] || exit 0
      IFS='|' read -r rtt jitter loss <<< "$metrics"
      awk -v r="$rtt" -v j="$jitter" -v l="$loss" -v mr="$MAX_RTT" -v mj="$MAX_JITTER" -v ml="$MAX_LOSS" 'BEGIN{exit !(r<=mr && j<=mj && l<=ml)}' || exit 0
      colo="$(probe_colo "$ip")"; [[ -n "$colo" ]] || colo="UNKNOWN"
      score="$(score_candidate "$rtt" "$jitter" "$loss" "$colo")"
      printf '%s|%s|%s|%s|%s|%s|%s\n' "$ip" "$family" "$colo" "$rtt" "$jitter" "$loss" "$score" >> "${TMP_DIR}/result.${shard}"
    ) &
    if (( job % WORKERS == 0 )); then wait || true; fi
done < "$TARGET_FILE"
wait || true

cat "${TMP_DIR}"/result.* 2>/dev/null | sort -t'|' -k7,7nr -k4,4n -k5,5n -k6,6n > "$RESULTS_FILE" || true
TOTAL_VALID="$(wc -l < "$RESULTS_FILE" | tr -d ' ')"
(( TOTAL_VALID > 0 )) || fatal "No edge survived strict thresholds (RTT<=${MAX_RTT}ms, jitter<=${MAX_JITTER}ms, loss<=${MAX_LOSS}%)."
awk -F'|' '!seen[$1]++' "$RESULTS_FILE" | head -n "$TOP_N" > "$DEDUP_FILE"

TMP_OUTPUT="${OUTPUT_FILE}.tmp"
printf 'rank,ip,family,colo,rtt_ms,jitter_ms,loss_pct,score\n' > "$TMP_OUTPUT"
rank=0
while IFS='|' read -r ip family colo rtt jitter loss score; do
    rank=$((rank+1))
    printf '%d,%s,%s,%s,%s,%s,%s,%s\n' "$rank" "$ip" "$family" "$colo" "$rtt" "$jitter" "$loss" "$score" >> "$TMP_OUTPUT"
done < "$DEDUP_FILE"
mv "$TMP_OUTPUT" "$OUTPUT_FILE"

success "Scanner complete: ${rank} best edges written to ${OUTPUT_FILE}"
printf '%-5s %-40s %-7s %-9s %-10s %-8s %-8s\n' Rank IP Colo RTT Jitter Loss Score
printf '%s\n' '----------------------------------------------------------------------------------------------------------'
awk -F',' 'NR>1{printf "%-5s %-40s %-7s %-9sms %-10sms %-8s %-8s\n",$1,$2,$4,$5,$6,$7,$8}' "$OUTPUT_FILE"
