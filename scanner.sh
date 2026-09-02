#!/usr/bin/env bash
set -Eeuo pipefail

# ==============================================================================
# Smart Proxy Server - Edge Scanner
# ------------------------------------------------------------------------------
# Stage 1 of the Intelligence Proxy Engine.
#
# Reads Cloudflare IPv4/IPv6 CIDRs, samples usable edge addresses, measures:
#   - RTT
#   - packet loss
#   - jitter
#   - a deterministic regional/colo hint when available
#
# The scanner is intentionally independent from proxy protocols. It only ranks
# edge IPs and writes the best candidates to cache/edges.csv for maker.sh.
# ==============================================================================

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${BASE_DIR}/config"
CACHE_DIR="${BASE_DIR}/cache"
OUTPUT_FILE="${CACHE_DIR}/edges.csv"

IPV4_FILE="${CONFIG_DIR}/cf-ipv4.txt"
IPV6_FILE="${CONFIG_DIR}/cf-ipv6.txt"
ASN_FILE="${CONFIG_DIR}/cf-asn13335.txt"

TOP_N="${EDGE_TOP_N:-10}"
MAX_PROBES="${EDGE_MAX_PROBES:-256}"
PING_COUNT="${EDGE_PING_COUNT:-3}"
TIMEOUT="${EDGE_TIMEOUT:-2}"
WORKERS="${EDGE_WORKERS:-16}"

# Strict acceptance thresholds. A candidate failing any hard gate is removed.
MAX_RTT="${EDGE_MAX_RTT:-180}"
MAX_JITTER="${EDGE_MAX_JITTER:-35}"
MAX_LOSS="${EDGE_MAX_LOSS:-20}"

# Weighted score: lower RTT/loss/jitter is better. Colo is a small tie-breaker.
RTT_WEIGHT="${EDGE_RTT_WEIGHT:-50}"
JITTER_WEIGHT="${EDGE_JITTER_WEIGHT:-25}"
LOSS_WEIGHT="${EDGE_LOSS_WEIGHT:-20}"
COLO_WEIGHT="${EDGE_COLO_WEIGHT:-5}"

TMP_DIR=""
cleanup() {
    [[ -n "${TMP_DIR}" && -d "${TMP_DIR}" ]] && rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

fatal() { printf '[✗] %s\n' "$*" >&2; exit 1; }
info() { printf '[*] %s\n' "$*"; }
success() { printf '[✓] %s\n' "$*"; }
warning() { printf '[!] %s\n' "$*" >&2; }

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || fatal "Required command not found: $1"
}

is_uint() {
    [[ "${1:-}" =~ ^[0-9]+$ ]]
}

is_number() {
    [[ "${1:-}" =~ ^[0-9]+([.][0-9]+)?$ ]]
}

# Pick a reproducible host address from a CIDR without enumerating the whole
# subnet. We intentionally avoid network/broadcast addresses for IPv4.
sample_cidr() {
    local cidr="$1"
    python3 - "$cidr" <<'PY'
import ipaddress
import hashlib
import sys

net = ipaddress.ip_network(sys.argv[1], strict=False)
if net.version == 4:
    # Skip network/broadcast where possible.
    count = net.num_addresses
    if count <= 2:
        candidates = list(net.hosts())
        if not candidates:
            print(net.network_address)
            raise SystemExit
        print(candidates[0])
        raise SystemExit
    usable = count - 2
    digest = hashlib.sha256(str(net).encode()).digest()
    offset = int.from_bytes(digest[:4], 'big') % usable + 1
else:
    # IPv6 ranges are huge; use a stable host offset from the prefix.
    digest = hashlib.sha256(str(net).encode()).digest()
    offset = int.from_bytes(digest[:8], 'big') & ((1 << min(64, net.max_prefixlen - net.prefixlen)) - 1)
print(ipaddress.ip_address(int(net.network_address) + offset))
PY
}

# Try Cloudflare trace through the candidate to obtain colo. This is deliberately
# best-effort and never blocks ranking for long.
probe_colo() {
    local ip="$1"
    local family_flag=""
    [[ "$ip" == *:* ]] && family_flag="-6" || family_flag="-4"

    timeout "${TIMEOUT}s" curl -k -sS --noproxy '*' \
        "$family_flag" --connect-timeout "$TIMEOUT" \
        --interface "$ip" https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null \
        | awk -F= '$1=="colo"{print $2; exit}' || true
}

# Ping a candidate and return: rtt|jitter|loss. Three samples are enough for
# edge discovery; the expensive performance test belongs to score.sh.
probe_ip() {
    local ip="$1"
    local family_flag="-4"
    [[ "$ip" == *:* ]] && family_flag="-6"

    local out received loss avg
    out="$(ping "$family_flag" -n -c "$PING_COUNT" -W "$TIMEOUT" "$ip" 2>/dev/null || true)"
    [[ -n "$out" ]] || return 1

    received="$(awk -F',' '/packet loss/{gsub(/%/,"",$3); print 100-$3; exit}' <<< "$out")"
    if [[ -z "$received" ]]; then
        received="$(awk '/received,/{print $4; exit}' <<< "$out")"
        if [[ -n "$received" ]]; then
            received="$(awk -v r="$received" -v c="$PING_COUNT" 'BEGIN{if(c>0) print 100-(r*100/c); else print 100}')"
        fi
    fi

    # ping summary: min/avg/max/mdev = x/y/z/w ms
    avg="$(awk -F' = ' '/min\/avg\/max|round-trip/{split($2,a," "); split(a[1],v,"/"); print v[2]; exit}' <<< "$out")"
    local mdev
    mdev="$(awk -F' = ' '/min\/avg\/max|round-trip/{split($2,a," "); split(a[1],v,"/"); print v[4]; exit}' <<< "$out")"

    is_number "$received" || received=100
    is_number "$avg" || return 1
    is_number "$mdev" || mdev=0

    loss="$received"
    # mdev is a good cheap dispersion metric and works well as a jitter proxy.
    printf '%s|%s|%s\n' "$avg" "$mdev" "$loss"
}

# Map colo to a tiny preference bonus. We do not make geography dominate the
# score because the local RTT is the primary signal.
colo_score() {
    local colo="${1:-UNKNOWN}"
    case "$colo" in
        LHR|FRA|AMS|CDG|BER|MAD|MRS|VIE|ZRH|WAW|PRG|ARN|HEL|IST|DXB|DOH|BAH|RUH|KWI|JED|TLV|TBS|GYD)
            printf '100\n' ;;
        NRT|HKG|SIN|ICN|TYO|KIX|SYD|MEL|BOM|DEL|BLR|MAA|BKK|KUL|CGK|MNL)
            printf '95\n' ;;
        IAD|ORD|DFW|ATL|MIA|SEA|SFO|LAX|DEN|YYZ|MEX|GRU|EZE|SCL)
            printf '85\n' ;;
        *)
            printf '50\n' ;;
    esac
}

score_candidate() {
    local rtt="$1" jitter="$2" loss="$3" colo="$4"
    local rtt_score jitter_score loss_score colo_score_value

    # Clamp each component to a 0..100 quality score.
    rtt_score="$(awk -v x="$rtt" -v max="$MAX_RTT" 'BEGIN{ s=100-(x/max*100); if(s<0)s=0; if(s>100)s=100; printf "%.4f",s }')"
    jitter_score="$(awk -v x="$jitter" -v max="$MAX_JITTER" 'BEGIN{ s=100-(x/max*100); if(s<0)s=0; if(s>100)s=100; printf "%.4f",s }')"
    loss_score="$(awk -v x="$loss" -v max="$MAX_LOSS" 'BEGIN{ s=100-(x/max*100); if(s<0)s=0; if(s>100)s=100; printf "%.4f",s }')"
    colo_score_value="$(colo_score "$colo")"

    awk -v r="$rtt_score" -v j="$jitter_score" -v l="$loss_score" -v c="$colo_score_value" \
        -v rw="$RTT_WEIGHT" -v jw="$JITTER_WEIGHT" -v lw="$LOSS_WEIGHT" -v cw="$COLO_WEIGHT" \
        'BEGIN{ printf "%.2f", (r*rw + j*jw + l*lw + c*cw)/(rw+jw+lw+cw) }'
}

read_cidrs() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    awk '
        /^[[:space:]]*#/ {next}
        /^[[:space:]]*$/ {next}
        /^[[:space:]]*[0-9A-Fa-f:.]+\/[0-9]+[[:space:]]*$/ {
            gsub(/[[:space:]]+/, "", $0)
            print $0
        }
    ' "$file"
}

###############################################################################
# Main
###############################################################################

require_cmd awk
require_cmd ping
require_cmd python3
require_cmd sort
require_cmd head
require_cmd timeout
require_cmd curl

is_uint "$TOP_N" || fatal "EDGE_TOP_N must be an integer"
is_uint "$MAX_PROBES" || fatal "EDGE_MAX_PROBES must be an integer"
is_uint "$PING_COUNT" || fatal "EDGE_PING_COUNT must be an integer"

[[ -f "$IPV4_FILE" ]] || fatal "Missing $IPV4_FILE"
[[ -f "$IPV6_FILE" ]] || warning "Missing $IPV6_FILE; IPv6 scan will be skipped."
[[ -f "$ASN_FILE" ]] || warning "Missing $ASN_FILE; ASN metadata file is not available."

mkdir -p "$CACHE_DIR"
TMP_DIR="$(mktemp -d /tmp/smartproxy-scanner.XXXXXX)"
CIDR_FILE="${TMP_DIR}/cidrs.txt"
TARGET_FILE="${TMP_DIR}/targets.txt"
RESULTS_FILE="${TMP_DIR}/results.txt"

: > "$CIDR_FILE"
read_cidrs "$IPV4_FILE" >> "$CIDR_FILE"
read_cidrs "$IPV6_FILE" >> "$CIDR_FILE" 2>/dev/null || true

[[ -s "$CIDR_FILE" ]] || fatal "No valid CIDRs found."

info "Building edge sample from Cloudflare CIDRs..."
python3 - "$CIDR_FILE" "$TARGET_FILE" "$MAX_PROBES" <<'PY'
import ipaddress
import hashlib
import sys

src, dst, limit = sys.argv[1], sys.argv[2], int(sys.argv[3])
items = []
seen = set()
with open(src, encoding='utf-8') as f:
    for raw in f:
        cidr = raw.strip()
        if not cidr:
            continue
        net = ipaddress.ip_network(cidr, strict=False)
        # One deterministic sample per announced CIDR.
        if net.version == 4:
            hosts = list(net.hosts()) if net.num_addresses <= 2**16 else None
            if hosts:
                ip = hosts[len(hosts)//2]
            else:
                usable = max(1, net.num_addresses - 2)
                off = int.from_bytes(hashlib.sha256(cidr.encode()).digest()[:4], 'big') % usable + 1
                ip = ipaddress.ip_address(int(net.network_address)+off)
        else:
            width = min(64, 128 - net.prefixlen)
            off = int.from_bytes(hashlib.sha256(cidr.encode()).digest()[:8], 'big') & ((1 << width)-1)
            ip = ipaddress.ip_address(int(net.network_address)+off)
        if str(ip) not in seen:
            seen.add(str(ip))
            items.append((str(ip), str(net), net.version))

# Add extra points from the largest IPv4 ranges. This creates geographical
# diversity without exploding into millions of probes.
for cidr in list(dict.fromkeys(x[1] for x in items)):
    try:
        net = ipaddress.ip_network(cidr, strict=False)
    except ValueError:
        continue
    if net.version != 4 or net.prefixlen > 20:
        continue
    probes = min(4, max(1, net.num_addresses // 4096))
    for idx in range(probes):
        usable = max(1, net.num_addresses - 2)
        off = 1 + ((idx + 1) * usable // (probes + 1))
        ip = ipaddress.ip_address(int(net.network_address)+off)
        if str(ip) not in seen:
            seen.add(str(ip))
            items.append((str(ip), str(net), net.version))

items.sort(key=lambda x: hashlib.sha256((x[1]+"|"+x[0]).encode()).hexdigest())
items = items[:limit]
with open(dst, 'w', encoding='utf-8') as f:
    for ip, cidr, version in items:
        f.write(f"{ip}|{cidr}|IPv{version}\n")
print(len(items))
PY

TARGET_COUNT="$(wc -l < "$TARGET_FILE" | tr -d ' ')"
(( TARGET_COUNT > 0 )) || fatal "No edge targets generated."
info "Probing ${TARGET_COUNT} edge candidates (ping=${PING_COUNT}, timeout=${TIMEOUT}s, workers=${WORKERS})..."

# Bash-only worker pool. Each worker writes one line to its own shard to avoid
# concurrent append races on the Orange Pi's filesystem.
for n in $(seq 1 "$WORKERS"); do : > "${TMP_DIR}/result.${n}"; done

worker_id=0
while IFS='|' read -r ip cidr family; do
    worker_id=$((worker_id % WORKERS + 1))
    (
        metrics="$(probe_ip "$ip" || true)"
        [[ -n "$metrics" ]] || exit 0
        IFS='|' read -r rtt jitter loss <<< "$metrics"

        # Hard gates keep scanner strict and ensure only genuinely good edges
        # move on to maker/validator stages.
        awk -v r="$rtt" -v j="$jitter" -v l="$loss" \
            -v mr="$MAX_RTT" -v mj="$MAX_JITTER" -v ml="$MAX_LOSS" \
            'BEGIN{exit !(r<=mr && j<=mj && l<=ml)}' || exit 0

        colo="$(probe_colo "$ip")"
        [[ -n "$colo" ]] || colo="UNKNOWN"
        score="$(score_candidate "$rtt" "$jitter" "$loss" "$colo")"
        printf '%s|%s|%s|%s|%s|%s|%s\n' "$ip" "$family" "$colo" "$rtt" "$jitter" "$loss" "$score" \
            >> "${TMP_DIR}/result.${worker_id}"
    ) &

    # Limit concurrent jobs by waiting after every WORKERS launches.
    if (( worker_id == WORKERS )); then
        wait || true
    fi
done < "$TARGET_FILE"
wait || true

cat "${TMP_DIR}"/result.* 2>/dev/null | sort -t'|' -k7,7nr -k4,4n -k5,5n -k6,6n > "$RESULTS_FILE" || true

TOTAL_VALID="$(wc -l < "$RESULTS_FILE" | tr -d ' ')"
(( TOTAL_VALID > 0 )) || fatal "No edge survived strict thresholds (RTT<=${MAX_RTT}ms, jitter<=${MAX_JITTER}ms, loss<=${MAX_LOSS}%)."

# Keep one best measurement per IP, then the final top N.
DEDUP_FILE="${TMP_DIR}/dedup.txt"
awk -F'|' '!seen[$1]++' "$RESULTS_FILE" | head -n "$TOP_N" > "$DEDUP_FILE"

TMP_OUTPUT="${OUTPUT_FILE}.tmp"
printf 'rank,ip,family,colo,rtt_ms,jitter_ms,loss_pct,score\n' > "$TMP_OUTPUT"
rank=0
while IFS='|' read -r ip family colo rtt jitter loss score; do
    rank=$((rank + 1))
    printf '%d,%s,%s,%s,%s,%s,%s,%s\n' \
        "$rank" "$ip" "$family" "$colo" "$rtt" "$jitter" "$loss" "$score" >> "$TMP_OUTPUT"
done < "$DEDUP_FILE"
mv "$TMP_OUTPUT" "$OUTPUT_FILE"

success "Scanner complete: ${rank} best edges written to ${OUTPUT_FILE}"
printf '\n'
printf '%-5s %-40s %-7s %-9s %-10s %-8s %-8s\n' \
    "Rank" "IP" "Colo" "RTT" "Jitter" "Loss" "Score"
printf '%s\n' '----------------------------------------------------------------------------------------------------------'
awk -F',' 'NR>1 {printf "%-5s %-40s %-7s %-9sms %-10sms %-8s %-8s\n", $1,$2,$4,$5,$6,$7,$8}' "$OUTPUT_FILE"
