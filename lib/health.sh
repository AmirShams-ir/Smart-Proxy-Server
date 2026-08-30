#!/usr/bin/env bash
set -Eeuo pipefail
BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$BASE_DIR/config/defaults.conf"
mkdir -p "$LOG_DIR"

usage(){ echo "Usage: $0 <profile-file>" >&2; exit 2; }
[ $# -eq 1 ] || usage
profile="$1"
[ -f "$profile" ] || { echo "missing profile" >&2; exit 2; }

uri="$(head -n1 "$profile" | tr -d '\r')"
case "$uri" in
  vless://*|trojan://*) ;;
  *) echo "unsupported profile scheme" >&2; exit 3 ;;
esac

host="$(printf '%s\n' "$uri" | sed -nE 's#^[a-z]+://[^@]+@([^:/?#]+).*#\1#p')"
port="$(printf '%s\n' "$uri" | sed -nE 's#^[a-z]+://[^@]+@[^:/?#]+:([0-9]+).*#\1#p')"
[ -n "$host" ] || { echo "invalid profile host" >&2; exit 3; }
port="${port:-443}"

# Lightweight endpoint reachability metrics used for ranking.
raw="$(ping -n -c "$PING_COUNT" -W "$TIMEOUT" "$host" 2>/dev/null || true)"
loss="$(printf '%s\n' "$raw" | sed -nE 's/.*, ([0-9]+)% packet loss.*/\1/p' | tail -n1)"
rtt_avg="$(printf '%s\n' "$raw" | sed -nE 's/.* = [0-9.]+\/([0-9.]+)\/.* ms/\1/p' | tail -n1)"

# TCP connect timing fallback when ICMP is unavailable.
tcp_ms=""
if command -v timeout >/dev/null 2>&1; then
  start="$(date +%s%3N)"
  if timeout "$TIMEOUT" bash -c "</dev/tcp/$host/$port" 2>/dev/null; then
    tcp_ms="$(( $(date +%s%3N) - start ))"
  fi
fi

[ -n "${loss:-}" ] || loss=100
if [ -n "${rtt_avg:-}" ]; then rtt_ms="$rtt_avg"; elif [ -n "$tcp_ms" ]; then rtt_ms="$tcp_ms"; else rtt_ms=9999; fi

jitter_ms=0
samples="$(printf '%s\n' "$raw" | grep -oE 'time[=<][0-9.]+ ms' | sed -E 's/time[=<]//' || true)"
if [ "$(printf '%s\n' "$samples" | sed '/^$/d' | wc -l)" -ge 2 ]; then
  min="$(printf '%s\n' "$samples" | awk 'NR==1{m=$1} $1<m{m=$1} END{print int(m+0.5)}')"
  max="$(printf '%s\n' "$samples" | awk 'NR==1{m=$1} $1>m{m=$1} END{print int(m+0.5)}')"
  jitter_ms=$((max-min))
fi

success=$((100-loss))
printf 'host=%s port=%s rtt=%s jitter=%s loss=%s success=%s\n' "$host" "$port" "$rtt_ms" "$jitter_ms" "$loss" "$success"
