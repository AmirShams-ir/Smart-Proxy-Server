#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================================
# Smart Proxy Server - singtest
#
# Fast connectivity test for one sing-box configuration/outbound.
#
# Usage:
#   bash singtest.sh /etc/sing-box/config.json
#   bash singtest.sh cache/generated/candidate.json
#
# Design:
#   - Do NOT create a temporary SOCKS/mixed inbound.
#   - Do NOT run speed, upload, download, jitter, or ranking tests.
#   - For a full production config, temporarily run that exact config on a
#     private SOCKS port and test it with the same curl method used by test.sh.
#   - For a generated outbound fragment, wrap only that outbound into a minimal
#     sing-box config and test it on a private SOCKS port.
# ============================================================================

SING_BOX="${SING_BOX_BIN:-sing-box}"
TARGET_URL="${SINGTEST_URL:-https://cp.cloudflare.com/generate_204}"
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
require_cmd ss

mkdir -p "$WORK_ROOT"
RUN_DIR="$WORK_ROOT/run-$$"
mkdir -p "$RUN_DIR"

CONFIG_FILE="$RUN_DIR/config.json"
LOG_FILE="$RUN_DIR/sing-box.log"
ERR_FILE="$RUN_DIR/sing-box.err"
HTTP_FILE="$RUN_DIR/httpcode"
CURL_ERR="$RUN_DIR/curl.err"
META_FILE="$RUN_DIR/meta.txt"
PID=""

cleanup(){
    if [[ -n "${PID:-}" ]] && kill -0 "$PID" 2>/dev/null; then
        kill "$PID" 2>/dev/null || true
        wait "$PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

###############################################################################
# Build a test config.
# For a full config, preserve the selected outbound exactly as-is and only
# replace the inbound with a private SOCKS listener. This mirrors test.sh:
# curl -> socks5-hostname -> real sing-box outbound.
###############################################################################
python3 - "$INPUT" "$CONFIG_FILE" "$PORT" "$META_FILE" <<'PY'
import json
import os
import sys
from pathlib import Path

src = Path(sys.argv[1])
out = Path(sys.argv[2])
port = int(sys.argv[3])
meta = Path(sys.argv[4])

data = json.loads(src.read_text(encoding='utf-8'))

if not isinstance(data, dict):
    raise SystemExit('JSON root must be an object')

# ---------------------------------------------------------------------------
# Full sing-box config
# ---------------------------------------------------------------------------
if 'outbounds' in data:
    cfg = data
    outbounds = cfg.get('outbounds') or []
    if not outbounds:
        raise SystemExit('full config contains no outbounds')

    wanted = os.environ.get('SINGTEST_OUTBOUND', '').strip()
    route = cfg.get('route') or {}
    if not wanted and isinstance(route, dict):
        final = route.get('final')
        if isinstance(final, str) and final:
            wanted = final

    if not wanted:
        for item in outbounds:
            if isinstance(item, dict) and item.get('tag'):
                wanted = str(item['tag'])
                break

    if not wanted:
        raise SystemExit('could not determine outbound')

    selected = None
    for item in outbounds:
        if isinstance(item, dict) and item.get('tag') == wanted:
            selected = item
            break

    if selected is None:
        raise SystemExit(f'outbound not found: {wanted}')

    # Use the exact selected outbound and isolate only the inbound side.
    cfg = dict(cfg)
    cfg['inbounds'] = [{
        'type': 'socks',
        'tag': 'singtest-in',
        'listen': '127.0.0.1',
        'listen_port': port,
    }]
    cfg['route'] = dict(cfg.get('route') or {})
    cfg['route']['final'] = wanted
    cfg['route']['rules'] = []
    cfg.pop('experimental', None)

    out.write_text(json.dumps(cfg, indent=2, ensure_ascii=False), encoding='utf-8')

    transport = (selected.get('transport') or {}).get('type', 'tcp')
    security = 'tls' if (selected.get('tls') or {}).get('enabled') else 'none'
    print(f'mode=full', file=meta.open('w', encoding='utf-8'))
    with meta.open('a', encoding='utf-8') as f:
        print(f'tag={wanted}', file=f)
        print(f"protocol={selected.get('type','unknown')}", file=f)
        print(f"server={selected.get('server','-')}", file=f)
        print(f"port={selected.get('server_port','-')}", file=f)
        print(f'transport={transport}', file=f)
        print(f'security={security}', file=f)
    raise SystemExit(0)

# ---------------------------------------------------------------------------
# Generated outbound fragment from maker.sh
# ---------------------------------------------------------------------------
outbound = dict(data)
tag = str(outbound.pop('tag', 'singtest-out')) or 'singtest-out'

cfg = {
    'log': {'level': 'error'},
    'inbounds': [{
        'type': 'socks',
        'tag': 'singtest-in',
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
out.write_text(json.dumps(cfg, indent=2, ensure_ascii=False), encoding='utf-8')

transport = (outbound.get('transport') or {}).get('type', 'tcp')
security = 'tls' if (outbound.get('tls') or {}).get('enabled') else 'none'
with meta.open('w', encoding='utf-8') as f:
    print('mode=fragment', file=f)
    print(f'tag={tag}', file=f)
    print(f"protocol={outbound.get('type','unknown')}", file=f)
    print(f"server={outbound.get('server','-')}", file=f)
    print(f"port={outbound.get('server_port','-')}", file=f)
    print(f'transport={transport}', file=f)
    print(f'security={security}', file=f)
PY

MODE="$(awk -F= '$1=="mode"{print $2}' "$META_FILE")"
NAME="$(awk -F= '$1=="tag"{print $2}' "$META_FILE")"
PROTOCOL="$(awk -F= '$1=="protocol"{print $2}' "$META_FILE")"
SERVER="$(awk -F= '$1=="server"{print $2}' "$META_FILE")"
SERVER_PORT="$(awk -F= '$1=="port"{print $2}' "$META_FILE")"
TRANSPORT="$(awk -F= '$1=="transport"{print $2}' "$META_FILE")"
SECURITY="$(awk -F= '$1=="security"{print $2}' "$META_FILE")"

###############################################################################
# Validate config first.
###############################################################################
if ! "$SING_BOX" check -c "$CONFIG_FILE" >"$RUN_DIR/check.out" 2>&1; then
    printf '\n[!] Configuration check failed\n' >&2
    cat "$RUN_DIR/check.out" >&2
    printf '\nDiagnostics: %s\n' "$RUN_DIR" >&2
    exit 1
fi

###############################################################################
# Port must be available.
###############################################################################
if ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq '(^|:)127\.0\.0\.1:'"$PORT"'$|(^|:)0\.0\.0\.0:'"$PORT"'$|(^|:)\[::\]:'"$PORT"'$'; then
    fatal "Local test port $PORT is already in use. Use SINGTEST_PORT=<free-port>."
fi

###############################################################################
# Start isolated sing-box and perform the same style of SOCKS test as test.sh.
###############################################################################
"$SING_BOX" run -c "$CONFIG_FILE" >"$LOG_FILE" 2>"$ERR_FILE" &
PID=$!

info "Testing sing-box connectivity..."
printf '  %-12s %s\n' 'Mode' "$MODE"
printf '  %-12s %s\n' 'Outbound' "$NAME"
printf '  %-12s %s\n' 'Protocol' "$PROTOCOL"
printf '  %-12s %s:%s\n' 'Endpoint' "$SERVER" "$SERVER_PORT"
printf '  %-12s %s/%s\n' 'Transport' "$TRANSPORT" "$SECURITY"
printf '  %-12s %s\n' 'Target' "$TARGET_URL"
printf '\n'

# Wait briefly for the actual SOCKS listener, not a fake TCP readiness probe.
ready=0
for _ in {1..20}; do
    if ss -lnt 2>/dev/null | grep -Eq '[:.]'"$PORT"'[[:space:]]'; then
        ready=1
        break
    fi
    if ! kill -0 "$PID" 2>/dev/null; then
        break
    fi
    sleep 0.05
done

if (( ready == 0 )); then
    warning "sing-box test listener did not become ready"
    [[ -s "$ERR_FILE" ]] && { printf '\n--- sing-box error ---\n' >&2; cat "$ERR_FILE" >&2; }
    printf '\nDiagnostics: %s\n' "$RUN_DIR" >&2
    exit 1
fi

START_MS="$(date +%s%3N)"
set +e
curl -4 -L \
    --max-time "$TIMEOUT" \
    --connect-timeout 5 \
    --socks5-hostname "127.0.0.1:$PORT" \
    -sS -o /dev/null \
    -w '%{http_code}' \
    "$TARGET_URL" >"$HTTP_FILE" 2>"$CURL_ERR"
CURL_RC=$?
set -e
END_MS="$(date +%s%3N)"
RESPONSE_MS=$((END_MS-START_MS))
HTTP_CODE="$(tr -d '\r\n ' < "$HTTP_FILE" 2>/dev/null || true)"

if (( CURL_RC == 0 )) && [[ "$HTTP_CODE" =~ ^[23][0-9][0-9]$ ]]; then
    printf '\n'
    success "Connectivity PASS"
    printf '  Response : %sms\n' "$RESPONSE_MS"
    printf '  HTTP     : %s\n' "$HTTP_CODE"
    printf '  Outbound : %s\n' "$NAME"
    rm -rf "$RUN_DIR"
    exit 0
fi

printf '\n'
warning "Connectivity FAIL"
printf '  Response : %sms\n' "$RESPONSE_MS"
printf '  HTTP     : %s\n' "${HTTP_CODE:-000}"
printf '  Curl RC  : %s\n' "$CURL_RC"

if [[ -s "$CURL_ERR" ]]; then
    printf '\n--- curl error ---\n' >&2
    cat "$CURL_ERR" >&2
fi

if [[ -s "$ERR_FILE" ]]; then
    printf '\n--- sing-box error ---\n' >&2
    cat "$ERR_FILE" >&2
fi

printf '\nDiagnostics: %s\n' "$RUN_DIR" >&2
exit 1
