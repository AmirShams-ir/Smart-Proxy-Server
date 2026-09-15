#!/usr/bin/env bash
set -Eeuo pipefail

# Smart Proxy Server - score engine
# Reads cache/validated/*.json, measures Download/Upload with speedtest.sh,
# measures RTT, calculates a weighted 0-100 score, writes cache/winner.csv,
# and copies the top 4 configs into cache/winner/.

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALIDATED_DIR="${SCORE_VALIDATED_DIR:-$BASE_DIR/cache/validated}"
WINNER_DIR="${SCORE_WINNER_DIR:-$BASE_DIR/cache/winner}"
CSV_FILE="${SCORE_CSV:-$BASE_DIR/cache/winner.csv}"
TOP_N="${SCORE_TOP:-4}"
RTT_TIMEOUT="${SCORE_RTT_TIMEOUT:-8}"
DOWNLOAD_WEIGHT="${SCORE_DOWNLOAD_WEIGHT:-45}"
UPLOAD_WEIGHT="${SCORE_UPLOAD_WEIGHT:-30}"
RTT_WEIGHT="${SCORE_RTT_WEIGHT:-25}"
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

TOTAL_WEIGHT=$((DOWNLOAD_WEIGHT + UPLOAD_WEIGHT + RTT_WEIGHT))
(( TOTAL_WEIGHT == 100 )) || fatal "Score weights must sum to 100 (got $TOTAL_WEIGHT)"
(( TOP_N > 0 )) || fatal "SCORE_TOP must be greater than zero"

mapfile -t CONFIGS < <(find "$VALIDATED_DIR" -maxdepth 1 -type f -name '*.json' -print | sort)
CONFIG_COUNT="${#CONFIGS[@]}"
(( CONFIG_COUNT > 0 )) || fatal "No JSON configs found in $VALIDATED_DIR"

info "Scoring $CONFIG_COUNT validated profiles..."
printf '  Validated : %s\n' "$VALIDATED_DIR"
printf '  Speedtest : bash %s\n' "$SPEEDTEST"
printf '  Weights   : Down=%s%% Up=%s%% RTT=%s%%\n\n' "$DOWNLOAD_WEIGHT" "$UPLOAD_WEIGHT" "$RTT_WEIGHT"

profile_name(){
    # Keep the complete filename because maker.sh encodes protocol/edge/port/
    # transport/security in it. This prevents all BPB_trojan profiles collapsing
    # into the same display name.
    basename "$1" .json
}

measure_rtt(){
    local input="$1" port="$2" run_dir="$TMP_DIR/rtt-$port"
    local cfg="$run_dir/config.json" pid="" ready=0 http rc t0 t1
    mkdir -p "$run_dir"

    if ! python3 - "$input" "$cfg" "$port" <<'PY'
import json,os,sys
from pathlib import Path
src=Path(sys.argv[1]); out=Path(sys.argv[2]); port=int(sys.argv[3])
data=json.loads(src.read_text(encoding='utf-8'))
if not isinstance(data,dict): raise SystemExit(1)
if 'outbounds' in data:
    obs=data.get('outbounds') or []
    wanted=os.environ.get('SCORE_OUTBOUND','').strip()
    route=data.get('route') or {}
    if not wanted and isinstance(route,dict):
        final=route.get('final')
        if isinstance(final,str) and final: wanted=final
    if not wanted:
        for item in obs:
            if isinstance(item,dict) and item.get('tag'):
                wanted=str(item['tag']); break
    selected=next((x for x in obs if isinstance(x,dict) and x.get('tag')==wanted),None)
    if selected is None: raise SystemExit(1)
    cfg=dict(data)
    cfg['inbounds']=[{'type':'socks','tag':'score-rtt-in','listen':'127.0.0.1','listen_port':port}]
    cfg['route']=dict(cfg.get('route') or {})
    cfg['route']['final']=wanted
    cfg['route']['rules']=[]
    cfg.pop('experimental',None)
    out.write_text(json.dumps(cfg,indent=2,ensure_ascii=False),encoding='utf-8')
else:
    ob=dict(data); tag=str(ob.pop('tag','score-rtt-out')) or 'score-rtt-out'
    cfg={'log':{'level':'error'},'inbounds':[{'type':'socks','tag':'score-rtt-in','listen':'127.0.0.1','listen_port':port}], 'outbounds':[dict(ob,tag=tag),{'type':'direct','tag':'direct'},{'type':'block','tag':'block'}], 'route':{'final':tag,'rules':[]}}
    out.write_text(json.dumps(cfg,indent=2,ensure_ascii=False),encoding='utf-8')
PY
    then
        echo "-"; return
    fi

    if ! "$SING_BOX" check -c "$cfg" >/dev/null 2>&1; then echo "-"; return; fi
    "$SING_BOX" run -c "$cfg" >"$run_dir/sing-box.log" 2>"$run_dir/sing-box.err" & pid=$!
    for _ in {1..30}; do
        if ss -lnt 2>/dev/null | grep -Eq '[:.]'"$port"'[[:space:]]'; then ready=1; break; fi
        if ! kill -0 "$pid" 2>/dev/null; then break; fi
        sleep 0.05
    done
    if (( ready == 0 )); then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; echo "-"; return; fi

    t0="$(date +%s%N)"
    set +e
    http="$(curl -4 -L --max-time "$RTT_TIMEOUT" --connect-timeout 4 --socks5-hostname "127.0.0.1:$port" -sS -o /dev/null -w '%{http_code}' 'https://cp.cloudflare.com/generate_204' 2>"$run_dir/curl.err")"
    rc=$?
    set -e
    t1="$(date +%s%N)"
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    if (( rc == 0 )) && [[ "$http" =~ ^2[0-9][0-9]$ ]]; then
        awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.2f",(b-a)/1000000}'
    else
        echo "-"
    fi
}

printf '%-58s %8s %10s %10s %8s\n' 'Profile' 'RTT(ms)' 'Download' 'Upload' 'Score'
printf '%s\n' '----------------------------------------------------------------------------------------------------------'

index=0
for input in "${CONFIGS[@]}"; do
    index=$((index+1))
    name="$(profile_name "$input")"
    info "[$index/$CONFIG_COUNT] Testing $name" >&2

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

    port=$((15000 + index))
    rtt="$(measure_rtt "$input" "$port")"
    printf '%s\t%s\t%s\t%s\t%s\n' "$input" "$name" "$rtt" "$download" "$upload" >> "$RESULTS"
    printf '%-58s %8s %10s %10s %8s\n' "$name" "$rtt" "$download" "$upload" '-'
    (( speed_rc != 0 )) && warning "$name speedtest returned rc=$speed_rc; measured values retained" >&2 || true
done

python3 - "$RESULTS" "$CSV_FILE" "$WINNER_DIR" "$TOP_N" "$DOWNLOAD_WEIGHT" "$UPLOAD_WEIGHT" "$RTT_WEIGHT" <<'PY'
import csv,math,shutil,sys
from pathlib import Path
results=Path(sys.argv[1]); csv_file=Path(sys.argv[2]); winner_dir=Path(sys.argv[3])
top_n=int(sys.argv[4]); wd,wu,wr=map(float,sys.argv[5:8])
rows=[]
for line in results.read_text(encoding='utf-8').splitlines():
    if line.strip():
        path,name,rtt,down,up=line.split('\t')
        rtt_val=None if rtt == '-' else float(rtt)
        rows.append({'path':path,'name':name,'rtt':rtt_val,'download':float(down),'upload':float(up)})

# Only candidates with valid RTT are rankable. A failed RTT must not become RTT=0,
# because 0 ms would otherwise be interpreted as the best possible latency.
rankable=[r for r in rows if r['rtt'] is not None and r['rtt']>0]
max_down=max((r['download'] for r in rankable),default=0.0)
max_up=max((r['upload'] for r in rankable),default=0.0)
min_rtt=min((r['rtt'] for r in rankable),default=0.0)

for r in rows:
    if r not in rankable:
        r['score']=0.0
        continue
    ds=(r['download']/max_down*100) if max_down else 0.0
    us=(r['upload']/max_up*100) if max_up else 0.0
    rs=(min_rtt/r['rtt']*100) if min_rtt and r['rtt'] else 0.0
    r['score']=round((ds*wd+us*wu+rs*wr)/100,2)

rows.sort(key=lambda r:(-r['score'],-r['download'],-r['upload'],r['rtt'] if r['rtt'] is not None else math.inf,r['name']))

with csv_file.open('w',newline='',encoding='utf-8') as f:
    w=csv.writer(f); w.writerow(['Rank','Profile','RTT_ms','Download_Mbps','Upload_Mbps','Score'])
    for i,r in enumerate(rows,1):
        w.writerow([i,r['name'],f"{r['rtt']:.2f}" if r['rtt'] is not None else '-',f"{r['download']:.2f}",f"{r['upload']:.2f}",f"{r['score']:.2f}"])

for old in winner_dir.glob('*.json'): old.unlink(missing_ok=True)
selected=[r for r in rows if r['score']>0][:min(top_n,len(rows))]
for r in selected:
    shutil.copy2(r['path'],winner_dir/Path(r['path']).name)

print(f"{'Rank':>4} {'Profile':<58} {'RTT(ms)':>8} {'Download':>10} {'Upload':>10} {'Score':>8}")
print('-'*106)
for i,r in enumerate(rows,1):
    rtt='-' if r['rtt'] is None else f"{r['rtt']:.2f}"
    print(f"{i:>4} {r['name']:<58} {rtt:>8} {r['download']:>10.2f} {r['upload']:>10.2f} {r['score']:>8.2f}")
PY

success "Score complete"
printf 'CSV     : %s\n' "$CSV_FILE"
printf 'Winners : %s\n' "$WINNER_DIR"
printf 'Top     : %s\n' "$TOP_N"
