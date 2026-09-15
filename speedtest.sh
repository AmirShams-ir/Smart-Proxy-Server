#!/usr/bin/env bash
set -Eeuo pipefail

# Smart Proxy Server - speedtest
#
# Fast download/upload throughput test for ONE sing-box config.

SING_BOX="${SING_BOX_BIN:-sing-box}"
PORT="${SPEEDTEST_PORT:-1235}"
TIMEOUT="${SPEEDTEST_TIMEOUT:-15}"
DOWNLOAD_BYTES="${SPEEDTEST_DOWNLOAD_BYTES:-1048576}"
UPLOAD_BYTES="${SPEEDTEST_UPLOAD_BYTES:-524288}"
DOWNLOAD_URL="${SPEEDTEST_DOWNLOAD_URL:-https://speed.cloudflare.com/__down?bytes=${DOWNLOAD_BYTES}}"
UPLOAD_URL="${SPEEDTEST_UPLOAD_URL:-https://httpbin.org/post}"
WORK_ROOT="${SPEEDTEST_WORK_DIR:-/tmp/smartproxy-speedtest}"

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
require_cmd ss
require_cmd awk
require_cmd head
require_cmd wc
require_cmd date

mkdir -p "$WORK_ROOT"
RUN_DIR="$WORK_ROOT/run-$$"
mkdir -p "$RUN_DIR"

CONFIG_FILE="$RUN_DIR/config.json"
ERR_FILE="$RUN_DIR/sing-box.err"
LOG_FILE="$RUN_DIR/sing-box.log"
META_FILE="$RUN_DIR/meta.txt"
UPLOAD_FILE="$RUN_DIR/upload.bin"
DOWNLOAD_FILE="$RUN_DIR/download.out"
DOWNLOAD_ERR="$RUN_DIR/download.err"
UPLOAD_ERR="$RUN_DIR/upload.err"
PID=""

cleanup(){
    if [[ -n "${PID:-}" ]] && kill -0 "$PID" 2>/dev/null; then
        kill "$PID" 2>/dev/null || true
        wait "$PID" 2>/dev/null || true
    fi
    rm -rf "$RUN_DIR"
}
trap cleanup EXIT INT TERM

###############################################################################
# Build an isolated test config.
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

if 'outbounds' in data:
    outbounds = data.get('outbounds') or []
    if not outbounds:
        raise SystemExit('full config contains no outbounds')

    wanted = os.environ.get('SPEEDTEST_OUTBOUND', '').strip()
    route = data.get('route') or {}
    if not wanted and isinstance(route, dict):
        final = route.get('final')
        if isinstance(final, str) and final:
            wanted = final

    if not wanted:
        for item in outbounds:
            if isinstance(item, dict) and item.get('tag'):
                wanted = str(item['tag'])
                break

    selected = next(
        (item for item in outbounds
         if isinstance(item, dict) and item.get('tag') == wanted),
        None,
    )
    if selected is None:
        raise SystemExit(f'outbound not found: {wanted}')

    cfg = dict(data)
    cfg['inbounds'] = [{
        'type': 'socks',
        'tag': 'speedtest-in',
        'listen': '127.0.0.1',
        'listen_port': port,
    }]
    cfg['route'] = dict(cfg.get('route') or {})
    cfg['route']['final'] = wanted
    cfg['route']['rules'] = []
    cfg.pop('experimental', None)
    out.write_text(json.dumps(cfg, indent=2, ensure_ascii=False), encoding='utf-8')

    transport = (selected.get('transport') or {}).get('type', 'tcp')
    tls = selected.get('tls') or {}
    security = 'tls' if tls.get('enabled') else 'none'
    with meta.open('w', encoding='utf-8') as f:
        print('tag=' + str(wanted), file=f)
        print('protocol=' + str(selected.get('type', 'unknown')), file=f)
        print('server=' + str(selected.get('server', '-')), file=f)
        print('port=' + str(selected.get('server_port', '-')), file=f)
        print('transport=' + str(transport), file=f)
        print('security=' + security, file=f)
    raise SystemExit(0)

outbound = dict(data)
tag = str(outbound.pop('tag', 'speedtest-out')) or 'speedtest-out'

cfg = {
    'log': {'level': 'error'},
    'inbounds': [{
        'type': 'socks',
        'tag': 'speedtest-in',
        'listen': '127.0.0.1',
        'listen_port': port,
    }],
    'outbounds': [
        dict(outbound, tag=tag),
        {'type': 'direct', 'tag': 'direct'},
        {'type': 'block', 'tag': 'block'},
    ],
    'route': {'final': tag, 'rules': []},
}
out.write_text(json.dumps(cfg, indent=2, ensure_ascii=False), encoding='utf-8')

transport = (outbound.get('transport') or {}).get('type', 'tcp')
tls = outbound.get('tls') or {}
security = 'tls' if tls.get('enabled') else 'none'
with meta.open('w', encoding='utf-8') as f:
    print('tag=' + tag, file=f)
    print('protocol=' + str(outbound.get('type', 'unknown')), file=f)
    print('server=' + str(outbound.get('server', '-')), file=f)
    print('port=' + str(outbound.get('server_port', '-')), file=f)
    print('transport=' + str(transport), file=f)
    print('security=' + security, file=f)
PY

NAME="$(awk -F= '$1=="tag"{print $2}' "$META_FILE")"
PROTOCOL="$(awk -F= '$1=="protocol"{print $2}' "$META_FILE")"
SERVER="$(awk -F= '$1=="server"{print $2}' "$META_FILE")"
SERVER_PORT="$(awk -F= '$1=="port"{print $2}' "$META_FILE")"
TRANSPORT="$(awk -F= '$1=="transport"{print $2}' "$META_FILE")"
SECURITY="$(awk -F= '$1=="security"{print $2}' "$META_FILE")"

if ! "$SING_BOX" check -c "$CONFIG_FILE" >"$RUN_DIR/check.out" 2>&1; then
    printf '\n[!] Configuration check failed\n' >&2
    cat "$RUN_DIR/check.out" >&2
    exit 1
fi

if ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq '(^|:)127\.0\.0\.1:'"$PORT"'$|(^|:)0\.0\.0\.0:'"$PORT"'$|(^|:)\[::\]:'"$PORT"'$'; then
    fatal "Local test port $PORT is already in use. Use SPEEDTEST_PORT=<free-port>."
fi

"$SING_BOX" run -c "$CONFIG_FILE" >"$LOG_FILE" 2>"$ERR_FILE" &
PID=$!

info "Starting fast speed test through sing-box..."
printf '  %-12s %s\n' 'Profile' "$NAME"
printf '  %-12s %s\n' 'Protocol' "$PROTOCOL"
printf '  %-12s %s:%s\n' 'Endpoint' "$SERVER" "$SERVER_PORT"
printf '  %-12s %s/%s\n' 'Transport' "$TRANSPORT" "$SECURITY"
printf '  %-12s %s (%s bytes)\n' 'Download' "$DOWNLOAD_URL" "$DOWNLOAD_BYTES"
printf '  %-12s %s (%s bytes)\n' 'Upload' "$UPLOAD_URL" "$UPLOAD_BYTES"
printf '\n'

ready=0
for _ in {1..30}; do
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
    [[ -s "$ERR_FILE" ]] && cat "$ERR_FILE" >&2
    exit 1
fi

###############################################################################
# Download
###############################################################################
: > "$DOWNLOAD_FILE"
: > "$DOWNLOAD_ERR"
DOWNLOAD_START="$(date +%s%N)"
set +e
DOWNLOAD_HTTP="$(curl -4 -L --http1.1 --max-time "$TIMEOUT" --connect-timeout 5 \
    --socks5-hostname "127.0.0.1:$PORT" \
    -sS -o "$DOWNLOAD_FILE" -w '%{http_code}' \
    "$DOWNLOAD_URL" 2>"$DOWNLOAD_ERR")"
DOWNLOAD_RC=$?
set -e
DOWNLOAD_END="$(date +%s%N)"
DOWNLOAD_BYTES_DONE="$(wc -c < "$DOWNLOAD_FILE" 2>/dev/null || printf '0')"
DOWNLOAD_SECONDS="$(awk -v a="$DOWNLOAD_START" -v b="$DOWNLOAD_END" 'BEGIN{printf "%.3f", (b-a)/1000000000}')"
DOWNLOAD_MBPS="$(awk -v b="$DOWNLOAD_BYTES_DONE" -v s="$DOWNLOAD_SECONDS" 'BEGIN{if(s>0) printf "%.2f", (b*8/1000000)/s; else print "0.00"}')"

###############################################################################
# Upload
#
# IMPORTANT: measure actual curl transfer counters rather than assuming the
# whole local payload was transmitted.
###############################################################################
head -c "$UPLOAD_BYTES" /dev/zero > "$UPLOAD_FILE"
: > "$UPLOAD_ERR"
UPLOAD_START="$(date +%s%N)"
set +e
UPLOAD_META="$(curl -4 --http1.1 --max-time "$TIMEOUT" --connect-timeout 5 \
    --socks5-hostname "127.0.0.1:$PORT" \
    -sS -o /dev/null \
    -w '%{http_code} %{size_upload} %{time_total} %{speed_upload}' \
    -X POST --data-binary "@$UPLOAD_FILE" \
    "$UPLOAD_URL" 2>"$UPLOAD_ERR")"
UPLOAD_RC=$?
set -e
UPLOAD_END="$(date +%s%N)"

UPLOAD_HTTP="$(awk '{print $1}' <<<"$UPLOAD_META")"
UPLOAD_BYTES_SENT="$(awk '{printf "%.0f", $2}' <<<"$UPLOAD_META")"
UPLOAD_SECONDS="$(awk '{print $3}' <<<"$UPLOAD_META")"
UPLOAD_CURL_SPEED="$(awk '{print $4}' <<<"$UPLOAD_META")"

[[ "$UPLOAD_BYTES_SENT" =~ ^[0-9]+$ ]] || UPLOAD_BYTES_SENT=0
[[ "$UPLOAD_SECONDS" =~ ^[0-9]+([.][0-9]+)?$ ]] || UPLOAD_SECONDS="$(awk -v a="$UPLOAD_START" -v b="$UPLOAD_END" 'BEGIN{printf "%.3f", (b-a)/1000000000}')"
[[ "$UPLOAD_CURL_SPEED" =~ ^[0-9]+([.][0-9]+)?$ ]] || UPLOAD_CURL_SPEED=0

UPLOAD_SPEED_MBPS="$(awk -v b="$UPLOAD_BYTES_SENT" -v s="$UPLOAD_SECONDS" 'BEGIN{if(s>0) printf "%.2f",(b*8/1000000)/s; else print "0.00"}')"
UPLOAD_CURL_MBPS="$(awk -v bps="$UPLOAD_CURL_SPEED" 'BEGIN{printf "%.2f", bps*8/1000000}')"

format_bytes(){
    awk -v n="${1:-0}" 'BEGIN {
        if (n < 1024) printf "%.0f B", n;
        else if (n < 1048576) printf "%.2f KiB", n/1024;
        else if (n < 1073741824) printf "%.2f MiB", n/1048576;
        else printf "%.2f GiB", n/1073741824;
    }'
}

printf '%s\n' '============================================================'
printf '%-18s %s\n' 'Download' "${DOWNLOAD_MBPS} Mbps"
printf '%-18s %s\n' 'Downloaded' "$(format_bytes "$DOWNLOAD_BYTES_DONE")"
printf '%-18s %s\n' 'Download time' "${DOWNLOAD_SECONDS}s"
printf '%-18s %s\n' 'Download HTTP' "${DOWNLOAD_HTTP:-000}"
printf '%s\n' '------------------------------------------------------------'
printf '%-18s %s\n' 'Upload' "${UPLOAD_SPEED_MBPS} Mbps"
printf '%-18s %s\n' 'Upload curl' "${UPLOAD_CURL_MBPS} Mbps"
printf '%-18s %s\n' 'Uploaded' "$(format_bytes "$UPLOAD_BYTES_SENT")"
printf '%-18s %s\n' 'Upload time' "${UPLOAD_SECONDS}s"
printf '%-18s %s\n' 'Upload HTTP' "${UPLOAD_HTTP:-000}"
printf '%s\n' '============================================================'

DOWNLOAD_OK=false
UPLOAD_OK=false
[[ "$DOWNLOAD_RC" -eq 0 && "$DOWNLOAD_HTTP" =~ ^[23][0-9][0-9]$ && "$DOWNLOAD_BYTES_DONE" -gt 0 ]] && DOWNLOAD_OK=true
[[ "$UPLOAD_RC" -eq 0 && "$UPLOAD_HTTP" =~ ^[23][0-9][0-9]$ && "$UPLOAD_BYTES_SENT" -eq "$UPLOAD_BYTES" ]] && UPLOAD_OK=true

# A response timeout is only accepted when the entire configured payload was
# reported by curl as uploaded and the server returned a 2xx/3xx response.
if [[ "$UPLOAD_RC" -ne 0 && "$UPLOAD_HTTP" =~ ^[23][0-9][0-9]$ && "$UPLOAD_BYTES_SENT" -eq "$UPLOAD_BYTES" ]]; then
    UPLOAD_OK=true
fi

if [[ "$DOWNLOAD_OK" == true && "$UPLOAD_OK" == true ]]; then
    success "Fast speed test completed"
    exit 0
fi

warning "Speed test completed with warnings"
(( DOWNLOAD_RC != 0 )) && [[ -s "$DOWNLOAD_ERR" ]] && { printf 'Download error: '; tail -n 2 "$DOWNLOAD_ERR"; }
(( UPLOAD_RC != 0 )) && [[ -s "$UPLOAD_ERR" ]] && { printf 'Upload note: '; tail -n 2 "$UPLOAD_ERR"; }
exit 1
