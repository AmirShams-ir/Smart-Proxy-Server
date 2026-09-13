#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================================
# Smart Proxy Server - Candidate Validator
#
# Stage 1 only:
#   cache/generated/*.json -> singtest.sh -> RTT
#                         (parallel=6)
#   -> cache/validated/stage1.tsv
#
# IMPORTANT:
#   singtest.sh is the single source of truth for connectivity testing.
#   validator.sh does not duplicate sing-box/curl test logic.
# ============================================================================

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$BASE_DIR/config/defaults.conf"

GENERATED_DIR="$BASE_DIR/cache/generated"
VALIDATED_DIR="$BASE_DIR/cache/validated"
STAGE1_FILE="$VALIDATED_DIR/stage1.tsv"
WORK_DIR="$BASE_DIR/cache/validator"
LOCK_FILE="/run/smartproxy-validator.lock"
LOCK_META="/run/smartproxy-validator.lock.info"

PARALLEL="${VALIDATOR_PARALLEL:-6}"
SINGTEST="$BASE_DIR/singtest.sh"

fatal(){ printf '[✗] %s\n' "$*" >&2; exit 1; }
warning(){ printf '[!] %s\n' "$*" >&2; }
info(){ printf '[*] %s\n' "$*"; }
success(){ printf '[✓] %s\n' "$*"; }
require_cmd(){ command -v "$1" >/dev/null 2>&1 || fatal "Missing required command: $1"; }

require_cmd bash
require_cmd awk
require_cmd sort
require_cmd flock
require_cmd mktemp

[[ -f "$SINGTEST" ]] || fatal "singtest.sh not found: $SINGTEST"
[[ -d "$GENERATED_DIR" ]] || fatal "Missing generated candidate directory: $GENERATED_DIR"
(( PARALLEL > 0 )) || fatal "VALIDATOR_PARALLEL must be > 0"

mkdir -p "$VALIDATED_DIR" "$WORK_DIR" "$WORK_DIR/stage1"
rm -f "$STAGE1_FILE" "$WORK_DIR/stage1"/*.result "$WORK_DIR/stage1"/*.meta

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    lock_pid="$(cat "$LOCK_META" 2>/dev/null || true)"
    if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
        warning "Another validator run is already active (PID $lock_pid)."
        exit 0
    fi
    warning "Validator lock metadata is stale; continuing."
fi
printf '%s\n' "$$" > "$LOCK_META"
trap 'rm -f "$LOCK_META"' EXIT

shopt -s nullglob
CANDIDATES=("$GENERATED_DIR"/*.json)
shopt -u nullglob
[[ ${#CANDIDATES[@]} -gt 0 ]] || fatal "No JSON candidates found in $GENERATED_DIR"

# Extract the maker profile/tag without reimplementing singtest's connectivity logic.
profile_name(){
    awk -F'=' '$1=="tag" {sub(/^tag=/,""); print; exit}' "$1"
}

# Extract response time from singtest output.
response_ms(){
    awk -F':' '/^[[:space:]]*Response[[:space:]]*:/ {gsub(/[^0-9.]/,"",$2); print $2; exit}' "$1"
}

stage1_worker(){
    local candidate="$1" slot="$2"
    local base run_dir output rc profile rtt

    base="$(basename "$candidate")"
    run_dir="$WORK_DIR/stage1/${slot}_${base}"
    mkdir -p "$run_dir"
    output="$run_dir/output"

    profile="$(python3 - "$candidate" <<'PY'
import json,sys
with open(sys.argv[1],encoding='utf-8') as f:
    d=json.load(f)
print(d.get('tag', 'candidate'))
PY
)"

    set +e
    SINGTEST_WORK_DIR="$run_dir/singtest" \
    SINGTEST_PORT="$((1234 + slot + 1))" \
    bash "$SINGTEST" "$candidate" >"$output" 2>&1
    rc=$?
    set -e

    rtt="$(response_ms "$output" || true)"
    if (( rc == 0 )) && [[ "$rtt" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        printf '%s\t%s\t%s\n' "$candidate" "$profile" "$rtt" > "$run_dir/result"
    else
        printf '%s\t%s\tFAILED\n' "$candidate" "$profile" > "$run_dir/result"
        cp -f "$output" "$run_dir/singtest-output.txt" 2>/dev/null || true
    fi
}

info "Validating ${#CANDIDATES[@]} generated candidates..."
info "Stage 1: singtest connectivity (parallel=$PARALLEL)"
printf '\n%-56s %-8s\n' 'Profile' 'RTT'
printf '%-56s %-8s\n' '--------------------------------------------------------' '--------'

pids=()
slot=0
running=0
for candidate in "${CANDIDATES[@]}"; do
    ((slot+=1))
    slot_id=$(( (slot - 1) % PARALLEL ))
    stage1_worker "$candidate" "$slot_id" &
    pids+=("$!")
    ((running+=1))

    if (( running >= PARALLEL )); then
        wait "${pids[0]}" 2>/dev/null || true
        pids=("${pids[@]:1}")
        ((running-=1))
    fi
done

for pid in "${pids[@]}"; do
    wait "$pid" 2>/dev/null || true
done

# Consolidate successful probes.
TMP_RESULTS="$(mktemp "$WORK_DIR/stage1-results.XXXXXX")"
trap 'rm -f "$LOCK_META" "$TMP_RESULTS"' EXIT

for result_file in "$WORK_DIR"/stage1/*/result; do
    [[ -f "$result_file" ]] || continue
    IFS=$'\t' read -r candidate profile rtt < "$result_file" || true
    [[ "$rtt" =~ ^[0-9]+([.][0-9]+)?$ ]] || continue
    printf '%s\t%s\t%s\n' "$candidate" "$profile" "$rtt" >> "$TMP_RESULTS"
done

COUNT="$(wc -l < "$TMP_RESULTS" | tr -d ' ')"
(( COUNT > 0 )) || fatal "No candidate passed Stage 1. See $WORK_DIR/stage1/"

# Stage 1 artifact requested by user: Rank / Profile / RTT.
printf 'Rank\tProfile\tRTT\n' > "$STAGE1_FILE"
rank=0
while IFS=$'\t' read -r candidate profile rtt; do
    ((rank+=1))
    printf '%s\t%s\t%s\n' "$rank" "$profile" "$rtt" >> "$STAGE1_FILE"
done < <(sort -t$'\t' -k3,3n -k2,2 "$TMP_RESULTS")

printf '\n'
success "Stage 1 complete"
printf '  Candidates : %s\n' "${#CANDIDATES[@]}"
printf '  Passed     : %s\n' "$COUNT"
printf '  Parallel   : %s\n' "$PARALLEL"
printf '\n'
printf '%-56s %-8s\n' 'Profile' 'RTT'
printf '%-56s %-8s\n' '--------------------------------------------------------' '--------'
awk -F'\t' 'NR>1 {printf "%-56s %-8s\n", $2, $3}' "$STAGE1_FILE"
printf '\nStage 1 file: %s\n' "$STAGE1_FILE"
