#!/usr/bin/env bash
set -Eeuo pipefail

# ==============================================================================
# Smart Proxy Server - Edge Scanner
# ------------------------------------------------------------------------------
# Stage 1 of the Intelligence Proxy Engine.
#
# Reads Cloudflare ASN/CIDR source files, generates real host addresses, probes
# them quickly and writes ONLY the selected IP addresses to cache/edges.csv.
# No proxy protocol/configuration is handled here.
# ==============================================================================

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${BASE_DIR}/config"
CACHE_DIR="${BASE_DIR}/cache"
OUTPUT_FILE="${CACHE_DIR}/edges.csv"

IPV4_FILE="${CONFIG_DIR}/cf-ipv4.txt"
IPV6_FILE="${CONFIG_DIR}/cf-ipv6.txt"
ASN_FILE="${CONFIG_DIR}/cf-asn13335.txt"

TOP_N="${EDGE_TOP_N:-10}"
MAX_PROBES="${EDGE_MAX_PROBES:-512}"
PING_COUNT="${EDGE_PING_COUNT:-3}"
TIMEOUT="${EDGE_TIMEOUT:-2}"
WORKERS="${EDGE_WORKERS:-8}"

# Strict hard gates.
MAX_RTT="${EDGE_MAX_RTT:-180}"
MAX_JITTER="${EDGE_MAX_JITTER:-35}"
MAX_LOSS="${EDGE_MAX_LOSS:-20}"

# Quality weights. Colo is only a small tie-breaker.
RTT_WEIGHT="${EDGE_RTT_WEIGHT:-50}"
JITTER_WEIGHT="${EDGE_JITTER_WEIGHT:-25}"
LOSS_WEIGHT="${EDGE_LOSS_WEIGHT:-20}"
COLO_WEIGHT="${EDGE_COLO_WEIGHT:-5}"

TMP_DIR=""
cleanup() {
    [[ -n "${TMP_DIR}" && -d "${TMP_DIR}" ]] && rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fatal()   { printf '[✗] %s\n' "$*" >&2; exit 1; }
info()    { printf '[*] %s\n' "$*"; }
warning() { printf '[!] %s\n' "$*" >&2; }
success() { printf '[✓] %s\n' "$*"; }

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || fatal "Required command not found: $1"
}

is_uint() {
    [[ "${1:-}" =~ ^[0-9]+$ ]] && (( 10#$1 > 0 ))
}

is_number() {
    [[ "${1:-}" =~ ^[0-9]+([.][0-9]+)?$ ]]
}

read_cidrs() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    awk '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*$/  { next }
        /^[[:space:]]*[0-9A-Fa-f:.]+\/[0-9]+[[:space:]]*$/ {
            gsub(/[[:space:]]+/, "", $0)
            print
        }
    ' "$file"
}

# Generate valid host IPs only. For IPv4, network and broadcast addresses are
# always excluded when the subnet has usable hosts. Several deterministic sample
# points are generated from every sufficiently large CIDR, giving diversity.
build_targets() {
    local src="$1" dst="$2"
    python3 - "$src" "$dst" "$MAX_PROBES" <<'PY'
import hashlib
import ipaddress
import sys

src, dst, limit = sys.argv[1], sys.argv[2], int(sys.argv[3])
seen = set()
targets = []

with open(src, encoding="utf-8") as fh:
    cidrs = [line.strip() for line in fh if line.strip()]

for cidr in cidrs:
    net = ipaddress.ip_network(cidr, strict=False)

    if net.version == 4:
        if net.num_addresses == 1:
            offsets = [0]
        elif net.num_addresses == 2:
            offsets = [0, 1]
        else:
            usable = net.num_addresses - 2
            # Avoid edge-of-range addresses and use multiple spread-out samples.
            raw = hashlib.sha256(cidr.encode()).digest()
            seed = int.from_bytes(raw[:8], "big")
            points = 8 if usable >= 8 else usable
            offsets = []
            for i in range(points):
                base = 1 + ((i + 1) * usable // (points + 1))
                # Small deterministic perturbation while staying inside hosts.
                jitter = ((seed >> ((i % 8) * 8)) & 0xFF) % max(1, usable // 32)
                off = min(usable, max(1, base + jitter - (jitter // 2)))
                offsets.append(off)
    else:
        width = min(64, 128 - net.prefixlen)
        seed = int.from_bytes(hashlib.sha256(cidr.encode()).digest()[:8], "big")
        offsets = []
        points = 8
        mask = (1 << width) - 1 if width > 0 else 0
        for i in range(points):
            value = (seed + (i + 1) * 0x9E3779B97F4A7C15) & mask if width else 0
            offsets.append(value)

    for offset in offsets:
        ip = ipaddress.ip_address(int(net.network_address) + int(offset))
        key = str(ip)
        if key not in seen:
            seen.add(key)
            targets.append((key, str(net), f"IPv{net.version}"))

# Stable shuffle makes runs different across CIDRs while remaining deterministic.
targets.sort(key=lambda x: hashlib.sha256((x[1] + "|" + x[0]).encode()).hexdigest())

with open(dst, "w", encoding="utf-8") as fh:
    for ip, cidr, family in targets[:limit]:
        fh.write(f"{ip}|{cidr}|{family}\n")
PY
}

# Return avg_rtt|jitter|loss. ICMP is used only as a cheap discovery signal;
# the next validator stage will perform protocol-specific connectivity tests.
probe_ip() {
    local ip="$1"
    local family="-4"
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

    is_number "$avg" || return 1
    is_number "$mdev" || mdev=0
    is_uint "$transmitted" || return 1
    is_uint "$received" || return 1
    (( transmitted > 0 )) || return 1

    loss="$(awk -v t="$transmitted" -v r="$received" 'BEGIN{printf "%.2f",((t-r)*100)/t}')"
    printf '%s|%s|%s\n' "$avg" "$mdev" "$loss"
}

# Cloudflare trace is best-effort. It is NOT required for a candidate to survive.
# A missing colo gets a neutral score so geography never defeats good latency.
probe_colo() {
    local ip="$1"
    local url='https://www.cloudflare.com/cdn-cgi/trace'
    timeout "$TIMEOUT" curl -k -sS --noproxy '*' \
        --connect-timeout "$TIMEOUT" \
        --resolve "www.cloudflare.com:443:${ip}" \
        "$url" 2>/dev/null |
        awk -F= '$1 == "colo" {print $2; exit}' || true
}

colo_score() {
    case "${1:-UNKNOWN}" in
        GYD|TBS|IST|DXB|DOH|BAH|RUH|KWI|JED|TLV|FRA|AMS|LHR|CDG|BER|MAD|MRS|VIE|ZRH|WAW|PRG|ARN|HEL)
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
    local rs js ls cs

    rs="$(awk -v x="$rtt" -v m="$MAX_RTT" \
        'BEGIN{s=100-(x/m*100);if(s<0)s=0;if(s>100)s=100;printf "%.4f",s}')"
    js="$(awk -v x="$jitter" -v m="$MAX_JITTER" \
        'BEGIN{s=100-(x/m*100);if(s<0)s=0;if(s>100)s=100;printf "%.4f",s}')"
    ls="$(awk -v x="$loss" -v m="$MAX_LOSS" \
        'BEGIN{s=100-(x/m*100);if(s<0)s=0;if(s>100)s=100;printf "%.4f",s}')"
    cs="$(colo_score "$colo")"

    awk -v r="$rs" -v j="$js" -v l="$ls" -v c="$cs" \
        -v rw="$RTT_WEIGHT" -v jw="$JITTER_WEIGHT" -v lw="$LOSS_WEIGHT" -v cw="$COLO_WEIGHT" \
        'BEGIN{printf "%.2f",(r*rw+j*jw+l*lw+c*cw)/(rw+jw+lw+cw)}'
}

require_cmd awk
require_cmd ping
require_cmd python3
require_cmd sort
require_cmd head
require_cmd timeout
require_cmd curl
require_cmd mktemp
require_cmd wc

is_uint "$TOP_N"      || fatal "EDGE_TOP_N must be a positive integer"
is_uint "$MAX_PROBES" || fatal "EDGE_MAX_PROBES must be a positive integer"
is_uint "$PING_COUNT" || fatal "EDGE_PING_COUNT must be a positive integer"
is_uint "$WORKERS"    || fatal "EDGE_WORKERS must be a positive integer"

[[ -f "$IPV4_FILE" ]] || fatal "Missing $IPV4_FILE"
[[ -f "$IPV6_FILE" ]] || warning "Missing $IPV6_FILE; IPv6 scan will be skipped."
if [[ -f "$ASN_FILE" ]]; then
    grep -Eq '^[[:space:]]*AS13335[[:space:]]*$' "$ASN_FILE" || \
        warning "$ASN_FILE does not contain AS13335; continuing with CIDR sources."
else
    warning "Missing $ASN_FILE; continuing with CIDR sources."
fi

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
for n in $(seq 1 "$WORKERS"); do
    : > "${TMP_DIR}/result.${n}"
done

job=0
while IFS='|' read -r ip cidr family; do
    job=$((job + 1))
    shard=$(( (job - 1) % WORKERS + 1 ))
    (
        metrics="$(probe_ip "$ip" || true)"
        [[ -n "$metrics" ]] || exit 0
        IFS='|' read -r rtt jitter loss <<< "$metrics"

        awk -v r="$rtt" -v j="$jitter" -v l="$loss" \
            -v mr="$MAX_RTT" -v mj="$MAX_JITTER" -v ml="$MAX_LOSS" \
            'BEGIN{exit !(r<=mr && j<=mj && l<=ml)}' || exit 0

        colo="$(probe_colo "$ip")"
        [[ -n "$colo" ]] || colo="UNKNOWN"
        score="$(score_candidate "$rtt" "$jitter" "$loss" "$colo")"
        printf '%s|%s|%s\n' "$ip" "$score" "$colo" >> "${TMP_DIR}/result.${shard}"
    ) &

    if (( job % WORKERS == 0 )); then
        wait || true
    fi
done < "$TARGET_FILE"
wait || true

cat "${TMP_DIR}"/result.* 2>/dev/null |
    sort -t'|' -k2,2nr -k1,1 > "$RESULTS_FILE" || true

TOTAL_VALID="$(wc -l < "$RESULTS_FILE" | tr -d ' ')"
(( TOTAL_VALID > 0 )) || fatal "No edge survived strict thresholds (RTT<=${MAX_RTT}ms, jitter<=${MAX_JITTER}ms, loss<=${MAX_LOSS}%)."

# One row per IP, then top N. The scanner output intentionally contains only IPs.
awk -F'|' '!seen[$1]++' "$RESULTS_FILE" | head -n "$TOP_N" > "$DEDUP_FILE"
SELECTED="$(wc -l < "$DEDUP_FILE" | tr -d ' ')"

# The scanner contract is exactly one column: ip.
TMP_OUTPUT="${OUTPUT_FILE}.tmp"
printf 'ip\n' > "$TMP_OUTPUT"
while IFS='|' read -r ip score colo; do
    printf '%s\n' "$ip" >> "$TMP_OUTPUT"
done < "$DEDUP_FILE"
mv "$TMP_OUTPUT" "$OUTPUT_FILE"

success "Scanner complete: ${SELECTED} best edges written to ${OUTPUT_FILE}"
printf '\n%-5s %-40s\n' "Rank" "IP"
printf '%s\n' '--------------------------------------------------'
awk 'NR>1{printf "%-5s %-40s\n",NR-1,$1}' "$OUTPUT_FILE"
