#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================================
# Smart Proxy Server - Stage 3 : Sing-box RTT Validator
#
# Reads ONLY generated outbound fragments from cache/generated/*.json.
# Each candidate is tested through sing-box using the same wrapper logic as
# singtest.sh. Only RTT is reported to stdout and all results are written to:
#   cache/validated/rtt.json
#
# Architecture:
#   maker.sh -> cache/generated/*.json -> singbox.sh -> cache/validated/rtt.json
# ============================================================================

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INPUT_DIR="$BASE_DIR/cache/generated"
VALIDATED_DIR="$BASE_DIR/cache/validated"
OUTPUT_FILE="$VALIDATED_DIR/rtt.json"

SING_BOX="${SING_BOX_BIN:-sing-box}"
TARGET_URL="${SINGTEST_URL:-https://cp.cloudflare.com/generate_204}"
TIMEOUT="${SINGTEST_TIMEOUT:-8}"
START_PORT="${SINGTEST_PORT:-1234}"
WORK_ROOT="${SINGTEST_WORK_DIR:-/tmp/smartproxy-singtest}"
PARALLEL="${SINGBOX_PARALLEL:-4}"

fatal(){ printf '[✗] %s\n' "$*" >&2; exit 1; }
info(){ printf '[*] %s\n' "$*"; }
success(){ printf '[✓] %s\n' "$*"; }

require_cmd(){
    command -v "$1" >/dev/null 2>&1 || fatal "Missing required command: $1"
}

is_uint(){
    [[ "${1:-}" =~ ^[0-9]+$ ]] && (( 10#$1 > 0 ))
}

mkdir -p "$VALIDATED_DIR" "$WORK_ROOT"

require_cmd "$SING_BOX"
require_cmd python3
require_cmd curl
require_cmd ss
require_cmd grep
require_cmd find
require_cmd sort
require_cmd wc
require_cmd sleep
require_cmd date

is_uint "$PARALLEL" || fatal "SINGBOX_PARALLEL must be a positive integer"

# Never treat previously-created sing-box configs such as config.json as
# generated candidates. maker.sh creates names containing an IP address.
shopt -s nullglob
mapfile -t CANDIDATES < <(
    find "$INPUT_DIR" -maxdepth 1 -type f -name '*.json' -print |
    awk -F/ '{n=$NF; if (n ~ /_[0-9]+_(tcp|ws|grpc)_(none|tls)\.json$/) print}' |
    sort
)
shopt -u nullglob

(( ${#CANDIDATES[@]} > 0 )) || fatal "No generated JSON candidates found in $INPUT_DIR"

RUN_DIR="$WORK_ROOT/run-$$"
RESULT_DIR="$RUN_DIR/results"
mkdir -p "$RESULT_DIR"

cleanup(){ rm -rf "$RUN_DIR"; }
trap cleanup EXIT INT TERM

free_port(){
    local port="$1"
    while (( port <= 65535 )); do
        if ! ss -lnt 2>/dev/null | grep -Eq "(^|:)(127\.0\.0\.1:|0\.0\.0\.0:|\[::\]:)$port[[:space:]]"; then
            printf '%s\n' "$port"
            return 0
        fi
        port=$((port + 1))
    done
    return 1
}

write_result(){
    local output="$1" profile="$2" rtt="$3" status="$4"
    python3 - "$output" "$profile" "$rtt" "$status" <<'PY'
import json
import sys
from pathlib import Path

out = Path(sys.argv[1])
profile = sys.argv[2]
rtt_raw = sys.argv[3]
status = sys.argv[4]
rtt = None if rtt_raw == "null" else int(rtt_raw)
out.write_text(json.dumps({"profile": profile, "rtt": rtt, "status": status}, ensure_ascii=False), encoding="utf-8")
PY
}

validate_one(){
    local input="$1" index="$2"
    local name port run_dir config_file log_file err_file http_file curl_err pid result_file

    name="$(basename "$input" .json)"
    run_dir="$RUN_DIR/job-$index"
    result_file="$RESULT_DIR/result-$index.json"
    mkdir -p "$run_dir"

    port="$(free_port "$((START_PORT + index))")" || {
        write_result "$result_file" "$name" null failed
        return 0
    }

    config_file="$run_dir/config.json"
    log_file="$run_dir/sing-box.log"
    err_file="$run_dir/sing-box.err"
    http_file="$run_dir/httpcode"
    curl_err="$run_dir/curl.err"
    pid=""

    cleanup_one(){
        if [[ -n "${pid:-}" ]] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
        fi
    }

    # Use exactly the same fragment-wrapping model as singtest.sh.
    if ! python3 - "$input" "$config_file" "$port" <<'PY'
import json
import sys
from pathlib import Path

src = Path(sys.argv[1])
out = Path(sys.argv[2])
port = int(sys.argv[3])

data = json.loads(src.read_text(encoding="utf-8"))
if not isinstance(data, dict):
    raise ValueError("JSON root must be an object")

# maker.sh emits a single outbound fragment. Accept only that shape here.
if "outbounds" in data or "inbounds" in data:
    raise ValueError("expected generated outbound fragment, not a full sing-box config")
if not data.get("type") or not data.get("server") or not data.get("server_port"):
    raise ValueError("missing generated outbound fields")

outbound = dict(data)
tag = str(outbound.pop("tag", "singtest-out")) or "singtest-out"

cfg = {
    "log": {"level": "error"},
    "inbounds": [{
        "type": "socks",
        "tag": "singtest-in",
        "listen": "127.0.0.1",
        "listen_port": port,
    }],
    "outbounds": [
        dict(outbound, tag=tag),
        {"type": "direct", "tag": "direct"},
        {"type": "block", "tag": "block"},
    ],
    "route": {
        "final": tag,
        "rules": [],
    },
}

out.write_text(json.dumps(cfg, indent=2, ensure_ascii=False), encoding="utf-8")
PY
    then
        write_result "$result_file" "$name" null failed
        return 0
    fi

    # Keep all validation logic identical in spirit to singtest.sh.
    if ! "$SING_BOX" check -c "$config_file" >"$run_dir/check.out" 2>"$err_file"; then
        write_result "$result_file" "$name" null failed
        return 0
    fi

    "$SING_BOX" run -c "$config_file" >"$log_file" 2>"$err_file" &
    pid=$!

    local ready=0
    for _ in {1..40}; do
        if ss -lnt 2>/dev/null | grep -Eq "127\.0\.0\.1:$port[[:space:]]"; then
            ready=1
            break
        fi
        if ! kill -0 "$pid" 2>/dev/null; then
            break
        fi
        sleep 0.05
    done

    if (( ready == 0 )); then
        cleanup_one
        write_result "$result_file" "$name" null failed
        return 0
    fi

    local start_ms end_ms rtt http_code curl_rc
    start_ms="$(date +%s%3N)"
    set +e
    curl -4 -L \
        --max-time "$TIMEOUT" \
        --connect-timeout 5 \
        --socks5-hostname "127.0.0.1:$port" \
        -sS -o /dev/null \
        -w '%{http_code}' \
        "$TARGET_URL" >"$http_file" 2>"$curl_err"
    curl_rc=$?
    set -e
    end_ms="$(date +%s%3N)"
    rtt=$((end_ms - start_ms))
    http_code="$(tr -d '\r\n ' < "$http_file" 2>/dev/null || true)"

    cleanup_one

    if (( curl_rc == 0 )) && [[ "$http_code" =~ ^[23][0-9][0-9]$ ]]; then
        write_result "$result_file" "$name" "$rtt" passed
    else
        write_result "$result_file" "$name" null failed
    fi
}

info "Testing ${#CANDIDATES[@]} generated JSON candidates..."
printf '\n'
printf '%-56s %8s\n' "Profile" "RTT"
printf '%s\n' '----------------------------------------------------------------'

active=0
for input in "${CANDIDATES[@]}"; do
    active=$((active + 1))
    validate_one "$input" "$active" &
    while (( $(jobs -rp | wc -l) >= PARALLEL )); do
        wait -n || true
    done
done
wait || true

python3 - "$RESULT_DIR" "$OUTPUT_FILE" <<'PY'
import json
import sys
from pathlib import Path

results_dir = Path(sys.argv[1])
out = Path(sys.argv[2])
rows = []
for src in sorted(results_dir.glob("result-*.json")):
    try:
        rows.append(json.loads(src.read_text(encoding="utf-8")))
    except (OSError, json.JSONDecodeError):
        continue

rows.sort(key=lambda x: (
    0 if x.get("status") == "passed" and isinstance(x.get("rtt"), int) else 1,
    x.get("rtt") if isinstance(x.get("rtt"), int) else 10**9,
    x.get("profile", ""),
))

out.write_text(json.dumps(rows, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

for row in rows:
    profile = str(row.get("profile", "-"))
    rtt = row.get("rtt")
    print(f"{profile}\t{rtt}ms" if row.get("status") == "passed" and isinstance(rtt, int) else f"{profile}\t-")
PY

printf '%s\n' '----------------------------------------------------------------'
success "RTT validation complete: $OUTPUT_FILE"
