#!/usr/bin/env bash

set -Eeuo pipefail

###############################################################################
# Smart Proxy Server - Reload / Race Report
# Runs the health + scoring race and prints a human-readable report.
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

printf '\n'
info "Testing proxy profiles..."
printf '\n'
printf '%-24s %-28s %7s %9s %7s %7s %7s\n' \
  "Profile" "Host" "RTT" "Jitter" "Loss" "Success" "Score"
printf '%s\n' '---------------------------------------------------------------------------------------------------------------'

PROFILE_ROOT="$PROFILE_DIR"
if [[ ! -d "$PROFILE_ROOT" || -z "$(find "$PROFILE_ROOT" -maxdepth 1 -type f -name '*.txt' -print -quit)" ]]; then
    [[ -d "$BASE_DIR/profiles" ]] && PROFILE_ROOT="$BASE_DIR/profiles"
fi

shopt -s nullglob
mapfile -t profiles < <(find "$PROFILE_ROOT" -maxdepth 1 -type f -name '*.txt' | sort)
shopt -u nullglob

[[ ${#profiles[@]} -gt 0 ]] || fatal "No proxy profiles found in $PROFILE_ROOT"

best_name=""
best_score=-1
best_success=-1
best_rtt=999999
best_jitter=999999
rows=()

for file in "${profiles[@]}"; do
    name="$(basename "$file" .txt)"
    health="$(${BASE_DIR}/lib/health.sh "$file" 2>/dev/null || true)"
    if [[ -z "$health" ]]; then
        printf '%-24s %-28s %7s %9s %7s %7s %7s\n' "$name" "-" "-" "-" "-" "-" "ERROR"
        continue
    fi

    scored="$(printf '%s\n' "$health" | "${BASE_DIR}/lib/score.sh")"
    score="$(printf '%s\n' "$scored" | sed -n 's/.*score=\([0-9]*\).*/\1/p')"
    host="$(printf '%s\n' "$health" | sed -n 's/.*host=\([^ ]*\).*/\1/p')"
    rtt="$(printf '%s\n' "$health" | sed -n 's/.* rtt=\([^ ]*\).*/\1/p')"
    jitter="$(printf '%s\n' "$health" | sed -n 's/.* jitter=\([^ ]*\).*/\1/p')"
    loss="$(printf '%s\n' "$health" | sed -n 's/.* loss=\([^ ]*\).*/\1/p')"
    success_rate="$(printf '%s\n' "$health" | sed -n 's/.* success=\([^ ]*\).*/\1/p')"

    [[ "$score" =~ ^[0-9]+$ ]] || score=0
    rows+=("$score|$name|$host|$rtt|$jitter|$loss|$success_rate")

    if awk -v s="$score" -v bs="$best_score" -v suc="$success_rate" -v bsuc="$best_success" -v r="$rtt" -v br="$best_rtt" -v j="$jitter" -v bj="$best_jitter" 'BEGIN {
        if (s > bs) exit 0
        if (s < bs) exit 1
        if (suc > bsuc) exit 0
        if (suc < bsuc) exit 1
        if (r < br) exit 0
        if (r > br) exit 1
        if (j < bj) exit 0
        exit 1
    }'; then
        best_score="$score"
        best_name="$name"
        best_success="$success_rate"
        best_rtt="$rtt"
        best_jitter="$jitter"
    fi

done

printf '%s\n' "${rows[@]}" | sort -t'|' -k1,1nr -k7,7nr -k4,4n | while IFS='|' read -r score name host rtt jitter loss success_rate; do
    printf '%-24s %-28s %7sms %9sms %7s%% %7s%% %7s\n' \
      "$name" "$host" "$rtt" "$jitter" "$loss" "$success_rate" "$score"
done

printf '%s\n' '---------------------------------------------------------------------------------------------------------------'

[[ -n "$best_name" ]] || fatal "No usable proxy profile found."

echo
echo "Winner"
echo "---------------------------------------------------------------------------------------------------------------"
printf 'Profile : %s\n' "$best_name"
printf 'Score   : %s/100\n' "$best_score"
printf 'RTT     : %sms\n' "$best_rtt"
printf 'Jitter  : %sms\n' "$best_jitter"
printf 'Success : %s%%\n' "$best_success"

echo "---------------------------------------------------------------------------------------------------------------"

# race.sh is responsible for hysteresis, state management, generation and reload.
info "Applying race decision..."
result="$("${BASE_DIR}/lib/race.sh" 2>&1)"
printf '%s\n' "$result"

active="$(printf '%s\n' "$result" | sed -n 's/^\[ACTIVE\] \([^ ]*\).*$/\1/p' | tail -n1)"
active_score="$(printf '%s\n' "$result" | sed -n 's/^\[ACTIVE\] [^ ]*  score=\([0-9]*\).*$/\1/p' | tail -n1)"

if [[ -n "$active" ]]; then
    echo
echo "Active Profile"
printf 'Profile : %s\n' "$active"
printf 'Score   : %s/100\n' "${active_score:-unknown}"
fi

echo
echo "========================================"
success "Smart Proxy Server race completed successfully."
echo "========================================"
