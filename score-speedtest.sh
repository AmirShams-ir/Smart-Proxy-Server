#!/usr/bin/env bash
set -Eeuo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALIDATED_DIR="${SCORE_VALIDATED_DIR:-$BASE_DIR/cache/validated}"
WINNER_DIR="${SCORE_WINNER_DIR:-$BASE_DIR/cache/winner}"
CSV_FILE="${SCORE_CSV:-$BASE_DIR/cache/winner.csv}"
TOP_N="${SCORE_TOP:-4}"
SPEEDTEST="$BASE_DIR/speedtest.sh"
SCORE_DOWNLOAD_WEIGHT="${SCORE_DOWNLOAD_WEIGHT:-45}"
SCORE_UPLOAD_WEIGHT="${SCORE_UPLOAD_WEIGHT:-30}"
SCORE_RTT_WEIGHT="${SCORE_RTT_WEIGHT:-25}"
SCORE_SPEEDTEST_TIMEOUT="${SCORE_SPEEDTEST_TIMEOUT:-15}"
SCORE_DOWNLOAD_BYTES="${SCORE_DOWNLOAD_BYTES:-1048576}"
SCORE_UPLOAD_BYTES="${SCORE_UPLOAD_BYTES:-524288}"
SCORE_RTT_URL="${SCORE_RTT_URL:-https://cp.cloudflare.com/generate_204}"
SCORE_RTT_TIMEOUT="${SCORE_RTT_TIMEOUT:-8}"

fatal(){ printf '[✗] %s\n' "$*" >&2; exit 1; }
info(){ printf '[*] %s\n' "$*"; }
success(){ printf '[✓] %s\n' "$*"; }
warning(){ printf '[!] %s\n' "$*" >&2; }
require_cmd(){ command -v "$1" >/dev/null 2>&1 || fatal "Missing required command: $1"; }

require_cmd bash
require_cmd python3
require_cmd awk
require_cmd curl
require_cmd ss
require_cmd find
require_cmd sort
require_cmd cp
require_cmd "$SPEEDTEST" || true
[[ -f "$SPEEDTEST" ]] || fatal "speedtest.sh not found: $SPEEDTEST"
[[ -d "$VALIDATED_DIR" ]] || fatal "Validated directory not found: $VALIDATED_DIR"

TOTAL=$((SCORE_DOWNLOAD_WEIGHT + SCORE_UPLOAD_WEIGHT + SCORE_RTT_WEIGHT))
(( TOTAL == 100 )) || fatal "Score weights must sum to 100"

mkdir -p "$WINNER_DIR" "$(dirname "$CSV_FILE")"
rm -f "$WINNER_DIR"/*.json
TMP_DIR="$(mktemp -d /tmp/smartproxy-score2.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM
RAW="$TMP_DIR/raw.tsv"
: > "$RAW"

mapfile -t CONFIGS < <(find "$VALIDATED_DIR" -maxdepth 1 -type f -name '*.json' -print | sort)
COUNT="${#CONFIGS[@]}"
(( COUNT > 0 )) || fatal "No validated JSON profiles found"

info "Fast-scoring $COUNT validated profiles..."
printf '  Method    : sing-box + one SOCKS session per profile\n'
printf '  Payload   : Download=%s bytes, Upload=%s bytes\n' "$SCORE_DOWNLOAD_BYTES" "$SCORE_UPLOAD_BYTES"
printf '  Weights   : Down=%s%% Up=%s%% RTT=%s%%\n\n' "$SCORE_DOWNLOAD_WEIGHT" "$SCORE_UPLOAD_WEIGHT" "$SCORE_RTT_WEIGHT"

python3 - "$SPEEDTEST" <<'PY' >/dev/null
import sys
from pathlib import Path
p=Path(sys.argv[1])
if not p.is_file():
    raise SystemExit(1)
PY

###############################################################################
# This wrapper intentionally keeps the existing speedtest.sh untouched.
# score-speedtest.sh is an optimized scorer entry point and still delegates
# transfer measurements to speedtest.sh for consistency.
###############################################################################

printf '%-58s %8s %10s %10s %8s\n' 'Profile' 'RTT(ms)' 'Download' 'Upload' 'Score'
printf '%s\n' '----------------------------------------------------------------------------------------------------------'

idx=0
for cfg in "${CONFIGS[@]}"; do
  idx=$((idx+1))
  name="$(basename "$cfg" .json)"
  info "[$idx/$COUNT] Testing $name" >&2

  out="$TMP_DIR/speed-$idx.out"
  err="$TMP_DIR/speed-$idx.err"
  set +e
  SCORE_DOWNLOAD_BYTES="$SCORE_DOWNLOAD_BYTES" \
  SCORE_UPLOAD_BYTES="$SCORE_UPLOAD_BYTES" \
  SPEEDTEST_TIMEOUT="$SCORE_SPEEDTEST_TIMEOUT" \
  bash "$SPEEDTEST" "$cfg" >"$out" 2>"$err"
  rc=$?
  set -e

  download="$(awk '/^Download[[:space:]]+[0-9.]+ Mbps/{print $2; exit}' "$out" 2>/dev/null || true)"
  upload="$(awk '/^Upload[[:space:]]+[0-9.]+ Mbps/{print $2; exit}' "$out" 2>/dev/null || true)"
  [[ "$download" =~ ^[0-9]+([.][0-9]+)?$ ]] || download=0
  [[ "$upload" =~ ^[0-9]+([.][0-9]+)?$ ]] || upload=0

  # Reuse the same endpoint to measure RTT. This is separate from the transfer
  # process because speedtest.sh currently owns its temporary SOCKS listener.
  rtt="-"
  rdir="$TMP_DIR/rtt-$idx"
  mkdir -p "$rdir"
  rcfg="$rdir/config.json"
  python3 - "$cfg" "$rcfg" "$((15500+idx))" <<'PY' || true
import json,sys
from pathlib import Path
src=Path(sys.argv[1]); out=Path(sys.argv[2]); port=int(sys.argv[3])
data=json.loads(src.read_text(encoding='utf-8'))
if 'outbounds' in data:
    obs=data.get('outbounds') or []
    route=data.get('route') or {}
    wanted=route.get('final') if isinstance(route,dict) else None
    if not wanted:
        for x in obs:
            if isinstance(x,dict) and x.get('tag'):
                wanted=x['tag']; break
    chosen=next((x for x in obs if isinstance(x,dict) and x.get('tag')==wanted),None)
    if chosen is None: raise SystemExit(1)
    cfg=dict(data)
    cfg['inbounds']=[{'type':'socks','tag':'score-rtt-in','listen':'127.0.0.1','listen_port':port}]
    cfg['route']=dict(cfg.get('route') or {})
    cfg['route']['final']=wanted
    cfg['route']['rules']=[]
    cfg.pop('experimental',None)
else:
    outb=dict(data); tag=str(outb.pop('tag','score-rtt-out')) or 'score-rtt-out'
    cfg={'log':{'level':'error'},'inbounds':[{'type':'socks','tag':'score-rtt-in','listen':'127.0.0.1','listen_port':port}],'outbounds':[dict(outb,tag=tag),{'type':'direct','tag':'direct'},{'type':'block','tag':'block'}],'route':{'final':tag,'rules':[]}}
out.write_text(json.dumps(cfg,ensure_ascii=False),encoding='utf-8')
PY
  if [[ -s "$rcfg" ]] && sing-box check -c "$rcfg" >/dev/null 2>&1; then
      port=$((15500+idx))
      sing-box run -c "$rcfg" >"$rdir/log" 2>"$rdir/err" & pid=$!
      ready=0
      for _ in {1..30}; do
          if ss -lnt 2>/dev/null | grep -Eq '[:.]'"$port"'[[:space:]]'; then ready=1; break; fi
          if ! kill -0 "$pid" 2>/dev/null; then break; fi
          sleep 0.05
      done
      if (( ready )); then
          t0="$(date +%s%N)"
          set +e
          code="$(curl -4 -L --connect-timeout 4 --max-time "$SCORE_RTT_TIMEOUT" --socks5-hostname "127.0.0.1:$port" -sS -o /dev/null -w '%{http_code}' "$SCORE_RTT_URL" 2>/dev/null)"
          c_rc=$?
          set -e
          t1="$(date +%s%N)"
          if (( c_rc == 0 )) && [[ "$code" =~ ^2[0-9][0-9]$ ]]; then
              rtt="$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.2f",(b-a)/1000000}')"
          fi
      fi
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
  fi

  printf '%s\t%s\t%s\t%s\t%s\n' "$cfg" "$name" "$rtt" "$download" "$upload" >> "$RAW"
  printf '%-58s %8s %10s %10s %8s\n' "$name" "$rtt" "$download" "$upload" '-'
  (( rc != 0 )) && warning "$name speedtest rc=$rc" >&2 || true
done

python3 - "$RAW" "$CSV_FILE" "$WINNER_DIR" "$TOP_N" "$SCORE_DOWNLOAD_WEIGHT" "$SCORE_UPLOAD_WEIGHT" "$SCORE_RTT_WEIGHT" <<'PY'
import csv,math,shutil,sys
from pathlib import Path
raw=Path(sys.argv[1]); csv_path=Path(sys.argv[2]); win=Path(sys.argv[3])
top=int(sys.argv[4]); wd,wu,wr=map(float,sys.argv[5:8])
rows=[]
for line in raw.read_text().splitlines():
    if not line: continue
    p,n,r,d,u=line.split('\t')
    rows.append({'path':p,'name':n,'rtt':None if r=='-' else float(r),'download':float(d),'upload':float(u)})
rankable=[r for r in rows if r['rtt'] is not None and r['rtt']>0]
maxd=max((r['download'] for r in rankable),default=0)
maxu=max((r['upload'] for r in rankable),default=0)
minr=min((r['rtt'] for r in rankable),default=0)
for r in rows:
    if r not in rankable:
        r['score']=0.0
    else:
        ds=r['download']/maxd*100 if maxd else 0
        us=r['upload']/maxu*100 if maxu else 0
        rs=minr/r['rtt']*100 if minr and r['rtt'] else 0
        r['score']=round((ds*wd+us*wu+rs*wr)/100,2)
rows.sort(key=lambda r:(-r['score'],-r['download'],-r['upload'],r['rtt'] if r['rtt'] else math.inf,r['name']))
with csv_path.open('w',newline='') as f:
    w=csv.writer(f); w.writerow(['Rank','Profile','RTT_ms','Download_Mbps','Upload_Mbps','Score'])
    for i,r in enumerate(rows,1): w.writerow([i,r['name'],'-' if r['rtt'] is None else f'{r["rtt"]:.2f}',f'{r["download"]:.2f}',f'{r["upload"]:.2f}',f'{r["score"]:.2f}'])
for p in win.glob('*.json'): p.unlink(missing_ok=True)
selected=[r for r in rows if r['score']>0][:top]
for r in selected: shutil.copy2(r['path'],win/Path(r['path']).name)
print(f"{'Rank':>4} {'Profile':<58} {'RTT(ms)':>8} {'Download':>10} {'Upload':>10} {'Score':>8}")
print('-'*106)
for i,r in enumerate(rows,1):
    rs='-' if r['rtt'] is None else f'{r["rtt"]:.2f}'
    print(f'{i:>4} {r["name"]:<58} {rs:>8} {r["download"]:>10.2f} {r["upload"]:>10.2f} {r["score"]:>8.2f}')
PY

success "Score complete"
printf 'CSV     : %s\n' "$CSV_FILE"
printf 'Winners : %s\n' "$WINNER_DIR"
printf 'Top     : %s\n' "$TOP_N"
