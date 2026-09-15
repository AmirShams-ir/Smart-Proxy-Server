#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================================
# Smart Proxy Server - score engine
#
# Read every JSON candidate from cache/validated, run speedtest.sh, calculate
# a deterministic 0-100 score, write cache/winner.csv, and copy the best four
# profiles into cache/winner/.
#
# Usage:
#   bash score.sh
#
# Optional environment variables:
#   SCORE_VALIDATED_DIR=cache/validated
#   SCORE_WINNER_DIR=cache/winner
#   SCORE_CSV=cache/winner.csv
#   SCORE_RTT_TIMEOUT=8
#   SCORE_DOWNLOAD_WEIGHT=45
#   SCORE_UPLOAD_WEIGHT=30
#   SCORE_RTT_WEIGHT=25
#   SCORE_TOP=4
#   SCORE_SPEEDTEST_TIMEOUT=15
#   SCORE_DOWNLOAD_BYTES=1048576
#   SCORE_UPLOAD_BYTES=524288
#
# Scoring:
#   Download: normalized against the fastest candidate
#   Upload:   normalized against the fastest candidate
#   RTT:      inverted normalized against the lowest RTT
#
# Final score is a weighted 0-100 value.
# ============================================================================

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
success(){ printf '[✓] %s\n' "$*"; }
warning(){ printf '[!] %s\n' "$*" >&2; }

require_cmd(){ command -v "$1" >/dev/null 2>&1 || fatal "Missing required command: $1"; }

require_cmd python3
require_cmd awk
require_cmd sort
require_cmd cp
require_cmd find
require_cmd sed
require_cmd grep
require_cmd date
require_cmd "$SING_BOX"
[[ -x "$SPEEDTEST" ]] || fatal "speedtest.sh is not executable: $SPEEDTEST"
[[ -d "$VALIDATED_DIR" ]] || fatal "Validated directory not found: $VALIDATED_DIR"

mkdir -p "$WINNER_DIR"
rm -f "$WINNER_DIR"/*.json
mkdir -p "$(dirname "$CSV_FILE")"

TMP_DIR="$(mktemp -d /tmp/smartproxy-score.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM
RESULTS="$TMP_DIR/results.tsv"
: > "$RESULTS"

###############################################################################
# Weighted score inputs must be valid and sum to 100.
###############################################################################
TOTAL_WEIGHT=$((DOWNLOAD_WEIGHT + UPLOAD_WEIGHT + RTT_WEIGHT))
(( TOTAL_WEIGHT == 100 )) || fatal "Score weights must sum to 100 (got $TOTAL_WEIGHT)"
(( TOP_N > 0 )) || fatal "SCORE_TOP must be greater than zero"

mapfile -t CONFIGS < <(find "$VALIDATED_DIR" -maxdepth 1 -type f -name '*.json' -print | sort)
CONFIG_COUNT="${#CONFIGS[@]}"
(( CONFIG_COUNT > 0 )) || fatal "No JSON configs found in $VALIDATED_DIR"

info "Scoring $CONFIG_COUNT validated profiles..."
printf '  Validated : %s\n' "$VALIDATED_DIR"
printf '  Speedtest : %s\n' "$SPEEDTEST"
printf '  Weights   : Down=%s%% Up=%s%% RTT=%s%%\n' "$DOWNLOAD_WEIGHT" "$UPLOAD_WEIGHT" "$RTT_WEIGHT"
printf '\n'

###############################################################################
# Extract a profile tag from JSON. Works for a complete config or a fragment.
###############################################################################
profile_name(){
    python3 - "$1" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
data = json.loads(p.read_text(encoding='utf-8'))
name = None
if isinstance(data, dict):
    route = data.get('route') or {}
    if isinstance(route, dict):
        final = route.get('final')
        if isinstance(final, str) and final:
            name = final
    if not name and isinstance(data.get('outbounds'), list):
        for item in data['outbounds']:
            if isinstance(item, dict) and item.get('tag'):
                name = str(item['tag'])
                break
    if not name:
        name = str(data.get('tag') or '')
if not name:
    name = Path(sys.argv[1]).stem
print(name)
PY
}

###############################################################################
# RTT test using sing-box + temporary local SOCKS, matching speedtest's model.
###############################################################################
measure_rtt(){
    local input="$1"
    local port="$2"
    local run_dir="$TMP_DIR/rtt-$port"
    local cfg="$run_dir/config.json"
    local meta="$run_dir/meta.txt"
    local log="$run_dir/sing-box.log"
    local err="$run_dir/sing-box.err"
    local pid=""

    mkdir -p "$run_dir"

    if ! python3 - "$input" "$cfg" "$port" "$meta" <<'PY'
import json, os, sys
from pathlib import Path
src=Path(sys.argv[1]); out=Path(sys.argv[2]); port=int(sys.argv[3]); meta=Path(sys.argv[4])
data=json.loads(src.read_text(encoding='utf-8'))
if not isinstance(data, dict): raise SystemExit('JSON root must be an object')
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
    if selected is None: raise SystemExit('outbound not found')
    cfg=dict(data)
    cfg['inbounds']=[{'type':'socks','tag':'score-rtt-in','listen':'127.0.0.1','listen_port':port}]
    cfg['route']=dict(cfg.get('route') or {})
    cfg['route']['final']=wanted
    cfg['route']['rules']=[]
    cfg.pop('experimental',None)
    out.write_text(json.dumps(cfg,indent=2,ensure_ascii=False),encoding='utf-8')
    with meta.open('w',encoding='utf-8') as f:
        print(wanted,file=f)
    raise SystemExit(0)

ob=dict(data); tag=str(ob.pop('tag','score-rtt-out')) or 'score-rtt-out'
cfg={'log':{'level':'error'},'inbounds':[{'type':'socks','tag':'score-rtt-in','listen':'127.0.0.1','listen_port':port}], 'outbounds':[dict(ob,tag=tag),{'type':'direct','tag':'direct'},{'type':'block','tag':'block'}], 'route':{'final':tag,'rules':[]}}
out.write_text(json.dumps(cfg,indent=2,ensure_ascii=False),encoding='utf-8')
meta.write_text(tag+'\n',encoding='utf-8')
PY
    then
        echo "-"
        return 0
    fi

    if ! "$SING_BOX" check -c "$cfg" >"$run_dir/check.out" 2>&1; then
        echo "-"
        return 0
    fi

    "$SING_BOX" run -c "$cfg" >"$log" 2>"$err" &
    pid=$!
    trap 'if [[ -n "${pid:-}" ]] && kill -0 "$pid" 2>/dev/null; then kill "$pid" 2>/dev/null || true; fi' RETURN

    local ready=0
    for _ in {1..30}; do
        if ss -lnt 2>/dev/null | grep -Eq '[:.]'"$port"'[[:space:]]'; then ready=1; break; fi
        if ! kill -0 "$pid" 2>/dev/null; then break; fi
        sleep 0.05
    done
    if (( ready == 0 )); then
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        echo "-"
        return 0
    fi

    local t0 t1 avg
    t0="$(date +%s%N)"
    if ! timeout "$RTT_TIMEOUT" curl -4 -L --max-time "$RTT_TIMEOUT" --connect-timeout 4 --socks5-hostname "127.0.0.1:$port" -sS -o /dev/null -w '%{http_code}' 'https://cp.cloudflare.com/generate_204' >"$run_dir/http" 2>"$run_dir/curl.err"; then
        kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; echo "-"; return 0
    fi
    t1="$(date +%s%N)"
    http="$(tr -d '\r\n ' < "$run_dir/http")"
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    if [[ "$http" =~ ^2[0-9][0-9]$ ]]; then
        awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.2f",(b-a)/1000000}'
    else
        echo "-"
    fi
}

###############################################################################
# Header.
###############################################################################
printf '%-46s %8s %10s %10s %8s\n' 'Profile' 'RTT(ms)' 'Download' 'Upload' 'Score'
printf '%s\n' '------------------------------------------------------------------------------------------'

index=0
for input in "${CONFIGS[@]}"; do
    index=$((index+1))
    name="$(profile_name "$input" 2>/dev/null || basename "$input" .json)"
    info "[$index/$CONFIG_COUNT] Testing $name" >&2

    out="$TMP_DIR/speed-$index.out"
    set +e
    SCORE_DOWNLOAD_BYTES="$DOWNLOAD_BYTES" \
    SCORE_UPLOAD_BYTES="$UPLOAD_BYTES" \
    SPEEDTEST_TIMEOUT="$SPEEDTEST_TIMEOUT" \
    "$SPEEDTEST" "$input" >"$out" 2>"$TMP_DIR/speed-$index.err"
    speed_rc=$?
    set -e

    download="$(awk '/^Download[[:space:]]+[0-9.]+ Mbps/{print $2; exit}' "$out" 2>/dev/null || true)"
    upload="$(awk '/^Upload[[:space:]]+[0-9.]+ Mbps/{print $2; exit}' "$out" 2>/dev/null || true)"
    [[ "$download" =~ ^[0-9]+([.][0-9]+)?$ ]] || download=0
    [[ "$upload" =~ ^[0-9]+([.][0-9]+)?$ ]] || upload=0

    port=$((15000 + index))
    rtt="$(measure_rtt "$input" "$port")"
    [[ "$rtt" =~ ^[0-9]+([.][0-9]+)?$ ]] || rtt=0

    printf '%s\t%s\t%s\t%s\t%s\n' "$input" "$name" "$rtt" "$download" "$upload" >> "$RESULTS"
    printf '%-46s %8s %10s %10s %8s\n' "$name" "$rtt" "$download" "$upload" '-'

    if (( speed_rc != 0 )); then
        warning "$name speedtest returned rc=$speed_rc; usable measured values were retained" >&2
    fi
done

###############################################################################
# Normalize and score all candidates after every raw measurement is collected.
###############################################################################
python3 - "$RESULTS" "$CSV_FILE" "$WINNER_DIR" "$TOP_N" "$DOWNLOAD_WEIGHT" "$UPLOAD_WEIGHT" "$RTT_WEIGHT" <<'PY'
import csv, math, os, shutil, sys
from pathlib import Path

results = Path(sys.argv[1])
csv_file = Path(sys.argv[2])
winner_dir = Path(sys.argv[3])
top_n = int(sys.argv[4])
w_down, w_up, w_rtt = map(float, sys.argv[5:8])

rows=[]
for line in results.read_text(encoding='utf-8').splitlines():
    if not line.strip(): continue
    path,name,rtt,down,up=line.split('\t')
    rows.append({'path':path,'name':name,'rtt':float(rtt),'download':float(down),'upload':float(up)})

max_down=max((r['download'] for r in rows), default=0.0)
max_up=max((r['upload'] for r in rows), default=0.0)
valid_rtt=[r['rtt'] for r in rows if r['rtt']>0]
min_rtt=min(valid_rtt, default=0.0)

for r in rows:
    down_score=(r['download']/max_down*100.0) if max_down>0 else 0.0
    up_score=(r['upload']/max_up*100.0) if max_up>0 else 0.0
    rtt_score=(min_rtt/r['rtt']*100.0) if (min_rtt>0 and r['rtt']>0) else 0.0
    r['down_score']=down_score
    r['up_score']=up_score
    r['rtt_score']=rtt_score
    r['score']=round((down_score*w_down + up_score*w_up + rtt_score*w_rtt)/100.0,2)

# Stable deterministic ordering: score, download, upload, RTT, profile.
rows.sort(key=lambda r:(-r['score'],-r['download'],-r['upload'],r['rtt'] if r['rtt']>0 else math.inf,r['name']))

csv_file.parent.mkdir(parents=True,exist_ok=True)
with csv_file.open('w',newline='',encoding='utf-8') as f:
    writer=csv.writer(f)
    writer.writerow(['Rank','Profile','RTT_ms','Download_Mbps','Upload_Mbps','Score'])
    for i,r in enumerate(rows,1):
        writer.writerow([i,r['name'],f"{r['rtt']:.2f}" if r['rtt'] else '-',f"{r['download']:.2f}",f"{r['upload']:.2f}",f"{r['score']:.2f}"])

# Replace winner directory contents atomically-ish by clearing only JSON files.
for old in winner_dir.glob('*.json'):
    old.unlink(missing_ok=True)

selected=rows[:min(top_n,len(rows))]
for rank,r in enumerate(selected,1):
    src=Path(r['path'])
    dst=winner_dir / src.name
    shutil.copy2(src,dst)

# Emit final table for shell.
print('FINAL_HEADER')
print(f"{'Rank':>4} {'Profile':<46} {'RTT(ms)':>8} {'Download':>10} {'Upload':>10} {'Score':>8}")
print('-'*86)
for i,r in enumerate(rows,1):
    print(f"{i:>4} {r['name']:<46} {r['rtt']:>8.2f} {r['download']:>10.2f} {r['upload']:>10.2f} {r['score']:>8.2f}")
print('WINNERS')
for i,r in enumerate(selected,1):
    print(f"{i}\t{r['name']}\t{Path(r['path']).name}\t{r['score']:.2f}")
PY

###############################################################################
# Re-print scored table with progress-safe formatting and winner summary.
###############################################################################
SCORE_OUTPUT="$(python3 - "$RESULTS" "$DOWNLOAD_WEIGHT" "$UPLOAD_WEIGHT" "$RTT_WEIGHT" <<'PY'
import math,sys
from pathlib import Path
results=Path(sys.argv[1]); wd,wu,wr=map(float,sys.argv[2:5])
rows=[]
for line in results.read_text().splitlines():
    if not line.strip(): continue
    path,name,rtt,down,up=line.split('\t')
    rows.append({'path':path,'name':name,'rtt':float(rtt),'download':float(down),'upload':float(up)})
md=max((r['download'] for r in rows),default=0); mu=max((r['upload'] for r in rows),default=0); mr=min((r['rtt'] for r in rows if r['rtt']>0),default=0)
for r in rows:
    ds=r['download']/md*100 if md else 0
    us=r['upload']/mu*100 if mu else 0
    rs=mr/r['rtt']*100 if mr and r['rtt'] else 0
    r['score']=(ds*wd+us*wu+rs*wr)/100
rows.sort(key=lambda r:(-r['score'],-r['download'],-r['upload'],r['rtt'] if r['rtt'] else math.inf,r['name']))
for i,r in enumerate(rows,1):
    print(f"{i}\t{r['name']}\t{r['rtt'] if r['rtt'] else '-'}\t{r['download']:.2f}\t{r['upload']:.2f}\t{r['score']:.2f}")
PY
)"

printf '\n'
printf '%-5s %-46s %8s %10s %10s %8s\n' 'Rank' 'Profile' 'RTT(ms)' 'Download' 'Upload' 'Score'
printf '%s\n' '------------------------------------------------------------------------------------------------'
while IFS=$'\t' read -r rank name rtt download upload score; do
    printf '%-5s %-46s %8s %10s %10s %8s\n' "$rank" "$name" "$rtt" "$download" "$upload" "$score"
done <<< "$SCORE_OUTPUT"

printf '\n'
success "Score complete"
printf '  CSV     : %s\n' "$CSV_FILE"
printf '  Winners : %s\n' "$WINNER_DIR"
printf '  Top %s profiles copied to winner directory.\n' "$TOP_N"
