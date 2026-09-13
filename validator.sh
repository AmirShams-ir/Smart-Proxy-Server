#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================================
# Smart Proxy Server - Candidate Validator
#
# Stage 1:
#   cache/generated/*.json -> fast real-proxy connectivity test (parallel=6)
#   -> cache/validated/index.tsv
#
# This validator intentionally keeps Stage 1 simple. Each generated outbound
# fragment is wrapped in a temporary sing-box config and tested using the same
# SOCKS5/curl method as test.sh. Stage 2 scoring can be added on this stable
# foundation later.
# ============================================================================

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$BASE_DIR/config/defaults.conf"

GENERATED_DIR="$BASE_DIR/cache/generated"
VALIDATED_DIR="$BASE_DIR/cache/validated"
WORK_DIR="$BASE_DIR/cache/validator"
RESULT_FILE="$WORK_DIR/results.tsv"
LOCK_FILE="/run/smartproxy-validator.lock"
LOCK_META="/run/smartproxy-validator.lock.info"

PARALLEL="${VALIDATOR_PARALLEL:-6}"
TIMEOUT="${VALIDATOR_STAGE1_TIMEOUT:-8}"
SING_BOX="${SING_BOX_BIN:-sing-box}"
TARGET_URL="${VALIDATOR_URL:-https://cp.cloudflare.com/generate_204}"

fatal(){ printf '[✗] %s\n' "$*" >&2; exit 1; }
warning(){ printf '[!] %s\n' "$*" >&2; }
info(){ printf '[*] %s\n' "$*"; }
success(){ printf '[✓] %s\n' "$*"; }
require_cmd(){ command -v "$1" >/dev/null 2>&1 || fatal "Missing required command: $1"; }
is_number(){ [[ "${1:-}" =~ ^[0-9]+([.][0-9]+)?$ ]]; }

mkdir -p "$VALIDATED_DIR" "$WORK_DIR" "$WORK_DIR/failures"
rm -f "$RESULT_FILE" "$VALIDATED_DIR"/*.json
: > "$RESULT_FILE"

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    lock_pid="$(cat "$LOCK_META" 2>/dev/null || true)"
    if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
        warning "Another validator run is already active (PID $lock_pid)."
        exit 0
    fi
    warning "Validator lock metadata is stale; continuing."
fi
printf '%s\n' "$$" > "$LOCK_META"
trap 'rm -f "$LOCK_META"' EXIT

require_cmd "$SING_BOX"
require_cmd python3
require_cmd awk
require_cmd sort
require_cmd curl
require_cmd ss
require_cmd flock
require_cmd sleep

[[ -d "$GENERATED_DIR" ]] || fatal "Missing generated candidate directory: $GENERATED_DIR"

shopt -s nullglob
CANDIDATES=("$GENERATED_DIR"/*.json)
shopt -u nullglob
[[ ${#CANDIDATES[@]} -gt 0 ]] || fatal "No JSON candidates found in $GENERATED_DIR"

(( PARALLEL > 0 )) || fatal "VALIDATOR_PARALLEL must be > 0"

next_port(){ echo $((19080 + $1)); }

metadata(){
    python3 - "$1" <<'PY'
import json, sys
with open(sys.argv[1], encoding='utf-8') as fh:
    d=json.load(fh)
transport=(d.get('transport') or {}).get('type', 'tcp')
tls=(d.get('tls') or {})
print(f"name={d.get('tag','candidate')}")
print(f"server={d.get('server','')}")
print(f"port={d.get('server_port','')}")
print(f"transport={transport}")
print(f"security={'tls' if tls.get('enabled') else 'none'}")
PY
}

probe_once(){
    local candidate="$1" timeout_s="$2" run_dir="$3" socks_port="$4"
    local config="$run_dir/config.json"
    local pid="" start_ms end_ms response_ms curl_rc http_code selected_tag

    python3 - "$candidate" "$config" "$socks_port" <<'PY'
import json
import sys
from pathlib import Path

src = Path(sys.argv[1])
out = Path(sys.argv[2])
port = int(sys.argv[3])

with src.open(encoding='utf-8') as fh:
    candidate = json.load(fh)

if not isinstance(candidate, dict):
    raise SystemExit('candidate JSON root must be an object')

outbound = dict(candidate)
tag = str(outbound.pop('tag', 'validator-out')) or 'validator-out'

cfg = {
    'log': {'level': 'error'},
    'inbounds': [{
        'type': 'socks',
        'tag': 'validator-in',
        'listen': '127.0.0.1',
        'listen_port': port,
    }],
    'outbounds': [
        dict(outbound, tag=tag),
        {'type': 'direct', 'tag': 'direct'},
        {'type': 'block', 'tag': 'block'},
    ],
    'route': {
        'final': tag,
        'rules': [],
    },
}

out.write_text(json.dumps(cfg, ensure_ascii=False), encoding='utf-8')
print(tag)
PY

    selected_tag="$(tail -n 1 "$run_dir/config.json" 2>/dev/null || true)"
    if ! "$SING_BOX" check -c "$config" >"$run_dir/check.out" 2>&1; then
        printf 'status=invalid\nrtt=\nhttp=\nreason=sing-box-check\n' > "$run_dir/result"
        return 1
    fi

    "$SING_BOX" run -c "$config" >"$run_dir/probe.out" 2>"$run_dir/probe.err" &
    pid=$!

    ready=0
    for _ in {1..20}; do
        if ss -lnt 2>/dev/null | grep -Eq '(^|:)127\.0\.0\.1:'"$socks_port"'[[:space:]]|(^|:)0\.0\.0\.0:'"$socks_port"'[[:space:]]'; then
            ready=1
            break
        fi
        if ! kill -0 "$pid" 2>/dev/null; then
            break
        fi
        sleep 0.05
    done

    if (( ready == 0 )); then
        printf 'status=failed\nrtt=0\nhttp=000\nreason=listener-not-ready\n' > "$run_dir/result"
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        return 1
    fi

    start_ms="$(date +%s%3N)"
    set +e
    curl -4 -L \
        --max-time "$timeout_s" \
        --connect-timeout 5 \
        --socks5-hostname "127.0.0.1:$socks_port" \
        -sS -o /dev/null \
        -w '%{http_code}' \
        "$TARGET_URL" >"$run_dir/httpcode" 2>"$run_dir/curl.err"
    curl_rc=$?
    set -e
    end_ms="$(date +%s%3N)"
    response_ms=$((end_ms-start_ms))
    http_code="$(tr -d '\r\n ' < "$run_dir/httpcode" 2>/dev/null || true)"

    if (( curl_rc == 0 )) && [[ "$http_code" =~ ^[23][0-9][0-9]$ ]]; then
        printf 'status=ok\nrtt=%s\nhttp=%s\n' "$response_ms" "$http_code" > "$run_dir/result"
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        return 0
    fi

    printf 'status=failed\nrtt=%s\nhttp=%s\ncurl_rc=%s\n' "$response_ms" "${http_code:-000}" "$curl_rc" > "$run_dir/result"
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    return 1
}

stage1_worker(){
    local candidate="$1" idx="$2"
    local run_dir="$WORK_DIR/stage1_${idx}_$$"
    local meta name server port transport security result status rtt
    mkdir -p "$run_dir"

    if ! meta="$(metadata "$candidate" 2>/dev/null)"; then
        rm -rf "$run_dir"
        return 0
    fi

    name="$(awk -F= '$1=="name"{print substr($0,index($0,"=")+1)}' <<< "$meta")"
    server="$(awk -F= '$1=="server"{print substr($0,index($0,"=")+1)}' <<< "$meta")"
    port="$(awk -F= '$1=="port"{print substr($0,index($0,"=")+1)}' <<< "$meta")"
    transport="$(awk -F= '$1=="transport"{print substr($0,index($0,"=")+1)}' <<< "$meta")"
    security="$(awk -F= '$1=="security"{print substr($0,index($0,"=")+1)}' <<< "$meta")"

    if probe_once "$candidate" "$TIMEOUT" "$run_dir" "$(next_port "$idx")" >/dev/null 2>&1; then
        result="$(cat "$run_dir/result" 2>/dev/null || true)"
        status="$(awk -F= '$1=="status"{print $2}' <<< "$result")"
        rtt="$(awk -F= '$1=="rtt"{print $2}' <<< "$result")"
        if [[ "$status" == ok ]] && is_number "$rtt"; then
            printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$rtt" "$candidate" "$name" "$transport/$security" "$server:$port" "stage1" >> "$RESULT_FILE"
        fi
    fi

    result="$(cat "$run_dir/result" 2>/dev/null || true)"
    if [[ "$result" != status=ok* ]]; then
        base="$(basename "$candidate")"
        printf '%s\n' "$candidate" > "$WORK_DIR/failures/${base}.path"
        cp -f "$run_dir/result" "$WORK_DIR/failures/${base}.result" 2>/dev/null || true
        cp -f "$run_dir/curl.err" "$WORK_DIR/failures/${base}.curl.err" 2>/dev/null || true
        cp -f "$run_dir/probe.err" "$WORK_DIR/failures/${base}.probe.err" 2>/dev/null || true
    fi

    rm -rf "$run_dir"
}

info "Validating ${#CANDIDATES[@]} generated candidates..."
info "Stage 1: fast real-proxy connectivity test (parallel=$PARALLEL)"
printf '  %-3s %-48s %-8s %-8s %-20s\n' 'Run' 'Profile' 'RTT' 'Status' 'Endpoint'
printf '  %-3s %-48s %-8s %-8s %-20s\n' '---' '-----------------------------------------------' '-------' '------' '-------------------'

pids=()
slot=0
running=0
for candidate in "${CANDIDATES[@]}"; do
    ((slot+=1))
    stage1_worker "$candidate" "$(( (slot-1) % PARALLEL ))" &
    pids+=("$!")
    ((running+=1))

    if (( running >= PARALLEL )); then
        wait "${pids[0]}" 2>/dev/null || true
        pids=("${pids[@]:1}")
        ((running-=1))
    fi
done

for pid in "${pids[@]}"; do
    wait "$pid" 2>/dev/null || true
done

STAGE1_COUNT="$(wc -l < "$RESULT_FILE" | tr -d ' ')"
TOTAL="${#CANDIDATES[@]}"

if (( STAGE1_COUNT == 0 )); then
    printf '\n'
    fatal "No candidate passed Stage 1. See cache/validator/failures/"
fi

###############################################################################
# Build validated index.
# For this fast stage: Score = RTT and Jitter = 0. Stage 2 will replace these
# with repeated measurements and a real score.
###############################################################################
INDEX_FILE="$VALIDATED_DIR/index.tsv"
printf 'Rank\tProfile\tRTT\tJitter\tScore\n' > "$INDEX_FILE"

rank=0
sort -t$'\t' -k1,1n "$RESULT_FILE" | while IFS=$'\t' read -r rtt candidate name transport endpoint stage; do
    ((rank+=1))
    score="$(awk -v r="$rtt" 'BEGIN{printf "%.2f", r}')"
    printf '%s\t%s\t%s\t%s\t%s\n' \
        "$rank" "$name" "$rtt" "0" "$score" >> "$INDEX_FILE"
    cp -f "$candidate" "$VALIDATED_DIR/$(printf '%03d_%s' "$rank" "$(basename "$candidate")")"
done

###############################################################################
# Human-readable result table.
###############################################################################
printf '\n'
success "Validator complete"
printf '  Candidates : %s\n' "$TOTAL"
printf '  Valid      : %s\n' "$STAGE1_COUNT"
printf '  Parallel   : %s\n' "$PARALLEL"
printf '  Target     : %s\n' "$TARGET_URL"
printf '\n'
printf '%-5s %-52s %-8s %-8s %-8s\n' 'Rank' 'Profile' 'RTT' 'Jitter' 'Score'
printf '%-5s %-52s %-8s %-8s %-8s\n' '-----' '----------------------------------------------------' '--------' '--------' '--------'

awk -F'\t' 'NR>1 {printf "%-5s %-52s %-8s %-8s %-8s\n", $1,$2,$3,$4,$5}' "$INDEX_FILE"
printf '\nIndex: %s\n' "$INDEX_FILE"
printf 'Failures: %s\n' "$WORK_DIR/failures"
