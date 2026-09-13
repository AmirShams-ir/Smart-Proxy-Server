#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================================
# Smart Proxy Server - Stage 3 : Validation
# ------------------------------------------------------------------------------
# Thin parallel wrapper around singtest.sh.
# Reads generated JSON configs from cache/generated/,
# reuses singtest.sh unchanged as the ONLY connectivity test engine,
# and stores ONLY successful candidates sorted by RTT (ascending) in:
#   cache/valid.csv
#
# CSV contract:
#   profile,rtt
#
# Architecture:
#   maker.sh -> cache/generated/*.json -> validator.sh -> singtest.sh
#                                                   -> cache/valid.csv
# ============================================================================

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INPUT_DIR="$BASE_DIR/cache/generated"
OUTPUT_FILE="$BASE_DIR/cache/valid.csv"
SINGTEST="$BASE_DIR/singtest.sh"

# Keep the default conservative for Orange Pi. Override with:
#   VALIDATOR_PARALLEL=8 bash validator.sh
PARALLEL="${VALIDATOR_PARALLEL:-4}"

fatal(){ printf '[✗] %s\n' "$*" >&2; exit 1; }
info(){ printf '[*] %s\n' "$*"; }
success(){ printf '[✓] %s\n' "$*"; }
warning(){ printf '[!] %s\n' "$*" >&2; }

require_cmd(){
    command -v "$1" >/dev/null 2>&1 || fatal "Required command not found: $1"
}

is_uint(){
    [[ "${1:-}" =~ ^[0-9]+$ ]] && (( 10#$1 > 0 ))
}

require_cmd awk
require_cmd find
require_cmd mktemp
require_cmd sort
require_cmd wc
require_cmd grep
require_cmd python3

[[ -f "$SINGTEST" ]] || fatal "singtest.sh not found: $SINGTEST"
[[ -d "$INPUT_DIR" ]] || fatal "Generated directory not found: $INPUT_DIR"
is_uint "$PARALLEL" || fatal "VALIDATOR_PARALLEL must be a positive integer"

chmod +x "$SINGTEST"
mkdir -p "$BASE_DIR/cache"

shopt -s nullglob
mapfile -t CANDIDATES < <(find "$INPUT_DIR" -maxdepth 1 -type f -name '*.json' -print | sort)
shopt -u nullglob

(( ${#CANDIDATES[@]} > 0 )) || fatal "No generated JSON candidates found in $INPUT_DIR"

TMP_DIR="$(mktemp -d /tmp/smartproxy-validation.XXXXXX)"
RESULT_DIR="$TMP_DIR/results"
mkdir -p "$RESULT_DIR"
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM

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

validate_one(){
    local input="$1"
    local index="$2"
    local profile log result rtt

    profile="$(basename "$input" .json)"
    log="$TMP_DIR/test-${index}.log"
    result="$RESULT_DIR/result-${index}.csv"

    # singtest.sh remains the ONLY connectivity/RTT test engine.
    if "$SINGTEST" "$input" >"$log" 2>&1; then
        rtt="$(extract_rtt "$log" || true)"
    else
        rtt=""
    fi

    if [[ "$rtt" =~ ^[0-9]+$ ]]; then
        printf '%s,%s\n' "$profile" "$rtt" > "$result"
        printf '%s|%s|%s\n' "$profile" "$rtt" "$index" > "$RESULT_DIR/display-${index}.txt"
    else
        : > "$result"
        printf '%s|-|%s\n' "$profile" "$index" > "$RESULT_DIR/display-${index}.txt"
    fi
}

info "Testing ${#CANDIDATES[@]} generated JSON candidates..."
info "Parallel workers: $PARALLEL"
printf '\n'
printf '%-56s %8s\n' 'Profile' 'RTT'
printf '%s\n' '----------------------------------------------------------------'

active=0
for input in "${CANDIDATES[@]}"; do
    active=$((active + 1))
    validate_one "$input" "$active" &

    while (( $(jobs -rp | wc -l) >= PARALLEL )); do
        wait -n || true
    done
done
wait || true

# Print results in deterministic candidate order, while CSV is RTT-sorted.
for display in "$RESULT_DIR"/display-*.txt; do
    [[ -f "$display" ]] || continue
    cat "$display"
done | sort -t'|' -k3,3n | while IFS='|' read -r profile rtt index; do
    if [[ "$rtt" =~ ^[0-9]+$ ]]; then
        printf '%-56s %7sms\n' "$profile" "$rtt"
    else
        printf '%-56s %8s\n' "$profile" '-'
    fi
done

TMP_OUTPUT="${OUTPUT_FILE}.tmp"
{
    printf 'profile,rtt\n'
    for result in "$RESULT_DIR"/result-*.csv; do
        [[ -s "$result" ]] || continue
        cat "$result"
    done | sort -t',' -k2,2n -k1,1
} > "$TMP_OUTPUT"
mv "$TMP_OUTPUT" "$OUTPUT_FILE"

VALID_COUNT="$(($(wc -l < "$OUTPUT_FILE") - 1))"
printf '%s\n' '----------------------------------------------------------------'
success "Validation complete: $VALID_COUNT valid candidates written to $OUTPUT_FILE"
