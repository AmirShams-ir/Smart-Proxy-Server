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

printf '\n'
info "Testing proxy profiles..."
printf '\n'
printf '%-24s %-28s %10s %9s %7s %7s %7s\n' \
  "Profile" "Host" "RTT" "Jitter" "Loss" "Success" "Score"
printf '%s\n' '----------------------------------------------------------------------------------------------------------------'

best_name=""
best_score=-1
best_success=-1
best_rtt=999999
best_jitter=999999
usable=0
errors=0

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

for file in "${profiles[@]}"; do
    name="$(basename "$file" .txt)"
    health=""

    if ! health="$(${BASE_DIR}/lib/health.sh "$file" 2>&1)"; then
        printf '%-24s %-28s %10s %9s %7s %7s %7s\n' "$name" "-" "-" "-" "-" "-" "ERROR"
        printf '[ERROR] %s: %s\n' "$name" "$health" >&2
        errors=$((errors + 1))
        continue
    fi

    [[ -n "$health" ]] || {
        printf '%-24s %-28s %10s %9s %7s %7s %7s\n' "$name" "-" "-" "-" "-" "-" "ERROR"
        printf '[ERROR] %s: health.sh returned no metrics\n' "$name" >&2
        errors=$((errors + 1))
        continue
    }

    scored=""
    if ! scored="$(printf '%s\n' "$health" | "${BASE_DIR}/lib/score.sh" 2>&1)"; then
        printf '%-24s %-28s %10s %9s %7s %7s %7s\n' "$name" "-" "-" "-" "-" "-" "ERROR"
        printf '[ERROR] %s: score.sh failed: %s\n' "$name" "$scored" >&2
        errors=$((errors + 1))
        continue
    fi

    score="$(printf '%s\n' "$scored" | sed -n 's/.*\bscore=\([0-9][0-9]*\)\b.*/\1/p')"
    host="$(printf '%s\n' "$health" | sed -n 's/.*\bhost=\([^ ]*\)\b.*/\1/p')"
    port="$(printf '%s\n' "$health" | sed -n 's/.*\bport=\([^ ]*\)\b.*/\1/p')"
    rtt="$(printf '%s\n' "$health" | sed -n 's/.*\brtt=\([^ ]*\)\b.*/\1/p')"
    jitter="$(printf '%s\n' "$health" | sed -n 's/.*\bjitter=\([^ ]*\)\b.*/\1/p')"
    loss="$(printf '%s\n' "$health" | sed -n 's/.*\bloss=\([^ ]*\)\b.*/\1/p')"
    success_rate="$(printf '%s\n' "$health" | sed -n 's/.*\bsuccess=\([^ ]*\)\b.*/\1/p')"

    if [[ ! "$score" =~ ^[0-9]+$ ]]; then
        printf '%-24s %-28s %10s %9s %7s %7s %7s\n' "$name" "${host:--}" "${rtt:--}" "${jitter:--}" "${loss:--}" "${success_rate:--}" "ERROR"
        printf '[ERROR] %s: invalid score output: %s\n' "$name" "$scored" >&2
        errors=$((errors + 1))
        continue
    fi

    [[ -n "$host" ]] || { printf '[ERROR] %s: missing host in health result\n' "$name" >&2; errors=$((errors + 1)); continue; }
    [[ "$rtt" =~ ^[0-9]+([.][0-9]+)?$ ]] || rtt=999999
    [[ "$jitter" =~ ^[0-9]+([.][0-9]+)?$ ]] || jitter=999999
    [[ "$loss" =~ ^[0-9]+([.][0-9]+)?$ ]] || loss=100
    [[ "$success_rate" =~ ^[0-9]+([.][0-9]+)?$ ]] || success_rate=0
    [[ "$port" =~ ^[0-9]+$ ]] || port=0

    printf '%s\n' "$name|$host|$port|$rtt|$jitter|$loss|$success_rate|$score" >> "$RESULT_FILE"
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
printf '%-24s %-28s %10s %9s %7s %7s %7s\n' \
  "Profile" "Host" "RTT" "Jitter" "Loss" "Success" "Score"
printf '%s\n' '----------------------------------------------------------------------------------------------------------------'

sort -t'|' -k8,8nr -k7,7nr -k4,4n -k5,5n -k1,1 "$RESULT_FILE" |
while IFS='|' read -r name host port rtt jitter loss success_rate score; do
    printf '%-24s %-28s %8sms %7sms %7s%% %7s%% %7s\n' \
      "$name" "$host" "$rtt" "$jitter" "$loss" "$success_rate" "$score"
done

printf '%s\n' '----------------------------------------------------------------------------------------------------------------'

echo
echo "Winner"
echo "----------------------------------------------------------------------------------------------------------------"
printf 'Profile : %s\n' "$best_name"
printf 'Score   : %s/100\n' "$best_score"
printf 'RTT     : %sms\n' "$best_rtt"
printf 'Jitter  : %sms\n' "$best_jitter"
printf 'Success : %s%%\n' "$best_success"
echo "----------------------------------------------------------------------------------------------------------------"

info "Applying race decision..."
RACE_RESULT_FILE="$RESULT_FILE" "${BASE_DIR}/lib/race.sh"

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
    active_score="$(awk -F'|' -v n="$active" '$1 == n {print $8; exit}' "$RESULT_FILE")"
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
