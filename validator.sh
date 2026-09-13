#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================================
# Smart Proxy Server - Stage 3 : Validation
# ------------------------------------------------------------------------------
# Parallel wrapper around singtest.sh.
# Reads generated JSON configs from cache/generated/,
# reuses singtest.sh unchanged as the ONLY connectivity/RTT test engine,
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
DEFAULTS_FILE="$BASE_DIR/config/defaults.conf"

fatal(){ printf '[✗] %s\n' "$*" >&2; exit 1; }
info(){ printf '[*] %s\n' "$*"; }
success(){ printf '[✓] %s\n' "$*"; }

require_cmd(){
    command -v "$1" >/dev/null 2>&1 || fatal "Required command not found: $1"
}

# Prefer explicit environment override, then defaults.conf, then 4.
PARALLEL="${VALIDATOR_PARALLEL:-}"
if [[ -z "$PARALLEL" && -f "$DEFAULTS_FILE" ]]; then
    PARALLEL="$(awk -F= '
        $1=="VALIDATOR_PARALLEL" {
            v=$2
            gsub(/^ +| +$/, "", v)
            if (v ~ /^\$\{/) {
                sub(/^\$\{[^:]+:-?/, "", v)
                sub(/\}$/, "", v)
            }
            print v
            exit
        }
    ' "$DEFAULTS_FILE")"
fi
PARALLEL="${PARALLEL:-4}"
[[ "$PARALLEL" =~ ^[0-9]+$ ]] || PARALLEL=4
(( 10#$PARALLEL > 0 )) || PARALLEL=4

require_cmd awk
require_cmd find
require_cmd mktemp
require_cmd sort
require_cmd wc
require_cmd python3

[[ -f "$SINGTEST" ]] || fatal "singtest.sh not found: $SINGTEST"
[[ -d "$INPUT_DIR" ]] || fatal "Generated directory not found: $INPUT_DIR"

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
    local profile log result display rtt

    profile="$(basename "$input" .json)"
    log="$TMP_DIR/test-${index}.log"
    result="$RESULT_DIR/result-${index}.csv"
    display="$RESULT_DIR/display-${index}.txt"

    # singtest.sh remains the ONLY connectivity/RTT test engine.
    if "$SINGTEST" "$input" >"$log" 2>&1; then
        rtt="$(extract_rtt "$log" || true)"
    else
        rtt=""
    fi

    if [[ "$rtt" =~ ^[0-9]+$ ]]; then
        printf '%s,%s\n' "$profile" "$rtt" > "$result"
        printf '%s|%s|%s\n' "$profile" "$rtt" "$index" > "$display"
    else
        : > "$result"
        printf '%s|-|%s\n' "$profile" "$index" > "$display"
    fi
}

info "Testing ${#CANDIDATES[@]} generated JSON candidates..."
info "Parallel workers: $PARALLEL"
printf '\n'
printf '%-56s %8s\n' 'Profile' 'RTT'
printf '%s\n' '----------------------------------------------------------------'

next_index=0
running=0
while (( next_index < ${#CANDIDATES[@]} || running > 0 )); do
    while (( running < PARALLEL && next_index < ${#CANDIDATES[@]} )); do
        next_index=$((next_index + 1))
        validate_one "${CANDIDATES[$((next_index - 1))]}" "$next_index" &
        running=$((running + 1))
    done

    if (( running > 0 )); then
        wait -n || true
        running=$((running - 1))
    fi
done

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
