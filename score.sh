#!/usr/bin/env bash
set -Eeuo pipefail

# Smart Proxy Server - score engine
# Cheap -> Expensive pipeline:
#   1) Read validator RTT from cache/valid.csv
#   2) Do NOT run RTT/Jitter probes here
#   3) Run speedtest.sh only for validated candidates
#   4) Score Download + Upload + validator RTT
#   5) Save cache/winner.csv and copy Top 4 into cache/winner/

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALIDATED_DIR="${SCORE_VALIDATED_DIR:-$BASE_DIR/cache/validated}"
VALID_CSV="${SCORE_VALID_CSV:-$BASE_DIR/cache/valid.csv}"
WINNER_DIR="${SCORE_WINNER_DIR:-$BASE_DIR/cache/winner}"
CSV_FILE="${SCORE_CSV:-$BASE_DIR/cache/winner.csv}"
TOP_N="${SCORE_TOP:-4}"
DOWNLOAD_WEIGHT="${SCORE_DOWNLOAD_WEIGHT:-55}"
UPLOAD_WEIGHT="${SCORE_UPLOAD_WEIGHT:-30}"
RTT_WEIGHT="${SCORE_RTT_WEIGHT:-15}"
SPEEDTEST_TIMEOUT="${SCORE_SPEEDTEST_TIMEOUT:-15}"
DOWNLOAD_BYTES="${SCORE_DOWNLOAD_BYTES:-1048576}"
UPLOAD_BYTES="${SCORE_UPLOAD_BYTES:-524288}"
SPEEDTEST="$BASE_DIR/speedtest.sh"

fatal(){ printf '[✗] %s\n' "$*" >&2; exit 1; }
info(){ printf '[*] %s\n' "$*"; }
warning(){ printf '[!] %s\n' "$*" >&2; }
success(){ printf '[✓] %s\n' "$*"; }
require_cmd(){ command -v "$1" >/dev/null 2>&1 || fatal "Missing required command: $1"; }

require_cmd python3
require_cmd awk
require_cmd sort
require_cmd find
require_cmd cp
require_cmd sed
require_cmd grep
require_cmd basename
require_cmd mktemp

[[ -f "$SPEEDTEST" ]] || fatal "speedtest.sh not found: $SPEEDTEST"
[[ -d "$VALIDATED_DIR" ]] || fatal "Validated directory not found: $VALIDATED_DIR"
[[ -f "$VALID_CSV" ]] || fatal "Validator CSV not found: $VALID_CSV"

TOTAL_WEIGHT=$((DOWNLOAD_WEIGHT + UPLOAD_WEIGHT + RTT_WEIGHT))
(( TOTAL_WEIGHT == 100 )) || fatal "Score weights must sum to 100 (got $TOTAL_WEIGHT)"
(( TOP_N > 0 )) || fatal "SCORE_TOP must be greater than zero"

mkdir -p "$WINNER_DIR" "$(dirname "$CSV_FILE")"
rm -f "$WINNER_DIR"/*.json

TMP_DIR="$(mktemp -d /tmp/smartproxy-score.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM
RESULTS="$TMP_DIR/results.tsv"
: > "$RESULTS"

###############################################################################
# Import validator RTT data once.
# Supports common validator.csv layouts:
#   Profile,RTT
#   Rank,Profile,RTT,...
# and tab-separated equivalents.
###############################################################################
python3 - "$VALID_CSV" "$TMP_DIR/validator.tsv" <<'PY'
import csv
import re
import sys
from pathlib import Path

src = Path(sys.argv[1])
out = Path(sys.argv[2])
lines = [x for x in src.read_text(encoding='utf-8', errors='replace').splitlines() if x.strip()]
if not lines:
    raise SystemExit('validator CSV is empty')

sample = '\n'.join(lines[:5])
try:
    delimiter = csv.Sniffer().sniff(sample, delimiters=',\t;').delimiter
except csv.Error:
    delimiter = ','

rows = list(csv.reader(lines, delimiter=delimiter))
header = [c.strip().lower() for c in rows[0]]

profile_idx = None
rtt_idx = None
for i, col in enumerate(header):
    if col in ('profile', 'name', 'candidate', 'config'):
        profile_idx = i
    if col in ('rtt', 'rtt_ms', 'latency', 'latency_ms'):
        rtt_idx = i

# Header-less fallback: profile first, RTT second.
data_rows = rows[1:] if profile_idx is not None or rtt_idx is not None else rows
profile_idx = 0 if profile_idx is None else profile_idx
rtt_idx = 1 if rtt_idx is None else rtt_idx

with out.open('w', encoding='utf-8') as f:
    for row in data_rows:
        if len(row) <= max(profile_idx, rtt_idx):
            continue
        profile = row[profile_idx].strip()
        rtt = row[rtt_idx].strip()
        if profile.endswith('.json'):
            profile = profile[:-5]
        if not profile:
            continue
        if re.fullmatch(r'[0-9]+(?:\.[0-9]+)?', rtt) and float(rtt) > 0:
            print(f'{profile}\t{rtt}', file=f)
PY

mapfile -t CONFIGS < <(find "$VALIDATED_DIR" -maxdepth 1 -type f -name '*.json' -print | sort)
CONFIG_COUNT="${#CONFIGS[@]}"
(( CONFIG_COUNT > 0 )) || fatal "No JSON configs found in $VALIDATED_DIR"

info "Scoring $CONFIG_COUNT validated profiles..."
printf '  Validated : %s\n' "$VALIDATED_DIR"
printf '  Validator : %s\n' "$VALID_CSV"
printf '  Speedtest : bash %s\n' "$SPEEDTEST"
printf '  Weights   : Down=%s%% Up=%s%% RTT=%s%%\n\n' "$DOWNLOAD_WEIGHT" "$UPLOAD_WEIGHT" "$RTT_WEIGHT"

profile_name(){ basename "$1" .json; }

###############################################################################
# Cheap gate from validator.csv, then expensive transfer test.
###############################################################################
printf '%-58s %8s %10s %10s %8s\n' 'Profile' 'RTT(ms)' 'Download' 'Upload' 'Score'
printf '%s\n' '----------------------------------------------------------------------------------------------------------'

index=0
for input in "${CONFIGS[@]}"; do
    index=$((index+1))
    name="$(profile_name "$input")"
    printf '[*] [%s/%s] Testing %s\n' "$index" "$CONFIG_COUNT" "$name" >&2

    rtt="$(awk -F '\t' -v p="$name" '$1==p {print $2; exit}' "$TMP_DIR/validator.tsv" 2>/dev/null || true)"

    if [[ ! "$rtt" =~ ^[0-9]+([.][0-9]+)?$ ]] || ! awk -v x="$rtt" 'BEGIN{exit !(x>0)}'; then
        printf '%s\t%s\t-\t0\t0\n' "$input" "$name" >> "$RESULTS"
        printf '%-58s %8s %10s %10s %8s\n' "$name" '-' '-' '-' 'SKIP'
        printf '[*] [%s/%s] No valid RTT from validator; skipping Download/Upload for %s\n' "$index" "$CONFIG_COUNT" "$name" >&2
        continue
    fi

    out="$TMP_DIR/speed-$index.out"
    set +e
    SCORE_DOWNLOAD_BYTES="$DOWNLOAD_BYTES" \
    SCORE_UPLOAD_BYTES="$UPLOAD_BYTES" \
    SPEEDTEST_TIMEOUT="$SPEEDTEST_TIMEOUT" \
    bash "$SPEEDTEST" "$input" >"$out" 2>"$TMP_DIR/speed-$index.err"
    speed_rc=$?
    set -e

    download="$(awk '/^Download[[:space:]]+[0-9.]+ Mbps/{print $2; exit}' "$out" 2>/dev/null || true)"
    upload="$(awk '/^Upload[[:space:]]+[0-9.]+ Mbps/{print $2; exit}' "$out" 2>/dev/null || true)"
    [[ "$download" =~ ^[0-9]+([.][0-9]+)?$ ]] || download=0
    [[ "$upload" =~ ^[0-9]+([.][0-9]+)?$ ]] || upload=0

    printf '%s\t%s\t%s\t%s\t%s\n' "$input" "$name" "$rtt" "$download" "$upload" >> "$RESULTS"
    printf '%-58s %8s %10s %10s %8s\n' "$name" "$rtt" "$download" "$upload" '-'

    if (( speed_rc != 0 )); then
        warning "$name speedtest returned rc=$speed_rc; measured values retained" >&2
    fi
done

###############################################################################
# Normalize and rank.
###############################################################################
python3 - "$RESULTS" "$CSV_FILE" "$WINNER_DIR" "$TOP_N" "$DOWNLOAD_WEIGHT" "$UPLOAD_WEIGHT" "$RTT_WEIGHT" <<'PY'
import csv
import math
import shutil
import sys
from pathlib import Path

results = Path(sys.argv[1])
csv_file = Path(sys.argv[2])
winner_dir = Path(sys.argv[3])
top_n = int(sys.argv[4])
wd, wu, wr = map(float, sys.argv[5:8])

rows=[]
for line in results.read_text(encoding='utf-8').splitlines():
    if not line.strip():
        continue
    path, name, rtt, down, up = line.split('\t')
    rows.append({
        'path': path,
        'name': name,
        'rtt': None if rtt == '-' else float(rtt),
        'download': float(down),
        'upload': float(up),
    })

rankable = [
    r for r in rows
    if r['rtt'] is not None and r['rtt'] > 0
    and r['download'] > 0 and r['upload'] > 0
]

max_down = max((r['download'] for r in rankable), default=0.0)
max_up = max((r['upload'] for r in rankable), default=0.0)
min_rtt = min((r['rtt'] for r in rankable), default=0.0)

for r in rows:
    if r not in rankable:
        r['score'] = 0.0
        continue

    down_score = (r['download'] / max_down * 100.0) if max_down else 0.0
    up_score = (r['upload'] / max_up * 100.0) if max_up else 0.0
    rtt_score = (min_rtt / r['rtt'] * 100.0) if min_rtt and r['rtt'] else 0.0

    r['score'] = round(
        down_score * wd / 100.0
        + up_score * wu / 100.0
        + rtt_score * wr / 100.0,
        2,
    )

rows.sort(key=lambda r: (
    -r['score'],
    -r['download'],
    -r['upload'],
    r['rtt'] if r['rtt'] is not None else math.inf,
    r['name'],
))

csv_file.parent.mkdir(parents=True, exist_ok=True)
with csv_file.open('w', newline='', encoding='utf-8') as f:
    writer = csv.writer(f)
    writer.writerow(['Rank','Profile','RTT_ms','Download_Mbps','Upload_Mbps','Score'])
    for rank, r in enumerate(rows, 1):
        writer.writerow([
            rank,
            r['name'],
            f"{r['rtt']:.2f}" if r['rtt'] is not None else '-',
            f"{r['download']:.2f}",
            f"{r['upload']:.2f}",
            f"{r['score']:.2f}",
        ])

for old in winner_dir.glob('*.json'):
    old.unlink(missing_ok=True)

selected = [r for r in rows if r['score'] > 0][:min(top_n, len(rows))]
for r in selected:
    shutil.copy2(r['path'], winner_dir / Path(r['path']).name)

print(f"{'Rank':>4} {'Profile':<58} {'RTT(ms)':>8} {'Download':>10} {'Upload':>10} {'Score':>8}")
print('-'*106)
for rank, r in enumerate(rows, 1):
    rtt = '-' if r['rtt'] is None else f"{r['rtt']:.2f}"
    print(
        f"{rank:>4} {r['name']:<58} {rtt:>8} "
        f"{r['download']:>10.2f} {r['upload']:>10.2f} {r['score']:>8.2f}"
    )
PY

success "Score complete"
printf 'CSV     : %s\n' "$CSV_FILE"
printf 'Winners : %s\n' "$WINNER_DIR"
printf 'Top     : %s\n' "$TOP_N"
