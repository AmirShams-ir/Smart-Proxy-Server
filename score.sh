#!/usr/bin/env bash
set -Eeuo pipefail

# Smart Proxy Server - score engine
# Reads cache/validated/*.json, performs 3 RTT probes first, and only if all
# RTT probes succeed runs speedtest.sh for Download/Upload. Calculates a
# weighted 0-100 score including RTT + Jitter, writes cache/winner.csv, and
# copies the top 4 valid profiles into cache/winner/.

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALIDATED_DIR="${SCORE_VALIDATED_DIR:-$BASE_DIR/cache/validated}"
WINNER_DIR="${SCORE_WINNER_DIR:-$BASE_DIR/cache/winner}"
CSV_FILE="${SCORE_CSV:-$BASE_DIR/cache/winner.csv}"
TOP_N="${SCORE_TOP:-4}"
RTT_PROBES="${SCORE_RTT_PROBES:-3}"
RTT_TIMEOUT="${SCORE_RTT_TIMEOUT:-8}"
DOWNLOAD_WEIGHT="${SCORE_DOWNLOAD_WEIGHT:-40}"
UPLOAD_WEIGHT="${SCORE_UPLOAD_WEIGHT:-25}"
RTT_WEIGHT="${SCORE_RTT_WEIGHT:-20}"
JITTER_WEIGHT="${SCORE_JITTER_WEIGHT:-15}"
SPEEDTEST_TIMEOUT="${SCORE_SPEEDTEST_TIMEOUT:-15}"
DOWNLOAD_BYTES="${SCORE_DOWNLOAD_BYTES:-1048576}"
UPLOAD_BYTES="${SCORE_UPLOAD_BYTES:-524288}"
SPEEDTEST="$BASE_DIR/speedtest.sh"
SING_BOX="${SING_BOX_BIN:-sing-box}"

fatal(){ printf '[✗] %s\n' "$*" >&2; exit 1; }
info(){ printf '[*] %s\n' "$*"; }
warning(){ printf '[!] %s\n' "$*" >&2; }
success(){ printf '[✓] %s\n' "$*"; }
require_cmd(){ command -v "$1" >/dev/null 2>&1 || fatal "Missing required command: $1"; }

require_cmd python3
require_cmd awk
require_cmd sort
require_cmd find
require_cmd sed
require_cmd grep
require_cmd date
require_cmd ss
require_cmd curl
require_cmd "$SING_BOX"
[[ -f "$SPEEDTEST" ]] || fatal "speedtest.sh not found: $SPEEDTEST"
[[ -d "$VALIDATED_DIR" ]] || fatal "Validated directory not found: $VALIDATED_DIR"

# Do not depend on Git executable bits.
SPEEDTEST_CMD=(bash "$SPEEDTEST")

mkdir -p "$WINNER_DIR" "$(dirname "$CSV_FILE")"
rm -f "$WINNER_DIR"/*.json

TMP_DIR="$(mktemp -d /tmp/smartproxy-score.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM
RESULTS="$TMP_DIR/results.tsv"
: > "$RESULTS"

TOTAL_WEIGHT=$((DOWNLOAD_WEIGHT + UPLOAD_WEIGHT + RTT_WEIGHT + JITTER_WEIGHT))
(( TOTAL_WEIGHT == 100 )) || fatal "Score weights must sum to 100 (got $TOTAL_WEIGHT)"
(( TOP_N > 0 )) || fatal "SCORE_TOP must be greater than zero"
(( RTT_PROBES >= 1 )) || fatal "SCORE_RTT_PROBES must be >= 1"

mapfile -t CONFIGS < <(find "$VALIDATED_DIR" -maxdepth 1 -type f -name '*.json' -print | sort)
CONFIG_COUNT="${#CONFIGS[@]}"
(( CONFIG_COUNT > 0 )) || fatal "No JSON configs found in $VALIDATED_DIR"

info "Scoring $CONFIG_COUNT validated profiles..."
printf '  Validated : %s\n' "$VALIDATED_DIR"
printf '  Speedtest : bash %s\n' "$SPEEDTEST"
printf '  Probes    : %s RTT samples/profile\n' "$RTT_PROBES"
printf '  Weights   : Down=%s%% Up=%s%% RTT=%s%% Jitter=%s%%\n\n' \
    "$DOWNLOAD_WEIGHT" "$UPLOAD_WEIGHT" "$RTT_WEIGHT" "$JITTER_WEIGHT"

profile_name(){ basename "$1" .json; }

###############################################################################
# Build one isolated sing-box SOCKS config for RTT probes.
###############################################################################
build_rtt_config(){
    local input="$1" cfg="$2" port="$3"

    python3 - "$input" "$cfg" "$port" <<'PY'
import json
import os
import sys
from pathlib import Path

src = Path(sys.argv[1])
out = Path(sys.argv[2])
port = int(sys.argv[3])

data = json.loads(src.read_text(encoding='utf-8'))
if not isinstance(data, dict):
    raise SystemExit('JSON root must be an object')

if 'outbounds' in data:
    outbounds = data.get('outbounds') or []
    if not outbounds:
        raise SystemExit('full config contains no outbounds')

    wanted = os.environ.get('SCORE_OUTBOUND', '').strip()
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
        'tag': 'score-rtt-in',
        'listen': '127.0.0.1',
        'listen_port': port,
    }]
    cfg['route'] = dict(cfg.get('route') or {})
    cfg['route']['final'] = wanted
    cfg['route']['rules'] = []
    cfg.pop('experimental', None)
    out.write_text(json.dumps(cfg, indent=2, ensure_ascii=False), encoding='utf-8')
    raise SystemExit(0)

outbound = dict(data)
tag = str(outbound.pop('tag', 'score-rtt-out')) or 'score-rtt-out'

cfg = {
    'log': {'level': 'error'},
    'inbounds': [{
        'type': 'socks',
        'tag': 'score-rtt-in',
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
PY
}

###############################################################################
# RTT gate + jitter measurement.
# All probes must succeed before speedtest.sh is allowed to run.
# Output: "RTT<TAB>JITTER" or "-<TAB>-"
###############################################################################
measure_rtt_jitter(){
    local input="$1" port="$2" run_dir="$TMP_DIR/rtt-$port"
    local cfg="$run_dir/config.json" pid="" ready=0
    local samples="" sample http rc

    mkdir -p "$run_dir"

    if ! build_rtt_config "$input" "$cfg" "$port" >"$run_dir/build.out" 2>"$run_dir/build.err"; then
        printf -- '-\t-\n'
        return 1
    fi

    if ! "$SING_BOX" check -c "$cfg" >"$run_dir/check.out" 2>&1; then
        printf -- '-\t-\n'
        return 1
    fi

    "$SING_BOX" run -c "$cfg" >"$run_dir/sing-box.log" 2>"$run_dir/sing-box.err" &
    pid=$!

    for _ in {1..30}; do
        if ss -lnt 2>/dev/null | grep -Eq '[:.]'"$port"'[[:space:]]'; then
            ready=1
            break
        fi
        if ! kill -0 "$pid" 2>/dev/null; then
            break
        fi
        sleep 0.05
    done

    if (( ready == 0 )); then
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        printf -- '-\t-\n'
        return 1
    fi

    for ((i=1; i<=RTT_PROBES; i++)); do
        set +e
        sample="$(curl -4 -L --max-time "$RTT_TIMEOUT" --connect-timeout 4 \
            --socks5-hostname "127.0.0.1:$port" \
            -sS -o /dev/null \
            -w '%{http_code}|%{time_total}' \
            'https://cp.cloudflare.com/generate_204' 2>"$run_dir/curl-$i.err")"
        rc=$?
        set -e

        http="${sample%%|*}"
        sample="${sample#*|}"

        if (( rc != 0 )) || [[ ! "$http" =~ ^2[0-9][0-9]$ ]] || [[ ! "$sample" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
            printf -- '-\t-\n'
            return 1
        fi

        # curl reports seconds; store milliseconds with sub-ms precision.
        ms="$(awk -v s="$sample" 'BEGIN{printf "%.2f", s*1000}')"
        samples+=" $ms"

        # Avoid hammering the same endpoint immediately three times.
        (( i < RTT_PROBES )) && sleep 0.10
    done

    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true

    awk -v values="$samples" '
        BEGIN {
            n=split(values,a," ");
            count=0; sum=0;
            for(i=1;i<=n;i++) if(a[i] != "") { count++; sum+=a[i]; }
            if(count < 1) exit 1;
            mean=sum/count;
            dev=0;
            for(i=1;i<=n;i++) if(a[i] != "") dev+=((a[i]-mean)<0 ? -(a[i]-mean) : (a[i]-mean));
            jitter=dev/count;
            printf "%.2f\t%.2f\n", mean, jitter;
        }
    '
}

printf '%-58s %8s %9s %10s %10s %8s\n' \
    'Profile' 'RTT(ms)' 'Jitter' 'Download' 'Upload' 'Score'
printf '%s\n' '----------------------------------------------------------------------------------------------------------------'

index=0
for input in "${CONFIGS[@]}"; do
    index=$((index+1))
    name="$(profile_name "$input")"
    info "[$index/$CONFIG_COUNT] Testing $name" >&2

    port=$((15000 + index))

    # -------------------------------------------------------------------------
    # Stage 1: RTT gate + jitter. If RTT is unavailable, stop here.
    # -------------------------------------------------------------------------
    rtt_jitter="$(measure_rtt_jitter "$input" "$port")" || true
    rtt="${rtt_jitter%%$'\t'*}"
    jitter="${rtt_jitter#*$'\t'}"

    if [[ "$rtt" == "-" || "$jitter" == "-" || ! "$rtt" =~ ^[0-9]+([.][0-9]+)?$ || ! "$jitter" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        printf '%s\t%s\t-\t-\t0\t0\n' "$input" "$name" >> "$RESULTS"
        printf '%-58s %8s %9s %10s %10s %8s\n' "$name" '-' '-' '-' '-' 'SKIP'
        info "[$index/$CONFIG_COUNT] RTT gate failed; skipping Download/Upload for $name" >&2
        continue
    fi

    # -------------------------------------------------------------------------
    # Stage 2: expensive transfer tests are only run after RTT passes.
    # -------------------------------------------------------------------------
    out="$TMP_DIR/speed-$index.out"
    set +e
    SCORE_DOWNLOAD_BYTES="$DOWNLOAD_BYTES" \
    SCORE_UPLOAD_BYTES="$UPLOAD_BYTES" \
    SPEEDTEST_TIMEOUT="$SPEEDTEST_TIMEOUT" \
    "${SPEEDTEST_CMD[@]}" "$input" >"$out" 2>"$TMP_DIR/speed-$index.err"
    speed_rc=$?
    set -e

    download="$(awk '/^Download[[:space:]]+[0-9.]+ Mbps/{print $2; exit}' "$out" 2>/dev/null || true)"
    upload="$(awk '/^Upload[[:space:]]+[0-9.]+ Mbps/{print $2; exit}' "$out" 2>/dev/null || true)"
    [[ "$download" =~ ^[0-9]+([.][0-9]+)?$ ]] || download=0
    [[ "$upload" =~ ^[0-9]+([.][0-9]+)?$ ]] || upload=0

    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$input" "$name" "$rtt" "$jitter" "$download" "$upload" >> "$RESULTS"
    printf '%-58s %8s %9s %10s %10s %8s\n' "$name" "$rtt" "$jitter" "$download" "$upload" '-'

    (( speed_rc != 0 )) && warning "$name speedtest returned rc=$speed_rc; measured values retained" >&2 || true
done

###############################################################################
# Normalize and rank.
###############################################################################
python3 - "$RESULTS" "$CSV_FILE" "$WINNER_DIR" "$TOP_N" "$DOWNLOAD_WEIGHT" "$UPLOAD_WEIGHT" "$RTT_WEIGHT" "$JITTER_WEIGHT" <<'PY'
import csv, math, shutil, sys
from pathlib import Path

results = Path(sys.argv[1])
csv_file = Path(sys.argv[2])
winner_dir = Path(sys.argv[3])
top_n = int(sys.argv[4])
wd, wu, wr, wj = map(float, sys.argv[5:9])

rows=[]
for line in results.read_text(encoding='utf-8').splitlines():
    if not line.strip():
        continue
    path,name,rtt,jitter,down,up=line.split('\t')
    rtt_v = None if rtt in ('-', '0') else float(rtt)
    jitter_v = None if jitter in ('-', '0') else float(jitter)
    rows.append({
        'path':path,
        'name':name,
        'rtt':rtt_v,
        'jitter':jitter_v,
        'download':float(down),
        'upload':float(up),
    })

# Only profiles with successful RTT + jitter + transfer tests are rankable.
rankable=[r for r in rows if r['rtt'] is not None and r['jitter'] is not None and r['download']>0 and r['upload']>0]
max_down=max((r['download'] for r in rankable), default=0.0)
max_up=max((r['upload'] for r in rankable), default=0.0)
min_rtt=min((r['rtt'] for r in rankable), default=0.0)
min_jitter=min((r['jitter'] for r in rankable), default=0.0)

for r in rows:
    if r not in rankable:
        r['score']=0.0
        continue

    down_score=(r['download']/max_down*100.0) if max_down else 0.0
    up_score=(r['upload']/max_up*100.0) if max_up else 0.0
    rtt_score=(min_rtt/r['rtt']*100.0) if min_rtt and r['rtt'] else 0.0
    jitter_score=(min_jitter/r['jitter']*100.0) if min_jitter and r['jitter'] else 0.0
    r['score']=round(
        (down_score*wd + up_score*wu + rtt_score*wr + jitter_score*wj)/100.0,
        2,
    )

rows.sort(key=lambda r:(
    -r['score'],
    -r['download'],
    -r['upload'],
    r['rtt'] if r['rtt'] is not None else math.inf,
    r['jitter'] if r['jitter'] is not None else math.inf,
    r['name'],
))

with csv_file.open('w', newline='', encoding='utf-8') as f:
    w=csv.writer(f)
    w.writerow(['Rank','Profile','RTT_ms','Jitter_ms','Download_Mbps','Upload_Mbps','Score'])
    for i,r in enumerate(rows,1):
        w.writerow([
            i,
            r['name'],
            f"{r['rtt']:.2f}" if r['rtt'] is not None else '-',
            f"{r['jitter']:.2f}" if r['jitter'] is not None else '-',
            f"{r['download']:.2f}",
            f"{r['upload']:.2f}",
            f"{r['score']:.2f}",
        ])

for old in winner_dir.glob('*.json'):
    old.unlink(missing_ok=True)

selected=[r for r in rows if r['score']>0][:min(top_n, len(rows))]
for r in selected:
    shutil.copy2(r['path'], winner_dir / Path(r['path']).name)

print(f"{'Rank':>4} {'Profile':<58} {'RTT(ms)':>8} {'Jitter':>9} {'Download':>10} {'Upload':>10} {'Score':>8}")
print('-'*116)
for i,r in enumerate(rows,1):
    rtt='-' if r['rtt'] is None else f"{r['rtt']:.2f}"
    jitter='-' if r['jitter'] is None else f"{r['jitter']:.2f}"
    print(
        f"{i:>4} {r['name']:<58} {rtt:>8} {jitter:>9} "
        f"{r['download']:>10.2f} {r['upload']:>10.2f} {r['score']:>8.2f}"
    )
PY

success "Score complete"
printf 'CSV     : %s\n' "$CSV_FILE"
printf 'Winners : %s\n' "$WINNER_DIR"
printf 'Top     : %s\n' "$TOP_N"
