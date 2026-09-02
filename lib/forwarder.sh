#!/usr/bin/env bash
# ============================================================================
# Smart Proxy Server - Smart Edge Race Orchestrator
# Phase 1: discover Cloudflare edges for the profile's endpoint port.
# Phase 2: verify the top candidates at TLS/transport level.
# Phase 3: validate real VLESS/Trojan proxy traffic.
# Phase 4: rank and store the best Edge candidates.
# ============================================================================
set -Eeuo pipefail

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$BASE_DIR/config/defaults.conf"

PROFILE="${1:-}"
[[ -n "$PROFILE" ]] || { echo "Usage: $0 <profile-file>" >&2; exit 2; }
[[ -f "$PROFILE" ]] || { echo "profile not found: $PROFILE" >&2; exit 2; }

URI="$(head -n1 "$PROFILE" | tr -d '\r')"
SCHEME="${URI%%:*}"
[[ "$SCHEME" == "vless" || "$SCHEME" == "trojan" ]] || { echo "unsupported profile scheme" >&2; exit 3; }

PROFILE_PORT="$(printf '%s\n' "$URI" | sed -nE 's#^[a-z]+://[^@]+@[^:/?#]+:([0-9]+).*#\1#p')"
PROFILE_PORT="${PROFILE_PORT:-443}"
export EDGE_PORT="$PROFILE_PORT"

EDGE_CANDIDATE_FILE="${EDGE_CANDIDATE_FILE:-$BASE_DIR/cache/candidates.json}"
EDGE_VERIFIED_FILE="${EDGE_VERIFIED_FILE:-$BASE_DIR/cache/verified.json}"
EDGE_PROBE_FILE="${EDGE_PROBE_FILE:-$BASE_DIR/cache/probed.json}"
EDGE_WINNERS_FILE="${EDGE_WINNERS_FILE:-$BASE_DIR/cache/winners.json}"
export EDGE_CANDIDATE_FILE EDGE_VERIFIED_FILE EDGE_PROBE_FILE EDGE_WINNERS_FILE

mkdir -p "$BASE_DIR/cache" "$(dirname "$EDGE_CANDIDATE_FILE")"

printf '\nSmart Edge Race\n'
printf 'Profile : %s\n' "$(basename "$PROFILE")"
printf 'Port    : %s\n' "$PROFILE_PORT"
printf 'Scheme  : %s\n' "$SCHEME"
printf '%s\n\n' '------------------------------------------------------------'

"$BASE_DIR/lib/edge-discovery.sh" "$PROFILE"
"$BASE_DIR/lib/edge-verify.sh" "$PROFILE"
"$BASE_DIR/lib/edge-probe.sh" "$PROFILE"
"$BASE_DIR/lib/edge-score.sh" "$PROFILE"

python3 - "$EDGE_WINNERS_FILE" <<'PY'
import json,sys
p=sys.argv[1]
with open(p,encoding='utf-8') as f: d=json.load(f)
print('\nTop Smart Edge winners:')
print('IP               PORT   SCORE   PROXY(ms)  VERIFY(ms)')
print('----------------------------------------------------------')
for x in d.get('winners',[]):
    print(f"{x['ip']:<16} {x.get('port',0):<6} {x.get('score',0):<7.2f} {x.get('proxy_ms',999999):<10.2f} {x.get('verify_ms',999999):.2f}")
PY
