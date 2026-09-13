#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================================
# Smart Proxy Server - Stage 3 : Validation
# ------------------------------------------------------------------------------
# Thin wrapper around singtest.sh.
# Reads generated JSON configs one by one from cache/generated/,
# reuses singtest.sh unchanged as the ONLY connectivity test engine,
# prints Profile + RTT for every candidate, and stores ONLY successful
# candidates sorted by RTT (ascending) in:
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

fatal(){ printf '[✗] %s\n' "$*" >&2; exit 1; }
info(){ printf '[*] %s\n' "$*"; }
success(){ printf '[✓] %s\n' "$*"; }

[[ -f "$SINGTEST" ]] || fatal "singtest.sh not found: $SINGTEST"
[[ -d "$INPUT_DIR" ]] || fatal "Generated directory not found: $INPUT_DIR"

chmod +x "$SINGTEST"
mkdir -p "$BASE_DIR/cache"

shopt -s nullglob
mapfile -t CANDIDATES < <(find "$INPUT_DIR" -maxdepth 1 -type f -name '*.json' -print | sort)
shopt -u nullglob

(( ${#CANDIDATES[@]} > 0 )) || fatal "No generated JSON candidates found in $INPUT_DIR"

TMP_DIR="$(mktemp -d /tmp/smartproxy-validation.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM

VALID_RAW="$TMP_DIR/valid.raw"
: > "$VALID_RAW"

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

info "Testing ${#CANDIDATES[@]} generated JSON candidates..."
printf '\n'
printf '%-56s %8s\n' 'Profile' 'RTT'
printf '%s\n' '----------------------------------------------------------------'

for input in "${CANDIDATES[@]}"; do
    profile="$(basename "$input" .json)"
    log="$TMP_DIR/test.log"

    # Reuse singtest.sh exactly as the only connectivity test engine.
    if "$SINGTEST" "$input" >"$log" 2>&1; then
        rtt="$(extract_rtt "$log" || true)"
    else
        rtt=""
    fi

    if [[ "$rtt" =~ ^[0-9]+$ ]]; then
        printf '%-56s %7sms\n' "$profile" "$rtt"
        printf '%s,%s\n' "$profile" "$rtt" >> "$VALID_RAW"
    else
        printf '%-56s %8s\n' "$profile" '-'
    fi
done

# Keep ONLY connectivity-valid candidates and sort by RTT ascending.
TMP_OUTPUT="${OUTPUT_FILE}.tmp"
{
    printf 'profile,rtt\n'
    sort -t',' -k2,2n -k1,1 "$VALID_RAW"
} > "$TMP_OUTPUT"
mv "$TMP_OUTPUT" "$OUTPUT_FILE"

VALID_COUNT="$(($(wc -l < "$OUTPUT_FILE") - 1))"
printf '%s\n' '----------------------------------------------------------------'
success "Validation complete: $VALID_COUNT valid candidates written to $OUTPUT_FILE"
