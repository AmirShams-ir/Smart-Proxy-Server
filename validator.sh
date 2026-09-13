#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================================
# Smart Proxy Server - Stage 3 : Validation
# ------------------------------------------------------------------------------
# Thin wrapper around singtest.sh.
# Reads generated outbound JSON files one by one from cache/generated/,
# executes the existing singtest.sh unchanged for each candidate, extracts
# only its measured Response RTT, prints Profile + RTT, and stores all
# results in cache/validated/rtt.json.
#
# Architecture:
#   maker.sh -> cache/generated/*.json -> validation.sh -> singtest.sh
#                                                   -> cache/validated/rtt.json
# ============================================================================

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INPUT_DIR="$BASE_DIR/cache/generated"
VALIDATED_DIR="$BASE_DIR/cache/validated"
OUTPUT_FILE="$VALIDATED_DIR/rtt.json"
SINGTEST="$BASE_DIR/singtest.sh"

fatal(){ printf '[✗] %s\n' "$*" >&2; exit 1; }
info(){ printf '[*] %s\n' "$*"; }
success(){ printf '[✓] %s\n' "$*"; }

[[ -f "$SINGTEST" ]] || fatal "singtest.sh not found: $SINGTEST"
[[ -x "$SINGTEST" ]] || chmod +x "$SINGTEST"
[[ -d "$INPUT_DIR" ]] || fatal "Generated directory not found: $INPUT_DIR"

mkdir -p "$VALIDATED_DIR"

shopt -s nullglob
mapfile -t CANDIDATES < <(find "$INPUT_DIR" -maxdepth 1 -type f -name '*.json' -print | sort)
shopt -u nullglob

(( ${#CANDIDATES[@]} > 0 )) || fatal "No generated JSON candidates found in $INPUT_DIR"

TMP_DIR="$(mktemp -d /tmp/smartproxy-validation.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM

RESULTS="$TMP_DIR/results.jsonl"
: > "$RESULTS"

extract_rtt(){
    local output="$1"
    awk '
        /Response[[:space:]]*:/ {
            line=$0
            sub(/^.*Response[[:space:]]*:[[:space:]]*/, "", line)
            sub(/ms.*$/, "", line)
            if (line ~ /^[0-9]+$/) {
                print line
                exit
            }
        }
    ' "$output"
}

extract_status(){
    local output="$1"
    if grep -q 'Connectivity PASS' "$output"; then
        printf 'passed\n'
    else
        printf 'failed\n'
    fi
}

info "Testing ${#CANDIDATES[@]} generated JSON candidates..."
printf '\n'
printf '%-56s %8s\n' 'Profile' 'RTT'
printf '%s\n' '----------------------------------------------------------------'

for input in "${CANDIDATES[@]}"; do
    profile="$(basename "$input" .json)"
    log="$TMP_DIR/${profile}.log"

    # Reuse singtest.sh exactly as the only test engine.
    if "$SINGTEST" "$input" >"$log" 2>&1; then
        status="$(extract_status "$log")"
        rtt="$(extract_rtt "$log" || true)"
    else
        status="failed"
        rtt=""
    fi

    if [[ "$status" == 'passed' && "$rtt" =~ ^[0-9]+$ ]]; then
        printf '%-56s %7sms\n' "$profile" "$rtt"
        python3 - "$RESULTS" "$profile" "$rtt" passed <<'PY'
import json
import sys
from pathlib import Path

path, profile, rtt, status = sys.argv[1:]
with open(path, 'a', encoding='utf-8') as f:
    f.write(json.dumps({
        'profile': profile,
        'rtt': int(rtt),
        'status': status,
    }, ensure_ascii=False) + '\n')
PY
    else
        printf '%-56s %8s\n' "$profile" '-'
        python3 - "$RESULTS" "$profile" failed <<'PY'
import json
import sys

path, profile, status = sys.argv[1:]
with open(path, 'a', encoding='utf-8') as f:
    f.write(json.dumps({
        'profile': profile,
        'rtt': None,
        'status': status,
    }, ensure_ascii=False) + '\n')
PY
    fi

done

python3 - "$RESULTS" "$OUTPUT_FILE" <<'PY'
import json
import sys
from pathlib import Path

src = Path(sys.argv[1])
out = Path(sys.argv[2])
rows = []

with src.open(encoding='utf-8') as f:
    for line in f:
        line = line.strip()
        if line:
            rows.append(json.loads(line))

rows.sort(key=lambda row: (
    0 if row.get('status') == 'passed' and isinstance(row.get('rtt'), int) else 1,
    row.get('rtt') if isinstance(row.get('rtt'), int) else 10**9,
    row.get('profile', ''),
))

out.parent.mkdir(parents=True, exist_ok=True)
out.write_text(
    json.dumps(rows, ensure_ascii=False, indent=2) + '\n',
    encoding='utf-8',
)
PY

printf '%s\n' '----------------------------------------------------------------'
success "Validation complete: $OUTPUT_FILE"
