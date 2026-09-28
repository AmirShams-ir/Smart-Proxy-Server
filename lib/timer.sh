#!/usr/bin/env bash
# Smart Proxy Server - Systemd Timer Synchronizer
set -Eeuo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="${SMARTPROXY_CONFIG_FILE:-$BASE_DIR/config/defaults.conf}"
TIMER_FILE="/etc/systemd/system/reload.timer"

fatal(){ printf '[✗] %s\n' "$*" >&2; exit 1; }
success(){ printf '[✓] %s\n' "$*"; }

[[ $EUID -eq 0 ]] || fatal "Run as root."
[[ -f "$CONFIG_FILE" ]] || fatal "Config not found: $CONFIG_FILE"

# Read only HEALTH_INTERVAL. Do not source defaults.conf because it contains
# shell-style parameter expansions intended for runtime configuration.
HEALTH_INTERVAL="$(awk -F= '
    /^[[:space:]]*#/ {next}
    /^[[:space:]]*HEALTH_INTERVAL[[:space:]]*=/ {
        sub(/^[[:space:]]*HEALTH_INTERVAL[[:space:]]*=/, "", $0)
        gsub(/[[:space:]]+/, "", $0)
        print
        exit
    }
' "$CONFIG_FILE")"

[[ "$HEALTH_INTERVAL" =~ ^[0-9]+([smhdw])$ ]] || fatal "Invalid HEALTH_INTERVAL in $CONFIG_FILE: ${HEALTH_INTERVAL:-empty}"

cat > "$TIMER_FILE" <<EOF
[Unit]
Description=Automatic Smart Proxy Server Full Rebuild

[Timer]
OnBootSec=30s
OnUnitActiveSec=${HEALTH_INTERVAL}
AccuracySec=1s
Persistent=true
Unit=reload.service

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable reload.timer >/dev/null
systemctl restart reload.timer

success "reload.timer synchronized to HEALTH_INTERVAL=${HEALTH_INTERVAL}"
