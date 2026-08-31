#!/usr/bin/env bash
set -Eeuo pipefail

###############################################################################
# Smart Proxy Server - Reload / Race Report
###############################################################################

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${BASE_DIR}/config/defaults.conf"
source "${BASE_DIR}/lib/common.sh"

LOCK_FILE="/run/smartproxy-reload.lock"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    warning "Another Smart Proxy race is already running. Skipping this run."
    exit 0
fi

PROFILE_ROOT="$PROFILE_DIR"
if [[ ! -d "$PROFILE_ROOT" || -z "$(find "$PROFILE_ROOT" -maxdepth 1 -type f -name '*.txt' -print -quit 2>/dev/null)" ]]; then
    [[ -d "$BASE_DIR/profiles" ]] && PROFILE_ROOT="$BASE_DIR/profiles"
fi

shopt -s nullglob
mapfile -t profiles < <(find "$PROFILE_ROOT" -maxdepth 1 -type f -name '*.txt' | sort)
shopt -u nullglob
[[ ${#profiles[@]} -gt 0 ]] || fatal "No proxy profiles found in $PROFILE_ROOT"

RESULT_DIR="/run/smartproxy"
RESULT_FILE="${RESULT_DIR}/race-results.$$"
mkdir -p "$RESULT_DIR"
trap 'rm -f "$RESULT_FILE"' EXIT
: > "$RESULT_FILE"

###############################################################################
# Report helpers
###############################################################################

print_header() {
    printf '%-24s %-28s %10s %9s %7s %9s %7s\n' \
        "Profile" "Host" "RTT" "Jitter" "Loss" "Success" "Score"
    printf '%s\n' '----------------------------------------------------------------------------------------------------------------'
}

print_row() {
    local name="$1" host="$2" rtt="$3" jitter="$4" loss="$5" success="$6" score="$7"
    printf '%-24s %-28s %10sms %9sms %7s%% %8s%% %7s\n' \
        "$name" "$host" "$rtt" "$jitter" "$loss" "$success" "$score"
}

parse_kv() {
    local input="$1" key="$2"
    awk -v key="$key" '{for(i=1;i<=NF;i++){split($i,a,"="); if(a[1]==key){print substr($i,length(key)+2); exit}}}' <<< "$input"
}

is_number() {
    [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]
}

is_better() {
    awk -v s="$1" -v bs="$2" \
        -v suc="$3" -v bsuc="$4" \
        -v r="$5" -v br="$6" \
        -v j="$7" -v bj="$8" \
        -v n="$9" -v bn="${10}" 'BEGIN {
        if (s != bs) exit !(s > bs)
        if (suc != bsuc) exit !(suc > bsuc)
        if (r != br) exit !(r < br)
        if (j != bj) exit !(j < bj)
        if (bn == "") exit 0
        exit !(n < bn)
    }'
}

printf '\n'
info "Testing proxy profiles..."
printf '\n'
print_header

best_name=""
best_score=-1
best_success=-1
best_rtt=999999
best_jitter=999999
usable=0
errors=0

for file in "${profiles[@]}"; do
    name="$(basename "$file" .txt)"
    health=""

    if ! health="$(${BASE_DIR}/lib/health.sh "$file" 2>&1)"; then
        print_row "$name" "-" "-" "-" "-" "-" "ERROR"
        printf '[ERROR] %s: %s\n' "$name" "$health" >&2
        errors=$((errors + 1))
        continue
    fi

    if [[ -z "$health" ]]; then
        print_row "$name" "-" "-" "-" "-" "-" "ERROR"
        printf '[ERROR] %s: health.sh returned no metrics\n' "$name" >&2
        errors=$((errors + 1))
        continue
    fi

    scored=""
    if ! scored="$(printf '%s\n' "$health" | "${BASE_DIR}/lib/score.sh" 2>&1)"; then
        print_row "$name" "-" "-" "-" "-" "-" "ERROR"
        printf '[ERROR] %s: score.sh failed: %s\n' "$name" "$scored" >&2
        errors=$((errors + 1))
        continue
    fi

    host="$(parse_kv "$health" host)"
    port="$(parse_kv "$health" port)"
    rtt="$(parse_kv "$health" rtt)"
    jitter="$(parse_kv "$health" jitter)"
    loss="$(parse_kv "$health" loss)"
    success_rate="$(parse_kv "$health" success)"
    score="$(parse_kv "$scored" score)"

    if ! [[ "$score" =~ ^[0-9]+$ ]]; then
        print_row "$name" "${host:--}" "${rtt:--}" "${jitter:--}" "${loss:--}" "${success_rate:--}" "ERROR"
        printf '[ERROR] %s: invalid score output: %s\n' "$name" "$scored" >&2
        errors=$((errors + 1))
        continue
    fi

    [[ -n "$host" ]] || host="-"
    is_number "$rtt" || rtt=999999
    is_number "$jitter" || jitter=999999
    is_number "$loss" || loss=100
    is_number "$success_rate" || success_rate=0
    [[ "$port" =~ ^[0-9]+$ ]] || port=0

    printf '%s\n' "$name|$host|$port|$rtt|$jitter|$loss|$success_rate|$score" >> "$RESULT_FILE"
    print_row "$name" "$host" "$rtt" "$jitter" "$loss" "$success_rate" "$score"
    usable=$((usable + 1))

    if is_better "$score" "$best_score" "$success_rate" "$best_success" "$rtt" "$best_rtt" "$jitter" "$best_jitter" "$name" "$best_name"; then
        best_score="$score"
        best_name="$name"
        best_success="$success_rate"
        best_rtt="$rtt"
        best_jitter="$jitter"
    fi
done

printf '%s\n' '----------------------------------------------------------------------------------------------------------------'
(( usable > 0 )) || fatal "No usable proxy profile found. Check: bash -x lib/health.sh <profile-file>"

printf '\n'
info "Ranking proxy profiles..."
printf '\n'
print_header

sort -t'|' -k8,8nr -k7,7nr -k4,4n -k5,5n -k1,1 "$RESULT_FILE" |
while IFS='|' read -r name host port rtt jitter loss success_rate score; do
    print_row "$name" "$host" "$rtt" "$jitter" "$loss" "$success_rate" "$score"
done

printf '%s\n' '----------------------------------------------------------------------------------------------------------------'

echo
echo "Winner"
echo "----------------------------------------------------------------------------------------------------------------"
printf 'Profile : %s\n' "$best_name"
printf 'Score   : %s/100\n' "$best_score"
printf 'RTT     : %sms\n' "$best_rtt"
printf 'Jitter  : %sms\n' "$best_jitter"
printf 'Loss    : %s%%\n' "$(awk -F'|' -v n="$best_name" '$1==n {print $6; exit}' "$RESULT_FILE")"
printf 'Success : %s%%\n' "$best_success"
echo "----------------------------------------------------------------------------------------------------------------"

info "Applying race decision..."
if ! RACE_RESULT_FILE="$RESULT_FILE" "${BASE_DIR}/lib/race.sh"; then
    fatal "Race decision failed."
fi

active=""
if [[ -f "$STATE_FILE" ]]; then
    active="$(python3 - "$STATE_FILE" <<'PY'
import json, sys
try:
    with open(sys.argv[1], encoding='utf-8') as f:
        print(json.load(f).get('active', ''))
except Exception:
    print('')
PY
)"
fi

if [[ -n "$active" ]]; then
    active_score="$(awk -F'|' -v n="$active" '$1==n {print $8; exit}' "$RESULT_FILE")"
    [[ -n "$active_score" ]] || active_score="unknown"
    echo
echo "Active Profile"
printf 'Profile : %s\n' "$active"
printf 'Score   : %s/100\n' "$active_score"
fi

if (( errors > 0 )); then
    warning "${usable} profiles usable, ${errors} profiles failed health/scoring checks."
fi

echo
echo "========================================"
success "Smart Proxy Server race completed successfully."
echo "========================================"
