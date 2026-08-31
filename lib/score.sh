#!/usr/bin/env bash
set -euo pipefail
BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "$BASE_DIR/config/defaults.conf"

get(){ printf '%s\n' "$1" | sed -n "s/.* $2=\([^ ]*\).*/\1/p"; }
input="$(cat)"
rtt="$(get "$input" rtt)"; jitter="$(get "$input" jitter)"; loss="$(get "$input" loss)"; success="$(get "$input" success)"
num(){ [[ "${1:-}" =~ ^[0-9]+([.][0-9]+)?$ ]]; }
num "$rtt" || rtt=9999
num "$jitter" || jitter=9999
num "$loss" || loss=100
num "$success" || success=0

# Normalized component scores: 100 is best. RTT is deliberately less
# forgiving than the legacy 0-500ms linear scale so healthy endpoints do not
# all collapse to score=100 after rounding.
clamp(){ awk -v x="$1" -v lo="$2" -v hi="$3" 'BEGIN{if(x<lo)x=lo;if(x>hi)x=hi;printf "%.6f",x}' ; }

rtt_n="$(clamp "$rtt" 0 250)"
jitter_n="$(clamp "$jitter" 0 100)"
loss_n="$(clamp "$loss" 0 100)"
success_n="$(clamp "$success" 0 100)"

# Smooth quality curves. 100ms RTT is still usable, but is meaningfully worse
# than 30ms; failures remain dominated by loss/success.
rtt_score="$(awk -v x="$rtt_n" 'BEGIN{printf "%.2f",100/(1+(x/45))}')"
jitter_score="$(awk -v x="$jitter_n" 'BEGIN{printf "%.2f",100/(1+(x/20))}')"
loss_score="$(awk -v x="$loss_n" 'BEGIN{printf "%.2f",100-x}')"

score="$(awk -v a="$rtt_score" -v b="$jitter_score" -v c="$loss_score" -v d="$success_n" -v aw="$RTT_WEIGHT" -v bw="$JITTER_WEIGHT" -v cw="$LOSS_WEIGHT" -v dw="$SUCCESS_WEIGHT" 'BEGIN{printf "%d",(a*aw+b*bw+c*cw+d*dw)/(aw+bw+cw+dw)+0.5}')"
(( score < 0 )) && score=0
(( score > 100 )) && score=100

printf 'score=%s rtt_score=%s jitter_score=%s loss_score=%s success_score=%s\n' "$score" "$rtt_score" "$jitter_score" "$loss_score" "$success_n"
