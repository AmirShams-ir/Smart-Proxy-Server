#!/usr/bin/env bash

set -Eeuo pipefail

###############################################################################
# Smart Proxy Server - Reload / Race Report
# Runs health + scoring exactly once, prints a deterministic ranking, then
# applies the same result set through race.sh.
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
if [[ ! -d "$PROFILE_ROOT" || -z "$(find "$PROFILE_ROOT" -maxdepth 1 -type f -name '*.txt' -print -quit)" ]]; then
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

for file in "${profiles[@]}"; do
    name="$(basename "$file" .txt)"
    health_err=""
    health=""

    if health="$(${BASE_DIR}/lib/health.sh "$file" 2>&1)"; then
        :
    else
        printf '%-24s %-28s %10s %9s %7s %7s %7s\n' "$name" "-" "-" "-" "-" "-" "ERROR"
        printf '[ERROR] %s: %s\n' "$name" "$health" >&2
        ((errors+=1))
        continue
    fi

    if [[ -z "$health" ]]; then
        printf '%-24s %-28s %10s %9s %7s %7s %7s\n' "$name" "-" "-" "-" "-" "-" "ERROR"
        printf '[ERROR] %s: health.sh returned no metrics\n' "$name" >&2
        ((errors+=1))
        continue
    fi

    scored="$(printf '%s\n' "$health" | "${BASE_DIR}/lib/score.sh")"
    score="$(printf '%s\n' "$scored" | sed -n 's/.*score=\([^ ]*\).*/\1/p')"
    host="$(printf '%s\n' "$health" | sed -n 's/.*host=\([^ ]*\).*/\1/p')"
    rtt="$(printf '%s\n' "$health" | sed -n 's/.* rtt=\([^ ]*\).*/\1/p')"
    jitter="$(printf '%s\n' "$health" | sed -n 's/.* jitter=\([^ ]*\).*/\1/p')"
    loss="$(printf '%s\n' "$health" | sed -n 's/.* loss=\([^ ]*\).*/\1/p')"
    success_rate="$(printf '%s\n' "$health" | sed -n 's/.* success=\([^ ]*\).*/\1/p')"

    [[ "$score" =~ ^[0-9]+$ ]] || { printf '[ERROR] %s: invalid score: %s\n' "$name" "$scored" >&2; ((errors+=1)); continue; }
    [[ -n "$host" ]] || { printf '[ERROR] %s: missing host in health result\n' "$name" >&2; ((errors+=1)); continue; }
    [[ "$rtt" =~ ^[0-9]+([.][0-9]+)?$ ]] || rtt=999999
    [[ "$jitter" =~ ^[0-9]+([.][0-9]+)?$ ]] || jitter=999999
    [[ "$loss" =~ ^[0-9]+([.][0-9]+)?$ ]] || loss=100
    [[ "$success_rate" =~ ^[0-9]+([.][0-9]+)?$ ]] || success_rate=0

    printf '%s\n' "$name|$host|$rtt|$jitter|$loss|$success_rate|$score" >> "$RESULT_FILE"
    ((usable+=1))

    if awk -v s="$score" -v bs="$best_score" -v suc="$success_rate" -v bsuc="$best_success" -v r="$rtt" -v br="$best_rtt" -v j="$jitter" -v bj="$best_jitter" -v n="$name" -v bn="$best_name" 'BEGIN {
        if (s > bs) exit 0
        if (s < bs) exit 1
        if (suc > bsuc) exit 0
        if (suc < bsuc) exit 1
        if (r < br) exit 0
        if (r > br) exit 1
        if (j < bj) exit 0
        if (j > bj) exit 1
        if (bn == "" || n < bn) exit 0
        exit 1
    }'; then
        best_score="$score"
        best_name="$name"
        best_success="$success_rate"
        best_rtt="$rtt"
        best_jitter="$jitter"
    fi

done

printf '%s\n' '----------------------------------------------------------------------------------------------------------------'

if (( usable == 0 )); then
    fatal "No usable proxy profile found. Check: bash -x lib/health.sh <profile>"
fi

printf '\n'
info "Ranking proxy profiles..."
printf '\n'
printf '%-24s %-28s %10s %9s %7s %7s %7s\n' \
  "Profile" "Host" "RTT" "Jitter" "Loss" "Success" "Score"
printf '%s\n' '----------------------------------------------------------------------------------------------------------------'

sort -t'|' -k7,7nr -k6,6nr -k3,3n -k4,4n -k1,1 "$RESULT_FILE" |
while IFS='|' read -r name host rtt jitter loss success_rate score; do
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
import json,sys
try:
    with open(sys.argv[1],encoding='utf-8') as f:
        print(json.load(f).get('active',''))
except Exception:
    print('')
PY
)"
fi

if [[ -n "$active" ]]; then
    active_score="$(awk -F'|' -v n="$active" '$1==n {print $7; exit}' "$RESULT_FILE")"
    [[ -n "$active_score" ]] || active_score="unknown"
    echo
echo "Active Profile"
printf 'Profile : %s\n' "$active"
printf 'Score   : %s/100\n' "$active_score"
fi

if (( errors > 0 )); then
    warning "${usable} profiles usable, ${errors} profiles failed health checks."
fi

echo
echo "========================================"
success "Smart Proxy Server race completed successfully."
echo "========================================"
