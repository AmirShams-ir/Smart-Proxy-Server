#!/usr/bin/env bash
set -Eeuo pipefail

# Smart Proxy Server - Forwarder
# Starts up to TOP_N ranked winners as independent sing-box SOCKS5 instances.
#
# Default LAN listeners:
#   192.168.1.2:1080 -> winner #1
#   192.168.1.2:1081 -> winner #2
#   192.168.1.2:1082 -> winner #3
#   192.168.1.2:1083 -> winner #4
#
# Runtime files are kept outside the repository:
#   /run/smartproxy-forwarder/configs/
#   /run/smartproxy-forwarder/pids/
#   /var/log/smartproxy-forwarder/

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CSV_FILE="${FORWARDER_CSV:-$BASE_DIR/cache/winner.csv}"
WINNER_DIR="${FORWARDER_WINNER_DIR:-$BASE_DIR/cache/winner}"
SING_BOX="${SING_BOX_BIN:-sing-box}"
BIND_ADDR="${FORWARDER_BIND:-0.0.0.0}"
BASE_PORT="${FORWARDER_BASE_PORT:-1080}"
MAX_INSTANCES="${FORWARDER_MAX:-4}"
RUN_ROOT="${FORWARDER_RUN_ROOT:-/run/smartproxy-forwarder}"
CONFIG_DIR="$RUN_ROOT/configs"
PID_DIR="$RUN_ROOT/pids"
LOG_DIR="${FORWARDER_LOG_DIR:-/var/log/smartproxy-forwarder}"

fatal(){ printf '[✗] %s\n' "$*" >&2; exit 1; }
info(){ printf '[*] %s\n' "$*"; }
warning(){ printf '[!] %s\n' "$*" >&2; }
success(){ printf '[✓] %s\n' "$*"; }

require_cmd(){ command -v "$1" >/dev/null 2>&1 || fatal "Missing required command: $1"; }

require_cmd "$SING_BOX"
require_cmd python3
require_cmd awk
require_cmd find
require_cmd sort
require_cmd sed
require_cmd ss
require_cmd grep
require_cmd pkill

[[ -f "$CSV_FILE" ]] || fatal "Winner CSV not found: $CSV_FILE"
[[ -d "$WINNER_DIR" ]] || fatal "Winner directory not found: $WINNER_DIR"
[[ "$BASE_PORT" =~ ^[0-9]+$ ]] || fatal "FORWARDER_BASE_PORT must be numeric"
(( MAX_INSTANCES > 0 && MAX_INSTANCES <= 16 )) || fatal "FORWARDER_MAX must be 1..16"

mkdir -p "$CONFIG_DIR" "$PID_DIR" "$LOG_DIR"
chmod 755 "$RUN_ROOT" "$CONFIG_DIR" "$PID_DIR" "$LOG_DIR"

# Stop only forwarder-managed processes.
stop_all(){
    shopt -s nullglob
    for pid_file in "$PID_DIR"/*.pid; do
        pid="$(cat "$pid_file" 2>/dev/null || true)"
        if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            for _ in {1..20}; do
                kill -0 "$pid" 2>/dev/null || break
                sleep 0.05
            done
            kill -9 "$pid" 2>/dev/null || true
        fi
        rm -f "$pid_file"
    done
    rm -f "$CONFIG_DIR"/*.json
    shopt -u nullglob
}

# Ensure a selected listener port is not occupied by an unrelated process.
check_port(){
    local port="$1"
    if ss -ltn 2>/dev/null | awk -v p=":$port" '$4 ~ p"$" {found=1} END{exit !found}'; then
        fatal "Port $port is already in use by another process."
    fi
}

# Resolve rankable winners directly from winner.csv.
mapfile -t WINNERS < <(
    python3 - "$CSV_FILE" "$WINNER_DIR" "$MAX_INSTANCES" <<'PY'
import csv
import sys
from pathlib import Path

csv_path = Path(sys.argv[1])
winner_dir = Path(sys.argv[2])
limit = int(sys.argv[3])

rows = []
with csv_path.open(newline='', encoding='utf-8') as f:
    for row in csv.DictReader(f):
        if row.get('Eligible','').strip().lower() != 'yes':
            continue
        status = row.get('Status','').strip().upper()
        if status != 'OK':
            continue
        profile = (row.get('Profile') or '').strip()
        if not profile:
            continue
        cfg = winner_dir / f'{profile}.json'
        if not cfg.is_file():
            continue
        try:
            score = float(row.get('Score','0'))
            rank = int(row.get('Rank','999999'))
        except ValueError:
            continue
        if score <= 0:
            continue
        rows.append((rank, -score, profile, str(cfg)))

rows.sort()
for item in rows[:limit]:
    print('\t'.join(map(str, item)))
PY
)

COUNT="${#WINNERS[@]}"
(( COUNT > 0 )) || fatal "No eligible winner configs found in $CSV_FILE"

stop_all

info "Starting $COUNT winner instance(s)..."
printf '  Bind address : %s\n' "$BIND_ADDR"
printf '  Port range   : %s-%s\n' "$BASE_PORT" "$((BASE_PORT + COUNT - 1))"
printf '  Winner dir   : %s\n\n' "$WINNER_DIR"

idx=0
for item in "${WINNERS[@]}"; do
    idx=$((idx + 1))
    IFS=$'\t' read -r rank negscore profile src <<< "$item"
    port=$((BASE_PORT + idx - 1))

    check_port "$port"

    cfg="$CONFIG_DIR/forwarder-$idx.json"
    log="$LOG_DIR/forwarder-$idx.log"
    pidfile="$PID_DIR/forwarder-$idx.pid"

    python3 - "$src" "$cfg" "$BIND_ADDR" "$port" <<'PY'
import json
import sys
from pathlib import Path

src = Path(sys.argv[1])
dst = Path(sys.argv[2])
bind = sys.argv[3]
port = int(sys.argv[4])

data = json.loads(src.read_text(encoding='utf-8'))
if not isinstance(data, dict):
    raise SystemExit('winner JSON root must be an object')

outbounds = data.get('outbounds')
if isinstance(outbounds, list):
    real = [
        o for o in outbounds
        if isinstance(o, dict) and o.get('type') not in {'direct','block'}
    ]
    if not real:
        raise SystemExit('winner config has no proxy outbound')

    # Prefer the route final when present; otherwise use the first real outbound.
    route = data.get('route')
    final = route.get('final') if isinstance(route, dict) else None
    chosen = next((o for o in real if o.get('tag') == final), real[0])
else:
    chosen = data

if not isinstance(chosen, dict) or not chosen.get('type'):
    raise SystemExit('invalid proxy outbound')

tag = str(chosen.get('tag') or f'forward-{port}')
chosen = dict(chosen, tag=tag)

cfg = {
    'log': {'level': 'error', 'timestamp': True},
    'inbounds': [{
        'type': 'socks',
        'tag': 'socks-in',
        'listen': bind,
        'listen_port': port,
    }],
    'outbounds': [
        chosen,
        {'type': 'direct', 'tag': 'direct'},
        {'type': 'block', 'tag': 'block'},
    ],
    'route': {
        'auto_detect_interface': True,
        'rules': [],
        'final': tag,
    },
}
dst.write_text(json.dumps(cfg, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')
PY

    "$SING_BOX" check -c "$cfg" >/dev/null 2>&1 || fatal "Invalid generated config for $profile"

    info "[$idx/$COUNT] $profile -> $BIND_ADDR:$port"

    "$SING_BOX" run -c "$cfg" >>"$log" 2>&1 &
    pid=$!
    echo "$pid" > "$pidfile"

    ready=0
    for _ in {1..40}; do
        if ! kill -0 "$pid" 2>/dev/null; then
            break
        fi
        if ss -ltn 2>/dev/null | awk -v p=":$port" '$4 ~ p"$" {found=1} END{exit !found}'; then
            ready=1
            break
        fi
        sleep 0.05
    done

    if (( ready == 0 )); then
        warning "$profile failed to start on port $port"
        [[ -s "$log" ]] && tail -n 8 "$log" >&2 || true
        stop_all
        exit 1
    fi

    success "Started PID=$pid on $BIND_ADDR:$port"
done

printf '\n'
printf '%-4s %-58s %-8s\n' 'Slot' 'Profile' 'Port'
printf '%s\n' '--------------------------------------------------------------------------------'
idx=0
for item in "${WINNERS[@]}"; do
    idx=$((idx + 1))
    IFS=$'\t' read -r rank negscore profile src <<< "$item"
    printf '%-4s %-58s %-8s\n' "$idx" "$profile" "$((BASE_PORT + idx - 1))"
done

printf '\n'
success "Forwarder complete: $COUNT independent sing-box instance(s) running."
printf 'Runtime : %s\n' "$RUN_ROOT"
printf 'Logs    : %s\n' "$LOG_DIR"
