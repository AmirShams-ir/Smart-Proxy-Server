#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================================
# Smart Proxy Server - Stage 3 : Validation
# ------------------------------------------------------------------------------
# Parallel wrapper around singtest.sh.
# Reads generated JSON configs from cache/generated/,
# reuses singtest.sh unchanged as the ONLY connectivity/RTT test engine,
# stores the top VALIDATOR_TOP successful candidates sorted by RTT in:
#   cache/valid.csv
# and copies those validated JSON configs to:
#   cache/validated/
#
# CSV contract:
#   profile,rtt
#
# Architecture:
#   maker.sh -> cache/generated/*.json -> validator.sh -> singtest.sh
#                                                   -> cache/valid.csv
#                                                   -> cache/validated/*.json
# ============================================================================

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INPUT_DIR="$BASE_DIR/cache/generated"
OUTPUT_FILE="$BASE_DIR/cache/valid.csv"
VALIDATED_DIR="$BASE_DIR/cache/validated"
SINGTEST="$BASE_DIR/singtest.sh"
DEFAULTS_FILE="$BASE_DIR/config/defaults.conf"

fatal(){ printf '[✗] %s\n' "$*" >&2; exit 1; }
info(){ printf '[*] %s\n' "$*"; }
success(){ printf '[✓] %s\n' "$*"; }

require_cmd(){
    command -v "$1" >/dev/null 2>&1 || fatal "Required command not found: $1"
}

read_default(){
    local key="$1"
    local value=""
    [[ -f "$DEFAULTS_FILE" ]] || return 0
    value="$(awk -F= -v key="$key" '
        $1==key {
            v=$2
            gsub(/^ +| +$/, "", v)
            if (v ~ /^\\$\\{/) {
                sub(/^\\$\\{[^:]+:-?/, "", v)
                sub(/\\}$/, "", v)
            }
            print v
            exit
        }
    ' "$DEFAULTS_FILE")"
    printf '%s\n' "$value"
}

PARALLEL="${VALIDATOR_PARALLEL:-$(read_default VALIDATOR_PARALLEL)}"
PARALLEL="${PARALLEL:-4}"
[[ "$PARALLEL" =~ ^[0-9]+$ ]] || PARALLEL=4
(( 10#$PARALLEL > 0 )) || PARALLEL=4

TOP="${VALIDATOR_TOP:-$(read_default VALIDATOR_TOP)}"
TOP="${TOP:-10}"
[[ "$TOP" =~ ^[0-9]+$ ]] || TOP=10
(( 10#$TOP > 0 )) || TOP=10

require_cmd awk
require_cmd find
require_cmd mktemp
require_cmd sort
require_cmd head
require_cmd wc
require_cmd python3
require_cmd cp
require_cmd rm

[[ -f "$SINGTEST" ]] || fatal "singtest.sh not found: $SINGTEST"
[[ -d "$INPUT_DIR" ]] || fatal "Generated directory not found: $INPUT_DIR"

chmod +x "$SINGTEST"
mkdir -p "$BASE_DIR/cache" "$VALIDATED_DIR"

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
info "Top valid candidates to keep: $TOP"
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

# Print every tested candidate in deterministic input order.
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

# Store only the fastest TOP successful candidates and copy their exact
# generated JSON configs into cache/validated/.
TMP_OUTPUT="${OUTPUT_FILE}.tmp"
rm -f "$VALIDATED_DIR"/*.json

{
    printf 'profile,rtt\n'
    for result in "$RESULT_DIR"/result-*.csv; do
        [[ -s "$result" ]] || continue
        cat "$result"
    done | sort -t',' -k2,2n -k1,1 | head -n "$TOP"
} > "$TMP_OUTPUT"
mv "$TMP_OUTPUT" "$OUTPUT_FILE"

while IFS=',' read -r profile rtt; do
    [[ "$profile" == "profile" ]] && continue
    [[ -n "$profile" ]] || continue
    src="$INPUT_DIR/${profile}.json"
    [[ -f "$src" ]] || continue
    cp -f "$src" "$VALIDATED_DIR/${profile}.json"
done < "$OUTPUT_FILE"

VALID_COUNT="$(($(wc -l < "$OUTPUT_FILE") - 1))"
VALIDATED_COUNT="$(find "$VALIDATED_DIR" -maxdepth 1 -type f -name '*.json' | wc -l | tr -d ' ')"
printf '%s\n' '----------------------------------------------------------------'
success "Validation complete: $VALID_COUNT top valid candidates written to $OUTPUT_FILE"
success "Validated JSON configs copied to $VALIDATED_DIR ($VALIDATED_COUNT files)"
