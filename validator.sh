#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================================
# Smart Proxy Server - Candidate Validator
#
# Stage 1 only:
#   cache/generated/*.json -> quick real sing-box connectivity test
#   parallel=6 -> cache/validated/index.tsv
#
# The validator intentionally stays lightweight. Scoring/retesting can be
# layered on top later. No ICMP/ping is used.
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
TIMEOUT="${VALIDATOR_STAGE1_TIMEOUT:-4}"
SING_BOX="${SING_BOX_BIN:-sing-box}"
TARGET_URL="${VALIDATOR_URL:-https://cp.cloudflare.com/generate_204}"

fatal(){ printf '[✗] %s\n' "$*" >&2; exit 1; }
success(){ printf '[✓] %s\n' "$*"; }
warning(){ printf '[!] %s\n' "$*" >&2; }
info(){ printf '[*] %s\n' "$*"; }
require_cmd(){ command -v "$1" >/dev/null 2>&1 || fatal "Missing required command: $1"; }

(( PARALLEL > 0 )) || fatal "VALIDATOR_PARALLEL must be > 0"
[[ -d "$GENERATED_DIR" ]] || fatal "Missing generated directory: $GENERATED_DIR"

mkdir -p "$VALIDATED_DIR" "$WORK_DIR/failures"
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
require_cmd curl
require_cmd timeout
require_cmd flock
require_cmd awk
require_cmd sort
require_cmd ss

shopt -s nullglob
CANDIDATES=("$GENERATED_DIR"/*.json)
shopt -u nullglob
[[ ${#CANDIDATES[@]} -gt 0 ]] || fatal "No JSON candidates found in $GENERATED_DIR"

next_port(){
    # Each worker receives a unique loopback port.
    echo $((19080 + $1))
}

metadata(){
    python3 - "$1" <<'PY'
import json, sys
with open(sys.argv[1], encoding='utf-8') as fh:
    d=json.load(fh)
transport=(d.get('transport') or {}).get('type', 'tcp')
tls=(d.get('tls') or {}).get('enabled', False)
name=d.get('tag') or 'candidate'
print(f"name={name}")
print(f"server={d.get('server','')}")
print(f"port={d.get('server_port','')}")
print(f"transport={transport}")
print(f"security={'tls' if tls else 'none'}")
PY
}

build_temp_config(){
    python3 - "$1" "$2" "$3" <<'PY'
import json, sys
src, dst, port = sys.argv[1], sys.argv[2], int(sys.argv[3])
with open(src, encoding='utf-8') as fh:
    candidate=json.load(fh)

outbound=dict(candidate)
outbound.pop('tag', None)
tag=f"validator-{port}"

cfg={
    'log': {'level':'error'},
    'inbounds': [{
        'type':'mixed',
        'tag':'validator-in',
        'listen':'127.0.0.1',
        'listen_port':port,
    }],
    'outbounds': [
        dict(outbound, tag=tag),
        {'type':'direct','tag':'direct'},
    ],
    'route': {'final':tag},
}
with open(dst,'w',encoding='utf-8') as fh:
    json.dump(cfg, fh, ensure_ascii=False)
PY
}

probe_candidate(){
    local candidate="$1" run_dir="$2" port="$3"
    local cfg="$run_dir/config.json" pid="" start end elapsed rc code

    mkdir -p "$run_dir"
    build_temp_config "$candidate" "$cfg" "$port" || {
        printf 'status=failed\nreason=build-config\n' > "$run_dir/result"
        return 1
    }

    if ! "$SING_BOX" check -c "$cfg" >"$run_dir/check.out" 2>&1; then
        printf 'status=failed\nreason=sing-box-check\n' > "$run_dir/result"
        return 1
    fi

    # Avoid false readiness probes. curl itself is the application-layer test.
    "$SING_BOX" run -c "$cfg" >"$run_dir/sing-box.out" 2>"$run_dir/sing-box.err" &
    pid=$!

    start="$(date +%s%3N)"
    set +e
    timeout "$TIMEOUT" curl -4 -L -sS -o /dev/null \
        --socks5-hostname "127.0.0.1:$port" \
        --connect-timeout "$TIMEOUT" \
        --max-time "$TIMEOUT" \
        -w '%{http_code}\n' "$TARGET_URL" \
        >"$run_dir/httpcode" 2>"$run_dir/curl.err"
    rc=$?
    set -e
    end="$(date +%s%3N)"
    elapsed=$((end-start))
    code="$(cat "$run_dir/httpcode" 2>/dev/null || true)"

    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true

    if (( rc == 0 )) && [[ "$code" =~ ^[23][0-9][0-9]$ ]]; then
        printf 'status=ok\nrtt=%s\nhttp=%s\n' "$elapsed" "$code" > "$run_dir/result"
        return 0
    fi

    printf 'status=failed\nrtt=%s\nhttp=%s\ncurl_rc=%s\n' \
        "$elapsed" "${code:-000}" "$rc" > "$run_dir/result"
    return 1
}

worker(){
    local candidate="$1" idx="$2"
    local run_dir="$WORK_DIR/run_${idx}_$$"
    local meta name server port transport security result status rtt
    mkdir -p "$run_dir"

    meta="$(metadata "$candidate" 2>/dev/null || true)"
    name="$(awk -F= '$1=="name"{print substr($0,index($0,"=")+1)}' <<< "$meta")"
    server="$(awk -F= '$1=="server"{print substr($0,index($0,"=")+1)}' <<< "$meta")"
    port="$(awk -F= '$1=="port"{print substr($0,index($0,"=")+1)}' <<< "$meta")"
    transport="$(awk -F= '$1=="transport"{print substr($0,index($0,"=")+1)}' <<< "$meta")"
    security="$(awk -F= '$1=="security"{print substr($0,index($0,"=")+1)}' <<< "$meta")"

    if probe_candidate "$candidate" "$run_dir" "$(next_port "$idx")"; then
        result="$(cat "$run_dir/result")"
        status="$(awk -F= '$1=="status"{print $2}' <<< "$result")"
        rtt="$(awk -F= '$1=="rtt"{print $2}' <<< "$result")"
        if [[ "$status" == ok ]] && [[ "$rtt" =~ ^[0-9]+$ ]]; then
            # Fields: rtt, profile, server, port, transport, security
            printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$rtt" "$(basename "$candidate")" "$server:$port" "$transport" "$security" "$name" \
                >> "$RESULT_FILE"
        fi
    else
        cp -f "$run_dir/result" "$WORK_DIR/failures/$(basename "$candidate").result" 2>/dev/null || true
        cp -f "$run_dir/curl.err" "$WORK_DIR/failures/$(basename "$candidate").curl.err" 2>/dev/null || true
        cp -f "$run_dir/sing-box.err" "$WORK_DIR/failures/$(basename "$candidate").sing-box.err" 2>/dev/null || true
    fi

    rm -rf "$run_dir"
}

info "Validating ${#CANDIDATES[@]} candidates from cache/generated/..."
info "Stage 1: quick connectivity test (Parallel=$PARALLEL)"
printf '\n'

running=0
slot=0
pids=()
for candidate in "${CANDIDATES[@]}"; do
    ((slot+=1))
    worker "$candidate" "$(( (slot-1) % PARALLEL ))" &
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

VALID_COUNT="$(wc -l < "$RESULT_FILE" | tr -d ' ' )"
FAIL_COUNT=$(( ${#CANDIDATES[@]} - VALID_COUNT ))

(( VALID_COUNT > 0 )) || fatal "No candidate passed connectivity. See cache/validator/failures/."

# First-stage results are sorted by RTT. Jitter is intentionally 0 here:
# repeated probes belong to the later scoring stage.
RANKED="$WORK_DIR/ranked.tsv"
sort -t$'\t' -k1,1n -k2,2 "$RESULT_FILE" > "$RANKED"

INDEX="$VALIDATED_DIR/index.tsv"
printf 'Rank\tProfile\tRTT\tJitter\tScore\n' > "$INDEX"

rank=0
while IFS=$'\t' read -r rtt profile endpoint transport security name; do
    ((rank+=1))
    # Stage 1 score is intentionally RTT-based only; this will be replaced by
    # the proper multi-sample score stage without changing the index format.
    score="$rtt"
    printf '%s\t%s\t%s\t0\t%s\n' \
        "$rank" "$profile" "$rtt" "$score" >> "$INDEX"
done < "$RANKED"

info ""
info "Validator results"
printf '%-5s %-46s %-8s %-8s %-8s\n' "Rank" "Profile" "RTT" "Jitter" "Score"
printf '%-5s %-46s %-8s %-8s %-8s\n' "-----" "----------------------------------------------" "--------" "--------" "--------"
while IFS=$'\t' read -r rank profile rtt jitter score; do
    printf '%-5s %-46s %-8s %-8s %-8s\n' \
        "$rank" "$profile" "${rtt}ms" "${jitter}ms" "$score"
done < <(tail -n +2 "$INDEX")

printf '\n'
success "Validator complete"
printf '  Candidates : %s\n' "${#CANDIDATES[@]}"
printf '  Passed     : %s\n' "$VALID_COUNT"
printf '  Failed     : %s\n' "$FAIL_COUNT"
printf '  Parallel   : %s\n' "$PARALLEL"
printf '  Index      : %s\n' "$INDEX"
