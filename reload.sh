#!/usr/bin/env bash
set -Eeuo pipefail

# Smart Proxy Server - Full Edge-to-Forwarder Orchestrator
# Pipeline:
#   scanner.sh -> maker.sh -> validator.sh -> score.sh -> forwarder.sh
#
# Normal reloads rebuild the complete proxy pool. No re-installation is needed
# when Cloudflare worker/edge paths fail.

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCK_FILE="/run/smartproxy-reload.lock"
LOG_DIR="/var/log/smartproxy"
RUN_DIR="/run/smartproxy"
PIPE_LOG="$LOG_DIR/rebuild.log"

SCANNER="$BASE_DIR/scanner.sh"
MAKER="$BASE_DIR/maker.sh"
VALIDATOR="$BASE_DIR/validator.sh"
SCORE="$BASE_DIR/score.sh"
FORWARDER="$BASE_DIR/forwarder.sh"

if [[ -n "${INVOCATION_ID:-}" ]] && command -v systemd-cat >/dev/null 2>&1 && [[ -z "${SMARTPROXY_JOURNALIZED:-}" ]]; then
    export SMARTPROXY_JOURNALIZED=1
    exec > >(systemd-cat -t smart-proxy-reload -p info) 2> >(systemd-cat -t smart-proxy-reload -p err)
fi

fatal(){ printf '[✗] %s\n' "$*" >&2; exit 1; }
info(){ printf '[*] %s\n' "$*"; }
warning(){ printf '[!] %s\n' "$*" >&2; }
success(){ printf '[✓] %s\n' "$*"; }

require_file(){
    [[ -f "$1" ]] || fatal "Required script not found: $1"
    [[ -x "$1" ]] || chmod +x "$1"
}

mkdir -p "$LOG_DIR" "$RUN_DIR"
touch "$PIPE_LOG"

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    warning "Another Smart Proxy rebuild is already running. Skipping this run."
    exit 0
fi

for script in "$SCANNER" "$MAKER" "$VALIDATOR" "$SCORE" "$FORWARDER"; do
    require_file "$script"
done

TMP_PIPE="$(mktemp -d /tmp/smartproxy-reload.XXXXXX)"
trap 'rm -rf "$TMP_PIPE"' EXIT INT TERM

run_stage(){
    local label="$1" script="$2" logfile="$TMP_PIPE/$3"
    info "[$label] $script"
    if ! bash "$script" > >(tee "$logfile") 2> >(tee -a "$PIPE_LOG" >&2); then
        warning "[$label] failed"
        return 1
    fi
    success "[$label] complete"
}

info "============================================================"
info "Smart Proxy Server full rebuild"
info "Pipeline: scanner -> maker -> validator -> score -> forwarder"
info "============================================================"

# 1. Fresh Cloudflare edge discovery
run_stage "1/5 Scanner" "$SCANNER" scanner.log || fatal "Scanner failed. Existing Forwarder was left untouched."

EDGE_FILE="$BASE_DIR/cache/edge.csv"
[[ -s "$EDGE_FILE" ]] || fatal "Scanner produced no edge.csv. Existing Forwarder was left untouched."
EDGE_COUNT="$(awk 'NR>1 && $1!="" {n++} END{print n+0}' "$EDGE_FILE")"
(( EDGE_COUNT > 0 )) || fatal "No usable edge IPs found. Existing Forwarder was left untouched."
info "Scanner produced $EDGE_COUNT edge(s)."

# 2. Candidate generation
run_stage "2/5 Maker" "$MAKER" maker.log || fatal "Maker failed. Existing Forwarder was left untouched."

GENERATED_DIR="$BASE_DIR/cache/generated"
GENERATED_COUNT="$(find "$GENERATED_DIR" -maxdepth 1 -type f -name '*.json' 2>/dev/null | wc -l | tr -d ' ')"
(( GENERATED_COUNT > 0 )) || fatal "Maker generated no candidates. Existing Forwarder was left untouched."
info "Maker produced $GENERATED_COUNT candidate(s)."

# 3. Protocol-aware validation
run_stage "3/5 Validator" "$VALIDATOR" validator.log || fatal "Validator failed. Existing Forwarder was left untouched."

VALID_CSV="$BASE_DIR/cache/valid.csv"
VALIDATED_DIR="$BASE_DIR/cache/validated"
[[ -s "$VALID_CSV" ]] || fatal "Validator produced no valid.csv. Existing Forwarder was left untouched."
VALIDATED_COUNT="$(find "$VALIDATED_DIR" -maxdepth 1 -type f -name '*.json' 2>/dev/null | wc -l | tr -d ' ')"
(( VALIDATED_COUNT > 0 )) || fatal "No validated profiles survived. Existing Forwarder was left untouched."
info "Validator kept $VALIDATED_COUNT validated candidate(s)."

# 4. Throughput scoring
run_stage "4/5 Score" "$SCORE" score.log || fatal "Score failed. Existing Forwarder was left untouched."

WINNER_CSV="$BASE_DIR/cache/winner.csv"
WINNER_DIR="$BASE_DIR/cache/winner"
[[ -s "$WINNER_CSV" ]] || fatal "Score produced no winner.csv. Existing Forwarder was left untouched."
ELIGIBLE_COUNT="$(awk -F',' 'NR>1 && tolower($7)=="yes" {n++} END{print n+0}' "$WINNER_CSV")"
WINNER_FILES="$(find "$WINNER_DIR" -maxdepth 1 -type f -name '*.json' 2>/dev/null | wc -l | tr -d ' ')"
(( ELIGIBLE_COUNT > 0 && WINNER_FILES > 0 )) || fatal "No eligible winners produced. Existing Forwarder was left untouched."
info "Score produced $ELIGIBLE_COUNT eligible winner(s)."

# 5. Replace the running Forwarder pool.
# forwarder.sh stops only its own managed processes, then starts the fresh
# winners on FORWARDER_BASE_PORT..FORWARDER_BASE_PORT+3.
run_stage "5/5 Forwarder" "$FORWARDER" forwarder.log || fatal "Forwarder failed to start the new pool."

LISTEN_BASE="${FORWARDER_BASE_PORT:-1080}"
LISTEN_MAX=$((LISTEN_BASE + ELIGIBLE_COUNT - 1))

printf '\n'
info "==================== Rebuild Summary ======================="
printf 'Scanner edges        : %s\n' "$EDGE_COUNT"
printf 'Generated candidates : %s\n' "$GENERATED_COUNT"
printf 'Validated candidates : %s\n' "$VALIDATED_COUNT"
printf 'Eligible winners     : %s\n' "$ELIGIBLE_COUNT"
printf 'Winner configs       : %s\n' "$WINNER_FILES"
printf 'Forwarder ports      : %s-%s\n' "$LISTEN_BASE" "$LISTEN_MAX"
info "============================================================"
success "Smart Proxy Server full rebuild completed."
