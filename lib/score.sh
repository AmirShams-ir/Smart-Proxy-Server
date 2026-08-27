#!/usr/bin/env bash
set -euo pipefail
BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "$BASE_DIR/config/defaults.conf"

get(){ printf '%s\n' "$1" | sed -n "s/.* $2=\([^ ]*\).*/\1/p"; }
input="$(cat)"
rtt="$(get "$input" rtt)"; jitter="$(get "$input" jitter)"; loss="$(get "$input" loss)"; success="$(get "$input" success)"
num(){ [[ "${1:-}" =~ ^[0-9]+([.][0-9]+)?$ ]]; }
num "$rtt" || rtt=9999; num "$jitter" || jitter=9999; num "$loss" || loss=100; num "$success" || success=0
# Normalized component scores: 100 is best.
clamp01(){ awk -v x="$1" -v lo="$2" -v hi="$3" 'BEGIN{if(x<lo)x=lo;if(x>hi)x=hi;print x}' ; }
rtt_n="$(clamp01 "$rtt" 0 500)"; jitter_n="$(clamp01 "$jitter" 0 200)"; loss_n="$(clamp01 "$loss" 0 100)"; success_n="$(clamp01 "$success" 0 100)"
rtt_score="$(awk -v x="$rtt_n" 'BEGIN{printf "%.2f",100-(x/500*100)}')"
jitter_score="$(awk -v x="$jitter_n" 'BEGIN{printf "%.2f",100-(x/200*100)}')"
loss_score="$(awk -v x="$loss_n" 'BEGIN{printf "%.2f",100-x}')"
score="$(awk -v a="$rtt_score" -v b="$jitter_score" -v c="$loss_score" -v d="$success_n" -v aw="$RTT_WEIGHT" -v bw="$JITTER_WEIGHT" -v cw="$LOSS_WEIGHT" -v dw="$SUCCESS_WEIGHT" 'BEGIN{printf "%d",(a*aw+b*bw+c*cw+d*dw)/(aw+bw+cw+dw)+0.5}')"
(( score < 0 )) && score=0; (( score > 100 )) && score=100
printf 'score=%s rtt_score=%s jitter_score=%s loss_score=%s success_score=%s\n' "$score" "$rtt_score" "$jitter_score" "$loss_score" "$success_n"