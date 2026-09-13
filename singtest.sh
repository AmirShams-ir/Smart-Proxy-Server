#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================================
# Smart Proxy Server - singtest
#
# Test one sing-box configuration for basic connectivity.
#
# Usage:
#   bash singtest.sh /etc/sing-box/config.json
#   bash singtest.sh cache/generated/candidate.json
#
# Accepted input:
#   1. Full sing-box configuration containing inbounds/outbounds.
#   2. Generated outbound fragment produced by maker.sh.
#
# The test intentionally does NOT perform speed benchmarking, jitter scoring,
# or ranking. It only answers whether usable application traffic can pass
# through the selected sing-box outbound.
# ============================================================================

SING_BOX="${SING_BOX_BIN:-sing-box}"
TARGET_URL="${SINGTEST_URL:-https://google.com/}"
TIMEOUT="${SINGTEST_TIMEOUT:-8}"
PORT="${SINGTEST_PORT:-1234}"
WORK_ROOT="${SINGTEST_WORK_DIR:-/tmp/smartproxy-singtest}"

fatal(){ printf '[✗] %s\n' "$*" >&2; exit 1; }
info(){ printf '[*] %s\n' "$*"; }
success(){ printf '[✓] %s\n' "$*"; }
warning(){ printf '[!] %s\n' "$*" >&2; }

usage(){
    printf 'Usage: %s <sing-box-config.json>\n' "$(basename "$0")" >&2
    exit 2
}

require_cmd(){
    command -v "$1" >/dev/null 2>&1 || fatal "Missing required command: $1"
}

[[ $# -eq 1 ]] || usage
INPUT="$1"
[[ -f "$INPUT" ]] || fatal "Config not found: $INPUT"

require_cmd "$SING_BOX"
require_cmd python3
require_cmd curl
require_cmd timeout
require_cmd flock
require_cmd ss

mkdir -p "$WORK_ROOT"
RUN_DIR="$WORK_ROOT/run-$$"
mkdir -p "$RUN_DIR"

CONFIG_FILE="$RUN_DIR/config.json"
PROBE_LOG="$RUN_DIR/sing-box.log"
PROBE_ERR="$RUN_DIR/sing-box.err"
HTTP_CODE_FILE="$RUN_DIR/httpcode"
CURL_ERR="$RUN_DIR/curl.err"
RESULT_FILE="$RUN_DIR/result"
PID=""

cleanup(){
    if [[ -n "${PID:-}" ]] && kill -0 "$PID" 2>/dev/null; then
        kill "$PID" 2>/dev/null || true
        wait "$PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

###############################################################################
# Detect input type and create an isolated test configuration
###############################################################################
INPUT_MODE=""
INPUT_META="$RUN_DIR/meta.txt"

python3 - "$INPUT" "$CONFIG_FILE" "$PORT" >"$INPUT_META" <<'PY'
import json
import sys
from pathlib import Path

src=Path(sys.argv[1])
out=Path(sys.argv[2])
port=int(sys.argv[3])

data=json.loads(src.read_text(encoding='utf-8'))

# Full sing-box configuration.
if isinstance(data, dict) and 'outbounds' in data:
    cfg=dict(data)

    # Never reuse a production listening port for the temporary test.
    cfg['inbounds']=[{
        'type':'mixed',
        'tag':'singtest-in',
        'listen':'127.0.0.1',
        'listen_port':port,
    }]

    outbounds=cfg.get('outbounds') or []
    if not outbounds:
        raise SystemExit('full config contains no outbounds')

    tags=[]
    for item in outbounds:
        if isinstance(item, dict) and item.get('tag'):
            tags.append(str(item['tag']))

    # Respect the config's final route when possible; otherwise choose its
    # first tagged outbound. The caller can override with SINGTEST_OUTBOUND.
    wanted = None
    route=cfg.get('route') or {}
    if isinstance(route, dict):
        final=route.get('final')
        if isinstance(final,str) and final:
            wanted=final

    override=None
    # Environment is intentionally passed as a plain string here.
    import os
    override=os.environ.get('SINGTEST_OUTBOUND','')
    if override:
        wanted=override

    if not wanted or wanted not in tags:
        wanted=tags[0] if tags else None

    if not wanted:
        raise SystemExit('full config has no tagged outbound')

    cfg['route']={'final':wanted}
    out.write_text(json.dumps(cfg,indent=2,ensure_ascii=False),encoding='utf-8')

    selected=next(x for x in outbounds if isinstance(x,dict) and x.get('tag')==wanted)
    print('mode=full')
    print(f"tag={wanted}")
    print(f"protocol={selected.get('type','unknown')}")
    print(f"server={selected.get('server','-')}")
    print(f"port={selected.get('server_port','-')}")
    transport=(selected.get('transport') or {}).get('type','tcp')
    security='tls' if (selected.get('tls') or {}).get('enabled') else 'none'
    print(f"transport={transport}")
    print(f"security={security}")
    raise SystemExit(0)

# Generated outbound fragment from maker.sh.
outbound=dict(data)
tag=str(outbound.pop('tag','singtest-out')) or 'singtest-out'

cfg={
    'log':{'level':'error'},
    'inbounds':[{
        'type':'mixed',
        'tag':'singtest-in',
        'listen':'127.0.0.1',
        'listen_port':port,
    }],
    'outbounds':[
        dict(outbound,tag=tag),
        {'type':'direct','tag':'direct'},
    ],
    'route':{'final':tag},
}
out.write_text(json.dumps(cfg,indent=2,ensure_ascii=False),encoding='utf-8')

print('mode=fragment')
print(f"tag={tag}")
print(f"protocol={outbound.get('type','unknown')}")
print(f"server={outbound.get('server','-')}")
print(f"port={outbound.get('server_port','-')}")
transport=(outbound.get('transport') or {}).get('type','tcp')
security='tls' if (outbound.get('tls') or {}).get('enabled') else 'none'
print(f"transport={transport}")
print(f"security={security}")
PY

MODE="$(awk -F= '$1=="mode"{print $2}' "$INPUT_META")"
NAME="$(awk -F= '$1=="tag"{print $2}' "$INPUT_META")"
PROTOCOL="$(awk -F= '$1=="protocol"{print $2}' "$INPUT_META")"
SERVER="$(awk -F= '$1=="server"{print $2}' "$INPUT_META")"
SERVER_PORT="$(awk -F= '$1=="port"{print $2}' "$INPUT_META")"
TRANSPORT="$(awk -F= '$1=="transport"{print $2}' "$INPUT_META")"
SECURITY="$(awk -F= '$1=="security"{print $2}' "$INPUT_META")"

###############################################################################
# Validate temporary configuration
###############################################################################
if ! "$SING_BOX" check -c "$CONFIG_FILE" >"$RUN_DIR/check.out" 2>&1; then
    printf 'status=INVALID_CONFIG\n' > "$RESULT_FILE"
    cat "$RUN_DIR/check.out" >&2
    printf '\nDiagnostics: %s\n' "$RUN_DIR" >&2
    trap - EXIT INT TERM
    exit 1
fi

###############################################################################
# Make sure the temporary test port is free
###############################################################################
if ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq '(^|:)127\.0\.0\.1:'"$PORT"'$|(^|:)0\.0\.0\.0:'"$PORT"'$|(^|:)\[::\]:'"$PORT"'$'; then
    fatal "Local test port $PORT is already in use. Use SINGTEST_PORT=<free-port>."
fi

###############################################################################
# Start isolated sing-box
###############################################################################
"$SING_BOX" run -c "$CONFIG_FILE" >"$PROBE_LOG" 2>"$PROBE_ERR" &
PID=$!

info "Testing sing-box connectivity..."
printf '  %-12s %s\n' 'Mode' "$MODE"
printf '  %-12s %s\n' 'Outbound' "$NAME"
printf '  %-12s %s\n' 'Protocol' "$PROTOCOL"
printf '  %-12s %s:%s\n' 'Endpoint' "$SERVER" "$SERVER_PORT"
printf '  %-12s %s/%s\n' 'Transport' "$TRANSPORT" "$SECURITY"
printf '  %-12s %s\n' 'Target' "$TARGET_URL"
printf '\n'

###############################################################################
# Actual connectivity test through temporary SOCKS5
###############################################################################
START_MS="$(date +%s%3N)"
set +e
timeout "$TIMEOUT" curl -fsS \
    --proxy "socks5h://127.0.0.1:$PORT" \
    --connect-timeout "$TIMEOUT" \
    --max-time "$TIMEOUT" \
    -o /dev/null \
    -w '%{http_code}\n' \
    "$TARGET_URL" >"$HTTP_CODE_FILE" 2>"$CURL_ERR"
CURL_RC=$?
set -e
END_MS="$(date +%s%3N)"
RESPONSE_MS=$((END_MS-START_MS))
HTTP_CODE="$(cat "$HTTP_CODE_FILE" 2>/dev/null || true)"

if (( CURL_RC == 0 )) && [[ "$HTTP_CODE" =~ ^[23][0-9][0-9]$ ]]; then
    printf 'status=PASS\nresponse_ms=%s\nhttp_code=%s\ncurl_rc=%s\n' \
        "$RESPONSE_MS" "$HTTP_CODE" "$CURL_RC" > "$RESULT_FILE"

    printf '\n'
    success "Connectivity PASS"
    printf '  Response : %sms\n' "$RESPONSE_MS"
    printf '  HTTP     : %s\n' "$HTTP_CODE"
    printf '  Outbound : %s\n' "$NAME"
    rm -rf "$RUN_DIR"
    exit 0
fi

printf 'status=FAIL\nresponse_ms=%s\nhttp_code=%s\ncurl_rc=%s\n' \
    "$RESPONSE_MS" "${HTTP_CODE:-000}" "$CURL_RC" > "$RESULT_FILE"

printf '\n'
warning "Connectivity FAIL"
printf '  Response : %sms\n' "$RESPONSE_MS"
printf '  HTTP     : %s\n' "${HTTP_CODE:-000}"
printf '  Curl RC  : %s\n' "$CURL_RC"

if [[ -s "$CURL_ERR" ]]; then
    printf '\n--- curl error ---\n' >&2
    cat "$CURL_ERR" >&2
fi

if [[ -s "$PROBE_ERR" ]]; then
    printf '\n--- sing-box error ---\n' >&2
    cat "$PROBE_ERR" >&2
fi

printf '\nDiagnostics: %s\n' "$RUN_DIR" >&2

trap - EXIT INT TERM
cleanup
exit 1
